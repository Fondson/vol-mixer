# Agent instructions

## Cutting a release

Push a tag `vX.Y.Z` and CI ([`.github/workflows/release.yml`](.github/workflows/release.yml)) builds the `.app`, attests provenance, and publishes the GitHub release.

Do this when `Sources/`, `App/`, `Package.swift`, or `scripts/build.sh` change. Skip for docs / agent-doc / `scripts/`-only changes.

Semver: patch for fixes, minor for features, major for breaking changes.

```sh
git tag -l --sort=-v:refname | head -1    # previous tag
git tag vX.Y.Z && git push origin vX.Y.Z  # trigger CI
```

## Do not

- Commit build artefacts (`.build/`, `vol-mixer.app/`, `vol-mixer.app.zip` are gitignored).
- Force-push `main` unless the user explicitly asks.
