# WikiViewer architecture

WikiViewer is a fast, native, **read-only** iOS viewer for a very large
Obsidian vault (20k files today, designed for 50k–100k notes). Obsidian Mobile
was unusable with this vault: its WebKit content process grew to 1.5–2.4 GiB
and was killed by Jetsam. WikiViewer never loads the vault into memory; every
screen is served by bounded, indexed SQLite queries against an immutable,
pre-built database.

This document describes the system as implemented. Decisions and open work
are tracked in [TASKS.md](TASKS.md); measurements in
[BENCHMARKS.md](BENCHMARKS.md); security in [THREAT_MODEL.md](THREAT_MODEL.md).

## Overview

```
Obsidian Desktop ⇄ Obsidian Sync ⇄ local vault on the Mac mini   (source of truth)
                                        │  read-only (O_RDONLY | O_NOFOLLOW)
                                        ▼
                         wikiindex (Indexer/, Swift, macOS)
            FSEvents fast path ─┐
   periodic reconciliation ─────┴─▶ changed files ─▶ stable read ─▶ parse
                                        │
                                        ▼
                               builder.sqlite (WAL, mutable, disposable)
                                        │  quiet period / max delay
                                        ▼  SQLite online backup → checks → hash
                       publish directory (immutable artifacts)
                         manifest.json               ← written last
                         generations/viewer-N.sqlite  (optional, whole file)
                         generations/viewer-N.chunks  (chunk list)
                         generations/viewer-N.assets  (blob references, GC)
                         chunks/<aa>/<sha256>         (content-addressed DB chunks)
                         assets/<aa>/<sha256>.<ext>   (content-addressed images)
                                        │
                   transport: Files/iCloud Drive folder, or HTTP(S)
                                        ▼
                          iOS app (WikiViewer/ + WikiKit/)
          staging → size/SHA-256 → SQLite validation → generations/<N>-<sha>
                          → atomic `current` switch → open read-only
```

There is no Obsidian Headless Sync, no dependency on Obsidian's internal
databases, caches, plugin APIs or Sync protocol. The file system is the only
interface between Obsidian and the builder.

## Repository layout

| Path | What |
|---|---|
| `WikiViewer/` | iOS app target (SwiftUI). File-system-synchronized group. |
| `WikiKit/` | Local SwiftPM package linked by the app. |
| `WikiKit/Sources/WikiShared` | Code shared by indexer and app: `ObsidianScanner`, `LinkTarget`, `Frontmatter`, `ViewerSchema`, `ArtifactManifest`, `ChunkList`, `VaultPath`, `Digest`. No dependencies. |
| `WikiKit/Sources/WikiViewerKit` | App data layer: `ViewerDatabase`, repositories, `TrigramSearchEngine`, `GenerationStore`, `ArtifactUpdater`, `ArtifactSource`s, `AssetProvider`, `NoteRenderer`, `Library`, `QueryBenchmark`. Bundles a demo artifact built from `Fixtures/vault`. |
| `Indexer/` | Host SwiftPM package: `IndexerCore` library + `wikiindex` CLI. |
| `Fixtures/vault` | Deterministic fixture vault used by all tests. |
| `scripts/` | `build_demo_artifact.sh`, `bench.sh`, `make_fixture_images.swift`. |

Why Swift for the indexer (the brief preferred Rust): the repo was Swift-only,
no Rust toolchain was installed, and Swift gives first-party FSEvents, ImageIO
and CryptoKit plus — most importantly — lets the indexer and the app run the
**same** Obsidian scanner, schema and manifest code, so link ordinals computed
at index time match the tokens found at render time.

## Indexer (`Indexer/Sources/IndexerCore`)

**Read-only vault access.** `VaultWalker` walks with `fts(3)` using
`FTS_PHYSICAL` (symlinks are never followed) and skips hidden directories
(`.obsidian`, `.trash`, `.git`) without descending. `StableReader` opens files
with `O_RDONLY | O_NOFOLLOW | O_CLOEXEC` and then checks the opened file's
real path (`F_GETPATH`): it must lie inside the vault (a *directory* above the
file may have been replaced by a symlink — `O_NOFOLLOW` only covers the last
component) and must equal the requested vault path exactly after NFC
normalization (on case-insensitive APFS a case-only rename otherwise leaves
the old path "readable"). Nothing in the indexer opens a vault
path for writing; `IndexerConfiguration.validate()` refuses a state or
publish directory inside the vault (and a vault inside them), resolving paths
with `realpath(3)` through the longest existing ancestor so the check also
holds for directories that do not exist yet. Tests snapshot the fixture vault
(size, mtime, SHA-256 of every file) before and after indexing+publishing.

**Stable reads.** `fstat A → read → 1-byte EOF probe → fstat B → lstat(path) C`;
accepted only if size, mtime (ns) and inode agree across A, B, C and the byte
count matches. C catches Obsidian replacing the file by rename while we read
the old inode. Unstable files are retried with linear backoff (up to 30
attempts), then left to reconciliation.

**Change detection.** `builder.sqlite` stores, per note/asset: path,
`mtime_ns`, size, content SHA-256 and the generation it was last indexed in
(`indexed_gen`).
- *Reconciliation* (correctness path, every 10 min and on dropped events):
  a metadata walk compared with stored (size, mtime); only differing files and
  deletions are read. No Markdown is reparsed for unchanged files.
- *FSEvents* (fast path): one stream for the whole vault
  (`kFSEventStreamCreateFlagFileEvents`), never one watcher per file.
  `MustScanSubDirs` → subtree reconciliation; `UserDropped`/`KernelDropped`/
  `RootChanged` → full reconciliation. Events are debounced (750 ms).
- A content hash equal to the stored one only updates metadata.

**Bounded work.** Changed paths are processed in batches of 512, one write
transaction per batch. Each batch transaction also records `dirty` and
`resolution_pending` in `builder_state`; link re-resolution clears the latter
in its own transaction. If the process dies in between, the next start
re-resolves every link once and still publishes. A `flock` on
`<state>/indexer.lock` prevents two indexers from sharing a builder/publish
directory. Notes are read and parsed with at most
`activeProcessorCount` tasks in flight; images with at most 2 (each large image
needs a full decode buffer). A 10k-file Sync burst therefore never fans out
into 10k simultaneous reads.

**Parsing.** `Frontmatter.split` (LF and CRLF) → Yams (YAML) → properties
stored as an ordered JSON array of `[key, value]` pairs, capped at 256 KiB
after expansion (YAML alias "billion laughs" cannot blow up the database); `ObsidianScanner` (shared with the
app) extracts wikilinks, embeds, internal Markdown links, inline tags,
headings (ATX and setext) and block IDs, skipping fenced code, `$$` math,
inline code, `%%comments%%` and HTML comments. Title = frontmatter `title` or
the file's basename. Tags = frontmatter `tags`/`tag` + inline `#tags`,
case-insensitively deduplicated (Unicode-aware `tags.key`). Aliases =
`aliases`/`alias`; a scalar is one alias (not split on commas).

**Publication scheduling.** Publish after the vault has been quiet for 20 s,
but never later than 5 min after the first unpublished change
(`PublicationScheduler`, unit tested with synthetic clocks), so a large Sync
batch is not published half-way yet updates cannot be postponed forever.

### Link resolution

Resolution happens on the host (`LinkResolver`), links are stored resolved,
and the app just follows ids. Candidates are looked up through indexed keys
(`notes.basename_key`, `assets.name_key`: NFC + lowercased), never by scanning.

1. Empty path (`[[#Heading]]`, `[x](#h)`) → the source note.
2. Extension is a known attachment type other than `.md` → asset, else note
   (`.md` optional).
3. Candidates share the target's file name (case/normalization-insensitive).
4. Preference: (a) relative path from the source folder (Markdown links, and
   wikilinks starting with `./`/`../`); (b) exact vault-root path; (c) if the
   target contains `/`, candidates whose path ends with `/<target>` — none →
   unresolved; (d) otherwise any candidate. Ties: same folder as source, then
   fewest path components, then shortest path, then lexicographic.
5. Aliases never resolve links (Obsidian writes `[[file|alias]]`).

Obsidian's exact tie-breaking for duplicate basenames is not publicly
specified; rule 4 is a documented, deterministic approximation (it matches
Obsidian's "shortest path" link format in the common case).

Unresolved links are kept (`target_note_id` and `target_asset_id` NULL) with
their `target_key`. When notes/assets are added, removed or renamed, only
links whose `target_key` matches the affected names (plus links of re-parsed
source notes and links that pointed at removed notes) are re-resolved — no
source Markdown is reparsed. Test: adding `Nonexistent Note.md` resolves
`[[Nonexistent Note]]` in `Home.md` without touching `Home.md`'s row.

## SQLite schema (`WikiShared/ViewerSchema.swift`, version 1)

| Table | Purpose / key indexes |
|---|---|
| `meta` | schema/scanner version, generation, created_at, counts |
| `folders` | lazy tree: `parent_id`, `path` UNIQUE, per-folder counts; `folders_parent_name` |
| `notes` | `path` UNIQUE, `folder_id`, `basename(_key)`, `title` (NOCASE), mtime, size, `content_hash`, `indexed_gen`, `frontmatter` (JSON), `body`; indexes `notes_folder(folder_id,title)`, `notes_basename_key`, `notes_title` |
| `tags`, `note_tags` | `tags.key` (NFC+lowercase) unique; tag → notes via `note_tags_tag(tag_id,note_id)`; note → tags via PK |
| `aliases` | `aliases_alias` |
| `links` | PK `(source_note_id, ordinal)`; kind (wiki/markdown), `is_embed`, raw, target path/key, heading, block id, display, `target_note_id`, `target_asset_id`, line. Backlinks = incoming rows via partial index `links_target_note(target_note_id, source_note_id)`; no duplicated backlink graph |
| `headings`, `blocks` | heading text/level/line and `^block-id` lines per note |
| `assets` | path, kind, source SHA-256, derivative blob SHA-256/ext/size/dims (no BLOBs in SQLite) |
| `notes_fts` | FTS5, `tokenize='trigram'`, `detail='none'`, external content = `notes(title, body)`, kept in sync by triggers |
| `builder_state`, `asset_derivatives` | builder-only; emptied in every snapshot |

Page size is 8192 (packs 2–3 KB note rows better than 4096: `notes` −16%).
`PRAGMA secure_delete=ON` on the builder and on each snapshot: text removed
from a note (or a deleted note) is zeroed instead of lingering in free space
that the backup would copy into published files.

**Builder vs viewer.** The builder database is the viewer schema plus two
builder-only tables. A publication (`Publisher`) is:

1. SQLite online backup of `builder.sqlite` into `.tmp/viewer-N.sqlite.partial`;
2. on that private copy: clear builder-only tables, drop references to asset
   blobs missing from the store (and mark them for reprocessing), write
   `meta`, `journal_mode=DELETE`, `incremental_vacuum`, bounded `ANALYZE`
   (`analysis_limit=400`), optional FTS integrity-check;
3. close; verify the header is in rollback mode and remove SQLite's unused
   `-shm` left by the WAL→DELETE switch;
4. `quick_check` (or `integrity_check` with `--full-check`) on a fresh
   read-only connection; schema and generation verified;
5. fsync; split into 128 KiB chunks written content-addressed (new chunks
   only), computing the whole-file SHA-256 in the same pass;
6. rename chunk list, asset sidecar and (unless `--chunks-only`) the database
   into `generations/`; fsync the directory;
7. write `manifest.json` to a temp file, fsync, rename — **last**; fsync dir.

A failure at any step leaves the previous manifest (and generation) intact;
tests inject crashes before the database rename, before the manifest rename,
and corruption before the integrity check. Generation numbers never go
backwards, even if `builder.sqlite` is deleted (the next number is
`max(state, generations on disk, manifest) + 1`). No VACUUM per publication.
Retention keeps the newest 3 generations; unreferenced chunks and asset blobs
older than a 1 h grace period are garbage-collected.

## Full-text search

FTS5 `trigram` tokenization gives useful Japanese substring search without a
morphological dictionary. With `detail='none'` the index only records which
rows contain each trigram; queries use `body LIKE '%term%'` on the FTS table,
which FTS5 answers from the trigram index and then verifies against the text
(exact substring semantics, no false positives). Measured on 20k notes the
index shrank from 109.5 MiB (`detail=full`) to 16.8 MiB and common-term
queries got faster (no bm25 over every match). Phrase `MATCH` is not used.

`TrigramSearchEngine` (behind the `SearchEngine` protocol, so a server-side
tokenizer or CJK bigram index can replace it without UI changes), on its own
read connection so a slow search never delays navigation:
- **stage 1 (index only):** every trigram of the longest term (≥ 3 chars)
  must occur — `MATCH '"abc" AND "bcd" AND …'` — newest rows first, at most
  2000 candidates; no note text is read;
- **stage 2:** exact substring `LIKE` on those candidates only, at most 400
  matches; plus title matches from `notes_title`;
- other terms (including < 3 chars, e.g. `東京`) filter the matches;
- rank by title hit, occurrence count, recency; snippet cut around the first
  match and highlighted in Swift — all bounded;
- queries with only < 3-character terms use titles, aliases and tags (indexed)
  and never scan note bodies.

So even a rare phrase made of very common trigrams reads a bounded number of
note bodies. Limitations: `LIKE` folds only ASCII case; for extremely common
terms only the newest 2000 candidates are considered.

## Assets

Every attachment with a known extension gets an `assets` row. Images get a
viewer blob: the original if it is ≤ 2048 px (configurable), ≤ 4 MB and a
web-friendly type, otherwise an ImageIO thumbnail (longest side 2048,
EXIF orientation applied, JPEG q=0.82 or PNG with alpha). Blobs live at
`assets/<aa>/<sha256>.<ext>`, deduplicated by content and shared across
generations; derivatives are cached by (source SHA-256, parameters). SVG,
PDF, audio and video are metadata-only for now (placeholders in the app).

## iOS app

### Data layer (`WikiViewerKit`)

- **`ViewerDatabase`** opens a finalized generation read-only
  (`SQLITE_OPEN_READONLY`), via `file:…?immutable=1` (Apple's SQLite is built
  with `SQLITE_USE_URI`; verified in the Simulator) because files under
  `generations/` never change, with `PRAGMA query_only=1`, an 8 MiB page cache
  and 128 MiB mmap (clean, reclaimable pages). Files in transport or staging
  locations are never opened this way. Opening runs a handful of catalog
  queries — O(1) in vault size.
- **Repositories** (`NoteRepository`, `FolderRepository`, `LinkRepository`,
  `TagRepository`, `AssetRepository`, `TrigramSearchEngine`) return small
  value types; every list query has a `LIMIT` (≤ 500) and an index. Folder
  listings use keyset pagination on `(folder_id, title, id)`. Backlinks and
  tag → notes are keyset-paginated in index order (newest note first:
  `links_target_note`, `note_tags_tag`), so a hub note with 50k backlinks or
  a tag on 50k notes costs the same per page as a small one; backlink counts
  are capped at 10,000 ("10000+").
- **`NoteRenderer`**: on-demand presentation parsing of *one* note, off the
  main actor (`@concurrent`). The shared scanner reports exact byte ranges of
  Obsidian tokens outside code/comments; each is rewritten into a standard
  CommonMark link/image whose URL encodes the resolved target
  (`wikiviewer://note/<id>?h=…`, `…/missing?t=…`, `…/tag?n=…`, embeds by
  index); comments are removed and `^block-id` markers stripped while keeping
  line numbers. swift-markdown (cmark-gfm) parses the result; the AST becomes
  `RenderBlock`s (headings, paragraphs as `AttributedString`, code, lists with
  task boxes, tables, quotes, callouts `> [!type]±`, embeds, rules). Lists
  are flattened into one row per item (with depth), code blocks longer than
  150 lines and tables longer than 60 rows are split, so a huge outline or
  log renders lazily row by row. Only in-app targets and http(s)/mailto
  become tappable links. Heading
  and block anchors map to block ids for scrolling. Link rows are matched by
  ordinal (same scanner on both sides) with a raw-text fallback.
- **`GenerationStore`**: `Application Support/WikiViewer/generations/<NNNNNN>-<sha[0:12]>/{viewer.sqlite, viewer.chunks, manifest.json}`,
  `staging/`, shared `assets/`, and atomically replaced pointer files
  `current`, `previous`, `lineage`. Excluded from device backup (derived data).
- **`ArtifactUpdater`**: manifest (≤ 64 KiB, structurally validated) →
  `generation > current` within the same source lineage → download into
  `staging/` (size-capped) — either the whole file or, when the device already
  has a generation, **only the missing chunks** (each verified against its
  SHA-256; present chunks are copied from installed generations) →
  whole-file size + SHA-256 → `quick_check`, schema, `meta.generation`,
  note count, and an **exact schema match** (the untrusted file's
  `sqlite_master` is compared with the schema this build creates in memory;
  no extra views/triggers, identical constraints) on a read-only
  (non-immutable) connection with `trusted_schema=OFF` → rename into
  `generations/`. Requires free space ≥ 2 × database size. Nothing is
  switched here.
- **`Library`** (`@MainActor`, `@Observable`): bootstrap opens `current`,
  falling back to `previous` and then any installed generation; a broken
  generation is deleted and never becomes the fallback. Update checks wait
  for bootstrap; one update runs at a time, and a source change cancels an
  in-flight update for the old source; "Delete Local Snapshots" cancels and
  awaits an in-flight update first. After a switch, asset blobs referenced by
  neither current nor previous are deleted. The
  switch: prepare fully → open the new database → atomically write `current`
  (old → `previous`) → swap the session on the main actor (views reload via
  `.task(id: session.id)`) → prune everything except current and previous.
  The old connection is released when the last in-flight query finishes; its
  files stay as the fallback. First launch installs the bundled demo artifact
  through the same validated path.
- **`AssetProvider`**: fetches a blob only when a view shows it, verifies its
  SHA-256 before moving it into the store, shares concurrent fetches.
  `ImageDownsampler` decodes with `CGImageSourceCreateThumbnailAtIndex` at
  display size (≤ 2048 px); `ImageCache` is a byte-bounded LRU (48 MiB),
  purged on memory warnings. At most 4 blob downloads run at once. Views drop
  their decoded image when they scroll off screen (LazyVStack keeps row
  state), embedded notes load at most 32k characters and drop their rendered
  blocks off screen, and large notes deeper in the navigation stack release
  their rendered blocks (re-rendered on return).

### Transport (`ArtifactSource`)

- `LocalFolderArtifactSource` — any folder the user picks in the Files app,
  stored as a security-scoped bookmark: a local folder, SMB share, or an
  **iCloud Drive folder that the Mac mini publishes into**. Reads are
  coordinated (`NSFileCoordinator`) so File Provider placeholders are
  materialized first; the folder is only read, never opened in place. No
  iCloud entitlement is needed for this.
- `HTTPArtifactSource` — any static HTTP(S) server; downloads stream to disk
  and are cancelled as soon as they exceed the announced size.
  `wikiindex serve` is a minimal static server for LAN tests (10 s request
  deadline, ≤ 64 connections).
- Coordinated folder reads run on a dedicated dispatch queue, not on Swift's
  cooperative thread pool (they can block while iCloud Drive downloads).

Generation numbers are compared only within one lineage (source identity), so
switching sources (e.g. from the demo) is never mistaken for "up to date".
Transport storage is never runtime storage: everything is copied into
staging, validated and moved into Application Support.

### UI

Native SwiftUI, standard `TabView` + `NavigationStack` per tab (Files,
Search, Tags, Settings), plain lists, system text styles (Dynamic Type), dark
mode by default. Routes are vault paths, not row ids, so navigation stacks
survive generation switches. Features: lazy folder tree, quick switcher
(⌘O / toolbar), note view with properties, tags, outline menu, wikilinks and
Markdown links, heading/block navigation, callouts, image and note embeds
(embedded notes render one level deep), backlinks (paged), tag → notes
(nested tags optional), full-text search with highlighted snippets, missing
note screen listing linking notes, Settings with generation/freshness,
source selection, update status, memory footprint and storage diagnostics.
No editing UI.

## Concurrency

The app target builds in Swift 6 language mode with main-actor default
isolation; the packages build in Swift 6 mode. UI state lives on the main
actor; database reads go through GRDB's async APIs (serialized on GRDB's
queue), and parsing, rendering, hashing and image decoding run off the main
actor (`@concurrent`, actors, task groups). The indexer is an `actor`; its
children are bounded task groups. No `@unchecked Sendable` or
`nonisolated(unsafe)` in production code; the FSEvents stream reference is
owned by a `Mutex`. (One test helper uses `@unchecked Sendable` guarded by a
lock.)

### Delta transport

Every publication also splits the database into 128 KiB chunks stored
content-addressed under `chunks/`, plus a chunk list per generation
(`generations/viewer-N.chunks`, its SHA-256 in the manifest). A device that
already has a generation copies every chunk it has from its installed
databases and fetches only the rest (6 in parallel, each verified), then
verifies the whole file as usual. Measured: after a one-note edit 39 of 3706
chunks were new for a 100k-note database (~5 MB instead of 463 MB). With
`--chunks-only` the whole database file is not published at all, which keeps
an iCloud Drive publish folder from re-uploading hundreds of MB per
generation; first installs then assemble from chunks.

## Dependencies

All via Swift Package Manager (no CocoaPods), all permissively licensed and
actively maintained:

| Package | Version | License | Used by | Why |
|---|---|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | MIT | app, indexer | SQLite access (already used by the project) |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | 0.9.0 | Apache-2.0 | app | CommonMark/GFM AST for native rendering (Apple) |
| swift-cmark (transitive) | 0.9.0 | BSD-2-Clause (+ MIT parts) | app | parser behind swift-markdown |
| [Yams](https://github.com/jpsim/Yams) | 6.2.2 | MIT (bundles libyaml, MIT) | indexer only | YAML frontmatter |

SQLite is the system library (3.54 on macOS 27; FTS5 with the trigram
tokenizer and `SQLITE_USE_URI` verified on macOS and the iOS 27 Simulator).
No code was copied from Obsidian; compatibility targets are Obsidian's public
documentation of links, embeds, tags, aliases, properties and callouts.

## Known limitations

- Scanner simplifications: indented (4-space) code blocks are scanned like
  text; inline code spans must close on the same line; inline `$math$` is not
  skipped; `[[x]]` nested inside Markdown link text is not recorded.
- Resolution tie-breaking for duplicate basenames approximates Obsidian.
- Remote images (`![](https://…)`) are shown as links, not fetched.
- Search: ASCII-only case folding; only the newest 2000 index candidates are
  verified for extremely common terms.
- Backlinks and tag listings are ordered newest-first (index order), not by
  title, to keep them bounded.
- No manifest signatures yet (hash validation is mandatory); see THREAT_MODEL.
- The indexer should run as a LaunchAgent in the logged-in user's GUI session:
  ImageIO's hardware JPEG path needs WindowServer access and can block inside
  a restricted sandbox (observed while developing).
