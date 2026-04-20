# Agent instructions

Guidance for AI coding agents (Claude, Codex, etc.) working in this repo.

## Release after shipping code changes

The README one-liner pulls `vol-mixer.app.zip` from the latest GitHub Release. When you push code changes to `main`, cut a new release so users installing via the one-liner get your fix.

Trigger: any change under `Sources/`, `App/`, `Package.swift`, `scripts/build.sh`, or anything else that affects the shipped `.app` binary.

Skip: README-only, docs-only, `scripts/` changes that don't affect the binary, `.gitignore`, `AGENTS.md` / `CLAUDE.md`.

## How to cut a release

1. Check the latest tag:
   ```sh
   git tag -l --sort=-v:refname | head -1
   ```
2. Pick the next version (semver):
   - patch (`v0.1.0` → `v0.1.1`) for bug fixes
   - minor (`v0.1.0` → `v0.2.0`) for user-visible features
   - major (`v0.1.0` → `v1.0.0`) for breaking changes (CLI flags renamed, install path changed, etc.)
3. Run:
   ```sh
   ./scripts/release.sh vX.Y.Z
   ```
   This cleans `.build/`, runs `scripts/build.sh`, zips `vol-mixer.app` with `ditto` (codesign-preserving), tags, pushes the tag, and creates the GitHub release with the zip attached.
4. Confirm:
   ```sh
   curl -sLI -o /dev/null -w "%{http_code}\n" \
     https://github.com/Fondson/vol-mixer/releases/latest/download/vol-mixer.app.zip
   ```
   Expect `200`.

## Release preconditions

`release.sh` refuses to run if:
- the version arg is missing or not in `vX.Y.Z` form
- the working tree has uncommitted changes
- the tag already exists

If any of these fail, fix them before retrying — don't `--force` anything.

## Do not

- Force-push `main` unless the user explicitly asks.
- Commit build artefacts — `.build/`, `vol-mixer.app/`, `vol-mixer.app.zip` are gitignored.
