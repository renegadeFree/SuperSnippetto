import AppKit

@main
private enum AutomationChecks {
    static func description(_ name: String, _ className: String, _ code: String) -> NSScriptCommandDescription {
        NSScriptCommandDescription(suiteName: "Espanso Locale", commandName: name, dictionary: ["CommandClass": className, "AppleEventClassCode": "ELcl", "AppleEventCode": code, "Type": "NSString", "ResultAppleEventCode": "TEXT"])!
    }
    static func main() throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool) { precondition(condition()); passed += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EspansoAutomation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let notReady = ELStatusCommand(commandDescription: description("status", "ELStatusCommand", "Stat"))
        check(notReady.performDefaultImplementation() == nil)
        check(notReady.scriptErrorNumber == -2700)
        let store = LibraryStore(url: folder.appendingPathComponent("library.json"))
        let engine = ExpansionEngine(store: store)
        let controller = DesktopController(store: store, engine: engine)
        withExtendedLifetime(controller) {
            let disable = ELDisableCommand(commandDescription: description("disable", "ELDisableCommand", "Dsbl"))
            check(disable.performDefaultImplementation() is String)
            check(store.data.paused && disable.scriptErrorNumber == 0)
            let enable = ELEnableCommand(commandDescription: description("enable", "ELEnableCommand", "Enbl"))
            check(enable.performDefaultImplementation() is String)
            check(!store.data.paused && enable.scriptErrorNumber == 0)
            let status = ELStatusCommand(commandDescription: description("status", "ELStatusCommand", "Stat"))
            check((status.performDefaultImplementation() as? String)?.contains("0 frammenti") == true)
        }
        var snippet = Snippet(); snippet.title = "Importato"; snippet.abbreviation = ";demo"; snippet.content = "test"
        let source = LibraryStore(url: folder.appendingPathComponent("source.json"))
        source.data.snippets = [snippet]
        try source.exportFile(folder.appendingPathComponent("valid.json"))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("invalid.json"))
        let before = store.data
        let diskBefore = try Data(contentsOf: store.fileURL)
        let failedImport = ELImportCommand(commandDescription: description("import", "ELImportCommand", "Impt"))
        failedImport.directParameter = [folder.appendingPathComponent("valid.json").path, folder.appendingPathComponent("invalid.json").path]
        check(failedImport.performDefaultImplementation() == nil)
        check(failedImport.scriptErrorNumber != 0)
        check(store.data == before)
        let diskAfter = try Data(contentsOf: store.fileURL)
        check(diskAfter == diskBefore)
        let validImport = ELImportCommand(commandDescription: description("import", "ELImportCommand", "Impt"))
        validImport.directParameter = folder.appendingPathComponent("valid.json").path
        check(validImport.performDefaultImplementation() is String)
        check(store.data.snippets.count == 1)
        let invalidDelete = ELDeleteCommand(commandDescription: description("delete", "ELDeleteCommand", "Delt"))
        invalidDelete.directParameter = [snippet.id.uuidString, "not-a-uuid"]
        check(invalidDelete.performDefaultImplementation() == nil)
        check(invalidDelete.scriptErrorNumber == -1700 && store.data.snippets.count == 1)
        let missingDelete = ELDeleteCommand(commandDescription: description("delete", "ELDeleteCommand", "Delt"))
        missingDelete.directParameter = [snippet.id.uuidString, UUID().uuidString]
        check(missingDelete.performDefaultImplementation() == nil)
        check(missingDelete.scriptErrorNumber == -1728 && store.data.snippets.count == 1)
        let validDelete = ELDeleteCommand(commandDescription: description("delete", "ELDeleteCommand", "Delt"))
        validDelete.directParameter = [snippet.id.uuidString, snippet.id.uuidString]
        check(validDelete.performDefaultImplementation() is String)
        check(store.data.snippets.isEmpty && store.data.trash?.count == 1)
        let invalidImport = ELImportCommand(commandDescription: description("import", "ELImportCommand", "Impt"))
        invalidImport.directParameter = [123, "file"]
        check(invalidImport.performDefaultImplementation() == nil)
        check(invalidImport.scriptErrorNumber == -1700)
        let blocker = folder.appendingPathComponent("not-a-folder")
        try Data().write(to: blocker)
        let badStore = LibraryStore(url: blocker.appendingPathComponent("library.json")); badStore.data.paused = true
        let badController = DesktopController(store: badStore, engine: ExpansionEngine(store: badStore))
        withExtendedLifetime(badController) {
            let failSave = ELEnableCommand(commandDescription: description("enable", "ELEnableCommand", "Enbl"))
            check(failSave.performDefaultImplementation() == nil)
            check(failSave.scriptErrorNumber != 0 && badStore.data.paused)
        }
        print("Automation: \(passed) in-process checks passed; no AppleEvents or keyboard automation sent")
    }
}
