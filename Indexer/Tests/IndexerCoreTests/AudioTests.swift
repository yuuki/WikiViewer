import Foundation
import GRDB
import Testing
@testable import IndexerCore
import WikiShared

/// Audio published for playing, and episodes (#43).
@Suite(.serialized) struct AudioTests {
    @Test func audioIsPublishedAsABlobAndEpisodesAreIndexed() async throws {
        var env = try Env(copyFixture: true)
        let audio = Data((0..<40_000).map { UInt8($0 % 251) })
        try FileManager.default.createDirectory(at: env.vault.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try audio.write(to: env.vault.appendingPathComponent("audio/ep.m4a"))
        try audio.write(to: env.vault.appendingPathComponent("audio/big.mp3"))
        try env.write("audio/Episode.md", """
        ---
        type: episode
        audio: "[[ep.m4a]]"
        date: 2026-10-04T08:00
        duration: "20:34"
        ---
        - [00:00] start
        """)
        try env.write("audio/Not an episode.md", "---\ntype: concept\n---\n![[ep.m4a]] about an episode")
        env.config.audioMaximumBytes = 50_000
        let indexer = try Indexer(configuration: env.config)
        let builder = await indexer.builder
        _ = try await indexer.reconcile()
        _ = try #require(try await indexer.publish())

        let sha = Digest.sha256Hex(audio)
        let blob = env.config.assetStoreURL.appendingPathComponent("\(sha.prefix(2))/\(sha).m4a")
        #expect(try Data(contentsOf: blob) == audio)
        let rows = try await builder.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT path, blob_ext FROM assets WHERE kind = ? ORDER BY path", arguments: [ViewerSchema.AssetKind.audio.rawValue])
                .map { [$0["path"] as String, $0["blob_ext"] as String? ?? "-"] }
        }
        #expect(rows == [["audio/big.mp3", "mp3"], ["audio/ep.m4a", "m4a"]])

        let episodes = try await builder.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT n.path, e.audio_asset_id IS NOT NULL AS audio, e.published, e.duration FROM episodes e JOIN notes n ON n.id = e.note_id")
                .map { [$0["path"] as String, String($0["audio"] as Bool), $0["published"] as String, String($0["duration"] as Int)] }
        }
        #expect(episodes == [["audio/Episode.md", "true", "2026-10-04", "1234"]])
    }

    @Test func audioOverTheLimitStaysMetadataOnly() async throws {
        var env = try Env(copyFixture: true)
        try Data(count: 2_000).write(to: env.vault.appendingPathComponent("long.m4a"))
        env.config.audioMaximumBytes = 1_000
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()
        let blob = try await indexer.builder.writer.read { db in
            try String.fetchOne(db, sql: "SELECT blob_sha256 FROM assets WHERE path = 'long.m4a'")
        }
        #expect(blob == nil)
    }
}
