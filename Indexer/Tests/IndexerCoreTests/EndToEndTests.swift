import Foundation
import Testing
@testable import IndexerCore
import WikiShared
import WikiViewerKit

/// indexer → publish dir → HTTP server → HTTPArtifactSource → updater →
/// generation store → read-only viewer database → repositories.
@Suite(.serialized) struct EndToEndTests {
    @Test func httpTransportEndToEnd() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try #require(try await indexer.publish())

        let server = try StaticHTTPServer(root: env.config.publishDirectory, port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let source = HTTPArtifactSource(baseURL: URL(string: "http://127.0.0.1:\(port)/")!)

        let store = try GenerationStore(root: env.tmp.sub("device/WikiViewer"))
        let updater = ArtifactUpdater(store: store)

        // Generation 1.
        guard case .available(let m1) = try await updater.check(source: source) else { Issue.record("no update"); return }
        let p1 = try await updater.prepare(m1, source: source)
        try await store.setCurrent(p1.installed, lineage: source.identifier)
        let db1 = try ViewerDatabase(url: p1.databaseURL, options: .init(immutable: true))
        let session1 = LibrarySession(database: db1, installed: p1.installed)
        let homeID = try #require(try await session1.notes.noteID(path: "Home.md"))
        #expect(try await session1.links.backlinkCount(to: homeID) == 3)
        #expect(try await session1.search.search("東京都", limit: 5).map(\.note.path) == ["日本語/東京メモ.md"])

        // Lazy asset fetch over HTTP with hash verification.
        let links = try await session1.links.outgoingLinks(of: homeID)
        let photoID = try #require(links.first { $0.raw == "photo.jpg|400" }?.targetAssetID)
        let photo = try #require(try await session1.assets.asset(id: photoID))
        let assets = AssetProvider(storeRoot: store.assetsURL, source: source)
        let blob = try await assets.blobURL(for: photo)
        #expect(try Digest.sha256Hex(fileAt: blob).hex == photo.blobSHA256)

        // Up to date → no work.
        #expect(try await updater.check(source: source) == .upToDate(current: 1))

        // Vault changes → generation 2 → device switches; old stays as fallback.
        try env.write("New Note.md", "# New Note\n\n[[Home]] 新しいメモ")
        _ = try await indexer.process(paths: ["New Note.md"])
        _ = try #require(try await indexer.publish())
        guard case .available(let m2) = try await updater.check(source: source) else { Issue.record("no update 2"); return }
        #expect(m2.generation == 2)
        let p2 = try await updater.prepare(m2, source: source)
        try await store.setCurrent(p2.installed, lineage: source.identifier)
        await store.prune()
        let session2 = LibrarySession(database: try ViewerDatabase(url: p2.databaseURL, options: .init(immutable: true)), installed: p2.installed)
        let home2 = try #require(try await session2.notes.noteID(path: "Home.md"))
        #expect(try await session2.links.backlinkCount(to: home2) == 4)
        #expect(try await session2.search.search("新しいメモ", limit: 5).map(\.note.path) == ["New Note.md"])
        #expect(await store.installedGenerations() == [p2.installed, p1.installed])
        // Session 1 is still readable while it is referenced.
        #expect(try await session1.notes.noteID(path: "New Note.md") == nil)

        // Manifest synced but neither the database, its new chunks nor its
        // packs yet (partial sync): rejected, current kept.
        try env.write("Another.md", "# Another")
        _ = try await indexer.process(paths: ["Another.md"])
        let r3 = try #require(try await indexer.publish())
        try FileManager.default.removeItem(at: r3.databaseURL)
        let list3 = try ChunkList.decode(Data(contentsOf: env.config.publishDirectory.appendingPathComponent(r3.manifest.chunks!.path)), expectedTotalBytes: r3.manifest.database.byteSize)
        let list2 = try ChunkList.make(fileAt: p2.databaseURL, chunkSize: list3.chunkSize).list
        let newChunk = try #require(Set(list3.digests).subtracting(list2.digests).first)
        try FileManager.default.removeItem(at: env.config.publishDirectory.appendingPathComponent(ChunkList.relativePath(for: newChunk)!))
        for part in (r3.manifest.packs?.deltas.flatMap(\.parts) ?? []) + (r3.manifest.packs?.keyframe?.parts ?? []) {
            try? FileManager.default.removeItem(at: env.config.publishDirectory.appendingPathComponent(part.path))
        }
        guard case .available(let m3) = try await updater.check(source: source) else { Issue.record("no update 3"); return }
        await #expect(throws: UpdateError.self) { _ = try await updater.prepare(m3, source: source) }
        #expect(await store.currentGeneration() == p2.installed)
    }

    @Test func httpRejectsTraversalAndNonPublishedFiles() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()
        // A secret file next to the publish directory contents.
        try Data("secret".utf8).write(to: env.config.publishDirectory.appendingPathComponent("secret.txt"))
        let server = try StaticHTTPServer(root: env.config.publishDirectory, port: 0)
        let port = try await server.start()
        defer { server.stop() }
        for path in ["/secret.txt", "/../state/builder.sqlite", "/generations/../secret.txt", "/.tmp/manifest.json.tmp"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 404, "\(path)")
        }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/manifest.json")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try ArtifactManifest.decode(data).generation == 1)
    }
}
