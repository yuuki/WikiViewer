import Foundation
import GRDB
import Testing
import WikiShared
@testable import WikiViewerKit

struct RecallTests {
    let now = ISO8601DateFormatter().date(from: "2026-10-04T08:00:00Z")!

    @Test func intervalsGrowWithGoodAnswersAndShrinkWithLapses() {
        var card = RecallCard.first(.good, at: now)
        #expect(card.stability == 3)
        #expect(card.due == now.addingTimeInterval(3 * 86_400))
        var t = card.due
        var intervals: [Double] = []
        for _ in 0..<4 {
            card = card.reviewed(.good, at: t)
            intervals.append(card.stability)
            t = card.due
        }
        #expect(intervals == intervals.sorted(), "each good answer lengthens the interval")
        #expect(intervals.last! > 30)
        let lapsed = card.reviewed(.again, at: t)
        #expect(lapsed.lapses == 1)
        #expect(lapsed.stability < card.stability * 0.5)
        #expect(lapsed.due == t.addingTimeInterval(RecallCard.againDelay))
        #expect(card.reviewed(.easy, at: t).stability > card.reviewed(.hard, at: t).stability)
        #expect(RecallCard.first(.again, at: now).due == now.addingTimeInterval(RecallCard.againDelay))
    }

    func item(_ id: String) -> RecallItem {
        RecallItem(id: id, note: NoteSummary(id: 1, title: "N", path: "N.md"), heading: nil, question: "q\(id)", answer: "a", created: "2026-10-01")
    }

    @Test func todaysQueueHasDueReviewsThenNewWithinLimits() {
        let items = (1...6).map { item(String($0)) }
        var cards: [String: RecallCard] = [:]
        cards["1"] = RecallCard.first(.good, at: now.addingTimeInterval(-5 * 86_400))  // due 2 days ago
        cards["2"] = RecallCard.first(.easy, at: now)                                  // not due
        cards["3"] = RecallCard.first(.good, at: now.addingTimeInterval(-4 * 86_400))  // due 1 day ago
        var discarded = RecallCard.first(.good, at: now.addingTimeInterval(-9 * 86_400))
        discarded.suspended = true
        cards["4"] = discarded
        let queue = RecallQueue.today(items: items, cards: cards, now: now, newLimit: 1, reviewLimit: 10, newDoneToday: 0, reviewsDoneToday: 0)
        #expect(queue.map(\.id) == ["1", "3", "5"])
        #expect(RecallQueue.today(items: items, cards: cards, now: now, newLimit: 1, reviewLimit: 1, newDoneToday: 1, reviewsDoneToday: 0).map(\.id) == ["1"])
    }

    @Test func itemsAreReadNewestFirst() async throws {
        let tmp = TempDir()
        let manifest = try makeArtifact(at: tmp.url, generation: 3) { db in
            let alpha = try Int64.fetchOne(db, sql: "SELECT id FROM notes WHERE path = 'Projects/Alpha.md'")!
            try db.execute(sql: """
                INSERT INTO recall_items VALUES ('a', ?, 'Summary', 'Q1', 'A1', '2026-10-01'), ('b', ?, NULL, 'Q2', 'A2', '2026-10-03')
                """, arguments: [alpha, alpha])
        }
        let database = try ViewerDatabase(url: tmp.url.appendingPathComponent(manifest.database.path), options: .init(immutable: true))
        let items = try await RecallRepository(database: database).items()
        #expect(items.map(\.id) == ["b", "a"])
        #expect(items[1].heading == "Summary")
        #expect(items[0].note.path == "Projects/Alpha.md")
    }
}
