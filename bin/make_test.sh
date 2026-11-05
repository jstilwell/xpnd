#!/bin/bash
# Builds a test copy of xpnd to run on another Mac: the universal release app (Developer ID, hardened
# runtime), notarized and stapled, zipped. Nothing is published, tagged or committed, Info.plist is
# left alone, and Sparkle is untouched, so this never counts as a release.
#
#   ./bin/make_test.sh                 build, notarize, staple, zip
#   ./bin/make_test.sh --no-notarize   build and zip only (on the other Mac: xattr -dr com.apple.quarantine xpnd.app)
#
# Output: build/test/xpnd-<version>-<commit>.zip
set -euo pipefail

NOTARIZE=true
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-notarize) NOTARIZE=false; shift ;;
        *) echo "Unknown option: $1"; echo "Usage: $0 [--no-notarize]"; exit 1 ;;
    esac
done

cd "$(dirname "$0")/.."
TEAM_ID="G65RD22S57"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
APP="build/release/xpnd.app"
OUT_DIR="build/test"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
COMMIT=$(git rev-parse --short HEAD)
[ -n "$(git status --porcelain)" ] && COMMIT="$COMMIT-dirty"
ZIP="$OUT_DIR/xpnd-$VERSION-$COMMIT.zip"

# Fail before the long build, as bin/build-release.sh does.
if [ "$NOTARIZE" = true ] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1; then
    echo "Notarization credentials (keychain profile '$NOTARY_PROFILE') aren't working."
    echo "Fix them (see bin/build-release.sh), or run with --no-notarize."
    exit 1
fi

rm -rf build/release
make release-app TEAM_ID="$TEAM_ID"

mkdir -p "$OUT_DIR"
rm -f "$ZIP"
# ditto keeps the bundle's signature and symlinks intact; plain zip can break them.
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$NOTARIZE" = true ]; then
    echo "Notarizing (waiting up to 30 minutes)..."
    OUTPUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout 30m --output-format json 2>&1) || true
    STATUS=$(echo "$OUTPUT" | grep -o '"status":"[^"]*"' | tail -1 | cut -d'"' -f4)
    if [ "$STATUS" != "Accepted" ]; then
        echo "Notarization didn't succeed (status: ${STATUS:-none})."
        echo "$OUTPUT"
        ID=$(echo "$OUTPUT" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        [ -n "$ID" ] && echo "Details: xcrun notarytool log \"$ID\" --keychain-profile \"$NOTARY_PROFILE\""
        exit 1
    fi
    # A zip can't be stapled: staple the app, then zip it again.
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl -a -t exec -vv "$APP"
fi

echo "Built $ZIP"
echo "Copy it to the other Mac, unzip, and move xpnd.app to /Applications."
