import Foundation
import Testing
@testable import WikiViewerKit

/// Opt-in query benchmark, used to measure inside the iOS Simulator:
///
///   TEST_RUNNER_WIKIVIEWER_BENCH_DB=/path/viewer-000001.sqlite \
///     xcodebuild test -scheme WikiKit-Package -destination 'platform=iOS Simulator,…' \
///     -only-testing:WikiViewerKitTests/BenchmarkTests
///
/// (xcodebuild forwards TEST_RUNNER_-prefixed variables to the test process.)
@Suite struct BenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIKIVIEWER_BENCH_DB"] != nil))
    func queryBenchmark() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["WIKIVIEWER_BENCH_DB"])
        let report = try await QueryBenchmark(url: URL(fileURLWithPath: path), iterations: 30).run()
        print("BENCHMARK-REPORT-BEGIN\n\(report.markdown)\nBENCHMARK-REPORT-END")
    }

    @Test func benchmarkRunsOnDemoDatabase() async throws {
        let manifest = try demoManifest()
        let report = try await QueryBenchmark(url: demoArtifact.appendingPathComponent(manifest.database.path), iterations: 2).run()
        #expect(report.noteCount == 11)
        #expect(report.measurements.count >= 15)
    }
}
