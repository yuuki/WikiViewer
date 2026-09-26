#!/bin/sh
# Build and test everything from the command line, without the Xcode app.
# Safe to run in several git worktrees at once: every build directory is
# inside the worktree, and iOS steps use this worktree's own simulator
# (scripts/sim.sh).
#
#   scripts/check.sh              Run every step below, in order
#   scripts/check.sh STEP...      Run only the given steps
#
# Steps:
#   indexer     swift build + swift test for Indexer (macOS host)
#   kit         swift test for WikiKit (macOS host)
#   kit-ios     WikiKit tests on this worktree's simulator
#   app         Build the iOS app for this worktree's simulator
#
# Stops at the first failing step.
set -eu
cd "$(dirname "$0")/.."

ALL="indexer kit kit-ios app"

step() {
  case "$1" in
    indexer)
      swift build --package-path Indexer -c release &&
        swift test --package-path Indexer ;;
    kit) swift test --package-path WikiKit ;;
    kit-ios) scripts/sim.sh test ;;
    app) scripts/sim.sh build >/dev/null ;;
    *)
      awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
      exit 2 ;;
  esac
}

[ $# -gt 0 ] || set -- $ALL
for s in "$@"; do
  echo "==> $s"
  start=$(date +%s)
  if ! step "$s"; then
    echo "==> $s FAILED" >&2
    exit 1
  fi
  echo "==> $s ok ($(( $(date +%s) - start ))s)"
done
echo "==> all ok: $*"
