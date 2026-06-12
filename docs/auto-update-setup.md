# Auto-update setup

One-time setup, done by the repo owner, to turn on the in-app updater. Until
it's done the updater is inert — the menu shows "Check for Updates…" but it
just reports "Updates not configured".

## What you're setting up, and why

The updater downloads the latest release and **refuses to install it unless a
detached signature verifies against a key built into the app**. That signature
is the security boundary: even if someone takes over the GitHub release, they
can't push code to users, because they can't forge your signature.

Two independent keys are involved:

| Key | Lives where | Protects against |
| --- | --- | --- |
| **Update key** (Ed25519) | public half in [`Updater.swift`](../Sources/vol-mixer/Updater.swift), private half in a CI secret | a malicious/compromised release installing code |
| **Signing cert** (self-signed, optional) | a CI secret | the macOS Audio Capture permission resetting on every update |

The signing cert is optional but recommended: without it, each release is
ad-hoc signed with a different identity, so macOS treats every update as a new
app and re-asks for Audio Capture. With one stable cert, the grant sticks.

Prerequisites: the `gh` CLI authenticated (`gh auth status`), and you're on an
up-to-date `main`.

---

## Step 1 — Update-signing keypair

Generate a keypair. The private half signs releases in CI; the public half is
baked into the app to check them.

```sh
swift - <<'EOF'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print("PRIVATE", key.rawRepresentation.base64EncodedString())
print("PUBLIC ", key.publicKey.rawRepresentation.base64EncodedString())
EOF
```

1. Copy the `PUBLIC` value into `publicKeyBase64` in
   [`Updater.swift`](../Sources/vol-mixer/Updater.swift) (replacing the
   `PASTE_…` placeholder). This is **not** secret — it ships in the app.
2. Store the `PRIVATE` value as a repo secret. It **is** secret — never commit
   it, and clear your terminal scrollback afterwards.

   ```sh
   gh secret set UPDATE_PRIVATE_KEY --repo Fondson/vol-mixer
   # paste the PRIVATE value at the prompt, press Enter
   ```

If you ever lose the private key or it leaks, generate a new pair and repeat —
older installs simply won't auto-update until their owners reinstall once.

---

## Step 2 — Stable signing certificate (recommended)

This one command makes a self-signed code-signing certificate and prints its
base64 + password. CI imports it, and [`build.sh`](../scripts/build.sh) finds it
by name (`vol-mixer-dev`) and signs every release with it.

```sh
PASS=$(openssl rand -base64 18)
printf %s "$PASS" | gh secret set SIGNING_CERT_PASSWORD --repo Fondson/vol-mixer
./scripts/make-ci-cert.sh "$PASS" 2>/dev/null | gh secret set SIGNING_CERT_P12 --repo Fondson/vol-mixer
```

That's it — the cert never touches your keychain, and the secrets are set. (Skip
this step to stay ad-hoc signed; auto-update still works, users just re-grant
Audio Capture after each update.)

---

## Step 3 — Cut the first signed release

The public key must be committed and both secrets must be set **before** you
tag, so CI signs the build.

```sh
git add -A && git commit -m "Enable signed auto-updates"
git push origin main
# Info.plist is already 0.3.0, which the release script requires to match the tag:
./scripts/release.sh v0.3.0
```

CI builds, signs the app with the stable cert, writes the Ed25519 `.sig`, and
publishes both to the release. Confirm the `.sig` is attached:

```sh
gh release view v0.3.0 --json assets --jq '.assets[].name'
# expect: Volume.Mixer.app.zip  and  Volume.Mixer.app.zip.sig
```

---

## Step 4 — Install it like a user would

The updater only acts on a copy in `/Applications` (never a dev build).

```sh
curl -fsSL https://raw.githubusercontent.com/Fondson/vol-mixer/main/scripts/install.sh | bash
```

Grant Audio Capture once when prompted.

---

## Step 5 — Prove the update works

Ship a newer version and watch the installed one pick it up.

```sh
# bump the version so the release script and the updater see something newer
/usr/bin/sed -i '' 's/<string>0.3.0<\/string>/<string>0.3.1<\/string>/' App/Info.plist
git add App/Info.plist && git commit -m "Bump to 0.3.1"
git push origin main
./scripts/release.sh v0.3.1
```

Then, in the running 0.3.0: right-click the menu-bar speaker → **Check for
Updates…**. It should offer 0.3.1, and after you confirm, install it and
relaunch. (It would also find it on its own at the next launch or daily check.)

---

## How a check works at runtime

1. Read `releases/latest` from the GitHub API; compare `tag_name` to the running
   version.
2. If newer, download `Volume.Mixer.app.zip` and `Volume.Mixer.app.zip.sig`.
3. Verify the signature against the embedded public key — **stop here if it
   doesn't match.**
4. Unzip, clear the quarantine flag, and hand off to a small helper that waits
   for the app to quit, swaps the bundle (keeping the old copy until the new one
   is in place), and relaunches.

Turn it off per-user from the menu's **Automatically Update** toggle; a manual
**Check for Updates…** is always available.
