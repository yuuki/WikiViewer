# WikiViewer

A fast, native, read-only iOS viewer for a very large Obsidian vault.

**Why.** With a vault of 20k+ notes (heading for 100k), Obsidian Mobile's web
view grows past 1.5–2.4 GiB and is killed by iOS. The phone does not need to
edit; it needs to read quickly and offline.

**What.** Obsidian Desktop and Obsidian Sync on a Mac mini remain the source
of truth. A host-side indexer (`wikiindex`) reads the vault without ever
writing to it, and publishes immutable, fully indexed SQLite snapshots. The
iPhone app downloads a snapshot, verifies it, and answers every screen with a
small indexed query. Its memory depends on what is on screen, not on the size
of the vault.

| Document | Contents |
|---|---|
| [SETUP.md](SETUP.md) | Step-by-step setup: indexing, iCloud Drive or Tailscale transport, Simulator and iPhone |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Design: goals, key decisions and their trade-offs, guarantees, limitations |
| [THREAT_MODEL.md](THREAT_MODEL.md) | What is protected, from what, and how the design responds |
| [BENCHMARKS.md](BENCHMARKS.md) | Measured numbers at 20k, 50k and 100k notes, and how to reproduce them |
| [TASKS.md](TASKS.md) | Decisions log, status, deferred work |
| [MACOS.md](MACOS.md) | macOS app: design, decisions and status (Japanese draft) |

## Build and test

Requirements: Xcode 27 (Swift 6.4), macOS 27.

```sh
# Host indexer (macOS)
swift build --package-path Indexer -c release
swift test --package-path Indexer

# Shared + viewer data layer (macOS host and iOS Simulator)
swift test --package-path WikiKit
xcodebuild test -scheme WikiKit-Package -destination 'platform=iOS Simulator,name=iPhone 17'  # run from WikiKit/

# iOS app
xcodebuild -project WikiViewer.xcodeproj -scheme WikiViewer \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# macOS app (same target; see MACOS.md)
scripts/mac.sh run
```

On first launch the app installs a small demo snapshot (built from
`Fixtures/vault`) through the normal validated update path.

## Publishing your vault (Mac mini)

```sh
BIN=Indexer/.build/release/wikiindex
# One-shot: index + publish if anything changed
$BIN build --vault "/path/to/Vault" --state ~/Library/Application\ Support/WikiIndexer/state \
           --publish "/path/to/publish"
# Long-running: FSEvents + periodic reconciliation + quiet-period publication
$BIN watch --vault "/path/to/Vault" --state ~/Library/Application\ Support/WikiIndexer/state \
           --publish "/path/to/publish" --chunks-only
# Validate a publish directory
$BIN verify --publish "/path/to/publish"
```

`--state` and `--publish` must be outside the vault (enforced). The vault is
opened read-only; nothing is ever written into it.

**Transport options**

Every generation is published with a small *delta pack* per recent
generation (only the changed database pages, compressed, in one file) and,
from time to time, a compressed *keyframe* for devices that start from
nothing. A phone downloads one delta pack per update — about 40 KiB after a
one-note edit at 20k notes — and falls back to 128 KiB chunks when no pack
applies. While the app is open it follows the source (see below); in the
background iOS may refresh it too.

- *iCloud Drive / Files folder:* point `--publish` at a folder in iCloud
  Drive (e.g. `~/Library/Mobile Documents/com~apple~CloudDocs/WikiViewer`),
  use `--chunks-only` so the whole database is never re-uploaded, then on the
  iPhone choose Settings → Update Source → Choose Folder… and pick that
  folder. No iCloud entitlement is required. The open app checks the folder
  every 30 s and retries while iCloud is still syncing a generation.
- *HTTP(S):* serve the publish directory with `wikiindex serve --publish DIR`
  behind HTTPS (e.g. Tailscale) — or any static HTTPS server — and enter its
  URL in Settings. `wikiindex serve` keeps connections alive and answers the
  app's long poll as soon as a generation is published, so an open app
  updates within a second or two; a plain static server is polled every 20 s.
  Plain HTTP to LAN hosts is not enabled in the app (App Transport Security).

`watch` publishes a small edit (up to 5 files) 3 s after the vault goes
quiet and a larger batch after 20 s (`--quick-quiet`, `--quick-files`,
`--quiet`). Changes under `.obsidian/` and other never-indexed folders do not
delay publication.

**Run as a LaunchAgent** (in the logged-in user's session, next to Obsidian —
ImageIO needs the GUI session for hardware JPEG decoding). Save as
`~/Library/LaunchAgents/local.wikiindex.plist` with your paths, then
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.wikiindex.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.wikiindex</string>
  <key>ProgramArguments</key><array>
    <string>/path/to/wikiindex</string><string>watch</string>
    <string>--vault</string><string>/path/to/Vault</string>
    <string>--state</string><string>/Users/you/Library/Application Support/WikiIndexer/state</string>
    <string>--publish</string><string>/path/to/publish</string>
    <string>--chunks-only</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/Users/you/Library/Logs/wikiindex.log</string>
</dict></plist>
```

Builder state is disposable: deleting the state directory triggers a full
re-index; generation numbers still never go backwards.

## Benchmarks

```sh
scripts/bench.sh 20000 50000 100000   # synthetic vaults, never your real vault
```

## License

MIT — see [LICENSE](LICENSE). Third-party dependencies keep their own licenses (listed in ARCHITECTURE.md).
