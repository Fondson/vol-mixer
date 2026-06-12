# Agent instructions

## Naming

Repo, inner binary, `CFBundleExecutable`, `CFBundleIdentifier`, and the `vol-mixer-dev` signing cert are all `vol-mixer`. The shipped bundle and display name are **Volume Mixer**. The release zip is `Volume.Mixer.app.zip` (dotted, GitHub normalises spaces in asset names), but inside the zip the bundle is `Volume Mixer.app` (with a space). Quote any shell path that contains a space.

## Cutting a release

Push a tag `vX.Y.Z` and CI ([`.github/workflows/release.yml`](.github/workflows/release.yml)) builds the `.app`, attests provenance, and publishes the GitHub release.

Do this when `Sources/`, `App/`, `Package.swift`, or `scripts/build.sh` change. Skip for docs / agent-doc / `scripts/`-only changes.

Semver: patch for fixes, minor for features, major for breaking changes.

```sh
git tag -l --sort=-v:refname | head -1    # previous tag
git tag vX.Y.Z && git push origin vX.Y.Z  # trigger CI
```

## Auto-update

The in-app updater installs a release only if its `.sig` verifies against the
Ed25519 key built into [`Updater.swift`](Sources/vol-mixer/Updater.swift). Full
one-time setup (keypair + signing cert + secrets) is in
[`docs/auto-update-setup.md`](docs/auto-update-setup.md). CI degrades gracefully:
no `UPDATE_PRIVATE_KEY` secret → no `.sig` (updater stays inert); no cert secret
→ ad-hoc signing.

## Do not

- Commit build artefacts (`.build/`, `Volume Mixer.app/`, `Volume Mixer.app.zip`, `App/AppIcon.iconset/` are gitignored).
- Force-push `main` unless the user explicitly asks.
