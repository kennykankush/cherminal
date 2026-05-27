#!/usr/bin/env bash
# Rebuild GhosttyKit.xcframework from a local Ghostty checkout.
# Vendor output: vendor/GhosttyKit.xcframework (gitignored — 130+ MB).
set -euo pipefail

GHOSTTY_DIR="${GHOSTTY_DIR:-$HOME/dev/ghostty}"
ZIG_BIN="${ZIG_BIN:-$(cd "$(dirname "$0")/.." && pwd)/vendor/zig/zig-aarch64-macos-0.15.2/zig}"

if [ ! -d "$GHOSTTY_DIR" ]; then
    echo "Ghostty checkout not found at $GHOSTTY_DIR"
    echo "Clone: git clone --depth 1 https://github.com/ghostty-org/ghostty.git $GHOSTTY_DIR"
    exit 1
fi

if [ ! -x "$ZIG_BIN" ]; then
    echo "Pinned Zig 0.15.2 not found at $ZIG_BIN"
    echo "Install: curl -L https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz | tar -xJ -C \"$(dirname "$ZIG_BIN")/..\""
    exit 1
fi

cd "$GHOSTTY_DIR"
"$ZIG_BIN" build -Doptimize=ReleaseFast -Demit-xcframework -Dxcframework-target=native

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf "$REPO_ROOT/vendor/GhosttyKit.xcframework"
cp -R "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" "$REPO_ROOT/vendor/"
echo "GhosttyKit.xcframework -> $REPO_ROOT/vendor/GhosttyKit.xcframework"
