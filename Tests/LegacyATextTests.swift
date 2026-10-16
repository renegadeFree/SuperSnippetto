import Foundation

@main
struct LegacyATextTests {
    static var checks = 0
    static let groupID = "4DC1DD5A-C972-4B8D-A822-24393A23E6FA"
    static let snippetID = "2EE72CCE-5347-4248-9F44-5D35F28755C2"
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do { if try !condition() { fatalError(message) } } catch { fatalError("\(message): \(error)") }
    }
    static func rejects(_ action: () throws -> Void) {
        checks += 1
        do { try action(); fatalError("Expected rejection") } catch {}
    }
    static func uid(_ value: Int) -> [String: Int] { ["CF$UID": value] }
    // Entirely synthetic keyed archive. XML-to-binary creates genuine UID leaves
    // through public property-list APIs, without encoding/decoding custom classes.
    static func archive(group: [String: Any] = [:], snippet: [String: Any] = [:], edit: ((inout [Any]) -> Void)? = nil) throws -> Data {
        var objects: [Any] = [
            "$null", // 0
            ["$class": uid(4), "NS.keys": [uid(2)], "NS.objects": [uid(3)]],
            "Snippets",
            ["$class": uid(6), "NS.objects": [uid(5)]],
            ["$classname": "NSDictionary", "$classes": ["NSDictionary", "NSObject"]],
            ["$class": uid(7), "UUID": uid(9), "Name": uid(8), "Items": uid(10), "DateCreated": uid(18),
             "CaseSensitivity": 0, "ExpandAfter": 0, "ExpandTrigger": 0, "EnabledIn": 0,
             "InputMethodsOption": 0, "ResetFormatting": false, "ShowInMenuBar": true,
             "ShowInMenuBarAtFirstLevel": false, "SuggestAbbreviations": true].merging(group) { _, new in new },
            ["$classname": "NSArray", "$classes": ["NSArray", "NSObject"]],
            ["$classname": "SnippetGroup", "$classes": ["SnippetGroup", "NSObject"]],
            "Synthetic group", groupID,
            ["$class": uid(6), "NS.objects": [uid(11)]],
            ["$class": uid(12), "UUID": uid(16), "Abbreviation": uid(14), "Aliases": uid(0),
             "Label": uid(15), "Note": uid(0), "Content": uid(13), "ContentType": 0,
             "CaseSensitivity": 0, "DateCreated": uid(18), "DateModified": uid(18), "12": 0].merging(snippet) { _, new in new },
            ["$classname": "Snippet", "$classes": ["Snippet", "NSObject"]],
            "Ciao🙂 【date:full locale:it】", ";legacy", "Synthetic snippet", snippetID,
            ["$classname": "NSDate", "$classes": ["NSDate", "NSObject"]],
            ["$class": uid(17), "NS.time": 0.0],
            "untranslated alias"
        ]
        edit?(&objects)
        let root: [String: Any] = ["$archiver": "NSKeyedArchiver", "$version": 100_000, "$top": ["root": uid(1)], "$objects": objects]
        let xml = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        let withUIDs = try PropertyListSerialization.propertyList(from: xml, options: [], format: nil)
        return try PropertyListSerialization.data(fromPropertyList: withUIDs, format: .binary, options: 0)
    }
    static func numericJSON(_ availability: Any = ["0": 0]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [["0": groupID, "2": "Synthetic group", "15": availability,
            "13": [["0": snippetID, "1": [";legacy"], "3": "t", "4": "Ciao🙂 <atext format=\"full\" locale=\"it\" type=\"date\">date</atext>", "10": "Synthetic snippet"]]]])
    }
    static func main() throws {
        let bytes = try archive()
        let result = try ATextImporter.decode(bytes)
        let item = result.library.snippets[0]
        let plist = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        check(try ATextImporter.decode(xml).library == result.library, "XML and binary keyed archives agree")
        check(bytes.starts(with: Data("bplist00".utf8)), "Synthetic binary plist fixture")
        check(result.library.groups.count == 1 && result.library.snippets.count == 1, "Legacy hierarchy")
        check(item.id == UUID(uuidString: snippetID) && item.groupID == UUID(uuidString: groupID), "Original IDs preserved")
        check(item.title == "Synthetic snippet" && item.abbreviation == ";legacy", "Original names and abbreviation")
        check(item.enabled && result.library.groups[0].enabled && item.trigger == .manual, "Defaults stay enabled with manual trigger")
        check(item.notes.isEmpty && result.warnings.count == 1, "Null notes and aliases handled")
        check(item.content.hasPrefix("Ciao🙂 {{date:") && !item.content.contains("【"), "Legacy date converted")
        let source = try JSONSerialization.jsonObject(with: Data(item.atextSourceJSON!.utf8)) as! [String: Any]
        check(source["Content"] as? String == "Ciao🙂 【date:full locale:it】", "Original macro source retained")
        check(source["Aliases"] is NSNull && source["DateCreated"] is [String: Any], "Null and date metadata retained")
        let groupSource = try JSONSerialization.jsonObject(with: Data(result.library.groups[0].atextSourceJSON!.utf8)) as! [String: Any]
        check(groupSource["Items"] == nil && groupSource["Name"] as? String == "Synthetic group", "No recursive source amplification")
        let numeric = try ATextImporter.decodeJSON(numericJSON())
        check(numeric.library.snippets[0].content == item.content, "Numeric JSON and keyed archive agree")
        check(numeric.library.snippets[0].enabled && numeric.library.groups[0].enabled, "Numeric all-applications default supported")
        for availability in [["0": 1], ["0": false], ["0": 0, "apps": ["example.app"]], [:]] as [[String: Any]] {
            let restricted = try ATextImporter.decodeJSON(numericJSON(availability))
            check(!restricted.library.groups[0].enabled && !restricted.library.snippets[0].enabled, "Unknown availability never widens scope")
        }
        for changes in [["EnabledIn": 1], ["ResetFormatting": true], ["FutureRule": "value"]] as [[String: Any]] {
            let restricted = try ATextImporter.decode(archive(group: changes))
            check(!restricted.library.groups[0].enabled && !restricted.library.snippets[0].enabled, "Legacy group rules stay blocked")
        }
        for changes in [["Aliases": uid(19)], ["ContentType": 1], ["CaseSensitivity": 1], ["FutureRule": true]] as [[String: Any]] {
            let restricted = try ATextImporter.decode(archive(snippet: changes))
            check(!restricted.library.snippets[0].enabled && restricted.library.snippets[0].atextSourceJSON != nil, "Unsupported legacy values retained and disabled")
        }
        let empty = try ATextImporter.decode(archive(snippet: ["Content": uid(0)]))
        check(empty.library.snippets[0].content.isEmpty, "Null content is empty")
        let unknownMacro = try ATextImporter.decode(archive(edit: { $0[13] = "before 【future:value】 after" }))
        check(!unknownMacro.library.snippets[0].enabled && unknownMacro.library.snippets[0].content.contains("【future:value】"), "Unknown legacy macro retained and disabled")
        let injection = try ATextImporter.decode(archive(edit: { $0[13] = "{{clipboard}}" }))
        check(!injection.library.snippets[0].enabled, "Literal native syntax never silently becomes active")
        rejects { _ = try ATextImporter.decode(archive(group: ["UUID": uid(16)])) }
        rejects { _ = try ATextImporter.decode(archive(snippet: ["Content": uid(999)])) }
        rejects { _ = try ATextImporter.decode(archive(edit: { $0[10] = ["$class": uid(6), "NS.objects": [uid(5)]] })) }
        rejects { _ = try ATextImporter.decode(archive(edit: { $0[10] = ["$class": uid(6), "NS.objects": [uid(11), uid(11)]] })) }
        rejects { _ = try ATextImporter.decode(archive(edit: { $0[12] = ["$classname": "UntrustedCustomClass"] })) }
        rejects { _ = try ATextImporter.decode(archive(edit: { $0[4] = ["not-a-class": "x"] })) }
        rejects { _ = try ATextImporter.decode(archive(edit: { $0[1] = ["$class": uid(4), "NS.keys": [uid(2), uid(2)], "NS.objects": [uid(3), uid(3)]] })) }
        rejects { _ = try ATextImporter.decode(archive(edit: { $0[1] = ["$class": uid(4), "NS.keys": [uid(2)], "NS.objects": []] })) }
        rejects { _ = try ATextImporter.decode(archive(edit: { $0[1] = "not a library" })) }
        rejects { _ = try ATextImporter.decode(Data("bplist00broken".utf8)) }
        rejects { _ = try ATextImporter.decodeJSON(Data("{}".utf8)) }

        let date = ISO8601DateFormatter().date(from: "2026-03-07T12:04:05Z")!
        for (name, style) in [("full", DateFormatter.Style.full), ("long", .long), ("medium", .medium), ("short", .short)] {
            for type in ["date", "time"] {
                let converted = ATextMacroConverter.convertLegacy("【\(type):\(name) locale:it 】")
                let template = ATextMacroConverter.convert(converted.text)
                let f = DateFormatter(); f.locale = Locale(identifier: "it")
                if type == "date" { f.dateStyle = style } else { f.timeStyle = style }
                check(converted.warnings.isEmpty && template.warnings.isEmpty, "Named legacy style supported")
                check(try TemplateRenderer().render(template.text, context: RenderContext(date: date)).text == f.string(from: date), "Legacy style renders expected localized date/time")
            }
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSnippetto-legacy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (name, data) in [("old.atext", bytes), ("aTextData.json", try numericJSON())] {
            let url = temporary.appendingPathComponent(name); try data.write(to: url)
            let store = LibraryStore(url: temporary.appendingPathComponent(name + "-library.json"))
            try store.importFile(url); let first = store.data
            try store.importFile(url)
            check(store.data == first, "Reimport same file is idempotent")
            try store.save()
            check(LibraryStore(url: store.fileURL).data == first, "Save and reopen retain conversion")
            try Data("broken".utf8).write(to: url)
            rejects { try store.importFile(url) }
            check(store.data == first, "Malformed source leaves existing data unchanged")
        }
        print("LegacyATextTests: \(checks) checks passed")
    }
}
