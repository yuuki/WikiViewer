# WikiViewer benchmarks

All numbers below were measured by the commands shown; nothing is estimated
unless marked. Synthetic vaults are generated on demand (never committed)
with a fixed seed.

- Machine: Apple M6 Mac (macOS 27.0), Xcode 27.0, Swift 6.4, SQLite 3.54
  (system). iOS Simulator: iPhone 17, iOS 27.0.
- Date: 2026-09-25.

## How to reproduce

```sh
# Host: generate 20k/50k/100k synthetic vaults, index, publish, edit, and
# run the viewer's query layer against the published database.
scripts/bench.sh 20000 50000 100000        # → bench-work/results-<N>.md

# Individual pieces
Indexer/.build/release/wikiindex synth --out bench-work/vault-20000 --notes 20000 --seed 42
Indexer/.build/release/wikiindex bench --vault bench-work/vault-20000 --work bench-work/work-20000 --updates 1000
Indexer/.build/release/wikiindex bench-queries --db bench-work/work-20000/publish/generations/viewer-000004.sqlite

# iOS Simulator: same query benchmark inside the simulator process
TEST_RUNNER_WIKIVIEWER_BENCH_DB=$PWD/bench-work/work-100000/publish/generations/viewer-000004.sqlite \
  xcodebuild test -scheme WikiKit-Package -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:WikiViewerKitTests/BenchmarkTests/queryBenchmark
```

Synthetic vault parameters (defaults of `wikiindex synth`): ~2 KB average
note, 6 links per note (3% unresolved, some path-qualified, heading, display
text and Markdown links), 400 folders (2 levels, some Japanese names), 500
tags, 50% Japanese paragraphs, frontmatter on 75% of notes, 1% duplicate
basenames, images embedded in 2% of notes (2400×1600 JPEGs, 20% byte-identical).

`wikiindex bench` measures, in one process: initial reconciliation+index,
initial publication, a no-op reconciliation, a single-note edit (process +
publish), a 1000-note burst (process + publish), 100 edits made without
telling the indexer followed by reconciliation (lost watcher events), and a
new note that resolves previously dangling links.

## Results (final code, 2026-09-25)

### Host indexer / publisher (`wikiindex bench`, release build)

| metric | 20k | 50k | 100k |
|---|---:|---:|---:|
| notes / image assets | 19,999 / 320 | 49,998 / 800 | 99,997 / 1,600 |
| links (unresolved) | 121,495 (4,862) | 302,089 (10,182) | 603,083 (19,322) |
| raw Markdown body text | 38.8 MiB | 96.8 MiB | 193.6 MiB |
| initial index (full reconcile) | 15.1 s | 37.4 s | 82.8 s |
| initial publication (backup, checks, chunking, SHA-256) | 4.3 s | 9.9 s | 18.3 s |
| no-op reconciliation (metadata walk) | 0.10 s | 0.23 s | 0.49 s |
| single-note update: process | 0.001 s | 0.001 s | 0.001 s |
| single-note update: publish | 0.58 s | 1.18 s | 2.08 s |
| 1000-note burst: process | 0.58 s | 0.71 s | 0.73 s |
| 1000-note burst: publish | 2.87 s | 4.69 s | 8.12 s |
| reconcile after 100 edits without events | 0.23 s | 0.33 s | 0.55 s |
| new note resolving dangling links | 0.001 s (5 links) | 0.001 s (6) | 0.001 s (9) |
| delta after single update (new 128 KiB chunks) | 27 / 756 | 30 / 1,863 | 41 / 3,711 |
| delta after 1000-note burst | 386 / 756 | 799 / 1,863 | 1,225 / 3,711 |
| viewer.sqlite | 94.4 MiB | 232.8 MiB | 463.9 MiB |
| — FTS5 trigram index (detail=none) | 16.7 MiB | 38.1 MiB | 73.2 MiB |
| — notes table | 51.1 MiB | 127.1 MiB | 253.9 MiB |
| builder.sqlite | 96.3 MiB | 233.1 MiB | 464.9 MiB |
| asset store (derivatives ≤ 2048 px) | 20.6 MiB | 51.1 MiB | 102.1 MiB |
| bench process peak memory footprint | 295 MiB | 615 MiB | 992 MiB |

Notes:
- A one-note edit publishes ~3.4–5 MiB of new chunks instead of the whole
  database (≈1% of 464 MiB at 100k).
- Host peak memory still grows with vault size (the bench process also holds
  reconciliation state, link-resolution caches and SQLite page cache for
  several publications). It is host-only and well within a Mac mini's RAM, but
  is listed as a remaining optimization.

### Update transfer: chunks vs. page packs (2026-09-27)

Same machine and command (`scripts/bench.sh 20000 100000`), after page packs
were added. "Files" is what a phone fetches per update: each is one iCloud
Drive item or one HTTP request.

| update | 20k: chunks | 20k: packs | 100k: chunks | 100k: packs |
|---|---:|---:|---:|---:|
| single-note edit | 30 files, 3.8 MiB | **1 file, 39.6 KiB** | 38 files, 4.8 MiB | **1 file, 172.9 KiB** |
| 1000-note burst | 396 files, 49.5 MiB | **2 files, 4.4 MiB** | 1,225 files, 153 MiB | **4 files, 4.3 MiB** |
| first install (nothing on the device) | 755 files, 94.3 MiB | **12 files, 26.8 MiB** (keyframe) | 3,707 files, 463 MiB | **58 files, 134.8 MiB** (keyframe) |

A pack is split into parts of at most 8 MiB before compression, which bounds
the memory needed to decode one. The chunk list (one small file) is fetched in
every case. A keyframe is republished only when more than 20% of the current
chunks are missing from it; until then a new device also fetches the chunks
that changed since.

On the phone a delta is written onto an APFS clone of the installed
generation and only the chunks it touched are hashed, instead of rewriting
and re-hashing the whole database (`quick_check` still reads it).

Publisher cost of packs:

| metric | 20k | 100k |
|---|---:|---:|
| initial publication (incl. keyframe) | 4.7 s | 14.1 s |
| single-note update: publish (3 deltas) | 0.59 s | 2.09 s |
| 1000-note burst: publish (3 deltas) | 2.66 s | 11.9 s |
| bench process peak memory footprint | 296 MiB | 531 MiB |

The 100k footprint fell from 992 MiB: publication used to keep every chunk it
read alive until it finished (autoreleased buffers, 108 MiB at 20k); reads are
now released per chunk. Private copies of the last three databases for
computing deltas take up to 3× the database size in the state directory.

Update latency is dominated by waiting, not by transfer; it has not been
measured end to end on a device. The mechanisms (see ARCHITECTURE.md): a
small edit is published 3 s after the vault is quiet (was 20 s, and Obsidian's
own `.obsidian/` writes reset the timer); an open app learns of a publication
over HTTP within about a second (long poll; test: under 5 s from publication
to the new generation being open, on localhost) or by polling a folder every
30 s; failed updates are retried with backoff. On the iPhone this holds for a
few minutes after opening or after an update; later checks come every
2–5 minutes, to save power.

### Effect of measured optimizations (20k notes)

| change | before | after |
|---|---:|---:|
| FTS5 `detail=full` → `detail=none` (index size) | 109.5 MiB | 16.8 MiB |
| common-term FTS query (`ORDER BY rank` vs bounded LIKE) | 60 ms | 0.5 ms (CLI) |
| page size 4096 → 8192 (`notes` table) | 63.2 MiB | 51.1 MiB |
| viewer.sqlite total | 199.5 MiB | 94.4 MiB |
| image decode concurrency 10 → 2 (builder peak footprint, `build` only) | 469 MiB | 159 MiB |

### Viewer queries — macOS host (`wikiindex bench-queries`, 30 iterations, warm)

Median / p95 in ms.

| query | 20k | 50k | 100k |
|---|---:|---:|---:|
| cold open (ms) | 1.50 | 1.07 | 1.00 |
| root folder: subfolders | 0.05 / 0.05 | 0.04 / 0.04 | 0.03 / 0.04 |
| largest folder: first 200 notes | 0.05 / 0.09 | 0.07 / 0.12 | 0.07 / 0.09 |
| largest folder: keyset page 2 | 0.06 / 0.07 | 0.07 / 0.07 | 0.07 / 0.16 |
| quick switcher prefix | 0.03 / 0.04 | 0.03 / 0.04 | 0.04 / 0.05 |
| quick switcher infix | 0.16 / 0.24 | 0.18 / 0.19 | 0.22 / 0.27 |
| FTS common English | 3.38 / 4.12 | 3.48 / 4.05 | 3.43 / 4.33 |
| FTS Japanese `全文検索` | 4.04 / 4.87 | 4.81 / 4.96 | 5.97 / 6.43 |
| FTS two terms | 4.73 / 4.99 | 5.15 / 5.36 | 4.91 / 5.15 |
| FTS rare phrase | 6.06 / 6.66 | 7.60 / 10.13 | 9.63 / 10.37 |
| FTS no match | 0.70 / 0.85 | 1.65 / 1.81 | 3.25 / 3.51 |
| short query fallback `東京` | 0.65 / 0.84 | 1.58 / 1.70 | 3.03 / 3.18 |
| backlinks, most-linked note | 0.05 / 0.06 | 0.05 / 0.06 | 0.06 / 0.07 |
| note fetch (body + links + tags) | 0.08 / 0.13 | 0.08 / 0.11 | 0.08 / 0.10 |
| note fetch + render | 0.26 / 0.41 | 0.26 / 0.32 | 0.27 / 0.36 |
| tags top 200 | 0.13 / 0.14 | 0.13 / 0.15 | 0.12 / 0.13 |

Search now matches every query term against all titles and aliases before
any bound applies (see ARCHITECTURE.md), which adds a scan of the title and
alias indexes to each search. Measured at 100k notes on the host (median ms,
before → after): quick switcher prefix 0.03 → 0.51, infix 0.17 → 1.99;
FTS common English 3.28 → 3.30, Japanese 6.69 → 5.61, two terms 5.05 → 8.53,
rare phrase 9.17 → 13.31, no match 3.24 → 3.55; short query fallback
2.93 → 3.75. The tables above predate this change.

### Viewer queries — iOS Simulator (iPhone 17, iOS 27.0, on the M6 host)

Same `QueryBenchmark` code in the simulator test process. **Simulator, not a
real device**: CPU and I/O are the Mac's; memory numbers are the simulator
process's `phys_footprint`, indicative only.

| query (median / p95 ms) | 20k | 100k |
|---|---:|---:|
| cold open (ms) | 3.10 | 7.06 |
| root folder: subfolders | 0.11 / 0.14 | 0.11 / 0.13 |
| largest folder: first 200 notes | 0.08 / 0.09 | 0.16 / 0.18 |
| largest folder: keyset page 2 | 0.14 / 0.16 | 0.17 / 0.19 |
| quick switcher prefix | 0.09 / 0.10 | 0.09 / 0.09 |
| quick switcher infix | 0.29 / 0.30 | 0.30 / 0.33 |
| FTS common English | 6.50 / 6.78 | 6.64 / 6.98 |
| FTS Japanese `全文検索` | 7.41 / 7.81 | 9.33 / 9.45 |
| FTS two terms | 10.05 / 12.01 | 10.12 / 10.31 |
| FTS rare phrase | 12.98 / 13.22 | 16.15 / 19.06 |
| FTS no match | 0.78 / 0.84 | 3.27 / 3.41 |
| short query fallback `東京` | 0.84 / 0.87 | 3.08 / 3.24 |
| backlinks, most-linked note | 0.13 / 0.15 | 0.13 / 0.14 |
| note fetch (body + links + tags) | 0.50 / 0.59 | 0.20 / 0.22 |
| note fetch + render | 0.55 / 0.67 | 0.57 / 0.71 |
| tags top 200 | 0.33 / 0.36 | 0.32 / 0.34 |
| phys_footprint after open / after run | 24.7 / 24.9 MiB | 24.8 / 25.1 MiB |

The test process footprint is the same for 20k and 100k notes: memory does
not scale with vault size. All bounded queries stay well under 20 ms at 100k.
The only queries that grow with vault size are the short-query fallback
(title-index scan) and no-match FTS (trigram doclist intersection), both still
≈3 ms at 100k.


## Real iPhone: manual measurement procedure

These need a physical device and were **not** measured here.

1. Build and run the `WikiViewer` scheme on the device from Xcode (Debug is
   fine; Release for final numbers). Publish a 100k synthetic artifact on the
   Mac (`scripts/bench.sh 100000`), then serve it:
   `Indexer/.build/release/wikiindex serve --publish bench-work/work-100000/publish --bind 0.0.0.0 --port 8080`
   behind HTTPS (e.g. `tailscale serve`), or copy the publish directory into
   an iCloud Drive folder and choose it in Settings → Update Source →
   Choose Folder.
2. **Launch RSS**: kill the app, relaunch, open Xcode's Debug navigator →
   Memory; record the value after the Files tab appears. Settings →
   Diagnostics → Memory footprint shows the same `phys_footprint` number.
3. **Steady RSS**: browse ~20 folders and ~30 notes (including a long note
   and one with several embeds), return to the root, wait 10 s, record.
4. **Search RSS**: run 10 searches (English, Japanese ≥3 chars, 2-char
   Japanese, multi-term), record the peak and the value 10 s later.
5. **Large-image peak**: open a note embedding a 6000×4000 JPEG and one with
   ~20 images; record the peak in the memory gauge (Instruments → Allocations
   / VM Tracker for detail).
6. **Generation switch**: with the app open on a note, publish a new
   generation on the Mac (edit one note), pull to Settings → Check for
   Updates; confirm the note stays open and reloads, the status shows the new
   generation, and memory returns to the steady value. Repeat while
   airplane-mode is toggled mid-download to confirm the old generation stays.
7. Instruments → Time Profiler for cold launch (`Time to first frame`).

Targets: steady state ~100–200 MB, no growth proportional to vault size,
indexed queries within tens of milliseconds when warm.
