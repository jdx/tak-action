#!/usr/bin/env bash
# Fail the job according to the comparison's outcome. Separate from the
# compare step so the report is uploaded first, whatever the outcome.
# shellcheck source=scripts/lib.sh
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

status=$(cat "$TAK_ACTION_REPORT_DIR/status" 2>/dev/null || true)
case "$status" in
  pass)
    echo "No instruction-count regression beyond the gate"
    ;;
  regressed)
    if [ "$(bool fail-on-regression "$INPUT_FAIL_ON_REGRESSION")" = true ]; then
      die "an instruction count rose beyond the gate; see the job summary"
    fi
    warn "an instruction count rose beyond the gate (reported only, because fail-on-regression is false)"
    ;;
  nothing-compared)
    # An empty comparison is not a pass. It means the base was never recorded,
    # or was recorded on a different runner class, and in both cases the gate
    # checked nothing. Under auto this fails too: either tak failed it, or the
    # installed tak is too old to have decided anything.
    if [ "$(nothing_compared_policy "$INPUT_FAIL_ON_NOTHING_COMPARED")" != false ]; then
      die "nothing was compared: the base commit has no measurement on this runner class. Record the base branch first (mode: record), set [gate] allow_empty = true in tak.toml on the base branch (tak releases with that setting), or set fail-on-nothing-compared: false"
    fi
    warn "nothing was compared (allowed, because fail-on-nothing-compared is false)"
    ;;
  nothing-compared-allowed)
    # tak passed an empty comparison because allow_empty is on in the base's
    # tak.toml. auto follows that; true overrides it.
    if [ "$(nothing_compared_policy "$INPUT_FAIL_ON_NOTHING_COMPARED")" = true ]; then
      die "nothing was compared. tak allowed it (allow_empty is on), but fail-on-nothing-compared is true"
    fi
    warn "nothing was compared; passing because tak's allow_empty setting is on. That is expected on a new runner class, for a new benchmark or a first recording, and is also what unrecorded or unfetched history looks like"
    ;;
  *)
    die "the comparison did not run; see the errors above and the job summary"
    ;;
esac
