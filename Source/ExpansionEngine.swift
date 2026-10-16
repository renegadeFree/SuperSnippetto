import AppKit
import ApplicationServices
import Carbon
import Combine

private let expansionEventMarker: Int64 = 0x455350414E534F
private let hotKeySignature: OSType = 0x4553504C

private func expansionTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ context: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ExpansionEngine>.fromOpaque(context).takeUnretainedValue().receive(type, event)
}

private func expansionHotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard result == noErr, identifier.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
    let engine = Unmanaged<ExpansionEngine>.fromOpaque(context).takeUnretainedValue()
    engine.triggerHotkey(identifier.id)
    return noErr
}

/// A short-lived typing buffer is kept only in memory; keyboard input is never logged or saved.
final class ExpansionEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Espansione arrestata"
    var onLibraryChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var onExpansion: ((Snippet) -> Void)?
    var onShowSearch: (() -> Void)?
    private(set) var lastExternalApplication: NSRunningApplication?
    private struct PendingTrigger {
        var id = UUID()
        var text: String
        var target: NSRunningApplication
        var focus: AXUIElement
    }
    private var pendingTrigger: PendingTrigger?
    private var activeTrigger: PendingTrigger?
    private var expansionTarget: NSRunningApplication?
    private var expansionFocus: AXUIElement?
    private var interrupted = false

    private let store: LibraryStore
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var buffer = ""
    private var focusedElement: AXUIElement?
    private var workspaceObserver: NSObjectProtocol?
    private var hotkeyHandler: EventHandlerRef?
    private var hotkeyReferences: [EventHotKeyRef] = []
    private var hotkeySnippets: [UInt32: UUID] = [:]
    var recordingHotkey = false { didSet { refreshHotkeys() } }
    var searchHotkey: SearchHotkey { store.data.effectiveSearchHotkey }
    private var busy = false
    private var pasteboardRestoration: DispatchWorkItem?
    private let scriptQueue = DispatchQueue(label: "local.espanso.scripts", qos: .userInitiated)

    init(store: LibraryStore) {
        self.store = store
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resetBuffer()
            self?.rememberExternalApplication()
        }
        rememberExternalApplication()
    }

    private func rememberExternalApplication() {
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier { lastExternalApplication = app }
    }

    deinit {
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false); CFMachPortInvalidate(eventTap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        for reference in hotkeyReferences { UnregisterEventHotKey(reference) }
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler) }
    }

    func start(prompt: Bool = false) {
        refreshHotkeys()
        guard !running else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let accessibility = AXIsProcessTrustedWithOptions(options)
        var listening = CGPreflightListenEventAccess()
        if prompt && !listening { listening = CGRequestListenEventAccess() }
        guard accessibility && listening else {
            status = "Abilita Accessibilità e Monitoraggio input nelle Impostazioni di Sistema, poi premi Avvia."
            return
        }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: expansionTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            status = "Impossibile ascoltare la tastiera. Controlla i permessi e riavvia l’app."
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        running = true
        status = "Espansione attiva"
        resetBuffer()
        refreshHotkeys()
    }

    func stop() {
        interrupted = true
        pendingTrigger = nil
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false); CFMachPortInvalidate(eventTap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        running = false
        resetBuffer()
        for reference in hotkeyReferences { UnregisterEventHotKey(reference) }
        hotkeyReferences.removeAll()
        hotkeySnippets.removeAll()
        status = "Espansione arrestata"
    }

    private func resetBuffer() { buffer = ""; focusedElement = nil }

    fileprivate func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetBuffer()
            if running, let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != expansionEventMarker else { return Unmanaged.passUnretained(event) }
        if let trigger = activeTrigger ?? pendingTrigger,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            interrupted = true
            activeTrigger = nil
            pendingTrigger = nil
            resetBuffer()
            if sameFocus(target: trigger.target, focus: trigger.focus), let replay = event.copy() {
                // Preserve the swallowed character before forwarding this newer user action.
                sendText(trigger.text)
                replay.setIntegerValueField(.eventSourceUserData, value: expansionEventMarker)
                replay.post(tap: .cghidEventTap)
                return nil
            }
        }
        if busy {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier { interrupted = true }
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { resetBuffer(); return Unmanaged.passUnretained(event) }
        guard running, contextAllowsExpansion() else { resetBuffer(); return Unmanaged.passUnretained(event) }
        if event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty == false {
            resetBuffer(); return Unmanaged.passUnretained(event)
        }
        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if key == 51 { if !buffer.isEmpty { buffer.removeLast() }; return Unmanaged.passUnretained(event) }
        if [53, 71, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(Int(key)) {
            resetBuffer(); return Unmanaged.passUnretained(event)
        }
        var units = [UniChar](repeating: 0, count: 128)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        guard length > 0 else { return Unmanaged.passUnretained(event) }
        let typed = String(utf16CodeUnits: units, count: length)
        guard !typed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
            resetBuffer(); return Unmanaged.passUnretained(event)
        }
        buffer += typed.replacingOccurrences(of: "\r", with: "\n")
        buffer = String(buffer.suffix(256))
        guard let match = matchCurrentBuffer() else { return Unmanaged.passUnretained(event) }
        guard let target = NSWorkspace.shared.frontmostApplication, let focus = focusedElement else { return Unmanaged.passUnretained(event) }
        resetBuffer()
        // The incoming key has not reached the destination. Remove only characters already delivered.
        let deleteCount = max(0, match.deleteCount - typed.count)
        let trigger = PendingTrigger(text: typed, target: target, focus: focus)
        pendingTrigger = trigger
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingTrigger?.id == trigger.id else { return }
            self.expand(match.snippet, deleteCount: deleteCount, typedAbbreviation: match.typedAbbreviation, trailingDelimiter: match.trailingDelimiter)
        }
        return nil
    }

    private func contextAllowsExpansion() -> Bool {
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted(), let application = NSWorkspace.shared.frontmostApplication else { return false }
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        lastExternalApplication = application
        guard libraryAllows(application.bundleIdentifier ?? "") else { return false }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            resetBuffer(); return false
        }
        let element = value as! AXUIElement
        if let focusedElement, !CFEqual(focusedElement, element) { buffer = "" }
        self.focusedElement = element
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) != (kAXSecureTextFieldSubrole as String) else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role as? String ?? "")
    }

    fileprivate func triggerHotkey(_ identifier: UInt32) {
        if identifier == 0 {
            guard !recordingHotkey, !busy, !IsSecureEventInputEnabled() else { return }
            rememberExternalApplication()
            onShowSearch?()
            return
        }
        guard running, !busy, contextAllowsExpansion(), let id = hotkeySnippets[identifier], let snippet = lookupSnippet(id), snippetAllowed(snippet) else { return }
        expand(snippet)
    }

    func refreshHotkeys() {
        for reference in hotkeyReferences { UnregisterEventHotKey(reference) }
        hotkeyReferences.removeAll()
        hotkeySnippets.removeAll()
        guard !recordingHotkey else { return }
        if hotkeyHandler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), expansionHotKeyCallback, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &hotkeyHandler)
            if result != noErr { onError?("Registrazione scorciatoie non disponibile (\(result))."); return }
        }
        var searchReference: EventHotKeyRef?
        let shortcut = searchHotkey
        guard shortcut.isValid else { onError?("Scorciatoia di ricerca non valida."); return }
        let searchResult = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers, EventHotKeyID(signature: hotKeySignature, id: 0), GetApplicationEventTarget(), 0, &searchReference)
        if searchResult == noErr, let searchReference { hotkeyReferences.append(searchReference) }
        else { onError?("La scorciatoia di ricerca è già in uso o non disponibile (\(searchResult)). Scegline un’altra nelle impostazioni.") }
        if running { registerLibraryHotkeys() }
    }

    func setSearchHotkey(_ shortcut: SearchHotkey) throws {
        guard shortcut.isValid else { throw LibraryError.invalid("Usa almeno ⌘, ⌥ o ⌃, senza Esc.") }
        guard !store.data.searchHotkeyConflict(shortcut) else { throw LibraryError.invalid("Questa combinazione è già assegnata a un frammento. Scegline un’altra.") }
        // Probe before changing the saved preference; recording temporarily releases our hotkeys.
        if shortcut != searchHotkey || recordingHotkey {
            var probe: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers, EventHotKeyID(signature: hotKeySignature, id: UInt32.max), GetApplicationEventTarget(), 0, &probe)
            guard result == noErr, let probe else { throw LibraryError.invalid("Combinazione già in uso da macOS o da un’altra app (\(result)). Scegline un’altra.") }
            UnregisterEventHotKey(probe)
        }
        let previous = store.data.searchHotkey
        store.data.searchHotkey = shortcut
        do { try store.save() }
        catch { store.data.searchHotkey = previous; throw error }
        refreshHotkeys()
    }

    private func registerHotkey(snippetID: UUID, keyCode: UInt32, modifiers: UInt32) {
        let identifier = UInt32(hotkeySnippets.count + 1)
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: hotKeySignature, id: identifier), GetApplicationEventTarget(), 0, &reference)
        if result == noErr, let reference { hotkeyReferences.append(reference); hotkeySnippets[identifier] = snippetID }
        else { onError?("Una scorciatoia è già in uso o non è disponibile (\(result)).") }
    }

    func expand(_ snippet: Snippet, deleteCount: Int = 0, typedAbbreviation: String = "", trailingDelimiter: String = "") {
        let trigger = pendingTrigger
        pendingTrigger = nil
        rememberExternalApplication()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let target = trigger?.target ?? (frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier ? lastExternalApplication : frontmost)
        guard !busy, !IsSecureEventInputEnabled(), AXIsProcessTrusted(), let target,
              store.isEnabled(snippet, appID: target.bundleIdentifier ?? "") else {
            if let trigger { recoverSuppressedText(trigger) }
            else if !AXIsProcessTrusted() { onError?("Abilita Accessibilità per SuperSnippetto nelle Impostazioni di Sistema prima di inserire testo nelle altre app.") }
            else if store.data.paused { onError?("L’espansione è in pausa. Riattivala dal menu nella barra di macOS.") }
            else if busy { onError?("Attendi il completamento dell’inserimento in corso.") }
            else { onError?("Il frammento non è disponibile nell’app corrente o il campo è protetto.") }
            return
        }
        let focus = trigger?.focus ?? focusedElement(in: target)
        guard let focus else {
            if let trigger { recoverSuppressedText(trigger) }
            else { onError?("Seleziona prima un campo di testo nell’app di destinazione, poi riapri la ricerca rapida.") }
            return
        }
        if let trigger, !sameFocus(target: trigger.target, focus: trigger.focus) { return }
        resetBuffer()
        busy = true
        interrupted = false
        expansionTarget = target
        expansionFocus = focus
        activeTrigger = trigger
        prepareExpansion(snippet, typedAbbreviation: typedAbbreviation) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.activeTrigger = nil
                self.busy = false
                if let trigger, !self.interrupted { self.recoverSuppressedText(trigger) }
                if (error as NSError).code != NSUserCancelledError { self.onError?(error.localizedDescription) }
            case .success(let output):
                guard !self.interrupted, !IsSecureEventInputEnabled(), AXIsProcessTrusted(), !target.isTerminated,
                      self.store.isEnabled(snippet, appID: target.bundleIdentifier ?? "") else {
                    self.activeTrigger = nil
                    self.busy = false
                    if let trigger, !self.interrupted { self.recoverSuppressedText(trigger) }
                    return
                }
                target.activate(options: [])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    guard !self.interrupted, self.sameFocus(target: target, focus: focus), self.contextAllowsExpansion() else {
                        self.activeTrigger = nil
                        self.busy = false
                        if let trigger, !self.interrupted { self.recoverSuppressedText(trigger) }
                        return
                    }
                    self.deliver(output, snippet: snippet, deleteCount: deleteCount, trailingDelimiter: trailingDelimiter)
                }
            }
        }
    }

    func preview(_ snippet: Snippet) {
        guard !busy else { onError?("Attendi l’inserimento in corso."); return }
        guard [.plain, .rich, .html].contains(snippet.kind) else { onError?("L’anteprima con campi è disponibile per i frammenti di testo."); return }
        busy = true
        // Finish the button/accessibility action before entering AppKit's modal loop.
        DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.prepareExpansion(snippet, typedAbbreviation: "") { [weak self] result in
            defer { self?.busy = false }
            switch result {
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { self?.onError?(error.localizedDescription) }
            case .success(let output):
                let alert = NSAlert(); alert.messageText = "Anteprima: \(snippet.title)"
                alert.informativeText = "Il risultato rimane in questa finestra."
                alert.addButton(withTitle: "Chiudi")
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 280)); scroll.hasVerticalScroller = true
                let view = NSTextView(frame: scroll.bounds); view.isEditable = false; view.isSelectable = true; view.font = .systemFont(ofSize: 14)
                if let data = output.richData, let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { view.textStorage?.setAttributedString(attr) }
                else { view.string = output.text }
                view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.textContainer?.widthTracksTextView = true
                scroll.documentView = view; alert.accessoryView = scroll; NSApp.activate(ignoringOtherApps: true); alert.runModal()
            }
        }
        }
    }

    private func focusedElement(in application: NSRunningApplication) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(application.processIdentifier), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func sameFocus(target: NSRunningApplication, focus: AXUIElement) -> Bool {
        guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let current = focusedElement(in: target) else { return false }
        return CFEqual(current, focus)
    }

    private struct ExpansionOutput {
        var text: String
        var richData: Data? = nil
        var richType: NSPasteboard.PasteboardType? = nil
        var cursorOffset: Int? = nil
    }

    private func deliver(_ output: ExpansionOutput, snippet: Snippet, deleteCount: Int, trailingDelimiter: String) {
        let pasteboard = NSPasteboard.general
        pasteboardRestoration?.perform()
        pasteboardRestoration?.cancel()
        let backup = (pasteboard.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if output.richType != .tiff { item.setString(output.text + trailingDelimiter, forType: .string) }
        if let data = output.richData, let type = output.richType {
            if type == .rtf,
               let rich = try? NSMutableAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                if !trailingDelimiter.isEmpty { rich.append(NSAttributedString(string: trailingDelimiter)) }
                let range = NSRange(location: 0, length: rich.length)
                if let updated = try? rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) { item.setData(updated, forType: .rtf) }
                if let html = try? rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) { item.setData(html, forType: .html) }
            } else { item.setData(data, forType: type) }
        }
        pasteboard.writeObjects([item])
        let ourChangeCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            guard !self.interrupted, let target = self.expansionTarget, let focus = self.expansionFocus,
                  self.sameFocus(target: target, focus: focus), self.contextAllowsExpansion() else {
                let trigger = self.activeTrigger
                self.activeTrigger = nil
                self.busy = false
                if let trigger, !self.interrupted { self.recoverSuppressedText(trigger) }
                return
            }
            self.activeTrigger = nil
            for _ in 0..<min(deleteCount, 256) { self.sendKey(51) }
            self.sendKey(9, flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                guard !self.interrupted, self.sameFocus(target: target, focus: focus) else { self.busy = false; return }
                if output.richType == .tiff && !trailingDelimiter.isEmpty { self.sendText(trailingDelimiter) }
                let movements = output.cursorOffset.map { max(0, $0 + trailingDelimiter.count) } ?? 0
                for _ in 0..<min(movements, 10_000) { self.sendKey(123) }
                self.busy = false
                self.onExpansion?(snippet)
            }
        }
        let restore = DispatchWorkItem {
            guard pasteboard.changeCount == ourChangeCount else { return }
            pasteboard.clearContents()
            let objects: [NSPasteboardItem] = backup.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !objects.isEmpty { pasteboard.writeObjects(objects) }
        }
        pasteboardRestoration = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restore)
    }

    private func sendKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: expansionEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    private func recoverSuppressedText(_ trigger: PendingTrigger) {
        guard !trigger.text.isEmpty, !trigger.target.isTerminated, !IsSecureEventInputEnabled() else { return }
        // Never move a swallowed character into another application or another field.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier { trigger.target.activate(options: []) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard self.sameFocus(target: trigger.target, focus: trigger.focus) else { return }
            self.sendText(trigger.text)
        }
    }

    private func sendText(_ text: String) {
        let units = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.setIntegerValueField(.eventSourceUserData, value: expansionEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    // Model integration is kept here so keyboard handling has one implementation.
    private func libraryAllows(_ appID: String) -> Bool { !store.data.paused && !store.data.excludedApps.contains(appID) }
    private func lookupSnippet(_ id: UUID) -> Snippet? { store.data.snippets.first { $0.id == id } }
    private func snippetAllowed(_ snippet: Snippet) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        let target = app?.bundleIdentifier == Bundle.main.bundleIdentifier ? lastExternalApplication : app
        return store.isEnabled(snippet, appID: target?.bundleIdentifier ?? "")
    }
    private func matchCurrentBuffer() -> ExpansionMatch? {
        store.match(in: buffer, appID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }
    private func registerLibraryHotkeys() {
        for snippet in store.data.snippets where snippet.enabled {
            guard let keyCode = snippet.hotkeyCode, (0...127).contains(keyCode) else { continue }
            if keyCode == searchHotkey.keyCode && snippet.hotkeyModifiers == searchHotkey.modifiers {
                onError?("Una scorciatoia di frammento coincide con quella della ricerca: modifica una delle due nelle impostazioni.")
                continue
            }
            registerHotkey(snippetID: snippet.id, keyCode: UInt32(keyCode), modifiers: snippet.hotkeyModifiers)
        }
    }

    private func selectedText() -> String {
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted(), let app = lastExternalApplication else { return "" }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return "" }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) != (kAXSecureTextFieldSubrole as String) else { return "" }
        var selected: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected)
        return selected as? String ?? ""
    }

    private func prepareExpansion(_ snippet: Snippet, typedAbbreviation: String, completion: @escaping (Result<ExpansionOutput, Error>) -> Void) {
        do {
            if snippet.kind == .image {
                let path = (snippet.content as NSString).expandingTildeInPath
                guard let image = NSImage(contentsOfFile: path), let data = image.tiffRepresentation else { throw LibraryError.invalid("L’immagine non è leggibile: \(path)") }
                completion(.success(ExpansionOutput(text: "", richData: data, richType: .tiff)))
                return
            }
            var context = RenderContext(clipboard: NSPasteboard.general.string(forType: .string) ?? "", selection: selectedText())
            let rich = snippet.kind == .rich || snippet.kind == .html
            if rich { context.clipboard = escapeHTML(context.clipboard); context.selection = escapeHTML(context.selection) }
            context.lookup = { [weak self] abbreviation in
                guard let self else { return nil }
                let candidates = self.store.data.snippets.filter { self.snippetAllowed($0) }
                let found = UUID(uuidString: abbreviation).flatMap { id in candidates.first { $0.id == id } }
                    ?? candidates.first { $0.matchesAbbreviation(abbreviation) }
                // Nested script/image snippets require a different execution pipeline.
                // Do not paste their source code as if it were expanded plain text.
                guard let found, [.plain, .rich, .html].contains(found.kind) else { return nil }
                return found.content
            }
            var rendered = try TemplateRenderer().render(snippet.content, context: context)
            var fieldRounds = 0
            while !rendered.fields.isEmpty {
                fieldRounds += 1
                guard fieldRounds <= 16, context.variables.count + rendered.fields.count <= 50 else { throw LibraryError.invalid("Troppi campi o condizioni annidate nel frammento.") }
                let specs = rendered.fields.map { name in rendered.fieldSpecs.first { $0.name == name } ?? TemplateField(name: name) }
                let answers = try askForFields(specs, title: snippet.title)
                var values = answers.values
                context.fieldTruth.merge(answers.truth) { _, new in new }
                if rich { values = values.mapValues(escapeHTML) }
                context.variables.merge(values) { _, new in new }
                rendered = try TemplateRenderer().render(snippet.content, context: context)
            }
            let code = rendered.text
            if [.shell, .appleScript, .javascript].contains(snippet.kind) {
                guard store.data.allowScripts else { throw LibraryError.invalid("L’esecuzione degli script è disabilitata. Abilitala nelle impostazioni solo per frammenti attendibili.") }
                scriptQueue.async {
                    let result = Result { try LocalScriptRunner.run(code: code, kind: snippet.kind) }
                    DispatchQueue.main.async {
                        completion(result.map { ExpansionOutput(text: self.adaptCase($0, snippet: snippet, typed: typedAbbreviation)) })
                    }
                }
                return
            }
            var text = rendered.text
            var cursorOffset = rendered.cursorOffset.map { text.count - $0 }
            if snippet.kind == .html || snippet.kind == .rich {
                // A temporary marker lets HTML tags disappear without moving the intended cursor.
                if let position = rendered.cursorOffset {
                    text.insert("\u{E001}", at: text.index(text.startIndex, offsetBy: position))
                }
                var attributed = try NSMutableAttributedString(data: Data(text.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
                let letters = typedAbbreviation.filter { $0.isLetter }
                if snippet.adaptCase, !letters.isEmpty, letters == letters.uppercased() {
                    let transformed = NSMutableAttributedString(string: "")
                    attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
                        transformed.append(NSAttributedString(string: (attributed.string as NSString).substring(with: range).uppercased(), attributes: attributes))
                    }
                    attributed = transformed
                } else if snippet.adaptCase, let first = letters.first, first.isUppercase,
                          String(letters.dropFirst()) == String(letters.dropFirst()).lowercased(), let initial = attributed.string.first {
                    attributed.replaceCharacters(in: NSRange(location: 0, length: String(initial).utf16.count), with: String(initial).uppercased())
                }
                let plain = attributed.string
                if let marker = plain.firstIndex(of: "\u{E001}") {
                    cursorOffset = plain[plain.index(after: marker)...].count
                    attributed.replaceCharacters(in: NSRange(marker...marker, in: plain), with: "")
                }
                let plainText = attributed.string
                let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                completion(.success(ExpansionOutput(text: plainText, richData: rtf, richType: .rtf, cursorOffset: cursorOffset)))
            } else {
                if let position = rendered.cursorOffset {
                    let suffix = String(text.suffix(text.count - position))
                    cursorOffset = adaptCase(suffix, snippet: snippet, typed: typedAbbreviation).count
                }
                text = adaptCase(text, snippet: snippet, typed: typedAbbreviation)
                completion(.success(ExpansionOutput(text: text, cursorOffset: cursorOffset)))
            }
        } catch { completion(.failure(error)) }
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func adaptCase(_ text: String, snippet: Snippet, typed: String) -> String {
        guard snippet.adaptCase, !typed.isEmpty else { return text }
        let letters = typed.filter { $0.isLetter }
        guard !letters.isEmpty else { return text }
        if letters == letters.uppercased() { return text.uppercased() }
        if let first = letters.first, first.isUppercase, String(letters.dropFirst()) == String(letters.dropFirst()).lowercased() {
            guard let character = text.first else { return text }
            return String(character).uppercased() + text.dropFirst()
        }
        return text
    }

    private func askForFields(_ specs: [TemplateField], title: String) throws -> (values: [String: String], truth: [String: Bool]) {
        guard specs.count <= 50 else { throw LibraryError.invalid("Un frammento può chiedere al massimo 50 campi.") }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Completa i campi del frammento."
        alert.addButton(withTitle: "Inserisci")
        alert.addButton(withTitle: "Annulla")
        let height = specs.reduce(CGFloat(0)) { $0 + ($1.kind == .multiline ? 124 : 58) }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: height))
        var readers: [(String, () -> String)] = []
        var booleanReaders: [(String, () -> Bool)] = []
        var firstControl: NSView?
        var y = height
        for spec in specs {
            let rowHeight: CGFloat = spec.kind == .multiline ? 124 : 58
            y -= rowHeight
            let label = NSTextField(labelWithString: spec.name)
            label.frame = NSRect(x: 0, y: y + rowHeight - 24, width: 340, height: 20)
            view.addSubview(label)
            let frame = NSRect(x: 0, y: y + 4, width: 340, height: 26)
            let control: NSView
            switch spec.kind {
            case .choice:
                let popup = NSPopUpButton(frame: frame, pullsDown: false)
                popup.addItems(withTitles: spec.options); popup.setAccessibilityLabel(spec.name)
                readers.append((spec.name, { popup.titleOfSelectedItem ?? "" })); control = popup
            case .checkbox:
                let checkbox = NSButton(checkboxWithTitle: spec.options.first ?? "sì", target: nil, action: nil)
                checkbox.frame = frame; checkbox.setAccessibilityLabel(spec.name)
                readers.append((spec.name, { checkbox.state == .on ? (spec.options.first ?? "sì") : (spec.options.last ?? "no") })); control = checkbox
                booleanReaders.append((spec.name, { checkbox.state == .on }))
            case .date:
                let picker = NSDatePicker(frame: frame); picker.datePickerStyle = .textFieldAndStepper; picker.datePickerElements = .yearMonthDay; picker.dateValue = Date(); picker.setAccessibilityLabel(spec.name)
                readers.append((spec.name, { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "it_IT"); formatter.dateFormat = spec.dateFormat; return formatter.string(from: picker.dateValue) })); control = picker
            case .multiline:
                let scroll = NSScrollView(frame: NSRect(x: 0, y: y + 4, width: 340, height: 90)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
                let text = NSTextView(frame: scroll.bounds); text.isRichText = false; text.allowsUndo = true; text.string = spec.defaultValue; text.font = .systemFont(ofSize: 13); text.setAccessibilityLabel(spec.name)
                text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.textContainer?.widthTracksTextView = true; scroll.documentView = text
                readers.append((spec.name, { text.string })); control = scroll
                if firstControl == nil { firstControl = text }
            case .text:
                let field = NSTextField(frame: frame); field.stringValue = spec.defaultValue; field.setAccessibilityLabel(spec.name)
                readers.append((spec.name, { field.stringValue })); control = field
            }
            view.addSubview(control)
            if firstControl == nil { firstControl = control }
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 365, height: min(400, height)))
        scroll.documentView = view
        scroll.hasVerticalScroller = height > 400
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - scroll.contentView.bounds.height)))
        alert.accessoryView = scroll
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = firstControl
        guard alert.runModal() == .alertFirstButtonReturn else { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
        return (Dictionary(uniqueKeysWithValues: readers.map { ($0.0, $0.1()) }), Dictionary(uniqueKeysWithValues: booleanReaders.map { ($0.0, $0.1()) }))
    }
}

/// Scripts use the user's normal account and can access its files. They require explicit opt-in.
/// The interpreter is fixed; only the snippet content is passed as a script argument.
private enum LocalScriptRunner {
    static func run(code: String, kind: SnippetKind) throws -> String {
        let process = Process()
        switch kind {
        case .shell: process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-c", code]
        case .appleScript: process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); process.arguments = ["-l", "AppleScript", "-e", code]
        case .javascript: process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); process.arguments = ["-l", "JavaScript", "-e", code]
        default: throw LibraryError.invalid("Tipo di script non valido.")
        }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("EspansoLocale-script-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw LibraryError.invalid("Impossibile preparare l’output dello script.")
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        process.standardOutput = output
        // Error output may contain secrets and is intentionally not exposed or saved.
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        func outputSize() -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        }
        do { try process.run() }
        catch { throw LibraryError.invalid("Impossibile avviare l’interprete dello script.") }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline && outputSize() <= 1_048_576 { Thread.sleep(forTimeInterval: 0.025) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        if outputSize() > 1_048_576 { throw LibraryError.invalid("Lo script supera il limite di output di 1 MB.") }
        if timedOut { throw LibraryError.invalid("Lo script è stato fermato dopo 5 secondi.") }
        guard process.terminationStatus == 0 else { throw LibraryError.invalid("Lo script è terminato con errore (\(process.terminationStatus)).") }
        guard let string = String(data: try Data(contentsOf: outputURL), encoding: .utf8) else { throw LibraryError.invalid("Lo script deve produrre testo UTF-8.") }
        return string.hasSuffix("\n") ? String(string.dropLast()) : string
    }
}


#if ENGINE_SELF_TEST
@main
private enum EngineSelfTest {
    static func main() throws {
        func expectFailure(_ operation: () throws -> Void) {
            do { try operation(); assertionFailure("Expected an error") } catch { }
        }
        let hello = try LocalScriptRunner.run(code: "printf 'ciao\\n'", kind: .shell)
        let unicode = try LocalScriptRunner.run(code: "printf 'è🙂\\n\\n'", kind: .shell)
        assert(hello == "ciao")
        assert(unicode == "è🙂\n")
        expectFailure { _ = try LocalScriptRunner.run(code: "exit 7", kind: .shell) }
        expectFailure { _ = try LocalScriptRunner.run(code: "printf '%01048577d' 0", kind: .shell) }
        let start = Date()
        expectFailure { _ = try LocalScriptRunner.run(code: "sleep 10", kind: .shell) }
        assert(Date().timeIntervalSince(start) < 7)
        try searchHotkeyChecks()
        print("Engine: 12 script/output/timeout and native hotkey checks passed")
    }

    static func searchHotkeyChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSnippettoHotkey-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(url: root.appendingPathComponent("library.json"))
        let engine = ExpansionEngine(store: store)
        engine.recordingHotkey = true
        let shortcut = SearchHotkey(keyCode: 80, modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
        var occupied: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers, EventHotKeyID(signature: 0x54455354, id: 1), GetApplicationEventTarget(), 0, &occupied)
        guard result == noErr, let occupied else { fatalError("Native test shortcut unavailable: \(result)") }
        do { try engine.setSearchHotkey(shortcut); fatalError("Occupied shortcut accepted") } catch { }
        assert(store.data.searchHotkey == nil)
        UnregisterEventHotKey(occupied)
        try engine.setSearchHotkey(shortcut)
        assert(LibraryStore(url: store.fileURL).data.searchHotkey == shortcut)
        engine.recordingHotkey = false
        var opened = 0
        engine.onShowSearch = { opened += 1 }
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr, let event else { fatalError("Cannot create test Carbon message") }
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: hotKeySignature, id: 0)
        assert(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id) == noErr)
        assert(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
        assert(opened == 1)
        engine.recordingHotkey = true
        engine.triggerHotkey(0)
        assert(opened == 1)
    }
}
#endif
