#!/usr/bin/env bash
# E2E: the dtach survival loop, against the REAL app (CherminalDev).
#
# Verifies the guarantees CI structurally can't (it needs a window server):
#   1. RESTORE-LIVE — a hand-launched agent's foreign-socket master is kept by
#      the launch sweep and REATTACHED (same pid), with no cold `--resume`
#      spawned (ConversationLedger.restorePlan's attachLiveShell path).
#   2. SURVIVE-QUIT — the master outlives ⌘Q and the SAME pid reattaches on
#      relaunch.
#   3. WRAP-BY-DEFAULT — with no explicit persistentSessions preference, a
#      fresh shell tab spawns under a dtach master (the registered default).
#
# Local/manual only (launches a GUI app). Touches ONLY the dev bundle
# (dev.hamulia.Cherminal.dev) — never the installed daily driver.
#
# Usage: scripts/e2e-dtach.sh        (expects the Debug build to exist;
#        pass --build to build it first)
set -uo pipefail

cd "$(dirname "$0")/.."
APP="build/Build/Products/Debug/CherminalDev.app"
BUNDLE_ID="dev.hamulia.Cherminal.dev"
SOCKDIR="$HOME/.cherminal/dtach/$BUNDLE_ID"
LOG="$HOME/Library/Application Support/$BUNDLE_ID/cherminal-debug.log"
DTACH="$APP/Contents/MacOS/dtach"
PASS=0; FAIL=0

if [[ "${1:-}" == "--build" ]]; then
    echo ":: building Debug"
    xcodegen generate >/dev/null
    xcodebuild -project Cherminal.xcodeproj -scheme Cherminal -configuration Debug \
        -derivedDataPath build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build >/dev/null || exit 1
fi
[[ -x "$DTACH" ]] || { echo "✗ dev build not found at $APP (run with --build)"; exit 1; }

check() {  # check <description> <command...>
    if "${@:2}" >/dev/null 2>&1; then echo "  ✓ $1"; PASS=$((PASS+1));
    else echo "  ✗ $1"; FAIL=$((FAIL+1)); fi
}
master_pid() { /usr/sbin/lsof -t "$1" 2>/dev/null | sort -u | head -1; }
quit_app()  { osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1; sleep 4; }
reap_all()  {
    for s in "$SOCKDIR"/*.sock; do
        [[ -e "$s" ]] && kill "$(master_pid "$s")" 2>/dev/null
        rm -f "$s"
    done
}
cleanup() {
    quit_app; reap_all
    defaults delete "$BUNDLE_ID" cherminal.lastWorkspaces 2>/dev/null
    defaults delete "$BUNDLE_ID" cherminal.detachedAgents 2>/dev/null
}
trap cleanup EXIT

echo ":: setup"
quit_app; mkdir -p "$SOCKDIR"; reap_all
defaults write "$BUNDLE_ID" cherminal.reopenChoice reopen
defaults delete "$BUNDLE_ID" cherminal.persistentSessions 2>/dev/null
defaults delete "$BUNDLE_ID" cherminal.detachedAgents 2>/dev/null

# ---- 1. RESTORE-LIVE: foreign-socket master kept + reattached --------------
echo ":: 1. restore-live (foreign socket reattach, no cold resume)"
S=$(uuidgen | tr 'A-Z' 'a-z'); A=$(uuidgen | tr 'A-Z' 'a-z')
"$DTACH" -n "$SOCKDIR/$S.sock" /bin/sh -c "exec sleep 600"; sleep 1
P1=$(master_pid "$SOCKDIR/$S.sock")
[[ -n "$P1" ]] || { echo "✗ couldn't stage a master"; exit 1; }
JSON="[{\"panes\":[{\"conversationID\":\"$A\",\"agentRaw\":\"claudeCode\",\"roomPath\":\"$HOME\",\"socketID\":\"$S\"}]}]"
defaults write "$BUNDLE_ID" cherminal.lastWorkspaces -data "$(printf %s "$JSON" | xxd -p | tr -d '\n')"
rm -f "$LOG"
open -n "$APP"; sleep 14
check "master survived the launch sweep (pid $P1)" test "$(master_pid "$SOCKDIR/$S.sock")" = "$P1"
check "no cold --resume spawned for the agent" bash -c "! ps -axww -o command= | grep -v grep | grep -q -- \"--resume $A\""
check "session restored from snapshot" grep -q "restoring 1 tab" "$LOG"

# ---- 2. SURVIVE-QUIT: same pid across quit + relaunch ----------------------
echo ":: 2. survive-quit (same pid across relaunch)"
quit_app
check "master survived quit" test "$(master_pid "$SOCKDIR/$S.sock")" = "$P1"
open -n "$APP"; sleep 13
check "relaunch reattached the SAME master" test "$(master_pid "$SOCKDIR/$S.sock")" = "$P1"
quit_app

# ---- 3. WRAP-BY-DEFAULT: fresh shells get masters --------------------------
echo ":: 3. wrap-by-default (registered persistentSessions default)"
reap_all
defaults delete "$BUNDLE_ID" cherminal.lastWorkspaces 2>/dev/null
open -n "$APP"; sleep 13
NEW=$(ls "$SOCKDIR" 2>/dev/null | head -1)
check "fresh shell spawned under a dtach master" test -n "$NEW"
[[ -n "$NEW" ]] && check "that master is alive" test -n "$(master_pid "$SOCKDIR/$NEW")"
quit_app

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && echo "E2E: ALL GREEN" || echo "E2E: FAILURES — see above"
exit $FAIL
