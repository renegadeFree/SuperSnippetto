import Foundation
import Combine
import CryptoKit

// Native format only. A cloud provider may replicate this folder; this class never makes network requests.
private struct FolderRevision: Codable, Equatable {
    var counter: UInt64
    var device: String
}

// Usage statistics stay on each device. The wire type deliberately omits Snippet.useCount.
private struct FolderSnippet: Codable, Equatable {
    var id: UUID
    var title: String
    var abbreviation: String
    var groupID: UUID?
    var content: String
    var kind: SnippetKind
    var trigger: TriggerMode
    var caseSensitive: Bool
    var wholeWord: Bool
    var adaptCase: Bool
    var enabled: Bool
    var appScope: AppScope
    var apps: [String]
    var hotkeyCode: Int?
    var hotkeyModifiers: UInt32
    var notes: String
    var aliases: [String]?
    var atextSourceJSON: String?

    init(_ snippet: Snippet) {
        id = snippet.id; title = snippet.title; abbreviation = snippet.abbreviation
        groupID = snippet.groupID; content = snippet.content; kind = snippet.kind; trigger = snippet.trigger
        caseSensitive = snippet.caseSensitive; wholeWord = snippet.wholeWord; adaptCase = snippet.adaptCase
        enabled = snippet.enabled; appScope = snippet.appScope; apps = snippet.apps
        hotkeyCode = snippet.hotkeyCode; hotkeyModifiers = snippet.hotkeyModifiers; notes = snippet.notes
        aliases = snippet.aliases; atextSourceJSON = snippet.atextSourceJSON
    }
    func local(useCount: Int) -> Snippet {
        Snippet(id: id, title: title, abbreviation: abbreviation, groupID: groupID, content: content,
                kind: kind, trigger: trigger, caseSensitive: caseSensitive, wholeWord: wholeWord,
                adaptCase: adaptCase, enabled: enabled, appScope: appScope, apps: apps,
                hotkeyCode: hotkeyCode, hotkeyModifiers: hotkeyModifiers, notes: notes, useCount: useCount,
                aliases: aliases, atextSourceJSON: atextSourceJSON)
    }
}

private struct FolderTrash: Codable, Equatable {
    var id: UUID
    var snippet: FolderSnippet
    var deletedAt: Date
    init(_ item: TrashedSnippet) { id = item.id; snippet = FolderSnippet(item.snippet); deletedAt = item.deletedAt }
}

private struct FolderValue: Codable, Equatable {
    var group: SnippetGroup?
    var snippet: FolderSnippet?
    var trash: FolderTrash?

    var key: String {
        if let group { return "g:" + group.id.uuidString }
        if let snippet { return "s:" + snippet.id.uuidString }
        return "t:" + trash!.id.uuidString
    }
    func conflict(id: UUID) -> Self {
        var copy = self
        if copy.group != nil { copy.group!.id = id; if copy.group!.name.utf8.count < 65_520 { copy.group!.name += " (conflitto)" } }
        if copy.snippet != nil { copy.snippet!.id = id; if copy.snippet!.title.utf8.count < 65_520 { copy.snippet!.title += " (conflitto)" } }
        if copy.trash != nil {
            copy.trash!.id = id; copy.trash!.snippet.id = id
            if copy.trash!.snippet.title.utf8.count < 65_520 { copy.trash!.snippet.title += " (conflitto)" }
        }
        return copy
    }
}

private struct FolderVersion: Codable, Equatable {
    var revision: FolderRevision
    // A causal frontier, including this event. Lamport timestamps alone cannot detect concurrent edits.
    var seen: [String: UInt64]
    var value: FolderValue? // nil is a persistent tombstone, never garbage-collected automatically.
}

private struct FolderDocument: Codable, Equatable {
    var format = "EspansoLocaleFolderSync"
    var version = 1
    var records: [String: FolderVersion] = [:]
}

private struct FolderState: Codable {
    var format = "EspansoLocaleFolderSyncState"
    var version = 1
    var device = UUID().uuidString
    var counter: UInt64 = 0
    var document = FolderDocument()
    var baseline: [String: String] = [:]
    // Journal marker: the remote write succeeded, but local save/sidecar commit may have been interrupted.
    var pendingTarget: [String: String]?
}

final class LibraryFolderSync: ObservableObject {
    @Published var status = "Sincronizzazione disattivata"
    @Published var lastError: String?
    private(set) var folderURL: URL?
    private let store: LibraryStore
    private let stateDirectory: URL
    private var timer: Timer?
    private var syncing = false
    private static let limit = 16 * 1024 * 1024
    private static let sharedName = "EspansoLocale.sync.json"

    init(store: LibraryStore, stateDirectory: URL? = nil) {
        self.store = store
        self.stateDirectory = stateDirectory ?? store.fileURL.deletingLastPathComponent()
        if let path = store.data.syncFolder, !path.isEmpty {
            folderURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            status = "Sincronizzazione pronta"
        }
    }

    deinit { timer?.invalidate() }

    func configure(folder: URL?) throws {
        precondition(Thread.isMainThread)
        let selected = folder?.standardizedFileURL
        if let selected {
            guard selected.isFileURL,
                  (try selected.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw LibraryError.invalid("Scegli una cartella locale esistente o una cartella del tuo provider cloud.")
            }
        }
        let previous = store.data.syncFolder
        store.data.syncFolder = selected?.path
        do { try store.save() }
        catch { store.data.syncFolder = previous; throw error }
        stop(); folderURL = selected; lastError = nil
        if selected != nil { start(); try syncNow() }
        else { status = "Sincronizzazione disattivata" }
    }

    func start() {
        precondition(Thread.isMainThread)
        guard folderURL != nil, timer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            do { try self.syncNow() } catch { /* syncNow publishes the actionable error. */ }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    func syncNow() throws {
        precondition(Thread.isMainThread)
        guard let folderURL, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            guard let configured = store.data.syncFolder,
                  URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL.path == folderURL.path else {
                stop()
                throw Self.invalid("La destinazione salvata è cambiata. Riconfigura la sincronizzazione prima di riprovare.")
            }
            guard (try folderURL.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw LibraryError.invalid("La cartella di sincronizzazione non è disponibile.")
            }
            try synchronize(in: folderURL)
            lastError = nil; status = "Sincronizzato · formato SuperSnippetto"
        } catch {
            lastError = error.localizedDescription
            status = "Sincronizzazione non riuscita"
            throw error
        }
    }

    private func synchronize(in folder: URL) throws {
        let identifier = Self.digest(Data(folder.path.utf8))
        let stateURL = stateDirectory.appendingPathComponent("folder-sync-\(identifier).json")
        let pendingURL = stateURL.appendingPathExtension("pending")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        var state: FolderState
        if FileManager.default.fileExists(atPath: stateURL.path) {
            state = try JSONDecoder().decode(FolderState.self, from: Self.read(stateURL))
            guard state.format == "EspansoLocaleFolderSyncState", state.version == 1,
                  UUID(uuidString: state.device) != nil else { throw Self.invalid("Stato locale sconosciuto.") }
            try Self.validate(state.document)
            try Self.validateHashes(state.baseline)
            if let pending = state.pendingTarget { try Self.validateHashes(pending) }
        } else { state = FolderState() }
        var current = try Self.snapshot(store.data)
        var hashes = try Self.hashes(current)
        let pending: FolderDocument?
        if FileManager.default.fileExists(atPath: pendingURL.path) {
            pending = try Self.decode(Self.read(pendingURL))
        } else {
            guard state.pendingTarget == nil else { throw Self.invalid("Journal locale mancante; non modificare i file di stato.") }
            pending = nil
        }
        // Complete an interrupted local commit before interpreting differences as new user edits.
        if let target = state.pendingTarget, let pending, target == hashes {
            state.document = pending
            state.baseline = hashes
            state.counter = max(state.counter, Self.maximumCounter(pending))
        }
        state.pendingTarget = nil
        state.counter = max(state.counter, Self.maximumCounter(state.document))
        var clock = Self.frontier(state.document)
        let keys = Set(hashes.keys).union(state.baseline.keys).sorted()
        for key in keys where hashes[key] != state.baseline[key] {
            guard state.counter < UInt64.max - 1 else { throw Self.invalid("Contatore revisioni esaurito.") }
            state.counter += 1; clock[state.device] = state.counter
            state.document.records[key] = FolderVersion(revision: FolderRevision(counter: state.counter, device: state.device), seen: clock, value: current[key])
        }
        // Persist captured local changes before publishing. Failed remote writes can retry the same revisions.
        state.baseline = hashes
        try Self.write(state, to: stateURL)

        let shared = folder.appendingPathComponent(Self.sharedName)
        var coordinationError: NSError?
        var operation: Result<Void, Error>?
        let writeOptions: NSFileCoordinator.WritingOptions = FileManager.default.fileExists(atPath: shared.path) ? .forReplacing : []
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: shared, options: writeOptions, error: &coordinationError) { coordinatedURL in
            operation = Result {
                let exists = FileManager.default.fileExists(atPath: coordinatedURL.path)
                let oldBytes = exists ? try Self.read(coordinatedURL) : nil
                let remote = try oldBytes.map(Self.decode) ?? FolderDocument()
                var merged = try Self.merge(state.document, pending ?? FolderDocument())
                merged = try Self.merge(merged, remote)
                try Self.validate(merged)
                let target = try Self.project(merged)
                let bytes = try Self.encode(merged)
                let localChanges = target != current
                let remoteChanges = oldBytes != bytes
                if !localChanges && !remoteChanges && pending == nil && state.document == merged { return }
                if localChanges || remoteChanges { _ = try store.createBackup() }
                if remoteChanges { try bytes.write(to: coordinatedURL, options: .atomic) }
                // Journal only after a successful remote commit. Baseline still describes local memory/disk.
                try Self.write(merged, to: pendingURL)
                state.pendingTarget = try Self.hashes(target)
                try Self.write(state, to: stateURL)
                if localChanges {
                    let previous = store.data
                    Self.apply(target, to: &store.data)
                    do { try store.save() }
                    catch { store.data = previous; throw error }
                }
                state.document = merged; state.baseline = state.pendingTarget!
                state.pendingTarget = nil
                state.counter = max(state.counter, Self.maximumCounter(merged))
                try Self.write(state, to: stateURL)
                try FileManager.default.removeItem(at: pendingURL)
                current = target; hashes = state.baseline
            }
        }
        if let coordinationError { throw coordinationError }
        guard let operation else { throw Self.invalid("Accesso coordinato alla cartella non riuscito.") }
        try operation.get()
    }

    private static func snapshot(_ data: LibraryData) throws -> [String: FolderValue] {
        var values: [String: FolderValue] = [:]
        for group in data.groups { try insert(FolderValue(group: group), into: &values) }
        for snippet in data.snippets { try insert(FolderValue(snippet: FolderSnippet(snippet)), into: &values) }
        for trash in data.trash ?? [] { try insert(FolderValue(trash: FolderTrash(trash)), into: &values) }
        return values
    }

    private static func insert(_ value: FolderValue, into values: inout [String: FolderValue]) throws {
        guard values.updateValue(value, forKey: value.key) == nil else { throw invalid("Identificatori duplicati nella libreria.") }
    }

    private static func hashes(_ values: [String: FolderValue]) throws -> [String: String] {
        try values.mapValues { digest(try encode($0)) }
    }

    private static func frontier(_ document: FolderDocument) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for version in document.records.values {
            for (device, counter) in version.seen { result[device] = max(result[device] ?? 0, counter) }
        }
        return result
    }

    private static func maximumCounter(_ document: FolderDocument) -> UInt64 { frontier(document).values.max() ?? 0 }

    private static func merge(_ left: FolderDocument, _ right: FolderDocument) throws -> FolderDocument {
        var output = left
        var queue = right.records.sorted { $0.key < $1.key }
        var index = 0
        while index < queue.count {
            guard index <= 500_000 else { throw invalid("Troppi conflitti nella sincronizzazione.") }
            let (key, incoming) = queue[index]; index += 1
            guard let existing = output.records[key] else { output.records[key] = incoming; continue }
            var winner: FolderVersion
            var conflict: FolderVersion?
            if existing.revision == incoming.revision {
                guard existing.value == incoming.value else { throw invalid("Revisioni identiche con contenuti diversi.") }
                winner = existing
            } else {
                let existingAfter = (existing.seen[incoming.revision.device] ?? 0) >= incoming.revision.counter
                let incomingAfter = (incoming.seen[existing.revision.device] ?? 0) >= existing.revision.counter
                guard !(existingAfter && incomingAfter) else { throw invalid("Cronologia delle revisioni incoerente.") }
                if existingAfter { winner = existing }
                else if incomingAfter { winner = incoming }
                else {
                    let incomingWins = incoming.revision.counter > existing.revision.counter ||
                        (incoming.revision.counter == existing.revision.counter && incoming.revision.device > existing.revision.device)
                    winner = incomingWins ? incoming : existing
                    let loser = incomingWins ? existing : incoming
                    if existing.value != incoming.value, loser.value != nil { conflict = loser }
                }
            }
            for item in [existing, incoming] {
                for (device, counter) in item.seen { winner.seen[device] = max(winner.seen[device] ?? 0, counter) }
            }
            output.records[key] = winner
            if var conflict, let value = conflict.value {
                let seed = Data(key.utf8) + (try encode(conflict.revision)) + (try encode(value))
                let id = uuid(from: SHA256.hash(data: seed))
                let copy = value.conflict(id: id)
                conflict.value = copy
                queue.append((copy.key, conflict))
            }
        }
        return output
    }

    private static func project(_ document: FolderDocument) throws -> [String: FolderValue] {
        var values = document.records.compactMapValues(\.value)
        var groups: [UUID: SnippetGroup] = [:]
        for value in values.values { if let group = value.group { groups[group.id] = group } }
        for (id, group) in groups {
            if let parent = group.parentID, groups[parent] == nil { groups[id]!.parentID = nil }
        }
        var resolved: Set<UUID> = []
        for id in groups.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !resolved.contains(id) {
            var path: [UUID] = [], positions: [UUID: Int] = [:], next: UUID? = id
            while let current = next, !resolved.contains(current) {
                if let position = positions[current] {
                    let root = path[position...].min { $0.uuidString < $1.uuidString }!
                    groups[root]!.parentID = nil
                    break
                }
                positions[current] = path.count; path.append(current)
                next = groups[current]?.parentID
            }
            resolved.formUnion(path)
        }
        for (key, var value) in values {
            if let group = value.group { value.group = groups[group.id] }
            if let group = value.snippet?.groupID, groups[group] == nil { value.snippet!.groupID = nil }
            if let group = value.trash?.snippet.groupID, groups[group] == nil { value.trash!.snippet.groupID = nil }
            values[key] = value
        }
        return values
    }

    private static func apply(_ values: [String: FolderValue], to data: inout LibraryData) {
        let ordered = values.keys.sorted().compactMap { values[$0] }
        var useCounts: [UUID: Int] = [:]
        for snippet in data.snippets + (data.trash ?? []).map(\.snippet) {
            useCounts[snippet.id] = max(useCounts[snippet.id] ?? 0, snippet.useCount)
        }
        data.groups = ordered.compactMap(\.group)
        data.snippets = ordered.compactMap(\.snippet).map { $0.local(useCount: useCounts[$0.id] ?? 0) }
        data.trash = ordered.compactMap(\.trash).map {
            TrashedSnippet(snippet: $0.snippet.local(useCount: useCounts[$0.id] ?? 0), deletedAt: $0.deletedAt)
        }
    }

    private static func validate(_ document: FolderDocument) throws {
        guard document.format == "EspansoLocaleFolderSync", document.version == 1,
              document.records.count <= 210_000 else { throw invalid("Formato, versione o dimensioni non supportati.") }
        for (key, record) in document.records {
            guard validKey(key), record.revision.counter > 0, record.revision.counter < UInt64.max,
                  UUID(uuidString: record.revision.device) != nil,
                  record.seen.count <= 4096,
                  record.seen[record.revision.device] == record.revision.counter,
                  record.seen.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value > 0 && $0.value <= record.revision.counter }) else {
                throw invalid("Record o revisione non validi.")
            }
            guard let value = record.value else { continue }
            guard [value.group != nil, value.snippet != nil, value.trash != nil].filter({ $0 }).count == 1,
                  value.key == key else { throw invalid("Contenuto e identificatore del record non corrispondono.") }
            if let group = value.group,
               group.name.utf8.count > 65_536 || (group.atextSourceJSON?.utf8.count ?? 0) > limit {
                throw invalid("Nome o metadati del gruppo troppo grandi.")
            }
            if let trash = value.trash {
                guard trash.id == trash.snippet.id, trash.deletedAt.timeIntervalSince1970.isFinite else { throw invalid("Cestino non valido.") }
            }
            if let snippet = value.snippet ?? value.trash?.snippet {
                guard snippet.hotkeyCode == nil || (0...127).contains(snippet.hotkeyCode!),
                      snippet.content.utf8.count <= limit, snippet.title.utf8.count <= 65_536,
                      snippet.abbreviation.utf8.count <= 65_536, snippet.notes.utf8.count <= 1_048_576,
                      snippet.apps.count <= 10_000, snippet.apps.allSatisfy({ $0.utf8.count <= 4096 }) else { throw invalid("Frammento non valido o troppo grande.") }
                guard (snippet.aliases?.count ?? 0) <= 10_000,
                      snippet.aliases?.allSatisfy({ $0.utf8.count <= 65_536 }) != false,
                      (snippet.atextSourceJSON?.utf8.count ?? 0) <= limit else {
                    throw invalid("Alias o metadati del frammento troppo grandi.")
                }
            }
        }
        let counts = document.records.values.compactMap(\.value)
        guard counts.filter({ $0.group != nil }).count <= 10_000,
              counts.filter({ $0.snippet != nil }).count <= 100_000,
              counts.filter({ $0.trash != nil }).count <= 100_000 else { throw invalid("Libreria sincronizzata troppo grande.") }
    }

    private static func validKey(_ key: String) -> Bool {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && ["g", "s", "t"].contains(String(parts[0])) &&
            UUID(uuidString: String(parts[1]))?.uuidString == String(parts[1])
    }

    private static func validateHashes(_ hashes: [String: String]) throws {
        guard hashes.count <= 210_000, hashes.allSatisfy({ validKey($0.key) && $0.value.count == 64 && $0.value.allSatisfy({ $0.isHexDigit }) }) else {
            throw invalid("Baseline locale non valida.")
        }
    }

    private static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= limit else { throw invalid("Il file deve essere regolare e non superare 16 MB.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw invalid("File oltre il limite di 16 MB.") }
        return data
    }

    private static func decode(_ bytes: Data) throws -> FolderDocument {
        let document = try JSONDecoder().decode(FolderDocument.self, from: bytes)
        try validate(document)
        return document
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= limit else { throw invalid("Documento o stato sync oltre il limite di 16 MB.") }
        return bytes
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let bytes = try encode(value)
        if FileManager.default.fileExists(atPath: url.path), try read(url) == bytes { return }
        try bytes.write(to: url, options: .atomic)
    }

    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func uuid(from hash: SHA256.Digest) -> UUID {
        var bytes = Array(hash.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private static func invalid(_ message: String) -> LibraryError { .invalid("Sincronizzazione: " + message) }
}
