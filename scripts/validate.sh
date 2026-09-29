#!/usr/bin/env bash
# Check every input before anything is installed, fetched or measured. A
# mistake found after a ten-minute build is a mistake found too late.
# shellcheck source=scripts/lib.sh
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

case "${INPUT_MODE:-}" in
  install | prepare | record | compare | comment) ;;
  "") die "input 'mode' is required: one of record, compare, comment, prepare, install" ;;
  *) die "input 'mode' must be one of record, compare, comment, prepare, install; got '$INPUT_MODE'" ;;
esac

for pair in \
  "install:${INPUT_INSTALL:-}" \
  "install-valgrind:${INPUT_INSTALL_VALGRIND:-}" \
  "measure:${INPUT_MEASURE:-}" \
  "push:${INPUT_PUSH:-}" \
  "summary:${INPUT_SUMMARY:-}" \
  "upload-artifact:${INPUT_UPLOAD_ARTIFACT:-}" \
  "fail-on-regression:${INPUT_FAIL_ON_REGRESSION:-}" \
  "fail-on-nothing-compared:${INPUT_FAIL_ON_NOTHING_COMPARED:-}" \
  "comment:${INPUT_COMMENT:-}" \
  "check:${INPUT_CHECK:-}" \
  "accept-trailers:${INPUT_ACCEPT_TRAILERS:-}"; do
  bool "${pair%%:*}" "${pair#*:}" >/dev/null
done

if [ "$INPUT_MODE" != comment ]; then
  if [ "$(bool install "$INPUT_INSTALL")" = true ] && [ -z "${INPUT_VERSION:-}" ]; then
    # No default on purpose. Changing the measuring instrument can put a step
    # in the series that looks like a change in the subject, so the version
    # moves only when someone decides it should.
    die "input 'version' is required (for example '0.0.13'); pin tak and upgrade it deliberately"
  fi
  if [ -n "${INPUT_VERSION:-}" ] && ! [[ "${INPUT_VERSION#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    die "input 'version' must be a release version such as '0.0.13', got '$INPUT_VERSION'"
  fi
fi

if [ -n "${INPUT_GATE_PCT:-}" ] && ! [[ "$INPUT_GATE_PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  die "input 'gate-pct' must be a non-negative number such as '1.0', got '$INPUT_GATE_PCT'"
fi

if [ -n "${INPUT_HEAD_SHA:-}" ] && ! is_sha "$INPUT_HEAD_SHA"; then
  die "input 'head-sha' must be a full commit SHA, got '$INPUT_HEAD_SHA'"
fi

# Artifact names and comment keys end up in file paths, API queries and an
# HTML comment; keep them to characters that are inert in all three.
if ! [[ "${INPUT_ARTIFACT_NAME:-}" =~ ^[A-Za-z0-9._-]{1,100}$ ]]; then
  die "input 'artifact-name' must match [A-Za-z0-9._-]{1,100}, got '${INPUT_ARTIFACT_NAME:-}'"
fi
if ! [[ "${INPUT_COMMENT_KEY:-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
  die "input 'comment-key' must match [A-Za-z0-9._-]{1,64}, got '${INPUT_COMMENT_KEY:-}'"
fi

if [ "$INPUT_MODE" = comment ]; then
  [ "${GITHUB_EVENT_NAME:-}" = workflow_run ] ||
    die "mode 'comment' runs only in a workflow triggered by workflow_run, got event '${GITHUB_EVENT_NAME:-}'. See the security model in the README."
  if [ "$(bool check "$INPUT_CHECK")" = true ] && [ -z "${INPUT_CHECK_NAME:-}" ]; then
    die "input 'check-name' must not be empty while 'check' is true"
  fi
  [ -n "${INPUT_TOKEN:-}" ] || die "input 'token' is required in comment mode"
fi

if [ "$INPUT_MODE" = record ] && [ "$(bool push "$INPUT_PUSH")" = true ] && [ -z "${INPUT_TOKEN:-}" ]; then
  die "input 'token' is required to push; pass \${{ secrets.GITHUB_TOKEN }} with contents: write, or set push: false"
fi

if [ "$INPUT_MODE" = record ] || [ "$INPUT_MODE" = compare ]; then
  if [ "$(bool measure "$INPUT_MEASURE")" = true ] && [ -z "${INPUT_RUN//[[:space:]]/}" ]; then
    die "input 'run' is empty; set measure: false if an earlier step already ran 'tak run --record'"
  fi
fi
