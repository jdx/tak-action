#!/usr/bin/env bash
# The check-run conclusion comment mode publishes, for every status and
# policy. End to end, comment mode needs a workflow_run event and a GitHub App
# token; the choice itself is a function of three strings, checked here.
set -euo pipefail
export GITHUB_ACTION_PATH="${GITHUB_ACTION_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
export RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d)}"
# shellcheck source=scripts/lib.sh
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

failed=0
# status  fail-on-regression  fail-on-nothing-compared  want
while read -r status on_regression on_nothing want; do
  got=$(check_conclusion "$status" "$on_regression" "$on_nothing")
  if [ "$got" = "$want" ]; then
    echo "ok   $status regression=$on_regression nothing=$on_nothing -> $got"
  else
    echo "FAIL $status regression=$on_regression nothing=$on_nothing -> $got, want $want"
    failed=1
  fi
done <<'CASES'
pass                     true  auto  success
regressed                true  auto  failure
regressed                false auto  neutral
nothing-compared         true  auto  failure
nothing-compared         true  true  failure
nothing-compared         true  false neutral
nothing-compared-allowed true  auto  neutral
nothing-compared-allowed true  false neutral
nothing-compared-allowed true  true  failure
error                    false false failure
something-unknown        false false failure
CASES

[ "$(check_title nothing-compared-allowed)" = "Nothing was compared (allowed by allow_empty)" ] || {
  echo "FAIL title for nothing-compared-allowed"
  failed=1
}
exit "$failed"
