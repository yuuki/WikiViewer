//
//  NoteRepository.swift
//  WikiViewer
//

import GRDB

/// Read-only queries over the `notes` table.
///
/// Every query is bounded by a limit so that callers never load the whole
/// vault into memory.
nonisolated struct NoteRepository: Sendable {
    static let maxPageSize = 100

    let database: AppDatabase

    /// Returns up to `limit` notes ordered by title, case-insensitively.
    ///
    /// The ordering matches the `notes_title` index, so SQLite reads the
    /// rows straight from the index without sorting.
    func firstNotes(limit: Int = maxPageSize) async throws -> [NoteSummary] {
        let limit = min(max(limit, 0), Self.maxPageSize)
        return try await database.reader.read { db in
            try NoteSummary
                .select(NoteSummary.Columns.id, NoteSummary.Columns.title)
                .order(NoteSummary.Columns.title.collating(.nocase))
                .limit(limit)
                .fetchAll(db)
        }
    }
}
