#!/bin/sh
# One dedicated iOS Simulator per git worktree, so parallel sessions never
# install over each other's app. The device is named "WikiViewer <slug>",
# where <slug> is "main" for the main checkout and the worktree directory name
# otherwise. It is created on first use and reused after that.
#
#   scripts/sim.sh udid          Print this worktree's simulator UDID (creates it)
#   scripts/sim.sh boot          Boot it and wait until it is ready
#   scripts/sim.sh build         Build the app for it (build/DerivedData)
#   scripts/sim.sh run           boot + build + install + launch
#   scripts/sim.sh test          Run WikiKit tests on it (build/DerivedDataKit)
#   scripts/sim.sh screenshot [FILE]
#                                Save a PNG (default build/sim-screenshot.png)
#   scripts/sim.sh delete        Shut down and delete this worktree's simulator
#   scripts/sim.sh gc            Delete simulators of worktrees that no longer exist
#   scripts/sim.sh list          List all WikiViewer simulators
#
# WV_SIM_DEVICE_TYPE and WV_SIM_RUNTIME override the device type and runtime
# (simctl identifiers). The runtime defaults to the newest available iOS.
set -eu
cd "$(dirname "$0")/.."

PREFIX="WikiViewer "
DEVICE_TYPE="${WV_SIM_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}"
APP_DERIVED=build/DerivedData
KIT_DERIVED=build/DerivedDataKit
APP="$APP_DERIVED/Build/Products/Debug-iphonesimulator/WikiViewer.app"

slug_for() { # $1 = worktree path; the main checkout is "main"
  if [ "$(cd "$1" && git rev-parse --path-format=absolute --git-dir)" = \
       "$(cd "$1" && git rev-parse --path-format=absolute --git-common-dir)" ]; then
    echo main
  else
    basename "$1"
  fi
}

NAME="$PREFIX$(slug_for "$(git rev-parse --show-toplevel)")"

# Prints "name<TAB>udid<TAB>state" for every WikiViewer simulator.
sims() {
  xcrun simctl list devices -j | python3 -c '
import json, sys
prefix = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"].startswith(prefix):
            print(d["name"], d["udid"], d["state"], sep="\t")
' "$PREFIX"
}

find_udid() { sims | awk -F'\t' -v n="$NAME" '$1 == n { print $2; exit }'; }

newest_ios_runtime() {
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"]
      if r["isAvailable"] and r["platform"] == "iOS"]
if not rs:
    sys.exit("no available iOS runtime")
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"])
'
}

ensure_udid() {
  udid=$(find_udid)
  if [ -z "$udid" ]; then
    runtime="${WV_SIM_RUNTIME:-$(newest_ios_runtime)}"
    udid=$(xcrun simctl create "$NAME" "$DEVICE_TYPE" "$runtime")
    echo "Created simulator \"$NAME\" ($udid)" >&2
  fi
  echo "$udid"
}

boot() {
  udid=$(ensure_udid)
  # bootstatus -b boots the device if needed and waits until it is usable.
  xcrun simctl bootstatus "$udid" -b >/dev/null
  echo "$udid"
}

build() {
  if grep -q '<[A-Z_]*>' Config/Local.xcconfig 2>/dev/null; then
    echo "warning: Config/Local.xcconfig still has placeholders like <BUNDLE_ID>" >&2
  fi
  udid=$(ensure_udid)
  xcodebuild -project WikiViewer.xcodeproj -scheme WikiViewer \
    -destination "id=$udid" -derivedDataPath "$APP_DERIVED" -quiet build
  echo "$APP"
}

case "${1:-}" in
  udid) ensure_udid ;;
  boot) boot ;;
  build) build ;;
  run)
    udid=$(boot)
    build >/dev/null
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
    xcrun simctl install "$udid" "$APP"
    xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" >/dev/null
    echo "Launched $bundle_id on \"$NAME\" ($udid)"
    ;;
  test)
    udid=$(ensure_udid)
    cd WikiKit
    xcodebuild test -scheme WikiKit-Package -destination "id=$udid" \
      -derivedDataPath "../$KIT_DERIVED" -quiet
    ;;
  screenshot)
    udid=$(boot)
    out="${2:-build/sim-screenshot.png}"
    mkdir -p "$(dirname "$out")"
    xcrun simctl io "$udid" screenshot "$out" >/dev/null 2>&1
    echo "$out"
    ;;
  delete)
    udid=$(find_udid)
    if [ -n "$udid" ]; then
      xcrun simctl shutdown "$udid" 2>/dev/null || true
      xcrun simctl delete "$udid"
      echo "Deleted \"$NAME\" ($udid)"
    fi
    ;;
  gc)
    live=$(git worktree list --porcelain | sed -n 's/^worktree //p' |
      while IFS= read -r wt; do
        [ -d "$wt" ] && echo "$PREFIX$(slug_for "$wt")"
      done)
    sims | while IFS="$(printf '\t')" read -r name udid _; do
      if ! printf '%s\n' "$live" | grep -Fqx "$name"; then
        xcrun simctl shutdown "$udid" 2>/dev/null || true
        xcrun simctl delete "$udid"
        echo "Deleted \"$name\" ($udid)"
      fi
    done
    ;;
  list) sims ;;
  *)
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
    exit 2
    ;;
esac
