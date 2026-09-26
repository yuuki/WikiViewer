//
//  HostBenchmark.swift
//  IndexerCore
//
//  Reproducible host-side benchmark. Only operates on synthetic vaults
//  (identified by SyntheticVault.markerName) because it edits notes to
//  measure incremental updates.
//

import Foundation
import GRDB
import WikiShared

public enum HostBenchmark {
    public struct Result: Sendable, Codable {
        public var notes = 0
        public var assets = 0
        public var links = 0
        public var unresolvedLinks = 0
        public var initialIndexSeconds = 0.0
        public var initialPublishSeconds = 0.0
        public var noopReconcileSeconds = 0.0
        public var singleUpdateSeconds = 0.0
        public var singleUpdatePublishSeconds = 0.0
        public var burstUpdates = 0
        public var burstSeconds = 0.0
        public var missedEventsReconcileSeconds = 0.0
        public var newNoteResolvesSeconds = 0.0
        public var newNoteResolvedLinks = 0
        public var viewerDatabaseBytes: Int64 = 0
        public var ftsBytes: Int64?
        public var notesTableBytes: Int64?
        public var bodyTextBytes: Int64 = 0
        public var builderDatabaseBytes: Int64 = 0
        public var assetStoreBytes: Int64 = 0
        public var peakRSSBytes: Int64 = 0
        public var chunkCount = 0
        public var chunkSize = 0
        public var singleUpdateNewChunks = 0
        public var burstPublishSeconds = 0.0
        public var burstNewChunks = 0
        /// Page packs: the first keyframe, and the delta pack from the
        /// previous generation after the single update and after the burst.
        public var keyframeBytes: Int64?
        public var singleUpdateDeltaPackBytes: Int64?
        public var burstDeltaPackBytes: Int64?
    }

    public static func run(vault: URL, work: URL, updates: Int, imageMax: Int) async throws {
        let result = try await measure(vault: vault, work: work, updates: updates, imageMax: imageMax)
        let mb = { (b: Int64) in String(format: "%.1f MiB", Double(b) / 1_048_576) }
        let s = { (x: Double) in String(format: "%.3f s", x) }
        print("""
        | metric | value |
        |---|---|
        | notes / assets / links (unresolved) | \(result.notes) / \(result.assets) / \(result.links) (\(result.unresolvedLinks)) |
        | initial index (reconcile) | \(s(result.initialIndexSeconds)) |
        | initial publish (snapshot+check+hash) | \(s(result.initialPublishSeconds)) |
        | no-op reconcile (metadata walk) | \(s(result.noopReconcileSeconds)) |
        | single-note update (process) | \(s(result.singleUpdateSeconds)) |
        | single-note update publish | \(s(result.singleUpdatePublishSeconds)) |
        | burst update of \(result.burstUpdates) notes | \(s(result.burstSeconds)) |
        | burst publish | \(s(result.burstPublishSeconds)) |
        | delta after single update | \(result.singleUpdateNewChunks) of \(result.chunkCount) chunks (\(result.chunkSize / 1024) KiB) |
        | delta after burst | \(result.burstNewChunks) of \(result.chunkCount) chunks |
        | keyframe pack (compressed database) | \(result.keyframeBytes.map(mb) ?? "n/a") |
        | delta pack after single update | \(result.singleUpdateDeltaPackBytes.map { String(format: "%.1f KiB", Double($0) / 1024) } ?? "n/a") |
        | delta pack after burst | \(result.burstDeltaPackBytes.map(mb) ?? "n/a") |
        | reconcile after 100 missed edits | \(s(result.missedEventsReconcileSeconds)) |
        | new note resolving dangling links | \(s(result.newNoteResolvesSeconds)) (\(result.newNoteResolvedLinks) links) |
        | viewer.sqlite size | \(mb(result.viewerDatabaseBytes)) |
        | FTS5 index size | \(result.ftsBytes.map(mb) ?? "n/a") |
        | notes table size | \(result.notesTableBytes.map(mb) ?? "n/a") |
        | raw body text | \(mb(result.bodyTextBytes)) |
        | builder.sqlite size | \(mb(result.builderDatabaseBytes)) |
        | asset store | \(mb(result.assetStoreBytes)) |
        | peak RSS | \(mb(result.peakRSSBytes)) |
        """)
        let json = try JSONEncoder().encode(result)
        print("JSON " + String(decoding: json, as: UTF8.self))
    }

    public static func measure(vault: URL, work: URL, updates: Int, imageMax: Int) async throws -> Result {
        let fm = FileManager.default
        guard SyntheticVault.isSyntheticVault(vault) else {
            throw IndexerError.unsafeLocation("benchmark edits notes; \(vault.path) is not a synthetic vault")
        }
        let workMarker = work.appendingPathComponent(".wikiviewer-bench-work")
        if fm.fileExists(atPath: work.path) {
            let contents = try fm.contentsOfDirectory(atPath: work.path)
            guard contents.isEmpty || fm.fileExists(atPath: workMarker.path) else {
                throw IndexerError.unsafeLocation("\(work.path) is not empty and not a benchmark work directory")
            }
            try fm.removeItem(at: work)
        }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try Data().write(to: workMarker)

        var config = IndexerConfiguration(vault: vault, stateDirectory: work.appendingPathComponent("state"), publishDirectory: work.appendingPathComponent("publish"))
        config.imageMaxDimension = imageMax
        var r = Result()
        let indexer = try Indexer(configuration: config)

        var t = Clock.now()
        _ = try await indexer.reconcile()
        r.initialIndexSeconds = Clock.seconds(since: t)
        t = Clock.now()
        guard let initial = try await indexer.publish() else { throw IndexerError.publicationFailed("nothing published") }
        r.initialPublishSeconds = Clock.seconds(since: t)
        r.keyframeBytes = initial.keyframeBytes

        t = Clock.now()
        let noop = try await indexer.reconcile()
        r.noopReconcileSeconds = Clock.seconds(since: t)
        precondition(!noop.index.changed, "no-op reconcile changed something")

        // Notes sorted for determinism.
        let notePaths = try await indexer.builder.writer.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM notes ORDER BY path LIMIT ?", arguments: [max(updates, 100) + 1])
        }
        func edit(_ path: String, _ n: Int) throws {
            let url = vault.appendingPathComponent(path)
            var text = try String(contentsOf: url, encoding: .utf8)
            text += "\nEdited \(n) [[Note 1 system]] #edited\n"
            try text.write(to: url, atomically: false, encoding: .utf8)
        }

        try edit(notePaths[0], 0)
        t = Clock.now()
        let single = try await indexer.process(paths: [notePaths[0]])
        r.singleUpdateSeconds = Clock.seconds(since: t)
        precondition(single.notesWritten == 1)
        t = Clock.now()
        let singlePublish = try await indexer.publish()
        r.singleUpdatePublishSeconds = Clock.seconds(since: t)
        r.singleUpdateNewChunks = singlePublish?.newChunks ?? -1
        r.singleUpdateDeltaPackBytes = singlePublish?.deltaPackBytes[initial.manifest.generation]

        let burst = Array(notePaths.prefix(updates))
        for (i, path) in burst.enumerated() { try edit(path, i + 1) }
        t = Clock.now()
        let burstStats = try await indexer.process(paths: burst)
        r.burstSeconds = Clock.seconds(since: t)
        r.burstUpdates = burstStats.notesWritten
        t = Clock.now()
        let burstPublish = try await indexer.publish()
        r.burstPublishSeconds = Clock.seconds(since: t)
        r.burstNewChunks = burstPublish?.newChunks ?? -1
        if let previous = singlePublish?.manifest.generation {
            r.burstDeltaPackBytes = burstPublish?.deltaPackBytes[previous]
        }

        // Simulate lost watcher events: edit without telling the indexer.
        for (i, path) in notePaths.suffix(100).enumerated() { try edit(path, 10_000 + i) }
        t = Clock.now()
        let missed = try await indexer.reconcile()
        r.missedEventsReconcileSeconds = Clock.seconds(since: t)
        precondition(missed.index.notesWritten == min(100, notePaths.count), "reconcile missed edits: \(missed)")

        // A new note that makes previously dangling links resolve.
        let dangling = try await indexer.builder.writer.read { db in
            try String.fetchOne(db, sql: "SELECT target_path FROM links WHERE target_note_id IS NULL AND target_asset_id IS NULL AND target_path LIKE 'Missing note %' GROUP BY target_path ORDER BY count(*) DESC LIMIT 1")
        }
        if let dangling {
            let before = try indexer.builder.counts().unresolved
            try Data("# \(dangling)\n".utf8).write(to: vault.appendingPathComponent("\(dangling).md"))
            t = Clock.now()
            _ = try await indexer.process(paths: ["\(dangling).md"])
            r.newNoteResolvesSeconds = Clock.seconds(since: t)
            r.newNoteResolvedLinks = before - (try indexer.builder.counts().unresolved)
            try fm.removeItem(at: vault.appendingPathComponent("\(dangling).md"))
            _ = try await indexer.process(paths: ["\(dangling).md"])
        }

        guard let final = try await indexer.publish(force: true) else { throw IndexerError.publicationFailed("final") }
        _ = initial
        let counts = try indexer.builder.counts()
        (r.notes, r.assets, r.links, r.unresolvedLinks) = counts
        r.viewerDatabaseBytes = final.manifest.database.byteSize
        r.chunkCount = final.manifest.chunks?.count ?? 0
        r.chunkSize = final.manifest.chunks?.chunkSize ?? 0
        r.builderDatabaseBytes = (try? fm.attributesOfItem(atPath: config.builderDatabaseURL.path)[.size] as? Int64) ?? 0
        r.assetStoreBytes = directorySize(config.assetStoreURL)

        var readonly = Configuration()
        readonly.readonly = true
        let viewer = try DatabaseQueue(path: final.databaseURL.path, configuration: readonly)
        let sizes: (Int64, Int64?, Int64?) = try await viewer.read { db in
            let body = try Int64.fetchOne(db, sql: "SELECT sum(length(CAST(body AS BLOB))) FROM notes") ?? 0
            guard (try? db.execute(sql: "SELECT 1 FROM dbstat LIMIT 1")) != nil else { return (body, nil, nil) }
            return (
                body,
                try Int64.fetchOne(db, sql: "SELECT sum(pgsize) FROM dbstat WHERE name LIKE 'notes_fts%'"),
                try Int64.fetchOne(db, sql: "SELECT sum(pgsize) FROM dbstat WHERE name = 'notes'")
            )
        }
        (r.bodyTextBytes, r.ftsBytes, r.notesTableBytes) = sizes
        try viewer.close()
        r.peakRSSBytes = peakResidentBytes()
        return r
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
