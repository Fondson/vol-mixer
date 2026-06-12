#!/usr/bin/env bash
# Generate a standalone self-signed code-signing certificate (CN vol-mixer-dev)
# as a .p12, and print the base64 + password to store as the SIGNING_CERT_P12 /
# SIGNING_CERT_PASSWORD repo secrets. CI imports it so every release is signed
# with one stable identity — which is what lets the Audio Capture permission
# survive updates. This does NOT touch your keychain. Run once; keep the output
# secret and don't commit it.
set -euo pipefail

CERT_NAME="vol-mixer-dev"
PASSWORD="${1:-$(openssl rand -base64 18)}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

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

# Apple's `security` tool only accepts the older .p12 encryption format. OpenSSL
# 3 needs -legacy to write it; LibreSSL (the macOS default) writes it without the flag.
if ! openssl pkcs12 -export -legacy -out "$tmp/cert.p12" \
        -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -name "$CERT_NAME" -passout "pass:$PASSWORD" >/dev/null 2>&1; then
    openssl pkcs12 -export -out "$tmp/cert.p12" \
        -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -name "$CERT_NAME" -passout "pass:$PASSWORD" >/dev/null
fi

b64=$(base64 -i "$tmp/cert.p12")

cat >&2 <<EOF
Add these two GitHub repo secrets (Settings → Secrets and variables → Actions),
then delete this terminal's scrollback:

  SIGNING_CERT_PASSWORD = $PASSWORD

Or with the gh CLI:

  printf %s '$PASSWORD' | gh secret set SIGNING_CERT_PASSWORD --repo Fondson/vol-mixer
  ./scripts/make-ci-cert.sh '$PASSWORD' | gh secret set SIGNING_CERT_P12 --repo Fondson/vol-mixer

The base64 of SIGNING_CERT_P12 is printed on stdout below.
EOF
echo "$b64"
