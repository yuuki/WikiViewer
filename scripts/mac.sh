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
#   scripts/mac.sh release       Build the app to keep (build/Release): Release,
#                                the plain bundle ID even in a worktree, the
#                                build number from git; checks the signature
#                                and zips it for another Mac
#   scripts/mac.sh install       release + put it in /Applications (or
#                                ~/Applications), the one there going to the
#                                Trash, and launch it
#
# WV_MAC_CONFIGURATION picks the configuration of build and run (default
# Debug). See SETUP.md, "Install on a Mac".
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

RELEASE_DERIVED=build/DerivedDataMacRelease
RELEASE_DIR=build/Release

# The app to keep. Its bundle ID has no worktree suffix: it is the one app
# whose snapshots and settings persist, whichever checkout built it.
release() {
  if ! grep -q '^DEVELOPMENT_TEAM *= *[A-Z0-9]' Config/Local.xcconfig 2>/dev/null; then
    echo "error: set DEVELOPMENT_TEAM in Config/Local.xcconfig (SETUP.md, Signing)" >&2
    exit 1
  fi
  if [ -n "$(git status --porcelain)" ]; then
    echo "warning: uncommitted changes are built in, under the last commit's build number" >&2
  fi
  # Build numbers only grow: the number of commits on the branch.
  build_number=$(git rev-list --count HEAD)
  xcodebuild -project WikiViewer.xcodeproj -scheme WikiViewer \
    -destination 'platform=macOS' -configuration Release \
    -derivedDataPath "$RELEASE_DERIVED" -quiet \
    WV_BUNDLE_ID_SUFFIX= CURRENT_PROJECT_VERSION="$build_number" build
  built="$RELEASE_DERIVED/Build/Products/Release/WikiViewer.app"
  # Apple Development signing adds get-task-allow (a debugger may attach)
  # even to a Release build. Re-sign without it, keeping the rest: the
  # sandbox entitlements come from build settings, so turning off the
  # injection (CODE_SIGN_INJECT_BASE_ENTITLEMENTS) would drop them too.
  entitlements="$RELEASE_DERIVED/entitlements.plist"
  codesign -d --entitlements - --xml "$built" > "$entitlements" 2>/dev/null
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$entitlements" >/dev/null 2>&1 || true
  identity=$(codesign -dvv "$built" 2>&1 | sed -n 's/^Authority=//p' | head -1)
  codesign --force --sign "$identity" --options runtime --entitlements "$entitlements" "$built"
  codesign --verify --strict --deep "$built"
  if ! codesign -d --entitlements - "$built" 2>/dev/null | grep -q app-sandbox; then
    echo "error: the build is not sandboxed" >&2
    exit 1
  fi
  if codesign -d --entitlements - "$built" 2>/dev/null | grep -q get-task-allow; then
    echo "error: the build allows debugging (get-task-allow): not a release build" >&2
    exit 1
  fi
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built/Contents/Info.plist")
  rm -rf "$RELEASE_DIR"
  mkdir -p "$RELEASE_DIR"
  # ditto keeps the signature intact.
  ditto "$built" "$RELEASE_DIR/WikiViewer.app"
  ditto -c -k --keepParent "$RELEASE_DIR/WikiViewer.app" "$RELEASE_DIR/WikiViewer-$version-$build_number.zip"
  echo "$RELEASE_DIR/WikiViewer.app ($version, build $build_number)"
  echo "$RELEASE_DIR/WikiViewer-$version-$build_number.zip"
}

# /Applications when it can be written without an administrator's password,
# otherwise ~/Applications.
install_dir() {
  if [ -w /Applications ]; then echo /Applications; else echo "$HOME/Applications"; fi
}

install_app() {
  release
  dir=$(install_dir)
  target="$dir/WikiViewer.app"
  id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$RELEASE_DIR/WikiViewer.app/Contents/Info.plist")
  osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
  # Let it finish quitting before its bundle is replaced.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -qf "$target/Contents/MacOS/WikiViewer" || break
    sleep 0.5
  done
  mkdir -p "$dir"
  # The previous build goes to the Trash, not away.
  if [ -e "$target" ]; then
    mv "$target" "$HOME/.Trash/WikiViewer $(date +%Y-%m-%d\ %H.%M.%S).app"
  fi
  ditto "$RELEASE_DIR/WikiViewer.app" "$target"
  open "$target"
  echo "Installed and launched $target"
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
  release) release ;;
  install) install_app ;;
  bundle-id)
    [ -d "$APP" ] || build >/dev/null
    bundle_id
    ;;
  *)
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
    exit 2
    ;;
esac
