#!/bin/sh
# Installs (or uninstalls) build/Lite.app into an Applications folder.
#
# Usage: scripts/install.sh <built .app> <install dir>       install / update
#        scripts/install.sh --uninstall <install dir>         remove
#
# - Works while Lite is running (even from inside it); restart Lite afterwards.
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

# Lite may be running, often because this script is running *inside* it. It isn't
# quit: that would hang up its tabs and kill this script half way. Replacing a running
# app's bundle is safe on macOS (rm + copy makes new files; the running copy keeps the
# old ones open), and the new version starts the next time Lite opens.
RUNNING=false
if osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null | grep -q true; then
    RUNNING=true
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
if [ "$RUNNING" = true ]; then
    echo "Lite is running: quit it (Cmd-Q) and open it again to use the new version."
fi
