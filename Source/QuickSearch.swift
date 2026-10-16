import SwiftUI
import AppKit
import Carbon

extension SearchHotkey {
    var label: String {
        let special = [36: "Invio", 48: "Tab", 49: "Spazio", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        var key = special[keyCode] ?? "tasto \(keyCode)"
        if special[keyCode] == nil, let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            var dead: UInt32 = 0; var length = 0; var characters = [UniChar](repeating: 0, count: 8)
            if UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit), &dead, characters.count, &length, &characters) == noErr, length > 0 {
                let translated = String(utf16CodeUnits: characters, count: length)
                if !translated.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value) }) { key = translated.uppercased() }
            }
        }
        return (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + key
    }
}

final class QuickSearchPanel: NSPanel {
    private var localClick: Any?
    private var globalClick: Any?
    private var deactivationObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "Cerca e inserisci"; level = .floating; isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClick = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            if let self, self.isVisible, event.window !== self { self.orderOut(nil) }
            return event
        }
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            if self?.isVisible == true { self?.orderOut(nil) }
        }
        deactivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.orderOut(nil) }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.makeKeyAndOrderFront(nil)
        }
    }
    override var canBecomeKey: Bool { true }
    override func becomeKey() {
        super.becomeKey()
        // SwiftUI's onAppear can run before the panel is key. Focus the native field here.
        func findField(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            return view.subviews.lazy.compactMap { findField($0) }.first
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isKeyWindow, let contentView = self.contentView, let field = findField(contentView) else { return }
            self.makeFirstResponder(field); field.selectText(nil)
        }
    }
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
    deinit {
        if let localClick { NSEvent.removeMonitor(localClick) }
        if let globalClick { NSEvent.removeMonitor(globalClick) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
}

struct QuickSearchField: NSViewRepresentable {
    @Binding var query: String
    let move: (Int) -> Void
    let insert: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusedSearchField()
        field.placeholderString = "Cerca titolo, abbreviazione o testo…"
        field.setAccessibilityLabel("Cerca un frammento")
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
        field.window?.initialFirstResponder = field
    }
    class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: QuickSearchField
        init(_ parent: QuickSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.query = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.insert()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
    class FocusedSearchField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.initialFirstResponder = self
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.isKeyWindow else { return }
                window.makeFirstResponder(self); self.selectText(nil)
            }
        }
    }
}

enum SnippetPreview {
    static func text(_ snippet: Snippet) -> String {
        switch snippet.kind {
        case .image: return "Immagine: \((snippet.content as NSString).lastPathComponent)"
        case .shell, .appleScript, .javascript: return "Script · eseguito solo all’inserimento"
        default:
            var text = String(snippet.content.prefix(16_384))
            if [.html, .rich].contains(snippet.kind) {
                // A text-only excerpt: never render HTML or load images/resources while searching.
                text = text.replacingOccurrences(of: #"(?is)<(script|style|head)\b[^>]*>.*?</\1\s*>"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)</?(?:p|div|br|li|tr|h[1-6])\b[^>]*>"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                let entities = ["nbsp": " ", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&"]
                let pattern = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-z]+);"#)
                let original = text as NSString
                for match in pattern.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
                    let name = original.substring(with: match.range(at: 1))
                    let number = name.hasPrefix("#x") ? UInt32(name.dropFirst(2), radix: 16) : (name.hasPrefix("#") ? UInt32(name.dropFirst()) : nil)
                    if let value = entities[name] ?? number.flatMap(UnicodeScalar.init).map(String.init), let range = Range(match.range, in: text) { text.replaceSubrange(range, with: value) }
                }
            }
            return String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(240))
        }
    }
}

struct QuickSearchView: View {
    @ObservedObject var store: LibraryStore
    let insert: (Snippet) -> Void
    @State private var query = ""
    @State private var selected: UUID?
    private var matches: [Snippet] { SnippetSearch.results(store.data.snippets, query: query) }
    var body: some View {
        VStack(spacing: 10) {
            QuickSearchField(query: $query, move: move, insert: choose, cancel: { NSApp.keyWindow?.cancelOperation(nil) }).frame(height: 26)
            ScrollViewReader { proxy in
                List(selection: $selected) {
                    ForEach(matches) { snippet in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snippet.title).fontWeight(.semibold).lineLimit(1)
                            Text(snippet.allAbbreviations.isEmpty ? "Senza abbreviazione" : snippet.allAbbreviations.joined(separator: " · "))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            Text(SnippetPreview.text(snippet)).font(.callout).lineLimit(2)
                        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).tag(snippet.id).id(snippet.id)
                    }
                }.onChange(of: selected) { id in if let id { proxy.scrollTo(id) } }
            }
            if matches.isEmpty { Text("Nessun frammento trovato").foregroundStyle(.secondary) }
            HStack {
                Text("↑↓ seleziona · Invio inserisce · Esc chiude").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Inserisci", action: choose).keyboardShortcut(.defaultAction).disabled(selectedSnippet == nil)
            }
        }.padding(15)
            .onAppear { selected = matches.first?.id }
            .onChange(of: query) { _ in selected = matches.first?.id }
    }
    private var selectedSnippet: Snippet? { matches.first { $0.id == selected } }
    private func move(_ offset: Int) { selected = SnippetSearch.moving(selected, by: offset, in: matches) }
    private func choose() { if let snippet = selectedSnippet { insert(snippet) } }
}

