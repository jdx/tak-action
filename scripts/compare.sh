#!/usr/bin/env bash
# Compare the measured head against the base, classify the result, and
# package the report for the job summary and for the comment job.
#
# This step never fails on its own account. It runs even after an earlier step
# failed, so that the report says what went wrong and the comment job has
# something to post; the gate step decides whether the job fails.
# shellcheck source=scripts/lib.sh
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

out=$TAK_ACTION_REPORT_DIR
rm -rf "$out"
mkdir -p "$out"
report="$out/report.md"

head=$(state_get HEAD_SHA)
base=$(state_get BASE_SHA)
wd=$(state_get PREPARED_WD)
measure_exit=$(state_get MEASURE_EXIT)
status=""

explain() {
  status=error
  printf '**The comparison did not run.** %s\n' "$1" >"$report"
}

if [ -z "$wd" ] || ! is_sha "$head" || ! is_sha "$base"; then
  explain "Installing tak or resolving the base commit failed; see the job log."
elif [ "$(bool measure "$INPUT_MEASURE")" = true ] && [ "$measure_exit" != 0 ]; then
  case "$measure_exit" in
    "" | started) explain "The run command did not finish; see the job log." ;;
    moved) explain "The run command moved HEAD, so the measurement is not of the commit under review." ;;
    *) explain "The run command exited with status $measure_exit; see the job log." ;;
  esac
elif ! cd "$wd"; then
  explain "The working directory disappeared before the comparison."
else
  use_tak
  args=(compare --rev "$head")
  if [ -n "${INPUT_GATE_PCT:-}" ]; then
    args+=(--gate-pct "$INPUT_GATE_PCT")
  fi

  # One benchmark name per line, each passed whole as its own --accept:
  # names are unrestricted, so nothing is split or trimmed. Only wholly empty
  # lines are dropped, which a YAML block scalar leaves at the end.
  accept=()
  while IFS= read -r name || [ -n "$name" ]; do
    [ -z "$name" ] || accept+=("$name")
  done <<<"${INPUT_ACCEPT:-}"
  accept_unsupported=false
  if [ "${#accept[@]}" -gt 0 ]; then
    if tak compare --help 2>/dev/null | grep -Eq -- '(^|[[:space:]])--accept([[:space:]=<]|$)'; then
      for name in "${accept[@]}"; do
        args+=(--accept "$name")
      done
    else
      accept_unsupported=true
    fi
  fi
  args+=("$base")

  # Off unless this workflow turns it on. tak.toml comes from the checkout
  # under test, so a pull request could otherwise enable Tak-Accept trailers
  # in its own commits and waive its own gate; the environment takes
  # precedence over the file. Harmless for tak releases that predate it.
  if [ "$(bool accept-trailers "${INPUT_ACCEPT_TRAILERS:-false}")" = true ]; then
    export TAK_ACCEPT_TRAILERS=1
  else
    export TAK_ACCEPT_TRAILERS=0
  fi

  if [ "$accept_unsupported" = true ]; then
    # Failing rather than comparing without the acceptances: a maintainer who
    # accepted a regression should not see the gate quietly ignore that.
    explain "The accept input names benchmarks, but $(tak --version) has no \`tak compare --accept\`. Upgrade tak, or remove accept."
    rc=""
  else
    # No token: this runs after the pull request's code has. tak refreshes
    # the notes from origin, and when that unauthenticated fetch fails (a
    # private repository) it falls back to the notes the prepare step already
    # fetched.
    set +e
    GIT_TERMINAL_PROMPT=0 tak "${args[@]}" >"$report" 2>"$TAK_ACTION_DIR/compare.err"
    rc=$?
    set -e
    cat "$TAK_ACTION_DIR/compare.err" >&2
  fi

  # tak has no machine-readable comparison output yet, so the outcomes are
  # told apart by its exit status and by lines tak writes itself. This is a
  # stopgap until it has one.
  #
  # The report is not safe to search as a whole. It echoes text the pull
  # request controls: benchmark names from its tak.toml, and in newer
  # releases Tak-Accept trailer values from its commits. Unanchored, a name
  # such as `**Nothing was compared` turned a clean run into a failure.
  # Anchoring to the start of a line is not enough either: tak 0.0.13 writes
  # a newline inside a benchmark name as a real newline, so a name can start
  # a line of its own. So each verdict is read only where no echoed text can
  # reach:
  #
  # - Nothing compared: the first line of the report, which tak writes
  #   before any name, in 0.0.13 and in releases that exit non-zero for it
  #   (the action never passes --allow-empty; fail-on-nothing-compared
  #   decides). Checked whatever the exit status, because released versions
  #   exit 0 for it. Not tak's stderr: that is checked before the exit status,
  #   so text reaching stderr could relabel a real regression as "nothing
  #   compared", which fail-on-nothing-compared: false would then pass.
  # - Regressed: a non-zero exit, tak's gate error on stderr (a count and a
  #   threshold, never a benchmark name), and the verdict line in the report,
  #   anchored to the start of a line. Both, so a stray match in one alone
  #   cannot turn another failure into a regression.
  #
  # A clean run needs exit status 0, which no report text can produce. If
  # any wording changes, the outcome falls through to "error" and still
  # fails, rather than passing.
  err="$TAK_ACTION_DIR/compare.err"

  # Whether this tak has the allow_empty setting, from `tak settings`, which
  # lists every setting by name at the start of a line. Run outside the
  # repository, so no tak.toml is read and nothing the pull request controls
  # can reach the output.
  #
  # A probe that fails is not the same answer as a tak without the setting,
  # though both fall back to failing the empty comparison: say so, with tak's
  # own last word, so that is not mistaken for an old tak.
  tak_has_allow_empty() {
    local settings probe_rc=0 probe_err="$TAK_ACTION_DIR/settings.err"
    settings=$(cd "${RUNNER_TEMP:?}" && tak settings 2>"$probe_err") || probe_rc=$?
    if [ "$probe_rc" -ne 0 ]; then
      warn "could not tell whether this tak has the allow_empty setting: 'tak settings' exited with status $probe_rc ($(tail -n1 "$probe_err")). Treating it as a tak without the setting, so this empty comparison is not treated as allowed"
      return 1
    fi
    grep -Eq '^allow_empty[[:space:]]' <<<"$settings"
  }
  if [ -z "$rc" ]; then
    : # already explained
  elif [ ! -s "$report" ]; then
    explain "tak compare exited with status $rc and printed no report."
  elif [[ "$(head -n1 "$report")" == '**Nothing was compared, and so nothing was gated.**'* ]]; then
    # tak releases with an allow_empty setting exit 0 for an empty
    # comparison only when that setting, read from the base's tak.toml, is
    # on: tak has already decided it should pass. Older releases exit 0 for
    # every empty comparison and decided nothing, so the same exit 0 means
    # nothing there. The exit status alone cannot tell the two apart; what
    # the installed tak supports can.
    if [ "$rc" -eq 0 ] && tak_has_allow_empty; then
      status=nothing-compared-allowed
    else
      status=nothing-compared
    fi
  elif [ "$rc" -eq 0 ]; then
    status=pass
  elif grep -Eq '^Error: [0-9]+ benchmark\(s\) regressed (by more than|beyond their gate)' "$err" &&
    grep -Eq '^\*\*[0-9]+ benchmark\(s\) above (the [^ ]+% gate|their gate)' "$report"; then
    status=regressed
  else
    status=error
    {
      echo
      echo "**tak compare exited with status $rc.**"
      echo
      echo '```text'
      head -c 4000 "$TAK_ACTION_DIR/compare.err"
      echo
      echo '```'
    } >>"$report"
  fi
fi

pr_number=""
if [ -f "${GITHUB_EVENT_PATH:-}" ]; then
  pr_number=$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")
fi

# One value per file, each validated by the reader. The comment job treats
# every byte here as untrusted, because the job that wrote it ran the pull
# request's code.
echo "$TAK_ACTION_REPORT_FORMAT" >"$out/format"
echo "$status" >"$out/status"
echo "$head" >"$out/head-sha"
echo "$base" >"$out/base-sha"
echo "$pr_number" >"$out/pr-number"

case "$status" in
  pass) headline="No instruction-count regression beyond the gate." ;;
  regressed) headline="An instruction count rose beyond the gate." ;;
  nothing-compared) headline="Nothing was compared: no benchmark was measured on both sides." ;;
  nothing-compared-allowed) headline="Nothing was compared, which tak allows here (allow_empty)." ;;
  *) headline="The comparison did not run." ;;
esac

{
  echo "### tak: $headline"
  echo
  cat "$report"
  echo
  echo "<sub>\`${head:0:12}\` compared with \`${base:0:12}\`. Measured in this job and not pushed to the history.</sub>"
} >>"${GITHUB_STEP_SUMMARY:?}"
cat "$report"

output status "$status"
output report "$report"
output head-sha "$head"
output base-sha "$base"

# Consumed, so a second comparison in the same job starts from scratch rather
# than reusing this one's base. Every invocation reinstalls (from its own
# cache) and so writes TAK afresh.
rm -f "$TAK_ACTION_STATE"
