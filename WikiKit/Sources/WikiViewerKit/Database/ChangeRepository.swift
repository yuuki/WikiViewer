//
//  ChangeRepository.swift
//  WikiViewerKit
//
//  What changed since a generation (#36): the host has already recorded,
//  per generation, the notes added, changed and removed and the new
//  entries of the vault's operation log. The phone reads the rows after a
//  generation, along the primary keys, and folds them into a digest.
//

import Foundation
import GRDB
import WikiShared

public struct NoteChange: Sendable, Hashable, Identifiable {
    public var generation: Int64
    public var path: String
    public var kind: ViewerSchema.ChangeKind
    public var title: String
    public var type: String?
    public var author: Provenance.Author

    public var id: String { path }
}

public struct LogEntry: Sendable, Hashable, Identifiable {
    public struct Page: Sendable, Hashable {
        public var label: String
        public var path: String
    }

    public var id: Int64
    public var generation: Int64
    public var date: String
    public var operation: String
    public var title: String
    /// The entry's lines below its heading (Markdown).
    public var body: String
    public var pages: [Page]

    /// An ingest of a new source (`ingest`, `ingest-paper`, …).
    public var isIngest: Bool { operation.lowercased().hasPrefix("ingest") }
    /// A thesis judged (`thesis`, `wiki-thesis`, …).
    public var isThesis: Bool { operation.lowercased().contains("thesis") && !isIngest }
}

/// Everything after a generation, folded per note.
public struct ChangeDigest: Sendable, Equatable {
    /// The generation the digest starts after.
    public var since: Int64
    /// One change per note, the latest (a note added and then changed in the
    /// range counts as added), newest first.
    public var changes: [NoteChange]
    /// Newest first.
    public var entries: [LogEntry]
    /// Totals over the range, including notes beyond the row limits.
    public var added = 0
    public var modified = 0
    public var removed = 0
    /// True if more rows exist than were read.
    public var truncated = false

    public var isEmpty: Bool { changes.isEmpty && entries.isEmpty }

    /// Log entries that ingested sources.
    public var ingests: [LogEntry] { entries.filter(\.isIngest) }
    /// Concepts Claude rewrote or created.
    public var concepts: [NoteChange] { changes.filter { $0.type == "concept" && $0.kind != .removed } }
    /// Theses judged (`type: thesis`).
    public var theses: [NoteChange] { changes.filter { $0.type == "thesis" && $0.kind != .removed } }
    /// New source pages (`type: source`).
    public var sources: [NoteChange] { changes.filter { $0.type == "source" && $0.kind == .added } }
    /// Changes by the reader (notes outside the wiki layer).
    public var humanChanges: [NoteChange] { changes.filter { $0.author == .human } }
    /// Claude's other changes.
    public var otherClaudeChanges: [NoteChange] {
        changes.filter { $0.author == .claude && !["concept", "thesis", "source"].contains($0.type ?? "") && !isLog($0) }
    }

    /// The log note itself changes with every entry; it is not news.
    func isLog(_ change: NoteChange) -> Bool { change.path.hasSuffix("/log.md") || change.path == "log.md" }

    /// Why a note changed: the first log entry naming it.
    public func reason(for path: String) -> LogEntry? {
        entries.first { $0.pages.contains { $0.path == path } }
    }
}

public struct ChangeRepository: Sendable {
    let database: ViewerDatabase

    public static let maximumChanges = 500
    public static let maximumEntries = 100

    public init(database: ViewerDatabase) {
        self.database = database
    }

    /// The last generation published before `date`, or 0: a digest "since
    /// date" starts after it.
    public func generation(before date: Date) async throws -> Int64 {
        let stamp = ISO8601DateFormatter().string(from: date)
        return try await database.reader.read { db in
            try Int64.fetchOne(db, sql: "SELECT max(generation) FROM generation_log WHERE created_at < ?", arguments: [stamp]) ?? 0
        }
    }

    /// When a generation was published, if it changed anything.
    public func publishedDate(of generation: Int64) async throws -> Date? {
        try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT created_at FROM generation_log WHERE generation = ?", arguments: [generation])
        }.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    public func digest(after generation: Int64) async throws -> ChangeDigest {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT generation, path, kind, title, type, author FROM change_log
                WHERE generation > ? ORDER BY generation DESC, path LIMIT ?
                """, arguments: [generation, Self.maximumChanges + 1])
            var digest = ChangeDigest(since: generation, changes: [], entries: [])
            digest.truncated = rows.count > Self.maximumChanges
            var byPath: [String: Int] = [:]
            for row in rows.prefix(Self.maximumChanges) {
                let change = NoteChange(generation: row["generation"], path: row["path"],
                                        kind: ViewerSchema.ChangeKind(rawValue: row["kind"]) ?? .modified,
                                        title: row["title"], type: row["type"],
                                        author: Provenance.Author(rawValue: row["author"]) ?? .human)
                if let index = byPath[change.path] {
                    // Rows come newest first: an older "added" makes the
                    // note new to the reader, unless it was removed since.
                    if change.kind == .added, digest.changes[index].kind == .modified { digest.changes[index].kind = .added }
                    continue
                }
                byPath[change.path] = digest.changes.count
                digest.changes.append(change)
            }
            if let totals = try Row.fetchOne(db, sql: """
                SELECT sum(added) AS added, sum(modified) AS modified, sum(removed) AS removed FROM generation_log WHERE generation > ?
                """, arguments: [generation]) {
                digest.added = totals["added"] ?? 0
                digest.modified = totals["modified"] ?? 0
                digest.removed = totals["removed"] ?? 0
            }
            digest.entries = try Row.fetchAll(db, sql: """
                SELECT id, generation, date, operation, title, body, pages FROM log_entries
                WHERE generation > ? ORDER BY generation DESC, id DESC LIMIT ?
                """, arguments: [generation, Self.maximumEntries]).map(Self.entry)
            return digest
        }
    }

    static func entry(_ row: Row) -> LogEntry {
        let pairs = (try? JSONSerialization.jsonObject(with: Data((row["pages"] as String? ?? "[]").utf8))) as? [[String]] ?? []
        return LogEntry(id: row["id"], generation: row["generation"], date: row["date"], operation: row["operation"],
                        title: row["title"], body: row["body"],
                        pages: pairs.compactMap { $0.count == 2 ? LogEntry.Page(label: $0[0], path: $0[1]) : nil })
    }
}
