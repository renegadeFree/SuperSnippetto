import Foundation
import CoreFoundation

/// Reads the older Apple keyed archive as data. It never instantiates archived classes.
enum LegacyATextArchive {
    struct Decoded {
        var groups: [[String: Any]]
        var sources: [UUID: [String: Any]]
        var issues: [UUID: [String]]
    }
    private static func invalid(_ detail: String) -> LibraryError { .invalid("aText legacy: \(detail)") }

    static func decode(_ data: Data) throws -> Decoded {
        guard data.count <= 64 * 1024 * 1024,
              let archive = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              archive["$archiver"] as? String == "NSKeyedArchiver",
              let objects = archive["$objects"] as? [Any], !objects.isEmpty, objects.count <= 200_000,
              objects[0] as? String == "$null",
              let top = archive["$top"] as? [String: Any], let root = top["root"] else {
            throw invalid("Archivio plist non riconosciuto.")
        }
        var graph = Graph(objects: objects)
        guard let library = try graph.resolve(root) as? [String: Any], let roots = library["Snippets"] as? [[String: Any]] else {
            throw invalid("Elenco Snippets mancante.")
        }
        var reader = Records()
        let groups = try roots.map { try reader.group($0, depth: 0) }
        return Decoded(groups: groups, sources: reader.sources, issues: reader.issues)
    }

    private struct Graph {
        let objects: [Any]
        var active: Set<Int> = []
        var cache: [Int: Any] = [:]
        var steps = 0

        /// Foundation exposes UID values as opaque property-list types. Convert only
        /// the tiny UID leaf to public XML, renaming CF$UID before reading it back.
        /// Whole-archive XML conversion would amplify shared strings unnecessarily.
        func index(_ value: Any) throws -> Int {
            let xml = try PropertyListSerialization.data(fromPropertyList: [value], format: .xml, options: 0)
            guard xml.count <= 2048, let text = String(data: xml, encoding: .utf8), text.contains("<key>CF$UID</key>") else {
                throw invalid("Riferimento UID non valido.")
            }
            let renamed = text.replacingOccurrences(of: "<key>CF$UID</key>", with: "<key>SuperSnippettoUID</key>")
            guard let array = try PropertyListSerialization.propertyList(from: Data(renamed.utf8), options: [], format: nil) as? [[String: Any]],
                  array.count == 1, array[0].count == 1, let number = array[0]["SuperSnippettoUID"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
                  number.doubleValue < Double(objects.count), number.doubleValue.rounded() == number.doubleValue else {
                throw invalid("Riferimento UID fuori archivio.")
            }
            return number.intValue
        }

        mutating func resolve(_ value: Any, depth: Int = 0) throws -> Any {
            steps += 1
            guard depth <= 256, steps <= 500_000 else { throw invalid("Archivio troppo complesso o gerarchia troppo profonda.") }
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number }
            if let data = value as? Data { return ["$legacyDataBase64": data.base64EncodedString()] }
            if let date = value as? Date { return ["$legacyDate": date.timeIntervalSince1970] }
            if let array = value as? [Any] { return try array.map { try resolve($0, depth: depth + 1) } }
            if let object = value as? [String: Any] {
                guard let reference = object["$class"] else { throw invalid("Oggetto privo di descrizione della classe.") }
                let classIndex = try index(reference)
                guard let descriptor = objects[classIndex] as? [String: Any], let name = descriptor["$classname"] as? String else {
                    throw invalid("Descrizione della classe non valida.")
                }
                switch name {
                case "NSArray", "NSMutableArray":
                    guard let values = object["NS.objects"] as? [Any] else { throw invalid("Array legacy non valido.") }
                    return try values.map { try resolve($0, depth: depth + 1) }
                case "NSDictionary", "NSMutableDictionary":
                    guard let keys = object["NS.keys"] as? [Any], let values = object["NS.objects"] as? [Any], keys.count == values.count else {
                        throw invalid("Dizionario legacy non valido.")
                    }
                    var result: [String: Any] = [:]
                    for (key, value) in zip(keys, values) {
                        guard let key = try resolve(key, depth: depth + 1) as? String, result[key] == nil else {
                            throw invalid("Chiave non testuale o duplicata.")
                        }
                        result[key] = try resolve(value, depth: depth + 1)
                    }
                    return result
                case "NSDate":
                    guard let time = object["NS.time"] as? NSNumber, CFGetTypeID(time) != CFBooleanGetTypeID(), time.doubleValue.isFinite else {
                        throw invalid("Data legacy non valida.")
                    }
                    return ["$legacyClass": name, "NS.time": time]
                case "Snippet", "SnippetGroup":
                    var result: [String: Any] = ["$legacyClass": name]
                    for (key, value) in object where key != "$class" { result[key] = try resolve(value, depth: depth + 1) }
                    return result
                default: throw invalid("Classe legacy non supportata: \(name). Nessun codice dell'archivio è stato eseguito.")
                }
            }
            let reference = try index(value)
            if reference == 0 { return NSNull() }
            if let cached = cache[reference] { return cached }
            guard active.insert(reference).inserted else { throw invalid("Riferimenti ciclici nell'archivio.") }
            defer { active.remove(reference) }
            let result = try resolve(objects[reference], depth: depth + 1)
            cache[reference] = result
            return result
        }
    }

    private struct Records {
        var sources: [UUID: [String: Any]] = [:]
        var issues: [UUID: [String]] = [:]

        func string(_ record: [String: Any], _ key: String) throws -> String {
            guard let value = record[key], !(value is NSNull) else { return "" }
            guard let value = value as? String else { throw invalid("La proprietà \(key) deve essere testuale.") }
            return value
        }
        func integer(_ record: [String: Any], _ key: String) throws -> Int {
            guard let value = record[key], !(value is NSNull) else { return 0 }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= Double(Int.min), number.doubleValue < Double(Int.max) else { throw invalid("La proprietà \(key) deve essere un intero.") }
            return number.intValue
        }
        mutating func remember(_ record: [String: Any], group: Bool) throws -> UUID {
            guard sources.count < 110_000, let id = UUID(uuidString: try string(record, "UUID")), sources[id] == nil else {
                throw invalid("UUID non valido/duplicato o troppi elementi.")
            }
            var own = record
            if group { own.removeValue(forKey: "Items") }
            sources[id] = own
            return id
        }
        func meaningful(_ value: Any?) -> Bool {
            guard let value, !(value is NSNull) else { return false }
            if let string = value as? String { return !string.isEmpty }
            if let number = value as? NSNumber { return number.doubleValue != 0 }
            if let array = value as? [Any] { return !array.isEmpty }
            return true
        }
        mutating func group(_ record: [String: Any], depth: Int) throws -> [String: Any] {
            guard depth <= 128, record["$legacyClass"] as? String == "SnippetGroup", let children = record["Items"] as? [[String: Any]] else {
                throw invalid("Gruppo legacy non valido o troppo annidato.")
            }
            let id = try remember(record, group: true)
            let known = Set(["$legacyClass", "UUID", "Name", "Items", "DateCreated", "ResetFormatting", "ShowInMenuBarAtFirstLevel", "CaseSensitivity", "ExpandAfter", "InputMethodsOption", "ExpandTrigger", "EnabledIn", "SuggestAbbreviations", "ShowInMenuBar"])
            let behavioral = ["ResetFormatting", "CaseSensitivity", "ExpandAfter", "InputMethodsOption", "ExpandTrigger", "EnabledIn"]
            let unsupported = record.keys.filter { (!known.contains($0) || behavioral.contains($0)) && meaningful(record[$0]) }.sorted()
            issues[id] = unsupported.map { "Opzione legacy non convertita: \($0); originale conservato." }
            let items = try children.map { child -> [String: Any] in
                if child["$legacyClass"] as? String == "SnippetGroup" { return try group(child, depth: depth + 1) }
                return try snippet(child)
            }
            return ["0": id.uuidString, "2": try string(record, "Name"), "13": items, "99": 1]
        }
        mutating func snippet(_ record: [String: Any]) throws -> [String: Any] {
            guard record["$legacyClass"] as? String == "Snippet" else { throw invalid("Frammento legacy non riconosciuto.") }
            let id = try remember(record, group: false)
            var problems: [String] = []
            let abbreviation = try string(record, "Abbreviation")
            if meaningful(record["Aliases"]) { problems.append("Alias legacy conservati nei metadati: formato da verificare.") }
            if try integer(record, "ContentType") != 0 { problems.append("Tipo di contenuto legacy non testuale; originale conservato senza esecuzione.") }
            if try integer(record, "CaseSensitivity") != 0 { problems.append("Regola maiuscole legacy non convertita.") }
            let known = Set(["$legacyClass", "UUID", "Abbreviation", "Aliases", "Content", "ContentType", "CaseSensitivity", "Label", "Note", "DateCreated", "DateModified", "12"])
            problems += record.keys.filter { !known.contains($0) && meaningful(record[$0]) }.sorted().map { "Opzione legacy non convertita: \($0); originale conservato." }
            let converted = ATextMacroConverter.convertLegacy(try string(record, "Content"))
            problems += converted.warnings
            issues[id] = problems
            return ["0": id.uuidString, "1": abbreviation.isEmpty ? [] : [abbreviation], "3": "t", "4": converted.text,
                    "10": try string(record, "Label"), "12": try string(record, "Note"), "99": 0]
        }
    }
}
