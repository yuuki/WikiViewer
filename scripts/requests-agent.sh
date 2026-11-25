#!/bin/bash
# Runs `wikiindex requests` as a LaunchAgent on the Mac that holds the vault,
# so the app's Ask Claude and Learning Path requests are answered by
# `claude -p` on this Mac's Claude Code login (the subscription, not an API
# key; scripts/claude-request.py removes the API-key variables).
#
#   scripts/requests-agent.sh install    copy the runner, write and load the agent
#   scripts/requests-agent.sh uninstall  unload and remove the agent
#   scripts/requests-agent.sh status     show the agent and the last log lines
#   scripts/requests-agent.sh check      ask claude -p "hi" the way the runner does
#
# The vault, publish and state folders come from the indexer's own agent
# (~/Library/LaunchAgents/local.wikiindex.plist, `wikiindex watch`); set
# WV_VAULT, WV_PUBLISH or WV_STATE to override them. WV_WIKIINDEX is the
# wikiindex binary (default: the one that agent runs).
#
# The runner is copied to ~/Library/Application Support/WikiIndexer/, so the
# agent does not depend on which branch a checkout has; run `install` again
# after changing scripts/claude-request.py.

set -euo pipefail

LABEL=local.wikiindex-requests
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
WATCH_PLIST="$HOME/Library/LaunchAgents/local.wikiindex.plist"
SUPPORT="$HOME/Library/Application Support/WikiIndexer"
RUNNER="$SUPPORT/claude-request.py"
LOG="$HOME/Library/Logs/wikiindex-requests.log"
SRC_RUNNER="$(cd "$(dirname "$0")" && pwd)/claude-request.py"
API_BILLING_ENV=(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
                 CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY)

# The value after `--<name>` in the watch agent's arguments ("bin" is the program).
watch_arg() {
    [ -f "$WATCH_PLIST" ] || return 0
    python3 -I - "$WATCH_PLIST" "$1" <<'EOF'
import plistlib, sys
args = plistlib.load(open(sys.argv[1], "rb")).get("ProgramArguments", [])
name = sys.argv[2]
if name == "bin":
    print(args[0] if args else "")
else:
    flag = "--" + name
    print(args[args.index(flag) + 1] if flag in args and args.index(flag) + 1 < len(args) else "")
EOF
}

resolve() {
    WIKIINDEX="${WV_WIKIINDEX:-$(watch_arg bin)}"
    VAULT="${WV_VAULT:-$(watch_arg vault)}"
    PUBLISH="${WV_PUBLISH:-$(watch_arg publish)}"
    STATE="${WV_STATE:-$(watch_arg state)}"
    CLAUDE="${CLAUDE_BIN:-$(command -v claude || true)}"
    local missing=0
    for pair in "wikiindex:$WIKIINDEX" "vault:$VAULT" "publish:$PUBLISH" "state:$STATE" "claude:$CLAUDE"; do
        if [ -z "${pair#*:}" ]; then
            echo "error: no ${pair%%:*} (set WV_${pair%%:*} or install the indexer's agent first)" >&2
            missing=1
        fi
    done
    [ "$missing" = 0 ] || exit 1
}

install() {
    resolve
    mkdir -p "$SUPPORT" "$STATE" "$(dirname "$LOG")"
    cp "$SRC_RUNNER" "$RUNNER"
    chmod 755 "$RUNNER"
    python3 -I - "$PLIST" "$LABEL" "$WIKIINDEX" "$PUBLISH" "$VAULT" "$RUNNER" "$STATE/requests.jsonl" "$LOG" "$CLAUDE" <<'EOF'
import os, plistlib, sys
plist, label, wikiindex, publish, vault, runner, reqlog, log, claude = sys.argv[1:]
path = ":".join(dict.fromkeys([os.path.dirname(claude), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]))
with open(plist, "wb") as f:
    plistlib.dump({
        "Label": label,
        "ProgramArguments": [wikiindex, "requests", "--publish", publish, "--vault", vault,
                             "--runner", runner, "--log", reqlog],
        "EnvironmentVariables": {"PATH": path, "CLAUDE_BIN": claude},
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Background",
        "StandardOutPath": log,
        "StandardErrorPath": log,
    }, f)
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "installed $LABEL"
    echo "  runner  $RUNNER"
    echo "  claude  $CLAUDE"
    echo "  inbox   $PUBLISH/inbox"
    echo "  log     $LOG"
}

uninstall() {
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed $LABEL (the runner copy in $SUPPORT is left)"
}

status() {
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
        launchctl print "gui/$(id -u)/$LABEL" | grep -E '^\s*(state|pid|last exit code) ='
    else
        echo "$LABEL is not loaded"
    fi
    [ -f "$LOG" ] && tail -n 5 "$LOG"
    return 0
}

# One tiny prompt, with the variables the runner removes also removed here.
check() {
    resolve
    local unset_args=()
    for name in "${API_BILLING_ENV[@]}"; do unset_args+=(-u "$name"); done
    env "${unset_args[@]}" "$CLAUDE" -p "Reply with OK." --output-format json --no-session-persistence </dev/null |
        python3 -I -c '
import json, sys
e = json.load(sys.stdin)
if e.get("is_error"):
    sys.exit("error: " + str(e.get("result") or e.get("subtype")) + " (run claude, then /login)")
print("ok:", (e.get("result") or "").strip()[:80])'
}

case "${1:-}" in
    install) install ;;
    uninstall) uninstall ;;
    status) status ;;
    check) check ;;
    *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
