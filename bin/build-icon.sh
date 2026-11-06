#!/bin/bash
# Rebuilds the app icon from the artwork in assets/icon: run it after changing any of it, and commit the result.
# Needs Xcode (actool) and Google Chrome, which renders the SVGs; sips and iconutil come with macOS.
#
# Resources/Assets.car comes from AppIcon.icon, the Icon Composer file. Without it macOS 26 and later shrink the
# icon onto a gray plate. Resources/AppIcon.icns is for macOS 14 and 15: app-icon.svg is the full artwork, and
# app-icon-small.svg has heavier strokes and no glow, for 16 and 32 pt at 1x, where the full version turns to mush.
set -euo pipefail

cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Google Chrome is needed to render the SVGs."; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/AppIcon.iconset"
mkdir "$SET"

render() { # svg, png
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
        --default-background-color=00000000 --window-size=1024,1024 \
        --screenshot="$2" "file://$PWD/$1" 2>/dev/null
    [ -f "$2" ] || { echo "Chrome didn't render $1."; exit 1; }
}

size() { # source png, pixels, iconset name
    sips -z "$2" "$2" "$1" --out "$SET/$3" > /dev/null
}

render assets/icon/app-icon.svg "$WORK/full.png"
render assets/icon/app-icon-small.svg "$WORK/small.png"

size "$WORK/small.png" 16 icon_16x16.png
size "$WORK/small.png" 32 icon_16x16@2x.png
size "$WORK/small.png" 32 icon_32x32.png
size "$WORK/full.png" 64 icon_32x32@2x.png
size "$WORK/full.png" 128 icon_128x128.png
size "$WORK/full.png" 256 icon_128x128@2x.png
size "$WORK/full.png" 256 icon_256x256.png
size "$WORK/full.png" 512 icon_256x256@2x.png
size "$WORK/full.png" 512 icon_512x512.png
cp "$WORK/full.png" "$SET/icon_512x512@2x.png"

iconutil --convert icns "$SET" --output Resources/AppIcon.icns

mkdir "$WORK/catalog"
xcrun actool assets/icon/AppIcon.icon --compile "$WORK/catalog" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --include-all-app-icons --output-partial-info-plist "$WORK/partial.plist" > /dev/null
cp "$WORK/catalog/Assets.car" Resources/Assets.car
echo "Wrote Resources/AppIcon.icns and Resources/Assets.car"
