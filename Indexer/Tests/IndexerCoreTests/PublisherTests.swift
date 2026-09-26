import Foundation
import GRDB
import Testing
@testable import IndexerCore
import WikiShared

@Suite struct PublisherTests {
    func indexed() async throws -> (Env, Indexer) {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        return (env, indexer)
    }

    @Test func publishedArtifactIsSelfContainedAndClean() async throws {
        let (env, indexer) = try await indexed()
        let result = try #require(try await indexer.publish())
        let dir = env.config.publishDirectory
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("generations").path)
        #expect(files.sorted() == ["viewer-000001.assets", "viewer-000001.chunks", "viewer-000001.packs", "viewer-000001.sqlite"], "no -wal/-shm/-journal side files")
        let report = try ArtifactVerifier.verify(publishDirectory: dir)
        #expect(report.manifest == result.manifest)
        #expect(report.tables["builder_state"] == nil)

        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: result.databaseURL.path, configuration: config)
        try await queue.read { (db: Database) throws in
            #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "delete")
            #expect(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'generation'") == "1")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM builder_state") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM asset_derivatives") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_stat1") ?? 0 > 0, "planner statistics are shipped")
        }
    }

    @Test func crashBeforeDatabaseRenameKeepsPreviousGeneration() async throws {
        let (env, indexer) = try await indexed()
        let first = try #require(try await indexer.publish())
        try env.write("New.md", "# new")
        _ = try await indexer.process(paths: ["New.md"])
        await #expect(throws: PublisherError.self) { try await indexer.publish(failpoint: .beforeDatabaseRename) }
        let report = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
        #expect(report.manifest == first.manifest, "manifest still points at the previous valid generation")
        // Next run recovers: leftovers are cleaned and a new generation is published.
        let second = try #require(try await indexer.publish())
        #expect(second.manifest.generation == 2)
        #expect(second.manifest.noteCount == first.manifest.noteCount + 1)
        let tmp = try FileManager.default.contentsOfDirectory(atPath: env.config.publishDirectory.appendingPathComponent(".tmp").path)
        #expect(tmp.isEmpty)
    }

    @Test func crashBeforeManifestRenameKeepsPreviousGeneration() async throws {
        let (env, indexer) = try await indexed()
        let first = try #require(try await indexer.publish())
        try env.write("New.md", "# new")
        _ = try await indexer.process(paths: ["New.md"])
        await #expect(throws: PublisherError.self) { try await indexer.publish(failpoint: .beforeManifestRename) }
        #expect(try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory).manifest == first.manifest)
        let second = try #require(try await indexer.publish())
        #expect(second.manifest.generation == 3, "the orphaned generation 2 number is never reused")
        _ = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
    }

    @Test func corruptSnapshotIsNeverPublished() async throws {
        let (env, indexer) = try await indexed()
        let first = try #require(try await indexer.publish())
        try env.write("New.md", "# new")
        _ = try await indexer.process(paths: ["New.md"])
        await #expect(throws: (any Error).self) { try await indexer.publish(failpoint: .corruptSnapshot) }
        #expect(try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory).manifest == first.manifest)
        #expect(await indexer.hasUnpublishedChanges, "changes stay pending after a failed publication")
    }

    @Test func tamperedArtifactFailsVerification() async throws {
        let (env, indexer) = try await indexed()
        let result = try #require(try await indexer.publish())
        let handle = try FileHandle(forWritingTo: result.databaseURL)
        try handle.seek(toOffset: 100)
        handle.write(Data([0x42]))
        try handle.close()
        #expect(throws: IndexerError.self) { try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory) }
    }

    @Test func retentionAndAssetGarbageCollection() async throws {
        var (env, _) = try await indexed()
        env.config.retainedGenerations = 2
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.publish(force: true)
        // Remove the large photo: its derivative becomes unreferenced once
        // no retained generation refers to it.
        try env.remove("attachments/photo.jpg")
        let homeText = try String(contentsOf: env.vault.appendingPathComponent("Home.md"), encoding: .utf8)
        try env.write("Home.md", homeText.replacingOccurrences(of: "![[photo.jpg|400]]", with: ""))
        _ = try await indexer.process(paths: ["attachments/photo.jpg", "Home.md"])
        _ = try await indexer.publish()
        let blobDirs = { try FileManager.default.subpathsOfDirectory(atPath: env.config.assetStoreURL.path).filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") } }
        #expect(try blobDirs().count == 2, "generation 1 still references the photo")
        try env.write("x.md", "x")
        _ = try await indexer.process(paths: ["x.md"])
        _ = try await indexer.publish()
        let gens = try FileManager.default.contentsOfDirectory(atPath: env.config.publishDirectory.appendingPathComponent("generations").path).sorted()
        #expect(gens.filter { $0.hasSuffix(".sqlite") } == ["viewer-000002.sqlite", "viewer-000003.sqlite"])
        #expect(try blobDirs().count == 1, "photo derivative collected once unreferenced (grace 0 in tests)")
        _ = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
    }

    @Test func missingBlobIsDroppedFromSnapshotAndReprocessed() async throws {
        let (env, indexer) = try await indexed()
        _ = try await indexer.publish()
        // Somebody deleted the whole asset store.
        try FileManager.default.removeItem(at: env.config.assetStoreURL)
        try env.write("y.md", "y")
        _ = try await indexer.process(paths: ["y.md"])
        let result = try #require(try await indexer.publish())
        #expect(result.missingBlobs == 2)
        #expect(result.manifest.assetCount == 0)
        _ = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
        // The builder marked the assets stale; the next reconcile restores them.
        let stats = try await indexer.reconcile()
        #expect(stats.index.assetsWritten == 3)
        let repaired = try #require(try await indexer.publish())
        #expect(repaired.manifest.assetCount == 3)
        _ = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
    }

    @Test func httpServerRejectsTraversal() {
        let root = URL(fileURLWithPath: "/srv/publish")
        #expect(StaticHTTPServer.resolve(requestPath: "/manifest.json", root: root)?.path == "/srv/publish/manifest.json")
        #expect(StaticHTTPServer.resolve(requestPath: "/generations/viewer-000001.sqlite", root: root) != nil)
        #expect(StaticHTTPServer.resolve(requestPath: "/assets/ab/abc.jpg", root: root) != nil)
        #expect(StaticHTTPServer.resolve(requestPath: "/chunks/ab/abc", root: root) != nil)
        #expect(StaticHTTPServer.resolve(requestPath: "/../etc/passwd", root: root) == nil)
        #expect(StaticHTTPServer.resolve(requestPath: "/assets/../../etc/passwd", root: root) == nil)
        #expect(StaticHTTPServer.resolve(requestPath: "/%2e%2e/etc/passwd", root: root) == nil)
        #expect(StaticHTTPServer.resolve(requestPath: "/.tmp/x", root: root) == nil)
        #expect(StaticHTTPServer.resolve(requestPath: "/state/builder.sqlite", root: root) == nil)
        #expect(StaticHTTPServer.resolve(requestPath: "/assets/ab/.hidden", root: root) == nil)
    }
}

@Suite struct SchedulerTests {
    func config() -> IndexerConfiguration {
        var c = IndexerConfiguration(vault: URL(fileURLWithPath: "/v"), stateDirectory: URL(fileURLWithPath: "/s"), publishDirectory: URL(fileURLWithPath: "/p"))
        c.debounce = .seconds(1)
        c.quietPeriod = .seconds(10)
        // The quick path has its own tests; these exercise the full period.
        c.quickQuietPeriod = .seconds(10)
        c.maximumPublicationDelay = .seconds(60)
        c.reconciliationInterval = .seconds(600)
        c.unstableRetryDelay = .seconds(2)
        return c
    }

    @Test func debounceThenQuietPeriod() {
        let t0 = ContinuousClock.now
        var s = PublicationScheduler(configuration: config(), now: t0)
        s.recordEvent(paths: ["a.md"], at: t0)
        #expect(s.duePaths(at: t0 + .milliseconds(500)).isEmpty, "debounced")
        #expect(s.duePaths(at: t0 + .seconds(1)) == ["a.md"])
        s.completed(["a.md"], unstable: [], changed: true, at: t0 + .seconds(1))
        #expect(!s.shouldPublish(at: t0 + .seconds(5), hasChanges: true), "still within quiet period")
        #expect(s.shouldPublish(at: t0 + .seconds(11), hasChanges: true))
        s.published()
        #expect(!s.shouldPublish(at: t0 + .seconds(30), hasChanges: false))
    }

    @Test func continuousBurstIsBoundedByMaximumDelay() {
        let t0 = ContinuousClock.now
        var s = PublicationScheduler(configuration: config(), now: t0)
        var t = t0
        var published = false
        // Events every 2 s forever: the quiet period never elapses.
        for i in 0..<60 {
            t = t0 + .seconds(2 * i)
            s.recordEvent(paths: ["n\(i).md"], at: t)
            let due = s.duePaths(at: t + .milliseconds(1500))
            s.completed(due, unstable: [], changed: !due.isEmpty, at: t + .milliseconds(1500))
            if s.shouldPublish(at: t + .milliseconds(1600), hasChanges: true) {
                published = true
                break
            }
        }
        #expect(published)
        #expect(t - t0 <= .seconds(62), "published by the maximum delay despite constant activity")
    }

    @Test func unstableFilesBackOffAndEventuallyGiveUp() {
        let t0 = ContinuousClock.now
        var s = PublicationScheduler(configuration: config(), now: t0)
        s.recordEvent(paths: ["busy.md"], at: t0)
        var t = t0 + .seconds(1)
        s.completed(s.duePaths(at: t), unstable: ["busy.md"], changed: false, at: t)
        #expect(s.duePaths(at: t + .seconds(1)).isEmpty, "waiting for retry")
        #expect(s.duePaths(at: t + .seconds(2)) == ["busy.md"])
        for _ in 0..<PublicationScheduler.maxAttempts {
            t = t + .seconds(120)
            s.completed(["busy.md"], unstable: ["busy.md"], changed: false, at: t)
        }
        #expect(s.pending.isEmpty, "left to reconciliation")
    }

    @Test func droppedEventsTriggerReconciliation() {
        let t0 = ContinuousClock.now
        var s = PublicationScheduler(configuration: config(), now: t0)
        #expect(s.dueReconciliation(at: t0) == nil)
        s.requestRescan(nil, at: t0)
        #expect(s.dueReconciliation(at: t0)?.subpath == nil)
        #expect(s.dueReconciliation(at: t0) != nil)
        s.reconciled(changed: false, unstable: [], full: true, at: t0)
        #expect(s.dueReconciliation(at: t0 + .seconds(1)) == nil)
        #expect(s.dueReconciliation(at: t0 + .seconds(601)) != nil, "periodic correctness path")
        s.requestRescan("Sub", at: t0)
        #expect(s.dueReconciliation(at: t0 + .seconds(1))?.subpath == "Sub")
    }
}
