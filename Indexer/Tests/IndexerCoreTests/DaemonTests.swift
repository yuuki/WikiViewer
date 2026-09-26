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

    /// Editing the exclude file while watching re-reconciles and republishes
    /// without a restart; a broken edit keeps the current exclusions.
    @Test(.timeLimit(.minutes(1))) func excludeFileEditsApplyWithoutRestart() async throws {
        var env = try Env(copyFixture: true)
        let excludeFile = env.tmp.sub("exclude.txt")
        try Data("# initial\nProjects\n".utf8).write(to: excludeFile)
        env.config.excludeFile = excludeFile
        env.config.excludeFileCheckInterval = .milliseconds(100)
        env.config.debounce = .milliseconds(200)
        env.config.quietPeriod = .milliseconds(500)
        env.config.maximumPublicationDelay = .seconds(10)
        let daemon = try IndexerDaemon(configuration: env.config)
        let noteCounts = Mutex<[Int]>([])
        let task = Task {
            try await daemon.run(tick: .milliseconds(100)) { result in
                noteCounts.withLock { $0.append(result.manifest.noteCount) }
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

        // 11 fixture notes, 2 of them in Projects/.
        try await waitFor { noteCounts.withLock { $0 } == [9] }
        // Saved by rename, as most editors do.
        try Data("/Archive\n".utf8).write(to: excludeFile, options: .atomic)
        try await waitFor { noteCounts.withLock { $0.count } == 2 }
        #expect(noteCounts.withLock { $0 } == [9, 10], "Projects/ is back, Archive/ is gone")
        #expect(await daemon.indexer.filter.patterns == ["/Archive"])

        // An invalid pattern keeps the current filter and publishes nothing.
        try Data("../outside\n".utf8).write(to: excludeFile)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(noteCounts.withLock { $0 } == [9, 10])
        #expect(await daemon.indexer.filter.patterns == ["/Archive"])

        // Emptying the file removes every user exclusion.
        try Data().write(to: excludeFile)
        try await waitFor { noteCounts.withLock { $0.count } == 3 }
        #expect(noteCounts.withLock { $0 } == [9, 10, 11])
    }

    /// Editing the include file while watching changes the published
    /// folders; emptying it keeps them instead of publishing the whole vault.
    @Test(.timeLimit(.minutes(1))) func includeFileEditsApplyWithoutRestart() async throws {
        var env = try Env(copyFixture: true)
        let includeFile = env.tmp.sub("include.txt")
        try Data("Projects\n".utf8).write(to: includeFile)
        env.config.includeFile = includeFile
        env.config.excludePatterns = ["Private"]
        env.config.excludeFileCheckInterval = .milliseconds(100)
        env.config.debounce = .milliseconds(200)
        env.config.quietPeriod = .milliseconds(500)
        env.config.maximumPublicationDelay = .seconds(10)
        let daemon = try IndexerDaemon(configuration: env.config)
        let noteCounts = Mutex<[Int]>([])
        let task = Task {
            try await daemon.run(tick: .milliseconds(100)) { result in
                noteCounts.withLock { $0.append(result.manifest.noteCount) }
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

        // Projects/ holds Alpha and Beta, Daily/ one note.
        try await waitFor { noteCounts.withLock { $0 } == [2] }
        try Data("Projects\nDaily\n".utf8).write(to: includeFile, options: .atomic)
        try await waitFor { noteCounts.withLock { $0.count } == 2 }
        #expect(noteCounts.withLock { $0 } == [2, 3])
        #expect(await daemon.indexer.filter.includePatterns == ["/Projects", "/Daily"])
        #expect(await daemon.indexer.filter.patterns == ["Private"], "--exclude still applies")

        // An include file that lists no folder keeps the current filter.
        try Data("# emptied\n".utf8).write(to: includeFile)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(noteCounts.withLock { $0 } == [2, 3])
        #expect(await daemon.indexer.filter.includePatterns == ["/Projects", "/Daily"])
    }

    @Test func excludeFileMonitorReportsEachChangeOnce() throws {
        let tmp = TempDir()
        let url = tmp.sub("exclude.txt")
        try Data("A\n".utf8).write(to: url)
        var monitor = PatternFileMonitor(url: url, interval: .seconds(1))
        var now = ContinuousClock.now
        #expect(monitor.poll(at: now) == .changed(["A"]), "the first poll always reads the file")
        now += .seconds(2)
        #expect(monitor.poll(at: now) == .unchanged)
        try Data("A\nB\n".utf8).write(to: url)
        #expect(monitor.poll(at: now + .milliseconds(10)) == .unchanged, "throttled")
        now += .seconds(2)
        #expect(monitor.poll(at: now) == .changed(["A", "B"]))
        try FileManager.default.removeItem(at: url)
        now += .seconds(2)
        guard case .failed = monitor.poll(at: now) else { Issue.record("missing file must fail"); return }
        now += .seconds(2)
        #expect(monitor.poll(at: now) == .unchanged, "a missing file is reported once")
        try Data("C\n".utf8).write(to: url)
        now += .seconds(2)
        #expect(monitor.poll(at: now) == .changed(["C"]))
    }
}
