#!/usr/bin/env bash
# Build a Release "Cherminal" and install it to /Applications as your
# daily-driver copy. Distinct from the Debug "Cherminal Dev" build (separate
# bundle id + data dir) that you iterate on, so updating the daily driver
# never disturbs in-flight dev state.
#
# Usage: scripts/install.sh
#
# Signs with your Developer ID cert when one is in the keychain, else ad-hoc.
# That choice is not cosmetic: a keychain ACL entry ("Always Allow" on Claude
# Code's credentials, which the rate-limit meters read) binds to the app's code
# identity. A Developer ID signature is a stable identity that survives every
# reinstall; an ad-hoc/linker-signed one is just a hash of the binary, and this
# script replaces the bundle wholesale — so the grant is void by the next
# launch and macOS asks again. Sharing with others still needs the notarized
# path (scripts/release.sh).
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM="483LU3J5WJ"
IDENTITY="$(security find-identity -v -p codesigning \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
if [[ -n "$IDENTITY" ]]; then
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY"
             DEVELOPMENT_TEAM="$TEAM" ENABLE_HARDENED_RUNTIME=YES
             CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
  echo ":: signing as: $IDENTITY"
else
  SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
  echo ":: no Developer ID cert found — ad-hoc signing (keychain 'Always Allow'"
  echo "   will not survive reinstalls; see the note at the top of this script)"
fi

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
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "${SIGN_ARGS[@]}" build \
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
