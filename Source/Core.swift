import Foundation
import Combine

enum SnippetKind: String, Codable, CaseIterable { case plain, rich, html, image, shell, appleScript, javascript }
enum TriggerMode: String, Codable, CaseIterable { case immediate, delimiterKeep, delimiterDiscard, manual }
enum AppScope: String, Codable, CaseIterable { case all, only, except }

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "Nuovo frammento"
    var abbreviation = ""
    var groupID: UUID? = nil
    var content = ""
    var kind: SnippetKind = .plain
    var trigger: TriggerMode = .immediate
    var caseSensitive = false
    var wholeWord = true
    var adaptCase = false
    var enabled = true
    var appScope: AppScope = .all
    var apps: [String] = []
    var hotkeyCode: Int? = nil
    var hotkeyModifiers: UInt32 = 0
    var notes = ""
    var useCount = 0
    var aliases: [String]? = nil
    var atextSourceJSON: String? = nil

    var allAbbreviations: [String] {
        var seen: Set<String> = []
        return ([abbreviation] + (aliases ?? [])).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    func matchesAbbreviation(_ value: String) -> Bool {
        !value.isEmpty && (abbreviation == value || aliases?.contains(value) == true)
    }
}

struct SnippetGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Nuovo gruppo"
    var parentID: UUID? = nil
    var enabled = true
    var atextSourceJSON: String? = nil
}

struct TrashedSnippet: Codable, Identifiable, Equatable {
    var id: UUID
    var snippet: Snippet
    var deletedAt: Date
    init(snippet: Snippet, deletedAt: Date = Date()) {
        self.id = snippet.id; self.snippet = snippet; self.deletedAt = deletedAt
    }
}

struct LibraryData: Codable, Equatable {
    var groups: [SnippetGroup] = []
    var snippets: [Snippet] = []
    var excludedApps: [String] = []
    var delimiters = " \t\n.,;:!?()[]{}"
    var paused = false
    var allowScripts = false
    var launchAtLogin = false
    var syncFolder: String? = nil
    // Optional so libraries written by version 0.1 remain decodable unchanged.
    var trash: [TrashedSnippet]? = nil
    var backupIntervalMinutes: Int? = nil
    var backupRetention: Int? = nil
    var backupFolder: String? = nil
}

enum LibraryError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

private struct LibraryDocument: Codable {
    var format = "EspansoLocale"
    var version = 1
    var data: LibraryData
}

struct ExpansionMatch {
    var snippet: Snippet
    var deleteCount: Int
    var typedAbbreviation: String
    var trailingDelimiter: String
}

final class LibraryStore: ObservableObject {
    @Published var data = LibraryData()
    @Published private(set) var lastError: String?
    @Published private(set) var lastImportWarnings: [String] = []
    let fileURL: URL
    private var loadFailed = false
    private static let maximumFileBytes = 64 * 1024 * 1024
    private var recoveryBackupFolder: String?
    var effectiveBackupIntervalMinutes: Int { data.backupIntervalMinutes ?? 1440 }
    var effectiveBackupRetention: Int { data.backupRetention ?? 100 }
    var backupsDirectory: URL {
        if let path = recoveryBackupFolder ?? data.backupFolder, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }
    private var backupLocationURL: URL { fileURL.appendingPathExtension("backup-location.json") }

    init(url: URL? = nil) {
        // Keep the existing data directory and document identifier compatible across the rename.
        fileURL = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EspansoLocale/library.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if url == nil {
                let group = SnippetGroup(name: "Personali")
                data.groups = [group]
                data.snippets = [
                    Snippet(title: "Firma di esempio", abbreviation: ";firma", groupID: group.id, content: "Cordiali saluti,\n{{field:Nome}}"),
                    Snippet(title: "Data di oggi", abbreviation: ";oggi", groupID: group.id, content: "{{date:dd/MM/yyyy}}")
                ]
            }
            return
        }
        do { data = try Self.decodeJSON(Self.readLimited(fileURL)) }
        catch {
            lastError = error.localizedDescription; loadFailed = true
            if let bytes = try? Self.readLimited(backupLocationURL), bytes.count <= 16_384,
               let path = try? JSONDecoder().decode(String.self, from: bytes), path.hasPrefix("/") {
                recoveryBackupFolder = path
            }
            // Never overwrite an unreadable original until its exact bytes have been preserved.
            if let candidates = try? backups() {
                for backup in candidates {
                    guard let recovered = try? Self.decodeJSON(Self.readLimited(backup)) else { continue }
                    do {
                        let preserved = try preserveCorruptOriginal()
                        try Self.encode(recovered).write(to: fileURL, options: .atomic)
                        data = recovered; loadFailed = false; recoveryBackupFolder = nil
                        lastError = "Libreria recuperata dal backup \(backup.lastPathComponent). Originale conservato in \(preserved.path)."
                    } catch { lastError = "Ripristino automatico non riuscito: \(error.localizedDescription)" }
                    break
                }
            }
        }
    }

    func save() throws {
        guard !loadFailed else {
            throw LibraryError.invalid("La libreria originale non è leggibile. Esporta in un altro file prima di ripristinarla: \(fileURL.path)")
        }
        try Self.validate(data)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Snapshot the previous valid disk state, before replacing it with edited memory.
            let previous = try Self.decodeJSON(Self.readLimited(fileURL))
            let mostRecent = try backups().first.flatMap { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            if mostRecent == nil || Date().timeIntervalSince(mostRecent!) >= Double(effectiveBackupIntervalMinutes) * 60 { _ = try writeBackup(previous) }
        }
        try recordBackupLocation(for: data)
        try Self.encode(data).write(to: fileURL, options: .atomic)
    }

    /// Newest first. JSON snapshots include active snippets, preferences, groups and trash.
    func backups() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: backupsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix("snapshot-") && $0.pathExtension == "json" && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true) }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return first == second ? $0.lastPathComponent > $1.lastPathComponent : first > second
            }
    }

    @discardableResult
    func createBackup() throws -> URL { try writeBackup(data) }

    func restoreBackup(_ url: URL) throws {
        // Decode and validate the entire source before any file, snapshot or in-memory mutation.
        let restored = try Self.decodeJSON(Self.readLimited(url))
        _ = try createBackup()
        if FileManager.default.fileExists(atPath: fileURL.path),
           (try? Self.decodeJSON(Self.readLimited(fileURL))) == nil { _ = try preserveCorruptOriginal() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try recordBackupLocation(for: restored)
        try Self.encode(restored).write(to: fileURL, options: .atomic)
        loadFailed = false; lastError = nil; recoveryBackupFolder = nil
        data = restored
    }

    private func writeBackup(_ value: LibraryData) throws -> URL {
        try Self.validate(value)
        let bytes = try Self.encode(value)
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = backupsDirectory.appendingPathComponent("snapshot-\(formatter.string(from: Date()))-\(UUID().uuidString).json")
        try bytes.write(to: url, options: .atomic)
        let previous = try backups().filter { $0.lastPathComponent != url.lastPathComponent }
        for old in previous.dropFirst(max(0, effectiveBackupRetention - 1)) { try FileManager.default.removeItem(at: old) }
        return url
    }

    private func recordBackupLocation(for value: LibraryData) throws {
        let folder = value.backupFolder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).path }
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("Backups").path
        try JSONEncoder().encode(folder).write(to: backupLocationURL, options: .atomic)
    }

    private func preserveCorruptOriginal() throws -> URL {
        let original = fileURL.deletingPathExtension().appendingPathExtension("\(Int64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).corrupt")
        try FileManager.default.copyItem(at: fileURL, to: original)
        return original
    }

    func moveToTrash(_ ids: Set<UUID>) {
        var value = data
        var trash = value.trash ?? []
        for var snippet in value.snippets where ids.contains(snippet.id) {
            if trash.contains(where: { $0.snippet == snippet }) { continue }
            if trash.contains(where: { $0.id == snippet.id }) { snippet.id = UUID() }
            trash.append(TrashedSnippet(snippet: snippet))
        }
        value.snippets.removeAll { ids.contains($0.id) }
        value.trash = trash; data = value
    }

    func restoreFromTrash(_ ids: Set<UUID>) {
        var value = data
        for item in value.trash ?? [] where ids.contains(item.id) {
            var snippet = item.snippet
            if let group = snippet.groupID, !value.groups.contains(where: { $0.id == group }) { snippet.groupID = nil }
            if value.snippets.contains(snippet) { continue }
            if value.snippets.contains(where: { $0.id == snippet.id }) { snippet.id = UUID() }
            value.snippets.append(snippet)
        }
        value.trash?.removeAll { ids.contains($0.id) }
        data = value
    }

    func emptyTrash() { data.trash = [] }

    func exportFile(_ url: URL) throws {
        try Self.validate(data)
        if url.pathExtension.lowercased() == "csv" {
            try Self.encodeCSV(data).write(to: url, atomically: true, encoding: .utf8)
        } else { try Self.encode(data).write(to: url, options: .atomic) }
    }

    func importFile(_ url: URL) throws {
        let bytes = try Self.readLimited(url)
        let incoming: LibraryData
        var warnings: [String] = []
        switch url.pathExtension.lowercased() {
        case "csv":
            guard let string = String(data: bytes, encoding: .utf8) else { throw LibraryError.invalid("CSV non UTF-8.") }
            incoming = try Self.decodeCSV(string)
        case "plist", "textexpander", "xml": incoming = try Self.decodeTextExpander(bytes)
        case "atext":
            let result = try ATextImporter.decode(bytes)
            incoming = result.library; warnings = result.warnings
        default: incoming = try Self.decodeJSON(bytes)
        }
        try Self.validate(incoming)
        var merged = data
        // Imports never silently replace an existing item with different content.
        var groupMap: [UUID: UUID] = [:]
        for group in incoming.groups {
            if let existing = merged.groups.first(where: { $0.id == group.id }), existing != group { groupMap[group.id] = UUID() }
        }
        var changed = true
        while changed {
            changed = false
            for group in incoming.groups where groupMap[group.id] == nil {
                if let parent = group.parentID, groupMap[parent] != nil,
                   merged.groups.contains(where: { $0.id == group.id }) {
                    groupMap[group.id] = UUID(); changed = true
                }
            }
        }
        for group in incoming.groups {
            var copy = group
            copy.id = groupMap[group.id] ?? group.id
            copy.parentID = group.parentID.map { groupMap[$0] ?? $0 }
            if !merged.groups.contains(copy) { merged.groups.append(copy) }
        }
        let prepared = incoming.snippets.map { snippet -> Snippet in
            var copy = snippet; copy.groupID = snippet.groupID.map { groupMap[$0] ?? $0 }; return copy
        }
        var snippetMap: [UUID: UUID] = [:]
        for snippet in prepared {
            if let existing = merged.snippets.first(where: { $0.id == snippet.id }), existing != snippet { snippetMap[snippet.id] = UUID() }
        }
        // A reference to a remapped dependency also changes the importing parent, including cycles.
        changed = true
        while changed {
            changed = false
            for snippet in prepared where snippetMap[snippet.id] == nil {
                if let existing = merged.snippets.first(where: { $0.id == snippet.id }),
                   Self.remapSnippetReferences(snippet.content, using: snippetMap) != existing.content {
                    snippetMap[snippet.id] = UUID(); changed = true
                }
            }
        }
        for snippet in prepared {
            var copy = snippet
            copy.id = snippetMap[snippet.id] ?? snippet.id
            copy.content = Self.remapSnippetReferences(snippet.content, using: snippetMap)
            if merged.snippets.contains(copy) { continue }
            merged.snippets.append(copy)
        }
        if let importedTrash = incoming.trash {
            var trash = merged.trash ?? []
            for item in importedTrash {
                var copy = item
                copy.snippet.groupID = item.snippet.groupID.map { groupMap[$0] ?? $0 }
                copy.snippet.content = Self.remapSnippetReferences(item.snippet.content, using: snippetMap)
                if trash.contains(copy) { continue }
                if trash.contains(where: { $0.id == copy.id }) {
                    copy.id = UUID(); copy.snippet.id = copy.id
                }
                trash.append(copy)
            }
            merged.trash = trash
        }
        try Self.validate(merged)
        data = merged
        lastImportWarnings = warnings
    }

    private static func remapSnippetReferences(_ content: String, using ids: [UUID: UUID]) -> String {
        guard !ids.isEmpty else { return content }
        let pattern = try! NSRegularExpression(pattern: #"\{\{snippet:([0-9a-fA-F-]{36})\}\}"#)
        let text = NSMutableString(string: content)
        for match in pattern.matches(in: content, range: NSRange(content.startIndex..., in: content)).reversed() {
            guard let range = Range(match.range(at: 1), in: content), let oldID = UUID(uuidString: String(content[range])), let newID = ids[oldID] else { continue }
            text.replaceCharacters(in: match.range(at: 1), with: newID.uuidString)
        }
        return text as String
    }

    func isEnabled(_ snippet: Snippet, appID: String) -> Bool {
        guard snippet.enabled, !data.paused, !data.excludedApps.contains(appID) else { return false }
        switch snippet.appScope {
        case .only: guard snippet.apps.contains(appID) else { return false }
        case .except: guard !snippet.apps.contains(appID) else { return false }
        case .all: break
        }
        var groupID = snippet.groupID
        var visited: Set<UUID> = []
        while let id = groupID {
            guard visited.insert(id).inserted,
                  let group = data.groups.first(where: { $0.id == id }), group.enabled else { return false }
            groupID = group.parentID
        }
        return true
    }

    func match(in buffer: String, appID: String, manual: Bool = false) -> ExpansionMatch? {
        var best: ExpansionMatch?
        var bestLength = 0
        for snippet in data.snippets {
            guard isEnabled(snippet, appID: appID) else { continue }
            var candidate = buffer
            var delimiter = ""
            if !manual {
                switch snippet.trigger {
                case .manual: continue
                case .delimiterKeep, .delimiterDiscard:
                    guard let last = candidate.last, data.delimiters.contains(last) else { continue }
                    delimiter = String(candidate.removeLast())
                case .immediate: break
                }
            }
            for abbreviation in snippet.allAbbreviations {
                let length = abbreviation.count
                guard length > bestLength, candidate.count >= length else { continue }
                let typed = String(candidate.suffix(length))
                let same = snippet.caseSensitive ? typed == abbreviation : typed.compare(abbreviation, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
                guard same else { continue }
                let preceding = candidate.dropLast(length).last
                if snippet.wholeWord, let preceding, Self.wordCharacter(preceding) { continue }
                best = ExpansionMatch(snippet: snippet, deleteCount: length + delimiter.count,
                                      typedAbbreviation: typed,
                                      trailingDelimiter: snippet.trigger == .delimiterKeep ? delimiter : "")
                bestLength = length
            }
        }
        return best
    }

    private static func wordCharacter(_ char: Character) -> Bool {
        char == "_" || char.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) }
    }

    private static func encode(_ library: LibraryData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(LibraryDocument(data: library))
        guard bytes.count <= maximumFileBytes else { throw LibraryError.invalid("Documento troppo grande (massimo 64 MB).") }
        return bytes
    }

    private static func readLimited(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? 0) <= maximumFileBytes else {
            throw LibraryError.invalid("Il file deve essere un documento regolare di massimo 64 MB.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard bytes.count <= maximumFileBytes else { throw LibraryError.invalid("Documento troppo grande (massimo 64 MB).") }
        return bytes
    }

    private static func decodeJSON(_ bytes: Data) throws -> LibraryData {
        guard bytes.count <= maximumFileBytes else { throw LibraryError.invalid("Documento troppo grande (massimo 64 MB).") }
        let document = try JSONDecoder().decode(LibraryDocument.self, from: bytes)
        guard document.format == "EspansoLocale", document.version == 1 else { throw LibraryError.invalid("Formato o versione JSON non supportati.") }
        try validate(document.data)
        return document.data
    }

    private static func validate(_ library: LibraryData) throws {
        guard library.syncFolder == nil || (library.syncFolder!.utf8.count <= 8192 && (library.syncFolder! as NSString).expandingTildeInPath.hasPrefix("/")) else { throw LibraryError.invalid("La cartella di sincronizzazione deve avere un percorso assoluto.") }
        guard (1...525_600).contains(library.backupIntervalMinutes ?? 1440),
              (1...10_000).contains(library.backupRetention ?? 100),
              library.backupFolder == nil || (library.backupFolder!.utf8.count <= 8192 && (library.backupFolder! as NSString).expandingTildeInPath.hasPrefix("/")) else {
            throw LibraryError.invalid("Impostazioni backup non valide: intervallo 1–525600 minuti, conservazione 1–10000 e cartella assoluta.")
        }
        guard library.groups.count <= 10_000, library.snippets.count <= 100_000,
              (library.trash?.count ?? 0) <= 100_000, library.excludedApps.count <= 10_000,
              library.delimiters.utf8.count <= 65_536 else { throw LibraryError.invalid("Libreria oltre i limiti di dimensione supportati.") }
        guard Set(library.snippets.map(\.id)).count == library.snippets.count,
              Set(library.groups.map(\.id)).count == library.groups.count else { throw LibraryError.invalid("Identificatori duplicati nella libreria.") }
        let trash = library.trash ?? []
        guard Set(trash.map(\.id)).count == trash.count,
              trash.allSatisfy({ $0.id == $0.snippet.id && $0.deletedAt.timeIntervalSince1970.isFinite }) else { throw LibraryError.invalid("Cestino con identificatori duplicati o dati non validi.") }
        var totalTextBytes = 0
        for snippet in library.snippets + trash.map(\.snippet) {
            guard snippet.hotkeyCode == nil || (0...127).contains(snippet.hotkeyCode!), snippet.useCount >= 0,
                  snippet.content.utf8.count <= 16 * 1024 * 1024, snippet.title.utf8.count <= 65_536,
                  snippet.abbreviation.utf8.count <= 65_536, snippet.notes.utf8.count <= 1024 * 1024,
                  snippet.apps.count <= 10_000, snippet.apps.allSatisfy({ $0.utf8.count <= 4096 }) else {
                throw LibraryError.invalid("Frammento troppo grande, conteggio negativo o scorciatoia non valida.")
            }
            guard (snippet.aliases?.count ?? 0) <= 10_000, snippet.aliases?.allSatisfy({ $0.utf8.count <= 65_536 }) != false,
                  (snippet.atextSourceJSON?.utf8.count ?? 0) <= 16 * 1024 * 1024 else { throw LibraryError.invalid("Alias o metadati del frammento troppo grandi.") }
            totalTextBytes += snippet.content.utf8.count + snippet.notes.utf8.count + snippet.title.utf8.count + snippet.abbreviation.utf8.count
            totalTextBytes += (snippet.aliases ?? []).reduce(0) { $0 + $1.utf8.count } + (snippet.atextSourceJSON?.utf8.count ?? 0)
            guard totalTextBytes <= maximumFileBytes else { throw LibraryError.invalid("Contenuti complessivi oltre il limite di 64 MB.") }
        }
        for group in library.groups {
            totalTextBytes += group.atextSourceJSON?.utf8.count ?? 0
            guard totalTextBytes <= maximumFileBytes else { throw LibraryError.invalid("Metadati complessivi oltre il limite di 64 MB.") }
        }
        guard library.groups.allSatisfy({ $0.name.utf8.count <= 65_536 && ($0.atextSourceJSON?.utf8.count ?? 0) <= 16 * 1024 * 1024 }),
              library.excludedApps.allSatisfy({ $0.utf8.count <= 4096 }) else { throw LibraryError.invalid("Nome di gruppo o applicazione troppo lungo.") }
        let groups = Dictionary(uniqueKeysWithValues: library.groups.map { ($0.id, $0) })
        var resolved: Set<UUID> = []
        for group in library.groups {
            var next: UUID? = group.id
            var seen: Set<UUID> = []
            while let id = next, !resolved.contains(id) {
                guard seen.insert(id).inserted, let item = groups[id] else { throw LibraryError.invalid("Gruppi ciclici o riferimenti mancanti.") }
                next = item.parentID
            }
            resolved.formUnion(seen)
        }
        guard library.snippets.allSatisfy({ $0.groupID == nil || groups[$0.groupID!] != nil }) else { throw LibraryError.invalid("Un frammento fa riferimento a un gruppo mancante.") }
    }

    private static let csvHeaders = ["type", "id", "title", "abbreviation", "content", "kind", "trigger", "groupID", "parentID", "caseSensitive", "wholeWord", "adaptCase", "enabled", "appScope", "apps", "hotkeyCode", "hotkeyModifiers", "notes", "useCount", "aliases", "atextSourceJSON"]

    private static func encodeCSV(_ library: LibraryData) throws -> String {
        // CSV is an interchange table for active snippets and groups; JSON preserves trash/settings.
        var rows = [csvHeaders]
        for group in library.groups {
            var row = Array(repeating: "", count: csvHeaders.count)
            row[0] = "group"; row[1] = group.id.uuidString; row[2] = group.name
            row[8] = group.parentID?.uuidString ?? ""; row[12] = String(group.enabled)
            row[20] = group.atextSourceJSON ?? ""
            rows.append(row)
        }
        for s in library.snippets {
            let apps = String(data: try JSONEncoder().encode(s.apps), encoding: .utf8)!
            let aliases = try s.aliases.map { String(data: try JSONEncoder().encode($0), encoding: .utf8)! } ?? ""
            rows.append(["snippet", s.id.uuidString, s.title, s.abbreviation, s.content, s.kind.rawValue, s.trigger.rawValue,
                         s.groupID?.uuidString ?? "", "", String(s.caseSensitive), String(s.wholeWord), String(s.adaptCase),
                         String(s.enabled), s.appScope.rawValue, apps, s.hotkeyCode.map(String.init) ?? "", String(s.hotkeyModifiers), s.notes, String(s.useCount), aliases, s.atextSourceJSON ?? ""])
        }
        return rows.map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    private static func parseCSV(_ text: String) throws -> [[String]] {
        guard text.utf8.count <= maximumFileBytes else { throw LibraryError.invalid("CSV troppo grande (massimo 64 MB).") }
        let chars = Array(text)
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false, closed = false, index = 0
        while index < chars.count {
            let c = chars[index]
            if quoted {
                if c == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" { cell.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { cell.append(c) }
            } else if c == "," {
                guard row.count < 256 else { throw LibraryError.invalid("CSV con troppe colonne (massimo 256).") }
                row.append(cell); cell = ""; closed = false
            }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                guard rows.count < 110_001 else { throw LibraryError.invalid("CSV con troppe righe.") }
                row.append(cell); rows.append(row); row = []; cell = ""; closed = false
                if c == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
            }
            else if c == "\"", cell.isEmpty, !closed { quoted = true }
            else {
                guard !closed, c != "\"" else { throw LibraryError.invalid("CSV con virgolette non valide.") }
                cell.append(c)
            }
            index += 1
        }
        guard !quoted else { throw LibraryError.invalid("CSV con campo tra virgolette incompleto.") }
        if !cell.isEmpty || !row.isEmpty || closed { row.append(cell); rows.append(row) }
        return rows
    }

    private static func decodeCSV(_ text: String) throws -> LibraryData {
        let rows = try parseCSV(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard let headers = rows.first, Set(headers).count == headers.count,
              headers.contains("abbreviation"), headers.contains("content") else { throw LibraryError.invalid("Il CSV richiede le colonne abbreviation e content.") }
        var result = LibraryData()
        for row in rows.dropFirst() where row != [""] {
            guard row.count == headers.count else { throw LibraryError.invalid("CSV: numero di colonne incoerente.") }
            let value = Dictionary(uniqueKeysWithValues: zip(headers, row))
            func uuid(_ key: String) throws -> UUID? {
                guard let raw = value[key], !raw.isEmpty else { return nil }
                guard let id = UUID(uuidString: raw) else { throw LibraryError.invalid("CSV: UUID non valido in \(key).") }
                return id
            }
            func bool(_ key: String, _ fallback: Bool) throws -> Bool {
                guard let raw = value[key], !raw.isEmpty else { return fallback }
                switch raw.lowercased() { case "true", "1": return true; case "false", "0": return false; default: throw LibraryError.invalid("CSV: booleano non valido in \(key).") }
            }
            if value["type"] == "group" {
                result.groups.append(SnippetGroup(id: try uuid("id") ?? UUID(), name: value["title"] ?? "Gruppo", parentID: try uuid("parentID"), enabled: try bool("enabled", true), atextSourceJSON: value["atextSourceJSON"].flatMap { $0.isEmpty ? nil : $0 }))
                continue
            }
            if let type = value["type"], !type.isEmpty, type != "snippet" { throw LibraryError.invalid("CSV: tipo di riga sconosciuto.") }
            var snippet = Snippet()
            snippet.id = try uuid("id") ?? UUID(); snippet.title = value["title"] ?? value["abbreviation"] ?? "Frammento"
            snippet.abbreviation = value["abbreviation"] ?? ""; snippet.content = value["content"] ?? ""
            snippet.groupID = try uuid("groupID")
            if let raw = value["kind"], !raw.isEmpty {
                guard let kind = SnippetKind(rawValue: raw) else { throw LibraryError.invalid("CSV: tipo contenuto sconosciuto.") }; snippet.kind = kind
            }
            if let raw = value["trigger"], !raw.isEmpty {
                guard let trigger = TriggerMode(rawValue: raw) else { throw LibraryError.invalid("CSV: attivazione sconosciuta.") }; snippet.trigger = trigger
            }
            if let raw = value["appScope"], !raw.isEmpty {
                guard let scope = AppScope(rawValue: raw) else { throw LibraryError.invalid("CSV: ambito sconosciuto.") }; snippet.appScope = scope
            }
            snippet.caseSensitive = try bool("caseSensitive", false); snippet.wholeWord = try bool("wholeWord", true)
            snippet.adaptCase = try bool("adaptCase", false); snippet.enabled = try bool("enabled", true)
            if let raw = value["apps"], !raw.isEmpty { snippet.apps = try JSONDecoder().decode([String].self, from: Data(raw.utf8)) }
            if let raw = value["hotkeyCode"], !raw.isEmpty {
                guard let number = Int(raw), (0...127).contains(number) else { throw LibraryError.invalid("CSV: codice scorciatoia non valido.") }; snippet.hotkeyCode = number
            }
            if let raw = value["hotkeyModifiers"], !raw.isEmpty {
                guard let number = UInt32(raw) else { throw LibraryError.invalid("CSV: modificatori non validi.") }; snippet.hotkeyModifiers = number
            }
            if let raw = value["useCount"], !raw.isEmpty {
                guard let number = Int(raw), number >= 0 else { throw LibraryError.invalid("CSV: conteggio non valido.") }; snippet.useCount = number
            }
            snippet.notes = value["notes"] ?? ""
            if let raw = value["aliases"], !raw.isEmpty { snippet.aliases = try JSONDecoder().decode([String].self, from: Data(raw.utf8)) }
            snippet.atextSourceJSON = value["atextSourceJSON"].flatMap { $0.isEmpty ? nil : $0 }
            result.snippets.append(snippet)
        }
        return result
    }

    private static func decodeTextExpander(_ bytes: Data) throws -> LibraryData {
        let object = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
        guard let root = object as? [String: Any] else { throw LibraryError.invalid("Plist TextExpander non valido.") }
        var library = LibraryData()
        func appendGroup(_ dict: [String: Any]) throws {
            guard let snippets = dict["snippetsTE"] as? [[String: Any]] ?? dict["snippets"] as? [[String: Any]] else { throw LibraryError.invalid("Gruppo TextExpander privo di frammenti riconoscibili.") }
            let group = SnippetGroup(name: dict["name"] as? String ?? "TextExpander")
            library.groups.append(group)
            for item in snippets {
                guard let abbreviation = item["abbreviation"] as? String, let content = item["plainText"] as? String ?? item["content"] as? String else { throw LibraryError.invalid("Frammento TextExpander non testuale o non riconosciuto. Nessun dato importato.") }
                var snippet = Snippet(title: item["label"] as? String ?? abbreviation, abbreviation: abbreviation, groupID: group.id, content: content)
                snippet.notes = "Importato da plist TextExpander. Le macro specifiche di TextExpander restano testo da verificare."
                // Rich data and script formats cannot be translated faithfully; reject them explicitly.
                if let type = item["snippetType"] as? Int, type != 0 { throw LibraryError.invalid("Il plist contiene formati TextExpander non testuali. Esporta i frammenti come CSV per convertirli.") }
                library.snippets.append(snippet)
            }
        }
        if let groups = root["groups"] as? [[String: Any]] { for group in groups { try appendGroup(group) } }
        else { try appendGroup(root) }
        return library
    }
}

struct RenderContext {
    var date = Date()
    var clipboard = ""
    var selection = ""
    var variables: [String: String] = [:]
    var fieldTruth: [String: Bool] = [:]
    var lookup: ((String) -> String?)? = nil
}

struct RenderedText {
    var text: String
    var cursorOffset: Int?
    var fields: [String]
    var fieldSpecs: [TemplateField] = []
}

struct TemplateField: Equatable {
    enum Kind { case text, multiline, choice, checkbox, date }
    var name: String
    var kind: Kind = .text
    var defaultValue = ""
    var options: [String] = []
    var dateFormat = "yyyy-MM-dd"
}

struct TemplateRenderer {
    func render(_ content: String, context: RenderContext) throws -> RenderedText {
        guard content.utf8.count <= 4_000_000 else { throw LibraryError.invalid("Modello troppo grande (massimo 4 MB).") }
        var fields: [String] = []
        var fieldSpecs: [TemplateField] = []
        var cursorOffset: Int?
        var output = ""
        let cursorMarker = "\u{E000}\(UInt64.random(in: .min ... .max))\u{E001}"
        func dateString(_ argument: String, defaultFormat: String) throws -> String {
            var parts = Self.arguments(argument)
            var date = context.date
            var offset: (Calendar.Component, Int)?
            if let first = parts.first, first.range(of: "^[+-][0-9]+[yMwdhms]$", options: .regularExpression) != nil {
                let suffix = first.last!
                guard let amount = Int(first.dropLast()), abs(Double(amount)) <= 1_000_000 else { throw LibraryError.invalid("Offset data non valido.") }
                let component: Calendar.Component = ["y": .year, "M": .month, "w": .weekOfYear, "d": .day, "h": .hour, "m": .minute, "s": .second][suffix]!
                offset = (component, amount); parts.removeFirst()
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: parts.count > 1 && !parts[1].isEmpty ? parts[1] : "it_IT")
            var calendar = Calendar.current
            if parts.count > 2, !parts[2].isEmpty {
                guard let zone = TimeZone(identifier: parts[2]) else { throw LibraryError.invalid("Fuso orario sconosciuto: \(parts[2])") }
                formatter.timeZone = zone; calendar.timeZone = zone
            }
            formatter.calendar = calendar
            if let offset {
                guard let shifted = calendar.date(byAdding: offset.0, value: offset.1, to: date) else { throw LibraryError.invalid("Data fuori intervallo.") }
                date = shifted
            }
            formatter.dateFormat = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? defaultFormat
            return formatter.string(from: date)
        }
        func expand(_ input: String, stack: [String], depth: Int) throws -> String {
            guard depth <= 16 else { throw LibraryError.invalid("Modello troppo annidato (massimo 16 livelli).") }
            var result = "", resultBytes = 0, index = input.startIndex
            while index < input.endIndex {
                guard input[index...].hasPrefix("{{") else {
                    let char = input[index]; resultBytes += String(char).utf8.count
                    guard resultBytes <= 4_000_000 else { throw LibraryError.invalid("Espansione troppo grande (massimo 4 MB).") }
                    result.append(char); index = input.index(after: index); continue
                }
                let start = input.index(index, offsetBy: 2)
                var end = start, nesting = 1
                while end < input.endIndex {
                    if input[end...].hasPrefix("{{") { nesting += 1; end = input.index(end, offsetBy: 2) }
                    else if input[end...].hasPrefix("}}") {
                        nesting -= 1
                        if nesting == 0 { break }
                        end = input.index(end, offsetBy: 2)
                    } else { end = input.index(after: end) }
                }
                guard nesting == 0 else { throw LibraryError.invalid("Token non chiuso nel modello.") }
                let raw = String(input[start..<end])
                let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0]), argument = parts.count > 1 ? String(parts[1]) : ""
                let replacement: String
                switch name {
                case "date": replacement = try dateString(argument, defaultFormat: "yyyy-MM-dd")
                case "time": replacement = try dateString(argument, defaultFormat: "HH:mm")
                case "clipboard": replacement = context.clipboard
                case "selection": replacement = context.selection
                case "uuid": replacement = UUID().uuidString
                case "cursor":
                    // Cursor offset is carried as a private marker until all transformations finish.
                    replacement = cursorMarker
                case "field", "multiline", "choice", "check", "datefield":
                    let args = Self.arguments(argument)
                    let fieldName = (args.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !fieldName.isEmpty, fieldName.count <= 200 else { throw LibraryError.invalid("Un campo richiede un nome di massimo 200 caratteri.") }
                    var spec = TemplateField(name: fieldName)
                    switch name {
                    case "multiline": spec.kind = .multiline; spec.defaultValue = args.count > 1 ? args[1] : ""
                    case "choice":
                        guard (2...101).contains(args.count) else { throw LibraryError.invalid("Una scelta richiede da 1 a 100 opzioni: {{choice:Nome|Uno|Due}}.") }
                        spec.kind = .choice; spec.options = Array(args.dropFirst()); spec.defaultValue = spec.options[0]
                    case "check":
                        guard args.count == 1 || args.count == 3 else { throw LibraryError.invalid("Usa {{check:Nome|Sì|No}}.") }
                        spec.kind = .checkbox; spec.options = args.count == 3 ? Array(args.dropFirst()) : ["sì", "no"]
                    case "datefield": spec.kind = .date; spec.dateFormat = args.count > 1 && !args[1].isEmpty ? args[1] : "yyyy-MM-dd"
                    default: spec.defaultValue = args.count > 1 ? args[1] : ""
                    }
                    if let existing = fieldSpecs.first(where: { $0.name == fieldName }), existing != spec { throw LibraryError.invalid("Il campo \(fieldName) ha definizioni diverse nel frammento.") }
                    if !fieldSpecs.contains(where: { $0.name == fieldName }) { fieldSpecs.append(spec) }
                    if let value = context.variables[fieldName] { replacement = value }
                    else {
                        guard fields.count < 50 || fields.contains(fieldName) else { throw LibraryError.invalid("Massimo 50 campi per frammento.") }
                        if !fields.contains(fieldName) { fields.append(fieldName) }
                        replacement = "{{\(raw)}}"
                    }
                case "var": replacement = context.variables[argument] ?? ""
                case "if":
                    let args = Self.arguments(argument)
                    guard args.count == 3 else { throw LibraryError.invalid("Usa {{if:Nome|testo se vero|testo se falso}}.") }
                    let value = (context.variables[args[0]] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let condition = context.fieldTruth[args[0]] ?? (!value.isEmpty && !["0", "false", "no"].contains(value))
                    replacement = try expand(args[condition ? 1 : 2], stack: stack, depth: depth + 1)
                case "snippet":
                    guard !stack.contains(argument), let found = context.lookup?(argument) else { throw LibraryError.invalid("Frammento annidato mancante o ciclico: \(argument)") }
                    replacement = try expand(found, stack: stack + [argument], depth: depth + 1)
                case "upper": replacement = try expand(argument, stack: stack, depth: depth + 1).uppercased()
                case "lower": replacement = try expand(argument, stack: stack, depth: depth + 1).lowercased()
                case "title": replacement = try expand(argument, stack: stack, depth: depth + 1).capitalized
                case "trim": replacement = try expand(argument, stack: stack, depth: depth + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                case "length": replacement = String(try expand(argument, stack: stack, depth: depth + 1).count)
                case "replace", "regex":
                    let args = Self.arguments(argument)
                    guard args.count == 3 else { throw LibraryError.invalid("Usa {{\(name):cerca|sostituisci|testo}}.") }
                    let text = try expand(args[2], stack: stack, depth: depth + 1)
                    let search = try expand(args[0], stack: stack, depth: depth + 1)
                    let substituted = try expand(args[1], stack: stack, depth: depth + 1)
                    if name == "replace" { replacement = try Self.literalReplace(text, search: search, replacement: substituted) }
                    else { replacement = try Self.regexReplace(text, pattern: search, replacement: substituted) }
                case "urlencode":
                    let text = try expand(argument, stack: stack, depth: depth + 1)
                    replacement = text.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text
                case "urldecode":
                    let text = try expand(argument, stack: stack, depth: depth + 1)
                    guard let decoded = text.removingPercentEncoding else { throw LibraryError.invalid("Codifica URL non valida.") }; replacement = decoded
                case "base64": replacement = Data(try expand(argument, stack: stack, depth: depth + 1).utf8).base64EncodedString()
                case "unbase64":
                    guard let bytes = Data(base64Encoded: try expand(argument, stack: stack, depth: depth + 1)), let decoded = String(data: bytes, encoding: .utf8) else { throw LibraryError.invalid("Base64 non valido o non UTF-8.") }; replacement = decoded
                case "calc": replacement = try SafeArithmetic.evaluate(argument)
                default: replacement = "{{\(raw)}}"
                }
                resultBytes += replacement.utf8.count
                guard resultBytes <= 4_000_000 else { throw LibraryError.invalid("Espansione troppo grande (massimo 4 MB).") }
                result += replacement
                index = input.index(end, offsetBy: 2)
            }
            return result
        }
        output = try expand(content, stack: [], depth: 0)
        if let marker = output.range(of: cursorMarker) { cursorOffset = output[..<marker.lowerBound].count }
        output = output.replacingOccurrences(of: cursorMarker, with: "")
        return RenderedText(text: output, cursorOffset: cursorOffset, fields: fields, fieldSpecs: fieldSpecs)
    }

    // Pipes inside nested tokens belong to that token, not its enclosing transform.
    private static func arguments(_ string: String) -> [String] {
        var result: [String] = [], item = "", depth = 0, index = string.startIndex
        while index < string.endIndex {
            let next = string.index(after: index)
            if depth == 0, string[index] == "\\", next < string.endIndex, string[next] == "|" || string[next] == "\\" { item.append(string[next]); index = string.index(after: next) }
            else if string[index...].hasPrefix("{{") { depth += 1; item += "{{"; index = string.index(index, offsetBy: 2) }
            else if string[index...].hasPrefix("}}"), depth > 0 { depth -= 1; item += "}}"; index = string.index(index, offsetBy: 2) }
            else { let char = string[index]; if char == "|" && depth == 0 { result.append(item); item = "" } else { item.append(char) }; index = string.index(after: index) }
        }
        result.append(item); return result
    }

    private static func append(_ text: String, to result: inout String, bytes: inout Int) throws {
        bytes += text.utf8.count
        guard bytes <= 4_000_000 else { throw LibraryError.invalid("Trasformazione troppo grande (massimo 4 MB).") }
        result += text
    }

    private static func literalReplace(_ text: String, search: String, replacement: String) throws -> String {
        guard !search.isEmpty else { return text }
        var result = "", bytes = 0, index = text.startIndex
        while let range = text.range(of: search, range: index..<text.endIndex) {
            try append(String(text[index..<range.lowerBound]), to: &result, bytes: &bytes)
            try append(replacement, to: &result, bytes: &bytes); index = range.upperBound
        }
        try append(String(text[index...]), to: &result, bytes: &bytes); return result
    }

    private static func regexReplace(_ text: String, pattern: String, replacement: String) throws -> String {
        guard text.utf16.count <= 65_536, pattern.utf16.count <= 1024 else { throw LibraryError.invalid("Regex: massimo 64K caratteri di testo e 1024 di espressione.") }
        let regex = try NSRegularExpression(pattern: pattern)
        let deadline = Date().addingTimeInterval(0.2)
        var matches: [NSTextCheckingResult] = [], interrupted = false
        regex.enumerateMatches(in: text, options: .reportProgress, range: NSRange(text.startIndex..., in: text)) { match, flags, stop in
            if flags.contains(.internalError) || Date() > deadline || matches.count >= 10_000 { interrupted = true; stop.pointee = true }
            else if let match { matches.append(match) }
        }
        guard !interrupted else { throw LibraryError.invalid("Trasformazione regex troppo complessa.") }
        let source = text as NSString
        var result = "", bytes = 0, cursor = 0
        for match in matches {
            try append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), to: &result, bytes: &bytes)
            try append(regex.replacementString(for: match, in: text, offset: 0, template: replacement), to: &result, bytes: &bytes)
            cursor = match.range.location + match.range.length
        }
        try append(source.substring(from: cursor), to: &result, bytes: &bytes); return result
    }
}

// A small arithmetic grammar; no script engine, expressions, or function calls are evaluated.
private struct SafeArithmetic {
    var characters: [Character]
    var index = 0
    static func evaluate(_ input: String) throws -> String {
        guard input.count <= 1024 else { throw LibraryError.invalid("Calcolo troppo lungo.") }
        var parser = SafeArithmetic(characters: Array(input))
        let value = try parser.expression(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.characters.count, value.isFinite else { throw LibraryError.invalid("Calcolo non valido.") }
        return value.rounded() == value && abs(value) < 1e16 ? String(format: "%.0f", value) : String(value)
    }
    mutating func skipWhitespace() {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
    }
    mutating func consume(_ char: Character) -> Bool {
        skipWhitespace()
        guard index < characters.count, characters[index] == char else { return false }; index += 1; return true
    }
    mutating func expression(depth: Int) throws -> Double {
        var value = try term(depth: depth)
        while index < characters.count {
            if consume("+") { value += try term(depth: depth) }
            else if consume("-") { value -= try term(depth: depth) }
            else { break }
        }
        return value
    }
    mutating func term(depth: Int) throws -> Double {
        var value = try number(depth: depth)
        while index < characters.count {
            if consume("*") { value *= try number(depth: depth) }
            else if consume("/") {
                let divisor = try number(depth: depth)
                guard divisor != 0 else { throw LibraryError.invalid("Divisione per zero.") }; value /= divisor
            } else { break }
        }
        return value
    }
    mutating func number(depth: Int) throws -> Double {
        guard depth < 32 else { throw LibraryError.invalid("Calcolo troppo annidato.") }
        skipWhitespace()
        if consume("+") { return try number(depth: depth + 1) }
        if consume("-") { return try -number(depth: depth + 1) }
        if consume("(") {
            let value = try expression(depth: depth + 1)
            guard consume(")") else { throw LibraryError.invalid("Parentesi mancante nel calcolo.") }; return value
        }
        let start = index
        while index < characters.count, characters[index].isASCII && (characters[index].isNumber || characters[index] == ".") { index += 1 }
        guard let value = Double(String(characters[start..<index])) else { throw LibraryError.invalid("Numero non valido nel calcolo.") }
        return value
    }
}
