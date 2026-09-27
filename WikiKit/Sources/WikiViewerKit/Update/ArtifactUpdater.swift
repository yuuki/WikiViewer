//
//  ArtifactUpdater.swift
//  WikiViewerKit
//
//  transport → staging → size/SHA-256 → SQLite validation → generations/NNNNNN
//
//  Transports, cheapest first:
//   1. delta pack: clone an installed generation (APFS copy-on-write) and
//      write only the changed pages; verify only the chunks that changed;
//   2. keyframe: nothing installed — fetch the compressed database of a
//      recent generation, then only the chunks that changed since;
//   3. chunks: reuse chunks of installed generations, fetch the rest;
//   4. the whole database file.
//  A pack path that fails for any reason other than cancellation falls back
//  to chunks; every path ends with the same verification.
//
//  The updater prepares a generation completely before anyone may switch to
//  it. Switching (and closing the old connection) is the Library's job, on
//  the main actor, at a safe point. Any failure here leaves the current and
//  previous generations untouched.
//

import Foundation
import WikiShared

public struct PreparedGeneration: Sendable {
    public var manifest: ArtifactManifest
    public var installed: InstalledGeneration
    public var databaseURL: URL
    /// Transfer statistics (for diagnostics and tests).
    public var transfer = TransferStats()
}

public struct TransferStats: Sendable, Equatable {
    public var mode: Mode = .alreadyInstalled
    public var reusedChunks = 0
    public var fetchedChunks = 0
    public var fetchedBytes: Int64 = 0
    /// Pack parts downloaded (delta or keyframe).
    public var fetchedPacks = 0
    /// Why a pack path was abandoned for chunks, if it was.
    public var packFallback: String?

    public enum Mode: Sendable, Equatable {
        case alreadyInstalled
        case fullDownload
        case chunks
        case deltaPack
        case keyframe
    }
}

public enum UpdateCheck: Sendable, Equatable {
    case upToDate(current: Int64)
    case available(ArtifactManifest)
}

public enum UpdateError: Error, CustomStringConvertible {
    case malformedManifest(String)
    case invalidManifest(ArtifactManifest.ValidationError)
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch
    case invalidChunkList(String)
    case invalidDatabase(String)
    case insufficientSpace(needed: Int64, available: Int64)
    case transport(any Error)

    public var description: String {
        switch self {
        case .malformedManifest(let m): "Malformed manifest: \(m)"
        case .invalidManifest(let e): e.description
        case .sizeMismatch(let e, let a): "Database size \(a) does not match manifest (\(e))"
        case .hashMismatch: "Database SHA-256 does not match manifest"
        case .invalidChunkList(let m): "Chunk list failed validation: \(m)"
        case .insufficientSpace(let n, let a): "Not enough free space (need \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)), have \(ByteCountFormatter.string(fromByteCount: a, countStyle: .file)))"
        case .invalidDatabase(let m): "Database failed validation: \(m)"
        case .transport(let e): "Transfer failed: \(e)"
        }
    }
}

public actor ArtifactUpdater {
    public let store: GenerationStore

    public init(store: GenerationStore) {
        self.store = store
    }

    /// - ignoringCurrent: the current generation could not be opened (for
    ///   example one written with an older schema), so any generation the
    ///   source has counts as an update, even with the same number.
    public func check(source: any ArtifactSource, ignoringCurrent: Bool = false) async throws -> UpdateCheck {
        let data: Data
        do {
            data = try await source.fetchManifest()
        } catch {
            throw UpdateError.transport(error)
        }
        let manifest: ArtifactManifest
        do {
            manifest = try ArtifactManifest.decode(data).withoutInvalidPacks()
        } catch {
            throw UpdateError.malformedManifest(String(describing: error))
        }
        do {
            try manifest.validate()
        } catch {
            throw UpdateError.invalidManifest(error)
        }
        let current = ignoringCurrent ? nil : await store.currentGeneration()
        let sameLineage = await store.lineage() == source.identifier
        if let current, sameLineage, manifest.generation <= current.generation {
            return .upToDate(current: current.generation)
        }
        if let current, current == InstalledGeneration(manifest: manifest) {
            return .upToDate(current: current.generation)
        }
        return .available(manifest)
    }

    /// Downloads and validates a generation into generations/NNNNNN.
    /// Does not switch to it.
    public func prepare(_ manifest: ArtifactManifest, source: any ArtifactSource) async throws -> PreparedGeneration {
        let manifest = manifest.withoutInvalidPacks()
        try manifest.validate()
        // Already installed and validated by an earlier (interrupted) run.
        let expected = InstalledGeneration(manifest: manifest)
        if await store.installedGenerations().contains(expected), await store.manifest(for: expected) == manifest {
            return PreparedGeneration(manifest: manifest, installed: expected, databaseURL: store.databaseURL(for: expected))
        }
        let staging = try await store.makeStagingDirectory()
        var installed = false
        defer {
            if !installed { try? FileManager.default.removeItem(at: staging) }
        }
        let stagedDB = staging.appendingPathComponent("viewer.sqlite")
        var transfer = TransferStats()

        // Chunk list (delta transport), verified against the manifest.
        var chunkList: ChunkList?
        if let entry = manifest.chunks {
            let listURL = staging.appendingPathComponent("viewer.chunks")
            do {
                try await source.download(entry.path, to: listURL, maximumBytes: entry.byteSize)
            } catch {
                throw UpdateError.transport(error)
            }
            let data = try Data(contentsOf: listURL)
            guard Int64(data.count) == entry.byteSize, Digest.sha256Hex(data) == entry.sha256 else {
                throw UpdateError.invalidChunkList("hash mismatch")
            }
            do {
                chunkList = try ChunkList.decode(data, expectedTotalBytes: manifest.database.byteSize)
            } catch {
                throw UpdateError.invalidChunkList(String(describing: error))
            }
            guard chunkList?.chunkSize == entry.chunkSize, chunkList?.digests.count == entry.count else {
                throw UpdateError.invalidChunkList("does not match manifest")
            }
            try? FileManager.default.removeItem(at: listURL)
        }

        // A file already proven to match `chunkList` chunk by chunk needs no
        // second whole-file pass.
        var verifiedByChunks = false
        var assembled = false
        let local = await localChunkIndex()
        if let packs = manifest.packs {
            do {
                if let delta = await applicableDelta(packs) {
                    let result = try await applyDelta(delta, packs: packs, manifest: manifest, chunkList: chunkList, source: source, into: stagedDB, staging: staging)
                    transfer = result.stats
                    verifiedByChunks = result.verified
                    assembled = true
                } else if local.isEmpty, let keyframe = packs.keyframe, chunkList != nil || keyframe.sha256 == manifest.database.sha256 {
                    transfer = try await assembleFromKeyframe(keyframe, packs: packs, manifest: manifest, chunkList: chunkList, source: source, into: stagedDB, staging: staging)
                    assembled = true
                }
            } catch where error is CancellationError || Task.isCancelled {
                // Transport errors wrap cancellation; never fall back then.
                throw CancellationError()
            } catch {
                // Packs are an optimization: fall back to chunks.
                transfer.packFallback = String(describing: error)
                try? FileManager.default.removeItem(at: stagedDB)
                Self.removePackWorkFiles(in: staging)
            }
        }
        if !assembled {
            // Staging may hold fetched chunks plus the assembled file.
            try requireSpace(manifest.database.byteSize * 2)
            let fallback = transfer.packFallback
            func downloadWholeFile() async throws {
                try await source.download(manifest.database.path, to: stagedDB, maximumBytes: manifest.database.byteSize)
                transfer = TransferStats(mode: .fullDownload, fetchedBytes: manifest.database.byteSize)
            }
            if let chunkList, !local.isEmpty {
                // Delta: reuse chunks of the generations already on the device.
                do {
                    transfer = try await assemble(chunkList, local: local, source: source, into: stagedDB, staging: staging)
                } catch UpdateError.transport(TransportError.notFound(_)) {
                    // A source with the whole file but not its chunks (the
                    // bundled demo, replacing an older demo generation).
                    do {
                        try await downloadWholeFile()
                    } catch {
                        throw UpdateError.transport(error)
                    }
                }
            } else {
                do {
                    try await downloadWholeFile()
                } catch TransportError.notFound(_) where chunkList != nil {
                    // Chunks-only publication: assemble from chunks alone.
                    transfer = try await assemble(chunkList!, local: [:], source: source, into: stagedDB, staging: staging)
                } catch {
                    throw UpdateError.transport(error)
                }
            }
            transfer.packFallback = fallback
        }
        try Task.checkCancellation()
        // The staging directory becomes the generation directory: nothing but
        // the database, its chunk list and the manifest may remain in it.
        Self.removePackWorkFiles(in: staging)

        // 1. Size and SHA-256 over the whole assembled file (streamed), which
        //    also records this generation's chunk list for future deltas —
        //    unless the pack path already verified every chunk against the
        //    manifest's chunk list.
        if verifiedByChunks, let chunkList {
            try chunkList.encoded().write(to: staging.appendingPathComponent("viewer.chunks"))
        } else {
            let chunkSize = chunkList?.chunkSize ?? ChunkList.defaultChunkSize
            let (computedList, sha) = try ChunkList.make(fileAt: stagedDB, chunkSize: chunkSize)
            let size = computedList.totalBytes
            guard size == manifest.database.byteSize else {
                throw UpdateError.sizeMismatch(expected: manifest.database.byteSize, actual: size)
            }
            guard sha == manifest.database.sha256 else { throw UpdateError.hashMismatch }
            try computedList.encoded().write(to: staging.appendingPathComponent("viewer.chunks"))
        }

        // 2. SQLite validation of the untrusted file (read-only, not immutable).
        do {
            try ViewerDatabase.validateUntrusted(at: stagedDB, expectedSchema: manifest.schemaVersion, expectedGeneration: manifest.generation, expectedNoteCount: manifest.noteCount)
        } catch {
            throw UpdateError.invalidDatabase(String(describing: error))
        }
        // Validation opened the file read-only in rollback mode; make sure no
        // side files were left that would travel with the generation.
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: stagedDB.path + suffix)
        }

        // 3. Record the manifest next to the database, then install atomically.
        try manifest.encoded().write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        let installedGeneration = try await store.install(stagingDirectory: staging, manifest: manifest)
        installed = true
        return PreparedGeneration(manifest: manifest, installed: installedGeneration, databaseURL: store.databaseURL(for: installedGeneration), transfer: transfer)
    }

    static let spaceMargin: Int64 = 64 * 1024 * 1024

    /// Fails before downloading anything if the volume lacks `bytes` plus a margin.
    func requireSpace(_ bytes: Int64) throws {
        let needed = bytes + Self.spaceMargin
        if let available = try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           available < needed {
            throw UpdateError.insufficientSpace(needed: needed, available: available)
        }
    }

    // MARK: Packs

    struct DeltaChoice {
        var delta: ArtifactManifest.PackIndex.Delta
        var base: InstalledGeneration
    }

    /// The smallest delta whose base is an installed generation.
    func applicableDelta(_ packs: ArtifactManifest.PackIndex) async -> DeltaChoice? {
        var best: DeltaChoice?
        for generation in [await store.currentGeneration(), await store.previousGeneration()].compactMap({ $0 }) {
            guard let installed = await store.manifest(for: generation),
                  let delta = packs.deltas.first(where: { $0.baseSHA256 == installed.database.sha256 && $0.baseByteSize == installed.database.byteSize }),
                  FileManager.default.fileExists(atPath: store.databaseURL(for: generation).path) else { continue }
            if best == nil || delta.byteSize < best!.delta.byteSize {
                best = DeltaChoice(delta: delta, base: generation)
            }
        }
        return best
    }

    static let packFetchConcurrency = 4

    static func removePackWorkFiles(in staging: URL) {
        for name in ["packs", "keyframe.sqlite"] {
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(name))
        }
    }

    /// Downloads pack parts into `staging/packs/` (bounded concurrency) and
    /// verifies each one's size and SHA-256. Returns the local files in order.
    func fetchParts(_ parts: [ArtifactManifest.PackIndex.Part], source: any ArtifactSource, staging: URL) async throws -> [URL] {
        let dir = staging.appendingPathComponent("packs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = parts.map { dir.appendingPathComponent($0.sha256) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue(_ i: Int) {
                let part = parts[i]
                let target = urls[i]
                group.addTask {
                    do {
                        try await source.download(part.path, to: target, maximumBytes: part.byteSize)
                    } catch {
                        throw UpdateError.transport(error)
                    }
                    let (sha, size) = try Digest.sha256Hex(fileAt: target)
                    guard size == part.byteSize, sha == part.sha256 else { throw UpdateError.hashMismatch }
                }
            }
            while next < min(Self.packFetchConcurrency, parts.count) {
                enqueue(next)
                next += 1
            }
            while try await group.next() != nil {
                if next < parts.count {
                    enqueue(next)
                    next += 1
                }
            }
        }
        return urls
    }

    /// Clones the base generation's database (copy-on-write on APFS, so only
    /// changed pages take space) and applies the delta's blocks in place.
    /// Returns whether the result was verified chunk by chunk.
    func applyDelta(_ choice: DeltaChoice, packs: ArtifactManifest.PackIndex, manifest: ArtifactManifest, chunkList: ChunkList?, source: any ArtifactSource, into destination: URL, staging: URL) async throws -> (stats: TransferStats, verified: Bool) {
        let delta = choice.delta
        try requireSpace(delta.byteSize + Int64(delta.blockCount) * Int64(packs.blockSize))
        var stats = TransferStats(mode: .deltaPack)
        let files = try await fetchParts(delta.parts, source: source, staging: staging)
        stats.fetchedPacks = files.count
        stats.fetchedBytes = delta.byteSize
        try Task.checkCancellation()

        let baseURL = store.databaseURL(for: choice.base)
        try FileManager.default.copyItem(at: baseURL, to: destination)
        let handle = try FileHandle(forUpdating: destination)
        defer { try? handle.close() }
        var touchedChunks = Set<Int>()
        var blocks = 0
        for file in files {
            try Task.checkCancellation()
            try autoreleasepool {
                let part = try PagePack.decodePart(try Data(contentsOf: file), expectedBlockSize: packs.blockSize, expectedTargetSize: manifest.database.byteSize)
                guard part.xor else { throw UpdateError.invalidChunkList("delta pack is not XOR") }
                try part.forEachEntry { index, payload in
                    let offset = UInt64(index) * UInt64(packs.blockSize)
                    try handle.seek(toOffset: offset)
                    let base = try handle.read(upToCount: payload.count) ?? Data()
                    try handle.seek(toOffset: offset)
                    try handle.write(contentsOf: PagePack.xor(payload, base: base))
                    if let chunkList { touchedChunks.insert(Int(offset / UInt64(chunkList.chunkSize))) }
                    blocks += 1
                }
            }
            try? FileManager.default.removeItem(at: file)
        }
        guard blocks == delta.blockCount else { throw UpdateError.invalidChunkList("delta has \(blocks) of \(delta.blockCount) blocks") }
        try handle.truncate(atOffset: UInt64(manifest.database.byteSize))
        try handle.synchronize()

        // Chunks not touched by the delta are the base's bytes, whose digests
        // this device computed when it installed the base.
        guard let chunkList,
              let baseData = try? Data(contentsOf: store.directory(for: choice.base).appendingPathComponent("viewer.chunks")),
              let baseList = try? ChunkList.decode(baseData, expectedTotalBytes: delta.baseByteSize),
              baseList.chunkSize == chunkList.chunkSize else {
            return (stats, false)
        }
        try Self.verifyPatched(destination, target: chunkList, base: baseList, touched: touchedChunks, handle: handle)
        stats.reusedChunks = chunkList.digests.count - touchedChunks.count
        return (stats, true)
    }

    /// Proves that `file` matches `target` chunk for chunk: a chunk is hashed
    /// unless the delta did not touch it and the base had the same digest at
    /// the same position with the same length.
    static func verifyPatched(_ file: URL, target: ChunkList, base: ChunkList, touched: Set<Int>, handle: FileHandle) throws {
        let size = try handle.seekToEnd()
        guard Int64(size) == target.totalBytes else {
            throw UpdateError.sizeMismatch(expected: target.totalBytes, actual: Int64(size))
        }
        for (i, digest) in target.digests.enumerated() {
            let unchanged = !touched.contains(i) && i < base.digests.count && base.digests[i] == digest && base.length(of: i) == target.length(of: i)
            if unchanged { continue }
            try autoreleasepool {
                try handle.seek(toOffset: UInt64(i) * UInt64(target.chunkSize))
                let data = try handle.read(upToCount: target.length(of: i)) ?? Data()
                guard data.count == target.length(of: i), Digest.sha256Hex(data) == digest else { throw UpdateError.hashMismatch }
            }
        }
    }

    /// Nothing installed: rebuild the keyframe's database in staging, then
    /// assemble the target from its chunks plus the chunks that changed
    /// since the keyframe. Keyframe bytes are only a chunk source: each
    /// reused chunk is matched by its own digest.
    func assembleFromKeyframe(_ keyframe: ArtifactManifest.PackIndex.Keyframe, packs: ArtifactManifest.PackIndex, manifest: ArtifactManifest, chunkList: ChunkList?, source: any ArtifactSource, into destination: URL, staging: URL) async throws -> TransferStats {
        let isTarget = keyframe.sha256 == manifest.database.sha256 && keyframe.byteSize == manifest.database.byteSize
        let partBytes = keyframe.parts.reduce(0) { $0 + $1.byteSize }
        try requireSpace(partBytes + keyframe.byteSize + (isTarget ? 0 : manifest.database.byteSize))
        let files = try await fetchParts(keyframe.parts, source: source, staging: staging)
        try Task.checkCancellation()

        let rebuilt = isTarget ? destination : staging.appendingPathComponent("keyframe.sqlite")
        FileManager.default.createFile(atPath: rebuilt.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: rebuilt)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(keyframe.byteSize))
            for file in files {
                try Task.checkCancellation()
                try autoreleasepool {
                    let part = try PagePack.decodePart(try Data(contentsOf: file), expectedBlockSize: packs.blockSize, expectedTargetSize: keyframe.byteSize)
                    guard !part.xor else { throw UpdateError.invalidChunkList("keyframe pack is XOR") }
                    try part.forEachEntry { index, payload in
                        try handle.seek(toOffset: UInt64(index) * UInt64(packs.blockSize))
                        try handle.write(contentsOf: payload)
                    }
                }
                try? FileManager.default.removeItem(at: file)
            }
            try handle.synchronize()
        }
        if isTarget {
            // Verified as a whole file by the caller.
            return TransferStats(mode: .keyframe, fetchedBytes: partBytes, fetchedPacks: files.count)
        }
        guard let chunkList else { throw UpdateError.invalidChunkList("keyframe needs a chunk list") }
        defer { try? FileManager.default.removeItem(at: rebuilt) }
        let (keyframeList, _) = try ChunkList.make(fileAt: rebuilt, chunkSize: chunkList.chunkSize)
        var local: [String: LocalChunk] = [:]
        for (i, digest) in keyframeList.digests.enumerated() where local[digest] == nil {
            local[digest] = LocalChunk(url: rebuilt, offset: UInt64(i) * UInt64(keyframeList.chunkSize), length: keyframeList.length(of: i))
        }
        var stats = try await assemble(chunkList, local: local, source: source, into: destination, staging: staging)
        stats.mode = .keyframe
        stats.fetchedPacks = files.count
        stats.fetchedBytes += partBytes
        return stats
    }

    struct LocalChunk {
        var url: URL
        var offset: UInt64
        var length: Int
    }

    /// digest → location of that chunk inside a database already installed
    /// on the device (current and previous generations).
    func localChunkIndex() async -> [String: LocalChunk] {
        var index: [String: LocalChunk] = [:]
        for generation in [await store.currentGeneration(), await store.previousGeneration()].compactMap({ $0 }) {
            let dir = store.directory(for: generation)
            let dbURL = dir.appendingPathComponent("viewer.sqlite")
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("viewer.chunks")),
                  let size = try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int64,
                  let list = try? ChunkList.decode(data, expectedTotalBytes: size) else { continue }
            for (i, digest) in list.digests.enumerated() where index[digest] == nil {
                index[digest] = LocalChunk(url: dbURL, offset: UInt64(i) * UInt64(list.chunkSize), length: list.length(of: i))
            }
        }
        return index
    }

    static let chunkFetchConcurrency = 6

    /// Builds the database from local chunks plus fetched missing chunks.
    /// Every fetched chunk is verified against its digest; every reused
    /// chunk is re-read from an installed (already validated) generation.
    func assemble(_ list: ChunkList, local: [String: LocalChunk], source: any ArtifactSource, into destination: URL, staging: URL) async throws -> TransferStats {
        var stats = TransferStats(mode: .chunks)
        let chunkDir = staging.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chunkDir) }

        var missing: [(digest: String, length: Int)] = []
        var seen = Set<String>()
        for (i, digest) in list.digests.enumerated() where local[digest] == nil && seen.insert(digest).inserted {
            missing.append((digest, list.length(of: i)))
        }
        stats.reusedChunks = list.digests.count - list.digests.filter { local[$0] == nil }.count
        stats.fetchedChunks = missing.count

        // Fetch missing chunks with bounded concurrency.
        try await withThrowingTaskGroup(of: Int64.self) { group in
            var next = 0
            func enqueue(_ item: (digest: String, length: Int)) {
                group.addTask {
                    guard let rel = ChunkList.relativePath(for: item.digest) else { throw UpdateError.invalidChunkList("name") }
                    let target = chunkDir.appendingPathComponent(item.digest)
                    do {
                        try await source.download(rel, to: target, maximumBytes: Int64(item.length))
                    } catch {
                        throw UpdateError.transport(error)
                    }
                    let data = try Data(contentsOf: target)
                    guard data.count == item.length, Digest.sha256Hex(data) == item.digest else { throw UpdateError.hashMismatch }
                    return Int64(data.count)
                }
            }
            while next < min(Self.chunkFetchConcurrency, missing.count) {
                enqueue(missing[next])
                next += 1
            }
            while let bytes = try await group.next() {
                stats.fetchedBytes += bytes
                if next < missing.count {
                    enqueue(missing[next])
                    next += 1
                }
            }
        }

        // Write the file in order.
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var readers: [URL: FileHandle] = [:]
        defer { for handle in readers.values { try? handle.close() } }
        for (i, digest) in list.digests.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
            let data: Data
            if let chunk = local[digest] {
                let handle: FileHandle
                if let h = readers[chunk.url] {
                    handle = h
                } else {
                    handle = try FileHandle(forReadingFrom: chunk.url)
                    readers[chunk.url] = handle
                }
                try handle.seek(toOffset: chunk.offset)
                data = try handle.read(upToCount: chunk.length) ?? Data()
            } else {
                data = try Data(contentsOf: chunkDir.appendingPathComponent(digest))
            }
            guard data.count == list.length(of: i) else { throw UpdateError.invalidChunkList("chunk \(i) length") }
            try output.write(contentsOf: data)
            }
        }
        try output.synchronize()
        return stats
    }
}
