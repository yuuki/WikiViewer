//
//  ChangeLog.swift
//  IndexerCore
//
//  What each generation changed (#36), so the app can show "what Claude did
//  since you last looked" by reading a few indexed rows:
//
//  - while indexing, every note written or deleted is noted in the
//    builder-only `pending_changes` (merged: added then changed is still
//    added, added then removed is nothing);
//  - before a publication, the pending changes become `change_log` rows of
//    that generation, with the note's title, type and author (Provenance);
//    the generation's time and counts go to `generation_log`;
//  - new entries of the vault's operation log (`wiki/log.md`, newest first,
//    `## [date] operation | title` and a few `- key: value` lines) become
//    `log_entries` rows of the generation they first appear in.
//
//  The first publication of a builder (a new state directory, or one
//  rebuilt for a new schema) only sets the baseline: indexing the whole
//  vault is not news.
//

import Foundation
import GRDB
import WikiShared

public struct ChangeLogConfiguration: Sendable {
    /// Vault path of the operation log.
    public var logNote = "wiki/log.md"
    /// Rows older than this are dropped.
    public var retention: TimeInterval = 30 * 24 * 3600
    /// A generation records at most this many notes (a sync of thousands
    /// is reported by its counts alone).
    public var maximumRowsPerGeneration = 2_000
    /// Log entries kept.
    public var maximumLogEntries = 1_000

    public init() {}
}

enum ChangeLog {
    static let baselineKey = "change_log_baseline"

    /// Notes a change to `path` in the builder's pending changes.
    static func notePending(_ db: Database, path: String, kind: ViewerSchema.ChangeKind) throws {
        let previous = try Int.fetchOne(db, sql: "SELECT kind FROM pending_changes WHERE path = ?", arguments: [path])
            .flatMap(ViewerSchema.ChangeKind.init(rawValue:))
        let merged: ViewerSchema.ChangeKind?
        switch (previous, kind) {
        case (nil, _): merged = kind
        case (.added, .removed): merged = nil
        case (.added, _): merged = .added
        case (.removed, .added), (.removed, .modified): merged = .modified
        case (.modified, _), (.removed, .removed): merged = kind == .added ? .modified : kind
        }
        if let merged {
            try db.execute(sql: "INSERT OR REPLACE INTO pending_changes(path, kind) VALUES (?, ?)", arguments: [path, merged.rawValue])
        } else {
            try db.execute(sql: "DELETE FROM pending_changes WHERE path = ?", arguments: [path])
        }
    }

    struct Summary: CustomStringConvertible {
        var added = 0, modified = 0, removed = 0, logEntries = 0
        var baseline = false
        var description: String {
            baseline ? "changes: baseline set" : "changes: +\(added) ~\(modified) -\(removed), \(logEntries) log entries"
        }
    }

    /// Turns pending changes into rows of `generation` (called inside the
    /// write transaction before the snapshot is taken).
    @discardableResult
    static func record(_ db: Database, generation: Int64, now: Date = Date(), configuration: ChangeLogConfiguration) throws -> Summary {
        var summary = Summary()
        let baselineSet = try String.fetchOne(db, sql: "SELECT value FROM builder_state WHERE key = ?", arguments: [baselineKey]) != nil
        let pending = try Row.fetchAll(db, sql: "SELECT path, kind FROM pending_changes ORDER BY path").map {
            (path: $0["path"] as String, kind: ViewerSchema.ChangeKind(rawValue: $0["kind"]) ?? .modified)
        }
        try db.execute(sql: "DELETE FROM pending_changes")
        if !baselineSet {
            summary.baseline = true
            try recordLogEntries(db, generation: 0, configuration: configuration)
            try db.execute(sql: "INSERT OR REPLACE INTO builder_state(key, value) VALUES (?, ?)", arguments: [baselineKey, String(generation)])
            return summary
        }
        var rows = 0
        for change in pending {
            switch change.kind {
            case .added: summary.added += 1
            case .modified: summary.modified += 1
            case .removed: summary.removed += 1
            }
            guard rows < configuration.maximumRowsPerGeneration else { continue }
            var title = VaultPath.basename(of: change.path)
            var type: String?
            var fields: [String: String] = [:]
            if change.kind != .removed,
               let note = try Row.fetchOne(db, sql: "SELECT title, frontmatter FROM notes WHERE path = ?", arguments: [change.path]) {
                title = note["title"]
                fields = scalarFields(frontmatterJSON: note["frontmatter"])
                type = fields["type"]
            } else if change.kind != .removed {
                continue // written then excluded: not a note any more
            }
            let author = Provenance.author(path: change.path, fields: fields)
            try db.execute(sql: """
                INSERT OR REPLACE INTO change_log(generation, path, kind, title, type, author) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [generation, change.path, change.kind.rawValue, title, type, author.rawValue])
            rows += 1
        }
        summary.logEntries = try recordLogEntries(db, generation: generation, configuration: configuration)
        if summary.added + summary.modified + summary.removed + summary.logEntries > 0 {
            try db.execute(sql: "INSERT OR REPLACE INTO generation_log(generation, created_at, added, modified, removed) VALUES (?, ?, ?, ?, ?)",
                           arguments: [generation, ISO8601DateFormatter().string(from: now), summary.added, summary.modified, summary.removed])
        }
        try prune(db, now: now, configuration: configuration)
        return summary
    }

    /// Drops what is older than the retention period.
    static func prune(_ db: Database, now: Date, configuration: ChangeLogConfiguration) throws {
        let cutoff = ISO8601DateFormatter().string(from: now.addingTimeInterval(-configuration.retention))
        if let oldest = try Int64.fetchOne(db, sql: "SELECT max(generation) FROM generation_log WHERE created_at < ?", arguments: [cutoff]) {
            try db.execute(sql: "DELETE FROM generation_log WHERE generation <= ?", arguments: [oldest])
            try db.execute(sql: "DELETE FROM change_log WHERE generation <= ?", arguments: [oldest])
        }
        try db.execute(sql: """
            DELETE FROM log_entries WHERE id NOT IN (SELECT id FROM log_entries ORDER BY id DESC LIMIT ?)
            """, arguments: [configuration.maximumLogEntries])
    }

    // MARK: The operation log

    struct LogEntry: Equatable {
        var date: String
        var operation: String
        var title: String
        /// The entry's lines below its heading.
        var body: String
        /// Lines of the entry in the note's body (heading included).
        var lines: Range<Int>
        var key: String { Digest.sha256Hex(Data("\(date)|\(operation)|\(title)|\(body)".utf8)) }
    }

    /// Entries of a log note: `## [YYYY-MM-DD] operation | title` headings
    /// and the lines up to the next level-2 heading.
    static func parseLog(_ body: String) -> [LogEntry] {
        let lines = body.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        var entries: [LogEntry] = []
        var current: (date: String, operation: String, title: String, start: Int)?
        func close(at end: Int) {
            guard let c = current else { return }
            let text = lines[(c.start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(LogEntry(date: c.date, operation: c.operation, title: c.title, body: text, lines: c.start..<end))
            current = nil
        }
        for (index, line) in lines.enumerated() where line.hasPrefix("## ") || line.hasPrefix("# ") {
            close(at: index)
            guard line.hasPrefix("## ["), let close = line.firstIndex(of: "]") else { continue }
            let date = String(line[line.index(line.startIndex, offsetBy: 4)..<close])
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            current = (date, parts.first ?? "", parts.count > 1 ? parts[1] : "", index)
        }
        close(at: lines.count)
        return entries
    }

    /// Adds the log note's entries not seen before, as of `generation`.
    @discardableResult
    static func recordLogEntries(_ db: Database, generation: Int64, configuration: ChangeLogConfiguration) throws -> Int {
        guard let note = try Row.fetchOne(db, sql: "SELECT id, body FROM notes WHERE path = ?", arguments: [configuration.logNote]) else { return 0 }
        let noteID: Int64 = note["id"]
        let entries = parseLog(note["body"])
        guard !entries.isEmpty else { return 0 }
        // The log's resolved links, by line, to name the pages an entry touched.
        var pagesByLine: [Int: [(String, String)]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT l.line, l.display, n.title, n.path FROM links l JOIN notes n ON n.id = l.target_note_id
            WHERE l.source_note_id = ? AND l.is_embed = 0 ORDER BY l.ordinal
            """, arguments: [noteID]) {
            let path: String = row["path"]
            let label = (row["display"] as String?).flatMap { $0.isEmpty ? nil : $0 } ?? (row["title"] as String)
            pagesByLine[row["line"], default: []].append((label, path))
        }
        var added = 0
        // Oldest first, so ids follow the log's order.
        for entry in entries.reversed() {
            let key = entry.key
            if try Bool.fetchOne(db, sql: "SELECT 1 FROM log_entries WHERE entry_key = ?", arguments: [key]) == true { continue }
            var pages: [[String]] = []
            var seen = Set<String>()
            for line in entry.lines {
                for (label, path) in pagesByLine[line] ?? [] where seen.insert(path).inserted {
                    pages.append([label, path])
                }
            }
            let json = String(decoding: (try? JSONSerialization.data(withJSONObject: pages)) ?? Data("[]".utf8), as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO log_entries(entry_key, generation, date, operation, title, body, pages) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [key, generation, entry.date, entry.operation, entry.title, String(entry.body.prefix(8_000)), json])
            added += 1
        }
        return generation == 0 ? 0 : added
    }

    /// Top-level frontmatter values as text (lists joined by ", ").
    static func scalarFields(frontmatterJSON: String?) -> [String: String] {
        guard let json = frontmatterJSON, let data = json.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [:] }
        var fields: [String: String] = [:]
        for pair in pairs where pair.count == 2 {
            guard let key = pair[0] as? String else { continue }
            switch pair[1] {
            case let s as String: fields[key] = s
            case let n as NSNumber: fields[key] = n.stringValue
            case let list as [Any]: fields[key] = list.compactMap { $0 as? String }.joined(separator: ", ")
            default: break
            }
        }
        return fields
    }
}
