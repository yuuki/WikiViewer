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
| [ARCHITECTURE.md](ARCHITECTURE.md) | Design: goals, key decisions and their trade-offs, guarantees, limitations |
| [THREAT_MODEL.md](THREAT_MODEL.md) | What is protected, from what, and how the design responds |
| [BENCHMARKS.md](BENCHMARKS.md) | Measured numbers at 20k, 50k and 100k notes, and how to reproduce them |
| [TASKS.md](TASKS.md) | Decisions log, status, deferred work |

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

- *iCloud Drive / Files folder:* point `--publish` at a folder in iCloud
  Drive (e.g. `~/Library/Mobile Documents/com~apple~CloudDocs/WikiViewer`),
  use `--chunks-only` so each generation uploads only changed 128 KiB chunks,
  then on the iPhone choose Settings → Update Source → Choose Folder… and pick
  that folder. No iCloud entitlement is required.
- *HTTP(S):* serve the publish directory with any static HTTPS server (or
  `wikiindex serve --publish DIR --bind 0.0.0.0` behind HTTPS, e.g. Tailscale)
  and enter its URL in Settings. Plain HTTP to LAN hosts is not enabled in the
  app (App Transport Security).

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
