import Foundation
import Testing
import WikiShared
@testable import WikiViewerKit

struct UpdatePacingTests {
    func step(after seconds: Int, waitingForMac: Bool = false, _ conditions: UpdateConditions = UpdateConditions()) -> UpdateStep {
        UpdateSchedule.step(sinceActivity: .seconds(seconds), waitingForMac: waitingForMac, conditions: conditions)
    }

    @Test func followsRightAfterActivityAndPollsWhenQuiet() {
        #expect(step(after: 0) == .follow)
        #expect(step(after: 4 * 60) == .follow)
        #expect(step(after: 6 * 60) == .poll(every: UpdateSchedule.quietInterval))
        #expect(step(after: 2 * 3600) == .poll(every: UpdateSchedule.idleInterval))
    }

    @Test func cellularFollowsForAShorterTime() {
        let cellular = UpdateConditions(expensive: true)
        #expect(step(after: 60, cellular) == .follow)
        #expect(step(after: 3 * 60, cellular) == .poll(every: UpdateSchedule.quietInterval))
    }

    @Test func aRequestWaitingForTheMacKeepsFollowing() {
        #expect(step(after: 2 * 3600, waitingForMac: true) == .follow)
        #expect(step(after: 2 * 3600, waitingForMac: true, UpdateConditions(expensive: true)) == .follow)
    }

    @Test func lowPowerAndLowDataModeNeverFollow() {
        for conditions in [UpdateConditions(lowPowerMode: true), UpdateConditions(constrained: true)] {
            #expect(step(after: 0, conditions) == .poll(every: UpdateSchedule.savingInterval))
            #expect(step(after: 0, waitingForMac: true, conditions) == .poll(every: UpdateSchedule.savingRequestInterval))
        }
    }

    @MainActor
    @Test func onlyARecentlySentUnfinishedRequestAwaitsTheMac() async throws {
        let source = RequestSource()
        let queue = RequestQueue(fileURL: nil)
        let request = HostRequest(kind: .ask, notePath: "Notes/A.md", noteTitle: "A", question: .free, text: "Why?")
        try queue.enqueue(request)
        // Not sent yet (offline or refused): nothing to wait for.
        #expect(!queue.isAwaitingHost())

        let sent = Date()
        await queue.sync(source: source, now: sent)
        #expect(queue.isAwaitingHost(now: sent))
        #expect(!queue.isAwaitingHost(now: sent + RequestQueue.awaitingHostWindow + 1))

        source.state.withLock { $0.statuses[request.id] = HostRequestStatus(id: request.id, kind: .ask, state: .done) }
        await queue.sync(source: source, now: sent)
        #expect(!queue.isAwaitingHost(now: sent))
    }
}
