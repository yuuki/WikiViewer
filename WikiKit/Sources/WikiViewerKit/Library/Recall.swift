//
//  Recall.swift
//  WikiViewerKit
//
//  Recall practice (#40). Questions about notes read days ago are made on
//  the host (`recall_items`); when to ask each again is the device's own,
//  so it follows the reader rather than the vault: a small spaced-
//  repetition scheduler in the spirit of FSRS — each card has a stability
//  (days until recall drops to about 90%) and a difficulty, and a grade
//  moves both.
//

import Foundation
import GRDB
import WikiShared

public struct RecallItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var note: NoteSummary
    public var heading: String?
    public var question: String
    public var answer: String
    public var created: String
}

public struct RecallRepository: Sendable {
    let database: ViewerDatabase

    /// Questions read at once: the newest, bounded.
    public static let limit = 500

    public init(database: ViewerDatabase) {
        self.database = database
    }

    /// The newest questions (recall_items_created).
    public func items(limit: Int = RecallRepository.limit) async throws -> [RecallItem] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.id AS item, r.heading, r.question, r.answer, r.created, n.id, n.title, n.path FROM recall_items r
                JOIN notes n ON n.id = r.note_id ORDER BY r.created DESC, r.id DESC LIMIT ?
                """, arguments: [min(max(limit, 1), Self.limit)]).map { row in
                RecallItem(id: row["item"], note: NoteSummary(row: row), heading: row["heading"],
                           question: row["question"], answer: row["answer"], created: row["created"])
            }
        }
    }
}

/// The schedule of one question on this device.
public struct RecallCard: Codable, Sendable, Equatable {
    public enum Grade: Int, Codable, Sendable, CaseIterable {
        case again = 1, hard, good, easy
    }

    /// Days until recall falls to about 90%.
    public var stability: Double
    /// 1 (easy) … 10 (hard).
    public var difficulty: Double
    public var due: Date
    public var reviews: Int
    public var lapses: Int
    public var lastReview: Date
    /// Discarded by the reader: never asked again.
    public var suspended = false

    /// First answers set the stability (days) by grade.
    static let initialStability: [Grade: Double] = [.again: 0.4, .hard: 1.2, .good: 3.0, .easy: 8.0]
    static let againDelay: TimeInterval = 10 * 60

    /// The card after a first answer.
    public static func first(_ grade: Grade, at now: Date) -> RecallCard {
        let stability = initialStability[grade] ?? 3
        var card = RecallCard(stability: stability, difficulty: 5 - Double(grade.rawValue - 3) * 1.5, due: now,
                              reviews: 1, lapses: grade == .again ? 1 : 0, lastReview: now)
        card.difficulty = min(max(card.difficulty, 1), 10)
        card.due = grade == .again ? now.addingTimeInterval(againDelay) : now.addingTimeInterval(stability * 86_400)
        return card
    }

    /// Recall probability now (the forgetting curve of FSRS).
    public func retrievability(at now: Date) -> Double {
        let elapsed = max(0, now.timeIntervalSince(lastReview) / 86_400)
        return pow(1 + elapsed / (9 * stability), -1)
    }

    /// The card after answering with `grade` at `now`.
    public func reviewed(_ grade: Grade, at now: Date) -> RecallCard {
        var next = self
        next.reviews += 1
        next.lastReview = now
        next.difficulty = min(max(difficulty - Double(grade.rawValue - 3) * 0.8, 1), 10)
        if grade == .again {
            next.lapses += 1
            next.stability = max(0.2, stability * 0.3)
            next.due = now.addingTimeInterval(Self.againDelay)
            return next
        }
        // Harder to remember later: a review when recall had dropped grows
        // stability more; difficulty and a "hard" answer grow it less.
        let r = retrievability(at: now)
        let ease = (11 - next.difficulty) / 10
        let bonus: Double = switch grade {
        case .hard: 0.6
        case .good: 2.5
        case .easy: 4.0
        case .again: 0
        }
        next.stability = stability * (1 + bonus * ease * (1.5 - r) * 1.2)
        next.due = now.addingTimeInterval(next.stability * 86_400)
        return next
    }
}

/// Which questions to ask today.
public enum RecallQueue {
    /// Due reviews first (most overdue first), then new questions (newest
    /// note first), within the daily limits; suspended cards never.
    public static func today(items: [RecallItem], cards: [String: RecallCard], now: Date,
                             newLimit: Int, reviewLimit: Int, newDoneToday: Int, reviewsDoneToday: Int) -> [RecallItem] {
        let reviews = items.filter { item in
            guard let card = cards[item.id] else { return false }
            return !card.suspended && card.due <= now
        }
        .sorted { (cards[$0.id]?.due ?? now) < (cards[$1.id]?.due ?? now) }
        let new = items.filter { cards[$0.id] == nil }
        return Array(reviews.prefix(max(0, reviewLimit - reviewsDoneToday))) + Array(new.prefix(max(0, newLimit - newDoneToday)))
    }
}
