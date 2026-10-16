import Foundation

/// A conservative bridge for observed aText inline markup. This is original code;
/// unsupported operations remain verbatim and cause the importer to disable the item.
enum ATextMacroConverter {
    /// Older macOS exports use full-width brackets instead of inline XML.
    static func convertLegacy(_ input: String) -> (text: String, warnings: [String]) {
        let pattern = try! NSRegularExpression(pattern: #"【(date|time):(full|long|medium|short)(?:\s+locale:([A-Za-z][A-Za-z0-9_-]{0,63}))?\s*】"#)
        let output = NSMutableString(string: input)
        for match in pattern.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            let text = input as NSString
            let type = text.substring(with: match.range(at: 1)), format = text.substring(with: match.range(at: 2))
            let locale = match.range(at: 3).location == NSNotFound ? "" : " locale=\"\(text.substring(with: match.range(at: 3)))\""
            output.replaceCharacters(in: match.range, with: "<atext type=\"\(type)\" format=\"\(format)\"\(locale)></atext>")
        }
        let text = output as String
        let warnings = text.contains("【") || text.contains("】") ? ["Macro legacy tra parentesi speciali non convertita; originale conservato."] : []
        return (text, warnings)
    }

    static func convert(_ input: String) -> (text: String, warnings: [String]) {
        var warnings: [String] = [], output = "", cursor = input.startIndex, count = 0
        var fieldDefinitions: [String: String] = [:]
        var references: [(marker: String, name: String, original: String, replacement: String)] = []
        var referenceMarker = "\u{E002}\(UUID().uuidString)"
        while input.contains(referenceMarker) { referenceMarker = "\u{E002}\(UUID().uuidString)" }
        if input.contains("{{") || input.contains("}}") {
            warnings.append("Il testo contiene delimitatori di modello nativi: revisione necessaria prima dell'attivazione.")
        }
        while let start = input.range(of: "<atext", range: cursor..<input.endIndex) {
            let afterName = start.upperBound
            guard afterName == input.endIndex || input[afterName].isWhitespace || input[afterName] == ">" || input[afterName] == "/" else {
                output += input[cursor..<afterName]; cursor = afterName; continue
            }
            output += input[cursor..<start.lowerBound]
            var end = afterName, quote: Character?
            while end < input.endIndex {
                let char = input[end]
                if let active = quote { if char == active { quote = nil } }
                else if char == "\"" || char == "'" { quote = char }
                else if char == ">" { break }
                end = input.index(after: end)
            }
            guard end < input.endIndex else {
                output += input[start.lowerBound...]; cursor = input.endIndex
                warnings.append("Macro aText non chiusa, conservata senza conversione."); break
            }
            let openingEnd = input.index(after: end)
            let isEmpty = input[start.lowerBound..<openingEnd].dropLast().last == "/"
            let tokenEnd: String.Index
            if isEmpty { tokenEnd = openingEnd }
            else if let close = input.range(of: "</atext>", range: openingEnd..<input.endIndex) { tokenEnd = close.upperBound }
            else {
                output += input[start.lowerBound...]; cursor = input.endIndex
                warnings.append("Macro aText non chiusa, conservata senza conversione."); break
            }
            let raw = String(input[start.lowerBound..<tokenEnd]); count += 1
            if count > 4096 || raw.utf8.count > 65_536 {
                output += raw; warnings.append("Macro aText oltre i limiti di conversione.")
            } else {
                let parsed = MacroXML()
                let parser = XMLParser(data: Data(raw.utf8)); parser.delegate = parsed
                parser.shouldResolveExternalEntities = false
                if !raw.contains("<!"), parser.parse(), parsed.valid, parsed.depth == 0 {
                    if let replacement = replacement(parsed.attributes, body: parsed.body, number: count) {
                        if parsed.attributes["type"] == "field", let name = parsed.attributes["name"], !name.isEmpty {
                            if replacement.hasPrefix("{{var:") {
                                let marker = referenceMarker + "-\(references.count)\u{E003}"
                                references.append((marker, name, raw, replacement)); output += marker
                            } else {
                                if let previous = fieldDefinitions[name], previous != replacement { warnings.append("Il campo aText \(name) ha definizioni differenti.") }
                                else { fieldDefinitions[name] = replacement }
                                output += replacement
                            }
                        } else { output += replacement }
                    }
                    else {
                        output += raw
                        let type = parsed.attributes["type"] ?? parsed.body.lowercased()
                        warnings.append("Macro aText non convertita: \(String(type.prefix(80))). Originale conservato.")
                    }
                } else { output += raw; warnings.append("Markup aText non riconosciuto, conservato senza conversione.") }
            }
            cursor = tokenEnd
        }
        output += input[cursor...]
        for reference in references {
            let found = fieldDefinitions[reference.name] != nil
            output = output.replacingOccurrences(of: reference.marker, with: found ? reference.replacement : reference.original)
            if !found { warnings.append("Riferimento al campo aText \(reference.name) senza definizione modificabile nello stesso frammento.") }
        }
        return (output, Array(Set(warnings)).sorted())
    }

    private static func replacement(_ attributes: [String: String], body: String, number: Int) -> String? {
        var a = attributes
        let type = a.removeValue(forKey: "type") ?? body.lowercased()
        a.removeValue(forKey: "contenteditable") // Editor presentation, not expansion behavior.
        func safe(_ value: String) -> Bool { !value.contains("{{") && !value.contains("}}") }
        func argument(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
        }
        switch type {
        case "caret", "|": return a.isEmpty ? "{{cursor}}" : nil
        case "clipboard":
            if a["history"] == "0" { a.removeValue(forKey: "history") }
            return a.isEmpty ? "{{clipboard}}" : nil
        case "snippet":
            guard let guid = a.removeValue(forKey: "guid") ?? a.removeValue(forKey: "uuid"),
                  let id = UUID(uuidString: guid), a.isEmpty else { return nil }
            return "{{snippet:\(id.uuidString)}}"
        case "field":
            let flagsText = a.removeValue(forKey: "flags") ?? "0"
            guard let flags = Int(flagsText), flags == 0 || flags == 4 else { return nil }
            let kind = a.removeValue(forKey: "fieldtype2") ?? "0"
            guard kind == "0" || kind == "2" else { return nil }
            let name = a.removeValue(forKey: "name") ?? ""
            let value = a.removeValue(forKey: "value") ?? ""
            guard safe(name), safe(value), name.count <= 200 else { return nil }
            if a["description"] == "" { a.removeValue(forKey: "description") }
            // Layout does not alter the field value; retain its original attributes in metadata.
            if let width = a["width"], let n = Int(width), n >= 0 { a.removeValue(forKey: "width") }
            let linesText = a.removeValue(forKey: "lines") ?? "1"
            guard let lines = Int(linesText), (1...100).contains(lines) else { return nil }
            if flags == 0 {
                guard !name.isEmpty, value.isEmpty, a.isEmpty else { return nil }
                return "{{var:\(name)}}"
            }
            let fieldName = name.isEmpty ? "Campo aText \(number)" : name
            if kind == "2" {
                guard lines == 1, value.isEmpty else { return nil }
                var options: [String] = []
                while let item = a.removeValue(forKey: "item\(options.count)") {
                    guard options.count < 100, safe(item), !item.hasPrefix("snippet:"), !item.hasPrefix("group:") else { return nil }
                    options.append(item)
                }
                guard !options.isEmpty, a.isEmpty else { return nil }
                return "{{choice:\(argument(fieldName))|\(options.map(argument).joined(separator: "|"))}}"
            }
            guard a.isEmpty else { return nil }
            return "{{\(lines > 1 ? "multiline" : "field"):\(argument(fieldName))|\(argument(value))}}"
        case "datetime", "date", "time":
            let preset = a.removeValue(forKey: "preset") == "1"
            let localeName = a.removeValue(forKey: "locale") ?? Locale.current.identifier
            guard localeName.count < 100, safe(localeName), localeName.range(of: "^[A-Za-z][A-Za-z0-9_@=.-]*$", options: .regularExpression) != nil else { return nil }
            var sourceFormat = a.removeValue(forKey: "format") ?? ""
            var legacyFormat: String?
            let styles: [String: DateFormatter.Style] = ["full": .full, "long": .long, "medium": .medium, "short": .short]
            if (type == "date" || type == "time"), let style = styles[sourceFormat] {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: localeName)
                if type == "date" { formatter.dateStyle = style } else { formatter.timeStyle = style }
                legacyFormat = formatter.dateFormat
            }
            let standard = preset || sourceFormat.isEmpty
            if sourceFormat.isEmpty { sourceFormat = "f" }
            var offset = ""
            if let shift = a.removeValue(forKey: "f0") {
                guard let match = shift.range(of: "^shift;day:-?[0-9]{1,6};$", options: .regularExpression), match == shift.startIndex..<shift.endIndex,
                      let amount = Int(shift.dropFirst(10).dropLast()) else { return nil }
                offset = "\(amount >= 0 ? "+" : "")\(amount)d|"
            }
            guard a.isEmpty, let format = legacyFormat ?? dateFormat(sourceFormat, preset: standard, locale: Locale(identifier: localeName)), safe(format) else { return nil }
            return "{{date:\(offset)\(argument(format))|\(argument(localeName))}}"
        default: return nil
        }
    }

    /// Only formats whose tokens have a known Foundation equivalent are accepted.
    private static func dateFormat(_ source: String, preset: Bool, locale: Locale) -> String? {
        if preset && source.count == 1 {
            let f = DateFormatter(); f.locale = locale
            switch source {
            case "d": f.dateStyle = .short
            case "D": f.dateStyle = .full
            case "t": f.timeStyle = .short
            case "T": f.timeStyle = .medium
            case "f": f.dateStyle = .full; f.timeStyle = .short
            case "F": f.dateStyle = .full; f.timeStyle = .medium
            case "g": f.dateStyle = .short; f.timeStyle = .short
            case "G": f.dateStyle = .short; f.timeStyle = .medium
            case "s": return "yyyy-MM-dd'T'HH:mm:ss"
            default: return nil
            }
            return f.dateFormat
        }
        guard !source.isEmpty, source.count <= 512 else { return nil }
        let chars = Array(source); var index = 0, result = ""
        func literal(_ text: String) -> String {
            if text.allSatisfy({ $0 == "'" }) { return String(repeating: "''", count: text.count) }
            return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        }
        while index < chars.count {
            let char = chars[index]
            if char == "'" || char == "\"" {
                let quote = char; index += 1; var text = "", closed = false
                while index < chars.count {
                    if chars[index] == quote { index += 1; closed = true; break }
                    if chars[index] == "\\" { index += 1; guard index < chars.count else { return nil } }
                    text.append(chars[index]); index += 1
                }
                guard closed else { return nil }; result += literal(text); continue
            }
            if char == "\\" {
                index += 1; guard index < chars.count else { return nil }
                result += literal(String(chars[index])); index += 1; continue
            }
            if char.isASCII && char.isLetter {
                var end = index + 1
                while end < chars.count && chars[end] == char { end += 1 }
                let n = end - index, token = String(chars[index..<end])
                switch char {
                case "d": guard n <= 4 else { return nil }; result += n >= 3 ? String(repeating: "E", count: n) : token
                case "M": guard n <= 4 else { return nil }; result += token
                case "y": guard n == 2 || n == 4 else { return nil }; result += token
                case "H", "h", "m", "s": guard n <= 2 else { return nil }; result += token
                case "f": guard n <= 3 else { return nil }; result += String(repeating: "S", count: n)
                case "t": guard n == 2 else { return nil }; result += "a"
                default: return nil
                }
                index = end
            } else {
                // .NET ':' and '/' are locale separators, not necessarily literals.
                // Imported common formats use those separators; retain the explicit form.
                guard char != "%" else { return nil }
                result += String(char); index += 1
            }
        }
        return result
    }
}

private final class MacroXML: NSObject, XMLParserDelegate {
    var attributes: [String: String] = [:], body = "", depth = 0, valid = true
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        guard depth == 1, name == "atext" else { valid = false; parser.abortParsing(); return }
        self.attributes = attributes
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
    func parser(_ parser: XMLParser, foundCharacters string: String) { body += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { valid = false; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { valid = false; parser.abortParsing() }
}
