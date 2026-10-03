import Foundation
import Testing
@testable import IndexerCore
import WikiShared
import WikiViewerKit

/// Page-level packs: publisher → publish dir → updater (delta on a clone,
/// keyframe + chunks), fallbacks and garbage collection.
@Suite(.serialized) struct PackTransportTests {
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

    /// Enough notes that the database spans many chunks and pages: a
    /// one-note edit dirties about a dozen scattered chunks whatever the
    /// vault size, so with 300 notes it already reached 19% of them, just
    /// under the 20% at which the keyframe is renewed. 450 notes keep it
    /// near 10%.
    static let bulkNotes = 450

    func bigEnv(configure: (inout IndexerConfiguration) -> Void = { _ in }) async throws -> (Env, Indexer) {
        var env = try Env(copyFixture: true)
        env.config.chunkSize = 16 * 1024
        configure(&env.config)
        for i in 0..<Self.bulkNotes {
            try env.write("Bulk/Note \(i).md", "# Note \(i)\n\n" + String(repeating: "Body text for note \(i) with [[Home]] and 日本語の本文。\n", count: 20))
        }
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try #require(try await indexer.publish())
        return (env, indexer)
    }

    func edit(_ env: Env, _ indexer: Indexer, _ path: String, _ text: String) async throws -> PublishResult {
        try env.write(path, text)
        _ = try await indexer.process(paths: [path])
        return try #require(try await indexer.publish())
    }

    /// Pack work files must not travel into the installed generation.
    func expectCleanGeneration(_ store: GenerationStore, _ prepared: PreparedGeneration) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(for: prepared.installed).path).sorted()
        #expect(files == ["manifest.json", "viewer.chunks", "viewer.sqlite"])
    }

    func search(_ prepared: PreparedGeneration, _ text: String) async throws -> [String] {
        let session = LibrarySession(database: try ViewerDatabase(url: prepared.databaseURL, options: .init(immutable: true)), installed: prepared.installed)
        return try await session.search.search(text, limit: 5).map(\.note.path)
    }

    @Test func firstInstallUsesKeyframeAndUpdatesUseOneDeltaPack() async throws {
        let (env, indexer) = try await bigEnv()
        let first = try #require(ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory).manifest.packs)
        #expect(first.keyframe?.generation == 1)
        #expect(first.deltas.isEmpty, "nothing to diff against yet")

        let (store, updater) = try device(env)
        let src1 = CountingSource(LocalFolderArtifactSource(root: env.config.publishDirectory))
        let g1 = try await update(updater, store, src1)
        #expect(g1.transfer.mode == .keyframe)
        #expect(src1.files.allSatisfy { $0.hasPrefix("packs/") || $0.hasSuffix(".chunks") }, "\(src1.files)")
        #expect(src1.bytes < g1.manifest.database.byteSize / 2, "compressed: \(src1.bytes) of \(g1.manifest.database.byteSize)")

        let r2 = try await edit(env, indexer, "Bulk/Note 7.md", "# Note 7\n\nEdited once.\n")
        let packs2 = try #require(r2.manifest.packs)
        #expect(packs2.deltas.count == 1)
        #expect(packs2.keyframe?.generation == 1, "keyframe still covers most chunks: \(r2.newChunks) of \(r2.manifest.chunks?.count ?? 0) new")
        let src2 = CountingSource(LocalFolderArtifactSource(root: env.config.publishDirectory))
        let g2 = try await update(updater, store, src2)
        #expect(g2.transfer.mode == .deltaPack, "\(g2.transfer)")
        #expect(g2.transfer.packFallback == nil)
        let packFiles = src2.files.filter { $0.hasPrefix("packs/") }
        #expect(packFiles.count == 1, "one file: \(src2.files)")
        #expect(!src2.files.contains { $0.hasPrefix("chunks/") })
        let chunkBytes = Int64(r2.newChunks * env.config.chunkSize)
        #expect(packs2.deltas[0].byteSize * 4 < chunkBytes, "delta \(packs2.deltas[0].byteSize) B vs new chunks \(chunkBytes) B")
        #expect(try await search(g2, "Edited once") == ["Bulk/Note 7.md"])
        try expectCleanGeneration(store, g1)
        try expectCleanGeneration(store, g2)
        #expect(try Digest.sha256Hex(fileAt: g2.databaseURL).hex == g2.manifest.database.sha256)
        // The recorded chunk list lets the next update verify incrementally.
        let recorded = try Data(contentsOf: store.directory(for: g2.installed).appendingPathComponent("viewer.chunks"))
        #expect(try ChunkList.make(fileAt: g2.databaseURL, chunkSize: env.config.chunkSize).list.encoded() == recorded)
    }

    @Test func deviceThatMissedGenerationsUsesDeltaFromOlderBase() async throws {
        let (env, indexer) = try await bigEnv()
        let (store, updater) = try device(env)
        let src = LocalFolderArtifactSource(root: env.config.publishDirectory)
        _ = try await update(updater, store, src)
        _ = try await edit(env, indexer, "Bulk/Note 1.md", "# one")
        _ = try await edit(env, indexer, "Bulk/Note 2.md", "# two")
        let r4 = try await edit(env, indexer, "Bulk/Note 3.md", "# three 三番目")
        #expect(r4.manifest.packs?.deltas.count == 3, "deltas from generations 3, 2 and 1")
        let g4 = try await update(updater, store, src)
        #expect(g4.manifest.generation == 4)
        #expect(g4.transfer.mode == .deltaPack)
        #expect(try await search(g4, "three 三番目") == ["Bulk/Note 3.md"])

        // Older than every delta base: falls back to reusing chunks.
        let (oldStore, oldUpdater) = try device(env)
        _ = try await update(oldUpdater, oldStore, src)
        for i in 10..<14 { _ = try await edit(env, indexer, "Bulk/Note \(i).md", "# edit \(i)") }
        let late = try await update(oldUpdater, oldStore, src)
        #expect(late.transfer.mode == .chunks)
        #expect(try await search(late, "edit 13") == ["Bulk/Note 13.md"])
    }

    @Test func shrinkingDatabaseIsTruncated() async throws {
        // Most pages change: allow a delta as large as the database.
        let (env, indexer) = try await bigEnv { $0.packDeltaLimitRatio = 2 }
        let (store, updater) = try device(env)
        let src = LocalFolderArtifactSource(root: env.config.publishDirectory)
        let g1 = try await update(updater, store, src)
        for i in 50..<Self.bulkNotes { try env.remove("Bulk/Note \(i).md") }
        _ = try await indexer.reconcile()
        let r2 = try #require(try await indexer.publish())
        #expect(r2.manifest.database.byteSize < g1.manifest.database.byteSize, "incremental vacuum shrank the file")
        let g2 = try await update(updater, store, src)
        #expect(g2.transfer.mode == .deltaPack)
        #expect(g2.manifest.noteCount == r2.manifest.noteCount)
    }

    @Test func newDeviceUsesOlderKeyframePlusChangedChunks() async throws {
        let (env, indexer) = try await bigEnv()
        let r2 = try await edit(env, indexer, "Bulk/Note 5.md", "# five changed")
        #expect(r2.manifest.packs?.keyframe?.generation == 1)
        let (store, updater) = try device(env)
        let src = CountingSource(LocalFolderArtifactSource(root: env.config.publishDirectory))
        let g = try await update(updater, store, src)
        #expect(g.transfer.mode == .keyframe)
        #expect(g.transfer.fetchedChunks > 0 && g.transfer.fetchedChunks < g.transfer.reusedChunks, "\(g.transfer)")
        #expect(try await search(g, "five changed") == ["Bulk/Note 5.md"])
        try expectCleanGeneration(store, g)
    }

    @Test func keyframeIsRenewedWhenTooManyChunksChanged() async throws {
        let (env, indexer) = try await bigEnv { $0.keyframeRefreshRatio = 0 }
        let r2 = try await edit(env, indexer, "Bulk/Note 5.md", "# five changed")
        #expect(r2.manifest.packs?.keyframe?.generation == 2)
        #expect(r2.keyframeBytes != nil)
        let report = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
        #expect(report.checkedPacks == (r2.manifest.packs!.keyframe!.parts.count + r2.manifest.packs!.deltas.flatMap(\.parts).count))
    }

    @Test func corruptPackFallsBackToChunks() async throws {
        let (env, indexer) = try await bigEnv()
        let (store, updater) = try device(env)
        let src = LocalFolderArtifactSource(root: env.config.publishDirectory)
        let g1 = try await update(updater, store, src)
        let r2 = try await edit(env, indexer, "Bulk/Note 9.md", "# nine")
        let part = try #require(r2.manifest.packs?.deltas.first?.parts.first)
        let url = env.config.publishDirectory.appendingPathComponent(part.path)
        var data = try Data(contentsOf: url)
        data[data.count / 2] ^= 0xFF
        try data.write(to: url)
        #expect(throws: (any Error).self) { try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory) }

        let g2 = try await update(updater, store, src)
        #expect(g2.transfer.mode == .chunks)
        #expect(g2.transfer.packFallback != nil)
        #expect(try await search(g2, "nine") == ["Bulk/Note 9.md"])
        #expect(await store.previousGeneration() == g1.installed)
        try expectCleanGeneration(store, g2)
    }

    @Test func forgedDeltaThatDecodesIsCaughtByChunkVerification() async throws {
        let (env, indexer) = try await bigEnv()
        let (store, updater) = try device(env)
        let src = LocalFolderArtifactSource(root: env.config.publishDirectory)
        let g1 = try await update(updater, store, src)
        let r2 = try await edit(env, indexer, "Bulk/Note 9.md", "# nine")
        // Replace the delta with a valid pack that writes wrong bytes, and fix
        // up the manifest so that its hashes match (a forged manifest).
        var manifest = r2.manifest
        let delta = try #require(manifest.packs?.deltas.first)
        var writer = PagePack.Writer(blockSize: manifest.packs!.blockSize, targetSize: manifest.database.byteSize, xor: true)
        var parts: [Data] = []
        for index in 0..<delta.blockCount {
            let payload = Data(repeating: 0x5A, count: PagePack.blockLength(index + 3, blockSize: manifest.packs!.blockSize, fileSize: manifest.database.byteSize))
            if let p = writer.append(index: index + 3, payload: payload) { parts.append(p) }
        }
        if let p = writer.flush() { parts.append(p) }
        var forgedParts: [ArtifactManifest.PackIndex.Part] = []
        for p in parts {
            let sha = Digest.sha256Hex(p)
            let rel = PagePack.relativePath(for: sha)!
            try FileManager.default.createDirectory(at: env.config.publishDirectory.appendingPathComponent(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
            try p.write(to: env.config.publishDirectory.appendingPathComponent(rel))
            forgedParts.append(.init(path: rel, byteSize: Int64(p.count), sha256: sha))
        }
        manifest.packs!.deltas[0].parts = forgedParts
        manifest.packs!.deltas[0].blockCount = delta.blockCount
        try manifest.encoded().write(to: env.config.publishDirectory.appendingPathComponent("manifest.json"))

        let g2 = try await update(updater, store, src)
        #expect(g2.transfer.packFallback != nil, "chunk verification rejected the patched file")
        #expect(g2.transfer.mode == .chunks)
        #expect(try Digest.sha256Hex(fileAt: g2.databaseURL).hex == r2.manifest.database.sha256)
        #expect(await store.previousGeneration() == g1.installed)
    }

    /// A source whose pack downloads never finish until cancelled.
    struct StallingPacks: ArtifactSource {
        let inner: LocalFolderArtifactSource
        var displayName: String { inner.displayName }
        var identifier: String { inner.identifier }
        func fetchManifest() async throws -> Data { try await inner.fetchManifest() }
        func download(_ relativePath: String, to destination: URL, maximumBytes: Int64) async throws {
            if relativePath.hasPrefix("packs/") {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    // Like a transport, report cancellation as a transport error.
                    throw TransportError.unavailable("cancelled")
                }
            }
            try await inner.download(relativePath, to: destination, maximumBytes: maximumBytes)
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancellingDuringPackDownloadDoesNotFallBack() async throws {
        let (env, indexer) = try await bigEnv()
        let (store, updater) = try device(env)
        let local = LocalFolderArtifactSource(root: env.config.publishDirectory)
        let g1 = try await update(updater, store, local)
        _ = try await edit(env, indexer, "Bulk/Note 2.md", "# two")
        let src = StallingPacks(inner: local)
        guard case .available(let m) = try await updater.check(source: src) else { Issue.record("no update"); return }
        let task = Task { try await updater.prepare(m, source: src) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await store.currentGeneration() == g1.installed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.stagingURL.path).isEmpty)
    }

    @Test func chunksOnlyPublicationWithPacks() async throws {
        let (env, indexer) = try await bigEnv { $0.publishFullDatabase = false }
        let (store, updater) = try device(env)
        let src = LocalFolderArtifactSource(root: env.config.publishDirectory)
        let g1 = try await update(updater, store, src)
        #expect(g1.transfer.mode == .keyframe)
        let r2 = try await edit(env, indexer, "Bulk/Note 4.md", "# four")
        #expect(!FileManager.default.fileExists(atPath: r2.databaseURL.path))
        _ = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
        let g2 = try await update(updater, store, src)
        #expect(g2.transfer.mode == .deltaPack)
    }

    @Test func garbageCollectionKeepsOnlyReferencedPacks() async throws {
        let (env, indexer) = try await bigEnv {
            $0.retainedGenerations = 1
            $0.keyframeRefreshRatio = 0
        }
        var last: PublishResult?
        for i in 0..<3 { last = try await edit(env, indexer, "Bulk/Note \(i).md", "# rewritten \(i)") }
        let referenced = Set(PackPublisher.partNames(last?.manifest.packs))
        let stored = try FileManager.default.subpathsOfDirectory(atPath: env.config.publishDirectory.appendingPathComponent("packs").path)
            .filter { $0.count > 3 }.map { String($0.split(separator: "/").last!) }
        #expect(Set(stored) == referenced)
        // Private copies: only the recent bases are kept.
        let bases = try FileManager.default.contentsOfDirectory(atPath: env.config.stateDirectory.appendingPathComponent("pack-bases").path)
        #expect(bases.filter { $0.hasSuffix(".sqlite") }.count <= env.config.packDeltaBases)
    }

    @Test func packsCanBeDisabled() async throws {
        let (env, _) = try await bigEnv { $0.publishPacks = false }
        let report = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
        #expect(report.manifest.packs == nil)
        #expect(!FileManager.default.fileExists(atPath: env.config.publishDirectory.appendingPathComponent("packs").path))
    }
}

/// HTTP: persistent connections and long polling.
@Suite(.serialized) struct HTTPSyncTests {
    final class Metrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        // @unchecked: test-only; guarded by `lock`.
        let lock = NSLock()
        var reused: [Bool] = []
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            lock.withLock { reused.append(metrics.transactionMetrics.last?.isReusedConnection ?? false) }
        }
    }

    func served() async throws -> (Env, Indexer, StaticHTTPServer, URL) {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try #require(try await indexer.publish())
        let server = try StaticHTTPServer(root: env.config.publishDirectory, port: 0)
        let port = try await server.start()
        return (env, indexer, server, URL(string: "http://127.0.0.1:\(port)/")!)
    }

    @Test func connectionsAreReused() async throws {
        let (env, _, server, url) = try await served()
        defer { server.stop() }
        defer { withExtendedLifetime(env) {} } // keeps the publish directory
        let metrics = Metrics()
        let session = URLSession(configuration: .ephemeral, delegate: metrics, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let source = HTTPArtifactSource(baseURL: url, session: session)
        for _ in 0..<3 { _ = try await source.fetchManifest() }
        #expect(metrics.lock.withLock { metrics.reused } == [false, true, true])
    }

    @Test(.timeLimit(.minutes(1))) func longPollReturnsWhenANewGenerationIsPublished() async throws {
        let (env, indexer, server, url) = try await served()
        defer { server.stop() }
        let source = HTTPArtifactSource(baseURL: url)
        // Already newer than `after`: immediate.
        let start = ContinuousClock.now
        _ = try await source.waitForManifest(after: 0, interval: .seconds(60))
        #expect(ContinuousClock.now - start < .seconds(2))

        let waiter = Task { try await source.waitForManifest(after: 1, interval: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(500))
        try env.write("Poll.md", "# Poll")
        _ = try await indexer.process(paths: ["Poll.md"])
        let published = ContinuousClock.now
        _ = try #require(try await indexer.publish())
        let data = try await waiter.value
        #expect(try ArtifactManifest.decode(data).generation == 2)
        #expect(ContinuousClock.now - published < .seconds(3), "answered on publication, not after the timeout")
    }

    @Test func longPollQueryIsParsed() {
        #expect(StaticHTTPServer.longPoll(requestPath: "/manifest.json?wait=42")! == (42, 25))
        #expect(StaticHTTPServer.longPoll(requestPath: "/manifest.json?wait=1&timeout=999")! == (1, 55))
        #expect(StaticHTTPServer.longPoll(requestPath: "/manifest.json") == nil)
        #expect(StaticHTTPServer.longPoll(requestPath: "/generations/x?wait=1") == nil)
        #expect(StaticHTTPServer.resolve(requestPath: "/packs/ab/" + String(repeating: "a", count: 64), root: URL(fileURLWithPath: "/p")) != nil)
    }

    /// The whole path an open app takes: Library.watchForUpdates over HTTP
    /// installs a new generation within seconds of its publication.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func openAppFollowsPublications() async throws {
        let (env, indexer, server, url) = try await served()
        defer { server.stop() }
        let defaults = try #require(UserDefaults(suiteName: "wikiviewer-test-\(UUID().uuidString)"))
        let library = Library(store: try GenerationStore(root: env.tmp.sub("device/WikiViewer")), defaults: defaults)
        library.setSource(.http(url))
        let watcher = Task { await library.watchForUpdates() }
        defer { watcher.cancel() }
        func waitFor(generation: Int64) async throws {
            for _ in 0..<100 {
                if library.session?.info.generation == generation { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            Issue.record("generation \(generation) not installed")
        }
        try await waitFor(generation: 1)
        try env.write("Live.md", "# Live")
        _ = try await indexer.process(paths: ["Live.md"])
        let published = ContinuousClock.now
        _ = try #require(try await indexer.publish())
        try await waitFor(generation: 2)
        #expect(ContinuousClock.now - published < .seconds(5))
    }
}

/// Publication latency on the host.
struct QuickPublicationTests {
    func config() -> IndexerConfiguration {
        var c = IndexerConfiguration(vault: URL(fileURLWithPath: "/v"), stateDirectory: URL(fileURLWithPath: "/s"), publishDirectory: URL(fileURLWithPath: "/p"))
        c.debounce = .seconds(1)
        c.quietPeriod = .seconds(20)
        c.quickQuietPeriod = .seconds(3)
        c.quickPublishMaxFiles = 5
        c.maximumPublicationDelay = .seconds(300)
        return c
    }

    @Test func smallEditUsesQuickQuietPeriod() {
        let t0 = ContinuousClock.now
        var s = PublicationScheduler(configuration: config(), now: t0)
        s.recordEvent(paths: ["a.md"], at: t0)
        s.completed(s.duePaths(at: t0 + .seconds(1)), unstable: [], changed: true, at: t0 + .seconds(1))
        #expect(!s.shouldPublish(at: t0 + .seconds(3), hasChanges: true))
        #expect(s.shouldPublish(at: t0 + .seconds(4), hasChanges: true), "published 3 s after a single edit")
    }

    @Test func burstUsesFullQuietPeriod() {
        let t0 = ContinuousClock.now
        var s = PublicationScheduler(configuration: config(), now: t0)
        let paths = (0..<20).map { "n\($0).md" }
        s.recordEvent(paths: paths, at: t0)
        s.completed(s.duePaths(at: t0 + .seconds(1)), unstable: [], changed: true, at: t0 + .seconds(1))
        #expect(!s.shouldPublish(at: t0 + .seconds(10), hasChanges: true))
        #expect(s.shouldPublish(at: t0 + .seconds(21), hasChanges: true))
        s.published()
        // The next small edit is quick again.
        s.recordEvent(paths: ["a.md"], at: t0 + .seconds(30))
        s.completed(s.duePaths(at: t0 + .seconds(31)), unstable: [], changed: true, at: t0 + .seconds(31))
        #expect(s.shouldPublish(at: t0 + .seconds(34), hasChanges: true))
    }

    @Test func reconciliationChangesUseFullQuietPeriod() {
        let t0 = ContinuousClock.now
        var s = PublicationScheduler(configuration: config(), now: t0)
        s.reconciled(changed: true, unstable: [], full: true, at: t0)
        #expect(!s.shouldPublish(at: t0 + .seconds(5), hasChanges: true))
        #expect(s.shouldPublish(at: t0 + .seconds(20), hasChanges: true))
    }

    @Test func eventsForPathsNeverIndexedAreIgnored() throws {
        let filter = try VaultFilter(excluding: ["Private"])
        #expect(IndexerDaemon.isIgnored(".obsidian/workspace.json", filter: filter))
        #expect(IndexerDaemon.isIgnored(".obsidian", filter: filter))
        #expect(IndexerDaemon.isIgnored("Notes/.DS_Store", filter: filter))
        #expect(IndexerDaemon.isIgnored("A/Private/secret.md", filter: filter))
        #expect(IndexerDaemon.isIgnored("node_modules/x/readme.md", filter: filter))
        #expect(!IndexerDaemon.isIgnored("Notes/a.md", filter: filter))
        #expect(!IndexerDaemon.isIgnored("Notes", filter: filter))
    }
}
