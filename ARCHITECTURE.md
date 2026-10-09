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

Editing, syncing changes back, Obsidian plugins (the Graph tab re-creates
the wiki-lens network views natively; it does not run the plugin), Dataview, Canvas, arbitrary
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
trigram index; a query made only of them is matched against titles, aliases
and tags.

Every term of a query must match, in any order, and each bound applies only
after all terms have filtered. Titles and aliases are matched exhaustively
against every term by scanning their small indexes (about 2 ms at 100k
notes), so a note whose title contains the whole query is found however
many other notes share one of its words; name matches rank above text
matches. An earlier design took title and text candidates from the longest
term alone, capped them (50 titles in title order, 400 text matches), and
only then applied the other terms, which lost such notes whenever that term
was common (e.g. "2024 振り返り" among hundreds of "2024-…" daily notes).

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
syntax inside code or comments is not misinterpreted. LaTeX math (`$…$`,
`$$…$$`) is lifted out before Markdown parsing and typeset natively with
SwiftMath. Very long lists, code
blocks and tables are split so that even a huge note is laid out lazily.

### Obsidian Bases are evaluated on the host

A `.base` file is a query over every note: filters, formulas, sorting and
grouping. Evaluating it on the phone would mean reading all notes' properties,
which is exactly what the phone must not do. So the indexer treats a `.base`
file as an attachment (links, embeds and folder listings reach it like any
other) and, before each publication, evaluates it with its own implementation
of the Bases expression language. The result is stored as rows keyed by the
base, the view, an order-preserving binary encoding of the group and sort
values, and the note; the phone pages a view along that primary key, like
every other list. Because the keys come from the note alone, a one-note edit
rewrites only that note's rows, and the rebuild writes only differences, so
delta packs stay small. Evaluating all bases takes under a second for 12k
notes (7 bases, 56k rows).

Cost: every publication re-evaluates every base (a base depends on every
note). Formulas that depend on the current time (`now()`, `today()`) are only
as fresh as the last publication.

### The link graph is analysed on the host, drawn a cluster at a time

The Graph tab reproduces the network views of the vault's wiki-lens plugin
(Backbone Graph and Local Lens) in a form suited to a phone. Clustering and
layout need the whole graph, so like link resolution they run on the Mac:
before each publication the indexer finds Leiden communities among the notes
in scope, lays out each cluster with ForceAtlas2 (Barnes-Hut above a few
hundred notes), lays out the largest clusters as non-overlapping bubbles for
the overview, and stores the result in the `graph_*` tables. The phone reads
at most 60 clusters for the overview, at most 400 notes (the most linked) of
one cluster, and a few dozen notes for a note's local graph, which it ranks
from the link rows in about a dozen bounded queries.

Clusters should be topics. Plain modularity merged unrelated topics in a
vault of 18k notes (blockchain, trusted computing and SDN in one cluster of
1,000 notes), so the clustering uses modularity at resolution 2.5
(`--graph-resolution`), about 80 clusters of at most ~700 notes there.

The map must not reshuffle with every edit, and a one-note edit must not
rewrite thousands of rows (every delta pack would grow). Starting from the
previous clusters is not the way to get there: Louvain started that way
never splits a cluster, so clusters only grow with the vault (which is how
the 1,000-note clusters came about), and Leiden started that way moves
hundreds of notes between near-equal partitions on every run. Instead the
objective itself rewards staying put: each previous cluster gets an anchor
node linked to its former members with weight 0.05 × their degree (temporal
coupling as in multislice modularity), and Leiden runs on that graph until a
run changes nothing. On the author's vault, adding 30 notes then moves about
10 others, and after the vault grows fivefold the clusters are as fine as
clusters computed afresh. Clusters made another way (by an older version or
at another resolution) are not followed; the next refresh starts afresh.
Clusters keep their id (and colour) by overlap
with the previous ones, a cluster whose members and inner links are unchanged
keeps its layout exactly, a changed one starts from its previous layout, and
only rows that differ are written. Nothing is recomputed when the notes and
links in scope are unchanged.

On the phone, touch replaces hover: a tap selects a node, brings out its links
and neighbours and opens a card with the next steps (open the note, its local
graph, a neighbour, the cluster). A list replaces the map for browsing and for
VoiceOver. `--graph-include` / `--graph-exclude` choose which notes the graph
covers, typically leaving out index and log notes that link to everything.
Cost: the graph is as fresh as the last publication, and the phone sees one
cluster at a time rather than all notes at once.

### Requests: the one way back, outside the vault

A viewer that only reads cannot ask. With Claude writing much of the vault,
the reader wants to ask *while* reading ("is this true?", "what does this
assume?") and keep the answer as a note with its sources, not as a chat.
The design keeps every earlier guarantee:

- the app never writes to the vault: it queues a small JSON request on the
  device and sends it to an inbox *outside* the vault — over HTTP to
  `wikiindex serve` (token-checked), or as a file in the synced folder it
  already reads (`<publish>/inbox/`);
- `wikiindex requests` takes requests one at a time and hands each to a
  *runner*, which starts Claude Code in the vault with tools confined to
  `wiki/`; wikiindex itself still never writes to the vault;
- the answer is an ordinary note, so it reaches the phone with the next
  snapshot (delta pack), linked to the note it is about by the vault's own
  skills (`wiki-ask-source`, `wiki-thesis`, `wiki-query`);
- progress travels back the same way as snapshots: the worker writes
  `<publish>/requests/<id>.json`, which the app polls along with the
  manifest. Offline, requests wait on the device and are sent later.

The same queue carries other kinds of request. A *learning path* (#35)
asks Claude to order the notes the vault has on a subject; the answer is a
note with `type: path` whose top-level numbered list is the path (a step's
note is the first resolved link on its line; a step without one marks
missing material). The app shows it as steps and keeps the reader's
progress on the device: which steps were read is the reader's, not the
vault's.

The reader can also run one of the vault's own agent skills (Run Skill).
The app cannot see the vault's `.claude/skills` or `.agents/skills`, so the
request worker publishes what it offers as `<publish>/requests/skills.json`
(name, description, argument hint) next to the status files, and the app
reads it through the same transport. A `skill` request names one entry;
the worker checks it against the catalog again before running, and passes
the runner where the skill is, since a skill only in `.agents/skills` is
not one Claude Code loads by name, and whether it may use the web. Asking
stays off the web, so vault text cannot leave the Mac through a question;
skills that only work on the web (ingesting a URL, research) get it when
the Mac says so, which the catalog shows the reader.

Cost: a second Mac process, and answers are as fast as Claude plus one
publication. The vault's rule that `wiki/` is Claude's and the primary
layer the human's is enforced by the runner's allow-list, not by WikiViewer.

### What changed, recorded on the host (schema 4)

When Claude updates the vault overnight, the reader wants to read what
happened, not hunt for it. The phone cannot compare two generations (that
would read every note), so the indexer records it as it goes: every note
written or deleted is noted in a builder-only table, and before a
publication those notes become `change_log` rows of that generation (path,
kind, title, frontmatter type, author by `Provenance`), with the
generation's time and counts in `generation_log`. New entries of the
vault's operation log (`wiki/log.md`, `--log-note`) are stored with the
generation they first appear in, together with the pages they link to.

"Since you last looked" differs per device, so the host does not decide
it: each device remembers the generation it was showing when it was last
put away and reads the rows after it (or after the last generation before
a date), along the primary keys. The first publication of a builder only
sets the baseline — indexing a whole vault is not news — and rows older
than 30 days, or beyond 2,000 notes per generation, are not kept.

Who made a change is approximated by who wrote the note: an explicit
`author_kind`, a wiki `address`, or the `wiki/` folder mean Claude;
anything else the reader. The indexer reads only the vault, so an edit
the reader made to a wiki page in Obsidian still counts as Claude's.

### Provenance from the note itself

With notes by the reader and by Claude side by side, a note shows who
wrote it, how far it has been checked, how fresh it is and what it rests
on, so the reader knows how much to trust it. The indexer reads only the
vault, so all of it comes from the note: the author by the rule in
`Provenance` (explicit `author_kind`, a wiki `address`, the `wiki/`
folder); checked when the wiki tooling says so (`judged` on a thesis,
`recompiled` on a concept, or `verified`/`reviewed`), otherwise
"unverified" for Claude's notes; fresh by `updated` or the file time;
resting on its `sources`. A source page's originals live under `.raw/`,
a hidden folder that is never published, so the app names them and links
the original online (`url`, `doi`, `arxiv_id`) instead; `publish: false`
marks an original not to share. A thesis page (wiki-thesis) gets its
verdict, confidence and the way to its evidence table at the top.

### Host-made extras beside the notes (schema 5)

Some of what the reader wants next to a note is computed by the vault's
own tools, not written in it: wiki-related's neighbours by role (what a
page builds on, its evidence, what contradicts it, its peers). Those tools
are Python and need the vault's whole graph, so they run on the Mac and
leave their results in one directory outside the vault (`--extras`). The
indexer imports each file before a publication into a bounded table
(at most 12 neighbours per note), writing only rows that differ, and
`watch` publishes when a file changes. `scripts/export-related.py` runs
wiki-related for every wiki page (about 18,000 in 85 s) without writing
into the vault. A missing file simply empties its table.

The same way, the graph becomes a lens on questions (schema 6). The
indexer exports its clusters (id, label, most linked notes) to
`<state>/graph-clusters.json`; `scripts/export-graph-lens.py` collects
each cluster's open questions from its concept pages' `## 未解決の問い`
and, optionally, asks Claude (read-only tools) for a short summary of new
or changed clusters only, and turns the vault's wiki-gap reports into gap
candidates. Summaries are stored outside the vault, keyed by the
indexer's cluster ids — the vault's own rule keeps cluster ids out of wiki
pages — and marked stale when the cluster's members move on. Gaps are
resolved to notes and clusters on the host and drawn as dashed links.

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

- The vault is never written to by the app or the indexer. (Claude Code,
  started by the request runner, writes only under `wiki/`.)
- A published manifest never refers to an incomplete or unverified database.
- A generation, once published or installed, is never modified.
- The phone never opens a database that has not passed verification.
- A failed or interrupted update leaves the previous generation usable.
- Generation numbers never go backwards, even if the builder is rebuilt.
- Derived state (builder database, published artifacts, on-device
  generations) can be deleted and rebuilt from the vault.
- No screen loads a number of rows proportional to the size of the vault
  (the graph included: it is clustered and laid out on the host).

## Compatibility with Obsidian

Supported: wikilinks with paths, labels, headings and block references;
embeds of images, notes and note sections; Markdown links to notes and
attachments; YAML frontmatter (shown as properties; wikilinks in string
values such as `up: "[[Home]]"` are links and count as backlinks), aliases,
frontmatter and inline tags (including nested tags); headings and callouts; unresolved links;
inline and display LaTeX math; Obsidian Bases (`.base` files: filters,
formulas, property display names, sorting, grouping and several views).
The reference is Obsidian's public documentation; no Obsidian code is used.

## Known limitations of the initial implementation

- When several notes share a name, the link target is chosen by a
  deterministic rule (closest folder, then shortest path) that approximates
  Obsidian, whose exact rule is not documented.
- Search folds case for ASCII only. When the words of a query occur in the
  text of very many notes, only the most recent of those are checked for
  text matches (titles and aliases are always checked in full).
- Backlinks and tag lists are ordered by recency, not by title.
- Remote images in notes are shown as links and not fetched (privacy, memory).
- PDF, audio and video have no preview yet, and the originals a source
  page cites (`.raw/`) are not published: the app shows their names and
  their addresses online, not the page a claim comes from.
- Math is typeset by SwiftMath, which covers common LaTeX math but not all
  of MathJax; a formula it cannot parse is shown as its source.
- "What changed" attributes a change to the note's author, not to whoever
  edited it last, and keeps 30 days.
- Bases: views are shown as lists (table, cards and list views alike, one row
  per note with its columns as label–value pairs); summaries, `this`,
  `file.ctime`, embedded bases' own rendering and ```` ```base ```` code blocks
  are not supported. Functions the indexer does not implement evaluate to
  empty and are listed at the top of the base. The file-name column shows the
  file name, as Obsidian does. Folder rows count bases as attachments.
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
| SwiftMath (with its bundled OpenType math fonts) | MIT / OFL, GUST | Native LaTeX math typesetting, app only |

SQLite itself is the system library on both macOS and iOS.
