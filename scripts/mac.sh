#!/bin/sh
# Build and run the macOS app from the command line. In a git worktree the
# app gets its own bundle ID ("<bundle id>.wt-<worktree>"), so its sandbox
# container, snapshots and preferences are its own: parallel sessions never
# share them, and the app built from the main checkout keeps the plain
# bundle ID.
#
#   scripts/mac.sh build         Build the app (build/DerivedDataMac); prints its path
#   scripts/mac.sh run           build + launch (replacing a running copy)
#   scripts/mac.sh quit          Quit this worktree's running copy
#   scripts/mac.sh bundle-id     Print this worktree's bundle ID
#
# WV_MAC_CONFIGURATION picks the configuration (default Debug).
set -eu
cd "$(dirname "$0")/.."

CONFIGURATION="${WV_MAC_CONFIGURATION:-Debug}"
DERIVED=build/DerivedDataMac
APP="$DERIVED/Build/Products/$CONFIGURATION/WikiViewer.app"

# Empty in the main checkout; ".wt-<worktree>" in a worktree, reduced to the
# characters a bundle ID allows.
suffix() {
  if [ "$(git rev-parse --path-format=absolute --git-dir)" = \
       "$(git rev-parse --path-format=absolute --git-common-dir)" ]; then
    echo ""
  else
    echo ".wt-$(basename "$(git rev-parse --show-toplevel)" | tr -c 'A-Za-z0-9.\n-' '-')"
  fi
}

build() {
  if grep -q '<[A-Z_]*>' Config/Local.xcconfig 2>/dev/null; then
    echo "warning: Config/Local.xcconfig still has placeholders like <BUNDLE_ID>" >&2
  fi
  xcodebuild -project WikiViewer.xcodeproj -scheme WikiViewer \
    -destination 'platform=macOS' -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED" -quiet \
    WV_BUNDLE_ID_SUFFIX="$(suffix)" build
  echo "$APP"
}

bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
}

quit() {
  [ -d "$APP" ] || return 0
  osascript -e "tell application id \"$(bundle_id)\" to quit" >/dev/null 2>&1 || true
}

case "${1:-}" in
  build) build ;;
  run)
    build >/dev/null
    quit
    open -n "$APP"
    echo "Launched $(bundle_id) ($APP)"
    ;;
  quit) quit ;;
  bundle-id)
    [ -d "$APP" ] || build >/dev/null
    bundle_id
    ;;
  *)
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
    exit 2
    ;;
esac
