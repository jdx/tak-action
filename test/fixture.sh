#!/usr/bin/env bash
# A throwaway project for the action's own tests: a bare repository standing
# in for GitHub, and a clone of it with two tiny benchmarks. Pushing notes to a
# local bare repository exercises the same `tak push` path without a token.
#
#   fixture.sh init ROOT               create ROOT/origin.git and ROOT/work
#   fixture.sh commit ROOT N MESSAGE   set the loop to N iterations and commit
set -euo pipefail

cmd=$1
root=$2
work="$root/work"

commit() {
  local n=$1 message=$2
  echo "$n" >"$work/iterations"
  git -C "$work" add -A
  git -C "$work" -c user.name=test -c user.email=test@localhost \
    commit --quiet --allow-empty -m "$message"
  git -C "$work" rev-parse HEAD
}

case "$cmd" in
  init)
    rm -rf "$root"
    mkdir -p "$root"
    git init --quiet --bare --initial-branch=main "$root/origin.git"
    git init --quiet --initial-branch=main "$work"
    git -C "$work" remote add origin "$root/origin.git"
    cat >"$work/tak.toml" <<'TOML'
# Distinct from anything a real project records, so the fixture's series can
# never be mistaken for, or compared with, a real one.
[runner]
class = "tak-action-fixture"

[gate]
pct = 1.0

# The startup control: almost no work, so it should never move.
[bench.true]
cmd = "/bin/true"
runs = 3

# The representative path: its cost scales with the committed iteration count,
# which is how a test commit introduces a regression.
[bench.loop]
cmd = ["sh", "loop.sh"]
runs = 3
TOML
    cat >"$work/loop.sh" <<'SH'
n=$(cat iterations)
i=0
while [ "$i" -lt "$n" ]; do
  i=$((i + 1))
done
SH
    commit 200 "initial" >/dev/null
    git -C "$work" push --quiet origin main
    git -C "$work" rev-parse HEAD
    ;;
  commit)
    commit "$3" "$4"
    ;;
  *)
    echo "unknown command $cmd" >&2
    exit 2
    ;;
esac
