#!/usr/bin/env bash
# Cut a public release: build → sign (Developer ID) → dmg → notarize →
# staple → tag → GitHub Release. One command, runs on THIS Mac — the
# signing cert lives in the login keychain, so nothing secret ever leaves
# the machine (no certs in CI).
#
# Usage: scripts/release.sh <version>            e.g. scripts/release.sh 0.2.0
#
# Prerequisites (one-time):
#   • A "Developer ID Application" cert in the keychain
#     (Xcode → Settings → Accounts → Manage Certificates… → + → Developer ID Application)
#   • A stored notary credential:
#     xcrun notarytool store-credentials cherminal-notary \
#       --apple-id <apple-id-email> --team-id 483LU3J5WJ --password <app-specific-password>
#   • gh auth (for the release upload)
#
# What it does, in order:
#   1. bump CFBundleShortVersionString to <version>, CFBundleVersion +1 (project.yml)
#   2. xcodegen + Release build (arm64), Manual signing with the Developer ID
#      identity + hardened runtime (required for notarization)
#   3. verify the signature (codesign --deep --strict)
#   4. package a dmg (app + /Applications symlink), sign the dmg too
#   5. notarize (notarytool --wait) and staple the ticket
#   6. Gatekeeper dress rehearsal (spctl) — the exact check a downloader hits
#   7. commit the bump, tag v<version>, push, gh release create with the dmg
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: scripts/release.sh <version>  (e.g. 0.2.0)" >&2; exit 2; }

NOTARY_PROFILE="cherminal-notary"
# The paid Developer Program team (the Developer ID cert's team) — NOT the
# old free personal team 29CYQWJSMF that the Apple Development cert is on.
TEAM="483LU3J5WJ"
APP_NAME="Cherminal"
BUILD_DIR="build-release"
DMG="dist/${APP_NAME}-${VERSION}.dmg"

# ---- preflight ---------------------------------------------------------------
fail() { echo "✗ $1" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || fail "working tree not clean — commit or stash first"
[[ "$(git branch --show-current)" == "main" ]] || fail "release from main only"
git tag | grep -qx "v$VERSION" && fail "tag v$VERSION already exists"

IDENTITY="$(security find-identity -v -p codesigning \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
[[ -n "$IDENTITY" ]] || fail "no 'Developer ID Application' cert in the keychain
  → Xcode → Settings → Accounts → Manage Certificates… → + → Developer ID Application"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "no notary credential '$NOTARY_PROFILE' — run:
  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id $TEAM --password <app-specific-password>"

echo ":: releasing $APP_NAME $VERSION"
echo ":: signing as: $IDENTITY"

# ---- 1. version bump ----------------------------------------------------------
CUR_BUILD="$(grep 'CFBundleVersion:' project.yml | grep -o '[0-9]*')"
NEW_BUILD=$((CUR_BUILD + 1))
sed -i '' "s/CFBundleShortVersionString: \"[^\"]*\"/CFBundleShortVersionString: \"$VERSION\"/" project.yml
sed -i '' "s/CFBundleVersion: \"[^\"]*\"/CFBundleVersion: \"$NEW_BUILD\"/" project.yml
echo ":: version $VERSION ($NEW_BUILD)"

# ---- 2. build, signed ---------------------------------------------------------
echo ":: xcodegen + Release build (arm64, hardened runtime)"
xcodegen generate >/dev/null
BUILD_LOG="$(mktemp -t cherminal-release-build-XXXX.log)"
xcodebuild -project Cherminal.xcodeproj -scheme Cherminal -configuration Release \
    -derivedDataPath "$BUILD_DIR" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build >"$BUILD_LOG" 2>&1 \
    || { tail -30 "$BUILD_LOG"; fail "build failed (full log: $BUILD_LOG)"; }
grep -E "warning: .*Cherminal/" "$BUILD_LOG" || true

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || fail "build produced no app at $APP"

# ---- 3. verify signature ------------------------------------------------------
codesign --verify --deep --strict "$APP" || fail "signature does not verify"
# Authority lines only print at -dvv (two v's) — -dv shows none at all.
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID Application" >/dev/null \
    || fail "app is not Developer ID signed"
echo "✓ signature verified (Developer ID, hardened runtime)"

# ---- 4. dmg -------------------------------------------------------------------
echo ":: packaging dmg"
mkdir -p dist
rm -f "$DMG"
STAGE="$(mktemp -d -t cherminal-dmg-XXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "✓ $DMG"

# ---- 5. notarize + staple ------------------------------------------------------
echo ":: notarizing (this waits on Apple — typically 1–5 min)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
    | grep -E "id:|status:" | head -4
xcrun stapler staple "$DMG" >/dev/null
echo "✓ notarized + stapled"

# ---- 6. Gatekeeper dress rehearsal ---------------------------------------------
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | head -1
echo "✓ Gatekeeper accepts the dmg"

# ---- 7. tag + publish -----------------------------------------------------------
SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
git add project.yml Cherminal/Info.plist
git commit -m "Release $VERSION (build $NEW_BUILD)" >/dev/null
git tag "v$VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" "$DMG" \
    --title "$APP_NAME $VERSION" \
    --generate-notes
echo
echo "✓ released: https://github.com/kennykankush/cherminal/releases/tag/v$VERSION"

# ---- 8. bump the Homebrew cask --------------------------------------------------
# The release is ALREADY live above — a cask failure must not read as a
# release failure, so this step warns-and-continues instead of dying.
bump_cask() {
    local tap_dir
    tap_dir="$(mktemp -d -t cherminal-tap-XXXX)"
    git clone --quiet --depth 1 "https://github.com/kennykankush/homebrew-tap.git" "$tap_dir"
    local cask="$tap_dir/Casks/cherminal.rb"
    sed -i '' "s/^  version \".*\"/  version \"$VERSION\"/" "$cask"
    sed -i '' "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" "$cask"
    grep -q "version \"$VERSION\"" "$cask" && grep -q "sha256 \"$SHA256\"" "$cask" \
        || { rm -rf "$tap_dir"; return 1; }
    git -C "$tap_dir" commit -aqm "cherminal $VERSION"
    git -C "$tap_dir" push -q
    rm -rf "$tap_dir"
}
if bump_cask; then
    echo "✓ brew cask bumped — brew install --cask kennykankush/tap/cherminal serves $VERSION"
else
    echo "⚠ cask bump FAILED — the release is live, but the tap still serves the old version."
    echo "  Bump manually in github.com/kennykankush/homebrew-tap/Casks/cherminal.rb:"
    echo "    version \"$VERSION\""
    echo "    sha256  \"$SHA256\""
fi
