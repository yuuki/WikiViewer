//
//  ViewerSchema.swift
//  WikiShared
//

/// SQLite schema of the published viewer database (schema version 1).
///
/// The builder database uses exactly these tables plus builder-only tables
/// (see `builderOnlyTables`), which are emptied in every published snapshot.
///
/// Design notes (see ARCHITECTURE.md for the full rationale):
/// - Every list the viewer shows is served by an index; no query needs to
///   scan `notes`.
/// - `*_key` columns hold NFC + lowercased strings for link resolution
///   (SQLite's NOCASE only folds ASCII).
/// - Backlinks are not stored separately; they are the incoming rows of
///   `links`, served by `links_target_note`.
/// - FTS5 uses the `trigram` tokenizer over an external-content table, so the
///   note text is stored once (in `notes.body`), with `detail='none'`: the
///   index only records which rows contain each trigram. Searches use
///   `LIKE '%term%'` on the FTS table, which FTS5 answers from the trigram
///   index and then verifies against the text (exact substring semantics).
///   Measured on a 20k-note vault: 17 MiB instead of 109 MiB for
///   detail=full, and faster bounded queries (see BENCHMARKS.md).
/// - Page size 8192 (set by the builder) packs 2–3 KB note rows better than
///   4096 (−16% for `notes`).
public enum ViewerSchema {
    public static let version = WikiVersions.schemaVersion

    /// Root folder id. The vault root is always folder 1 with path "".
    public static let rootFolderID: Int64 = 1

    /// Page size of builder and published databases.
    public static let pageSize = 8192

    public static let requiredTables = [
        "meta", "folders", "notes", "tags", "note_tags", "aliases",
        "links", "headings", "blocks", "assets", "notes_fts",
    ]

    public static let builderOnlyTables = ["builder_state", "asset_derivatives"]

    public enum LinkKind: Int, Sendable {
        case wiki = 0
        case markdown = 1
    }

    public enum AssetKind: Int, Sendable {
        case image = 0
        case pdf = 1
        case audio = 2
        case video = 3
        case other = 4

        public static func forExtension(_ ext: String) -> AssetKind? {
            switch ext {
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "avif", "svg": .image
            case "pdf": .pdf
            case "mp3", "m4a", "wav", "ogg", "flac", "aac", "3gp", "webm_audio": .audio
            case "mp4", "mov", "webm", "ogv", "mkv", "m4v": .video
            default: nil
            }
        }
    }

    public enum TagSource: Int, Sendable {
        case frontmatter = 0
        case inline = 1
        case both = 2
    }

    public static let createStatements: [String] = [
        """
        CREATE TABLE meta(
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE folders(
          id INTEGER PRIMARY KEY,
          parent_id INTEGER REFERENCES folders(id),
          path TEXT NOT NULL UNIQUE,
          name TEXT NOT NULL COLLATE NOCASE,
          note_count INTEGER NOT NULL DEFAULT 0,
          folder_count INTEGER NOT NULL DEFAULT 0,
          asset_count INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX folders_parent_name ON folders(parent_id, name)",
        """
        CREATE TABLE notes(
          id INTEGER PRIMARY KEY,
          path TEXT NOT NULL UNIQUE,
          folder_id INTEGER NOT NULL REFERENCES folders(id),
          basename TEXT NOT NULL,
          basename_key TEXT NOT NULL,
          title TEXT NOT NULL COLLATE NOCASE,
          mtime_ns INTEGER NOT NULL,
          size INTEGER NOT NULL,
          content_hash TEXT NOT NULL,
          indexed_gen INTEGER NOT NULL DEFAULT 0,
          frontmatter TEXT,
          body TEXT NOT NULL
        )
        """,
        "CREATE INDEX notes_folder ON notes(folder_id, title)",
        "CREATE INDEX notes_basename_key ON notes(basename_key)",
        "CREATE INDEX notes_title ON notes(title)",
        """
        CREATE TABLE tags(
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL COLLATE NOCASE,
          key TEXT NOT NULL UNIQUE,
          note_count INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX tags_name ON tags(name)",
        """
        CREATE TABLE note_tags(
          note_id INTEGER NOT NULL,
          tag_id INTEGER NOT NULL,
          source INTEGER NOT NULL,
          PRIMARY KEY(note_id, tag_id)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX note_tags_tag ON note_tags(tag_id, note_id)",
        """
        CREATE TABLE aliases(
          note_id INTEGER NOT NULL,
          alias TEXT NOT NULL COLLATE NOCASE,
          PRIMARY KEY(note_id, alias)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX aliases_alias ON aliases(alias)",
        """
        CREATE TABLE links(
          source_note_id INTEGER NOT NULL,
          ordinal INTEGER NOT NULL,
          kind INTEGER NOT NULL,
          is_embed INTEGER NOT NULL,
          raw TEXT NOT NULL,
          target_path TEXT NOT NULL,
          target_key TEXT NOT NULL,
          heading TEXT,
          block_id TEXT,
          display TEXT,
          target_note_id INTEGER,
          target_asset_id INTEGER,
          line INTEGER NOT NULL,
          PRIMARY KEY(source_note_id, ordinal)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX links_target_note ON links(target_note_id, source_note_id) WHERE target_note_id IS NOT NULL",
        "CREATE INDEX links_target_key ON links(target_key)",
        """
        CREATE TABLE headings(
          note_id INTEGER NOT NULL,
          ordinal INTEGER NOT NULL,
          level INTEGER NOT NULL,
          text TEXT NOT NULL,
          heading_key TEXT NOT NULL,
          line INTEGER NOT NULL,
          PRIMARY KEY(note_id, ordinal)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE blocks(
          note_id INTEGER NOT NULL,
          block_id TEXT NOT NULL,
          line INTEGER NOT NULL,
          PRIMARY KEY(note_id, block_id)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE assets(
          id INTEGER PRIMARY KEY,
          path TEXT NOT NULL UNIQUE,
          folder_id INTEGER NOT NULL REFERENCES folders(id),
          name TEXT NOT NULL COLLATE NOCASE,
          name_key TEXT NOT NULL,
          ext TEXT NOT NULL,
          kind INTEGER NOT NULL,
          mtime_ns INTEGER NOT NULL,
          size INTEGER NOT NULL,
          source_sha256 TEXT NOT NULL,
          blob_sha256 TEXT,
          blob_ext TEXT,
          blob_size INTEGER,
          width INTEGER,
          height INTEGER
        )
        """,
        "CREATE INDEX assets_name_key ON assets(name_key)",
        "CREATE INDEX assets_folder ON assets(folder_id, name)",
        """
        CREATE VIRTUAL TABLE notes_fts USING fts5(
          title, body,
          content='notes', content_rowid='id',
          tokenize='trigram', detail='none'
        )
        """,
        """
        CREATE TRIGGER notes_fts_ai AFTER INSERT ON notes BEGIN
          INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
        END
        """,
        """
        CREATE TRIGGER notes_fts_ad AFTER DELETE ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
        END
        """,
        """
        CREATE TRIGGER notes_fts_au AFTER UPDATE OF title, body ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
          INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
        END
        """,
        // Builder-only tables. Present in snapshots but emptied.
        """
        CREATE TABLE builder_state(
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE asset_derivatives(
          source_sha256 TEXT NOT NULL,
          params TEXT NOT NULL,
          blob_sha256 TEXT NOT NULL,
          blob_ext TEXT NOT NULL,
          blob_size INTEGER NOT NULL,
          width INTEGER,
          height INTEGER,
          PRIMARY KEY(source_sha256, params)
        ) WITHOUT ROWID
        """,
    ]

    public enum MetaKey {
        public static let schemaVersion = "schema_version"
        public static let scannerVersion = "scanner_version"
        public static let generation = "generation"
        public static let createdAt = "created_at"
        public static let builder = "builder"
        public static let noteCount = "note_count"
        public static let assetCount = "asset_count"
    }
}
