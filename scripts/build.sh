#!/usr/bin/env bash
# Build vol-mixer into a signed .app bundle.
#
# On first run, bootstraps a persistent self-signed code-signing identity via
# setup-signing.sh so the TCC Audio Capture grant survives rebuilds. Falls
# back to ad-hoc signing only if the bootstrap fails.
set -euo pipefail

CONFIG=${CONFIG:-release}
APP=vol-mixer.app
BIN=vol-mixer
CERT_NAME="vol-mixer-dev"

cd "$(dirname "$0")/.."

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH=".build/$CONFIG/$BIN"
[[ -x "$BIN_PATH" ]] || { echo "no binary at $BIN_PATH" >&2; exit 1; }

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN"
cp App/Info.plist "$APP/Contents/Info.plist"

# Ensure the persistent signing cert exists locally. setup-signing.sh is
# idempotent. Skip in CI — runners are ephemeral; ad-hoc signing is fine.
if [[ -z "${CI:-}" ]] && ! security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "→ bootstrapping persistent signing identity (one-time)"
    ./scripts/setup-signing.sh
fi

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    IDENTITY="$CERT_NAME"
else
    IDENTITY="-"
    echo "→ bootstrap failed — ad-hoc signing (TCC grant will reset each rebuild)"
fi

echo "→ codesigning ($IDENTITY)"
codesign --force --deep --sign "$IDENTITY" --options runtime "$APP"
codesign --verify "$APP"

echo "→ done. open $APP"
