#!/usr/bin/env bash
# Fetch the vendored GhosttyKit.xcframework for a fresh clone.
#
# The xcframework is too large to commit (134 MB, one object >100 MB GitHub
# cap) — it ships as a release asset pinned by vendor/GhosttyKit.version
# (the same source CI uses). The repo is public, so a plain curl works; no
# gh auth needed.
#
# Usage: scripts/fetch-ghostty.sh [--force]
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="kennykankush/cherminal"
DEST="vendor/GhosttyKit.xcframework"

if [[ -d "$DEST" && "${1:-}" != "--force" ]]; then
    echo "✓ $DEST already present (use --force to re-download)"
    exit 0
fi

TAG="$(grep -v '^#' vendor/GhosttyKit.version | tr -d '[:space:]')"
[[ -n "$TAG" ]] || { echo "✗ no tag in vendor/GhosttyKit.version" >&2; exit 1; }
URL="https://github.com/$REPO/releases/download/$TAG/GhosttyKit.xcframework.zip"

echo ":: fetching $TAG"
TMP="$(mktemp -t ghosttykit-XXXX.zip)"
trap 'rm -f "$TMP"' EXIT
curl -fL --progress-bar "$URL" -o "$TMP"

rm -rf "$DEST"
unzip -q "$TMP" -d vendor/
test -d "$DEST" || { echo "✗ unzip produced no $DEST" >&2; exit 1; }
echo "✓ $DEST ready ($TAG)"
