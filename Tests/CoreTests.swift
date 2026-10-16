import Foundation

@main
struct CoreTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do { guard try condition() else { fatalError("FAILED: \(message)") } }
        catch { fatalError("FAILED: \(message): \(error)") }
    }
    static func rejects(_ message: String, _ block: () throws -> Void) {
        do { try block(); fatalError("FAILED: expected error: \(message)") } catch { checks += 1 }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EspansoLocaleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(url: root.appendingPathComponent("library.json"))
        check(store.data == LibraryData(), "explicit test path starts empty")
        let parent = SnippetGroup(name: "Parent")
        let group = SnippetGroup(name: "Child", parentID: parent.id)
        let snippet = Snippet(title: "Firma, \"personale\"", abbreviation: ";sig", groupID: group.id, content: "Ciao, \"mondo\"\r\nSeconda riga\nTerza 👨‍👩‍👧‍👦", notes: "Prova\r\nCSV")
        store.data.groups = [parent, group]
        store.data.snippets = [snippet]
        check(store.match(in: ";sig", appID: "test")?.deleteCount == 4, "immediate matching")
        check(store.match(in: "ciao;sig", appID: "test") == nil, "word boundary")
        check(store.match(in: "à;sig", appID: "test") == nil, "Unicode boundary")
        check(store.match(in: "👨‍👩‍👧‍👦;sig", appID: "test") != nil, "emoji boundary")
        check(store.match(in: ";SIG", appID: "test") != nil, "case insensitive")
        store.data.snippets[0].caseSensitive = true
        check(store.match(in: ";SIG", appID: "test") == nil, "case sensitive")
        store.data.snippets[0].caseSensitive = false
        store.data.groups[0].enabled = false
        check(store.match(in: ";sig", appID: "test") == nil, "disabled ancestor")
        store.data.groups[0].enabled = true
        store.data.excludedApps = ["test"]
        check(store.match(in: ";sig", appID: "test") == nil, "excluded app")
        store.data.excludedApps = []
        store.data.snippets[0].appScope = .only
        store.data.snippets[0].apps = ["allowed"]
        check(store.match(in: ";sig", appID: "test") == nil, "only app")
        check(store.match(in: ";sig", appID: "allowed") != nil, "allowed app")
        store.data.snippets[0].appScope = .except
        check(store.match(in: ";sig", appID: "allowed") == nil, "except app")
        store.data.snippets[0].appScope = .all
        store.data.snippets[0].trigger = .delimiterKeep
        check(store.match(in: ";sig", appID: "test") == nil, "delimiter required")
        let matched = store.match(in: ";sig ", appID: "test")
        check(matched?.deleteCount == 5 && matched?.trailingDelimiter == " ", "delimiter keep")
        store.data.snippets[0].trigger = .delimiterDiscard
        check(store.match(in: ";sig ", appID: "test")?.trailingDelimiter == "", "delimiter discard")
        store.data.snippets[0].trigger = .manual
        check(store.match(in: ";sig", appID: "test") == nil, "manual does not auto match")
        check(store.match(in: ";sig", appID: "test", manual: true) != nil, "manual explicit match")
        store.data.paused = true
        check(store.match(in: ";sig", appID: "test", manual: true) == nil, "paused")
        store.data.paused = false
        store.data.snippets[0] = snippet
        store.data.snippets.append(Snippet(abbreviation: "sig", content: "short", wholeWord: false))
        check(store.match(in: ";sig", appID: "test")?.snippet.id == snippet.id, "longest suffix wins")
        store.data.snippets[0].abbreviation = "é👨‍👩‍👧‍👦"
        check(store.match(in: "é👨‍👩‍👧‍👦", appID: "test")?.deleteCount == 2, "grapheme deletion")
        store.data.snippets = [snippet]
        try store.save()
        check(LibraryStore(url: store.fileURL).data == store.data, "JSON persisted roundtrip")
        let exported = root.appendingPathComponent("export.json")
        try store.exportFile(exported)
        let imported = LibraryStore(url: root.appendingPathComponent("other.json"))
        try imported.importFile(exported)
        check(imported.data.snippets == store.data.snippets && imported.data.groups == store.data.groups, "JSON import")
        try imported.importFile(exported)
        check(imported.data.snippets.count == 1 && imported.data.groups.count == 2, "idempotent identical import")
        imported.data.snippets[0].content = "existing edit"
        try imported.importFile(exported)
        check(imported.data.snippets.count == 2 && imported.data.snippets.contains(where: { $0.content == "existing edit" }), "UUID conflict retains existing edits")
        let csv = root.appendingPathComponent("export.csv")
        try store.exportFile(csv)
        let csvStore = LibraryStore(url: root.appendingPathComponent("csv.json"))
        try csvStore.importFile(csv)
        check(csvStore.data.snippets == store.data.snippets && csvStore.data.groups == store.data.groups, "CSV exact newline and quoting roundtrip")
        let before = imported.data
        try "abbreviation,content\nfoo,\"broken".write(to: csv, atomically: true, encoding: .utf8)
        rejects("unclosed CSV") { try imported.importFile(csv) }
        check(imported.data == before, "failed import is atomic")
        try "abbreviation,content\nfoo,bar,excess\n".write(to: csv, atomically: true, encoding: .utf8)
        rejects("bad CSV row") { try imported.importFile(csv) }
        try "{broken".write(to: exported, atomically: true, encoding: .utf8)
        rejects("invalid JSON") { try imported.importFile(exported) }
        try "{corrupt".write(to: store.fileURL, atomically: true, encoding: .utf8)
        let corrupt = LibraryStore(url: store.fileURL)
        check(corrupt.lastError != nil, "load corruption visible")
        rejects("corrupt file is never overwritten") { try corrupt.save() }
        let unchanged = try String(contentsOf: store.fileURL, encoding: .utf8)
        check(unchanged == "{corrupt", "original corrupt data preserved")
        let plist = root.appendingPathComponent("sample.textexpander")
        let object: [String: Any] = ["name": "Sample", "snippetsTE": [["abbreviation": "abc", "plainText": "Imported", "label": "Example", "snippetType": 0]]]
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: plist)
        try imported.importFile(plist)
        check(imported.data.snippets.contains(where: { $0.abbreviation == "abc" && $0.content == "Imported" }), "TextExpander text plist")
        let renderer = TemplateRenderer()
        var context = RenderContext(date: Date(timeIntervalSince1970: 0), clipboard: "{{uuid}}", selection: "Selected", variables: ["Nome": "Ada"])
        let rendered = try renderer.render("Ciao {{field:Nome}} 👩🏽‍💻{{cursor}}! {{selection}} {{clipboard}} {{calc:(1+2)*3}} {{upper:ciao}}", context: context)
        check(rendered.text == "Ciao Ada 👩🏽‍💻! Selected {{uuid}} 9 CIAO", "render tokens, clipboard is literal")
        check(rendered.cursorOffset == "Ciao Ada 👩🏽‍💻".count, "cursor grapheme offset")
        let fields = try renderer.render("{{field:A}} {{field:B}} {{field:A}}", context: context)
        check(fields.fields == ["A", "B"], "missing fields deduplicated in order")
        check(fields.text.contains("{{field:A}}"), "missing field stays recognizable")
        context.lookup = { $0 == "nested" ? "{{upper:{{field:Nome}}}}" : nil }
        check(try renderer.render("{{snippet:nested}}", context: context).text == "ADA", "nested tokens")
        context.lookup = { _ in "{{snippet:cycle}}" }
        rejects("recursive snippet") { _ = try renderer.render("{{snippet:cycle}}", context: context) }
        rejects("unclosed template") { _ = try renderer.render("{{clipboard", context: context) }
        rejects("calc divide zero") { _ = try renderer.render("{{calc:1/0}}", context: context) }
        rejects("calc never executes code") { _ = try renderer.render("{{calc:system(1)}}", context: context) }
        rejects("calc adjacent numbers") { _ = try renderer.render("{{calc:1 2}}", context: context) }
        check(try renderer.render("{{calc: 2 * ( 3 + 1 ) }}", context: context).text == "8", "arithmetic whitespace")
        check(try renderer.render("{{calc:-2+5/2}}", context: context).text == "0.5", "safe arithmetic precedence")
        check(try renderer.render("{{unknown:value}}", context: context).text == "{{unknown:value}}", "unknown token preserved")
        check(try renderer.render("{{uuid}}", context: context).text.count == 36, "UUID generation")
        try persistenceChecks(root: root)
        try aliasChecks(root: root)
        try importWarningChecks(root: root)
        try searchHotkeyChecks(root: root)
        print("CoreTests: \(checks) checks passed")
    }

    static func searchHotkeyChecks(root: URL) throws {
        let store = LibraryStore(url: root.appendingPathComponent("hotkey/library.json"))
        check(store.data.effectiveSearchHotkey == .standard, "existing library uses standard search shortcut")
        check(SearchHotkey.standard.isValid, "standard search shortcut is valid")
        let custom = SearchHotkey(keyCode: 1, modifiers: 4352) // Control + Command + S
        check(custom.isValid, "custom search shortcut is valid")
        check(!SearchHotkey(keyCode: 1, modifiers: 0).isValid, "plain keys cannot become a global shortcut")
        check(!SearchHotkey(keyCode: 1, modifiers: 512).isValid, "shift alone cannot become a global shortcut")
        check(!SearchHotkey(keyCode: 53, modifiers: 256).isValid, "escape stays available to cancel recording")
        check(!SearchHotkey(keyCode: 128, modifiers: 256).isValid, "invalid key code rejected")
        check(!SearchHotkey(keyCode: 1, modifiers: 257).isValid, "unknown modifier bits rejected")
        store.data.searchHotkey = custom
        try store.save()
        check(LibraryStore(url: store.fileURL).data.effectiveSearchHotkey == custom, "custom shortcut survives restart")
        store.data.snippets = [Snippet(hotkeyCode: custom.keyCode, hotkeyModifiers: custom.modifiers)]
        check(store.data.searchHotkeyConflict(custom), "snippet shortcut collision detected")
        store.data.snippets[0].enabled = false
        check(store.data.searchHotkeyConflict(custom), "disabled snippet still reserves its shortcut")
        check(!store.data.searchHotkeyConflict(.standard), "former search shortcut becomes available")
        store.data.searchHotkey = SearchHotkey(keyCode: -1, modifiers: 0)
        rejects("invalid shortcut is never saved") { try store.save() }
        check(LibraryStore(url: store.fileURL).data.effectiveSearchHotkey == custom, "rejected save preserves previous shortcut")
        store.data.searchHotkey = nil; store.data.snippets = []
        try store.save()
        check(LibraryStore(url: store.fileURL).data.effectiveSearchHotkey == .standard, "library without new preference decodes with original default")
    }

    static func persistenceChecks(root: URL) throws {
        let location = root.appendingPathComponent("persistence/library.json")
        let store = LibraryStore(url: location)
        let original = Snippet(title: "Original", abbreviation: ";backup", content: "Saved version")
        store.data.snippets = [original]
        check(store.effectiveBackupIntervalMinutes == 1440 && store.effectiveBackupRetention == 100, "backward-compatible backup defaults")
        try store.save()
        check(try store.backups().isEmpty, "first save has no previous version to back up")
        store.data.snippets[0].content = "Second version"
        try store.save()
        let automatic = try store.backups()
        check(automatic.count == 1, "overwrite snapshots previous valid file")
        let old = LibraryStore(url: automatic[0])
        check(old.data.snippets == [original], "automatic snapshot contains previous disk version")
        store.data.snippets[0].content = "Third version"
        try store.save()
        check(try store.backups().count == 1, "automatic snapshots obey interval")
        store.data.snippets[0].content = "Unflushed edits"
        let explicit = try store.createBackup()
        check(LibraryStore(url: explicit).data == store.data, "explicit snapshot includes unflushed in-memory changes")
        let unflushed = store.data
        try store.restoreBackup(automatic[0])
        check(store.data.snippets == [original] && LibraryStore(url: location).data == store.data, "restore commits disk and memory together")
        check(try store.backups().contains(where: { LibraryStore(url: $0).data == unflushed }), "restore snapshots current memory before replacement")
        let bad = root.appendingPathComponent("bad-backup.json")
        try "not json".write(to: bad, atomically: true, encoding: .utf8)
        let diskBefore = try Data(contentsOf: location)
        let dataBefore = store.data
        let countBefore = try store.backups().count
        rejects("malformed backup") { try store.restoreBackup(bad) }
        let diskAfter = try Data(contentsOf: location)
        check(store.data == dataBefore && diskAfter == diskBefore, "malformed restore changes neither memory nor file")
        check(try store.backups().count == countBefore, "malformed restore creates no extra snapshot")

        store.data.backupRetention = 3
        for _ in 0..<5 { _ = try store.createBackup() }
        let retained = try store.backups()
        check(retained.count == 3, "snapshot retention prunes oldest copies")
        store.data.backupIntervalMinutes = 1
        try store.save()
        for url in try store.backups() {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -61)], ofItemAtPath: url.path)
        }
        store.data.snippets[0].content = "Interval version"
        try store.save()
        check(try store.backups().contains(where: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSinceNow ?? -100) > -10 }), "configured interval permits next automatic snapshot")

        let oldJSON = root.appendingPathComponent("old-version.json")
        var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: location)) as! [String: Any]
        var oldData = envelope["data"] as! [String: Any]
        for key in ["trash", "backupIntervalMinutes", "backupRetention", "backupFolder"] { oldData.removeValue(forKey: key) }
        envelope["data"] = oldData
        try JSONSerialization.data(withJSONObject: envelope).write(to: oldJSON)
        let oldLibrary = LibraryStore(url: oldJSON)
        check(oldLibrary.lastError == nil && oldLibrary.data.trash == nil && oldLibrary.effectiveBackupRetention == 100, "0.1 JSON without new keys loads")

        let group = SnippetGroup(name: "Deleted group")
        store.data.groups = [group]
        store.data.snippets[0].groupID = group.id
        let removed = store.data.snippets[0]
        store.moveToTrash([removed.id])
        check(store.data.snippets.isEmpty && store.data.trash?.first?.snippet == removed, "move to recoverable trash")
        store.data.groups = []
        var conflict = removed
        conflict.groupID = nil; conflict.content = "Existing conflicting ID"
        store.data.snippets.append(conflict)
        store.restoreFromTrash([removed.id])
        check(store.data.snippets.count == 2 && Set(store.data.snippets.map(\.id)).count == 2, "trash restore preserves both conflicting IDs")
        check(store.data.snippets.allSatisfy({ $0.groupID == nil }) && store.data.trash?.isEmpty == true, "missing trash group detaches safely")
        store.moveToTrash(Set(store.data.snippets.map(\.id)))
        let withTrash = store.data
        let export = root.appendingPathComponent("trash.json")
        try store.exportFile(export)
        check(LibraryStore(url: export).data == withTrash, "JSON exports complete trash")
        let csv = root.appendingPathComponent("trash.csv")
        try store.exportFile(csv)
        check(try String(contentsOf: csv, encoding: .utf8).split(separator: "\n").count == 1, "CSV exports active snippets only")
        let imported = LibraryStore(url: root.appendingPathComponent("trash-import/library.json"))
        try imported.importFile(export)
        check(imported.data.trash == withTrash.trash, "JSON import retains trash")
        store.emptyTrash()
        check(store.data.trash?.isEmpty == true, "explicitly empty trash")

        let recoveryPath = root.appendingPathComponent("recovery/library.json")
        let recoverable = LibraryStore(url: recoveryPath)
        recoverable.data.snippets = [original]
        recoverable.data.backupFolder = root.appendingPathComponent("custom-backups").path
        try recoverable.save()
        let recoverySnapshot = try recoverable.createBackup()
        try "{broken-original".write(to: recoveryPath, atomically: true, encoding: .utf8)
        let recovered = LibraryStore(url: recoveryPath)
        check(recovered.data == recoverable.data && recovered.lastError?.contains("recuperata") == true, "corrupt library recovers latest valid custom-folder backup")
        let preserved = try FileManager.default.contentsOfDirectory(at: recoveryPath.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.pathExtension == "corrupt" }
        check(preserved.count == 1, "recovery preserves original corrupt file")
        check(try String(contentsOf: preserved[0], encoding: .utf8) == "{broken-original", "recovery preserves exact original corrupt bytes")
        try recovered.save()
        check(LibraryStore(url: recoveryPath).data == recoverable.data, "autosave resumes after recovery")
        check(FileManager.default.fileExists(atPath: recoverySnapshot.path), "source snapshot remains recoverable")
        var invalid = recovered.data
        invalid.snippets[0].hotkeyCode = 128
        recovered.data = invalid
        let invariantFile = try Data(contentsOf: recoveryPath)
        rejects("hotkey out of range") { try recovered.save() }
        check(try Data(contentsOf: recoveryPath) == invariantFile, "invalid save preserves existing file")
        recovered.data = recoverable.data
        recovered.data.backupIntervalMinutes = 0
        rejects("invalid backup interval") { try recovered.save() }
    }

    static func aliasChecks(root: URL) throws {
        let store = LibraryStore(url: root.appendingPathComponent("aliases/library.json"))
        let group = SnippetGroup(name: "Source group", atextSourceJSON: "{\"original\":\"group\"}")
        var snippet = Snippet(title: "Multiple triggers", abbreviation: ";main", groupID: group.id, content: "Alias text", aliases: [";extra", "é👩🏽‍💻", ";main", "", ";extra"], atextSourceJSON: "{\"unknownFeature\":42}")
        store.data.groups = [group]; store.data.snippets = [snippet]
        check(snippet.allAbbreviations == [";main", ";extra", "é👩🏽‍💻"], "alias list excludes empty and duplicate abbreviations")
        check(snippet.matchesAbbreviation(";extra") && snippet.matchesAbbreviation(";main") && !snippet.matchesAbbreviation(""), "lookup helper recognizes primary and aliases")
        check(store.match(in: ";extra", appID: "test")?.snippet.id == snippet.id, "alias expands same snippet")
        check(store.match(in: ";EXTRA", appID: "test")?.typedAbbreviation == ";EXTRA", "alias respects insensitive case and preserves typed text")
        check(store.match(in: "word;extra", appID: "test") == nil, "alias respects word boundary")
        check(store.match(in: "é👩🏽‍💻", appID: "test")?.deleteCount == 2, "alias deletion counts graphemes")
        store.data.snippets[0].caseSensitive = true
        check(store.match(in: ";EXTRA", appID: "test") == nil, "alias respects case sensitivity")
        store.data.snippets[0].caseSensitive = false
        store.data.snippets[0].trigger = .delimiterKeep
        check(store.match(in: ";extra ", appID: "test")?.deleteCount == 7 && store.match(in: ";extra ", appID: "test")?.trailingDelimiter == " ", "alias delimiter deletion and preservation")
        store.data.snippets[0].trigger = .manual
        check(store.match(in: ";extra", appID: "test") == nil && store.match(in: ";extra", appID: "test", manual: true) != nil, "alias manual trigger")
        store.data.snippets[0] = snippet
        store.data.snippets.insert(Snippet(abbreviation: "extra", content: "Shorter", wholeWord: false), at: 0)
        check(store.match(in: ";extra", appID: "test")?.snippet.id == snippet.id, "longest alias wins across all snippets")
        store.data.snippets = [snippet]
        store.data.snippets[0].abbreviation = ""
        check(store.match(in: ";extra", appID: "test") != nil, "aliases work when primary abbreviation is empty")
        store.data.snippets[0] = snippet
        store.data.groups[0].enabled = false
        check(store.match(in: ";extra", appID: "test") == nil, "alias respects disabled group")
        store.data.groups[0].enabled = true
        let renderer = TemplateRenderer()
        let context = RenderContext(lookup: { key in store.data.snippets.first { $0.matchesAbbreviation(key) }?.content })
        check(try renderer.render("{{snippet:;extra}}", context: context).text == "Alias text", "nested template resolves alias through shared lookup")
        let json = root.appendingPathComponent("aliases-export.json")
        let csv = root.appendingPathComponent("aliases-export.csv")
        try store.exportFile(json); try store.exportFile(csv)
        check(LibraryStore(url: json).data == store.data, "JSON preserves aliases and original source metadata")
        let csvImport = LibraryStore(url: root.appendingPathComponent("aliases-csv/library.json"))
        try csvImport.importFile(csv)
        check(csvImport.data == store.data, "CSV preserves aliases and original source metadata")
        let oldSnippet = Snippet(abbreviation: "legacy", content: "No extra fields")
        let oldBytes = try JSONEncoder().encode(oldSnippet)
        let oldDecoded = try JSONDecoder().decode(Snippet.self, from: oldBytes)
        check(oldDecoded.aliases == nil && oldDecoded.atextSourceJSON == nil, "legacy snippet decodes without optional metadata")
        let bad = root.appendingPathComponent("invalid.atext")
        try "invalid archive".write(to: bad, atomically: true, encoding: .utf8)
        let warnings = store.lastImportWarnings, before = store.data
        rejects("invalid atext is atomic") { try store.importFile(bad) }
        check(store.data == before && store.lastImportWarnings == warnings, "failed import preserves data and previous warnings")

        let dependency = Snippet(title: "Dependency", abbreviation: ";dep", content: "Imported dependency")
        let originalToken = "{{snippet:\(dependency.id.uuidString.lowercased())}}"
        let referencing = Snippet(title: "Parent", abbreviation: ";parent", content: originalToken, atextSourceJSON: originalToken)
        let source = LibraryStore(url: root.appendingPathComponent("reference-source/library.json"))
        source.data.snippets = [dependency, referencing]
        let removedReference = Snippet(title: "Trashed parent", content: originalToken)
        source.data.trash = [TrashedSnippet(snippet: removedReference)]
        let sourceFile = root.appendingPathComponent("reference-source.json")
        try source.exportFile(sourceFile)
        let destination = LibraryStore(url: root.appendingPathComponent("reference-target/library.json"))
        var conflicting = dependency; conflicting.content = "Existing edit"
        destination.data.snippets = [conflicting, referencing]
        try destination.importFile(sourceFile)
        let importedDependency = destination.data.snippets.first { $0.content == "Imported dependency" }!
        let importedParent = destination.data.snippets.first { $0.id != referencing.id && $0.title == "Parent" }!
        check(importedDependency.id != dependency.id && destination.data.snippets.contains(conflicting), "UUID collision preserves existing dependency and imports new ID")
        check(importedParent.content == "{{snippet:\(importedDependency.id.uuidString)}}", "nested UUID references remap case-insensitively to imported dependency")
        check(importedParent.atextSourceJSON == originalToken, "reference remapping leaves original metadata unchanged")
        check(destination.data.snippets.contains(referencing), "dependency remap clones parent without overwriting existing parent")
        check(destination.data.trash?.first?.snippet.content == importedParent.content, "trashed UUID references follow imported dependency")
        snippet.aliases = Array(repeating: "x", count: 10_001)
        store.data.snippets = [snippet]
        rejects("alias count limit") { try store.exportFile(json) }
    }

    static func importWarningChecks(root: URL) throws {
        // Tiny original fixture: a valid uncompressed LZ4 frame around one plain record.
        let groupID = UUID(), snippetID = UUID()
        let records: [[String: Any]] = [["0": groupID.uuidString, "99": 1, "2": "Original test group", "13": [["0": snippetID.uuidString, "99": 0, "1": [";one", ";two"], "3": "t", "4": "Original test text"]]]]
        let payload = try JSONSerialization.data(withJSONObject: records)
        let descriptor = Data([0x60, 0x40])
        var frame = Data([0x04, 0x22, 0x4d, 0x18]); frame.append(descriptor)
        frame.append(UInt8((LZ4FrameCodec.xxHash32(descriptor) >> 8) & 255))
        let block = UInt32(payload.count) | 0x8000_0000
        for shift in stride(from: 0, through: 24, by: 8) { frame.append(UInt8((block >> shift) & 255)) }
        frame.append(payload); frame.append(Data(repeating: 0, count: 4))
        var archive = try JSONSerialization.data(withJSONObject: ["0": "00000000-0000-0000-0000-000000000000", "1": true])
        archive.append(0); archive.append(frame)
        let url = root.appendingPathComponent("warning-fixture.atext")
        try archive.write(to: url)
        let store = LibraryStore(url: root.appendingPathComponent("import-warnings/library.json"))
        try store.importFile(url)
        check(store.data.snippets.first?.aliases == [";two"], "atext imports additional abbreviations as aliases")
        check(!store.lastImportWarnings.isEmpty && store.data.snippets.first?.trigger == .manual, "successful atext import exposes conversion warnings")
        let before = store.data, warnings = store.lastImportWarnings
        try "malformed".write(to: url, atomically: true, encoding: .utf8)
        rejects("failed atext retains prior conversion warnings") { try store.importFile(url) }
        check(store.data == before && store.lastImportWarnings == warnings, "failed atext leaves data and populated warnings unchanged")
        let json = root.appendingPathComponent("warnings-roundtrip.json")
        try store.exportFile(json)
        check(!String(data: try Data(contentsOf: json), encoding: .utf8)!.contains("lastImportWarnings"), "warnings are transient and never persisted")
        try store.importFile(json)
        check(store.lastImportWarnings.isEmpty, "successful non-atext import clears conversion warnings")
    }
}
