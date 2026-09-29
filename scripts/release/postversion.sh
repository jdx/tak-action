#!/usr/bin/env bash
# Tag the merged release: vX.Y.Z, the floating major tag vX, and a GitHub
# release. Adapted from jdx/mise-action, reading ./VERSION instead of
# package.json.
set -euo pipefail

VERSION="$(tr -d '[:space:]' <VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "VERSION holds '$VERSION', not X.Y.Z" >&2
  exit 1
}
MAJOR_VERSION="${VERSION%%.*}"

# The checkout uses persist-credentials: false, so plain git push needs gh's
# credential helper to authenticate with GITHUB_TOKEN.
gh auth setup-git

git tag "v$VERSION" || echo "Tag v$VERSION already exists locally"
git push origin "v$VERSION" || echo "Tag v$VERSION already exists on remote"

# Pre-v1, the floating v0 tag moves across breaking changes too. The README
# says to pin a full SHA or an exact tag for that reason.
git tag "v$MAJOR_VERSION" -f
if ! git push origin "v$MAJOR_VERSION" -f; then
  echo "Failed to push v$MAJOR_VERSION, fetching and retrying"
  git fetch origin "refs/tags/v$MAJOR_VERSION:refs/tags/v$MAJOR_VERSION" -f
  git tag "v$MAJOR_VERSION" -f
  git push origin "v$MAJOR_VERSION" -f
fi

if gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "Release v$VERSION already exists"
else
  gh release create "v$VERSION" --generate-notes --verify-tag
fi
