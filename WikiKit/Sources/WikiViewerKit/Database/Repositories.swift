//
//  Repositories.swift
//  WikiViewerKit
//
//  Read-only, bounded queries. Rules:
//  - every list query has a LIMIT (clamped by `maxPage`);
//  - every query is served by an index (see ViewerSchema); none scans notes;
//  - note bodies are only fetched one note at a time.
//

import Foundation
import GRDB
import WikiShared

public let maxPage = 500

func clampLimit(_ limit: Int) -> Int { min(max(limit, 1), maxPage) }

func likeEscaped(_ s: String) -> String {
    var out = ""
    for c in s {
        if c == "%" || c == "_" || c == "\\" { out.append("\\") }
        out.append(c)
    }
    return out
}

extension NoteSummary: FetchableRecord {
    public init(row: Row) {
        self.init(id: row["id"], title: row["title"], path: row["path"])
    }
}

// MARK: - Notes

public struct NoteRepository: Sendable {
    public let database: ViewerDatabase

    public init(database: ViewerDatabase) {
        self.database = database
    }

    public func note(id: Int64) async throws -> NoteDetail? {
        try await database.reader.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT id, path, title, basename, folder_id, mtime_ns, size, frontmatter, body FROM notes WHERE id = ?", arguments: [id]) else { return nil }
            return NoteDetail(
                id: row["id"],
                path: row["path"],
                title: row["title"],
                basename: row["basename"],
                folderID: row["folder_id"],
                modified: Date(timeIntervalSince1970: Double(row["mtime_ns"] as Int64) / 1e9),
                size: row["size"],
                properties: PropertyDecoder.decode(row["frontmatter"]),
                body: row["body"]
            )
        }
    }

    public func summary(id: Int64) async throws -> NoteSummary? {
        try await database.reader.read { db in
            try NoteSummary.fetchOne(db, sql: "SELECT id, title, path FROM notes WHERE id = ?", arguments: [id])
        }
    }

    /// Exact path lookup (UNIQUE index).
    public func noteID(path: String) async throws -> Int64? {
        try await database.reader.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM notes WHERE path = ?", arguments: [path])
        }
    }

    /// Notes with a given basename, case/normalization-insensitive (indexed).
    public func notes(basename: String, limit: Int = 20) async throws -> [NoteSummary] {
        let key = VaultPath.matchKey(basename)
        return try await database.reader.read { db in
            try NoteSummary.fetchAll(db, sql: "SELECT id, title, path FROM notes WHERE basename_key = ? ORDER BY path LIMIT ?", arguments: [key, clampLimit(limit)])
        }
    }

    /// The first `maxCharacters` characters of a note's body (for embeds and
    /// previews); never splits a UTF-8 sequence.
    public func bodyPrefix(id: Int64, maxCharacters: Int) async throws -> String? {
        try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT substr(body, 1, ?) FROM notes WHERE id = ?", arguments: [maxCharacters, id])
        }
    }
}

// MARK: - Folders

public struct FolderRepository: Sendable {
    public let database: ViewerDatabase

    public init(database: ViewerDatabase) {
        self.database = database
    }

    public func folder(id: Int64) async throws -> FolderSummary? {
        try await database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM folders WHERE id = ?", arguments: [id]).map(Self.folder)
        }
    }

    public func folderID(path: String) async throws -> Int64? {
        try await database.reader.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE path = ?", arguments: [path])
        }
    }

    /// Direct subfolders, ordered by name (folders_parent_name index).
    public func subfolders(of folderID: Int64, limit: Int = maxPage) async throws -> Page<FolderSummary> {
        let limit = clampLimit(limit)
        return try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM folders WHERE parent_id = ? ORDER BY name LIMIT ?", arguments: [folderID, limit + 1])
            return Page(items: rows.prefix(limit).map(Self.folder), hasMore: rows.count > limit)
        }
    }

    /// Notes directly in a folder, title order, keyset-paginated
    /// (notes_folder index: folder_id, title).
    public func notes(in folderID: Int64, after cursor: TitleCursor? = nil, limit: Int = 200) async throws -> Page<NoteSummary> {
        let limit = clampLimit(limit)
        return try await database.reader.read { db in
            let rows: [NoteSummary]
            if let cursor {
                rows = try NoteSummary.fetchAll(db, sql: """
                    SELECT id, title, path FROM notes
                    WHERE folder_id = ? AND (title > ? OR (title = ? AND id > ?))
                    ORDER BY title, id LIMIT ?
                    """, arguments: [folderID, cursor.title, cursor.title, cursor.id, limit + 1])
            } else {
                rows = try NoteSummary.fetchAll(db, sql: "SELECT id, title, path FROM notes WHERE folder_id = ? ORDER BY title, id LIMIT ?", arguments: [folderID, limit + 1])
            }
            return Page(items: Array(rows.prefix(limit)), hasMore: rows.count > limit)
        }
    }

    public func assets(in folderID: Int64, limit: Int = 200) async throws -> Page<AssetInfo> {
        let limit = clampLimit(limit)
        return try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM assets WHERE folder_id = ? ORDER BY name LIMIT ?", arguments: [folderID, limit + 1])
            return Page(items: rows.prefix(limit).map(AssetRepository.asset), hasMore: rows.count > limit)
        }
    }

    static func folder(_ row: Row) -> FolderSummary {
        FolderSummary(id: row["id"], parentID: row["parent_id"], name: row["name"], path: row["path"],
                      noteCount: row["note_count"], folderCount: row["folder_count"], assetCount: row["asset_count"])
    }
}

// MARK: - Links

public struct LinkRepository: Sendable {
    public let database: ViewerDatabase
    /// Upper bound on links read for one note (pathological notes).
    public static let maxLinksPerNote = 20_000

    public init(database: ViewerDatabase) {
        self.database = database
    }

    /// Outgoing links of one note in document order (primary key order).
    public func outgoingLinks(of noteID: Int64) async throws -> [OutgoingLink] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ordinal, kind, is_embed, raw, target_path, heading, block_id, display, target_note_id, target_asset_id
                FROM links WHERE source_note_id = ? ORDER BY ordinal LIMIT ?
                """, arguments: [noteID, Self.maxLinksPerNote]).map { row in
                OutgoingLink(
                    ordinal: row["ordinal"],
                    kind: ViewerSchema.LinkKind(rawValue: row["kind"]) ?? .wiki,
                    isEmbed: row["is_embed"],
                    raw: row["raw"],
                    targetPath: row["target_path"],
                    heading: row["heading"],
                    blockID: row["block_id"],
                    display: row["display"],
                    targetNoteID: row["target_note_id"],
                    targetAssetID: row["target_asset_id"]
                )
            }
        }
    }

    /// Notes linking to `noteID` (excluding itself), newest first.
    ///
    /// Keyset-paginated along `links_target_note(target_note_id,
    /// source_note_id)`: each page reads at most `limit` distinct sources
    /// from the index, so a hub note with 50k backlinks costs the same as
    /// one with 5. Titles and per-source link counts are fetched for the
    /// page only.
    public func backlinks(to noteID: Int64, before cursor: Int64? = nil, limit: Int = 100) async throws -> Page<Backlink> {
        let limit = clampLimit(limit)
        return try await database.reader.read { db in
            var sql = "SELECT DISTINCT source_note_id FROM links WHERE target_note_id = ? AND source_note_id != ?"
            var args: [Int64] = [noteID, noteID]
            if let cursor {
                sql += " AND source_note_id < ?"
                args.append(cursor)
            }
            sql += " ORDER BY source_note_id DESC LIMIT \(limit + 1)"
            let ids = try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            let pageIDs = Array(ids.prefix(limit))
            guard !pageIDs.isEmpty else { return Page(items: [], hasMore: false) }
            let placeholders = pageIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.id, n.title, n.path,
                  (SELECT count(*) FROM links l WHERE l.target_note_id = ? AND l.source_note_id = n.id) AS c
                FROM notes n WHERE n.id IN (\(placeholders))
                """, arguments: StatementArguments([noteID] + pageIDs))
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, Backlink(note: NoteSummary(row: $0), linkCount: $0["c"])) })
            return Page(items: pageIDs.compactMap { byID[$0] }, hasMore: ids.count > limit)
        }
    }

    /// Number of distinct notes linking here, counted up to `cap` (index-only).
    public func backlinkCount(to noteID: Int64, cap: Int = 10_000) async throws -> Int {
        try await database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT DISTINCT source_note_id FROM links WHERE target_note_id = ? AND source_note_id != ? LIMIT ?)", arguments: [noteID, noteID, cap]) ?? 0
        }
    }

    /// Notes containing unresolved links to `target` (indexed by target_key).
    public func notesLinkingToMissing(_ targetPath: String, limit: Int = 100) async throws -> [NoteSummary] {
        let key = VaultPath.matchKey(VaultPath.fileName(of: targetPath.hasSuffix(".md") ? String(targetPath.dropLast(3)) : targetPath))
        return try await database.reader.read { db in
            try NoteSummary.fetchAll(db, sql: """
                SELECT DISTINCT n.id, n.title, n.path FROM links l JOIN notes n ON n.id = l.source_note_id
                WHERE l.target_key = ? AND l.target_note_id IS NULL AND l.target_asset_id IS NULL
                LIMIT ?
                """, arguments: [key, clampLimit(limit)])
        }
    }

    public func headings(of noteID: Int64) async throws -> [HeadingInfo] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT ordinal, level, text, heading_key, line FROM headings WHERE note_id = ? ORDER BY ordinal LIMIT 5000", arguments: [noteID]).map {
                HeadingInfo(ordinal: $0["ordinal"], level: $0["level"], text: $0["text"], key: $0["heading_key"], line: $0["line"])
            }
        }
    }

    public func blockLine(noteID: Int64, blockID: String) async throws -> Int? {
        try await database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT line FROM blocks WHERE note_id = ? AND block_id = ?", arguments: [noteID, blockID])
        }
    }
}

// MARK: - Tags

public struct TagRepository: Sendable {
    public let database: ViewerDatabase

    public init(database: ViewerDatabase) {
        self.database = database
    }

    public enum Order: Sendable { case name, count }

    /// Tags filtered by name prefix. The tags table has one row per distinct
    /// tag (bounded by tag cardinality, not note count).
    public func tags(prefix: String = "", order: Order = .name, limit: Int = 200, offset: Int = 0) async throws -> Page<TagSummary> {
        let limit = clampLimit(limit)
        let orderBy = order == .name ? "name" : "note_count DESC, name"
        return try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, note_count FROM tags WHERE name LIKE ? ESCAPE '\\'
                ORDER BY \(orderBy) LIMIT ? OFFSET ?
                """, arguments: [likeEscaped(prefix) + "%", limit + 1, max(0, offset)])
            return Page(items: rows.prefix(limit).map { TagSummary(id: $0["id"], name: $0["name"], noteCount: $0["note_count"]) }, hasMore: rows.count > limit)
        }
    }

    public func tag(named name: String) async throws -> TagSummary? {
        let key = VaultPath.matchKey(name)
        return try await database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT id, name, note_count FROM tags WHERE key = ?", arguments: [key]).map {
                TagSummary(id: $0["id"], name: $0["name"], noteCount: $0["note_count"])
            }
        }
    }

    public func tags(of noteID: Int64) async throws -> [TagSummary] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.id, t.name, t.note_count FROM note_tags nt JOIN tags t ON t.id = nt.tag_id
                WHERE nt.note_id = ? ORDER BY t.name LIMIT 500
                """, arguments: [noteID]).map { TagSummary(id: $0["id"], name: $0["name"], noteCount: $0["note_count"]) }
        }
    }

    /// Upper bound on nested tags merged for one listing.
    static let maxNestedTags = 200

    /// Notes carrying the tag (and, if `includeNested`, its `tag/…`
    /// children), newest first, keyset-paginated.
    ///
    /// Each tag's notes are read in `note_tags_tag(tag_id, note_id)` order and
    /// merged, so a page costs O(tags × limit) index entries regardless of
    /// how many notes carry the tag (no sort over all tagged notes, no OFFSET).
    public func notes(taggedWith tag: TagSummary, includeNested: Bool = true, before cursor: Int64? = nil, limit: Int = 200) async throws -> Page<NoteSummary> {
        let limit = clampLimit(limit)
        return try await database.reader.read { db in
            var tagIDs: [Int64] = [tag.id]
            if includeNested {
                tagIDs += try Int64.fetchAll(db, sql: "SELECT id FROM tags WHERE name LIKE ? ESCAPE '\\' LIMIT \(Self.maxNestedTags)", arguments: [likeEscaped(tag.name) + "/%"])
            }
            var merged = Set<Int64>()
            for tagID in tagIDs {
                let ids: [Int64]
                if let cursor {
                    ids = try Int64.fetchAll(db, sql: "SELECT note_id FROM note_tags WHERE tag_id = ? AND note_id < ? ORDER BY note_id DESC LIMIT ?", arguments: [tagID, cursor, limit + 1])
                } else {
                    ids = try Int64.fetchAll(db, sql: "SELECT note_id FROM note_tags WHERE tag_id = ? ORDER BY note_id DESC LIMIT ?", arguments: [tagID, limit + 1])
                }
                merged.formUnion(ids)
            }
            let ordered = merged.sorted(by: >)
            let pageIDs = Array(ordered.prefix(limit))
            guard !pageIDs.isEmpty else { return Page(items: [], hasMore: false) }
            let placeholders = pageIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try NoteSummary.fetchAll(db, sql: "SELECT id, title, path FROM notes WHERE id IN (\(placeholders))", arguments: StatementArguments(pageIDs))
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            return Page(items: pageIDs.compactMap { byID[$0] }, hasMore: ordered.count > limit)
        }
    }
}

// MARK: - Assets

public struct AssetRepository: Sendable {
    public let database: ViewerDatabase

    public init(database: ViewerDatabase) {
        self.database = database
    }

    public func asset(id: Int64) async throws -> AssetInfo? {
        try await database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM assets WHERE id = ?", arguments: [id]).map(Self.asset)
        }
    }

    static func asset(_ row: Row) -> AssetInfo {
        AssetInfo(
            id: row["id"], path: row["path"], name: row["name"], ext: row["ext"],
            kind: ViewerSchema.AssetKind(rawValue: row["kind"]) ?? .other,
            size: row["size"], blobSHA256: row["blob_sha256"], blobExt: row["blob_ext"],
            blobSize: row["blob_size"], width: row["width"], height: row["height"]
        )
    }
}

// MARK: - Frontmatter decoding

enum PropertyDecoder {
    /// Decodes the `[[key, value], …]` JSON produced by the indexer.
    static func decode(_ json: String?) -> [Property] {
        guard let json, let data = json.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
        return pairs.compactMap { pair in
            guard pair.count == 2, let key = pair[0] as? String else { return nil }
            return Property(key: key, value: value(pair[1], depth: 0))
        }
    }

    static func value(_ any: Any, depth: Int) -> PropertyValue {
        guard depth < 16 else { return .null }
        switch any {
        case let s as String: return .text(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.stringValue)
        case let a as [Any]: return .list(a.map { value($0, depth: depth + 1) })
        case let d as [String: Any]:
            return .object(d.keys.sorted().map { Property(key: $0, value: value(d[$0]!, depth: depth + 1)) })
        default: return .null
        }
    }
}
