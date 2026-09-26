//
//  SearchRepository.swift
//  WikiViewerKit
//
//  Full-text search and quick switching.
//
//  The UI talks to the `SearchEngine` protocol only, so the trigram
//  implementation can be replaced (e.g. by a server-side Japanese tokenizer
//  or a CJK bigram index shipped in a new schema version) without touching
//  views.
//

import Foundation
import GRDB
import WikiShared

public protocol SearchEngine: Sendable {
    /// Full-text search. Results are bounded by `limit`.
    func search(_ query: String, limit: Int) async throws -> [SearchHit]
    /// Title / alias / path matching for the quick switcher.
    func quickSwitch(_ query: String, limit: Int) async throws -> [SearchHit]
}

/// Substring search over an FTS5 `trigram` index with `detail='none'`.
///
/// Query handling:
/// - The query is split on whitespace into terms, which are ANDed.
/// - Candidates come from the most selective (longest) term of ≥ 3
///   characters. Stage 1 asks the index only: every trigram of the term must
///   occur in the note (`"abc" AND "bcd" AND …`), newest rows first, at most
///   `candidateLimit` rows — no note text is read. Stage 2 verifies the exact
///   substring with `LIKE` on those candidates only (ASCII case-insensitive)
///   and keeps at most `matchLimit`. So even a rare phrase made of very
///   common trigrams reads a bounded number of note bodies.
/// - Title matches are added from `notes_title`; remaining terms (including
///   those shorter than 3 characters, common in Japanese, e.g. "東京") filter
///   the matches.
/// - Ranking (title hit, occurrence count, recency) and snippets are computed
///   only for the bounded match set.
/// - If every term is shorter than 3 characters a bounded fallback searches
///   titles, aliases and tags (indexed), never note bodies.
///
/// Limitation: for extremely common terms only the newest `candidateLimit`
/// candidates are considered.
public struct TrigramSearchEngine: SearchEngine {
    public let database: ViewerDatabase
    /// Upper bound on index candidates verified per query.
    public static let candidateLimit = 2000
    /// Upper bound on verified matches ranked per query.
    public static let matchLimit = 400

    public init(database: ViewerDatabase) {
        self.database = database
    }

    public static let minimumTrigramLength = 3

    public static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    /// Whether `search` reads note text for this query. It does not when
    /// every term is shorter than a trigram (e.g. the Japanese "東京"): only
    /// titles, aliases and tags are matched then, which the UI should say.
    public static func searchesNoteText(_ query: String) -> Bool {
        terms(query).contains { $0.unicodeScalars.count >= minimumTrigramLength }
    }

    /// FTS5 query requiring every trigram (3 Unicode scalars, as the trigram
    /// tokenizer counts) of `term`. Each trigram is a quoted one-token string.
    static func trigramQuery(_ term: String) -> String? {
        let scalars = Array(term.unicodeScalars)
        guard scalars.count >= 3 else { return nil }
        var seen = Set<String>()
        var parts: [String] = []
        for i in 0...(scalars.count - 3) {
            var trigram = String.UnicodeScalarView()
            trigram.append(contentsOf: scalars[i..<(i + 3)])
            let token = String(trigram)
            guard seen.insert(token.lowercased()).inserted else { continue }
            parts.append("\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
        }
        return parts.joined(separator: " AND ")
    }

    public func search(_ query: String, limit: Int = 50) async throws -> [SearchHit] {
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return [] }
        let limit = clampLimit(limit)
        guard let primary = terms.filter({ $0.unicodeScalars.count >= Self.minimumTrigramLength }).max(by: { $0.unicodeScalars.count < $1.unicodeScalars.count }),
              let match = Self.trigramQuery(primary) else {
            return try await shortQueryFallback(terms, limit: limit)
        }
        var others = terms
        if let i = others.firstIndex(of: primary) { others.remove(at: i) }
        let escapedPrimary = "%" + likeEscaped(primary) + "%"

        var sql = """
            WITH candidates(id) AS (
              SELECT rowid FROM notes_fts WHERE notes_fts MATCH ? ORDER BY rowid DESC LIMIT \(Self.candidateLimit)
            ),
            body_hits(id) AS (
              SELECT n.id FROM candidates c JOIN notes n ON n.id = c.id
              WHERE n.body LIKE ? ESCAPE '\\' LIMIT \(Self.matchLimit)
            ),
            title_hits(id) AS (
              SELECT id FROM notes INDEXED BY notes_title WHERE title LIKE ? ESCAPE '\\' LIMIT 50
            ),
            hits(id) AS (SELECT id FROM body_hits UNION SELECT id FROM title_hits)
            SELECT n.id, n.title, n.path,
              (n.title LIKE ? ESCAPE '\\') AS in_title,
              (length(n.body) - length(replace(lower(n.body), lower(?), ''))) AS occurrences,
              substr(n.body, max(1, instr(lower(n.body), lower(?)) - 60), 220) AS excerpt
            FROM hits JOIN notes n ON n.id = hits.id
            """
        var args: [String] = [match, escapedPrimary, escapedPrimary, escapedPrimary, primary, primary]
        if !others.isEmpty {
            sql += " WHERE " + others.map { _ in "(n.body LIKE ? ESCAPE '\\' OR n.title LIKE ? ESCAPE '\\')" }.joined(separator: " AND ")
            for term in others {
                let pattern = "%" + likeEscaped(term) + "%"
                args.append(pattern)
                args.append(pattern)
            }
        }
        sql += " ORDER BY in_title DESC, occurrences DESC, n.mtime_ns DESC LIMIT \(limit)"
        let highlightTerms = terms
        let finalSQL = sql
        let finalArgs = args
        return try await database.searchReader.read { db in
            try Row.fetchAll(db, sql: finalSQL, arguments: StatementArguments(finalArgs)).map { row in
                let excerpt: String? = row["excerpt"]
                return SearchHit(
                    note: NoteSummary(row: row),
                    snippet: excerpt.map { Self.snippet($0, terms: highlightTerms) },
                    match: (row["in_title"] as Bool? ?? false) ? .title : .content
                )
            }
        }
    }

    /// Trims an excerpt to ~160 characters around the first match and wraps
    /// every term occurrence in highlight markers.
    static func snippet(_ excerpt: String, terms: [String]) -> String {
        var text = excerpt.replacingOccurrences(of: "\n", with: " ")
        let firstMatch = terms.compactMap { text.range(of: $0, options: [.caseInsensitive]) }.min { $0.lowerBound < $1.lowerBound }
        var prefix = ""
        if let match = firstMatch {
            let startOffset = max(0, text.distance(from: text.startIndex, to: match.lowerBound) - 40)
            if startOffset > 0 {
                text = String(text.dropFirst(startOffset))
                prefix = "…"
            }
        }
        var suffix = ""
        if text.count > 160 {
            text = String(text.prefix(160))
            suffix = "…"
        }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            let hit = terms.compactMap { rest.range(of: $0, options: [.caseInsensitive, .anchored]) }.max { $0.upperBound < $1.upperBound }
            if let hit {
                out.append(SearchHit.highlightStart)
                out += text[hit]
                out.append(SearchHit.highlightEnd)
                index = hit.upperBound
            } else {
                out.append(text[index])
                index = text.index(after: index)
            }
        }
        return prefix + out + suffix
    }

    /// For queries shorter than a trigram: titles (prefix, then substring),
    /// aliases and tags. Bounded by `limit`; bodies are not scanned.
    func shortQueryFallback(_ terms: [String], limit: Int) async throws -> [SearchHit] {
        let term = terms.max(by: { $0.count < $1.count }) ?? ""
        return try await matchNames(term, limit: limit, includeTags: true)
    }

    public func quickSwitch(_ query: String, limit: Int = 30) async throws -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return try await matchNames(q, limit: clampLimit(limit), includeTags: false)
    }

    func matchNames(_ q: String, limit: Int, includeTags: Bool) async throws -> [SearchHit] {
        let prefix = likeEscaped(q) + "%"
        let infix = "%" + likeEscaped(q) + "%"
        return try await database.searchReader.read { db in
            var hits: [SearchHit] = []
            var seen = Set<Int64>()
            func add(_ hit: SearchHit) {
                guard hits.count < limit, seen.insert(hit.note.id).inserted else { return }
                hits.append(hit)
            }
            // 1. Title prefix: range scan on notes_title (NOCASE column → LIKE optimization).
            for row in try Row.fetchAll(db, sql: "SELECT id, title, path FROM notes WHERE title LIKE ? ESCAPE '\\' ORDER BY title LIMIT ?", arguments: [prefix, limit]) {
                add(SearchHit(note: NoteSummary(row: row), snippet: nil, match: .title))
            }
            // 2. Alias prefix (aliases_alias).
            if hits.count < limit {
                for row in try Row.fetchAll(db, sql: """
                    SELECT n.id, n.title, n.path, a.alias FROM aliases a JOIN notes n ON n.id = a.note_id
                    WHERE a.alias LIKE ? ESCAPE '\\' ORDER BY a.alias LIMIT ?
                    """, arguments: [prefix, limit]) {
                    add(SearchHit(note: NoteSummary(row: row), snippet: nil, match: .alias(row["alias"])))
                }
            }
            // 3. Title substring: full scan of the small notes_title index
            //    (title + rowid only), stopped by LIMIT.
            if hits.count < limit {
                for row in try Row.fetchAll(db, sql: "SELECT id, title, path FROM notes INDEXED BY notes_title WHERE title LIKE ? ESCAPE '\\' LIMIT ?", arguments: [infix, limit * 2]) {
                    add(SearchHit(note: NoteSummary(row: row), snippet: nil, match: .title))
                }
            }
            // 4. Alias substring.
            if hits.count < limit {
                for row in try Row.fetchAll(db, sql: """
                    SELECT n.id, n.title, n.path, a.alias FROM aliases a JOIN notes n ON n.id = a.note_id
                    WHERE a.alias LIKE ? ESCAPE '\\' LIMIT ?
                    """, arguments: [infix, limit]) {
                    add(SearchHit(note: NoteSummary(row: row), snippet: nil, match: .alias(row["alias"])))
                }
            }
            // 5. Tags (short-query search only).
            if includeTags, hits.count < limit {
                for row in try Row.fetchAll(db, sql: """
                    SELECT n.id, n.title, n.path, t.name FROM tags t
                    JOIN note_tags nt ON nt.tag_id = t.id JOIN notes n ON n.id = nt.note_id
                    WHERE t.name LIKE ? ESCAPE '\\' LIMIT ?
                    """, arguments: [infix, limit]) {
                    add(SearchHit(note: NoteSummary(row: row), snippet: nil, match: .tag(row["name"])))
                }
            }
            return hits
        }
    }
}
