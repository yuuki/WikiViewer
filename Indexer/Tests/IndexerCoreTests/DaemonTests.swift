import Foundation
import GRDB
import Synchronization
import Testing
@testable import IndexerCore
import WikiShared

@Suite(.serialized) struct DaemonTests {
    /// End-to-end: FSEvents → debounce → process → quiet period → publish.
    @Test(.timeLimit(.minutes(1))) func watcherPublishesAfterQuietPeriod() async throws {
        var env = try Env(copyFixture: true)
        env.config.debounce = .milliseconds(200)
        env.config.quietPeriod = .milliseconds(800)
        env.config.maximumPublicationDelay = .seconds(10)
        let daemon = try IndexerDaemon(configuration: env.config)
        let published = Mutex<[Int64]>([])
        let task = Task {
            try await daemon.run(tick: .milliseconds(100)) { result in
                published.withLock { $0.append(result.manifest.generation) }
            }
        }
        defer { task.cancel() }

        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            Issue.record("timed out")
        }

        try await waitFor { published.withLock { $0 } == [1] }
        // Give FSEvents time to arm before generating events.
        try await Task.sleep(for: .milliseconds(500))
        // A burst of edits should produce one publication, not five.
        for i in 0..<5 {
            try env.write("Burst/\(i).md", "# Burst \(i)\n[[Home]]")
            try await Task.sleep(for: .milliseconds(50))
        }
        try await waitFor { published.withLock { $0.count } >= 2 }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(published.withLock { $0 } == [1, 2])
        let report = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
        #expect(report.manifest.noteCount == 16)
    }
}
