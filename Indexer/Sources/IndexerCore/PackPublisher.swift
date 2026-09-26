//
//  PackPublisher.swift
//  IndexerCore
//
//  Publishes page-level packs (WikiShared/PagePack.swift) next to chunks:
//
//   - a *delta* from each of the last `packDeltaBases` published databases
//     to the new one: a device that has one of them installed downloads one
//     small file instead of every changed 128 KiB chunk;
//   - a *keyframe*, the whole database compressed, renewed only when too
//     many of the current generation's chunks are missing from it: a device
//     with nothing installed downloads it and fetches only the remaining
//     chunks.
//
//  Computing a delta needs the base database, which a chunks-only
//  publication does not keep; the publisher therefore keeps private copies
//  of recent databases in `<state>/pack-bases/` (APFS clones where
//  possible). Only chunks whose digests differ are read and compared, so a
//  delta costs time proportional to the change, not the database.
//
//  State changes become effective only after the manifest naming the new
//  packs is in place (`commit`); files left by a failed publication are
//  removed on the next one.
//

import Foundation
import WikiShared

final class PackPublisher {
    let configuration: IndexerConfiguration

    init(configuration: IndexerConfiguration) {
        self.configuration = configuration
    }

    var basesDirectory: URL { configuration.stateDirectory.appendingPathComponent("pack-bases", isDirectory: true) }
    var stateURL: URL { basesDirectory.appendingPathComponent("state.json") }
    var packStoreURL: URL { configuration.publishDirectory.appendingPathComponent("packs", isDirectory: true) }

    struct Base: Codable, Equatable {
        var generation: Int64
        var sha256: String
        var byteSize: Int64
    }

    struct State: Codable, Equatable {
        /// Newest first; each has `g-<generation>.sqlite` and `.chunks`.
        var recent: [Base] = []
        /// The published keyframe; its chunk list is `keyframe.chunks`.
        var keyframe: ArtifactManifest.PackIndex.Keyframe?
    }

    /// Result of `build`, applied by `commit` once the manifest is published.
    struct Pending {
        var index: ArtifactManifest.PackIndex
        var state: State
        var newKeyframeList: ChunkList?
    }

    struct Stats {
        var deltas: [(base: Int64, blocks: Int, bytes: Int64)] = []
        var keyframeBytes: Int64?
    }

    func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    func baseURL(_ generation: Int64) -> URL { basesDirectory.appendingPathComponent("g-\(generation).sqlite") }
    func baseListURL(_ generation: Int64) -> URL { basesDirectory.appendingPathComponent("g-\(generation).chunks") }
    var keyframeListURL: URL { basesDirectory.appendingPathComponent("keyframe.chunks") }

    /// Builds the packs for a finished snapshot and keeps a private copy of it
    /// as a future base. Returns nil (no packs) if the file is not a database
    /// whose page size divides the chunk size.
    func build(database: URL, list: ChunkList, sha256: String, generation: Int64) throws -> (Pending, Stats)? {
        let fm = FileManager.default
        try fm.createDirectory(at: basesDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: packStoreURL, withIntermediateDirectories: true)
        var state = loadState()
        removeUnreferencedBases(state)

        let handle = try FileHandle(forReadingFrom: database)
        let header = try handle.read(upToCount: 100) ?? Data()
        try handle.close()
        guard let blockSize = PagePack.sqlitePageSize(header: header), list.chunkSize % blockSize == 0 else {
            Log.warning("packs: unsupported page size; publishing chunks only")
            return nil
        }
        var stats = Stats()
        var touched = Set<URL>()
        defer { for dir in touched { try? fsyncPath(dir) } }

        // Deltas from recent bases (their private copies must still exist).
        var deltas: [ArtifactManifest.PackIndex.Delta] = []
        let limit = Int64(Double(list.totalBytes) * configuration.packDeltaLimitRatio)
        for base in state.recent.prefix(min(configuration.packDeltaBases, ArtifactManifest.PackIndex.maximumDeltas)) where base.sha256 != sha256 {
            guard let baseData = try? Data(contentsOf: baseListURL(base.generation)),
                  let baseList = try? ChunkList.decode(baseData, expectedTotalBytes: base.byteSize),
                  baseList.chunkSize == list.chunkSize,
                  fm.fileExists(atPath: baseURL(base.generation).path) else { continue }
            guard let delta = try makeDelta(base: base, baseList: baseList, target: database, targetList: list, blockSize: blockSize, limit: limit, touched: &touched) else {
                Log.debug("packs: delta from \(base.generation) exceeds the limit; skipped")
                continue
            }
            deltas.append(delta)
            stats.deltas.append((base.generation, delta.blockCount, delta.byteSize))
        }

        // Keyframe: keep the current one while it still covers enough chunks.
        var keyframe = state.keyframe
        var newKeyframeList: ChunkList?
        if !keyframeStillUseful(keyframe, list: list) {
            let parts = try writeKeyframe(database: database, list: list, blockSize: blockSize, touched: &touched)
            if parts.count <= ArtifactManifest.PackIndex.maximumParts {
                keyframe = .init(generation: generation, byteSize: list.totalBytes, sha256: sha256, parts: parts)
                newKeyframeList = list
                stats.keyframeBytes = parts.reduce(0) { $0 + $1.byteSize }
            } else {
                // Too large for one manifest: new devices use chunks.
                keyframe = nil
            }
        }

        // The new database becomes a base (clone, not a copy, on APFS).
        let copy = baseURL(generation)
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: database, to: copy)
        try list.encoded().write(to: baseListURL(generation), options: .atomic)

        state.recent.insert(Base(generation: generation, sha256: sha256, byteSize: list.totalBytes), at: 0)
        state.recent = Array(state.recent.prefix(max(configuration.packDeltaBases, 1)))
        state.keyframe = keyframe
        let index = ArtifactManifest.PackIndex(blockSize: blockSize, keyframe: keyframe, deltas: deltas)
        return (Pending(index: index, state: state, newKeyframeList: newKeyframeList), stats)
    }

    /// Makes `pending` the pack state (after the manifest was published).
    func commit(_ pending: Pending) throws {
        if let list = pending.newKeyframeList {
            try list.encoded().write(to: keyframeListURL, options: .atomic)
        }
        try JSONEncoder().encode(pending.state).write(to: stateURL, options: .atomic)
        removeUnreferencedBases(pending.state)
    }

    /// Private copies not named by the state (older bases, failed publications).
    func removeUnreferencedBases(_ state: State) {
        let fm = FileManager.default
        let keep = Set(state.recent.flatMap { ["g-\($0.generation).sqlite", "g-\($0.generation).chunks"] } + ["state.json", "keyframe.chunks"])
        for name in (try? fm.contentsOfDirectory(atPath: basesDirectory.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: basesDirectory.appendingPathComponent(name))
        }
    }

    /// Pack parts referenced by a published index.
    static func partNames(_ index: ArtifactManifest.PackIndex?) -> [String] {
        guard let index else { return [] }
        return ((index.keyframe?.parts ?? []) + index.deltas.flatMap(\.parts)).map(\.sha256)
    }

    // MARK: Keyframe

    func keyframeStillUseful(_ keyframe: ArtifactManifest.PackIndex.Keyframe?, list: ChunkList) -> Bool {
        guard let keyframe,
              keyframe.parts.allSatisfy({ FileManager.default.fileExists(atPath: configuration.publishDirectory.appendingPathComponent($0.path).path) }),
              let data = try? Data(contentsOf: keyframeListURL),
              let keyframeList = try? ChunkList.decode(data, expectedTotalBytes: keyframe.byteSize),
              keyframeList.chunkSize == list.chunkSize else { return false }
        let covered = Set(keyframeList.digests)
        let missing = list.digests.lazy.filter { !covered.contains($0) }.count
        return Double(missing) <= Double(list.digests.count) * configuration.keyframeRefreshRatio
    }

    func writeKeyframe(database: URL, list: ChunkList, blockSize: Int, touched: inout Set<URL>) throws -> [ArtifactManifest.PackIndex.Part] {
        let reader = try BlockReader(url: database, capacity: 1 << 20)
        var writer = PagePack.Writer(blockSize: blockSize, targetSize: list.totalBytes, xor: false)
        var parts: [ArtifactManifest.PackIndex.Part] = []
        var index = 0
        var position: Int64 = 0
        while position < list.totalBytes {
            let bytes = try reader.read(at: UInt64(position), count: Int(min(Int64(reader.capacity), list.totalBytes - position)))
            guard !bytes.isEmpty else { throw PublisherError(description: "database shorter than its chunk list") }
            var offset = 0
            while offset < bytes.count {
                let length = PagePack.blockLength(index, blockSize: blockSize, fileSize: list.totalBytes)
                guard offset + length <= bytes.count else { throw PublisherError(description: "read not aligned to blocks") }
                if let part = writer.append(index: index, payload: UnsafeRawBufferPointer(rebasing: bytes[offset ..< offset + length])) {
                    parts.append(try store(part, touched: &touched))
                }
                offset += length
                index += 1
            }
            position += Int64(bytes.count)
        }
        if let part = writer.flush() { parts.append(try store(part, touched: &touched)) }
        return parts
    }

    // MARK: Delta

    /// Blocks of `target` that differ from `base`, XORed against the base
    /// block. Only chunks whose digests differ are read. Returns nil if the
    /// raw delta would exceed `limit` bytes.
    func makeDelta(base: Base, baseList: ChunkList, target: URL, targetList: ChunkList, blockSize: Int, limit: Int64, touched: inout Set<URL>) throws -> ArtifactManifest.PackIndex.Delta? {
        let chunkSize = targetList.chunkSize
        let targetReader = try BlockReader(url: target, capacity: chunkSize)
        let baseReader = try BlockReader(url: baseURL(base.generation), capacity: chunkSize)
        let blocksPerChunk = chunkSize / blockSize
        var writer = PagePack.Writer(blockSize: blockSize, targetSize: targetList.totalBytes, xor: true)
        var parts: [ArtifactManifest.PackIndex.Part] = []
        for (i, digest) in targetList.digests.enumerated() {
            if i < baseList.digests.count, baseList.digests[i] == digest, baseList.length(of: i) == targetList.length(of: i) { continue }
            let targetChunk = try targetReader.read(at: UInt64(i) * UInt64(chunkSize), count: targetList.length(of: i))
            guard targetChunk.count == targetList.length(of: i) else { throw PublisherError(description: "short read of chunk \(i)") }
            let baseChunk = i < baseList.digests.count
                ? try baseReader.read(at: UInt64(i) * UInt64(chunkSize), count: baseList.length(of: i))
                : UnsafeRawBufferPointer(start: nil, count: 0)
            var offset = 0
            var block = i * blocksPerChunk
            while offset < targetChunk.count {
                let length = PagePack.blockLength(block, blockSize: blockSize, fileSize: targetList.totalBytes)
                let t = UnsafeRawBufferPointer(rebasing: targetChunk[offset ..< offset + length])
                let b = offset < baseChunk.count ? UnsafeRawBufferPointer(rebasing: baseChunk[offset ..< min(offset + length, baseChunk.count)]) : UnsafeRawBufferPointer(start: nil, count: 0)
                if b.count != t.count || memcmp(b.baseAddress!, t.baseAddress!, t.count) != 0 {
                    if let part = writer.append(index: block, payload: PagePack.xor(Data(t), base: Data(b))) {
                        parts.append(try store(part, touched: &touched))
                    }
                    if writer.totalRawBytes > limit { return nil }
                }
                offset += length
                block += 1
            }
        }
        if let part = writer.flush() { parts.append(try store(part, touched: &touched)) }
        // Blocks past the end of a shrunken target need no entry: the device
        // truncates to the target size. A target identical to its base (only
        // possible if both hashes match, excluded by the caller) has no parts.
        guard !parts.isEmpty else { return nil }
        return .init(baseSHA256: base.sha256, baseByteSize: base.byteSize, blockCount: writer.totalBlocks, parts: parts)
    }

    // MARK: Store

    /// Writes a part content-addressed under `packs/` (once).
    func store(_ part: Data, touched: inout Set<URL>) throws -> ArtifactManifest.PackIndex.Part {
        let digest = Digest.sha256Hex(part)
        guard let rel = PagePack.relativePath(for: digest) else { throw PublisherError(description: "pack digest") }
        let target = configuration.publishDirectory.appendingPathComponent(rel)
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.path) {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(digest).\(UUID().uuidString).tmp")
            try part.write(to: tmp)
            try fsyncPath(tmp)
            try atomicRename(tmp, to: target)
            touched.insert(target.deletingLastPathComponent())
        }
        return .init(path: rel, byteSize: Int64(part.count), sha256: digest)
    }
}

/// Reads a file with pread(2) into one buffer reused across calls.
/// FileHandle.read returns a fresh buffer per call; reading a database of
/// hundreds of megabytes that way leaves the freed buffers dirty in malloc's
/// cache (measured: +80 MiB of footprint for a 94 MiB keyframe).
final class BlockReader {
    let fd: Int32
    let buffer: UnsafeMutableRawBufferPointer
    var capacity: Int { buffer.count }

    init(url: URL, capacity: Int) throws {
        fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        buffer = .allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        close(fd)
        buffer.deallocate()
    }

    /// Up to `count` (≤ capacity) bytes at `offset`; fewer only at the end of
    /// the file. The bytes are valid until the next call.
    func read(at offset: UInt64, count: Int) throws -> UnsafeRawBufferPointer {
        precondition(count <= capacity)
        var done = 0
        while done < count {
            let n = pread(fd, buffer.baseAddress! + done, count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { break }
            done += n
        }
        return UnsafeRawBufferPointer(rebasing: buffer[0 ..< done])
    }
}
