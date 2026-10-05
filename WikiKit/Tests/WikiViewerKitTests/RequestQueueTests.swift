import Foundation
import Synchronization
import Testing
import WikiShared
@testable import WikiViewerKit

/// A source that takes requests in memory and can be taken offline.
final class RequestSource: ArtifactSource, Sendable {
    struct State {
        var offline = false
        var received: [UUID: Data] = [:]
        var statuses: [UUID: HostRequestStatus] = [:]
    }

    let state = Mutex(State())
    var displayName: String { "requests" }
    var identifier: String { "requests" }
    var acceptsRequests: Bool { true }

    func fetchManifest() async throws -> Data { throw TransportError.notFound("manifest.json") }
    func download(_ relativePath: String, to destination: URL, maximumBytes: Int64) async throws {
        throw TransportError.notFound(relativePath)
    }

    func submitRequest(_ data: Data, id: UUID) async throws {
        try state.withLock { state in
            if state.offline { throw TransportError.unavailable("offline") }
            state.received[id] = data
        }
    }

    func fetchRequestStatus(id: UUID) async throws -> HostRequestStatus {
        try state.withLock { state in
            if state.offline { throw TransportError.unavailable("offline") }
            guard let status = state.statuses[id] else { throw TransportError.notFound("requests/\(id)") }
            return status
        }
    }
}

@MainActor
struct RequestQueueTests {
    func ask(_ text: String = "Why?") -> HostRequest {
        HostRequest(kind: .ask, notePath: "Notes/A.md", noteTitle: "A", question: .free, text: text)
    }

    @Test func requestsAreValidated() throws {
        #expect(throws: HostRequest.ValidationError.missing("text")) {
            try HostRequest(kind: .ask, notePath: "A.md", question: .free).validate()
        }
        #expect(throws: HostRequest.ValidationError.missing("notePath")) {
            try HostRequest(kind: .ask, question: .verify).validate()
        }
        #expect(throws: HostRequest.ValidationError.unsafePath("../A.md")) {
            try HostRequest(kind: .ask, notePath: "../A.md", question: .verify).validate()
        }
        #expect(throws: HostRequest.ValidationError.tooLarge("text")) {
            try HostRequest(kind: .path, text: String(repeating: "x", count: HostRequest.maximumTextLength + 1)).validate()
        }
        let request = ask()
        #expect(try HostRequest.decode(try request.encoded()) == request)
        #expect(HostRequest.id(fromFileName: request.fileName) == request.id)
        #expect(HostRequest.id(fromFileName: "x.json") == nil)
    }

    @Test func waitsOfflineThenSendsAndFollowsTheStatus() async throws {
        let tmp = TempDir()
        let file = tmp.sub("requests.json")
        let source = RequestSource()
        source.state.withLock { $0.offline = true }
        let queue = RequestQueue(fileURL: file)
        let first = ask("first")
        let second = ask("second")
        try queue.enqueue(first)
        try queue.enqueue(second)
        await queue.sync(source: source)
        #expect(queue.entries.map(\.phase) == [.waiting, .waiting])
        #expect(queue.entry(id: first.id)?.lastError != nil)

        // Kept across launches.
        let reloaded = RequestQueue(fileURL: file)
        #expect(reloaded.entries.map(\.id) == [second.id, first.id])

        source.state.withLock { $0.offline = false }
        await reloaded.sync(source: source)
        #expect(reloaded.entries.map(\.phase) == [.queued, .queued])
        #expect(source.state.withLock { Set($0.received.keys) } == [first.id, second.id])
        #expect(reloaded.pendingCount == 2)

        source.state.withLock {
            $0.statuses[first.id] = HostRequestStatus(id: first.id, kind: .ask, state: .processing)
            $0.statuses[second.id] = HostRequestStatus(id: second.id, kind: .ask, state: .done, answerPath: "wiki/asks/A.md")
        }
        await reloaded.sync(source: source)
        #expect(reloaded.entry(id: first.id)?.phase == .processing)
        #expect(reloaded.entry(id: second.id)?.phase == .done)
        #expect(reloaded.entry(id: second.id)?.status?.answerPath == "wiki/asks/A.md")
        #expect(reloaded.pendingCount == 1)

        reloaded.removeFinished()
        #expect(reloaded.entries.map(\.id) == [first.id])
    }

    @Test func aRequestTheMacNeverPicksUpFailsEventually() async throws {
        let source = RequestSource()
        let queue = RequestQueue(fileURL: nil)
        let request = ask()
        try queue.enqueue(request)
        let sent = Date()
        await queue.sync(source: source, now: sent)
        await queue.sync(source: source, now: sent.addingTimeInterval(3600))
        #expect(queue.entry(id: request.id)?.phase == .queued)
        await queue.sync(source: source, now: sent.addingTimeInterval(RequestQueue.statusTimeout + 1))
        #expect(queue.entry(id: request.id)?.phase == .failed)
    }

    @Test func theDemoTakesNoRequests() async throws {
        let queue = RequestQueue(fileURL: nil)
        try queue.enqueue(ask())
        await queue.sync(source: LocalFolderArtifactSource(root: demoArtifact, acceptsRequests: false))
        #expect(queue.entries.first?.phase == .waiting)
        #expect(queue.entries.first?.lastError == nil)
    }

    @Test func statusFilesAreValidated() throws {
        let id = UUID()
        let bad = HostRequestStatus(id: id, kind: .ask, state: .done, answerPath: "../../etc/passwd")
        #expect(throws: HostRequest.ValidationError.self) { try HostRequestStatus.decode(try HostRequest.encoder.encode(bad)) }
        #expect(throws: (any Error).self) { try HostRequestStatus.decode(Data(count: HostRequestStatus.maximumEncodedSize + 1)) }
    }
}
