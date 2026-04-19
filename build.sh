#!/usr/bin/env bash
# Build vol-mixer and wrap it into a signed .app bundle that can obtain the
# Audio Capture TCC grant.
set -euo pipefail

CONFIG=${CONFIG:-release}
APP=vol-mixer.app
BIN=vol-mixer
CONTENTS=$APP/Contents
MACOS=$CONTENTS/MacOS
RES=$CONTENTS/Resources

cd "$(dirname "$0")"

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH=".build/$CONFIG/$BIN"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "build produced no binary at $BIN_PATH" >&2
    exit 1
fi

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN_PATH" "$MACOS/$BIN"
cp App/Info.plist "$CONTENTS/Info.plist"

CERT_NAME="vol-mixer-dev"
if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    IDENTITY="$CERT_NAME"
    echo "→ codesigning with persistent identity '$CERT_NAME' (TCC grant survives rebuilds)"
else
    IDENTITY="-"
    echo "→ ad-hoc codesigning (Audio Capture prompt will reappear on each rebuild)"
    echo "  run ./scripts/setup-signing.sh once to persist the TCC grant"
fi
codesign --force --deep --sign "$IDENTITY" --options runtime "$APP"
codesign --verify --verbose=2 "$APP"

echo "→ done"
echo
echo "Launch:  open $APP"
echo "Or drag $APP into /Applications for a permanent home."
echo
echo "On first use the app will prompt for Audio Capture permission."
echo "Grant it in System Settings › Privacy & Security › Audio Capture,"
echo "then quit and relaunch the app."
