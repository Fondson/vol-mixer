#!/usr/bin/env bash
# Cut a release: build, zip (codesign-preserving), tag, push tag,
# and upload the asset to a new GitHub release.
#
#   usage: ./scripts/release.sh vX.Y.Z
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 vX.Y.Z" >&2
    exit 2
fi
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "version must match vX.Y.Z (got '$VERSION')" >&2
    exit 2
fi

cd "$(dirname "$0")/.."

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "working tree is dirty — commit or stash first" >&2
    exit 1
fi

if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "tag $VERSION already exists" >&2
    exit 1
fi

echo "→ clean build"
rm -rf .build
./scripts/build.sh

echo "→ zipping (ditto preserves codesign)"
rm -f vol-mixer.app.zip
ditto -c -k --keepParent vol-mixer.app vol-mixer.app.zip

echo "→ tagging $VERSION"
git tag "$VERSION"
git push origin "$VERSION"

echo "→ creating GitHub release"
gh release create "$VERSION" vol-mixer.app.zip \
    --title "$VERSION" \
    --generate-notes

echo
echo "done: https://github.com/Fondson/vol-mixer/releases/tag/$VERSION"
