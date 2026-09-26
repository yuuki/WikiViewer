# WikiViewer

Several Claude Code sessions may work on this repo at once, each in its own git
worktree. Build, test and run from the command line with the scripts below, so
sessions do not step on each other.

## Build and test

- `scripts/check.sh` builds and tests everything: Indexer, WikiKit on the host
  and on the simulator, and the iOS app. `scripts/check.sh indexer kit` runs
  only those steps. Run it before calling a change done.
- Do not use the Xcode MCP tools (`mcp__xcode__*`) for building, testing or
  running. They drive the one Xcode app that all sessions share.

## Simulator

- `scripts/sim.sh` gives each worktree its own simulator, named
  `WikiViewer <worktree>` (`WikiViewer main` in the main checkout). Never use
  another simulator: another session may be using it.
- `scripts/sim.sh run` boots, builds, installs and launches the app.
  `scripts/sim.sh screenshot` saves a PNG and prints its path.
- For taps and swipes, pass the UDID from `scripts/sim.sh udid` as `device` to
  the iOS Simulator tool.
- `scripts/sim.sh gc` deletes simulators whose worktree is gone.

## Physical device

- `scripts/device.sh run` builds, installs and launches the app on the first
  paired iPhone. `WV_DEVICE=<name or UDID>` picks another one.
- The device is shared by every worktree, so only run it when asked.

## Sandbox

`swift build`, `xcodebuild` and `simctl` fail inside the Bash sandbox
(SwiftPM cache writes, CoreSimulator services). Run these scripts with the
sandbox disabled.
