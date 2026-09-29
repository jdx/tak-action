#!/usr/bin/env bash
# Publish what `tak run --record` wrote locally, then summarise it.
# shellcheck source=scripts/lib.sh
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

enter_working_directory
use_tak
mask_token "${INPUT_TOKEN:-}"

this_repository() {
  # Normalise https://host/owner/repo(.git) and git@host:owner/repo(.git)
  # to owner/repo, lowercased, so either spelling of the remote matches.
  local url=$1
  url=${url%/}
  url=${url%.git}
  url=${url#*://}
  url=${url#*@}
  url=${url#*[:/]}
  [ "${url,,}" = "${GITHUB_REPOSITORY,,}" ]
}

if [ "$(bool push "$INPUT_PUSH")" = true ]; then
  # A branch's numbers are not the trunk's. Pushing a pull request's
  # measurement into the shared history makes the series unreadable, and a
  # later comparison would treat the branch as a baseline.
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request | pull_request_target | merge_group)
      if this_repository "$(git remote get-url origin)"; then
        die "refusing to push refs/notes/tak from a $GITHUB_EVENT_NAME event; record only the main branch, and use mode: compare for pull requests"
      fi
      ;;
  esac
  # tak shells out to git for the push, which picks the credential up from
  # the environment for this one process and never writes it to disk.
  with_token "$INPUT_TOKEN" tak push
  echo "Pushed refs/notes/tak"
fi

if [ "$(bool summary "$INPUT_SUMMARY")" = true ]; then
  # Through a file rather than straight into the summary: with_token prints a
  # mask command on stdout, which must reach the runner, not the summary.
  if with_token "$INPUT_TOKEN" tak history >"$TAK_ACTION_DIR/history.md"; then
    {
      echo "### tak: recorded $(git rev-parse --short HEAD)"
      echo
      echo '```text'
      cat "$TAK_ACTION_DIR/history.md"
      echo '```'
    } >>"${GITHUB_STEP_SUMMARY:?}"
  else
    warn "tak history failed, so the job summary has no history"
  fi
fi
