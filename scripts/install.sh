#!/usr/bin/env bash
# Build a Release "Cherminal" and install it to /Applications as your
# daily-driver copy. Distinct from the Debug "Cherminal Dev" build (separate
# bundle id + data dir) that you iterate on, so updating the daily driver
# never disturbs in-flight dev state.
#
# Usage: scripts/install.sh
#
# Note: this is an ad-hoc-signed local build — fine for your own Mac (no
# Gatekeeper warning since you built it). Sharing with others needs the
# notarized Developer ID path (see memory: distribution-plan).
set -euo pipefail

cd "$(dirname "$0")/.."

echo ":: xcodegen generate"
xcodegen generate >/dev/null

echo ":: building Release (arm64) → build/Build/Products/Release"
# arm64 only: libghostty-internal-fat.a is arm64-only, so a universal/x86_64
# link fails. -derivedDataPath build pins the product path so we install the
# build we just made (the old `find DerivedData | head -1` could grab a STALE
# Release app). Abort on failure instead of silently installing something old.
LOG=/tmp/cherminal-release-build.log
if ! xcodebuild -project Cherminal.xcodeproj -scheme Cherminal \
  -configuration Release -derivedDataPath build \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build \
  >"$LOG" 2>&1; then
  echo "✗ Release build FAILED — last lines of $LOG:"
  tail -25 "$LOG"
  exit 1
fi

REL="build/Build/Products/Release/Cherminal.app"
if [[ ! -d "$REL" ]]; then
  echo "✗ built app not found at $REL (see $LOG)"
  exit 1
fi

echo ":: installing → /Applications/Cherminal.app (in-place; does NOT quit a running copy)"
# Session-safe swap: `rm` unlinks the old bundle, so a still-running Cherminal
# (e.g. the one this script is running inside) keeps its already-mapped binary
# on the now-unlinked inode and is NOT killed — it just keeps running the old
# code until you quit it. `ditto` writes the new bundle to fresh inodes. We
# deliberately do NOT auto-quit/relaunch: doing that from inside a Cherminal
# pane would kill this very script (which is exactly how a past install died).
rm -rf "/Applications/Cherminal.app"
ditto "$REL" "/Applications/Cherminal.app"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "/Applications/Cherminal.app/Contents/Info.plist" 2>/dev/null || echo "?")
BUILDNO=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "/Applications/Cherminal.app/Contents/Info.plist" 2>/dev/null || echo "?")
echo "✓ Installed Cherminal $VERSION ($BUILDNO) to /Applications"
echo "  Quit & reopen Cherminal (⌘Q, then relaunch) to pick up this build —"
echo "  your tabs and dtach agents restore on relaunch."
