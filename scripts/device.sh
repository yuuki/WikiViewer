#!/bin/sh
# Build, install and launch the app on a physical iPhone.
#
#   scripts/device.sh list        List paired physical devices
#   scripts/device.sh udid        Print the UDID of the device to use
#   scripts/device.sh build       Build the app for it (build/DerivedDataDevice)
#   scripts/device.sh run         build + install + launch
#
# The device is the first paired physical iPhone, preferring one that is
# connected now. WV_DEVICE picks a specific one by name or UDID.
# A physical device is shared by every worktree: the last "run" wins.
set -eu
cd "$(dirname "$0")/.."

DERIVED=build/DerivedDataDevice
APP="$DERIVED/Build/Products/Debug-iphoneos/WikiViewer.app"

# Prints "name<TAB>udid<TAB>tunnelState" for every paired physical device,
# connected ones first.
devices() {
  xcrun devicectl list devices -q --json-output /dev/stdout 2>/dev/null | python3 -c '
import json, sys
devs = [d for d in json.load(sys.stdin)["result"]["devices"]
        if d["hardwareProperties"].get("reality") == "physical"
        and d["connectionProperties"].get("pairingState") == "paired"]
devs.sort(key=lambda d: d["connectionProperties"].get("tunnelState") != "connected")
for d in devs:
    print(d["deviceProperties"]["name"], d["hardwareProperties"]["udid"],
          d["connectionProperties"].get("tunnelState"), sep="\t")
'
}

find_udid() {
  udid=$(devices | awk -F'\t' -v want="${WV_DEVICE:-}" \
    'want == "" || $1 == want || $2 == want { print $2; exit }')
  if [ -z "$udid" ]; then
    echo "error: no paired physical device${WV_DEVICE:+ matching \"$WV_DEVICE\"}" >&2
    exit 1
  fi
  echo "$udid"
}

build() {
  if grep -q '<[A-Z_]*>' Config/Local.xcconfig 2>/dev/null; then
    echo "warning: Config/Local.xcconfig still has placeholders like <BUNDLE_ID>" >&2
  fi
  udid=$(find_udid)
  xcodebuild -project WikiViewer.xcodeproj -scheme WikiViewer \
    -destination "id=$udid" -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates -quiet build
  echo "$APP"
}

case "${1:-}" in
  list) devices ;;
  udid) find_udid ;;
  build) build ;;
  run)
    udid=$(find_udid)
    build >/dev/null
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
    xcrun devicectl device install app -q --device "$udid" "$APP"
    xcrun devicectl device process launch -q --terminate-existing \
      --device "$udid" "$bundle_id"
    echo "Launched $bundle_id on $udid"
    ;;
  *)
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
    exit 2
    ;;
esac
