#!/usr/bin/env bash
# Cut a release by tagging. CI (.github/workflows/release.yml) builds the .app,
# attests provenance, and publishes the GitHub release on the tag push — this
# script only validates and pushes the tag.
#
#   usage: ./scripts/release.sh vX.Y.Z
set -euo pipefail

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: $0 vX.Y.Z" >&2; exit 2; }
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "version must match vX.Y.Z (got '$VERSION')" >&2; exit 2; }

cd "$(dirname "$0")/.."

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "working tree is dirty — commit or stash first" >&2; exit 1
fi
if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "tag $VERSION already exists" >&2; exit 1
fi

# CI builds from the pushed ref, so refuse to tag an unpushed HEAD.
git fetch -q origin
if ! git merge-base --is-ancestor HEAD origin/main; then
    echo "HEAD is not on origin/main — push your commits first" >&2; exit 1
fi

# The shipped app's version comes from Info.plist; keep it in step with the tag.
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)
if [[ "v$plist_version" != "$VERSION" ]]; then
    echo "Info.plist version ($plist_version) != ${VERSION#v} — update App/Info.plist first" >&2
    exit 1
fi

echo "→ tagging $VERSION and pushing (CI will build + publish)"
git tag "$VERSION"
git push origin "$VERSION"

echo "done. Watch: https://github.com/Fondson/vol-mixer/actions"
