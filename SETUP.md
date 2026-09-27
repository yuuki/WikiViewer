# Setup

This guide sets up WikiViewer from scratch: index your vault on a Mac, get
the snapshot to the app, and run the app in the iOS Simulator or on an iPhone.

Placeholders used below. Replace them with your own values:

| Placeholder | Meaning |
|---|---|
| `<VAULT>` | Path to your Obsidian vault, e.g. `~/Obsidian/MyVault` |
| `<STATE>` | Builder state directory, e.g. `~/Library/Application Support/WikiIndexer/state` |
| `<PUBLISH>` | Publish directory the app reads from |
| `<TEAM_ID>` | Your Apple Developer team ID |
| `<BUNDLE_ID>` | A bundle identifier you own, e.g. `com.example.WikiViewer` |
| `<DEVICE>` | Your iPhone's name or UDID, as shown by `xcrun devicectl list devices` |
| `<SIM_UDID>` | A simulator UDID, as shown by `xcrun simctl list devices` |
| `<HOST>.<TAILNET>.ts.net` | Your Mac's Tailscale MagicDNS name |

`<STATE>` and `<PUBLISH>` must be outside the vault. The indexer refuses them
otherwise. It never writes into the vault.

## 1. Requirements

- A Mac with macOS 27 and Xcode 27 (Swift 6.4)
- An iPhone on iOS 27 or later, or the iOS Simulator
- An Apple account signed in to Xcode. A free Personal Team works for
  installing on your own device.
- Optional: iCloud Drive, or [Tailscale](https://tailscale.com) on both the Mac
  and the iPhone

## 2. Build the indexer

```sh
swift build --package-path Indexer -c release
swift test --package-path Indexer          # optional
BIN=Indexer/.build/release/wikiindex
```

If `swift build` fails with `sandbox-exec: sandbox_apply: Operation not
permitted`, you are running it inside another sandbox (for example a sandboxed
agent shell). Run it from a normal terminal.

## 3. Index the vault and publish a snapshot

Pick a transport first (section 4), because it decides `<PUBLISH>`.

```sh
$BIN build --vault "<VAULT>" --state "<STATE>" --publish "<PUBLISH>"
$BIN verify --publish "<PUBLISH>"
```

- The first run indexes everything. For a vault of about 17k notes and 17k
  images this takes about 2 minutes, and the publish directory is about 3 GB.
  Most of that is image blobs. The database itself is about 300 MB.
- Later runs are incremental and publish only when something changed. Pass
  `--force` to publish anyway.
- Add `--chunks-only` when publishing to iCloud Drive. Each new generation then
  uploads only small delta packs and the changed 128 KiB chunks, never the
  whole database.
- Every generation also gets *delta packs*: the changed database pages since
  each of the last 3 generations, compressed into one file each (split into
  8 MiB parts only for large changes). The phone downloads one of them per
  update instead of many chunks. To compute them,
  `<STATE>/pack-bases/` keeps a copy of the last 3 databases (APFS clones where
  possible; up to 3× the database size on disk). A compressed *keyframe* of
  the whole database is republished when more than 20% of it has changed, for
  phones that start from nothing. `--pack-bases N` changes the number of
  deltas, `--no-packs` turns packs off.
- Notes with invalid YAML frontmatter are still indexed. The indexer prints a
  warning for each one.
- One state directory belongs to one publish directory. To publish to a new
  location, use a new `<STATE>`.

### Excluding folders

Hidden folders (`.obsidian`, `.trash`, …) and `node_modules` are never
indexed. To leave out other folders, pass `--exclude` (repeatable) or keep the
patterns in a file and pass `--exclude-file`:

```sh
cat > "<STATE>/exclude.txt" <<'EOT'
# One pattern per line. A line starting with "#" is a comment.
# A folder named "Private" at any depth:
Private
# Only the top-level "Templates" folder:
/Templates
# A path from the vault root:
Archive/2024
# * and ? match within one folder name:
Daily/*-draft
EOT
$BIN build --vault "<VAULT>" --state "<STATE>" --publish "<PUBLISH>" \
  --exclude-file "<STATE>/exclude.txt"
```

Patterns name folders only and match case-insensitively. Everything inside an
excluded folder is excluded, including images. Links to excluded notes show as
unresolved in the app.

After editing the patterns, run `build` again. A running `watch` notices edits
to the `--exclude-file` within about a second and applies them without a
restart. If the edited file cannot be read or has an invalid pattern, it keeps
the current exclusions and logs an error. Patterns given with `--exclude` can
only change with a restart. The next generation drops notes in newly excluded
folders and adds notes in folders that are no longer excluded. Older retained
generations keep their content until they are garbage collected.

### Publishing only some folders

To publish only selected folders of the vault, pass `--include` (repeatable)
or keep the folders in a file and pass `--include-file`:

```sh
cat > "<STATE>/include.txt" <<'EOT'
# One folder per line, always a path from the vault root.
Projects
Work/Notes
# The folder your notes embed images from:
attachments
EOT
$BIN build --vault "<VAULT>" --state "<STATE>" --publish "<PUBLISH>" \
  --include-file "<STATE>/include.txt"
```

Only files inside an included folder are indexed and published, including its
subfolders. Notes at the top of the vault are not published. `*` and `?` work
as in exclude patterns. Unlike an exclude pattern, an include pattern always
starts at the vault root: `Projects` does not match `Archive/Projects`.
`--exclude` still applies inside the included folders.

Images are published by folder too. If your notes embed images from a shared
folder such as `attachments`, include that folder. Links to notes that are not
published show as unresolved in the app.

The include file must list at least one folder. If it lists none, `build`
refuses to start, and a running `watch` keeps the current folders and logs an
error. An emptied file never publishes the whole vault. A running `watch`
applies other edits to the `--include-file` within about a second, like edits
to the `--exclude-file`. The next generation drops notes in folders that are no
longer included.

### The link graph

The app's Graph tab shows clusters of linked notes, which the indexer computes
before each publication. By default the graph covers every published note.
Leave out notes that link to almost everything (indexes, logs), since they
pull all clusters together, and optionally limit the graph to one folder:

```sh
$BIN build --vault "<VAULT>" --state "<STATE>" --publish "<PUBLISH>" \
  --graph-include wiki \
  --graph-exclude wiki/index.md --graph-exclude wiki/log.md --graph-exclude wiki/meta
```

A pattern is a folder or an fnmatch(3) pattern on the note path (`*` also
crosses `/`), case-insensitive. Clusters are named after their most linked
note, preferring the frontmatter `type` values given by
`--graph-label-types` (default `concept,question,entity,source`); `type` and
`status` also colour the notes in the app. `--no-graph` turns the graph off.
Changing these options recomputes the graph on the next publication.

The viewer database schema is version 3 since the graph was added: update the
indexer and the app together. The indexer rebuilds its builder database once
(a full re-index), and the app installs the next generation it publishes.

To keep the snapshot up to date, run `watch` instead of `build`. See the
LaunchAgent example in [README.md](README.md#publishing-your-vault-mac-mini).
`watch` publishes an edit of up to 5 notes about 3 seconds after the vault goes
quiet, and a larger batch (such as an Obsidian Sync burst) after 20 seconds.

The app follows the source while it is open. When it is closed, iOS may also
refresh it in the background if **Settings → General → Background App
Refresh** is on; iOS decides how often.

## 4. Get the snapshot to the app

### Option A: iCloud Drive

```sh
PUBLISH="$HOME/Library/Mobile Documents/com~apple~CloudDocs/WikiViewer"
$BIN build --vault "<VAULT>" --state "<STATE>" --publish "$PUBLISH" --chunks-only
```

In the app, open **Settings → Choose Folder…**, browse to **iCloud Drive →
WikiViewer**, go *into* the folder, and tap **Open**.

The first upload of several GB takes a while. To check progress on the Mac,
count the files that are still waiting:

```sh
brctl status com.apple.CloudDocs | grep -c ' r:'
```

The number falls toward 0 as files finish. Do not count the `Under /WikiViewer/…`
lines. Such a line stays until every file in that folder is done, so the
count barely moves.

The iPhone can lag behind the Mac by several minutes. If the folder on the
phone shows only `assets`, open the Files app, go to iCloud Drive →
WikiViewer, and pull down to refresh.

While the app is open it re-reads the manifest every 30 seconds. If iCloud has
delivered a new manifest but not yet all of its files, the update fails
quietly and is retried after 5, 10, 20… seconds, so it completes once the
sync does. Of the two options, iCloud Drive has the higher latency: Apple
decides when files are uploaded and downloaded.

### Option B: HTTPS over Tailscale

App Transport Security blocks plain HTTP to LAN hosts, so serve over HTTPS.
Tailscale gives you HTTPS that only devices in your tailnet can reach.

One-time setup on the Mac:

```sh
sudo brew services start tailscale   # if Tailscale was installed with Homebrew
tailscale up                         # opens a login URL
```

In the Tailscale admin console, enable **MagicDNS** and **HTTPS
Certificates**. Install the Tailscale app on the iPhone and sign in to the same
tailnet.

Serve the publish directory on localhost, then expose it to the tailnet:

```sh
$BIN serve --publish "<PUBLISH>" --port 8080 --bind 127.0.0.1
tailscale serve --bg 8080
curl -sI https://<HOST>.<TAILNET>.ts.net/manifest.json   # expect 200
```

In the app, enter `https://<HOST>.<TAILNET>.ts.net` under **Settings →
Update Source** and tap **Use**.

While the app is open it keeps a request to `wikiindex serve` waiting
(`manifest.json?wait=N`, up to 25 s at a time); the server answers as soon as a
new generation is published, so the app starts downloading within about a
second. `tailscale serve` passes these requests through unchanged.

`tailscale serve` only proxies. It stops working when `wikiindex serve` stops.
To stop exposing the snapshot:

```sh
tailscale serve --https=443 off
```

Avoid `tailscale funnel`. It publishes the snapshot to the whole internet.

## 5. Run in the iOS Simulator

```sh
xcodebuild -project WikiViewer.xcodeproj -scheme WikiViewer \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

On first launch the app shows a small bundled demo vault. To load your own
snapshot in the simulator, put the publish directory in the simulator's
**On My iPhone** storage and choose it in the app.

1. Find the simulator's local Files storage:

   ```sh
   D=~/Library/Developer/CoreSimulator/Devices/<SIM_UDID>/data/Containers/Shared/AppGroup
   for f in "$D"/*/.com.apple.mobile_container_manager.metadata.plist; do
     plutil -extract MCMMetadataIdentifier raw "$f" | grep -q LocalStorage \
       && echo "$(dirname "$f")/File Provider Storage"
   done
   ```

2. Copy the publish directory there. On APFS, `cp -c` clones files instead of
   duplicating them, so a 3 GB copy takes a few seconds and almost no disk
   space:

   ```sh
   cp -Rc "<PUBLISH>" "<printed path>/vault-publish"
   ```

3. In the app, open **Settings → Choose Folder… → Browse → On My iPhone →
   vault-publish** and tap **Open**. The status shows *Updated to N* when it
   is done.

To update later, copy the new files over the old ones (`cp -Rc "<PUBLISH>/"
"<printed path>/vault-publish/"`) and tap **Check for Updates**.

## 6. Run on an iPhone

### Signing

The project has no development team, and its bundle identifier is the
placeholder `com.example.WikiViewer` (both in `Config/Signing.xcconfig`). The
Simulator needs neither. For a device, set both in `Config/Local.xcconfig`,
which is git-ignored:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

- `DEVELOPMENT_TEAM`: your team (`<TEAM_ID>`). A Personal Team is fine.
- `PRODUCT_BUNDLE_IDENTIFIER`: `<BUNDLE_ID>`. It must be unique across all
  Apple developer accounts, so do not use the placeholder. Use a reverse domain
  you control.

Do not pick the team in **Signing & Capabilities**. Xcode writes it into the
project file, where it overrides `Local.xcconfig` and ends up in your commits.
Values passed on the command line (`DEVELOPMENT_TEAM=<TEAM_ID>
PRODUCT_BUNDLE_IDENTIFIER=<BUNDLE_ID>`) still override both files.

Claude Code copies `Local.xcconfig` into new git worktrees (see
`.worktreeinclude`). Worktrees created with plain `git worktree add` do not get
it; copy it yourself.

Then sign in to Xcode with that Apple account: **Xcode → Settings → Apple
Accounts**.

### Prepare the device

1. Connect the iPhone by USB, unlock it, and tap **Trust** if it asks.
2. Turn on **Settings → Privacy & Security → Developer Mode**. The iPhone
   restarts. After it restarts, confirm **Turn On** and enter your passcode.
   The option appears only after the device has been connected to Xcode once.

### Build, install and launch

In Xcode, pick the iPhone as the run destination and press **Run** (⌘R). From
the command line:

```sh
xcodebuild -project WikiViewer.xcodeproj -scheme WikiViewer \
  -destination 'platform=iOS,name=<DEVICE>' -allowProvisioningUpdates \
  -derivedDataPath build/device \
  DEVELOPMENT_TEAM=<TEAM_ID> PRODUCT_BUNDLE_IDENTIFIER=<BUNDLE_ID> build
xcrun devicectl device install app --device <DEVICE> \
  build/device/Build/Products/Debug-iphoneos/WikiViewer.app
xcrun devicectl device process launch --device <DEVICE> <BUNDLE_ID>
```

With a Personal Team, iOS refuses to launch the app until you trust the
developer: **Settings → General → VPN & Device Management → Developer App →
your Apple account → Trust**.

Apps signed with a Personal Team expire after 7 days. Run the app from Xcode
again to re-sign it.

Then load a snapshot as in section 4.

## 7. Troubleshooting

`xcrun devicectl device process launch` reports the actual reason when
Xcode says only "The app failed to launch".

| Symptom | Cause | Fix |
|---|---|---|
| `No Accounts: Add a new account in Accounts settings` | Xcode has no Apple account | Sign in under **Xcode → Settings → Apple Accounts** |
| `No profiles for '<BUNDLE_ID>' were found` | No account for the selected team, or the bundle ID is taken | Select your team. Use a bundle ID you own |
| Device shows `connected (no DDI)`; `The device is currently locked` | The developer disk image cannot mount while the device is locked | Unlock the iPhone and keep it unlocked |
| `Installing cryptex … is disallowed because developer mode is not enabled` | Developer Mode is off | Turn on Developer Mode (section 6) |
| `invalid code signature, inadequate entitlements or its profile has not been explicitly trusted` | The developer certificate is not trusted on the device | **Settings → General → VPN & Device Management → Trust** |
| Folder picker shows only `assets` | iCloud Drive has not finished syncing to the phone | Wait for the upload to finish (section 4A), then refresh in the Files app |
| HTTP URL rejected or fails | App Transport Security blocks plain HTTP | Use HTTPS, e.g. with Tailscale (section 4B) |
| *Check for Updates* says up to date, but the vault changed | Nothing was published | Run `build` again, or check the `watch` log |

## Privacy notes

- A snapshot contains the full text of every indexed note and every image.
  Anyone who can read `<PUBLISH>` can read your vault, including folders you
  consider private.
- iCloud Drive stores the snapshot in your iCloud account.
- `tailscale serve` exposes it only to devices in your tailnet. Check who else
  is in your tailnet before you serve it.
- Hidden folders such as `.obsidian` and `.trash` are never indexed. Other
  folders are indexed. Move anything you do not want on the phone out of the
  vault.
