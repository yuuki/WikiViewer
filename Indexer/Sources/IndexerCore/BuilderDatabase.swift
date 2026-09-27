//
//  BuilderDatabase.swift
//  IndexerCore
//
//  builder.sqlite: mutable builder state (WAL). The viewer never reads it;
//  publications are consistent snapshots copied out of it (see Publisher).
//

import Foundation
import GRDB
import WikiShared

/// What changed during a batch, so link resolution can be limited to the
/// affected rows instead of the whole links table.
struct ResolutionWork {
    /// Notes whose outgoing links were (re)written.
    var sources: Set<Int64> = []
    /// Keys (note basename / asset file name) whose candidate set changed.
    var keys: Set<String> = []
    var removedNotes: Set<Int64> = []
    var removedAssets: Set<Int64> = []

    var isEmpty: Bool { sources.isEmpty && keys.isEmpty && removedNotes.isEmpty && removedAssets.isEmpty }

    mutating func merge(_ other: ResolutionWork) {
        sources.formUnion(other.sources)
        keys.formUnion(other.keys)
        removedNotes.formUnion(other.removedNotes)
        removedAssets.formUnion(other.removedAssets)
    }
}

/// Stored per-file state used by reconciliation.
public struct StoredFileState: Sendable, Equatable {
    public var size: Int64
    public var mtimeNs: Int64
    public var isNote: Bool
}

public struct AssetBlobInfo: Sendable, Equatable {
    public var sha256: String
    public var ext: String
    public var size: Int64
    public var width: Int?
    public var height: Int?
}

public final class BuilderDatabase: Sendable {
    public let writer: DatabaseQueue
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.label = "builder"
        config.foreignKeysEnabled = false

        // Builder state is disposable: if it was written by another schema or
        // with another page size, start over; the next reconciliation
        // repopulates it from the vault.
        if fm.fileExists(atPath: url.path) {
            let probe = try DatabaseQueue(path: url.path, configuration: config)
            let (version, pageSize, mismatch) = try probe.read { db in
                (try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0,
                 try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0,
                 try SchemaCheck.mismatch(db))
            }
            try probe.close()
            if version != ViewerSchema.version || pageSize != ViewerSchema.pageSize || (version != 0 && mismatch != nil) {
                Log.warning("builder database has schema \(version) (\(mismatch ?? "same SQL")), page size \(pageSize); rebuilding it from the vault")
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    try? fm.removeItem(atPath: url.path + suffix)
                }
            }
        }

        writer = try DatabaseQueue(path: url.path, configuration: config)
        let isNew = try writer.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 } == 0
        if isNew {
            try writer.writeWithoutTransaction { db in
                // Both must be set before any table exists and before WAL mode.
                try db.execute(sql: "PRAGMA page_size = \(ViewerSchema.pageSize)")
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
                try db.execute(sql: "VACUUM")
            }
        }
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // Zero deleted content so text removed from a note (or a deleted
            // note) does not linger in free space that snapshots copy.
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        if isNew {
            try writer.write { db in
                for statement in ViewerSchema.createStatements {
                    try db.execute(sql: statement)
                }
                try db.execute(sql: "INSERT INTO folders(id, parent_id, path, name) VALUES (?, NULL, '', '')", arguments: [ViewerSchema.rootFolderID])
                try db.execute(sql: "PRAGMA user_version = \(ViewerSchema.version)")
            }
        }
        // Notes parsed by another parser version: forget their size, mtime
        // and hash so the next reconciliation re-reads and re-parses them.
        // Assets and their derivatives are kept.
        try writer.write { db in
            let key = "parser_version"
            let stored = try String.fetchOne(db, sql: "SELECT value FROM builder_state WHERE key = ?", arguments: [key])
            guard stored != String(NoteParser.version) else { return }
            if !isNew {
                Log.info("note parser changed (\(stored ?? "none") → \(NoteParser.version)); re-parsing all notes")
                try db.execute(sql: "UPDATE notes SET size = -1, mtime_ns = -1, content_hash = ''")
            }
            try db.execute(sql: "INSERT OR REPLACE INTO builder_state(key, value) VALUES (?, ?)", arguments: [key, String(NoteParser.version)])
        }
    }

    // MARK: State

    public func state(_ key: String) throws -> String? {
        try writer.read { db in try String.fetchOne(db, sql: "SELECT value FROM builder_state WHERE key = ?", arguments: [key]) }
    }

    public func setState(_ key: String, _ value: String) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO builder_state(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        }
    }

    /// path → stored metadata for every indexed file. O(files) on the host,
    /// used only by reconciliation.
    public func fileStates() throws -> [String: StoredFileState] {
        try writer.read { db in
            var result: [String: StoredFileState] = [:]
            let notes = try Row.fetchCursor(db, sql: "SELECT path, size, mtime_ns FROM notes")
            while let row = try notes.next() {
                result[row[0]] = StoredFileState(size: row[1], mtimeNs: row[2], isNote: true)
            }
            let assets = try Row.fetchCursor(db, sql: "SELECT path, size, mtime_ns FROM assets")
            while let row = try assets.next() {
                result[row[0]] = StoredFileState(size: row[1], mtimeNs: row[2], isNote: false)
            }
            return result
        }
    }

    /// Indexed paths below `folder/`, via a range scan on the UNIQUE path
    /// indexes ("/" is 0x2F, so every "folder/…" sorts in ["folder/", "folder0")).
    public func indexedPaths(under folder: String) throws -> [String] {
        try writer.read { db in
            let low = folder + "/"
            let high = folder + "0"
            return try String.fetchAll(db, sql: "SELECT path FROM notes WHERE path >= ? AND path < ? UNION ALL SELECT path FROM assets WHERE path >= ? AND path < ?", arguments: [low, high, low, high])
        }
    }

    public func storedSHA256(assetPath: String) throws -> String? {
        try writer.read { db in try String.fetchOne(db, sql: "SELECT source_sha256 FROM assets WHERE path = ?", arguments: [assetPath]) }
    }

    public func cachedDerivative(sourceSHA256: String, params: String) throws -> AssetBlobInfo? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT blob_sha256, blob_ext, blob_size, width, height FROM asset_derivatives WHERE source_sha256 = ? AND params = ?", arguments: [sourceSHA256, params]).map {
                AssetBlobInfo(sha256: $0[0], ext: $0[1], size: $0[2], width: $0[3], height: $0[4])
            }
        }
    }

    public func counts() throws -> (notes: Int, assets: Int, links: Int, unresolved: Int) {
        try writer.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT count(*) FROM notes") ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM assets") ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM links") ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM links WHERE target_note_id IS NULL AND target_asset_id IS NULL") ?? 0
            )
        }
    }

    // MARK: Writes (called inside a write transaction)

    struct FolderCache {
        var ids: [String: Int64] = ["": ViewerSchema.rootFolderID]
    }

    func ensureFolder(_ db: Database, path: String, cache: inout FolderCache) throws -> Int64 {
        if let id = cache.ids[path] { return id }
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE path = ?", arguments: [path]) {
            cache.ids[path] = id
            return id
        }
        let parentID = try ensureFolder(db, path: VaultPath.folder(of: path), cache: &cache)
        try db.execute(sql: "INSERT INTO folders(parent_id, path, name) VALUES (?, ?, ?)", arguments: [parentID, path, VaultPath.fileName(of: path)])
        let id = db.lastInsertedRowID
        try db.execute(sql: "UPDATE folders SET folder_count = folder_count + 1 WHERE id = ?", arguments: [parentID])
        cache.ids[path] = id
        return id
    }

    /// Deletes empty folders from `folderID` upwards (never the root).
    func pruneFolders(_ db: Database, from folderID: Int64, cache: inout FolderCache) throws {
        var current: Int64? = folderID
        while let id = current, id != ViewerSchema.rootFolderID {
            guard let row = try Row.fetchOne(db, sql: "SELECT parent_id, path, note_count, folder_count, asset_count FROM folders WHERE id = ?", arguments: [id]) else { return }
            let notes: Int = row["note_count"]
            let folders: Int = row["folder_count"]
            let assets: Int = row["asset_count"]
            guard notes <= 0, folders <= 0, assets <= 0 else { return }
            let parent: Int64? = row["parent_id"]
            try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id])
            cache.ids[row["path"]] = nil
            if let parent {
                try db.execute(sql: "UPDATE folders SET folder_count = folder_count - 1 WHERE id = ?", arguments: [parent])
            }
            current = parent
        }
    }

    func upsertNote(_ db: Database, path: String, meta: FileMeta, contentHash: String, parsed: ParsedNote, generation: Int64, work: inout ResolutionWork, folders: inout FolderCache) throws {
        let basename = VaultPath.basename(of: path)
        let basenameKey = VaultPath.matchKey(basename)
        let noteID: Int64
        if let existing = try Row.fetchOne(db, sql: "SELECT id, content_hash FROM notes WHERE path = ?", arguments: [path]) {
            noteID = existing["id"]
            let oldHash: String = existing["content_hash"]
            if oldHash == contentHash {
                try db.execute(sql: "UPDATE notes SET mtime_ns = ?, size = ? WHERE id = ?", arguments: [meta.mtimeNs, meta.size, noteID])
                return
            }
            try deleteNoteChildren(db, noteID: noteID)
            try db.execute(
                sql: "UPDATE notes SET title = ?, mtime_ns = ?, size = ?, content_hash = ?, indexed_gen = ?, frontmatter = ?, body = ? WHERE id = ?",
                arguments: [parsed.title, meta.mtimeNs, meta.size, contentHash, generation, parsed.frontmatterJSON, parsed.body, noteID]
            )
        } else {
            let folderID = try ensureFolder(db, path: VaultPath.folder(of: path), cache: &folders)
            try db.execute(
                sql: """
                INSERT INTO notes(path, folder_id, basename, basename_key, title, mtime_ns, size, content_hash, indexed_gen, frontmatter, body)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [path, folderID, basename, basenameKey, parsed.title, meta.mtimeNs, meta.size, contentHash, generation, parsed.frontmatterJSON, parsed.body]
            )
            noteID = db.lastInsertedRowID
            try db.execute(sql: "UPDATE folders SET note_count = note_count + 1 WHERE id = ?", arguments: [folderID])
            work.keys.insert(basenameKey)
        }
        try insertNoteChildren(db, noteID: noteID, path: path, parsed: parsed)
        work.sources.insert(noteID)
    }

    private func insertNoteChildren(_ db: Database, noteID: Int64, path: String, parsed: ParsedNote) throws {
        for tag in parsed.tags {
            // Tags are unique by their NFC-lowercased key (Obsidian tags are
            // case-insensitive, including non-ASCII letters); the first
            // spelling seen is displayed.
            let key = VaultPath.matchKey(tag.name)
            try db.execute(sql: "INSERT INTO tags(name, key, note_count) VALUES (?, ?, 0) ON CONFLICT(key) DO NOTHING", arguments: [tag.name, key])
            let tagID = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE key = ?", arguments: [key])!
            try db.execute(sql: "INSERT OR IGNORE INTO note_tags(note_id, tag_id, source) VALUES (?, ?, ?)", arguments: [noteID, tagID, tag.source.rawValue])
            if db.changesCount > 0 {
                try db.execute(sql: "UPDATE tags SET note_count = note_count + 1 WHERE id = ?", arguments: [tagID])
            }
        }
        for alias in parsed.aliases {
            try db.execute(sql: "INSERT OR IGNORE INTO aliases(note_id, alias) VALUES (?, ?)", arguments: [noteID, alias])
        }
        let linkStatement = try db.cachedStatement(sql: """
            INSERT INTO links(source_note_id, ordinal, kind, is_embed, raw, target_path, target_key, heading, block_id, display, line)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        for (ordinal, link) in parsed.links.enumerated() {
            let kind = ViewerSchema.LinkKind(rawValue: link.kind.rawValue) ?? .wiki
            let target = LinkResolver.classify(kind: kind, targetPath: link.target.path, sourcePath: path)
            let display = link.kind == .markdown ? link.text : link.target.display
            try linkStatement.execute(arguments: [
                noteID, ordinal, kind.rawValue, link.isEmbed, link.raw, link.target.path, target.key,
                link.target.heading, link.target.blockID, display, link.line,
            ])
        }
        for (ordinal, heading) in parsed.headings.enumerated() {
            try db.execute(
                sql: "INSERT INTO headings(note_id, ordinal, level, text, heading_key, line) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [noteID, ordinal, heading.level, heading.text, HeadingKey.make(heading.text), heading.line]
            )
        }
        for block in parsed.blockIDs {
            try db.execute(sql: "INSERT OR IGNORE INTO blocks(note_id, block_id, line) VALUES (?, ?, ?)", arguments: [noteID, block.id, block.line])
        }
    }

    private func deleteNoteChildren(_ db: Database, noteID: Int64) throws {
        try db.execute(sql: "UPDATE tags SET note_count = note_count - 1 WHERE id IN (SELECT tag_id FROM note_tags WHERE note_id = ?)", arguments: [noteID])
        try db.execute(sql: "DELETE FROM note_tags WHERE note_id = ?", arguments: [noteID])
        try db.execute(sql: "DELETE FROM aliases WHERE note_id = ?", arguments: [noteID])
        try db.execute(sql: "DELETE FROM links WHERE source_note_id = ?", arguments: [noteID])
        try db.execute(sql: "DELETE FROM headings WHERE note_id = ?", arguments: [noteID])
        try db.execute(sql: "DELETE FROM blocks WHERE note_id = ?", arguments: [noteID])
    }

    func deleteNote(_ db: Database, path: String, work: inout ResolutionWork, folders: inout FolderCache) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT id, folder_id, basename_key FROM notes WHERE path = ?", arguments: [path]) else { return }
        let id: Int64 = row["id"]
        let folderID: Int64 = row["folder_id"]
        try deleteNoteChildren(db, noteID: id)
        try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id])
        try db.execute(sql: "UPDATE folders SET note_count = note_count - 1 WHERE id = ?", arguments: [folderID])
        try pruneFolders(db, from: folderID, cache: &folders)
        work.keys.insert(row["basename_key"])
        work.removedNotes.insert(id)
        work.sources.remove(id)
    }

    func upsertAsset(_ db: Database, path: String, kind: ViewerSchema.AssetKind, meta: FileMeta, sourceSHA256: String, blob: AssetBlobInfo?, text: String? = nil, work: inout ResolutionWork, folders: inout FolderCache) throws {
        let name = VaultPath.fileName(of: path)
        // A base's source; its rows are evaluated before publication.
        func storeBase(_ id: Int64) throws {
            guard kind == .base else { return }
            try db.execute(sql: "INSERT INTO bases(asset_id, source) VALUES (?, ?) ON CONFLICT(asset_id) DO UPDATE SET source = excluded.source",
                           arguments: [id, text ?? ""])
        }
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM assets WHERE path = ?", arguments: [path]) {
            try db.execute(
                sql: "UPDATE assets SET mtime_ns = ?, size = ?, source_sha256 = ?, blob_sha256 = ?, blob_ext = ?, blob_size = ?, width = ?, height = ? WHERE id = ?",
                arguments: [meta.mtimeNs, meta.size, sourceSHA256, blob?.sha256, blob?.ext, blob?.size, blob?.width, blob?.height, id]
            )
            try storeBase(id)
            return
        }
        let folderID = try ensureFolder(db, path: VaultPath.folder(of: path), cache: &folders)
        let key = VaultPath.matchKey(name)
        try db.execute(
            sql: """
            INSERT INTO assets(path, folder_id, name, name_key, ext, kind, mtime_ns, size, source_sha256, blob_sha256, blob_ext, blob_size, width, height)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [path, folderID, name, key, VaultPath.fileExtension(of: path), kind.rawValue, meta.mtimeNs, meta.size, sourceSHA256, blob?.sha256, blob?.ext, blob?.size, blob?.width, blob?.height]
        )
        try storeBase(db.lastInsertedRowID)
        try db.execute(sql: "UPDATE folders SET asset_count = asset_count + 1 WHERE id = ?", arguments: [folderID])
        work.keys.insert(key)
    }

    func recordDerivative(_ db: Database, sourceSHA256: String, params: String, blob: AssetBlobInfo) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO asset_derivatives(source_sha256, params, blob_sha256, blob_ext, blob_size, width, height) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [sourceSHA256, params, blob.sha256, blob.ext, blob.size, blob.width, blob.height]
        )
    }

    func deleteAsset(_ db: Database, path: String, work: inout ResolutionWork, folders: inout FolderCache) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT id, folder_id, name_key FROM assets WHERE path = ?", arguments: [path]) else { return }
        let id: Int64 = row["id"]
        let folderID: Int64 = row["folder_id"]
        try db.execute(sql: "DELETE FROM assets WHERE id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM bases WHERE asset_id = ?", arguments: [id])
        for table in ["base_cells", "base_rows", "base_groups"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE base_id = ?", arguments: [id])
        }
        try db.execute(sql: "UPDATE folders SET asset_count = asset_count - 1 WHERE id = ?", arguments: [folderID])
        try pruneFolders(db, from: folderID, cache: &folders)
        work.keys.insert(row["name_key"])
        work.removedAssets.insert(id)
    }

    /// Marks an asset for reprocessing on the next reconciliation (used when
    /// its blob went missing from the store).
    public func invalidateAsset(path: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE assets SET mtime_ns = 0 WHERE path = ?", arguments: [path])
        }
    }

    // MARK: Resolution

    /// Resolves the links affected by `work`. Candidate lists are looked up by
    /// the indexed `*_key` columns and cached for the duration of the call.
    func resolve(_ db: Database, work: ResolutionWork) throws -> Int {
        guard !work.isEmpty else { return 0 }
        var noteCandidates: [String: [ResolutionCandidate]] = [:]
        var assetCandidates: [String: [ResolutionCandidate]] = [:]
        var sourcePaths: [Int64: String] = [:]

        func sourcePath(_ id: Int64) throws -> String? {
            if let p = sourcePaths[id] { return p }
            let p = try String.fetchOne(db, sql: "SELECT path FROM notes WHERE id = ?", arguments: [id])
            sourcePaths[id] = p
            return p
        }
        func candidates(note key: String) throws -> [ResolutionCandidate] {
            if let c = noteCandidates[key] { return c }
            let c = try Row.fetchAll(db, sql: "SELECT id, path FROM notes WHERE basename_key = ?", arguments: [key]).map { ResolutionCandidate(id: $0[0], path: $0[1]) }
            noteCandidates[key] = c
            return c
        }
        func candidates(asset key: String) throws -> [ResolutionCandidate] {
            if let c = assetCandidates[key] { return c }
            let c = try Row.fetchAll(db, sql: "SELECT id, path FROM assets WHERE name_key = ?", arguments: [key]).map { ResolutionCandidate(id: $0[0], path: $0[1]) }
            assetCandidates[key] = c
            return c
        }

        let update = try db.cachedStatement(sql: "UPDATE links SET target_note_id = ?, target_asset_id = ? WHERE source_note_id = ? AND ordinal = ?")
        var updated = 0
        var visited = Set<LinkKey>()

        func process(_ cursor: RowCursor) throws {
            while let row = try cursor.next() {
                let key = LinkKey(source: row["source_note_id"], ordinal: row["ordinal"])
                guard visited.insert(key).inserted else { continue }
                guard let source = try sourcePath(key.source) else { continue }
                let kind = ViewerSchema.LinkKind(rawValue: row["kind"]) ?? .wiki
                let target = LinkResolver.classify(kind: kind, targetPath: row["target_path"], sourcePath: source)
                var noteID: Int64?
                var assetID: Int64?
                switch target {
                case .sameNote:
                    noteID = key.source
                case .note(let k, _, _, _):
                    noteID = LinkResolver.choose(target, candidates: try candidates(note: k), sourcePath: source)
                case .asset(let k, _, _, _):
                    assetID = LinkResolver.choose(target, candidates: try candidates(asset: k), sourcePath: source)
                case .invalid:
                    break
                }
                let oldNote: Int64? = row["target_note_id"]
                let oldAsset: Int64? = row["target_asset_id"]
                if oldNote != noteID || oldAsset != assetID {
                    try update.execute(arguments: [noteID, assetID, key.source, key.ordinal])
                    updated += 1
                }
            }
        }

        let columns = "source_note_id, ordinal, kind, target_path, target_note_id, target_asset_id"
        for source in work.sources {
            try process(try Row.fetchCursor(db, sql: "SELECT \(columns) FROM links WHERE source_note_id = ?", arguments: [source]))
        }
        for key in work.keys {
            try process(try Row.fetchCursor(db, sql: "SELECT \(columns) FROM links WHERE target_key = ?", arguments: [key]))
        }
        for id in work.removedNotes {
            try process(try Row.fetchCursor(db, sql: "SELECT \(columns) FROM links WHERE target_note_id = ?", arguments: [id]))
        }
        // Links to a removed asset always carry that asset's name key, which
        // deleteAsset added to `work.keys`; no unindexed target_asset_id scan needed.
        try db.execute(sql: "DELETE FROM tags WHERE note_count <= 0")
        return updated
    }

    private struct LinkKey: Hashable {
        var source: Int64
        var ordinal: Int64
    }
}

func escapeLike(_ s: String) -> String {
    var out = ""
    for c in s {
        if c == "%" || c == "_" || c == "\\" { out.append("\\") }
        out.append(c)
    }
    return out
}
