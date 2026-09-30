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

# Tag only what is on main. release.yml checks out the release PR's merge
# commit; if that is not on main (a merge to another branch, or a checkout of
# the synthetic merge ref), refuse rather than tag a commit users can't reach.
git fetch --quiet origin main
head_sha="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$head_sha" origin/main || {
  echo "HEAD $head_sha is not on main; refusing to tag it" >&2
  exit 1
}

git tag "v$VERSION" || echo "Tag v$VERSION already exists locally"
git push origin "v$VERSION" || echo "Tag v$VERSION already exists on remote"

# Pre-v1, the floating v0 tag moves across breaking changes too. The README
# says to pin a full SHA or an exact tag for that reason.
#
# Only forward: a rerun of an older release's workflow recreates its exact tag
# and release if they are missing, but must not drag vN back from a newer
# release. The remote's tags decide, since this checkout may predate them.
git fetch --quiet --tags --force origin
highest="$(git tag --list "v$MAJOR_VERSION.*.*" | grep -E "^v$MAJOR_VERSION\.[0-9]+\.[0-9]+$" | sort -V | tail -1)"
if [ "$highest" != "v$VERSION" ]; then
  echo "v$VERSION is not the newest v$MAJOR_VERSION release ($highest is); leaving v$MAJOR_VERSION alone"
else
  git tag "v$MAJOR_VERSION" -f
  if ! git push origin "v$MAJOR_VERSION" -f; then
    echo "Failed to push v$MAJOR_VERSION, fetching and retrying"
    git fetch origin "refs/tags/v$MAJOR_VERSION:refs/tags/v$MAJOR_VERSION" -f
    git tag "v$MAJOR_VERSION" -f
    git push origin "v$MAJOR_VERSION" -f
  fi
fi

if gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "Release v$VERSION already exists"
else
  gh release create "v$VERSION" --generate-notes --verify-tag
fi
