#!/bin/sh
# Installs (or uninstalls) build/Lite.app into an Applications folder.
#
# Usage: scripts/install.sh <built .app> <install dir>       install / update
#        scripts/install.sh --uninstall <install dir>         remove
#
# - Quits a running Lite first (it asks before closing tabs that are busy).
# - Only ever replaces a bundle whose identifier is Lite's, never anything else.
# - Registers with LaunchServices so Spotlight/Finder/Dock see the new version.
set -eu

BUNDLE_ID=com.liamnewmarch.lite
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ "${1:-}" = "--uninstall" ]; then
    MODE=uninstall
    DEST_DIR=${2:?install dir}
else
    MODE=install
    SRC=${1:?built .app}
    DEST_DIR=${2:?install dir}
fi
DEST="$DEST_DIR/Lite.app"

# Refuse to touch a different app that happens to be called Lite.app.
if [ -e "$DEST" ]; then
    existing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || echo "?")
    if [ "$existing" != "$BUNDLE_ID" ]; then
        echo "error: $DEST exists but isn't Lite (bundle id: $existing); not touching it" >&2
        exit 1
    fi
fi

# Quit a running Lite (the installed copy or a dev build) and wait for it to exit.
if osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null | grep -q true; then
    echo "Quitting running Lite…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    i=0
    while osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null | grep -q true; do
        i=$((i + 1))
        if [ $i -gt 50 ]; then
            echo "error: Lite is still running (a quit confirmation may be open); quit it and retry" >&2
            exit 1
        fi
        sleep 0.2
    done
fi

if [ "$MODE" = uninstall ]; then
    if [ -e "$DEST" ]; then
        "$LSREGISTER" -u "$DEST" 2>/dev/null || true
        rm -rf "$DEST"
        echo "Removed $DEST (your config in ~/.config/lite is untouched)"
    else
        echo "Nothing to remove at $DEST"
    fi
    exit 0
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
# ditto preserves the bundle exactly (permissions, signature, extended attributes).
ditto "$SRC" "$DEST"
codesign --verify --strict "$DEST"
"$LSREGISTER" -f "$DEST"
echo "Installed $DEST"
