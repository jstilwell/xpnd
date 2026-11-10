#!/bin/bash
set -e

# Builds a release: a universal app signed with Developer ID and the hardened runtime, in a signed,
# notarized, and stapled DMG, plus a signed Sparkle appcast pointing at it. With --upload it publishes
# the DMG to updates.xpnd.dev and a GitHub release, then the appcast to updates.xpnd.dev. The app reads
# that appcast, so uploading it, last of all, is what ships the update.
#
#   ./bin/build-release.sh [--upload]

UPLOAD=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --upload) UPLOAD=true; shift ;;
        *) echo "Unknown option: $1"; echo "Usage: $0 [--upload]"; exit 1 ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

APP_NAME="xpnd"
REPO="jstilwell/xpnd"
PLIST_PATH="Resources/Info.plist"
RELEASE_DIR="build/release"
APP="$RELEASE_DIR/$APP_NAME.app"
APPCAST="$RELEASE_DIR/appcast.xml"
# Where updates live: the R2 bucket behind updates.xpnd.dev. The feed is SUFeedURL.
UPDATES_URL="https://updates.xpnd.dev"
UPDATES_BUCKET="xpnd-updates"
FEED_URL="${UPDATES_URL}/appcast.xml"
WRANGLER="npx --yes wrangler@4.152.0"
# The team every release is signed by; the Makefile's TEAM_ID, passed to it below.
TEAM_ID="G65RD22S57"
# The keychain account holding xpnd's update signing key (see `generate_keys --account`).
SPARKLE_ACCOUNT="xpnd"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Release assets download only from a public repository, and publishing needs the GitHub CLI.
if [ "$UPLOAD" = true ]; then
    if ! command -v gh &> /dev/null || ! gh auth status &> /dev/null; then
        echo -e "${RED}Error: the GitHub CLI must be installed and signed in (brew install gh; gh auth login).${NC}"
        exit 1
    fi
    if [ "$(gh repo view "$REPO" --json visibility --jq .visibility)" != "PUBLIC" ]; then
        echo -e "${RED}Error: ${REPO} is private, so installed copies couldn't download its releases.${NC}"
        echo "Make it public first: gh repo edit ${REPO} --visibility public --accept-visibility-change-consequences"
        exit 1
    fi
    # Fail before the long build. The login covers several accounts, so name the one with the bucket.
    if [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
        echo -e "${RED}Error: set CLOUDFLARE_ACCOUNT_ID to the account holding the ${UPDATES_BUCKET} bucket.${NC}"
        exit 1
    fi
    if ! $WRANGLER r2 bucket info "$UPDATES_BUCKET" > /dev/null 2>&1; then
        echo -e "${RED}Error: can't reach the ${UPDATES_BUCKET} R2 bucket. Sign in with: npx wrangler login${NC}"
        exit 1
    fi
fi

# Preflight: notarization credentials and Apple's agreements, before spending time building.
echo -e "${YELLOW}Checking notarization credentials...${NC}"
NOTARY_PREFLIGHT=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json 2>&1) || {
    echo -e "${RED}Notarization preflight failed.${NC}"
    if echo "$NOTARY_PREFLIGHT" | grep -qi "agreement"; then
        echo "An Apple Developer agreement needs accepting: https://developer.apple.com/account"
        echo "and https://appstoreconnect.apple.com/ → Business → Agreements, Tax, and Banking."
    elif echo "$NOTARY_PREFLIGHT" | grep -qi "keychain"; then
        echo "Keychain profile '$NOTARY_PROFILE' is missing. Create it with:"
        echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your-apple-id> --team-id <your-team-id>"
    fi
    echo "Raw error:"
    echo "$NOTARY_PREFLIGHT"
    exit 1
}
echo -e "${GREEN}Notarization credentials OK${NC}"

SIGN_UPDATE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
if [ ! -x "$SIGN_UPDATE" ]; then
    xcrun swift package resolve > /dev/null
fi
if [ ! -x "$SIGN_UPDATE" ]; then
    echo -e "${RED}Error: Sparkle's sign_update not found at $SIGN_UPDATE${NC}"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST_PATH")
if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: Could not read the version from $PLIST_PATH${NC}"
    exit 1
fi

# Release notes come from this version's section of CHANGELOG.md.
if [ ! -f CHANGELOG.md ]; then
    echo -e "${RED}Error: CHANGELOG.md not found${NC}"
    exit 1
fi
CHANGELOG_SECTION=$(sed -n "/^## ${VERSION} /,/^## /{/^## ${VERSION} /d;/^## /d;p;}" CHANGELOG.md)
CHANGELOG_SECTION=$(echo "$CHANGELOG_SECTION" | awk 'NF{found=1} found' | awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--)if(lines[i]~/[^ \t]/){last=i;break} for(i=1;i<=last;i++)print lines[i]}')
if [ -z "$CHANGELOG_SECTION" ]; then
    echo -e "${RED}Error: No CHANGELOG.md entry for version ${VERSION}${NC}"
    echo "Add one like this before building:"
    echo ""
    echo "  ## ${VERSION} - $(date +%m-%d-%Y)"
    echo ""
    echo "  ### Changed"
    echo "  - What changed"
    exit 1
fi
if grep -q "^## ${VERSION} - [Uu]nreleased" CHANGELOG.md; then
    echo -e "${RED}Error: CHANGELOG.md still calls ${VERSION} unreleased. Give it today's date ($(date +%m-%d-%Y)).${NC}"
    exit 1
fi
echo -e "${GREEN}Found the CHANGELOG.md entry for ${VERSION}${NC}"

GITHUB_NOTES="## What's New in Version ${VERSION}

${CHANGELOG_SECTION}"
APPCAST_FEATURES=""
while IFS= read -r line; do
    if [[ "$line" == -\ * ]]; then
        # Sparkle shows the notes as HTML: escape what HTML would read as markup, and drop Markdown's
        # emphasis and code marks, which would show as written.
        item=$(printf '%s' "${line#- }" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/\*\*//g' -e 's/`//g')
        APPCAST_FEATURES="${APPCAST_FEATURES}          <li>${item}</li>
"
    fi
done <<< "$CHANGELOG_SECTION"
if [ -z "$APPCAST_FEATURES" ]; then
    APPCAST_FEATURES="          <li>Bug fixes and improvements</li>
"
fi

# Sparkle compares CFBundleVersion, so it follows the version.
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST_PATH")
if [ "$BUILD_VERSION" != "$VERSION" ]; then
    echo -e "${YELLOW}Syncing CFBundleVersion ($BUILD_VERSION) to $VERSION${NC}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST_PATH"
fi
CURRENT_FEED_URL=$(/usr/libexec/PlistBuddy -c "Print SUFeedURL" "$PLIST_PATH")
if [ "$CURRENT_FEED_URL" != "$FEED_URL" ]; then
    echo -e "${YELLOW}Setting SUFeedURL to $FEED_URL${NC}"
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" "$PLIST_PATH"
fi

# A release is cut from committed code, so the tag holds exactly what was built (including any
# Info.plist sync just made).
if [ "$UPLOAD" = true ] && [ -n "$(git status --porcelain)" ]; then
    echo -e "${RED}Error: the working tree has uncommitted changes.${NC}"
    git status --short
    echo "Commit them (including any Info.plist sync made just now) and run this again."
    exit 1
fi
# The release is tagged at the commit that was built, which GitHub must already have.
if [ "$UPLOAD" = true ] && [ -z "$(git branch -r --contains HEAD 2>/dev/null)" ]; then
    echo -e "${RED}Error: the commit to release isn't on GitHub yet. Push it, then run this again.${NC}"
    exit 1
fi
if git rev-parse -q --verify "refs/tags/v${VERSION}" > /dev/null \
    || { command -v gh &> /dev/null && gh release view "v${VERSION}" --repo "$REPO" &> /dev/null; }; then
    echo -e "${RED}Error: v${VERSION} is already released. Raise CFBundleShortVersionString in $PLIST_PATH.${NC}"
    exit 1
fi

# An update reaches every installed copy by itself, so one that fails its own tests never gets built.
echo -e "${YELLOW}Running the tests...${NC}"
make test

echo -e "${GREEN}Building ${APP_NAME} ${VERSION}${NC}"
rm -rf "$RELEASE_DIR"
make release-app TEAM_ID="$TEAM_ID"

# The appcast's minimum system must be what the binary needs, or Sparkle offers the update to Macs
# that can't run it.
MIN_SYSTEM_VERSION=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$APP/Contents/Info.plist")

DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
DOWNLOAD_URL="${UPDATES_URL}/${DMG_NAME}"
echo -e "${YELLOW}Creating ${DMG_NAME}${NC}"
DMG_TEMP=$(mktemp -d)
trap 'rm -rf "$DMG_TEMP"' EXIT
cp -R "$APP" "$DMG_TEMP/"
# A leading space sorts the Applications link after the app.
ln -s /Applications "$DMG_TEMP/ Applications"
# Current macOS makes disk images with diskutil (hdiutil create is deprecated there); older systems
# only have hdiutil. diskutil doesn't overwrite, so a stale DMG goes first.
rm -f "$DMG_PATH"
if diskutil image create from -h > /dev/null 2>&1; then
    diskutil image create from --format UDZO --volumeName "$APP_NAME" "$DMG_TEMP" "$DMG_PATH"
else
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_TEMP" -ov -format UDZO "$DMG_PATH"
fi

# The same certificate as the app, by hash: a renewed certificate shares the old one's name.
SIGNING_IDENTITY=$(make -s print-developer-id TEAM_ID="$TEAM_ID")
if [ -z "$SIGNING_IDENTITY" ] || ! codesign -dv "$APP" 2>&1 | grep -qx "TeamIdentifier=$TEAM_ID"; then
    echo -e "${RED}Error: the app isn't signed with team ${TEAM_ID}'s Developer ID Application certificate${NC}"
    exit 1
fi
echo -e "${YELLOW}Signing the DMG with ${SIGNING_IDENTITY} (team ${TEAM_ID})${NC}"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --strict "$DMG_PATH"

# Anything but "Accepted" stops the release: Gatekeeper blocks an un-notarized download.
echo -e "${YELLOW}Notarizing the DMG (waiting up to 30 minutes)...${NC}"
NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 30m --output-format json 2>&1) || true
SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
NOTARY_STATUS=$(echo "$NOTARY_OUTPUT" | grep -o '"status":"[^"]*"' | tail -1 | cut -d'"' -f4)
if [ "$NOTARY_STATUS" != "Accepted" ]; then
    echo -e "${RED}Notarization didn't succeed (status: ${NOTARY_STATUS:-none}). Release stopped.${NC}"
    echo "$NOTARY_OUTPUT"
    if [ -n "$SUBMISSION_ID" ]; then
        echo "Details: xcrun notarytool log \"$SUBMISSION_ID\" --keychain-profile \"$NOTARY_PROFILE\""
    fi
    exit 1
fi
xcrun stapler staple "$DMG_PATH"
if ! spctl -a -t open --context context:primary-signature -v "$DMG_PATH"; then
    echo -e "${RED}Error: Gatekeeper rejects the DMG. Release stopped.${NC}"
    exit 1
fi
echo -e "${GREEN}Notarized and stapled${NC}"

echo -e "${YELLOW}Signing the update...${NC}"
SIGNATURE=$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$DMG_PATH")
ED_SIGNATURE=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
if [ -z "$ED_SIGNATURE" ]; then
    echo -e "${RED}Error: Failed to sign the update${NC}"
    exit 1
fi
FILE_SIZE=$(stat -f%z "$DMG_PATH")
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > "$APPCAST" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.sparkleproject.org/xml/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${APP_NAME}</title>
    <link>https://github.com/${REPO}</link>
    <description>Most recent updates to ${APP_NAME}</description>
    <language>en</language>

    <item>
      <title>Version ${VERSION}</title>
      <link>https://github.com/${REPO}/releases/tag/v${VERSION}</link>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <description><![CDATA[
        <h2>What's New in Version ${VERSION}</h2>
        <ul>
${APPCAST_FEATURES}        </ul>
      ]]></description>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
        url="${DOWNLOAD_URL}"
        sparkle:version="${VERSION}"
        sparkle:shortVersionString="${VERSION}"
        length="${FILE_SIZE}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}" />
      <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
EOF

# The app requires a signed feed (SURequireSignedFeed). Nothing may change the appcast after this.
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$APPCAST"
if ! "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$APPCAST"; then
    echo -e "${RED}Error: the appcast's signature didn't verify${NC}"
    exit 1
fi
echo -e "${GREEN}Built ${DMG_PATH} and a signed ${APPCAST}${NC}"

if [ "$UPLOAD" = true ]; then
    # The DMG goes first, so the appcast never offers a file that isn't there.
    echo -e "${YELLOW}Uploading ${DMG_NAME} to ${UPDATES_URL}...${NC}"
    $WRANGLER r2 object put "${UPDATES_BUCKET}/${DMG_NAME}" --remote --file "$DMG_PATH" \
        --content-type application/x-apple-diskimage
    # A draft first, then published in one step, so the site never links a release without its DMG. The
    # tag is made on publishing, at the commit that was built.
    echo -e "${YELLOW}Creating the GitHub release...${NC}"
    gh release create "v${VERSION}" "$DMG_PATH" --draft --title "Version ${VERSION}" \
        --notes "$GITHUB_NOTES" --target "$(git rev-parse HEAD)" --repo "$REPO"
    gh release edit "v${VERSION}" --draft=false --latest --repo "$REPO"
    # Last, because this is what offers the update. Not cached, so it reaches installed copies at once.
    echo -e "${YELLOW}Publishing the appcast...${NC}"
    $WRANGLER r2 object put "${UPDATES_BUCKET}/appcast.xml" --remote --file "$APPCAST" \
        --content-type application/xml --cache-control "no-cache"
    echo -e "${GREEN}Released: https://github.com/${REPO}/releases/tag/v${VERSION}${NC}"
else
    echo -e "${YELLOW}Next:${NC} ./bin/build-release.sh --upload builds and publishes it."
fi
echo -e "${GREEN}Done!${NC}"
