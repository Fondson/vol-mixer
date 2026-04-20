# Agent instructions

## Naming

Repo, inner binary, `CFBundleExecutable`, `CFBundleIdentifier`, and the `vol-mixer-dev` signing cert are all `vol-mixer`. The shipped bundle, install path, release asset, and user-visible display name are **Volume Mixer** — note the space in `Volume Mixer.app` / `Volume Mixer.app.zip`. Quote paths in shell; URL-encode as `Volume%20Mixer.app.zip`.

## Cutting a release

Push a tag `vX.Y.Z` and CI ([`.github/workflows/release.yml`](.github/workflows/release.yml)) builds the `.app`, attests provenance, and publishes the GitHub release.

Do this when `Sources/`, `App/`, `Package.swift`, or `scripts/build.sh` change. Skip for docs / agent-doc / `scripts/`-only changes.

Semver: patch for fixes, minor for features, major for breaking changes.

```sh
git tag -l --sort=-v:refname | head -1    # previous tag
git tag vX.Y.Z && git push origin vX.Y.Z  # trigger CI
```

## Do not

- Commit build artefacts (`.build/`, `Volume Mixer.app/`, `Volume Mixer.app.zip`, `App/AppIcon.iconset/` are gitignored).
- Force-push `main` unless the user explicitly asks.
