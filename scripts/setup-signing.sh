#!/usr/bin/env bash
# One-time setup: generates a self-signed code-signing certificate and imports
# it into the login keychain so build.sh can sign vol-mixer with a stable
# identity. Stable identity = TCC keeps the Audio Capture grant across rebuilds.
#
# Safe to re-run — it no-ops if the cert already exists.
set -euo pipefail

CERT_NAME="vol-mixer-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# find-identity -v filters on trust and would miss a self-signed cert, so
# probe for the bare cert. codesign signs fine against it either way.
if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "→ signing identity '$CERT_NAME' already present — nothing to do"
    exit 0
fi

echo "→ creating self-signed code-signing certificate '$CERT_NAME'"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/cert.conf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3

[ dn ]
CN = $CERT_NAME
O = Local
C = US

[ v3 ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -config "$tmp/cert.conf" -extensions v3 >/dev/null 2>&1

# Modern macOS `security import` is inconsistent with empty PKCS#12
# passwords, so use a throwaway password that both sides agree on.
P12_PASS="vol-mixer-setup"

# -legacy uses PBE-SHA1-3DES + RC2 — the only PBE algs Apple's `security` tool
# accepts. OpenSSL 3's default AES-256 PBE produces "MAC verification failed".
openssl pkcs12 -export -legacy -out "$tmp/cert.p12" \
    -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "$CERT_NAME" -passout "pass:$P12_PASS" >/dev/null

# -T /usr/bin/codesign pre-authorises codesign to use the private key without
# a keychain prompt on every invocation (one-off prompt may still appear the
# first time — click "Always Allow").
security import "$tmp/cert.p12" \
    -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

echo "→ imported into $KEYCHAIN"
echo
echo "Next:"
echo "  1. ./build.sh                       # now signs with '$CERT_NAME'"
echo "  2. open vol-mixer.app"
echo "  3. Grant Audio Capture permission ONCE. Subsequent rebuilds keep it."
