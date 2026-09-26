# WikiViewer — task tracker

Persistent project state. Updated during implementation; the conversation is
not the source of truth. Legend: `[x]` done, `[~]` in progress, `[ ]` todo,
`[-]` deferred (with reason).

## Decisions (recorded as made)

- D1 Host-side indexer language: **Swift** (SwiftPM package `Indexer/`), not
  Rust. Evidence: the repository is Swift-only, no Rust toolchain is installed
  on this machine (installing one would modify files outside the repo), and
  Swift gives first-party FSEvents, ImageIO, CryptoKit and lets the indexer and
  the app share one Obsidian-syntax scanner, the manifest model and the schema
  (so link ordinals agree between index time and render time).
- D2 Shared code lives in a local SwiftPM package `WikiKit/` (`WikiShared`,
  `WikiViewerKit`). The app target links `WikiViewerKit`. This required a
  small hand edit of `project.pbxproj` (local package reference + product
  dependency) because no Xcode MCP tool adds package dependencies. The app
  target's `SWIFT_VERSION` was raised 5.0 → 6.0 (strict concurrency).
  Signing, bundle ID, team, entitlements, capabilities: untouched.
- D3 Builder DB schema is a superset of the viewer schema; a publication is an
  SQLite online-backup copy of `builder.sqlite`, post-processed (builder-only
  rows cleared, journal_mode=DELETE, meta, incremental_vacuum, bounded
  ANALYZE), checked, hashed and renamed into place. No VACUUM per publication.
- D4 Link resolution happens on the host; the viewer follows resolved ids.
  Rules in ARCHITECTURE.md ("Link resolution").
- D5 Search: FTS5 `trigram` external-content table over `notes(title, body)`;
  <3-character terms use a bounded fallback (titles/aliases/tags, indexed).
- D6 Transport: `ArtifactSource` protocol with `LocalFolderArtifactSource`
  (any Files-app folder incl. iCloud Drive via security-scoped bookmark — no
  iCloud entitlement needed) and `HTTPArtifactSource` (size-bounded streaming).
- D7 Frontmatter YAML parsed on the host with Yams (MIT) and stored as an
  ordered JSON array of `[key, value]` pairs; the app needs no YAML parser.
- D8 Generation directories on device are named `<generation>-<sha256[0:12]>`
  and tracked with `current`/`previous`/`lineage` pointer files, so two
  sources that both publish "generation 1" never collide.
- D9 Remote images referenced by URL are not fetched (privacy, bounded
  memory); they render as links.
- D10 FTS5 `detail='none'` (measured: 16.8 MiB vs 109.5 MiB for detail=full at
  20k notes, faster queries). Search = trigram AND MATCH for bounded
  candidates (index only) + exact LIKE verification on candidates.
- D11 Page size 8192 (notes table −16% vs 4096).
- D12 Delta transport: 128 KiB content-addressed chunks + per-generation chunk
  list; devices reuse local chunks. `--chunks-only` for iCloud Drive.
- D13 Backlinks and tag listings ordered newest-first (index order, keyset)
  instead of by title, to keep every page bounded for hub notes / huge tags.
- D14 Builder runs with `secure_delete=ON`; published snapshots never carry
  removed note text in free space.
- D15 Page-level packs (`WikiShared/PagePack.swift`) on top of chunks: per
  publication one delta pack from each of the last 3 generations (changed
  pages XOR old page, LZFSE, parts ≤ 8 MiB raw) and a compressed keyframe
  renewed when > 20% of chunks are missing from it. Chunks stay the unit of
  verification; packs are an optimization with fallback to chunks.
- D16 Delta install = APFS clone of the base generation + in-place page
  writes; verification hashes only chunks the pack touched (others equal the
  device-computed chunk list of the verified base). quick_check still runs.
- D17 Update latency: the open app follows the source (HTTP long poll against
  `wikiindex serve`, 20–30 s polling otherwise) with exponential-backoff
  retries; BGAppRefreshTask for closed-app refresh (Info.plist merged from
  `Config/WikiViewer-Info.plist`: `fetch` background mode + task id — no
  entitlement). One shared URLSession with per-task size-limit delegates.
- D18 Host: FSEvents for never-indexed paths (`.obsidian/`, excluded folders)
  do not count as activity; ≤ 5-file edits publish after 3 s of quiet,
  bursts/reconciliations after 20 s. `wikiindex serve` keeps connections alive.

## Phase A — repository baseline
- [x] Inspect repo, Xcode project, targets, git status
- [x] Build untouched project for iOS Simulator (BUILD SUCCEEDED, Xcode 27.0)
- [x] TASKS.md
- [x] ARCHITECTURE.md, THREAT_MODEL.md, BENCHMARKS.md with real content
- [x] Old sample-DB code replaced by WikiViewerKit (tests cover the new layer)

## Phase B — schema + fixture indexer
- [x] WikiShared: ObsidianScanner, LinkTarget, Frontmatter, Manifest, ViewerSchema, VaultPath, Digest
- [x] Indexer: builder schema, NoteParser (Yams), LinkResolver, BuilderDatabase
- [x] Fixture vault `Fixtures/vault` (+ `scripts/make_fixture_images.swift`)
- [x] `wikiindex build` / `wikiindex verify`
- [x] Link-resolution tests (fixture + case/Unicode/duplicates/relative)

## Phase C/D — iOS data access + UI
- [x] ViewerDatabase (readonly, `immutable=1` URI, query_only, bounded cache, mmap)
- [x] Repositories (notes, folders, links/backlinks, tags, assets, search)
- [x] Browse (lazy, keyset-paged), note view, native Markdown rendering
- [x] Wikilinks, headings/outline, block refs, callouts, embeds, backlinks, properties, tags
- [x] Verified in iOS Simulator (screenshots) — folder list, note, embeds, search

## Phase E — search
- [x] FTS5 trigram + snippets + highlight
- [x] Short-query fallback; mixed short/long terms
- [x] Quick switcher (title prefix/infix, alias)

## Phase F — incremental indexing
- [x] File state (path, mtime_ns, size, content hash, indexed_gen)
- [x] Stable reads (fstat/read/fstat/lstat; rename-over detection; no symlinks)
- [x] Reconciliation (metadata walk via fts(3))
- [x] FSEvents (single stream), debounce, bounded parse concurrency, retry/backoff
- [x] Targeted re-resolution on add/remove/rename (no reparse of sources)

## Phase G — publication
- [x] Backup snapshot → quick_check → fsync → SHA-256 → rename → manifest last
- [x] Quiet period + maximum publication delay (PublicationScheduler, tested)
- [x] Retention/GC of generations and orphan blobs (grace period)
- [x] Failure tests (crash before DB rename / before manifest, corrupt snapshot, missing blobs, rebuild)

## Phase H — assets
- [x] Content-addressed store, dedupe, derivatives (max dim, EXIF orientation)
- [x] iOS lazy fetch + SHA-256 verification + ImageIO downsampling + bounded cache

## Phase I — iOS updater
- [x] GenerationStore, staging, validation, atomic switch, fallback
- [x] Failure tests (malformed manifest, schema, hash, truncation, oversize, missing DB, corrupt SQLite, meta mismatch, missing tables, traversal)

## Phase J — transport
- [x] LocalFolderArtifactSource (NSFileCoordinator) — used by bundled demo + Files/iCloud Drive
- [x] HTTPArtifactSource + `wikiindex serve`
- [x] End-to-end test: indexer publish → HTTP → updater → repositories (+ lazy assets, partial sync)
- [x] Delta (chunk) transport, chunks-only publication, tamper tests

## Phase K — benchmarks
- [x] Synthetic vault generator (`wikiindex synth`)
- [x] Host benchmarks 20k/50k/100k (`scripts/bench.sh`)
- [x] Viewer query benchmarks on the host (`wikiindex bench-queries`)
- [~] Viewer query benchmarks inside the iOS Simulator (opt-in test)
- [~] BENCHMARKS.md with real numbers
- [x] Performance fixes from measurements: detail=none FTS, page size 8192,
      bounded image concurrency (builder peak footprint 469→159 MiB at 20k)

## Phase L — review
- [x] Adversarial / security / concurrency / SQLite / memory reviews (4 subagents)
- [x] Fix confirmed defects (each with a regression test where practical):
      case-only rename duplicates; CRLF frontmatter & excerpt crash; YAML alias
      bomb; quadratic `[` scanning; fence in callout; setext false positives;
      block id in comment; emoji/Unicode tags; URL parentheses; unsafe link
      schemes; symlinked directory component; secure_delete; exact schema
      verification + trusted_schema=OFF; interrupted resolution; state lock;
      chunk dir fsync; orphan generation cleanup; file↔directory transitions;
      images retained off-screen; huge notes (flattened lists, split code/tables);
      hub backlinks / huge tags (keyset); separate search connection; bounded
      search candidates; autoreleasepools; update/reset/bootstrap races;
      fallback never keeps a broken generation; device asset GC; HTTP server
      deadlines; free-space check; .gitignore unignore of Features/Tags
- [x] Final fresh diff review: no blockers; fixed `&`/`=` in link URLs,
      cancellable folder reads, Mac-side exact schema check (builder rebuild +
      publish/verify refusal), schema filter, HTTP counter, `.part` cleanup
- [x] Diff audit: only local package reference + SWIFT_VERSION 6.0 changed in
      the Xcode project; no signing/bundle/team/entitlement changes
- [x] Final build/test/benchmark pass

## Phase M — sync latency and transfer size
- [x] Page packs: format, publisher (deltas + keyframe, private bases, GC),
      manifest `packs`, `verify` checks packs
- [x] Updater: delta on APFS clone with incremental chunk verification,
      keyframe + chunks for empty devices, fallback to chunks on any failure
- [x] HTTP: shared URLSession (connection reuse), server keep-alive, long poll
- [x] App: foreground watcher with backoff, no 15-minute throttle, background
      app refresh
- [x] Indexer: ignore never-indexed paths, quick quiet period for small edits
- [x] Host memory: chunk reads in `writeChunks` were retained until the end of
      publication (autoreleased buffers); keyframe reads use one pread buffer
- [x] Review fixes: pack limits can never block publication (host drops an
      invalid index, reader ignores it); cancellation reaches the update task
      and is never turned into a chunk fallback; URLSession completion before
      continuation; server sends exactly the opened file's length
- [x] Tests: PagePackTests, PackTransportTests, HTTPSyncTests,
      QuickPublicationTests (incl. an open Library following HTTP publications)
- [-] APNs push from the Mac to wake the phone on publication: needs an Apple
      Developer push key and a way to register device tokens with the Mac;
      background refresh + foreground long poll cover most of the benefit.

## Deferred (explicit)
- [-] Manifest signing (Ed25519). Hash validation is mandatory and implemented;
      signing needs key management outside the repo (THREAT_MODEL T3).
- [-] Plain-HTTP to LAN hosts from the app needs an ATS exception (Info.plist);
      not added — use HTTPS (e.g. Tailscale) or the Files/iCloud folder source.
- [-] Title-ordered backlinks/tag lists (would need precomputed ordered tables).
- [-] CJK bigram / morphological search index (SearchEngine protocol allows it).
- [-] Real-device memory measurements (procedure in BENCHMARKS.md).
- [-] Host builder peak memory grows with vault size (~1 GB footprint in the
      100k bench process); bound reconciliation/resolution caches.
- [-] Multi-term search applies extra terms after the 400-match cap (may miss
      older notes containing all terms); candidates ordered by row id.
- [-] A generation that fails to open is discarded even on transient errors.
- [-] Publish-directory lock (only the state directory is locked).
- [-] Asset downloads are not cancelled when rows scroll away (bounded to 4).
- [-] PDF/audio/video preview (metadata + placeholder today).
- [-] Unlinked mentions, graph view, Canvas, Dataview (out of scope).
