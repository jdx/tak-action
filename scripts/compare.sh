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
  # told apart by its exit status and the text of its report. This is a
  # stopgap until it does.
  #
  # An empty comparison is recognised by its text whatever the exit status:
  # released versions exit 0 for it, and newer ones may exit non-zero unless
  # given --allow-empty. The action never passes that flag and decides with
  # fail-on-nothing-compared instead, so both behave the same here.
  #
  # Otherwise the exit status is the primary signal. If the wording of the
  # gate line ever changes, a regression falls through to "error" and still
  # fails, rather than passing.
  if [ -z "$rc" ]; then
    : # already explained
  elif [ ! -s "$report" ]; then
    explain "tak compare exited with status $rc and printed no report."
  elif grep -Fq '**Nothing was compared' "$report"; then
    status=nothing-compared
  elif [ "$rc" -eq 0 ]; then
    status=pass
  elif grep -Fq 'benchmark(s) above the ' "$report"; then
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
