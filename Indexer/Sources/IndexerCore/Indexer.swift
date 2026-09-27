//
//  Indexer.swift
//  IndexerCore
//
//  Incremental indexing pipeline:
//
//    reconciliation (metadata walk)  ─┐
//    FSEvents paths (fast path)      ─┴─▶ changed paths ─▶ bounded parallel
//        stable read + parse / asset processing ─▶ one write transaction per
//        batch ─▶ targeted link re-resolution ─▶ builder.sqlite
//

import Foundation
import GRDB
import WikiShared

public struct IndexStats: Sendable, CustomStringConvertible {
    public var notesWritten = 0
    public var assetsWritten = 0
    public var deleted = 0
    public var unchanged = 0
    public var unstable: [String] = []
    public var skipped = 0
    public var linksResolved = 0
    public var seconds = 0.0

    public var changed: Bool { notesWritten + assetsWritten + deleted > 0 }

    public var description: String {
        "notes=\(notesWritten) assets=\(assetsWritten) deleted=\(deleted) unchanged=\(unchanged) unstable=\(unstable.count) skipped=\(skipped) relinked=\(linksResolved) in \(String(format: "%.3f", seconds))s"
    }

    mutating func merge(_ other: IndexStats) {
        notesWritten += other.notesWritten
        assetsWritten += other.assetsWritten
        deleted += other.deleted
        unchanged += other.unchanged
        unstable += other.unstable
        skipped += other.skipped
        linksResolved += other.linksResolved
    }
}

public struct ReconcileStats: Sendable, CustomStringConvertible {
    public var filesSeen = 0
    public var candidates = 0
    public var walkSeconds = 0.0
    public var index = IndexStats()

    public var description: String {
        "seen=\(filesSeen) candidates=\(candidates) walk=\(String(format: "%.3f", walkSeconds))s; \(index)"
    }
}

/// Serializes all builder mutations. Parsing runs in child tasks; database
/// writes run on the actor, one transaction per batch.
public actor Indexer {
    public let configuration: IndexerConfiguration
    public let builder: BuilderDatabase
    public let publisher: Publisher
    let store: AssetStore
    private var generationForIndexing: Int64
    /// Folders excluded from (or included in) indexing. Starts from the
    /// configuration; the daemon replaces it when a pattern file changes.
    public private(set) var filter: VaultFilter
    /// True when builder.sqlite has changes not yet published.
    public private(set) var hasUnpublishedChanges: Bool
    /// Exclusive lock on the state directory (one indexer per builder).
    private let lock: StateLock

    public init(configuration: IndexerConfiguration) throws {
        try configuration.validate()
        try FileManager.default.createDirectory(at: configuration.stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuration.publishDirectory, withIntermediateDirectories: true)
        let lock = try StateLock(directory: configuration.stateDirectory)
        let builder = try BuilderDatabase(url: configuration.builderDatabaseURL)
        var dirty = (try builder.state("dirty")) == "1"
        if try builder.state("resolution_pending") == "1" {
            // A previous run stopped between committing parsed notes and
            // re-resolving links; redo resolution for every link once.
            Log.warning("link resolution was interrupted; re-resolving all links")
            _ = try builder.writer.write { db in
                let all = ResolutionWork(sources: Set(try Int64.fetchAll(db, sql: "SELECT id FROM notes")))
                let n = try builder.resolve(db, work: all)
                try db.execute(sql: "INSERT OR REPLACE INTO builder_state(key, value) VALUES ('resolution_pending', '0'), ('dirty', '1')")
                return n
            }
            dirty = true
        }
        let lastGeneration = Int64(try builder.state("last_generation") ?? "0") ?? 0
        let filter = try configuration.makeFilter()
        if !filter.patterns.isEmpty {
            Log.info("excluding folders: \(filter.patterns.joined(separator: ", "))")
        }
        if !filter.includePatterns.isEmpty {
            Log.info("publishing only folders: \(filter.includePatterns.joined(separator: ", "))")
        }

        self.configuration = configuration
        self.lock = lock
        self.builder = builder
        publisher = Publisher(configuration: configuration)
        store = AssetStore(root: configuration.assetStoreURL)
        hasUnpublishedChanges = dirty
        generationForIndexing = lastGeneration + 1
        self.filter = filter
    }

    /// Replaces the folder filter. Returns false if it is unchanged. The
    /// caller must then reconcile the whole vault: that removes files in
    /// newly excluded (or no longer included) folders and indexes files that
    /// are no longer excluded (or newly included).
    public func updateFilter(_ newFilter: VaultFilter) -> Bool {
        guard newFilter != filter else { return false }
        filter = newFilter
        return true
    }

    // MARK: Reconciliation (correctness path)

    /// Walks vault metadata and processes only files whose size or mtime
    /// differ from builder state, plus deletions. Never re-reads unchanged
    /// files, so a 100k-file reconciliation is a metadata walk.
    public func reconcile(subpath: String? = nil) async throws -> ReconcileStats {
        var stats = ReconcileStats()
        let walkStart = Clock.now()
        let entries = try VaultWalker.walk(vault: configuration.vault, subpath: subpath, filter: filter)
        let stored = try builder.fileStates()
        stats.walkSeconds = Clock.seconds(since: walkStart)
        stats.filesSeen = entries.count

        var candidates: [String] = []
        var seen = Set<String>()
        seen.reserveCapacity(entries.count)
        for entry in entries {
            seen.insert(entry.path)
            if let state = stored[entry.path], state.size == entry.meta.size, state.mtimeNs == entry.meta.mtimeNs,
               state.isNote == (entry.kind == .note) {
                continue
            }
            candidates.append(entry.path)
        }
        let scopePrefix = subpath.map { $0 + "/" }
        for path in stored.keys where !seen.contains(path) {
            if let scopePrefix, !path.hasPrefix(scopePrefix) { continue }
            candidates.append(path)
        }
        stats.candidates = candidates.count
        stats.index = try await process(paths: candidates)
        try builder.setState("last_reconcile", ISO8601DateFormatter().string(from: Date()))
        return stats
    }

    // MARK: Change processing

    enum Outcome: Sendable {
        case note(path: String, meta: FileMeta, hash: String, parsed: ParsedNote)
        case asset(path: String, kind: ViewerSchema.AssetKind, outcome: AssetOutcome)
        case deleted(path: String)
        case unstable(path: String)
        case skipped(path: String)
    }

    /// Processes a set of vault-relative paths (from FSEvents or
    /// reconciliation). Directories expand to their current contents plus
    /// previously indexed files beneath them.
    public func process(paths: [String]) async throws -> IndexStats {
        let start = Clock.now()
        var expanded: [String] = []
        var seen = Set<String>()
        for raw in paths {
            guard let path = VaultPath.normalizeRelative(raw) else { continue }
            // The path itself (a file, or a file that became a directory) …
            if seen.insert(path).inserted { expanded.append(path) }
            // … current contents if it is a directory now …
            if let info = VaultWalker.meta(vault: configuration.vault, relativePath: path), info.isDirectory {
                for entry in try VaultWalker.walk(vault: configuration.vault, subpath: path, filter: filter) where seen.insert(entry.path).inserted {
                    expanded.append(entry.path)
                }
            }
            // … and previously indexed files beneath it (deleted directory, or
            // a directory that became a file). Index range scan, cheap.
            for old in try builder.indexedPaths(under: path) where seen.insert(old).inserted {
                expanded.append(old)
            }
        }

        var stats = IndexStats()
        var work = ResolutionWork()
        let batchSize = max(1, configuration.batchSize)
        var index = 0
        while index < expanded.count {
            let batch = Array(expanded[index..<min(index + batchSize, expanded.count)])
            index += batch.count
            let outcomes = await readAndParse(batch)
            let (batchStats, batchWork) = try apply(outcomes)
            stats.merge(batchStats)
            work.merge(batchWork)
        }
        if !work.isEmpty {
            let finalWork = work
            let builder = builder
            stats.linksResolved = try await builder.writer.write { db in
                let n = try builder.resolve(db, work: finalWork)
                try db.execute(sql: "INSERT OR REPLACE INTO builder_state(key, value) VALUES ('resolution_pending', '0')")
                return n
            }
        }
        if stats.changed {
            markDirty()
        }
        stats.seconds = Clock.seconds(since: start)
        return stats
    }

    /// Reads and parses a batch with bounded concurrency. Never more than
    /// `parseConcurrency` files are in flight, so a large sync burst cannot
    /// fan out into thousands of simultaneous reads.
    private func readAndParse(_ batch: [String]) async -> [Outcome] {
        // Images are processed with their own, smaller concurrency limit.
        var notes: [String] = []
        var images: [String] = []
        for path in batch {
            if case .asset(.image) = VaultEntryKind.classify(path, filter: filter) { images.append(path) } else { notes.append(path) }
        }
        let notesOutcomes = await boundedMap(notes, limit: configuration.parseConcurrency)
        let imageOutcomes = await boundedMap(images, limit: configuration.imageConcurrency)
        return notesOutcomes + imageOutcomes
    }

    /// Runs `readOne` over `paths` with at most `limit` in flight, so a large
    /// sync burst cannot fan out into thousands of simultaneous reads.
    private func boundedMap(_ paths: [String], limit: Int) async -> [Outcome] {
        let config = configuration
        let filter = filter
        let store = store
        let builder = builder
        return await withTaskGroup(of: Outcome.self, returning: [Outcome].self) { group in
            var results: [Outcome] = []
            results.reserveCapacity(paths.count)
            var next = 0
            let limit = max(1, limit)
            func enqueue(_ path: String) {
                group.addTask {
                    autoreleasepool {
                        Self.readOne(path: path, configuration: config, filter: filter, store: store, builder: builder)
                    }
                }
            }
            while next < min(limit, paths.count) {
                enqueue(paths[next])
                next += 1
            }
            while let outcome = await group.next() {
                results.append(outcome)
                if next < paths.count {
                    enqueue(paths[next])
                    next += 1
                }
            }
            return results
        }
    }

    private static func readOne(path: String, configuration: IndexerConfiguration, filter: VaultFilter, store: AssetStore, builder: BuilderDatabase) -> Outcome {
        // Excluded paths count as deleted, so a newly excluded folder is
        // removed from the builder on the next reconcile.
        guard let kind = VaultEntryKind.classify(path, filter: filter) else { return .deleted(path: path) }
        switch kind {
        case .note:
            switch StableReader.read(vault: configuration.vault, relativePath: path, maximumBytes: configuration.maximumNoteBytes) {
            case .stable(let data, let meta):
                let text = String(decoding: data, as: UTF8.self)
                let parsed = NoteParser.parse(path: path, text: text)
                if let error = parsed.frontmatterError {
                    Log.warning("\(path): \(error)")
                }
                return .note(path: path, meta: meta, hash: Digest.sha256Hex(data), parsed: parsed)
            case .unstable:
                return .unstable(path: path)
            case .missing:
                return .deleted(path: path)
            case .tooLarge(let meta):
                Log.warning("\(path): \(meta.size) bytes exceeds the note size limit; skipped")
                return .skipped(path: path)
            case .failed(let error):
                Log.warning("\(path): read failed: \(error)")
                return .skipped(path: path)
            }
        case .asset(let assetKind):
            let params = configuration.derivativeParameters
            let result = AssetProcessor.process(
                vault: configuration.vault,
                path: path,
                kind: assetKind,
                configuration: configuration,
                store: store,
                cachedDerivative: { sha in try? builder.cachedDerivative(sourceSHA256: sha, params: params) }
            )
            switch result {
            case .processed(let outcome): return .asset(path: path, kind: assetKind, outcome: outcome)
            case .unstable: return .unstable(path: path)
            case .missing: return .deleted(path: path)
            case .failed(let error):
                Log.warning("\(path): asset failed: \(error)")
                return .skipped(path: path)
            }
        }
    }

    private func apply(_ outcomes: [Outcome]) throws -> (IndexStats, ResolutionWork) {
        var stats = IndexStats()
        var work = ResolutionWork()
        let generation = generationForIndexing
        let params = configuration.derivativeParameters
        try builder.writer.write { db in
            var folders = BuilderDatabase.FolderCache()
            let changesBefore = db.totalChangesCount
            defer {
                // Recorded in the same transaction as the changes: a crash
                // after this commit still leaves "publish" and "re-resolve"
                // pending for the next run.
                if db.totalChangesCount != changesBefore {
                    try? db.execute(sql: "INSERT OR REPLACE INTO builder_state(key, value) VALUES ('dirty', '1'), ('resolution_pending', '1')")
                }
            }
            for outcome in outcomes {
                switch outcome {
                case .note(let path, let meta, let hash, let parsed):
                    // If the path previously was an asset (extension change is impossible, but be safe).
                    try builder.upsertNote(db, path: path, meta: meta, contentHash: hash, parsed: parsed, generation: generation, work: &work, folders: &folders)
                    stats.notesWritten += 1
                case .asset(let path, let kind, let outcome):
                    try builder.upsertAsset(db, path: path, kind: kind, meta: outcome.meta, sourceSHA256: outcome.sourceSHA256, blob: outcome.blob, text: outcome.text, work: &work, folders: &folders)
                    if outcome.producedDerivative, let blob = outcome.blob {
                        try builder.recordDerivative(db, sourceSHA256: outcome.sourceSHA256, params: params, blob: blob)
                    }
                    stats.assetsWritten += 1
                case .deleted(let path):
                    let before = db.totalChangesCount
                    try builder.deleteNote(db, path: path, work: &work, folders: &folders)
                    try builder.deleteAsset(db, path: path, work: &work, folders: &folders)
                    if db.totalChangesCount != before { stats.deleted += 1 } else { stats.unchanged += 1 }
                case .unstable(let path):
                    stats.unstable.append(path)
                case .skipped:
                    stats.skipped += 1
                }
            }
        }
        return (stats, work)
    }

    private func markDirty() {
        if !hasUnpublishedChanges {
            hasUnpublishedChanges = true
            try? builder.setState("dirty", "1")
        }
    }

    // MARK: Publication

    /// Brings the graph tables up to date. A failure leaves the previous
    /// graph in place and never blocks a publication.
    private func refreshGraph() {
        do {
            let summary = try GraphBuilder.refresh(builder: builder, configuration: configuration.graph)
            if summary.unchanged { Log.debug(summary.description) } else { Log.info(summary.description) }
        } catch {
            Log.warning("graph: \(error); publishing the previous graph")
        }
    }

    public func publish(force: Bool = false, failpoint: PublishFailpoint? = nil) throws -> PublishResult? {
        guard force || hasUnpublishedChanges || publisher.currentManifest() == nil else { return nil }
        // Bases depend on every note, so they are evaluated once per
        // publication rather than per changed file.
        let baseStats = try builder.writer.write { db in try BaseBuilder.rebuild(db) }
        if baseStats.bases > 0 { Log.info("bases: \(baseStats)") }
        refreshGraph()
        let result = try publisher.publish(builder: builder, failpoint: failpoint)
        hasUnpublishedChanges = false
        try builder.setState("dirty", "0")
        generationForIndexing = result.manifest.generation + 1
        return result
    }
}

/// flock(2)-based exclusive lock on `<state>/indexer.lock`. Two indexers on
/// the same builder/publish directories would race on generation numbers,
/// temporary files and garbage collection.
final class StateLock: Sendable {
    let fd: Int32

    init(directory: URL) throws {
        let path = directory.appendingPathComponent("indexer.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw IndexerError.unsafeLocation("another wikiindex process is using \(directory.path)")
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
