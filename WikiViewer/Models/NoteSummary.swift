//
//  NoteSummary.swift
//  WikiViewer
//

import GRDB

/// The minimal columns needed to show a note in a list.
///
/// Note bodies are intentionally excluded so that lists stay cheap
/// regardless of how large the notes are.
nonisolated struct NoteSummary: Identifiable, Hashable, Sendable, Decodable, FetchableRecord, TableRecord {
    static let databaseTableName = "notes"

    var id: Int64
    var title: String

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let title = Column(CodingKeys.title)
    }
}
