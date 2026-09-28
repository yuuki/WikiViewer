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

/// Substring search over note names (titles, aliases, tags) and an FTS5
/// `trigram` index of note text with `detail='none'`.
///
/// Every term of the query (split on whitespace, NFC) must match, in any
/// order, and every bound below applies only after all terms have filtered —
/// never to candidates that one term alone selected, which would drop notes
/// matching the whole query whenever that one term is common.
///
/// 1. Names: notes whose title, or one of whose aliases, contains every term.
///    Titles and aliases are small and indexed, so they are matched
///    exhaustively (a prefix range scan, then a scan of the `notes_title` and
///    `aliases_alias` indexes; no note text is read) up to `nameMatchLimit`
///    matches, then ranked: exact name, prefix, substring; titles before
///    aliases; shorter names first; then recency. Queries made only of terms
///    shorter than a trigram (common in Japanese, e.g. "東京") also match tags
///    whose name contains every term, and never read note text.
/// 2. Text, when a term has ≥ 3 characters: stage 1 asks the index only —
///    every trigram of every such term must occur in the note, newest rows
///    first, at most `candidateLimit` rows. Stage 2 checks every term
///    (including short ones) with `LIKE` on the title or the body of those
///    candidates (ASCII case-insensitive) and keeps at most `matchLimit`. So a
///    rare phrase made of very common trigrams still reads a bounded number of
///    note bodies. Ranking (primary term in the title, occurrence count,
///    recency) and snippets are computed only for that bounded set.
///
/// Name matches rank above text matches.
///
/// Limitation: when the trigrams of the long terms occur in more than
/// `candidateLimit` notes, only the newest of those are checked for text
/// matches. Name matches are not affected.
public struct TrigramSearchEngine: SearchEngine {
    public let database: ViewerDatabase
    /// Upper bound on index candidates verified per query.
    public static let candidateLimit = 2000
    /// Upper bound on verified text matches ranked per query.
    public static let matchLimit = 400
    /// Upper bound on title and alias matches ranked per query.
    public static let nameMatchLimit = 1000

    public init(database: ViewerDatabase) {
        self.database = database
    }

    public static let minimumTrigramLength = 3

    /// Query terms: whitespace-separated, quotes trimmed, NFC (titles and
    /// paths are stored NFC), without case-insensitive duplicates.
    public static func terms(_ query: String) -> [String] {
        var seen = Set<String>()
        return query.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Whether `search` reads note text for this query. It does not when
    /// every term is shorter than a trigram (e.g. the Japanese "東京"): only
    /// titles, aliases and tags are matched then, which the UI should say.
    public static func searchesNoteText(_ query: String) -> Bool {
        terms(query).contains { $0.unicodeScalars.count >= minimumTrigramLength }
    }

    /// FTS5 query requiring every trigram (3 Unicode scalars, as the trigram
    /// tokenizer counts) of every term. Each trigram is a quoted one-token
    /// string. nil if no term is long enough.
    static func trigramQuery(_ terms: [String]) -> String? {
        var seen = Set<String>()
        var parts: [String] = []
        for term in terms {
            let scalars = Array(term.unicodeScalars)
            guard scalars.count >= 3 else { continue }
            for i in 0...(scalars.count - 3) {
                var trigram = String.UnicodeScalarView()
                trigram.append(contentsOf: scalars[i..<(i + 3)])
                let token = String(trigram)
                guard seen.insert(token.lowercased()).inserted else { continue }
                parts.append("\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    public func search(_ query: String, limit: Int = 50) async throws -> [SearchHit] {
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return [] }
        let limit = clampLimit(limit)
        let searchesText = terms.contains { $0.unicodeScalars.count >= Self.minimumTrigramLength }
        return try await database.searchReader.read { db in
            var hits = try Self.nameHits(db, terms: terms, limit: limit, includeTags: !searchesText)
            if searchesText {
                try Self.addSnippets(db, to: &hits, terms: terms)
                if hits.count < limit {
                    let named = Set(hits.map(\.id))
                    let text = try Self.textHits(db, terms: terms, limit: limit - hits.count + named.count)
                    hits += text.lazy.filter { !named.contains($0.id) }.prefix(limit - hits.count)
                }
            }
            return hits
        }
    }

    /// Notes whose text contains every term (see the type comment, step 2).
    static func textHits(_ db: Database, terms: [String], limit: Int) throws -> [SearchHit] {
        guard let match = trigramQuery(terms),
              let primary = terms.max(by: { $0.unicodeScalars.count < $1.unicodeScalars.count }) else { return [] }
        let filter = terms.map { _ in "(n.body LIKE ? ESCAPE '\\' OR n.title LIKE ? ESCAPE '\\')" }.joined(separator: " AND ")
        let sql = """
            WITH candidates(id) AS (
              SELECT rowid FROM notes_fts WHERE notes_fts MATCH ? ORDER BY rowid DESC LIMIT \(candidateLimit)
            ),
            matches(id) AS (
              SELECT n.id FROM candidates c JOIN notes n ON n.id = c.id
              WHERE \(filter) LIMIT \(matchLimit)
            )
            SELECT n.id, n.title, n.path,
              (n.title LIKE ? ESCAPE '\\') AS in_title,
              (length(n.body) - length(replace(lower(n.body), lower(?), ''))) AS occurrences,
              substr(n.body, max(1, instr(lower(n.body), lower(?)) - 60), 220) AS excerpt
            FROM matches JOIN notes n ON n.id = matches.id
            ORDER BY in_title DESC, occurrences DESC, n.mtime_ns DESC LIMIT \(limit)
            """
        var args: [String] = [match]
        for term in terms {
            let pattern = "%" + likeEscaped(term) + "%"
            args += [pattern, pattern]
        }
        args += ["%" + likeEscaped(primary) + "%", primary, primary]
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
            let excerpt: String? = row["excerpt"]
            return SearchHit(note: NoteSummary(row: row), snippet: excerpt.map { snippet($0, terms: terms) }, match: .content)
        }
    }

    /// Fills in snippets of name hits from their bodies, around the longest
    /// term (the start of the note if the body does not contain it).
    static func addSnippets(_ db: Database, to hits: inout [SearchHit], terms: [String]) throws {
        guard !hits.isEmpty, let primary = terms.max(by: { $0.unicodeScalars.count < $1.unicodeScalars.count }) else { return }
        let ids = hits.map(\.id)
        let sql = """
            SELECT id, substr(body, max(1, instr(lower(body), lower(?)) - 60), 220) AS excerpt
            FROM notes WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
            """
        var excerpts: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments([primary] as [any DatabaseValueConvertible] + ids)) {
            excerpts[row["id"]] = row["excerpt"]
        }
        for i in hits.indices {
            hits[i].snippet = excerpts[hits[i].id].flatMap { $0.isEmpty ? nil : snippet($0, terms: terms) }
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

    public func quickSwitch(_ query: String, limit: Int = 30) async throws -> [SearchHit] {
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return [] }
        let limit = clampLimit(limit)
        return try await database.searchReader.read { db in
            try Self.nameHits(db, terms: terms, limit: limit, includeTags: false)
        }
    }

    /// A title or alias that contains every term.
    struct NameMatch {
        var id: Int64
        var name: String
        var isAlias: Bool
    }

    /// Notes whose title or one alias (or, with `includeTags`, one tag)
    /// contains every term, ranked (see the type comment, step 1). Matching
    /// and ranking read only the covering `notes_title` and `aliases_alias`
    /// indexes; notes are looked up for the returned hits only.
    static func nameHits(_ db: Database, terms: [String], limit: Int, includeTags: Bool) throws -> [SearchHit] {
        let patterns: [any DatabaseValueConvertible] = terms.map { "%" + likeEscaped($0) + "%" }
        let prefix = likeEscaped(terms[0]) + "%"
        let titleFilter = patterns.map { _ in "title LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
        let aliasFilter = patterns.map { _ in "alias LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
        var matches: [NameMatch] = []

        func collect(_ sql: String, _ arguments: [any DatabaseValueConvertible], isAlias: Bool) throws {
            guard matches.count < nameMatchLimit else { return }
            for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments + [nameMatchLimit - matches.count])) {
                matches.append(NameMatch(id: row[0], name: row[1], isAlias: isAlias))
            }
        }

        // Prefix range scans first (NOCASE columns → LIKE optimization), so
        // exact and prefix matches are ranked even when a common query has
        // more than `nameMatchLimit` substring matches.
        try collect("SELECT id, title FROM notes WHERE title LIKE ? ESCAPE '\\' AND \(titleFilter) ORDER BY title LIMIT ?",
                    [prefix] + patterns, isAlias: false)
        try collect("SELECT note_id, alias FROM aliases WHERE alias LIKE ? ESCAPE '\\' AND \(aliasFilter) ORDER BY alias LIMIT ?",
                    [prefix] + patterns, isAlias: true)
        // Substring matches rank below every prefix match, so they are needed
        // only when prefix matches do not fill the page. Scans of the small
        // title and alias indexes, stopped by LIMIT.
        if Set(matches.map(\.id)).count < limit {
            try collect("SELECT id, title FROM notes INDEXED BY notes_title WHERE \(titleFilter) LIMIT ?",
                        patterns, isAlias: false)
            try collect("SELECT note_id, alias FROM aliases INDEXED BY aliases_alias WHERE \(aliasFilter) LIMIT ?",
                        patterns, isAlias: true)
        }

        var best: [NameMatch] = []
        var seen = Set<Int64>()
        for match in rankNames(matches, terms: terms) where best.count < limit && seen.insert(match.id).inserted {
            best.append(match)
        }
        var notes: [Int64: NoteSummary] = [:]
        if !best.isEmpty {
            let ids = best.map(\.id)
            for row in try Row.fetchAll(db, sql: "SELECT id, title, path FROM notes WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                                        arguments: StatementArguments(ids)) {
                notes[row["id"]] = NoteSummary(row: row)
            }
        }
        var hits = best.compactMap { match in
            notes[match.id].map { SearchHit(note: $0, snippet: nil, match: match.isAlias ? .alias(match.name) : .title) }
        }
        // Tags (queries without a trigram only), after every name match.
        if includeTags, hits.count < limit {
            let tagFilter = patterns.map { _ in "t.name LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
            for row in try Row.fetchAll(db, sql: """
                SELECT n.id, n.title, n.path, t.name FROM tags t
                JOIN note_tags nt ON nt.tag_id = t.id JOIN notes n ON n.id = nt.note_id
                WHERE \(tagFilter) LIMIT ?
                """, arguments: StatementArguments(patterns + [limit])) where hits.count < limit {
                let hit = SearchHit(note: NoteSummary(row: row), snippet: nil, match: .tag(row["name"]))
                if seen.insert(hit.id).inserted { hits.append(hit) }
            }
        }
        return hits
    }

    /// Exact name, then prefix of the first term, then substring; titles
    /// before aliases; shorter names; newest rows first.
    static func rankNames(_ matches: [NameMatch], terms: [String]) -> [NameMatch] {
        let whole = terms.joined(separator: " ").lowercased()
        let first = terms[0].lowercased()
        func key(_ m: NameMatch) -> (Int, Int, Int, Int64) {
            let name = m.name.lowercased()
            let quality = name == whole ? 0 : name.hasPrefix(first) ? 1 : 2
            return (quality, m.isAlias ? 1 : 0, m.name.count, -m.id)
        }
        return matches.map { (key($0), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
