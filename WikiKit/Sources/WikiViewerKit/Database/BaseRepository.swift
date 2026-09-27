//
//  BaseRepository.swift
//  WikiViewerKit
//
//  Obsidian Bases, as evaluated by the indexer. A view is read one page at a
//  time along the `base_rows` primary key (group, sort key, note), so a view
//  of 50k notes costs the same per page as one of 5.
//

import Foundation
import GRDB
import WikiShared

public struct BaseInfo: Sendable, Hashable {
    public var assetID: Int64
    public var path: String
    public var document: BaseDocument

    public var name: String { VaultPath.basename(of: path) }
}

public struct BaseGroup: Sendable, Hashable, Identifiable {
    public var key: Data
    /// The group's value as text; nil for notes without one.
    public var label: String?
    public var rowCount: Int

    public var id: Data { key }

    public init(key: Data, label: String?, rowCount: Int) {
        self.key = key
        self.label = label
        self.rowCount = rowCount
    }
}

public struct BaseRow: Sendable, Hashable, Identifiable {
    public var note: NoteSummary
    public var groupKey: Data
    public var sortKey: Data
    public var cells: [String: BaseCell]

    public var id: Int64 { note.id }
    /// The file name without extension: what Obsidian shows for `file.name`.
    public var name: String { VaultPath.basename(of: note.path) }
}

/// Keyset cursor within one view.
public struct BaseCursor: Sendable, Hashable {
    public var groupKey: Data
    public var sortKey: Data
    public var noteID: Int64

    public init(after row: BaseRow) {
        groupKey = row.groupKey
        sortKey = row.sortKey
        noteID = row.note.id
    }
}

public struct BaseRepository: Sendable {
    public let database: ViewerDatabase
    /// Upper bound on group headers read for one view.
    public static let maxGroups = 5000

    public init(database: ViewerDatabase) {
        self.database = database
    }

    public func base(path: String) async throws -> BaseInfo? {
        try await database.reader.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT a.id, a.path, b.definition FROM assets a JOIN bases b ON b.asset_id = a.id WHERE a.path = ?
                """, arguments: [path]) else { return nil }
            let json: String? = row[2]
            let document = json.flatMap { try? JSONDecoder().decode(BaseDocument.self, from: Data($0.utf8)) }
                ?? BaseDocument(views: [], error: "This base has not been evaluated.")
            return BaseInfo(assetID: row[0], path: row[1], document: document)
        }
    }

    /// Group headers of a grouped view, in display order.
    public func groups(baseID: Int64, view: Int) async throws -> [BaseGroup] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT group_key, label, row_count FROM base_groups WHERE base_id = ? AND view = ?
                ORDER BY group_key LIMIT \(Self.maxGroups)
                """, arguments: [baseID, view]).map {
                BaseGroup(key: $0[0], label: $0[1], rowCount: $0[2])
            }
        }
    }

    /// One page of a view's rows in display order.
    public func rows(baseID: Int64, view: Int, after cursor: BaseCursor? = nil, limit: Int = 100) async throws -> Page<BaseRow> {
        let limit = clampLimit(limit)
        return try await database.reader.read { db in
            var sql = """
                SELECT r.group_key, r.sort_key, r.note_id, n.title, n.path, c.cells
                FROM base_rows r
                JOIN notes n ON n.id = r.note_id
                LEFT JOIN base_cells c ON c.base_id = r.base_id AND c.note_id = r.note_id
                WHERE r.base_id = ? AND r.view = ?
                """
            var arguments: StatementArguments = [baseID, view]
            if let cursor {
                sql += " AND (r.group_key, r.sort_key, r.note_id) > (?, ?, ?)"
                arguments += [cursor.groupKey, cursor.sortKey, cursor.noteID]
            }
            sql += " ORDER BY r.group_key, r.sort_key, r.note_id LIMIT ?"
            arguments += [limit + 1]
            let decoder = JSONDecoder()
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            let items = rows.prefix(limit).map { row -> BaseRow in
                let json: String? = row[5]
                let cells = json.flatMap { try? decoder.decode([String: BaseCell].self, from: Data($0.utf8)) } ?? [:]
                return BaseRow(note: NoteSummary(id: row[2], title: row[3], path: row[4]), groupKey: row[0], sortKey: row[1], cells: cells)
            }
            return Page(items: items, hasMore: rows.count > limit)
        }
    }
}
