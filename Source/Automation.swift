import AppKit
import ApplicationServices
import Carbon

private enum AutomationFailure: LocalizedError {
    case invalid(String)
    case missing(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self { case .invalid(let text), .missing(let text), .unavailable(let text): return text }
    }
    var number: Int {
        switch self { case .invalid: return -1700; case .missing: return -1728; case .unavailable: return -2700 }
    }
}

/// Public AppleScript commands run through the same store and expansion engine as the UI.
@objc(ELBaseScriptCommand)
class ELBaseScriptCommand: NSScriptCommand {
    fileprivate func execute(_ action: @escaping (DesktopController) throws -> Any?) -> Any? {
        let operation: () -> Any? = {
            do {
                guard let controller = DesktopController.current else {
                    throw AutomationFailure.unavailable("La libreria non è ancora pronta. Riprova dopo l’avvio dell’app.")
                }
                return try action(controller)
            } catch {
                self.scriptErrorNumber = (error as? AutomationFailure)?.number ?? -2700
                self.scriptErrorString = error.localizedDescription
                return nil
            }
        }
        return Thread.isMainThread ? operation() : DispatchQueue.main.sync(execute: operation)
    }

    fileprivate func strings(single: Bool = false) throws -> [String] {
        let values: [String]
        if let value = directParameter as? String { values = [value] }
        else if !single, let list = directParameter as? [Any], list.allSatisfy({ $0 is String }) {
            values = list.map { $0 as! String }
        } else { throw AutomationFailure.invalid("È richiesto un testo\(single ? "" : " o una lista di testi").") }
        guard !values.isEmpty, values.count <= 1_000, values.allSatisfy({ !$0.isEmpty }) else {
            throw AutomationFailure.invalid("Fornisci da 1 a 1000 valori di testo non vuoti.")
        }
        return values
    }

    fileprivate func mutate(_ controller: DesktopController, _ action: () throws -> Any?) throws -> Any? {
        let snapshot = controller.store.data
        do {
            let result = try action()
            try controller.store.save()
            controller.engine.refreshHotkeys()
            return result
        } catch {
            controller.store.data = snapshot
            throw error
        }
    }
}

@objc(ELEnableCommand)
final class ELEnableCommand: ELBaseScriptCommand {
    override func performDefaultImplementation() -> Any? {
        execute { controller in
            try self.mutate(controller) {
                controller.store.data.paused = false
                return "Espansione abilitata. \(controller.engine.status)"
            }
        }
    }
}

@objc(ELDisableCommand)
final class ELDisableCommand: ELBaseScriptCommand {
    override func performDefaultImplementation() -> Any? {
        execute { controller in
            try self.mutate(controller) {
                controller.store.data.paused = true
                return "Espansione in pausa."
            }
        }
    }
}

@objc(ELExpandCommand)
final class ELExpandCommand: ELBaseScriptCommand {
    override func performDefaultImplementation() -> Any? {
        execute { controller in
            let value = try self.strings(single: true)[0]
            let candidates: [Snippet]
            if let id = UUID(uuidString: value), let exact = controller.store.data.snippets.first(where: { $0.id == id }) { candidates = [exact] }
            else { candidates = controller.store.data.snippets.filter { $0.matchesAbbreviation(value) } }
            guard let snippet = candidates.first else { throw AutomationFailure.missing("Frammento non trovato: \(value)") }
            guard candidates.count == 1 else { throw AutomationFailure.invalid("Abbreviazione ambigua. Specifica l’UUID del frammento.") }
            guard AXIsProcessTrusted() else { throw AutomationFailure.unavailable("Autorizza SuperSnippetto in Accessibilità prima di espandere un frammento.") }
            guard !IsSecureEventInputEnabled() else { throw AutomationFailure.unavailable("L’inserimento è disabilitato durante l’input protetto di macOS.") }
            let frontmost = NSWorkspace.shared.frontmostApplication
            let target = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier ? controller.engine.lastExternalApplication : frontmost
            guard let target, !target.isTerminated else { throw AutomationFailure.unavailable("Seleziona prima un campo di testo in un’altra app.") }
            guard controller.store.isEnabled(snippet, appID: target.bundleIdentifier ?? "") else {
                throw AutomationFailure.unavailable("Il frammento è in pausa, disabilitato o escluso per l’app di destinazione.")
            }
            controller.engine.expand(snippet)
            // Insertion, fill-in dialogs and scripts remain asynchronous and keep their normal UI errors.
            return "Richiesta di espansione: \(snippet.id.uuidString)"
        }
    }
}

@objc(ELImportCommand)
final class ELImportCommand: ELBaseScriptCommand {
    override func performDefaultImplementation() -> Any? {
        execute { controller in
            let paths = try self.strings()
            let urls = try paths.map { path -> URL in
                let expanded = (path as NSString).expandingTildeInPath
                guard expanded.hasPrefix("/") else { throw AutomationFailure.invalid("Il percorso deve essere assoluto: \(path)") }
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: expanded, isDirectory: &directory), !directory.boolValue else {
                    throw AutomationFailure.missing("File non trovato: \(path)")
                }
                return URL(fileURLWithPath: expanded)
            }
            return try self.mutate(controller) {
                let before = controller.store.data.snippets.count
                for url in urls { try controller.store.importFile(url) }
                return "Importati \(controller.store.data.snippets.count - before) frammenti da \(urls.count) file."
            }
        }
    }
}

@objc(ELDeleteCommand)
final class ELDeleteCommand: ELBaseScriptCommand {
    override func performDefaultImplementation() -> Any? {
        execute { controller in
            let rawIDs = try self.strings()
            let ids = try Set(rawIDs.map { value -> UUID in
                guard let id = UUID(uuidString: value) else { throw AutomationFailure.invalid("UUID non valido: \(value)") }
                return id
            })
            let existing = Set(controller.store.data.snippets.map(\.id))
            guard ids.isSubset(of: existing) else { throw AutomationFailure.missing("Uno o più UUID non appartengono ai frammenti attivi. Nessun elemento spostato.") }
            return try self.mutate(controller) {
                controller.store.moveToTrash(ids)
                return "Spostati nel cestino \(ids.count) frammenti."
            }
        }
    }
}

@objc(ELStatusCommand)
final class ELStatusCommand: ELBaseScriptCommand {
    override func performDefaultImplementation() -> Any? {
        execute { controller in
            "\(controller.store.data.paused ? "In pausa" : "Abilitato"); \(controller.engine.status); \(controller.store.data.snippets.count) frammenti."
        }
    }
}
