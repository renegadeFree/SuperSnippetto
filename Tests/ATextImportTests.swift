import Foundation

@main
struct ATextImportTests {
    static var checks = 0
    static let groupID = "9BDB07B9-0E15-4272-8FBC-2379980EFC55"
    static let childID = "A5962357-EA8D-44D6-A704-A18B8EA0D245"
    static let snippetID = "D8EAB07D-F504-4B29-A8F5-E32D2190E4B3"
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do { guard try condition() else { fatalError("FAILED: \(message)") } }
        catch { fatalError("FAILED: \(message): \(error)") }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError("FAILED: accepted \(message)") }
        catch { checks += 1 }
    }
    static func word(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    /// Synthetic fixture: public standard raw LZ4 frame, known descriptor checksum.
    static func archive(_ root: Any, header: [String: Any] = ["0": "00000000-0000-0000-0000-000000000000", "1": true]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        var frame = Data([4, 0x22, 0x4D, 0x18, 0x60, 0x40, 0x82])
        for index in stride(from: 0, to: json.count, by: 65_536) {
            let part = json[index..<min(index + 65_536, json.count)]
            frame.append(word(UInt32(part.count) | 0x80000000)); frame.append(part)
        }
        frame.append(word(0))
        return Data([0xEF, 0xBB, 0xBF]) + (try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) + Data([0]) + frame
    }
    static func snippet(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["0": snippetID, "1": [";one", ";two", ";one", ""], "3": "t", "4": "Original text", "10": "Synthetic", "12": "Original note"].merging(extra) { _, new in new }
    }
    static func group(_ children: [[String: Any]], _ extra: [String: Any] = [:]) -> [String: Any] {
        ["99": 1, "0": groupID, "2": "Synthetic group", "13": children].merging(extra) { _, new in new }
    }
    static func main() throws {
        let good = try archive([group([snippet()])])
        let result = try ATextImporter.decode(good)
        let value = result.library.snippets[0]
        check(result.library.groups.count == 1 && result.library.snippets.count == 1, "one group and one snippet")
        check(value.id == UUID(uuidString: snippetID) && value.groupID == UUID(uuidString: groupID), "stable original identifiers")
        check(value.abbreviation == ";one" && value.aliases == [";two"], "aliases preserved without duplicates")
        check(value.content == "Original text" && value.notes == "Original note", "content and notes")
        check(value.enabled && value.trigger == .manual, "supported content enabled with explicit manual trigger")
        check(result.warnings.contains { $0.contains("manuale") }, "manual trigger warning")
        let raw = try JSONSerialization.jsonObject(with: Data(value.atextSourceJSON!.utf8)) as! [String: Any]
        check(raw["1"] as? [String] == [";one", ";two", ";one", ""], "source aliases retained losslessly")
        let groupRaw = try JSONSerialization.jsonObject(with: Data(result.library.groups[0].atextSourceJSON!.utf8)) as! [String: Any]
        check(groupRaw["13"] == nil && groupRaw["2"] as? String == "Synthetic group", "group own metadata without subtree amplification")
        check(try ATextImporter.decode((Data([0xFF]) + good).dropFirst()).library.snippets[0].id == value.id, "Data slice with nonzero index")
        check(try ATextImporter.decode(archive([])).library.snippets.isEmpty, "empty archive")

        let nested = group([snippet()], ["0": childID])
        let nesting = try ATextImporter.decode(archive([group([nested])]))
        check(nesting.library.groups[1].parentID == UUID(uuidString: groupID), "nested groups retain hierarchy")
        check(nesting.library.snippets[0].groupID == UUID(uuidString: childID), "snippet retains nested owner")
        for option in ["3": "prefix", "4": 2, "19": "{\"Mode\":3}", "20": "IsWindows", "21": "[]", "700": "future"] as [String: Any] {
            let blocked = try ATextImporter.decode(archive([group([nested], [option.key: option.value])]))
            check(blocked.library.groups.allSatisfy { !$0.enabled } && !blocked.library.snippets[0].enabled, "unsupported group option \(option.key) blocks descendants")
            check(blocked.warnings.contains { $0.contains(option.key) }, "group option warning identifies \(option.key)")
        }
        let menus = try ATextImporter.decode(archive([group([snippet()], ["9": false, "10": false, "11": false, "22": false])]))
        check(menus.library.groups[0].enabled, "menu visibility and sync do not imply group disabled")

        for (kind, expected): (String, SnippetKind) in [("r", .rich), ("h", .html)] {
            let rich = try ATextImporter.decode(archive([group([snippet(["3": kind, "4": "<b>Main</b>", "5": "<b>Rich</b>"])])]))
            check(rich.library.snippets[0].kind == expected && rich.library.snippets[0].enabled, "supported \(kind) content")
            check(rich.library.snippets[0].content == (kind == "r" ? "<b>Rich</b>" : "<b>Main</b>"), "correct source field for \(kind)")
        }
        let scriptText = "doSomething(<atext type=\"clipboard\">text</atext>)"
        let script = try ATextImporter.decode(archive([group([snippet(["3": "s", "4": scriptText, "7": "bat", "8": "cmd.exe"])])]))
        check(!script.library.snippets[0].enabled && script.library.snippets[0].kind == .plain, "script imported as disabled text")
        check(script.library.snippets[0].content == scriptText, "script source never macro-converted")
        for option in ["2": 1, "6": [["0": "file.txt", "4": "Ym9keQ=="]], "14": ["parameter"], "15": 42, "18": "encoded", "19": "USER==test", "900": true] as [String: Any] {
            let blocked = try ATextImporter.decode(archive([group([snippet([option.key: option.value])])]))
            check(!blocked.library.snippets[0].enabled && blocked.library.snippets[0].atextSourceJSON != nil, "unsupported snippet option \(option.key) retained and disabled")
        }
        let macro = try ATextImporter.decode(archive([group([snippet(["4": "<atext type=\"future-operation\">original</atext>"])])]))
        check(!macro.library.snippets[0].enabled && !macro.warnings.isEmpty, "unsupported macro disables snippet")
        let tags = try ATextImporter.decode(archive([group([snippet(["11": "tag1 tag2"])])]))
        check(tags.library.snippets[0].notes.contains("tag1 tag2"), "tags retained in notes")

        for header in [["0": groupID, "1": true], ["0": "00000000-0000-0000-0000-000000000000", "1": false], ["0": "00000000-0000-0000-0000-000000000000", "1": 1], ["0": "00000000-0000-0000-0000-000000000000", "1": true, "2": "future"]] as [[String: Any]] {
            rejects("unsupported/protected header") { _ = try ATextImporter.decode(archive([], header: header)) }
        }
        rejects("missing separator") { _ = try ATextImporter.decode(Data("plain JSON".utf8)) }
        rejects("truncated compressed frame") { _ = try ATextImporter.decode(good.dropLast()) }
        rejects("trailing junk") { _ = try ATextImporter.decode(good + Data([1])) }
        rejects("root object") { _ = try ATextImporter.decode(archive(["bad": "root"])) }
        rejects("duplicate snippet ID") { _ = try ATextImporter.decode(archive([group([snippet(), snippet()])])) }
        rejects("duplicate group ID") { _ = try ATextImporter.decode(archive([group([]), group([])])) }
        rejects("duplicate across group and snippet") { _ = try ATextImporter.decode(archive([group([snippet(["0": groupID])])])) }
        rejects("malformed UUID") { _ = try ATextImporter.decode(archive([group([snippet(["0": "invalid"])])])) }
        rejects("non-string aliases") { _ = try ATextImporter.decode(archive([group([snippet(["1": [42]])])])) }
        rejects("non-string content") { _ = try ATextImporter.decode(archive([group([snippet(["4": 42])])])) }
        rejects("non-object children") { _ = try ATextImporter.decode(archive([group([], ["13": [42]])])) }
        var deep = group([])
        for _ in 0..<130 { deep = group([deep], ["0": UUID().uuidString]) }
        rejects("bounded hierarchy") { _ = try ATextImporter.decode(archive([deep])) }
        print("aText importer: \(checks) checks passed")
    }
}
