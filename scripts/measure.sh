#!/usr/bin/env bash
# Run the caller's build-and-measure command.
#
# This is the one place the action runs a shell over caller-supplied text, and
# it is the caller's own workflow input, passed through the environment rather
# than interpolated into the script. tak itself still never starts a shell for
# a measured command: `tak run` spawns each subject directly, so the shell
# here is outside every measurement.
# shellcheck source=scripts/lib.sh
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

enter_working_directory
use_tak

if [ -n "${INPUT_RUNNER_CLASS:-}" ]; then
  export TAK_RUNNER="$INPUT_RUNNER_CLASS"
fi

before=$(git rev-parse --verify 'HEAD^{commit}')
# Overwritten below. Left as "started" only if this step dies part-way, which
# the compare step reports rather than mistaking for a clean run.
state_set MEASURE_EXIT started
echo "::group::$INPUT_RUN"
set +e
bash -euo pipefail -c "$INPUT_RUN"
rc=$?
set -e
echo "::endgroup::"
after=$(git rev-parse --verify 'HEAD^{commit}')

state_set MEASURE_EXIT "$rc"
if [ "$before" != "$after" ]; then
  # The measurement was recorded against whatever HEAD was at the time, so it
  # is no longer attached to the commit this job was started for.
  state_set MEASURE_EXIT moved
  die "the run command moved HEAD from $before to $after; measure the commit that was checked out"
fi

[ "$rc" -eq 0 ] || die "the run command exited with status $rc"
