//
//  ArtifactUpdater.swift
//  WikiViewerKit
//
//  transport → staging → size/SHA-256 → SQLite validation → generations/NNNNNN
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

    public enum Mode: Sendable, Equatable {
        case alreadyInstalled
        case fullDownload
        case chunks
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

    public func check(source: any ArtifactSource) async throws -> UpdateCheck {
        let data: Data
        do {
            data = try await source.fetchManifest()
        } catch {
            throw UpdateError.transport(error)
        }
        let manifest: ArtifactManifest
        do {
            manifest = try ArtifactManifest.decode(data)
        } catch {
            throw UpdateError.malformedManifest(String(describing: error))
        }
        do {
            try manifest.validate()
        } catch {
            throw UpdateError.invalidManifest(error)
        }
        let current = await store.currentGeneration()
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
        try manifest.validate()
        // Already installed and validated by an earlier (interrupted) run.
        let expected = InstalledGeneration(manifest: manifest)
        if await store.installedGenerations().contains(expected), await store.manifest(for: expected) == manifest {
            return PreparedGeneration(manifest: manifest, installed: expected, databaseURL: store.databaseURL(for: expected))
        }
        // Staging may hold fetched chunks plus the assembled file: require
        // twice the database size plus a margin before downloading anything.
        let needed = manifest.database.byteSize * 2 + 64 * 1024 * 1024
        if let available = try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           available < needed {
            throw UpdateError.insufficientSpace(needed: needed, available: available)
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
        }

        let local = await localChunkIndex()
        if let chunkList, !local.isEmpty {
            // Delta: reuse chunks of the generations already on the device.
            transfer = try await assemble(chunkList, local: local, source: source, into: stagedDB, staging: staging)
        } else {
            do {
                try await source.download(manifest.database.path, to: stagedDB, maximumBytes: manifest.database.byteSize)
                transfer.mode = .fullDownload
                transfer.fetchedBytes = manifest.database.byteSize
            } catch TransportError.notFound(_) where chunkList != nil {
                // Chunks-only publication: assemble from chunks alone.
                transfer = try await assemble(chunkList!, local: [:], source: source, into: stagedDB, staging: staging)
            } catch {
                throw UpdateError.transport(error)
            }
        }
        try Task.checkCancellation()

        // 1. Size and SHA-256 over the whole assembled file (streamed). The
        //    same pass records this generation's chunk list for future deltas.
        let chunkSize = chunkList?.chunkSize ?? ChunkList.defaultChunkSize
        let (computedList, sha) = try ChunkList.make(fileAt: stagedDB, chunkSize: chunkSize)
        let size = computedList.totalBytes
        guard size == manifest.database.byteSize else {
            throw UpdateError.sizeMismatch(expected: manifest.database.byteSize, actual: size)
        }
        guard sha == manifest.database.sha256 else { throw UpdateError.hashMismatch }
        try computedList.encoded().write(to: staging.appendingPathComponent("viewer.chunks"))

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
