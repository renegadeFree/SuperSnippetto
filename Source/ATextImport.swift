import Foundation
import CoreFoundation

/// Imports the observed plain .atext container. Source records are retained for review.
/// This decoder never evaluates snippet scripts, expressions or embedded files.
enum ATextImporter {
    struct Result {
        var library: LibraryData
        var warnings: [String]
    }
    private static let maximumBytes = 64 * 1024 * 1024

    static func decode(_ data: Data) throws -> Result {
        guard data.count <= maximumBytes else { throw invalid("Documento oltre 64 MB.") }
        let prefix = String(data: data.prefix(256), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))) ?? ""
        if data.starts(with: Data("bplist".utf8)) || prefix.hasPrefix("<?xml") || prefix.hasPrefix("<plist") {
            let legacy = try LegacyATextArchive.decode(data)
            return try readGroups(legacy.groups, sources: legacy.sources, issues: legacy.issues)
        }
        let bytes = Data(data)
        guard let separator = bytes.prefix(16_384).firstIndex(of: 0) else {
            throw invalid("Intestazione mancante o troppo lunga.")
        }
        var headerBytes = Data(bytes[..<separator])
        if headerBytes.starts(with: [0xEF, 0xBB, 0xBF]) { headerBytes.removeFirst(3) }
        guard let header = try JSONSerialization.jsonObject(with: headerBytes) as? [String: Any],
              Set(header.keys) == Set(["0", "1"]),
              let identifier = header["0"] as? String,
              UUID(uuidString: identifier) == UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
              let plain = header["1"] as? NSNumber,
              CFGetTypeID(plain) == CFBooleanGetTypeID(), plain.boolValue else {
            throw invalid("Variante protetta o intestazione aText non supportata.")
        }
        let payload = try LZ4FrameCodec.decode(Data(bytes[(separator + 1)...]), maxOutput: maximumBytes)
        return try decodeJSON(payload)
    }

    static func decodeJSON(_ data: Data) throws -> Result {
        guard data.count <= maximumBytes else { throw invalid("Documento oltre 64 MB.") }
        guard let roots = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw invalid("Il contenuto deve essere un elenco di gruppi.")
        }
        return try readGroups(roots)
    }

    private static func readGroups(_ roots: [[String: Any]], sources: [UUID: [String: Any]] = [:], issues: [UUID: [String]] = [:]) throws -> Result {
        var reader = Reader()
        reader.legacySources = sources; reader.legacyIssues = issues
        for root in roots { try reader.group(root, parentID: nil, inheritedBlock: false, depth: 0) }
        return Result(library: reader.library, warnings: reader.warnings)
    }

    private static func invalid(_ detail: String) -> LibraryError { .invalid("aText: \(detail)") }

    private struct Reader {
        var library = LibraryData()
        var warnings: [String] = []
        var identifiers: Set<UUID> = []
        var metadataBytes = 0
        var warnedAboutManual = false
        var legacySources: [UUID: [String: Any]] = [:]
        var legacyIssues: [UUID: [String]] = [:]

        mutating func identifier(_ record: [String: Any]) throws -> UUID {
            guard let raw = record["0"] as? String, let id = UUID(uuidString: raw) else {
                throw ATextImporter.invalid("Identificatore UUID mancante o non valido.")
            }
            guard identifiers.insert(id).inserted else {
                throw ATextImporter.invalid("Identificatore duplicato: \(raw). Importazione annullata.")
            }
            return id
        }
        func string(_ record: [String: Any], _ key: String, fallback: String = "") throws -> String {
            guard let value = record[key] else { return fallback }
            guard let value = value as? String else { throw ATextImporter.invalid("La proprietà \(key) deve essere una stringa.") }
            return value
        }
        func integer(_ record: [String: Any], _ key: String) throws -> Int? {
            guard let value = record[key] else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= Double(Int.min), number.doubleValue < Double(Int.max) else {
                throw ATextImporter.invalid("La proprietà \(key) deve essere un intero.")
            }
            return number.intValue
        }
        mutating func source(_ record: [String: Any], omitChildren: Bool = false) throws -> String {
            var own = (record["0"] as? String).flatMap(UUID.init(uuidString:)).flatMap { legacySources[$0] } ?? record
            // Children retain their own records and parent links: do not duplicate an entire
            // subtree in every ancestor's metadata (which amplifies deeply nested inputs).
            if omitChildren { own.removeValue(forKey: "13"); own.removeValue(forKey: "Items") }
            let bytes = try JSONSerialization.data(withJSONObject: own, options: [.sortedKeys])
            guard bytes.count <= ATextImporter.maximumBytes - metadataBytes,
                  let text = String(data: bytes, encoding: .utf8) else {
                throw ATextImporter.invalid("Metadati originali oltre il limite di 64 MB.")
            }
            metadataBytes += bytes.count
            return text
        }
        func meaningful(_ value: Any?) -> Bool {
            guard let value, !(value is NSNull) else { return false }
            if let text = value as? String { return !text.isEmpty }
            if let values = value as? [Any] { return !values.isEmpty }
            if let number = value as? NSNumber { return number.doubleValue != 0 }
            return true
        }
        mutating func group(_ record: [String: Any], parentID: UUID?, inheritedBlock: Bool, depth: Int) throws {
            guard depth <= 128, library.groups.count < 10_000 else { throw ATextImporter.invalid("Troppi gruppi o gerarchia troppo profonda.") }
            if let marker = try integer(record, "99"), marker != 1 { throw ATextImporter.invalid("Tipo di gruppo sconosciuto.") }
            var item = SnippetGroup()
            item.id = try identifier(record)
            item.name = try string(record, "2", fallback: "Gruppo importato")
            item.parentID = parentID
            item.atextSourceJSON = try source(record, omitChildren: true)
            var unsupported = ["1", "3", "4", "5", "6", "7", "8", "14", "16", "17", "19", "20", "21"]
                .filter { meaningful(record[$0]) }
            // Older numeric JSON stores the all-applications default in key15.
            // Other availability variants remain blocked; do not widen their scope.
            if meaningful(record["15"]) {
                let availability = record["15"] as? [String: Any]
                let mode = availability?["0"] as? NSNumber
                let unrestricted = availability?.count == 1 && mode != nil && CFGetTypeID(mode!) != CFBooleanGetTypeID() && mode!.doubleValue == 0
                if !unrestricted { unsupported.append("15") }
            }
            let known = Set(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", "19", "20", "21", "22", "99"])
            let unknown = record.keys.filter { !known.contains($0) && meaningful(record[$0]) }.sorted()
            let legacy = legacyIssues[item.id] ?? []
            let blocked = inheritedBlock || !unsupported.isEmpty || !unknown.isEmpty || !legacy.isEmpty
            item.enabled = !blocked
            if !unsupported.isEmpty || !unknown.isEmpty {
                warnings.append("Gruppo \(item.name): regole aText non rappresentate (proprietà \((unsupported + unknown).joined(separator: ", "))). Gruppo e discendenti disattivati; originali conservati.")
            }
            warnings += legacy.map { "Gruppo \(item.name): \($0) Gruppo e discendenti disattivati." }
            library.groups.append(item)
            guard let rawChildren = record["13"] else { return }
            guard let children = rawChildren as? [[String: Any]] else { throw ATextImporter.invalid("I figli del gruppo devono essere oggetti JSON.") }
            for child in children {
                if try integer(child, "99") == 1 || child["13"] is [Any] {
                    try group(child, parentID: item.id, inheritedBlock: blocked, depth: depth + 1)
                } else {
                    try snippet(child, groupID: item.id, inheritedBlock: blocked)
                }
            }
        }
        mutating func snippet(_ record: [String: Any], groupID: UUID, inheritedBlock: Bool) throws {
            guard library.snippets.count < 100_000 else { throw ATextImporter.invalid("Troppi frammenti.") }
            if let marker = try integer(record, "99"), marker != 0 { throw ATextImporter.invalid("Tipo di frammento sconosciuto.") }
            var item = Snippet()
            item.id = try identifier(record); item.groupID = groupID
            item.atextSourceJSON = try source(record)
            let aliases: [String]
            if let raw = record["1"] {
                guard let strings = raw as? [String], strings.count <= 10_000 else { throw ATextImporter.invalid("Le abbreviazioni devono essere un elenco di stringhe.") }
                var seen: Set<String> = []
                aliases = strings.filter { !$0.isEmpty && seen.insert($0).inserted }
            } else { aliases = [] }
            item.abbreviation = aliases.first ?? ""
            item.aliases = Array(aliases.dropFirst())
            item.title = try string(record, "10", fallback: aliases.first ?? "Frammento importato")
            if item.title.isEmpty { item.title = aliases.first ?? "Frammento importato" }
            item.notes = try string(record, "12")
            let tags = try string(record, "11")
            if !tags.isEmpty { item.notes += (item.notes.isEmpty ? "" : "\n\n") + "Tag aText: \(tags)" }
            // Imported rules require explicit review: automatic trigger defaults vary by
            // source group and are not inferred from absent properties.
            item.trigger = .manual
            if !warnedAboutManual {
                warnings.append("I frammenti aText usano l'attivazione manuale: verifica le regole prima di attivare l'espansione automatica.")
                warnedAboutManual = true
            }
            var issues = legacyIssues[item.id] ?? []
            let kind = try string(record, "3", fallback: "t")
            let plain = try string(record, "4")
            switch kind {
            case "t": item.kind = .plain; item.content = plain
            case "r":
                item.kind = .rich
                item.content = try string(record, "5", fallback: plain)
                if record["5"] == nil { issues.append("Contenuto formattato mancante; testo originale conservato.") }
            case "h": item.kind = .html; item.content = plain
            case "s":
                item.kind = .plain; item.content = plain
                issues.append("Script aText conservato come testo disattivato; host e linguaggio originali nei metadati.")
            default:
                item.kind = .plain; item.content = plain
                issues.append("Tipo di contenuto aText non supportato: \(kind).")
            }
            // Preserve script source literally. Tokens in executable source must not be
            // converted into live native template operations.
            if kind != "s" {
                let converted = ATextMacroConverter.convert(item.content)
                item.content = converted.text; issues += converted.warnings
            }
            let unsupported = ["2", "6", "7", "8", "9", "14", "15", "16", "18", "19"]
                .filter { meaningful(record[$0]) }
            let known = Set(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "18", "19", "99"])
            let unknown = record.keys.filter { !known.contains($0) && meaningful(record[$0]) }.sorted()
            if !unsupported.isEmpty || !unknown.isEmpty {
                issues.append("Opzioni aText non rappresentate (proprietà \((unsupported + unknown).joined(separator: ", "))); originali conservati.")
            }
            item.enabled = !inheritedBlock && issues.isEmpty
            if inheritedBlock { issues.append("Disattivato per una regola del gruppo di origine.") }
            if !issues.isEmpty {
                item.notes += (item.notes.isEmpty ? "" : "\n\n") + "Importazione aText:\n" + issues.joined(separator: "\n")
                warnings += issues.map { "\(item.title): \($0)" }
            }
            library.snippets.append(item)
        }
    }
}
