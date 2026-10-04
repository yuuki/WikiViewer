import Foundation
import Testing
@testable import IndexerCore
import WikiShared

/// Reading history from devices (#42).
@Suite(.serialized) struct SignalStoreTests {
    struct Summary: Decodable {
        struct Note: Decodable {
            var path: String
            var reads: Int
            var seconds: Int
            var furthestBlock: Int?
            var pinned: Bool
            var lastRead: String?
        }
        var notes: [Note]
    }

    func signals(_ device: String, _ events: [(String, Int, Date)], pins: [String]? = nil) -> HostRequest {
        HostRequest(kind: .signals, device: device, signals: events.map {
            ReadingSignal(path: $0.0, title: VaultPath.basename(of: $0.0), openedAt: $0.2, seconds: $0.1, block: $0.1 / 10)
        }, pins: pins)
    }

    @Test func eventsAreStoredSummarizedAndExpired() throws {
        let tmp = TempDir()
        let store = try SignalStore(directory: tmp.sub("signals"), retention: 60 * 24 * 3600)
        let now = ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z")!
        let old = now.addingTimeInterval(-90 * 24 * 3600)
        #expect(try store.append(signals("iPhone 17", [("wiki/sources/A.md", 120, now), ("notes/B.md", 30, old)], pins: ["notes/C.md"]), now: now.addingTimeInterval(-91 * 24 * 3600)) == 2)
        #expect(try store.append(signals("Mac/mini", [("wiki/sources/A.md", 60, now)], pins: []), now: now) == 1)

        let files = try FileManager.default.contentsOfDirectory(atPath: tmp.sub("signals").path).sorted()
        #expect(files == ["pins-Mac-mini.json", "pins-iPhone-17.json", "reading-2026-10.jsonl", "summary.json"], "the July month expired; device names are made safe")
        let summary = try JSONDecoder().decode(Summary.self, from: Data(contentsOf: tmp.sub("signals/summary.json")))
        let a = try #require(summary.notes.first { $0.path == "wiki/sources/A.md" })
        #expect(a.reads == 2 && a.seconds == 180 && a.furthestBlock == 12)
        #expect(summary.notes.first { $0.path == "notes/C.md" }?.pinned == true)
        #expect(summary.notes.first { $0.path == "notes/C.md" }?.lastRead == nil)
        #expect(!summary.notes.contains { $0.path == "notes/B.md" })
        let mode = try FileManager.default.attributesOfItem(atPath: tmp.sub("signals").path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700, "private to the user")
    }

    @Test func workerStoresSignalsWithoutRunningClaude() async throws {
        let env = try Env(copyFixture: true)
        var config = RequestWorkerConfiguration(inbox: env.tmp.sub("publish/inbox"), publishDirectory: env.tmp.sub("publish"), vault: env.vault)
        config.signals = try SignalStore(directory: env.tmp.sub("signals"))
        let worker = try RequestWorker(configuration: config)
        let request = signals("iPad", [("Home.md", 40, Date())])
        try request.encoded().write(to: env.tmp.sub("publish/inbox/\(request.fileName)"))
        #expect(await worker.processPending() == 1)
        #expect(worker.readStatus(request.id)?.state == .done)
        #expect(FileManager.default.fileExists(atPath: env.tmp.sub("signals/summary.json").path))

        var refusing = config
        refusing.signals = nil
        let other = try RequestWorker(configuration: refusing)
        let second = signals("iPad", [("Home.md", 40, Date())])
        try second.encoded().write(to: env.tmp.sub("publish/inbox/\(second.fileName)"))
        await other.processPending()
        #expect(other.readStatus(second.id)?.state == .failed)
    }

    @Test func signalsMustStayOutOfTheVault() throws {
        let env = try Env(copyFixture: true)
        var config = RequestWorkerConfiguration(inbox: env.tmp.sub("inbox"), publishDirectory: env.tmp.sub("publish"), vault: env.vault)
        config.signals = try SignalStore(directory: env.vault.appendingPathComponent("signals"))
        #expect(throws: IndexerError.self) { try RequestWorker(configuration: config) }
        try? FileManager.default.removeItem(at: env.vault.appendingPathComponent("signals"))
    }
}
