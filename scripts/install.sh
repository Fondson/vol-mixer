#!/usr/bin/env bash
# Download + install the latest prebuilt Volume Mixer.app into /Applications.
# Requires only curl, unzip, xattr, open — all ship with macOS.
set -euo pipefail

URL="https://github.com/Fondson/vol-mixer/releases/latest/download/Volume%20Mixer.app.zip"
ZIP="${TMPDIR:-/tmp}/Volume Mixer.app.zip"
DEST="/Applications"
APP="$DEST/Volume Mixer.app"

echo "→ downloading latest release"
curl -fL "$URL" -o "$ZIP"

echo "→ installing to $DEST"
unzip -qo "$ZIP" -d "$DEST"
# Strip the quarantine attr so Gatekeeper doesn't block the ad-hoc-signed bundle.
xattr -cr "$APP"
rm -f "$ZIP"

# Clean up the legacy pre-rename bundle if present — same bundle ID, stale name.
if [[ -d "$DEST/vol-mixer.app" ]]; then
    echo "→ removing legacy $DEST/vol-mixer.app"
    rm -rf "$DEST/vol-mixer.app"
fi

echo "→ launching"
open "$APP"

echo
echo "done. Volume Mixer is in the menu bar (speaker icon)."
echo "First time you move a slider, grant Audio Capture in System Settings."
