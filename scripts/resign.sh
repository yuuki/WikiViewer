#!/bin/bash
# Keep the app signed on a paired iPhone with a free Personal Team.
#
# A Personal Team provisioning profile expires 7 days after Xcode creates it,
# and the app stops launching then. This rebuilds the app with Automatic
# Signing (xcodebuild -allowProvisioningUpdates), which gets a fresh profile,
# and installs it over the old copy with devicectl, usually over Wi-Fi. The
# app's data stays: an install over the same bundle ID keeps its container.
#
#   scripts/resign.sh run         Renew if due: build, sign, install, launch
#   scripts/resign.sh run --force Renew now, due or not
#   scripts/resign.sh status      Last success, profile expiry, next due
#   scripts/resign.sh log         Follow the log
#
# launchd runs "run" every 2 hours (LaunchAgent local.wikiviewer-resign, kept
# with the other agents in ~/obsidian/research/launchd/ and installed by its
# bin/install-launchagents.sh). A run does nothing until a renewal
# is due: 5 days after the last success, or when the installed profile has
# less than 48 hours left. A due run that cannot reach the iPhone (asleep
# away from Wi-Fi, locked since it restarted) fails, and the next run tries
# again, reusing the app it already built.
#
# It builds the local "main" branch in its own worktree
# (~/Library/Application Support/WikiViewerResign/checkout), so uncommitted
# work in the main checkout never reaches the phone, and it never builds in a
# directory another session uses. Config/Local.xcconfig (team, bundle ID)
# comes from the main checkout.
#
# Settings (environment):
#   WV_DEVICE                Device name or UDID (default: first paired iPhone)
#   WV_RESIGN_REF            Git ref to build (default: main)
#   WV_RESIGN_CONFIGURATION  Build configuration (default: Release)
#   WV_RESIGN_INTERVAL_DAYS  Renew this long after the last success (default: 5)
#   WV_RESIGN_MARGIN_HOURS   Renew when the profile has less left (default: 48)
#
# Logs: ~/Library/Logs/WikiViewerResign/ (resign.log, one xcodebuild log per
# build, launchd.log). See SETUP.md, "Keep the app signed".
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REF="${WV_RESIGN_REF:-main}"
CONFIGURATION="${WV_RESIGN_CONFIGURATION:-Release}"
INTERVAL_DAYS="${WV_RESIGN_INTERVAL_DAYS:-5}"
MARGIN_HOURS="${WV_RESIGN_MARGIN_HOURS:-48}"

STATE_DIR="$HOME/Library/Application Support/WikiViewerResign"
LOG_DIR="$HOME/Library/Logs/WikiViewerResign"
STATE="$STATE_DIR/state"
CHECKOUT="$STATE_DIR/checkout"
DERIVED="$STATE_DIR/DerivedData"
APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/WikiViewer.app"
LOG="$LOG_DIR/resign.log"

mkdir -p "$STATE_DIR" "$LOG_DIR"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG" >&2; }

# state: one "key=value" per line.
get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | tail -1 || true; }
put() {
  local tmp="$STATE.tmp"
  { [ -f "$STATE" ] && grep -v "^$1=" "$STATE" || true; echo "$1=$2"; } > "$tmp"
  mv "$tmp" "$STATE"
}

now() { date +%s; }
fmt() { [ -n "$1" ] && date -r "$1" '+%Y-%m-%d %H:%M:%S' || echo "-"; }

# Expiration of the profile embedded in an app, as epoch seconds.
profile_date() {
  local iso
  iso=$(security cms -D -i "$1/embedded.mobileprovision" 2>/dev/null |
    plutil -extract "$2" raw -o - - 2>/dev/null) || return 1
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s
}

# "name<TAB>udid" of the device to use: WV_DEVICE, or the first paired iPhone.
find_device() {
  xcrun devicectl list devices -q --json-output /dev/stdout 2>/dev/null |
    WANT="${WV_DEVICE:-}" python3 -c '
import json, os, sys
want = os.environ["WANT"]
for d in json.load(sys.stdin)["result"]["devices"]:
    hw, props = d["hardwareProperties"], d["deviceProperties"]
    if hw.get("reality") != "physical" or hw.get("platform") != "iOS":
        continue
    if d["connectionProperties"].get("pairingState") != "paired":
        continue
    if want and want not in (props["name"], hw["udid"]):
        continue
    print(props["name"], hw["udid"], sep="\t")
    break
'
}

# Seconds until the next renewal is due (0 or less: due now).
due_in() {
  local last expiry by_interval by_expiry
  last=$(get last_success)
  expiry=$(get profile_expiry)
  [ -n "$last" ] && [ -n "$expiry" ] || { echo 0; return; }
  by_interval=$(( last + INTERVAL_DAYS * 86400 - $(now) ))
  by_expiry=$(( expiry - MARGIN_HOURS * 3600 - $(now) ))
  echo $(( by_interval < by_expiry ? by_interval : by_expiry ))
}

# Brings the build worktree to $REF, creating it the first time.
update_checkout() {
  if [ ! -e "$CHECKOUT/.git" ]; then
    git -C "$REPO" worktree add --detach "$CHECKOUT" "$REF" >/dev/null 2>&1
  fi
  git -C "$CHECKOUT" checkout --detach --force -q "$REF"
  git -C "$CHECKOUT" clean -fdq
  cp "$REPO/Config/Local.xcconfig" "$CHECKOUT/Config/Local.xcconfig"
}

# Signing settings of the app target, read from Xcode itself.
build_settings() {
  xcodebuild -project "$CHECKOUT/WikiViewer.xcodeproj" -scheme WikiViewer \
    -configuration "$CONFIGURATION" -destination 'generic/platform=iOS' \
    -showBuildSettings 2>/dev/null |
    awk -F' = ' '$1 ~ /^ +(PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|CODE_SIGN_STYLE)$/ {
      gsub(/^ +/, "", $1); print $1 "=" $2 }'
}

# Moves Xcode's cached Personal Team profiles for this app ID aside, so the
# build asks Apple for a new 7-day profile instead of reusing one that has
# only days left. Moved, not deleted: they are under $STATE_DIR/old-profiles.
retire_profiles() {
  local app_id="$1" dir f id
  mkdir -p "$STATE_DIR/old-profiles"
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
             "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.mobileprovision "$dir"/*.provisionprofile; do
      [ -f "$f" ] || continue
      id=$(security cms -D -i "$f" 2>/dev/null |
        plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null) || continue
      if [ "$id" = "$app_id" ]; then
        mv "$f" "$STATE_DIR/old-profiles/"
        log "retired cached profile $(basename "$f")"
      fi
    done
  done
}

build() {
  local settings team bundle_id style commit started blog created expiry
  update_checkout
  commit=$(git -C "$CHECKOUT" rev-parse --short HEAD)
  settings=$(build_settings)
  team=$(sed -n 's/^DEVELOPMENT_TEAM=//p' <<<"$settings")
  bundle_id=$(sed -n 's/^PRODUCT_BUNDLE_IDENTIFIER=//p' <<<"$settings")
  style=$(sed -n 's/^CODE_SIGN_STYLE=//p' <<<"$settings")
  if [ -z "$team" ] || [ -z "$bundle_id" ] || [ "$style" != Automatic ]; then
    log "error: need Automatic signing with a team (team=$team bundle=$bundle_id style=$style)"
    return 1
  fi
  log "build $REF ($commit), $CONFIGURATION, $bundle_id, team $team"
  retire_profiles "$team.$bundle_id"

  started=$(now)
  blog="$LOG_DIR/build-$(date '+%Y%m%d-%H%M%S').log"
  if ! xcodebuild -project "$CHECKOUT/WikiViewer.xcodeproj" -scheme WikiViewer \
      -configuration "$CONFIGURATION" -destination 'generic/platform=iOS' \
      -derivedDataPath "$DERIVED" \
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
      build > "$blog" 2>&1; then
    log "error: xcodebuild failed; see $blog"
    grep -E 'error:|Signing|provisioning' "$blog" | tail -5 | sed 's/^/  /' | tee -a "$LOG" >&2
    return 1
  fi
  ls -1t "$LOG_DIR"/build-*.log | tail -n +11 | while read -r f; do rm -f "$f"; done

  created=$(profile_date "$APP" CreationDate)
  expiry=$(profile_date "$APP" ExpirationDate)
  codesign --verify --deep --strict "$APP"
  log "signed: profile created $(fmt "$created"), expires $(fmt "$expiry")"
  if [ "$expiry" -le $(( $(now) + MARGIN_HOURS * 3600 )) ]; then
    log "error: Xcode did not renew the profile (expires $(fmt "$expiry"))"
    return 1
  fi
  put built_commit "$commit"
  put built_at "$started"
}

install_and_launch() {
  local name="$1" udid="$2" bundle_id expiry
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
  log "install on $name ($udid)"
  if ! xcrun devicectl device install app -q --timeout 300 --device "$udid" "$APP" \
      >> "$LOG" 2>&1; then
    log "error: install failed (iPhone unreachable or locked?); will retry"
    return 1
  fi
  expiry=$(profile_date "$APP" ExpirationDate)
  put last_success "$(now)"
  put last_success_commit "$(get built_commit)"
  put profile_expiry "$expiry"
  put device "$udid"
  log "installed; profile valid until $(fmt "$expiry")"

  local out
  if out=$(xcrun devicectl device process launch -q --timeout 60 --terminate-existing \
      --device "$udid" "$bundle_id" 2>&1); then
    log "launched $bundle_id"
  elif grep -q 'explicitly trusted' <<<"$out"; then
    echo "$out" >> "$LOG"
    log "warning: installed, but iOS will not launch it until you trust the developer:" \
      "Settings > General > VPN & Device Management > Apple Development > Trust/Verify App"
  else
    echo "$out" >> "$LOG"
    log "warning: installed but could not launch $bundle_id (locked?)"
  fi
}

# Reuses the app from an earlier run that built it but could not install it,
# if its profile still has a day more than the renewal margin left.
reusable_build() {
  local built_at last expiry
  built_at=$(get built_at)
  last=$(get last_success)
  [ -n "$built_at" ] && [ -d "$APP" ] || return 1
  [ -z "$last" ] || [ "$built_at" -gt "$last" ] || return 1
  expiry=$(profile_date "$APP" ExpirationDate) || return 1
  [ "$expiry" -gt $(( $(now) + MARGIN_HOURS * 3600 + 86400 )) ]
}

notify_if_urgent() {
  local expiry
  expiry=$(get profile_expiry)
  [ -n "$expiry" ] && [ "$expiry" -lt $(( $(now) + 86400 )) ] || return 0
  osascript -e "display notification \"Renewal failed; the app expires $(fmt "$expiry"). See $LOG\" with title \"WikiViewer signing\"" 2>/dev/null || true
}

run() {
  local force="${1:-}" wait device name udid
  wait=$(due_in)
  if [ "$force" != --force ] && [ "$wait" -gt 0 ]; then
    echo "not due; next renewal in $(( wait / 3600 ))h ($(fmt $(( $(now) + wait ))))"
    return 0
  fi

  if ! shlock -f "$STATE_DIR/lock" -p $$; then
    log "another run holds the lock; skipping"
    return 0
  fi
  trap 'rm -f "$STATE_DIR/lock"' EXIT

  put last_attempt "$(now)"
  device=$(find_device)
  if [ -z "$device" ]; then
    log "error: no paired iPhone${WV_DEVICE:+ matching \"$WV_DEVICE\"}"
    put last_error "no device"; notify_if_urgent; return 1
  fi
  name=${device%%$'\t'*}; udid=${device##*$'\t'}

  if reusable_build && [ "$force" != --force ]; then
    log "reusing the app built $(fmt "$(get built_at)")"
  elif ! build; then
    put last_error build; notify_if_urgent; return 1
  fi
  if ! install_and_launch "$name" "$udid"; then
    put last_error install; notify_if_urgent; return 1
  fi
  put last_error ""
}

status() {
  local wait
  wait=$(due_in)
  echo "last success:   $(fmt "$(get last_success)") ($(get last_success_commit))"
  echo "profile expiry: $(fmt "$(get profile_expiry)")"
  echo "last attempt:   $(fmt "$(get last_attempt)")"
  if [ -n "$(get last_error)" ]; then echo "last error:     $(get last_error)"; fi
  if [ "$wait" -gt 0 ]; then
    echo "next renewal:   $(fmt $(( $(now) + wait )))"
  else
    echo "next renewal:   due now"
  fi
  launchctl print "gui/$(id -u)/local.wikiviewer-resign" 2>/dev/null |
    awk '/^\tstate =|last exit code/ { sub(/^\t+/, ""); print "agent:          " $0 }'
}

case "${1:-}" in
  run) shift; run "${1:-}" ;;
  status) status ;;
  log) tail -n 40 -f "$LOG" ;;
  *)
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
    exit 2
    ;;
esac
