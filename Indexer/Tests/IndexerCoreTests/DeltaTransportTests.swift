import Foundation
import Testing
@testable import IndexerCore
import WikiShared
import WikiViewerKit

/// Byte-counting wrapper to observe what a transport actually moves.
final class CountingSource: ArtifactSource, @unchecked Sendable {
    // @unchecked: test-only; counters are only touched under `lock`.
    let inner: any ArtifactSource
    private let lock = NSLock()
    private var _bytes: Int64 = 0
    private var _files: [String] = []

    init(_ inner: any ArtifactSource) { self.inner = inner }
    var displayName: String { inner.displayName }
    var identifier: String { inner.identifier }
    var bytes: Int64 { lock.withLock { _bytes } }
    var files: [String] { lock.withLock { _files } }

    func fetchManifest() async throws -> Data { try await inner.fetchManifest() }

    func download(_ relativePath: String, to destination: URL, maximumBytes: Int64) async throws {
        try await inner.download(relativePath, to: destination, maximumBytes: maximumBytes)
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        lock.withLock {
            _bytes += size
            _files.append(relativePath)
        }
    }
}

@Suite(.serialized) struct DeltaTransportTests {
    func device(_ env: Env) throws -> (GenerationStore, ArtifactUpdater) {
        let store = try GenerationStore(root: env.tmp.sub("device-\(UUID().uuidString)/WikiViewer"))
        return (store, ArtifactUpdater(store: store))
    }

    func update(_ updater: ArtifactUpdater, _ store: GenerationStore, _ source: any ArtifactSource) async throws -> PreparedGeneration {
        guard case .available(let m) = try await updater.check(source: source) else { throw CancellationError() }
        let p = try await updater.prepare(m, source: source)
        try await store.setCurrent(p.installed, lineage: source.identifier)
        await store.prune()
        _ = try ViewerDatabase(url: p.databaseURL, options: .init(immutable: true))
        return p
    }

    /// Enough notes that the database spans many chunks.
    func bigEnv() async throws -> (Env, Indexer) {
        var env = try Env(copyFixture: true)
        env.config.chunkSize = 16 * 1024
        for i in 0..<300 {
            try env.write("Bulk/Note \(i).md", "# Note \(i)\n\n" + String(repeating: "Body text for note \(i) with [[Home]] and 日本語の本文。\n", count: 20))
        }
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try #require(try await indexer.publish())
        return (env, indexer)
    }

    @Test func secondGenerationTransfersOnlyChangedChunks() async throws {
        let (env, indexer) = try await bigEnv()
        let (store, updater) = try device(env)
        let first = CountingSource(LocalFolderArtifactSource(root: env.config.publishDirectory))
        let g1 = try await update(updater, store, first)
        #expect(g1.transfer.mode == .fullDownload, "nothing local to reuse on first install")

        try env.write("Bulk/Note 7.md", "# Note 7\n\nEdited once.\n")
        _ = try await indexer.process(paths: ["Bulk/Note 7.md"])
        let published = try #require(try await indexer.publish())
        #expect(published.newChunks < published.manifest.chunks!.count / 4)

        let second = CountingSource(LocalFolderArtifactSource(root: env.config.publishDirectory))
        let g2 = try await update(updater, store, second)
        #expect(g2.transfer.mode == .chunks)
        #expect(g2.transfer.reusedChunks > g2.transfer.fetchedChunks * 3, "\(g2.transfer)")
        #expect(second.bytes < published.manifest.database.byteSize / 3, "delta moved \(second.bytes) of \(published.manifest.database.byteSize) bytes")
        #expect(!second.files.contains(published.manifest.database.path), "whole database not downloaded")
        let session = LibrarySession(database: try ViewerDatabase(url: g2.databaseURL, options: .init(immutable: true)), installed: g2.installed)
        #expect(try await session.search.search("Edited once", limit: 5).map(\.note.path) == ["Bulk/Note 7.md"])
    }

    @Test func chunksOnlyPublicationWorksForFirstInstallAndUpdates() async throws {
        var (env, _) = try await bigEnv()
        env.config.publishFullDatabase = false
        let indexer = try Indexer(configuration: env.config)
        try env.write("x.md", "# x")
        _ = try await indexer.process(paths: ["x.md"])
        let r = try #require(try await indexer.publish())
        #expect(!FileManager.default.fileExists(atPath: r.databaseURL.path), "no whole database in chunks-only mode")
        _ = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)

        let (store, updater) = try device(env)
        let src = LocalFolderArtifactSource(root: env.config.publishDirectory)
        let g = try await update(updater, store, src)
        #expect(g.transfer.mode == .chunks)
        #expect(g.transfer.reusedChunks == 0)
    }

    @Test func tamperedChunkIsRejected() async throws {
        let (env, indexer) = try await bigEnv()
        let (store, updater) = try device(env)
        let src = LocalFolderArtifactSource(root: env.config.publishDirectory)
        let g1 = try await update(updater, store, src)
        try env.write("Bulk/Note 1.md", "# changed")
        _ = try await indexer.process(paths: ["Bulk/Note 1.md"])
        let r = try #require(try await indexer.publish())
        // Corrupt every chunk that is new in this generation.
        let list = try ChunkList.decode(Data(contentsOf: env.config.publishDirectory.appendingPathComponent(r.manifest.chunks!.path)), expectedTotalBytes: r.manifest.database.byteSize)
        let old = try ChunkList.make(fileAt: g1.databaseURL, chunkSize: list.chunkSize).list
        for digest in Set(list.digests).subtracting(old.digests) {
            let url = env.config.publishDirectory.appendingPathComponent(ChunkList.relativePath(for: digest)!)
            var data = try Data(contentsOf: url)
            data[0] ^= 0xFF
            try data.write(to: url)
        }
        guard case .available(let m) = try await updater.check(source: src) else { Issue.record("no update"); return }
        await #expect(throws: UpdateError.self) { _ = try await updater.prepare(m, source: src) }
        #expect(await store.currentGeneration() == g1.installed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.stagingURL.path).isEmpty)
    }

    @Test func tamperedChunkListIsRejected() async throws {
        let (env, _) = try await bigEnv()
        let (_, updater) = try device(env)
        let src = LocalFolderArtifactSource(root: env.config.publishDirectory)
        guard case .available(let m) = try await updater.check(source: src) else { Issue.record("no update"); return }
        let listURL = env.config.publishDirectory.appendingPathComponent(m.chunks!.path)
        var text = try String(contentsOf: listURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\n0", with: "\n1")
        try text.write(to: listURL, atomically: false, encoding: .utf8)
        await #expect(throws: UpdateError.self) { _ = try await updater.prepare(m, source: src) }
    }

    @Test func garbageCollectionKeepsChunksOfRetainedGenerations() async throws {
        var (env, _) = try await bigEnv()
        env.config.retainedGenerations = 1
        let indexer = try Indexer(configuration: env.config)
        for i in 0..<3 {
            try env.write("Bulk/Note \(i).md", "# rewritten \(i)")
            _ = try await indexer.process(paths: ["Bulk/Note \(i).md"])
            _ = try await indexer.publish()
        }
        let report = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
        let list = try ChunkList.decode(Data(contentsOf: env.config.publishDirectory.appendingPathComponent(report.manifest.chunks!.path)), expectedTotalBytes: report.manifest.database.byteSize)
        let stored = try FileManager.default.subpathsOfDirectory(atPath: env.config.publishDirectory.appendingPathComponent("chunks").path).filter { $0.count > 3 }.count
        #expect(stored == Set(list.digests).count, "only the retained generation's chunks remain")
        let gens = try FileManager.default.contentsOfDirectory(atPath: env.config.publishDirectory.appendingPathComponent("generations").path).sorted()
        #expect(gens == ["viewer-000004.assets", "viewer-000004.chunks", "viewer-000004.sqlite"])
    }
}
