//
//  Publisher.swift
//  IndexerCore
//
//  Publishes immutable viewer generations:
//
//    builder.sqlite ──backup──▶ .tmp/viewer-N.sqlite.partial
//        post-process (clear builder-only rows, journal_mode=DELETE, meta,
//        incremental_vacuum, ANALYZE) ─▶ quick_check ─▶ close ─▶ fsync
//        ─▶ SHA-256 + chunks ─▶ page packs ─▶ rename to generations/viewer-N.sqlite
//        ─▶ fsync dir
//        ─▶ manifest.json.tmp ─▶ fsync ─▶ rename to manifest.json (LAST)
//
//  A failure at any step leaves the previous manifest.json (and therefore the
//  previous generation) untouched. Leftovers in .tmp are removed on the next
//  publication.
//

import Foundation
import GRDB
import WikiShared

public struct PublishResult: Sendable {
    public var manifest: ArtifactManifest
    public var databaseURL: URL
    public var seconds: Double
    public var missingBlobs: Int
    /// Chunks that did not exist in the store before (≈ delta size).
    public var newChunks: Int
    /// Bytes of each published delta pack, by base generation, and of a
    /// keyframe written by this publication.
    public var deltaPackBytes: [Int64: Int64] = [:]
    public var keyframeBytes: Int64?
}

/// Test hook to simulate crashes / corruption at specific points.
public enum PublishFailpoint: Sendable, Equatable {
    /// Throw after the snapshot is complete but before it is renamed.
    case beforeDatabaseRename
    /// Throw after the database is in `generations/` but before the manifest.
    case beforeManifestRename
    /// Corrupt the snapshot file before the integrity check.
    case corruptSnapshot
}

public struct PublisherError: Error, CustomStringConvertible {
    public var description: String
}

public final class Publisher: Sendable {
    public let configuration: IndexerConfiguration
    public static let builderIdentifier = "wikiindex/1"

    public init(configuration: IndexerConfiguration) {
        self.configuration = configuration
    }

    var publishDir: URL { configuration.publishDirectory }
    var generationsDir: URL { publishDir.appendingPathComponent("generations", isDirectory: true) }
    var tmpDir: URL { publishDir.appendingPathComponent(".tmp", isDirectory: true) }
    public var manifestURL: URL { publishDir.appendingPathComponent("manifest.json") }

    public func currentManifest() -> ArtifactManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? ArtifactManifest.decode(data)
    }

    /// Existing generation numbers in `generations/`.
    func existingGenerations() -> [Int64] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: generationsDir.path)) ?? []
        let numbers = names.compactMap { name -> Int64? in
            guard name.hasPrefix("viewer-") else { return nil }
            for suffix in [".sqlite", ".chunks"] where name.hasSuffix(suffix) {
                return Int64(name.dropFirst("viewer-".count).dropLast(suffix.count))
            }
            return nil
        }
        return Array(Set(numbers)).sorted()
    }

    var chunkStoreURL: URL { publishDir.appendingPathComponent("chunks", isDirectory: true) }
    var packs: PackPublisher { PackPublisher(configuration: configuration) }

    /// Splits the finished snapshot into content-addressed chunks (writing
    /// only chunks not already in the store) and computes the whole-file
    /// SHA-256 in the same pass.
    func writeChunks(of url: URL) throws -> (list: ChunkList, sha256: String, newChunks: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fm = FileManager.default
        var whole = SHA256Stream()
        var digests: [String] = []
        var total: Int64 = 0
        var written = 0
        var touchedDirectories = Set<URL>()
        defer {
            // New directory entries must be durable before the manifest names them.
            for dir in touchedDirectories { try? fsyncPath(dir) }
        }
        while true {
            // FileHandle.read returns an autoreleased buffer: without a pool
            // per chunk, every chunk of the database stays alive until the
            // publication ends (measured: 108 MiB at 20k notes).
            let read = try autoreleasepool { try handle.read(upToCount: configuration.chunkSize) }
            guard let chunk = read, !chunk.isEmpty else { break }
            whole.update(chunk)
            let digest = Digest.sha256Hex(chunk)
            digests.append(digest)
            total += Int64(chunk.count)
            guard let rel = ChunkList.relativePath(for: digest) else { continue }
            let target = publishDir.appendingPathComponent(rel)
            if !fm.fileExists(atPath: target.path) {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(digest).\(UUID().uuidString).tmp")
                try chunk.write(to: tmp)
                try fsyncPath(tmp)
                try atomicRename(tmp, to: target)
                touchedDirectories.insert(target.deletingLastPathComponent())
                written += 1
            }
        }
        return (ChunkList(chunkSize: configuration.chunkSize, totalBytes: total, digests: digests), whole.finalize(), written)
    }

    /// Never reuses a generation number, even if builder state was rebuilt.
    func nextGeneration(builder: BuilderDatabase) throws -> Int64 {
        let fromState = Int64(try builder.state("last_generation") ?? "0") ?? 0
        let fromDisk = existingGenerations().last ?? 0
        let fromManifest = currentManifest()?.generation ?? 0
        return max(fromState, fromDisk, fromManifest) + 1
    }

    public func publish(builder: BuilderDatabase, failpoint: PublishFailpoint? = nil) throws -> PublishResult {
        let start = Clock.now()
        let fm = FileManager.default
        try fm.createDirectory(at: generationsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: configuration.assetStoreURL, withIntermediateDirectories: true)
        cleanTemporaryFiles()

        let generation = try nextGeneration(builder: builder)
        removeUnpublishedGenerations(below: generation)
        let fileName = ArtifactManifest.databaseFileName(generation: generation)
        let partial = tmpDir.appendingPathComponent(fileName + ".partial")
        var succeeded = false
        defer {
            if !succeeded, failpoint == nil {
                removeDatabaseFiles(partial)
            }
        }

        // 1. Consistent snapshot via the SQLite online backup API.
        let snapshot = try DatabaseQueue(path: partial.path)
        try builder.writer.backup(to: snapshot)

        // 2. Post-process the private copy.
        let createdAt = ISO8601DateFormatter().string(from: Date())
        var missingBlobs: [(sha: String, ext: String)] = []
        var noteCount = 0
        var assetCount = 0
        var blobNames: [String] = []
        var assetBytes: Int64 = 0
        try snapshot.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
            try db.inTransaction {
                for table in ViewerSchema.builderOnlyTables {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
                let store = AssetStore(root: configuration.assetStoreURL)
                let blobs = try Row.fetchAll(db, sql: "SELECT DISTINCT blob_sha256, blob_ext FROM assets WHERE blob_sha256 IS NOT NULL")
                for row in blobs {
                    let sha: String = row[0]
                    let ext: String = row[1]
                    if !store.contains(sha256: sha, ext: ext) {
                        missingBlobs.append((sha, ext))
                        try db.execute(sql: "UPDATE assets SET blob_sha256 = NULL, blob_ext = NULL, blob_size = NULL WHERE blob_sha256 = ?", arguments: [sha])
                    }
                }
                blobNames = try String.fetchAll(db, sql: "SELECT DISTINCT blob_sha256 || '.' || blob_ext FROM assets WHERE blob_sha256 IS NOT NULL ORDER BY 1")
                noteCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM notes") ?? 0
                assetCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM assets WHERE blob_sha256 IS NOT NULL") ?? 0
                assetBytes = try Int64.fetchOne(db, sql: "SELECT coalesce(sum(blob_size), 0) FROM (SELECT DISTINCT blob_sha256, blob_size FROM assets WHERE blob_sha256 IS NOT NULL)") ?? 0
                let meta: [(String, String)] = [
                    (ViewerSchema.MetaKey.schemaVersion, String(ViewerSchema.version)),
                    (ViewerSchema.MetaKey.scannerVersion, String(WikiVersions.scannerVersion)),
                    (ViewerSchema.MetaKey.generation, String(generation)),
                    (ViewerSchema.MetaKey.createdAt, createdAt),
                    (ViewerSchema.MetaKey.builder, Self.builderIdentifier),
                    (ViewerSchema.MetaKey.noteCount, String(noteCount)),
                    (ViewerSchema.MetaKey.assetCount, String(assetCount)),
                ]
                for (key, value) in meta {
                    try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", arguments: [key, value])
                }
                return .commit
            }
            if configuration.fullIntegrityCheck {
                // FTS5's own consistency check needs a writable connection, so it
                // runs here on the private copy rather than on a published file.
                try db.execute(sql: "INSERT INTO notes_fts(notes_fts, rank) VALUES('integrity-check', 1)")
            }
            try db.execute(sql: "PRAGMA incremental_vacuum")
            // Bounded ANALYZE: gives the planner statistics without scanning
            // every index row of a large database.
            try db.execute(sql: "PRAGMA analysis_limit = 400")
            try db.execute(sql: "ANALYZE")
        }
        try snapshot.close()
        try finalizeRollbackJournalMode(partial)

        if failpoint == .corruptSnapshot {
            try corrupt(partial)
        }

        // 3. Integrity check on a fresh read-only connection.
        try verifyDatabase(at: partial, expectedGeneration: generation)

        // 4. Durability and digest.
        for suffix in ["-wal", "-shm", "-journal"] {
            let side = URL(fileURLWithPath: partial.path + suffix)
            if fm.fileExists(atPath: side.path) {
                throw PublisherError(description: "snapshot left \(suffix) file behind")
            }
        }
        try fsyncPath(partial)
        let (chunkList, sha, newChunks) = try writeChunks(of: partial)
        let size = chunkList.totalBytes
        try fsyncPath(chunkStoreURL)

        // Page packs are an optimization: if they cannot be built, the
        // generation is still published with chunks.
        var packBuild: (PackPublisher.Pending, PackPublisher.Stats)?
        if configuration.publishPacks {
            do {
                packBuild = try packs.build(database: partial, list: chunkList, sha256: sha, generation: generation)
                try fsyncPath(packs.packStoreURL)
            } catch {
                Log.warning("publish: page packs failed, publishing chunks only: \(error)")
            }
        }

        if failpoint == .beforeDatabaseRename {
            throw PublisherError(description: "failpoint beforeDatabaseRename")
        }

        // 5. Chunk list, asset reference sidecar and (optionally) the whole
        //    database move into generations/ (immutable from now on).
        let chunkListData = chunkList.encoded()
        let chunkListTmp = tmpDir.appendingPathComponent(fileName + ".chunks.tmp")
        try chunkListData.write(to: chunkListTmp)
        try fsyncPath(chunkListTmp)
        try atomicRename(chunkListTmp, to: publishDir.appendingPathComponent(ArtifactManifest.chunkListPath(generation: generation)))
        let sidecarTmp = tmpDir.appendingPathComponent(fileName + ".assets.tmp")
        try Data(blobNames.joined(separator: "\n").utf8).write(to: sidecarTmp)
        try fsyncPath(sidecarTmp)
        try atomicRename(sidecarTmp, to: sidecarURL(generation))
        let packSidecarTmp = tmpDir.appendingPathComponent(fileName + ".packs.tmp")
        try Data(PackPublisher.partNames(packBuild?.0.index).joined(separator: "\n").utf8).write(to: packSidecarTmp)
        try fsyncPath(packSidecarTmp)
        try atomicRename(packSidecarTmp, to: packSidecarURL(generation))
        let final = generationsDir.appendingPathComponent(fileName)
        if configuration.publishFullDatabase {
            try atomicRename(partial, to: final)
        } else {
            try? fm.removeItem(at: partial)
        }
        try fsyncPath(generationsDir)

        if failpoint == .beforeManifestRename {
            throw PublisherError(description: "failpoint beforeManifestRename")
        }

        // 6. Manifest last.
        var manifest = ArtifactManifest(
            generation: generation,
            createdAt: createdAt,
            database: .init(path: ArtifactManifest.databasePath(generation: generation), byteSize: size, sha256: sha),
            noteCount: noteCount,
            assetCount: assetCount,
            assets: .init(totalBytes: assetBytes),
            builder: Self.builderIdentifier,
            chunks: .init(
                path: ArtifactManifest.chunkListPath(generation: generation),
                byteSize: Int64(chunkListData.count),
                sha256: Digest.sha256Hex(chunkListData),
                chunkSize: chunkList.chunkSize,
                count: chunkList.digests.count
            ),
            packs: packBuild?.0.index
        )
        if manifest.packs != nil, manifest.withoutInvalidPacks().packs == nil {
            // Never let packs block a publication.
            Log.warning("publish: pack index failed validation; publishing chunks only")
            manifest.packs = nil
            packBuild = nil
        }
        try manifest.validate()
        let manifestTmp = tmpDir.appendingPathComponent("manifest.json.tmp")
        try manifest.encoded().write(to: manifestTmp)
        try fsyncPath(manifestTmp)
        try atomicRename(manifestTmp, to: manifestURL)
        try fsyncPath(publishDir)
        succeeded = true
        Log.debug("publish: \(newChunks) new of \(chunkList.digests.count) chunks")

        try builder.setState("last_generation", String(generation))
        var result = PublishResult(manifest: manifest, databaseURL: final, seconds: 0, missingBlobs: missingBlobs.count, newChunks: newChunks)
        if let (pending, stats) = packBuild {
            do {
                try packs.commit(pending)
            } catch {
                Log.warning("publish: could not record pack state: \(error)")
            }
            result.deltaPackBytes = Dictionary(stats.deltas.map { ($0.base, $0.bytes) }, uniquingKeysWith: { a, _ in a })
            result.keyframeBytes = stats.keyframeBytes
            Log.debug("publish: packs \(stats.deltas.map { "Δ\($0.base): \($0.blocks) blocks \($0.bytes) B" }.joined(separator: ", "))\(stats.keyframeBytes.map { ", keyframe \($0) B" } ?? "")")
        }
        if !missingBlobs.isEmpty {
            Log.warning("publish: \(missingBlobs.count) asset blob(s) missing from the store; their assets will be reprocessed")
            try builder.writer.write { db in
                for blob in missingBlobs {
                    try db.execute(sql: "DELETE FROM asset_derivatives WHERE blob_sha256 = ?", arguments: [blob.sha])
                    try db.execute(sql: "UPDATE assets SET mtime_ns = 0 WHERE blob_sha256 = ?", arguments: [blob.sha])
                }
            }
        }

        do {
            try collectGarbage(builder: builder, keeping: generation)
        } catch {
            Log.warning("publish: garbage collection failed: \(error)")
        }

        result.seconds = Clock.seconds(since: start)
        return result
    }

    /// Opens the file read-only and runs the integrity checks a reader would.
    public func verifyDatabase(at url: URL, expectedGeneration: Int64?) throws {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        defer { try? queue.close() }
        try queue.read { db in
            let pragma = configuration.fullIntegrityCheck ? "integrity_check" : "quick_check"
            let result = try String.fetchAll(db, sql: "PRAGMA \(pragma)")
            guard result == ["ok"] else {
                throw IndexerError.integrityCheckFailed(result.prefix(5).joined(separator: "; "))
            }
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard version == ViewerSchema.version else {
                throw IndexerError.integrityCheckFailed("user_version \(version)")
            }
            // Same exact-schema rule the device enforces before installing.
            if let mismatch = try SchemaCheck.mismatch(db) {
                throw IndexerError.integrityCheckFailed("schema \(mismatch)")
            }
            if let expectedGeneration {
                let gen = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [ViewerSchema.MetaKey.generation])
                guard gen == String(expectedGeneration) else {
                    throw IndexerError.integrityCheckFailed("meta generation \(gen ?? "nil")")
                }
            }
        }
    }

    /// The backup copies the builder's WAL-mode header; switching the copy to
    /// journal_mode=DELETE rewrites it but SQLite leaves an unused `-shm` file.
    /// With every connection closed, a rollback-mode header (bytes 18–19 ==
    /// 1) and no `-wal` file, that `-shm` carries no state and is removed so
    /// the published artifact is a single self-contained file.
    func finalizeRollbackJournalMode(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        try handle.seek(toOffset: 18)
        let versions = try handle.read(upToCount: 2) ?? Data()
        try handle.close()
        guard versions == Data([1, 1]) else {
            throw PublisherError(description: "snapshot is not in rollback-journal mode (header \(Array(versions)))")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path + "-wal") else {
            throw PublisherError(description: "snapshot left a -wal file behind")
        }
        if fm.fileExists(atPath: url.path + "-shm") {
            try fm.removeItem(atPath: url.path + "-shm")
        }
    }

    /// Files of generations that were never published (a publication failed
    /// after writing them but before the manifest): numbers above the
    /// manifest's generation. The next number is computed before this, so
    /// numbers are still never reused.
    func removeUnpublishedGenerations(below next: Int64) {
        let published = currentManifest()?.generation ?? 0
        for gen in existingGenerations() where gen > published && gen < next {
            for url in [
                generationsDir.appendingPathComponent(ArtifactManifest.databaseFileName(generation: gen)),
                publishDir.appendingPathComponent(ArtifactManifest.chunkListPath(generation: gen)),
                sidecarURL(gen),
                packSidecarURL(gen),
            ] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func cleanTemporaryFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path)) ?? []
        for name in names {
            try? FileManager.default.removeItem(at: tmpDir.appendingPathComponent(name))
        }
    }

    func removeDatabaseFiles(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    func corrupt(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // Overwrite part of page 2 (a b-tree page) with garbage.
        try handle.seek(toOffset: 4096 + 8)
        handle.write(Data(repeating: 0xFF, count: 2048))
    }

    // MARK: Garbage collection

    /// Keeps the newest `retainedGenerations` databases (always including the
    /// one the manifest points to) and deletes asset blobs that none of the
    /// retained generations nor the builder references, once they are older
    /// than the grace period.
    public func collectGarbage(builder: BuilderDatabase, keeping current: Int64) throws {
        let fm = FileManager.default
        let generations = existingGenerations()
        let keep = Set(generations.suffix(max(1, configuration.retainedGenerations))).union([current])
        for gen in generations where !keep.contains(gen) {
            for url in [
                generationsDir.appendingPathComponent(ArtifactManifest.databaseFileName(generation: gen)),
                publishDir.appendingPathComponent(ArtifactManifest.chunkListPath(generation: gen)),
                sidecarURL(gen),
                packSidecarURL(gen),
            ] {
                try? fm.removeItem(at: url)
            }
        }

        // Asset blobs referenced by retained generations (sidecars) and the builder.
        var referenced = Set<String>()
        for gen in keep {
            if let text = try? String(contentsOf: sidecarURL(gen), encoding: .utf8) {
                referenced.formUnion(text.split(separator: "\n").map(String.init))
                continue
            }
            let url = generationsDir.appendingPathComponent(ArtifactManifest.databaseFileName(generation: gen))
            guard fm.fileExists(atPath: url.path) else { continue }
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            try queue.read { db in
                let rows = try Row.fetchCursor(db, sql: "SELECT DISTINCT blob_sha256 || '.' || blob_ext FROM assets WHERE blob_sha256 IS NOT NULL")
                while let row = try rows.next() { referenced.insert(row[0]) }
            }
            try queue.close()
        }
        try builder.writer.write { db in
            // Forget derivatives whose source no longer exists in the vault, so
            // their blobs become collectable.
            try db.execute(sql: "DELETE FROM asset_derivatives WHERE source_sha256 NOT IN (SELECT source_sha256 FROM assets)")
            let rows = try Row.fetchCursor(db, sql: "SELECT DISTINCT blob_sha256 || '.' || blob_ext FROM assets WHERE blob_sha256 IS NOT NULL UNION SELECT blob_sha256 || '.' || blob_ext FROM asset_derivatives")
            while let row = try rows.next() { referenced.insert(row[0]) }
        }
        let removedBlobs = sweep(configuration.assetStoreURL, keep: referenced, isCollectable: isBlobName)

        // Chunks referenced by retained generations' chunk lists.
        var referencedChunks = Set<String>()
        for gen in keep {
            guard let data = try? Data(contentsOf: publishDir.appendingPathComponent(ArtifactManifest.chunkListPath(generation: gen))),
                  let text = String(data: data, encoding: .utf8) else { continue }
            referencedChunks.formUnion(text.split(separator: "\n").dropFirst().map(String.init))
        }
        let removedChunks = sweep(chunkStoreURL, keep: referencedChunks) { Digest.isValidHex($0) }

        // Pack parts referenced by retained generations' pack sidecars.
        var referencedPacks = Set<String>()
        for gen in keep {
            guard let text = try? String(contentsOf: packSidecarURL(gen), encoding: .utf8) else { continue }
            referencedPacks.formUnion(text.split(separator: "\n").map(String.init))
        }
        let removedPacks = sweep(packs.packStoreURL, keep: referencedPacks) { Digest.isValidHex($0) }
        if removedBlobs + removedChunks + removedPacks > 0 {
            Log.info("gc: removed \(removedBlobs) asset blob(s), \(removedChunks) chunk(s), \(removedPacks) pack(s)")
        }
    }

    func sidecarURL(_ generation: Int64) -> URL {
        generationsDir.appendingPathComponent("viewer-\(ArtifactManifest.paddedGeneration(generation)).assets")
    }

    /// Pack parts (digests) referenced by a generation's manifest.
    func packSidecarURL(_ generation: Int64) -> URL {
        generationsDir.appendingPathComponent("viewer-\(ArtifactManifest.paddedGeneration(generation)).packs")
    }

    /// Deletes files in `<root>/<2 hex>/` whose names are collectable, not in
    /// `keep`, and older than the grace period.
    func sweep(_ root: URL, keep: Set<String>, isCollectable: (String) -> Bool) -> Int {
        let fm = FileManager.default
        let graceSeconds = Double(configuration.assetGracePeriod.components.seconds)
        let now = Date()
        var removed = 0
        for prefix in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where prefix.count == 2 {
            let dir = root.appendingPathComponent(prefix)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                guard isCollectable(name), !keep.contains(name) else { continue }
                let url = dir.appendingPathComponent(name)
                let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
                guard now.timeIntervalSince(modified) >= graceSeconds else { continue }
                try? fm.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    /// Only `<64 hex>.<ext>` names are ever deleted by GC.
    func isBlobName(_ name: String) -> Bool {
        guard let dot = name.firstIndex(of: ".") else { return false }
        return Digest.isValidHex(String(name[..<dot])) && AssetBlobPath.isSafeExtension(String(name[name.index(after: dot)...]))
    }
}
