//
//  RelatedRepository.swift
//  WikiViewerKit
//
//  A note's neighbours by role (#38): what defines it, the evidence it
//  rests on, what contradicts it and its peers in the same topic — the
//  vault's wiki-related, computed on the host. One indexed read of at most
//  a dozen rows per note.
//

import Foundation
import GRDB
import WikiShared

public struct RelatedGroup: Sendable, Hashable, Identifiable {
    public struct Item: Sendable, Hashable, Identifiable {
        public var note: NoteSummary
        public var why: String?
        public var id: Int64 { note.id }
    }

    public var role: String
    public var items: [Item]
    public var id: String { role }

    /// Known roles first, in this order; others after, by name.
    public static let roleOrder = ["definition", "evidence", "contradiction", "cluster"]
}

public struct RelatedRepository: Sendable {
    let database: ViewerDatabase

    public init(database: ViewerDatabase) {
        self.database = database
    }

    public func related(to noteID: Int64) async throws -> [RelatedGroup] {
        try await database.reader.read { db in
            var groups: [String: [RelatedGroup.Item]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT r.role, r.why, n.id, n.title, n.path, n.mtime_ns FROM related r
                JOIN notes n ON n.id = r.target_note_id
                WHERE r.note_id = ? ORDER BY r.role, r.rank LIMIT 50
                """, arguments: [noteID]) {
                groups[row["role"], default: []].append(RelatedGroup.Item(note: NoteSummary(row: row), why: row["why"]))
            }
            return groups.keys.sorted { a, b in
                let order = RelatedGroup.roleOrder
                return (order.firstIndex(of: a) ?? order.count, a) < (order.firstIndex(of: b) ?? order.count, b)
            }.map { RelatedGroup(role: $0, items: groups[$0] ?? []) }
        }
    }
}
