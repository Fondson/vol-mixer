#!/usr/bin/env bash
# Download + install the latest prebuilt vol-mixer.app into /Applications.
# Requires only curl, unzip, xattr, open — all ship with macOS.
set -euo pipefail

URL="https://github.com/Fondson/vol-mixer/releases/latest/download/vol-mixer.app.zip"
ZIP="${TMPDIR:-/tmp}/vol-mixer.app.zip"
DEST="/Applications"

echo "→ downloading latest release"
curl -fL "$URL" -o "$ZIP"

echo "→ installing to $DEST"
unzip -qo "$ZIP" -d "$DEST"
# Strip the quarantine attr so Gatekeeper doesn't block the ad-hoc-signed bundle.
xattr -cr "$DEST/vol-mixer.app"
rm -f "$ZIP"

echo "→ launching"
open "$DEST/vol-mixer.app"

echo
echo "done. vol-mixer is in the menu bar (speaker icon)."
echo "First time you move a slider, grant Audio Capture in System Settings."
