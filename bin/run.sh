#!/bin/bash
set -e

usage() {
    cat <<'USAGE'
Builds this copy of xpnd for Apple silicon and Intel, as releases are, and runs it,
quitting any copy that's already running.

  ./bin/run.sh                      build and run
  ./bin/run.sh --test-snippets      first install Tests/Manual/test-snippets.yaml as your snippets,
                                    backing up the current file
  ./bin/run.sh --reset-permissions  first clear xpnd's Accessibility and Input Monitoring grants, so
                                    the welcome window runs again (macOS asks for your password)
  ./bin/run.sh --log                then stream what it does (Ctrl-C stops the log, not the app)

Options combine, e.g. ./bin/run.sh --test-snippets --log
USAGE
}

LOG=false
TEST_SNIPPETS=false
RESET_PERMISSIONS=false
for arg in "$@"; do
    case $arg in
        --log) LOG=true ;;
        --test-snippets) TEST_SNIPPETS=true ;;
        --reset-permissions) RESET_PERMISSIONS=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

cd "$(dirname "$0")/.."

if ! xcrun --find swift > /dev/null 2>&1; then
    echo "Building xpnd needs Xcode. Install it from the App Store, then run:"
    echo "  sudo xcode-select -s /Applications/Xcode.app"
    exit 1
fi

# The Makefile signs with the first Apple Development or Developer ID certificate it finds.
if ! security find-identity -v -p codesigning | grep -qE "Apple Development|Developer ID Application"; then
    echo "Note: no signing certificate found, so the build is signed ad hoc and macOS will ask for"
    echo "Accessibility access again after every build. An Apple Development certificate avoids that."
fi

if [ "$RESET_PERMISSIONS" = true ]; then
    make stop
    # ListenEvent is Input Monitoring.
    tccutil reset Accessibility com.jessestilwell.xpnd
    tccutil reset ListenEvent com.jessestilwell.xpnd
    echo "Cleared xpnd's permissions. The welcome window will ask for them again."
fi

if [ "$TEST_SNIPPETS" = true ]; then
    SNIPPETS_DIR="$HOME/Library/Application Support/xpnd"
    SNIPPETS="$SNIPPETS_DIR/snippets.yaml"
    MANUAL="$PWD/Tests/Manual"
    mkdir -p "$SNIPPETS_DIR"
    # Never lose the real snippets: anything already there is kept under a dated name.
    if [ -f "$SNIPPETS" ]; then
        BACKUP="$SNIPPETS.backup-$(date +%Y%m%d-%H%M%S)"
        cp -p "$SNIPPETS" "$BACKUP"
        echo "Backed up your snippets to: $BACKUP"
        echo "  Put them back with: mv \"$BACKUP\" \"$SNIPPETS\""
    fi
    sed "s|__MANUAL__|$MANUAL|g" "$MANUAL/test-snippets.yaml" > "$SNIPPETS.tmp"
    mv "$SNIPPETS.tmp" "$SNIPPETS"
    echo "Installed the test snippets."
fi

# Both architectures, as releases are built, so a local build matches what users get.
make run BUILD_FLAGS="--arch arm64 --arch x86_64"
echo "xpnd is running from build/xpnd.app. Look for its icon in the menu bar."
echo "If it just asked for Input Monitoring, quit it from the menu and run this again: macOS"
echo "only lets it listen after a relaunch."

if [ "$TEST_SNIPPETS" = true ]; then
    cat <<'TRY'

Try these in TextEdit:
  ;sig    signature            ;tix   input form (Esc leaves ;tix)     foo==>   foo→
  ;tmrw   tomorrow's date      ;cb    clipboard in brackets            ;loud    nested, uppercased
  ;sh     script output        ;calc  opens Calculator                 ;tab     presses Tab
  ;bad    fails: keyword stays, message explains
  Control-Option-Command-Space opens the picker.
TRY
fi

if [ "$LOG" = true ]; then
    make log
fi
