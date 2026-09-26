# WikiViewer — design of the initial implementation

This document explains **what** WikiViewer is made of and **why** it is built
this way. It deliberately leaves out how individual pieces work; that is what
the code (and its comments and tests) is for. Measurements are in
[BENCHMARKS.md](BENCHMARKS.md), security reasoning in
[THREAT_MODEL.md](THREAT_MODEL.md), open work in [TASKS.md](TASKS.md).

## The problem

The vault has more than 20,000 files and is expected to grow to 50,000–100,000
notes. Obsidian Mobile cannot handle it on iOS: its WebKit content process
grows to 1.5–2.4 GiB and is killed by Jetsam. The cause is structural — the
app loads and indexes the whole vault in memory on the device.

Editing still happens in Obsidian Desktop on a Mac mini, with Obsidian Sync as
the source of truth. On the iPhone, the need is to **read**: browse, open,
follow links, see backlinks and search, quickly and offline.

## Goals

- Memory on the phone depends on what is on screen, not on vault size.
- Nothing at startup or during ordinary navigation is proportional to the
  number of notes.
- Interactive queries answer in tens of milliseconds at 100k notes.
- Obsidian stays the only editor and the only owner of the vault; the vault is
  never written to.
- The phone always has a complete, consistent snapshot to show, including
  offline and during or after a failed update.
- Japanese is a first-class language for search.

## Non-goals

Editing, syncing changes back, Obsidian plugins, Dataview, Canvas, arbitrary
JavaScript, and exact reproduction of Obsidian's rendering. PDF, audio and
video are recognized but not yet previewed.

## Approach in one paragraph

All expensive work happens once, on the Mac: a host-side **indexer** reads the
vault, parses it, resolves every link and builds a fully indexed SQLite
database. That database is published as an **immutable snapshot** (a
"generation") together with a manifest and content-addressed images. The iOS
app downloads a generation, verifies it, and then only ever **queries** it —
each screen is a small, bounded, indexed query. The phone never parses the
vault, never builds a graph of notes, and never holds more than the note it is
showing.

```
Obsidian Desktop ⇄ Obsidian Sync ⇄ vault on the Mac mini   (source of truth)
                                     │ read only
                                     ▼
                          indexer  →  builder database (mutable, disposable)
                                     │ publish
                                     ▼
     manifest + immutable database generations (chunks, delta packs) + images
                                     │ iCloud Drive folder (polled), or HTTPS (long poll)
                                     ▼
     iOS app: patch/assemble → verify → install → switch atomically → query read-only
```

## Components and their responsibilities

**Indexer (`Indexer/`, macOS).** Keeps a derived model of the vault current
and publishes it. It notices changes cheaply, re-reads only what changed,
tolerates files that Obsidian is writing at the same moment, and decides when
a batch of changes is complete enough to publish. It owns every decision that
needs a global view of the vault — above all link resolution.

**Builder database.** The indexer's private, mutable working state. It is
*derived*: deleting it only costs a re-index. It is never read by the phone.

**Published artifacts.** A directory the phone can read through any file or
HTTP transport: a manifest (the pointer to the current generation), immutable
database generations, the chunks they are made of, page-level packs (deltas
between generations and an occasional compressed keyframe), and
content-addressed image blobs shared by all generations.

**Shared code (`WikiKit/WikiShared`).** The pieces both sides must agree on
exactly: the Obsidian syntax scanner, the database schema, the manifest and
chunk-list formats. Sharing the scanner is what lets the phone map each link
it renders to the link row the indexer resolved.

**Viewer data layer (`WikiKit/WikiViewerKit`).** Everything the app does
below the UI: opening a generation read-only, the queries behind each screen,
search, rendering one note, fetching images, and installing and switching
generations.

**iOS app (`WikiViewer/`).** Native SwiftUI screens on top of that layer.

## Key decisions

Each decision lists why it was made and what was given up.

### Precompute on the host; the phone only queries

The phone's memory problem cannot be solved by optimizing the same work on
the phone; the work has to move. The Mac has the file system, the CPU and no
memory pressure. Cost: the phone shows a snapshot that is as fresh as the last
publication (seconds to minutes behind Obsidian), and it depends on the Mac
being on.

### The file system is the only interface to Obsidian

The indexer reads the vault as Obsidian Desktop leaves it on disk. It does not
use Obsidian's internal caches, plugin APIs or the Sync protocol, and it does
not run Obsidian Headless Sync. Those are undocumented or would introduce a
second sync client for the same vault. Cost: Obsidian's own interpretation
(for example which of two notes with the same name a link means) has to be
re-derived; where Obsidian's behaviour is not documented, the indexer follows
a documented, deterministic rule of its own (see Known limitations).

### Never write to the vault

A viewer must never be able to damage the source of truth. The indexer opens
vault files read-only, never follows symbolic links out of the vault, and
refuses any configuration in which its own output would land inside the vault.
This is also tested: indexing and publishing leave every fixture file
byte-for-byte and timestamp-for-timestamp unchanged.

### Mutable builder, immutable generations

A database that the phone is reading must never change underneath it, and a
failed update must never leave the phone with nothing. So the builder keeps
changing, but what is published is a separate, finished file that never
changes again. Consequences that follow directly:

- the phone can open a generation with SQLite's "immutable" semantics — no
  locking, no change detection;
- a publication becomes visible only when the manifest is replaced, which is
  the last step; any earlier failure leaves the previous generation current;
- the phone keeps the current and the previous generation, so it can always
  fall back.

Cost: every publication copies the database, and the phone stores two
generations.

### Incremental indexing, with correctness not depending on the watcher

File-system events are fast but can be dropped or coalesced, especially
during a large Sync burst. The watcher is therefore only a fast path; a
periodic comparison of file metadata (size and modification time) is the
correctness path. Because that comparison reads metadata only, it stays cheap
at 100k files (≈0.5 s). A file is re-parsed only if it actually changed.

Obsidian may be writing a file while it is read, so a read is accepted only
if the file did not change during the read; otherwise it is retried later.

Publication waits for a quiet period so that a large Sync batch is not
published half-way, but never longer than a maximum delay, so continuous
activity cannot postpone updates forever.

### Resolve links once, on the host

Resolving `[[Note]]` requires knowing every note name in the vault — exactly
the global view the phone must not build. The indexer stores each link
already resolved to a note, an attachment, or explicitly *unresolved*.
Unresolved links are kept (not dropped), so when a matching note appears later
only the affected links are re-resolved, without re-parsing their source notes.
Backlinks are not stored separately; they are the same link rows, looked up
from the other side.

### SQLite as the phone's only data model

SQLite gives indexed, bounded queries over data far larger than memory, and it
is available on both sides. The app uses no second persistence layer (no Core
Data or SwiftData) and no in-memory model of the vault; every list is a
limited query, and pagination follows index order so that the cost of a page
does not depend on how many rows exist. For very large collections — a hub
note with tens of thousands of backlinks, a tag on tens of thousands of notes
— this means lists are ordered by recency rather than by title.

### Full-text search with a trigram index

Japanese has no spaces, and a morphological dictionary would be large and add
complexity. SQLite's trigram tokenizer gives substring search in any
language with no dictionary. The index stores only *which* notes contain each
trigram (not positions): measured, this made the index about six times
smaller (17 vs 110 MiB at 20k notes) and common queries faster. The exact
match is then verified on a bounded set of candidates, so no query reads an
unbounded amount of text. Terms shorter than three characters cannot use a
trigram index; they are matched against titles, aliases and tags only.

The UI talks to a search interface, not to this implementation, so a
better Japanese tokenizer or a bigram index can replace it later.

### Images: content-addressed, downsized, fetched lazily

Shipping the vault's original attachments would recreate the vault on the
phone. Instead, each image is published once per distinct content, downsized
to a viewer resolution (2048 px by default), and shared across generations.
The phone fetches an image only when it is displayed and decodes it at display
size, so a very large photo never becomes a very large bitmap in memory.

### Delta transport by content-addressed chunks

At 100k notes a generation is ~460 MB. Downloading — or, with iCloud Drive,
uploading from the Mac — the whole file for every edit would be impractical.
Each generation is therefore also published as fixed-size chunks named by
their hash. A phone that already has a generation reuses every chunk it has
and fetches only the rest; after a one-note edit that is about 1% of the file.
The whole reassembled file is still verified against the manifest. For an
iCloud Drive transport the whole file need not be published at all.

### Page-level delta packs on top of chunks

Chunks are the unit of storage and verification, but not a good unit of
transfer. An edit dirties individual 8 KiB SQLite pages scattered through the
file: measured at 20k notes, a one-note edit changes 31 pages (248 KiB) yet
26 chunks (3.3 MiB), and every chunk is a separate file — one iCloud Drive
item or one HTTP round trip each, which dominates small transfers.

So every publication also writes, for each of the last three generations, a
*delta pack*: only the pages that changed, XORed against the old page (so
unchanged bytes become zeros) and LZFSE-compressed, in a single file (about
40 KiB for that edit; large deltas are split into 8 MiB parts). A phone that has one of those generations installed
clones it (APFS copy-on-write: no copy, no extra space for unchanged pages),
writes the changed pages, and verifies only the chunks the pack touched —
the others are byte-for-byte the verified base. A phone with nothing
installed downloads a *keyframe*, the whole database compressed (about 3.5×
smaller), plus the chunks that changed since it; the keyframe is republished
only when more than 20% of the current chunks are missing from it, so
iCloud Drive does not re-upload the database for every edit. When no pack
applies, or a pack fails in any way, the phone falls back to chunks.

Packs are only a way to move bytes: whatever path assembled the file, it
must match the manifest's chunk list (or whole-file SHA-256) before SQLite
even opens it. Cost: the Mac keeps private copies of the last three
databases (to diff against) and computes a delta per base — proportional to
the change, since only chunks whose digests differ are compared.

### Following the source instead of polling rarely

What makes an update feel slow is mostly waiting, not transfer: the phone
used to check only when the app came to the foreground (at most every
15 minutes), and the Mac waited for 20 s of quiet — which Obsidian's own
writes to `.obsidian/` kept resetting. Now:

- the indexer ignores events for paths it never indexes, and publishes a
  small edit after 3 s of quiet (a burst or a reconciliation still waits
  20 s, so an Obsidian Sync batch is not published half-way);
- the open app follows the source: over HTTP it keeps a long-poll request
  open that `wikiindex serve` answers the moment a generation is published;
  a folder (iCloud Drive) or a plain static server is polled every 20–30 s;
- a failed update — typically iCloud having delivered the manifest before the
  files it names — is retried with backoff rather than on the next launch;
- iOS background app refresh fetches updates while the app is closed, which
  small deltas make feasible within the time iOS allows.

Cost: more publications (each a few hundred KiB with packs) and a request
held open while the app is in the foreground. iCloud Drive's own propagation
delay remains outside the app's control; HTTP over a private network is the
low-latency transport.

### Transport is replaceable; it is never runtime storage

The update logic is written against a small "artifact source" abstraction.
Two sources exist: a folder chosen in the Files app (which covers an iCloud
Drive folder the Mac publishes into, without any iCloud entitlement), and
HTTPS. Whatever the transport, files are copied into the app's own storage,
verified, and only then used; the app never opens a database that sits in a
synced or downloaded location.

### Treat every downloaded artifact as untrusted

A synced folder can be partially synced, a network can truncate, and a file
can be corrupt while still having the size it claims. Before a generation is
used, the phone checks its size, its SHA-256, SQLite's own integrity check,
the schema version, and that the schema is exactly the one this build of the
app expects. Failure at any step leaves the current generation untouched.

### Render one note at a time, natively

Rendering happens only for the note on screen, off the main thread, into
native SwiftUI views; there is no web view. Obsidian-specific syntax
(wikilinks, embeds, tags, block IDs, callouts) is turned into explicit
elements using the shared scanner rather than by text substitution, so
syntax inside code or comments is not misinterpreted. Very long lists, code
blocks and tables are split so that even a huge note is laid out lazily.

### Swift for the indexer

The brief preferred Rust for the host side. Swift was chosen because the
repository was Swift-only, no Rust toolchain was installed, and — decisively —
the indexer and the app can then share the same scanner, schema and manifest
code, which removes a whole class of "the two sides parse differently" bugs.
macOS file events, image processing and hashing are available first-party.

### A small demo snapshot ships with the app

On first launch the app installs a snapshot built from the repository's test
vault, through the same verified update path as real snapshots. The app is
therefore usable and testable before any source is configured, and the
install path is exercised on every fresh install.

## Guarantees (invariants)

- The vault is never written to by any part of the system.
- A published manifest never refers to an incomplete or unverified database.
- A generation, once published or installed, is never modified.
- The phone never opens a database that has not passed verification.
- A failed or interrupted update leaves the previous generation usable.
- Generation numbers never go backwards, even if the builder is rebuilt.
- Derived state (builder database, published artifacts, on-device
  generations) can be deleted and rebuilt from the vault.
- No screen loads a number of rows proportional to the size of the vault.

## Compatibility with Obsidian

Supported: wikilinks with paths, labels, headings and block references;
embeds of images, notes and note sections; Markdown links to notes and
attachments; YAML frontmatter (shown as properties), aliases, frontmatter and
inline tags (including nested tags); headings and callouts; unresolved links.
The reference is Obsidian's public documentation; no Obsidian code is used.

## Known limitations of the initial implementation

- When several notes share a name, the link target is chosen by a
  deterministic rule (closest folder, then shortest path) that approximates
  Obsidian, whose exact rule is not documented.
- Search folds case for ASCII only; for extremely common words only the most
  recent candidates are considered; multi-word queries can miss older notes.
- Backlinks and tag lists are ordered by recency, not by title.
- Remote images in notes are shown as links and not fetched (privacy, memory).
- PDF, audio and video have no preview yet.
- The manifest is hashed but not signed; see THREAT_MODEL.md.
- The indexer's own memory grows with vault size; it runs on the Mac, where
  this is acceptable for now (numbers in BENCHMARKS.md).
- Real-device memory has not been measured yet; the procedure is in
  BENCHMARKS.md.
- The indexer should run in the logged-in user's session (next to Obsidian);
  image processing can stall without access to the window server.

## Dependencies

| Package | License | Why |
|---|---|---|
| GRDB.swift | MIT | SQLite access on both sides; already used by the project |
| swift-markdown (with swift-cmark) | Apache-2.0 / BSD-2-Clause | CommonMark/GFM parsing for native rendering, maintained by Apple |
| Yams (with libyaml) | MIT | YAML frontmatter, indexer only |

SQLite itself is the system library on both macOS and iOS.
