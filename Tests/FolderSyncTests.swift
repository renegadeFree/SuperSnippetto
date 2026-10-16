import Foundation

@main
struct FolderSyncTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do { guard try condition() else { fatalError("FAILED: \(message)") } }
        catch { fatalError("FAILED: \(message): \(error)") }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError("FAILED: expected error: \(message)") }
        catch { checks += 1 }
    }
    static func directory(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func makePair(_ root: URL, _ name: String) throws -> (LibraryStore, LibraryStore, LibraryFolderSync, LibraryFolderSync, URL) {
        let base = try directory(root, name)
        let first = LibraryStore(url: try directory(base, "first").appendingPathComponent("library.json"))
        let second = LibraryStore(url: try directory(base, "second").appendingPathComponent("library.json"))
        let shared = try directory(base, "shared")
        return (first, second, LibraryFolderSync(store: first), LibraryFolderSync(store: second), shared)
    }
    static func sharedFile(_ folder: URL) -> URL { folder.appendingPathComponent("EspansoLocale.sync.json") }
    static func converge(_ a: LibraryFolderSync, _ b: LibraryFolderSync) throws {
        try a.syncNow(); try b.syncNow(); try a.syncNow()
    }
    static func main() throws {
        check(Thread.isMainThread, "CLI tests execute sync on main thread")
        let root = try directory(FileManager.default.temporaryDirectory, "EspansoLocaleSyncTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // First enable unions distinct content and preserves colliding UUIDs from two existing libraries.
        let (a, b, sa, sb, shared) = try makePair(root, "initial-and-causal")
        let group = SnippetGroup(name: "Group")
        let initial = Snippet(title: "Initial", abbreviation: ";one", groupID: group.id, content: "initial")
        a.data.groups = [group]; a.data.snippets = [initial]
        a.data.allowScripts = true; a.data.paused = true; a.data.excludedApps = ["first.app"]
        a.data.backupFolder = try directory(root, "first-backups").path
        b.data.backupFolder = try directory(root, "second-backups").path
        a.data.delimiters = "first"; a.data.backupIntervalMinutes = 91; a.data.backupRetention = 8
        b.data.allowScripts = false; b.data.paused = false; b.data.excludedApps = ["second.app"]
        b.data.delimiters = "second"; b.data.backupIntervalMinutes = 92; b.data.backupRetention = 9
        let other = Snippet(title: "Only second", abbreviation: ";two", content: "second")
        b.data.snippets = [other]
        try sa.configure(folder: shared); try sb.configure(folder: shared); try sa.syncNow()
        check(a.data.snippets.count == 2 && b.data.snippets.count == 2, "initial enable unions both libraries")
        check(Set(a.data.snippets.map(\.id)) == Set([initial.id, other.id]), "initial enable preserves UUIDs")
        check(a.data.groups.sorted { $0.id.uuidString < $1.id.uuidString } == b.data.groups.sorted { $0.id.uuidString < $1.id.uuidString }, "groups converge")
        check(a.data.allowScripts && a.data.paused && a.data.excludedApps == ["first.app"] && a.data.delimiters == "first", "first device settings isolated")
        check(!b.data.allowScripts && !b.data.paused && b.data.excludedApps == ["second.app"] && b.data.delimiters == "second", "second device settings isolated")
        check(a.data.backupFolder?.hasSuffix("first-backups") == true && b.data.backupFolder?.hasSuffix("second-backups") == true, "backup folder remains local")
        check(a.data.backupIntervalMinutes == 91 && b.data.backupIntervalMinutes == 92 && a.data.backupRetention == 8 && b.data.backupRetention == 9, "backup settings isolated")
        let sharedText = try String(contentsOf: sharedFile(shared), encoding: .utf8)
        for name in ["allowScripts", "paused", "excludedApps", "backupIntervalMinutes", "backupRetention", "backupFolder", "syncFolder", "delimiters", "launchAtLogin", "useCount"] {
            check(!sharedText.contains("\"\(name)\""), "shared document excludes \(name)")
        }
        check(try a.backups().count > 0 && b.backups().count > 0, "backup exists before sync changes")

        // Usage counters are device-local and do not create revisions or conflicts.
        a.data.snippets[a.data.snippets.firstIndex(where: { $0.id == initial.id })!].useCount = 5
        b.data.snippets[b.data.snippets.firstIndex(where: { $0.id == initial.id })!].useCount = 9
        try a.save(); try b.save()
        let beforeUsage = try Data(contentsOf: sharedFile(shared))
        try converge(sa, sb)
        check(try Data(contentsOf: sharedFile(shared)) == beforeUsage, "usage counts do not change shared records")
        check(a.data.snippets.count == 2 && b.data.snippets.count == 2, "usage-only differences never create conflicts")

        // A remote edit observed after the common baseline is causal, not a conflict.
        a.data.snippets[a.data.snippets.firstIndex(where: { $0.id == initial.id })!].content = "remote edit"
        try a.save(); try sa.syncNow()
        let backupsBeforeAdoption = try b.backups().count
        try sb.syncNow()
        check(b.data.snippets.count == 2 && b.data.snippets.first(where: { $0.id == initial.id })?.content == "remote edit", "sequential remote edit adopts exact UUID without conflict")
        check(try b.backups().count > backupsBeforeAdoption, "incoming mutation creates backup")
        check(a.data.snippets.first(where: { $0.id == initial.id })?.useCount == 5 && b.data.snippets.first(where: { $0.id == initial.id })?.useCount == 9, "remote content adoption preserves each device usage count")
        a.data.snippets[a.data.snippets.firstIndex(where: { $0.id == initial.id })!].useCount = 0
        b.data.snippets[b.data.snippets.firstIndex(where: { $0.id == initial.id })!].useCount = 0
        try a.save(); try b.save()

        // Both edit the same UUID without observing the other version.
        a.data.snippets[a.data.snippets.firstIndex(where: { $0.id == initial.id })!].content = "concurrent first"
        b.data.snippets[b.data.snippets.firstIndex(where: { $0.id == initial.id })!].content = "concurrent second"
        try a.save(); try b.save(); try converge(sa, sb)
        check(a.data.snippets.count == 3 && b.data.snippets.count == 3, "simultaneous edit preserves both versions once")
        check(Set(a.data.snippets.map(\.content)).isSuperset(of: ["concurrent first", "concurrent second"]), "conflict contents preserved")
        check(a.data.snippets == b.data.snippets, "stable winner and deterministic conflict UUID converge")
        let stableBytes = try Data(contentsOf: sharedFile(shared))
        for _ in 0..<4 { try converge(sa, sb) }
        check(a.data.snippets.count == 3 && b.data.snippets.count == 3, "repeated sync does not multiply conflicts")
        check(try Data(contentsOf: sharedFile(shared)) == stableBytes, "conflict document is idempotent")

        // Delete an automatically generated conflict copy, then restart: the original conflict cannot recreate it.
        let conflict = a.data.snippets.first(where: { $0.title.hasSuffix(" (conflitto)") })!
        a.data.snippets.removeAll { $0.id == conflict.id }; try a.save(); try converge(sa, sb)
        check(!b.data.snippets.contains(where: { $0.id == conflict.id }), "deletion of conflict copy propagates")
        sb.stop()
        let restartedB = LibraryStore(url: b.fileURL)
        let restartedSync = LibraryFolderSync(store: restartedB)
        try restartedSync.syncNow(); try sa.syncNow(); try restartedSync.syncNow()
        check(!restartedB.data.snippets.contains(where: { $0.id == conflict.id }) && restartedB.data.snippets.count == 2, "tombstone persists after restart without conflict resurrection")

        // Move-to-trash and permanent deletion are synchronized as separate causal records.
        a.moveToTrash([initial.id]); try a.save(); try converge(sa, restartedSync)
        check(!restartedB.data.snippets.contains(where: { $0.id == initial.id }) && restartedB.data.trash?.contains(where: { $0.id == initial.id }) == true, "trash transition propagates")
        a.emptyTrash(); try a.save(); try converge(sa, restartedSync)
        check(restartedB.data.trash?.isEmpty == true, "trash deletion propagates")
        let restartedA = LibraryStore(url: a.fileURL)
        let restartedSyncA = LibraryFolderSync(store: restartedA)
        try converge(restartedSyncA, restartedSync)
        check(!restartedA.data.snippets.contains(where: { $0.id == initial.id }) && restartedA.data.trash?.isEmpty == true, "permanent deletion persists after both devices restart")

        // A no-op tick performs no save, backup, shared-file write or sidecar replacement.
        let localFiles = try FileManager.default.contentsOfDirectory(at: restartedA.fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let tracked = localFiles + [sharedFile(shared)]
        let dates = try tracked.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let snapshots = try restartedA.backups().count
        try restartedSyncA.syncNow()
        let afterDates = try tracked.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        check(dates == afterDates, "no-op tick leaves file modification dates unchanged")
        check(try restartedA.backups().count == snapshots, "no-op tick creates no backup")

        // Different content with the same initial UUID is preserved on first enable.
        let (c, d, sc, sd, collisionFolder) = try makePair(root, "initial-collision")
        let sharedID = UUID()
        c.data.snippets = [Snippet(id: sharedID, content: "before first enable")]
        d.data.snippets = [Snippet(id: sharedID, content: "other existing library")]
        try sc.configure(folder: collisionFolder); try sd.configure(folder: collisionFolder); try converge(sc, sd)
        check(c.data.snippets.count == 2 && c.data.snippets == d.data.snippets, "initial UUID collision preserves both without repeated import")

        // Two valid local hierarchy edits can form a cycle only after merge.
        let (e, f, se, sf, hierarchyFolder) = try makePair(root, "hierarchy")
        let g1 = SnippetGroup(name: "One"), g2 = SnippetGroup(name: "Two")
        e.data.groups = [g1, g2]
        e.data.snippets = [Snippet(groupID: g1.id, content: "must survive group repair")]
        try se.configure(folder: hierarchyFolder); try sf.configure(folder: hierarchyFolder)
        e.data.groups[e.data.groups.firstIndex(where: { $0.id == g1.id })!].parentID = g2.id
        f.data.groups[f.data.groups.firstIndex(where: { $0.id == g2.id })!].parentID = g1.id
        try e.save(); try f.save(); try converge(se, sf)
        check(e.data.groups.sorted { $0.id.uuidString < $1.id.uuidString } == f.data.groups.sorted { $0.id.uuidString < $1.id.uuidString }, "cycle repair converges deterministically")
        let smallest = [g1.id, g2.id].min { $0.uuidString < $1.uuidString }!
        check(e.data.groups.first(where: { $0.id == smallest })?.parentID == nil, "smallest UUID breaks cycle")
        check(e.data.snippets.count == 1 && e.data.snippets[0].content == "must survive group repair", "cycle repair preserves snippet content")
        try e.save(); try f.save()
        let cycleStable = try Data(contentsOf: sharedFile(hierarchyFolder))
        try converge(se, sf)
        check(try Data(contentsOf: sharedFile(hierarchyFolder)) == cycleStable, "repair does not create artificial edit conflicts")

        // Delete a group while the other device adds a new snippet referencing it.
        e.data.groups.removeAll { $0.id == g1.id }
        for i in e.data.groups.indices where e.data.groups[i].parentID == g1.id { e.data.groups[i].parentID = nil }
        for i in e.data.snippets.indices where e.data.snippets[i].groupID == g1.id { e.data.snippets[i].groupID = nil }
        let orphan = Snippet(groupID: g1.id, content: "orphan content retained")
        f.data.snippets.append(orphan)
        try e.save(); try f.save(); try converge(se, sf)
        check(e.data.snippets.first(where: { $0.id == orphan.id })?.content == "orphan content retained", "orphan snippet preserved")
        check(e.data.snippets.first(where: { $0.id == orphan.id })?.groupID == nil && e.data.groups.sorted { $0.id.uuidString < $1.id.uuidString } == f.data.groups.sorted { $0.id.uuidString < $1.id.uuidString }, "orphan group references repaired deterministically")

        // Malformed/unknown/oversized remote files never get overwritten, even with local changes queued.
        let file = sharedFile(collisionFolder)
        let validRemote = try Data(contentsOf: file)
        let corrupt = Data("{not JSON".utf8)
        try corrupt.write(to: file)
        c.data.snippets[0].content = "local edit queued during corruption"; try c.save()
        let localBeforeFailure = c.data
        rejects("corrupt remote") { try sc.syncNow() }
        check(try Data(contentsOf: file) == corrupt && c.data == localBeforeFailure, "corruption preserves both remote bytes and local library")
        var unknown = try JSONSerialization.jsonObject(with: validRemote) as! [String: Any]
        unknown["version"] = 999
        let unknownBytes = try JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys])
        try unknownBytes.write(to: file)
        rejects("unknown remote version") { try sc.syncNow() }
        check(try Data(contentsOf: file) == unknownBytes, "unknown version not overwritten")
        let oversized = Data(repeating: 65, count: 16 * 1024 * 1024 + 1)
        try oversized.write(to: file)
        rejects("remote over 16 MB") { try sc.syncNow() }
        check(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == oversized.count, "oversized remote remains intact")
        try validRemote.write(to: file); try converge(sc, sd)
        check(c.data.snippets.count == 2 && c.data.snippets == d.data.snippets, "recovery after corrupt remote does not generate extra versions")
        check(c.data.snippets.contains(where: { $0.content == "local edit queued during corruption" }), "queued local edit survives corrupt-file retry")
        check(sc.lastError == nil, "successful retry clears actionable error")

        // Semantic corruption in a record, not just invalid JSON.
        var semantic = try JSONSerialization.jsonObject(with: validRemote) as! [String: Any]
        var records = semantic["records"] as! [String: Any]
        let key = records.keys.first!
        var record = records[key] as! [String: Any]
        record["seen"] = [String: UInt64]()
        records[key] = record; semantic["records"] = records
        let semanticBytes = try JSONSerialization.data(withJSONObject: semantic, options: [.sortedKeys])
        try semanticBytes.write(to: file)
        rejects("invalid causal revision") { try sd.syncNow() }
        check(try Data(contentsOf: file) == semanticBytes, "semantic corruption not overwritten")
        try validRemote.write(to: file)

        // A failed provider write preserves the published bytes and durably queues local revisions.
        let (w1, w2, sw1, sw2, writeFolder) = try makePair(root, "remote-write-failure")
        let queued = Snippet(content: "before failure")
        w1.data.snippets = [queued]
        try sw1.configure(folder: writeFolder); try sw2.configure(folder: writeFolder)
        w1.data.snippets[0].content = "queued edit survives restart"; try w1.save()
        let beforeWriteFailure = try Data(contentsOf: sharedFile(writeFolder))
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: writeFolder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: writeFolder.path) }
            rejects("provider write failure") { try sw1.syncNow() }
            check(try Data(contentsOf: sharedFile(writeFolder)) == beforeWriteFailure, "failed write leaves remote bytes untouched")
            check(w1.data.snippets[0].content == "queued edit survives restart", "failed write retains edited local content")
        }
        sw1.stop()
        let queuedRestart = LibraryStore(url: w1.fileURL)
        let queuedSync = LibraryFolderSync(store: queuedRestart)
        try converge(queuedSync, sw2)
        check(w2.data.snippets.count == 1 && w2.data.snippets[0].content == "queued edit survives restart", "same queued revision publishes after restart without conflict")

        // A remote commit followed by a failed local save is recovered through the local journal.
        let (j1, j2, sj1, unusedSync, journalFolder) = try makePair(root, "local-save-failure")
        let journalState = try directory(root, "separate-journal-state")
        let sj2 = LibraryFolderSync(store: j2, stateDirectory: journalState)
        j2.data.backupFolder = try directory(root, "journal-backups").path
        j1.data.snippets = [Snippet(content: "before local save failure")]
        try sj1.configure(folder: journalFolder); try sj2.configure(folder: journalFolder)
        j1.data.snippets[0].content = "remote commit survived"; try j1.save(); try sj1.syncNow()
        do {
            let localDirectory = j2.fileURL.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: localDirectory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: localDirectory.path) }
            rejects("local save failure after remote commit") { try sj2.syncNow() }
            check(j2.data.snippets[0].content == "before local save failure", "failed local save rolls memory back")
        }
        sj2.stop()
        let journalRestart = LibraryStore(url: j2.fileURL)
        let journalSync = LibraryFolderSync(store: journalRestart, stateDirectory: journalState)
        try converge(sj1, journalSync)
        check(journalRestart.data.snippets.count == 1 && journalRestart.data.snippets[0].content == "remote commit survived", "journal recovers remote commit without reinterpreting it as a local edit")
        let journalFiles = try FileManager.default.contentsOfDirectory(atPath: journalState.path)
        check(!journalFiles.contains(where: { $0.hasSuffix(".pending") }), "successful recovery removes pending journal")
        [sw1, sw2, queuedSync, sj1, sj2, unusedSync, journalSync].forEach { $0.stop() }

        // Restoring/changing persisted configuration cannot leave an old timer writing its previous folder.
        let alternateFolder = try directory(root, "restored-sync-choice")
        let beforeMismatch = try Data(contentsOf: file)
        c.data.syncFolder = alternateFolder.path; try c.save()
        rejects("configuration mismatch after restore") { try sc.syncNow() }
        check(try Data(contentsOf: file) == beforeMismatch, "old destination is not written after configuration mismatch")
        check(!FileManager.default.fileExists(atPath: sharedFile(alternateFolder).path), "stale object does not write the new choice either")
        check(sc.lastError != nil, "configuration mismatch is visible")
        c.data.syncFolder = nil; try c.save()
        rejects("disabled persisted configuration") { try sc.syncNow() }
        check(try Data(contentsOf: file) == beforeMismatch, "disabled persisted choice prevents explicit stale sync")
        try sc.configure(folder: collisionFolder)

        // Disable changes only the local choice and preserves the shared document.
        let beforeDisable = try Data(contentsOf: file)
        try sc.configure(folder: nil)
        check(sc.folderURL == nil && c.data.syncFolder == nil, "disable persists local setting")
        check(try Data(contentsOf: file) == beforeDisable, "disable does not delete shared data")
        [sa, sb, restartedSync, restartedSyncA, sc, sd, se, sf].forEach { $0.stop() }
        try metadataChecks(root)
        print("Folder sync: \(checks) checks passed")
    }

    static func metadataChecks(_ root: URL) throws {
        let (a, b, sa, sb, shared) = try makePair(root, "alias-source-metadata")
        defer { sa.stop(); sb.stop() }
        let group = SnippetGroup(name: "Imported group", atextSourceJSON: "{\"group\":\"original\"}")
        let active = Snippet(title: "Imported snippet", abbreviation: ";primary", groupID: group.id, content: "Unchanged content", useCount: 7,
                             aliases: [";secondary", "é👩🏽‍💻"], atextSourceJSON: "{\"source\":\"original\"}")
        let trashed = Snippet(title: "Trashed import", abbreviation: ";old", groupID: group.id, content: "Trashed text", useCount: 4,
                              aliases: [";old-alias"], atextSourceJSON: "{\"deleted\":true}")
        a.data.groups = [group]; a.data.snippets = [active]
        a.data.trash = [TrashedSnippet(snippet: trashed, deletedAt: Date(timeIntervalSince1970: 10))]
        try sa.configure(folder: shared); try sb.configure(folder: shared); try sa.syncNow()
        check(b.data.snippets.first?.aliases == active.aliases && b.data.snippets.first?.atextSourceJSON == active.atextSourceJSON,
              "active aliases and original source metadata cross wire")
        check(b.data.groups.first?.atextSourceJSON == group.atextSourceJSON, "group original source metadata crosses wire")
        check(b.data.trash?.first?.snippet.aliases == trashed.aliases && b.data.trash?.first?.snippet.atextSourceJSON == trashed.atextSourceJSON,
              "trash retains aliases and source metadata across wire")
        check(b.data.snippets.first?.useCount == 0 && b.data.trash?.first?.snippet.useCount == 0, "new remote records never copy source usage counters")
        b.data.snippets[0].useCount = 13; b.data.trash![0].snippet.useCount = 8
        try b.save()
        let beforeUsage = try Data(contentsOf: sharedFile(shared))
        try converge(sa, sb)
        check(try Data(contentsOf: sharedFile(shared)) == beforeUsage, "metadata-bearing records still ignore usage-only changes")
        a.data.snippets[0].aliases = [";causal"]
        a.data.snippets[0].atextSourceJSON = "{\"source\":\"updated\"}"
        a.data.trash![0].snippet.aliases = [";trash-updated"]
        a.data.trash![0].snippet.atextSourceJSON = "{\"deleted\":\"updated\"}"
        try a.save(); try sa.syncNow(); try sb.syncNow()
        check(b.data.snippets.count == 1 && b.data.snippets[0].id == active.id && b.data.snippets[0].aliases == [";causal"],
              "causal metadata-only change updates original record without conflict")
        check(b.data.snippets[0].atextSourceJSON == a.data.snippets[0].atextSourceJSON && b.data.snippets[0].useCount == 13,
              "metadata update preserves device-local active usage")
        check(b.data.trash?.first?.snippet.atextSourceJSON == a.data.trash?.first?.snippet.atextSourceJSON && b.data.trash?.first?.snippet.useCount == 8,
              "metadata update preserves device-local trash usage")
        check(b.data.trash?.first?.snippet.aliases == [";trash-updated"], "causal trash alias change synchronizes")

        a.data.snippets[0].aliases = [";left"]; a.data.snippets[0].atextSourceJSON = "{\"source\":\"left\"}"
        b.data.snippets[0].aliases = [";right"]; b.data.snippets[0].atextSourceJSON = "{\"source\":\"right\"}"
        a.data.groups[0].atextSourceJSON = "{\"group\":\"left\"}"
        b.data.groups[0].atextSourceJSON = "{\"group\":\"right\"}"
        try a.save(); try b.save(); try converge(sa, sb)
        check(a.data.snippets.count == 2 && b.data.snippets.count == 2, "concurrent metadata-only edits preserve both snippets")
        check(Set(a.data.snippets.compactMap(\.atextSourceJSON)) == Set(["{\"source\":\"left\"}", "{\"source\":\"right\"}"]),
              "metadata conflict keeps both original source records")
        check(Set(a.data.snippets.flatMap { $0.aliases ?? [] }) == Set([";left", ";right"]), "metadata conflict retains aliases on corresponding versions")
        check(a.data.groups.count == 2 && Set(a.data.groups.compactMap(\.atextSourceJSON)) == Set(["{\"group\":\"left\"}", "{\"group\":\"right\"}"]),
              "concurrent group metadata changes preserve both groups")
        check(a.data.snippets.first(where: { $0.id == active.id })?.useCount == 7 && b.data.snippets.first(where: { $0.id == active.id })?.useCount == 13,
              "metadata conflict preserves original UUID local usage counters")
        let stable = try Data(contentsOf: sharedFile(shared))
        let backups = try a.backups().count
        try converge(sa, sb)
        check(try Data(contentsOf: sharedFile(shared)) == stable, "metadata conflict wire converges without repeated writes")
        check(try a.backups().count == backups, "stable metadata sync creates no backups")
        let restarted = LibraryStore(url: b.fileURL)
        check(restarted.data.snippets == b.data.snippets && restarted.data.trash == b.data.trash, "metadata persists across local restart after sync")

        var envelope = try JSONSerialization.jsonObject(with: stable) as! [String: Any]
        var records = envelope["records"] as! [String: Any]
        let snippetKey = records.keys.first(where: { $0.hasPrefix("s:") })!
        var record = records[snippetKey] as! [String: Any]
        var value = record["value"] as! [String: Any]
        var wireSnippet = value["snippet"] as! [String: Any]
        wireSnippet["aliases"] = Array(repeating: "x", count: 10_001)
        value["snippet"] = wireSnippet; record["value"] = value; records[snippetKey] = record; envelope["records"] = records
        let invalid = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try invalid.write(to: sharedFile(shared))
        let localBefore = b.data
        rejects("too many wire aliases") { try sb.syncNow() }
        let remoteAfterFailure = try Data(contentsOf: sharedFile(shared))
        check(b.data == localBefore && remoteAfterFailure == invalid, "invalid metadata wire preserves local data and remote bytes")
        wireSnippet["aliases"] = [String(repeating: "x", count: 65_537)]
        value["snippet"] = wireSnippet; record["value"] = value; records[snippetKey] = record; envelope["records"] = records
        let longAlias = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try longAlias.write(to: sharedFile(shared))
        rejects("wire alias over 65536 bytes") { try sb.syncNow() }
        check(b.data == localBefore, "oversized alias never replaces local metadata")
        try stable.write(to: sharedFile(shared))

        // Older version-one wire lacks both new optional fields, including inside trash records.
        let (_, legacyReader, legacyWriterSync, legacyReaderSync, legacyFolder) = try makePair(root, "legacy-wire-metadata")
        defer { legacyWriterSync.stop(); legacyReaderSync.stop() }
        var legacyEnvelope = try JSONSerialization.jsonObject(with: stable) as! [String: Any]
        var legacyRecords = legacyEnvelope["records"] as! [String: Any]
        for (key, raw) in legacyRecords {
            var item = raw as! [String: Any]
            guard var oldValue = item["value"] as? [String: Any] else { continue }
            if var snippet = oldValue["snippet"] as? [String: Any] {
                snippet.removeValue(forKey: "aliases"); snippet.removeValue(forKey: "atextSourceJSON"); oldValue["snippet"] = snippet
            }
            if var trash = oldValue["trash"] as? [String: Any], var snippet = trash["snippet"] as? [String: Any] {
                snippet.removeValue(forKey: "aliases"); snippet.removeValue(forKey: "atextSourceJSON"); trash["snippet"] = snippet; oldValue["trash"] = trash
            }
            if var group = oldValue["group"] as? [String: Any] { group.removeValue(forKey: "atextSourceJSON"); oldValue["group"] = group }
            item["value"] = oldValue; legacyRecords[key] = item
        }
        legacyEnvelope["records"] = legacyRecords
        try JSONSerialization.data(withJSONObject: legacyEnvelope, options: [.sortedKeys]).write(to: sharedFile(legacyFolder))
        try legacyReaderSync.configure(folder: legacyFolder)
        check(legacyReader.data.snippets.count == 2 && legacyReader.data.snippets.allSatisfy({ $0.aliases == nil && $0.atextSourceJSON == nil }), "older wire decodes absent snippet aliases and metadata")
        check(legacyReader.data.trash?.first?.snippet.aliases == nil && legacyReader.data.trash?.first?.snippet.atextSourceJSON == nil, "older trash wire decodes absent optional metadata")
        check(legacyReader.data.groups.count == 2 && legacyReader.data.groups.allSatisfy({ $0.atextSourceJSON == nil }), "older group wire decodes absent original source metadata")
    }
}
