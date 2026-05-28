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

echo ":: building Release"
xcodebuild -project Cherminal.xcodeproj -scheme Cherminal \
  -configuration Release build CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

REL=$(find ~/Library/Developer/Xcode/DerivedData -name "Cherminal.app" -path "*/Release/*" 2>/dev/null | head -1)
if [[ -z "$REL" || ! -d "$REL" ]]; then
  echo "✗ Release build not found — check the build output above."
  exit 1
fi

echo ":: installing → /Applications/Cherminal.app"
# Relaunch-safe: quit the running copy first so we can overwrite it.
osascript -e 'tell application "Cherminal" to quit' >/dev/null 2>&1 || true
killall Cherminal 2>/dev/null || true
sleep 1
rm -rf "/Applications/Cherminal.app"
ditto "$REL" "/Applications/Cherminal.app"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "/Applications/Cherminal.app/Contents/Info.plist" 2>/dev/null || echo "?")
echo "✓ Installed Cherminal $VERSION to /Applications"
echo "  Launch it from Spotlight/Dock. Re-run this script to update it."
