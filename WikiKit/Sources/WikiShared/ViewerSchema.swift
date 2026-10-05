//
//  ViewerSchema.swift
//  WikiShared
//

/// SQLite schema of the published viewer database (schema version 5:
/// version 1 plus the Obsidian Bases tables (2), the link graph (3), the
/// record of what changed between generations (4) and the host's extras:
/// role-labelled neighbours (5).
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
/// - `graph_*` tables (version 3) hold the link graph the host has already
///   analysed: Leiden clusters, a layout per cluster and one for the
///   cluster overview. The phone reads them a cluster at a time and never
///   lays out or clusters the graph itself (see GraphBuilder.swift).
public enum ViewerSchema {
    public static let version = WikiVersions.schemaVersion

    /// Root folder id. The vault root is always folder 1 with path "".
    public static let rootFolderID: Int64 = 1

    /// Page size of builder and published databases.
    public static let pageSize = 8192

    public static let requiredTables = [
        "meta", "folders", "notes", "tags", "note_tags", "aliases",
        "links", "headings", "blocks", "assets", "notes_fts",
        "bases", "base_cells", "base_rows", "base_groups",
        "graph_clusters", "graph_cluster_links", "graph_nodes", "graph_types",
        "generation_log", "change_log", "log_entries",
        "related",
    ]

    public static let builderOnlyTables = ["builder_state", "asset_derivatives", "pending_changes"]

    /// `change_log.kind`.
    public enum ChangeKind: Int, Sendable, Codable {
        case added = 0
        case modified = 1
        case removed = 2
    }

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
        /// An Obsidian Bases file (`.base`), evaluated by the indexer into
        /// the `base_*` tables.
        case base = 5

        public static func forExtension(_ ext: String) -> AssetKind? {
            switch ext {
            case "base": .base
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
        // Obsidian Bases. A `.base` file is an asset (so links, embeds and
        // folder listings reach it); the indexer evaluates it over the notes
        // before each publication. Rows are keyed by values derived from the
        // note alone (group and sort keys are order-preserving encodings), so
        // an edit rewrites only the rows of the notes it changed, and the
        // viewer pages a view along the primary key.
        //
        // `definition` is the JSON of `BaseDocument`; `source` the YAML text.
        """
        CREATE TABLE bases(
          asset_id INTEGER PRIMARY KEY,
          source TEXT NOT NULL,
          definition TEXT
        )
        """,
        // One row per base and matching note: `cells` is the JSON object of
        // `BaseCell` values for every column any view of the base shows.
        """
        CREATE TABLE base_cells(
          base_id INTEGER NOT NULL,
          note_id INTEGER NOT NULL,
          cells TEXT NOT NULL,
          PRIMARY KEY(base_id, note_id)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE base_rows(
          base_id INTEGER NOT NULL,
          view INTEGER NOT NULL,
          group_key BLOB NOT NULL,
          sort_key BLOB NOT NULL,
          note_id INTEGER NOT NULL,
          PRIMARY KEY(base_id, view, group_key, sort_key, note_id)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE base_groups(
          base_id INTEGER NOT NULL,
          view INTEGER NOT NULL,
          group_key BLOB NOT NULL,
          label TEXT,
          row_count INTEGER NOT NULL,
          PRIMARY KEY(base_id, view, group_key)
        ) WITHOUT ROWID
        """,
        // The link graph, analysed on the host (see GraphBuilder.swift).
        // One row per cluster. x, y: centre in the overview layout, in the
        // units of GraphGeometry.clusterRadius. Only the largest
        // GraphGeometry.overviewClusters clusters are laid out; the others
        // are at 0, 0 and are listed but never drawn.
        """
        CREATE TABLE graph_clusters(
          id INTEGER PRIMARY KEY,
          label TEXT NOT NULL,
          size INTEGER NOT NULL,
          x REAL NOT NULL,
          y REAL NOT NULL
        )
        """,
        "CREATE INDEX graph_clusters_size ON graph_clusters(size, id)",
        // Links between two clusters (cluster_a < cluster_b), weight = link
        // count. skeleton = 1 for the few drawn by default on the overview.
        """
        CREATE TABLE graph_cluster_links(
          cluster_a INTEGER NOT NULL,
          cluster_b INTEGER NOT NULL,
          weight INTEGER NOT NULL,
          skeleton INTEGER NOT NULL,
          PRIMARY KEY(cluster_a, cluster_b)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX graph_cluster_links_b ON graph_cluster_links(cluster_b, cluster_a)",
        // Notes in the graph. x, y: position within the cluster's own layout,
        // inside the unit disk. weight: incoming links from other notes in
        // the graph; degree: distinct neighbours. type and status come from
        // the note's frontmatter.
        """
        CREATE TABLE graph_nodes(
          note_id INTEGER PRIMARY KEY,
          cluster_id INTEGER NOT NULL,
          x REAL NOT NULL,
          y REAL NOT NULL,
          weight INTEGER NOT NULL,
          degree INTEGER NOT NULL,
          type TEXT,
          status TEXT
        )
        """,
        "CREATE INDEX graph_nodes_cluster ON graph_nodes(cluster_id, weight)",
        // Distinct `type` values in the graph, for the type filter.
        """
        CREATE TABLE graph_types(
          name TEXT PRIMARY KEY NOT NULL,
          node_count INTEGER NOT NULL
        ) WITHOUT ROWID
        """,
        // What changed (version 4), for "what happened since you last
        // looked". One row per published generation, with its time and
        // how many notes it added, changed and removed.
        """
        CREATE TABLE generation_log(
          generation INTEGER PRIMARY KEY,
          created_at TEXT NOT NULL,
          added INTEGER NOT NULL,
          modified INTEGER NOT NULL,
          removed INTEGER NOT NULL
        )
        """,
        // The notes each generation added, changed or removed (kind:
        // ChangeKind), by path (a removed note has no row in `notes`).
        // type: the note's frontmatter type; author: Provenance.Author.
        // Bounded: a generation records at most ChangeLog.maximumRowsPerGeneration
        // notes and rows older than the retention period are dropped.
        """
        CREATE TABLE change_log(
          generation INTEGER NOT NULL,
          path TEXT NOT NULL,
          kind INTEGER NOT NULL,
          title TEXT NOT NULL,
          type TEXT,
          author INTEGER NOT NULL,
          PRIMARY KEY(generation, path)
        ) WITHOUT ROWID
        """,
        // Entries of the vault's operation log (`wiki/log.md`), each with
        // the generation it first appeared in. pages: JSON array of
        // [label, note path] for the notes the entry links to.
        """
        CREATE TABLE log_entries(
          id INTEGER PRIMARY KEY,
          entry_key TEXT NOT NULL UNIQUE,
          generation INTEGER NOT NULL,
          date TEXT NOT NULL,
          operation TEXT NOT NULL,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          pages TEXT NOT NULL
        )
        """,
        "CREATE INDEX log_entries_generation ON log_entries(generation, id)",
        // A note's neighbours by role (version 5), from the vault's
        // wiki-related (`<extras>/related.jsonl`, see Extras.swift): role is
        // its name (definition, evidence, contradiction, cluster, …), rank
        // the order within the role, why its one-line reason. At most
        // Extras.maximumRelatedPerNote rows per note.
        """
        CREATE TABLE related(
          note_id INTEGER NOT NULL,
          role TEXT NOT NULL,
          rank INTEGER NOT NULL,
          target_note_id INTEGER NOT NULL,
          why TEXT,
          PRIMARY KEY(note_id, role, rank)
        ) WITHOUT ROWID
        """,
        // Builder-only tables. Present in snapshots but emptied.
        """
        CREATE TABLE builder_state(
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        ) WITHOUT ROWID
        """,
        // Notes changed since the last publication (kind: ChangeKind).
        """
        CREATE TABLE pending_changes(
          path TEXT PRIMARY KEY NOT NULL,
          kind INTEGER NOT NULL
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
        /// Notes and clusters in the graph tables.
        public static let graphNodeCount = "graph_node_count"
        public static let graphClusterCount = "graph_cluster_count"
    }
}
