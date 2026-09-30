#!/usr/bin/env bash
# The trusted half of pull-request reporting. Runs in a workflow_run job from
# the default branch, holds a token that can write comments and checks, and
# for that reason executes nothing from the pull request: it checks out no
# code, and reads the report artifact strictly as data.
#
# Everything in the artifact was written by a job that ran the pull request's
# code, so every byte of it is untrusted. What to comment on and which commit
# the check belongs to come from the workflow_run event, which GitHub writes;
# the artifact can only contribute text and a status from a fixed set.
# Backticks in the printf formats below are markdown code spans, not command
# substitutions, so single quotes are exactly right.
# shellcheck disable=SC2016
# shellcheck source=scripts/lib.sh
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

event=${GITHUB_EVENT_PATH:?}
export GH_TOKEN="$INPUT_TOKEN"
server=${GITHUB_SERVER_URL:-https://github.com}
export GH_HOST="${server#*://}"
repo=${GITHUB_REPOSITORY:?}

wr() { jq -r ".workflow_run.$1 // empty" "$event"; }

trigger_event=$(wr event)
trigger_conclusion=$(wr conclusion)
head_sha=$(wr head_sha)
head_repo=$(wr head_repository.full_name)
head_branch=$(wr head_branch)
run_url=$(wr html_url)

skip() {
  echo "$1"
  output status skipped
  exit 0
}

[ "$trigger_event" = pull_request ] ||
  skip "The triggering run was for a '$trigger_event' event, not a pull request; nothing to report"
case "$trigger_conclusion" in
  # A newer push supersedes a cancelled run, and its own run will report.
  cancelled | skipped) skip "The triggering run was $trigger_conclusion; nothing to report" ;;
esac
is_sha "$head_sha" || die "workflow_run.head_sha is not a commit SHA: '$head_sha'"

# --- read the artifact, as data ---------------------------------------------

dir=${INPUT_ARTIFACT_DIR:?}

# Regular files only, and never more than a bound. A symlink could point the
# read somewhere else on the runner, and the size cap keeps a hostile artifact
# from turning into an oversized API request.
read_artifact() {
  local name=$1 max=$2
  local path="$dir/$name"
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    head -c "$max" "$path"
  fi
}

status=error
body_file="$TAK_ACTION_DIR/report-body.md"
claimed_pr=""
base_sha=""

if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
  printf '**The comparison did not run.** The compare job uploaded no `%s` artifact; it probably failed before measuring. See [the run](%s).\n' \
    "$INPUT_ARTIFACT_NAME" "$run_url" >"$body_file"
else
  format=$(read_artifact format 16 | tr -d '[:space:]')
  artifact_head=$(read_artifact head-sha 128 | tr -d '[:space:]')
  if [ "$format" != "$TAK_ACTION_REPORT_FORMAT" ]; then
    printf '**The report could not be read.** Its format is `%s`, and this version of tak-action reads format `%s`. The pull request and the comment workflow probably pin different tak-action releases.\n' \
      "${format//[^0-9A-Za-z.]/}" "$TAK_ACTION_REPORT_FORMAT" >"$body_file"
  elif [ "$artifact_head" != "$head_sha" ]; then
    printf '**The report could not be used.** It describes commit `%s`, but the run was for `%s`.\n' \
      "${artifact_head//[^0-9a-f]/}" "$head_sha" >"$body_file"
  else
    candidate=$(read_artifact status 32 | tr -d '[:space:]')
    case "$candidate" in
      pass | regressed | nothing-compared | nothing-compared-allowed | error) status=$candidate ;;
      *) status=error ;;
    esac
    base_sha=$(read_artifact base-sha 128 | tr -d '[:space:]')
    is_sha "$base_sha" || base_sha=""
    claimed_pr=$(read_artifact pr-number 16 | tr -d '[:space:]')
    [[ "$claimed_pr" =~ ^[0-9]+$ ]] || claimed_pr=""
    # Under the comment size limit (65536), cut at a byte and then dropping
    # any partial UTF-8 sequence the cut left behind.
    read_artifact report.md 60000 | iconv -f UTF-8 -t UTF-8 -c >"$body_file" || true
    if [ ! -s "$body_file" ]; then
      status=error
      echo '**The report was empty.**' >"$body_file"
    elif [ "$(stat -c %s "$dir/report.md")" -gt 60000 ]; then
      printf '\n\n*Report truncated; see [the run](%s) for the rest.*\n' "$run_url" >>"$body_file"
    fi
  fi
fi

# The trusted side decides what each outcome means for the check, not the
# artifact: the compare job's inputs came from the pull request's copy of the
# workflow.
conclusion=$(check_conclusion "$status" "$INPUT_FAIL_ON_REGRESSION" "$INPUT_FAIL_ON_NOTHING_COMPARED")
title=$(check_title "$status")
output status "$status"
output conclusion "$conclusion"
echo "status=$status conclusion=$conclusion"

# --- find the pull request ----------------------------------------------------

# From the event, never from the artifact. workflow_run.pull_requests is
# empty for pull requests from forks, so fall back to asking for open pull
# requests whose head is this branch at this exact commit. The artifact's
# claim can at most choose between pull requests that pass that test.
prs=$(jq -r --arg sha "$head_sha" '.workflow_run.pull_requests[]? | select(.head.sha == $sha) | .number' "$event")
if [ -z "$prs" ] && [ -n "$head_repo" ] && [ -n "$head_branch" ]; then
  # Not fatal: the check run below needs only the commit, and is the part
  # that gates, so a failed lookup should cost the comment and nothing more.
  prs=$(gh api --method GET "repos/$repo/pulls" -f state=open -f head="${head_repo%%/*}:$head_branch" --paginate |
    jq -r --arg sha "$head_sha" --arg repo "$head_repo" \
      '.[] | select(.head.sha == $sha and .head.repo.full_name == $repo) | .number') ||
    {
      warn "could not list pull requests for $head_repo:$head_branch; not commenting"
      prs=""
    }
fi
pr=""
if [ -n "$prs" ]; then
  pr=$(head -n1 <<<"$prs")
  if [ -n "$claimed_pr" ] && grep -qx "$claimed_pr" <<<"$prs"; then
    pr=$claimed_pr
  fi
  [ "$(wc -l <<<"$prs")" -eq 1 ] || warn "several open pull requests have head $head_sha; reporting on #$pr"
fi
output pr-number "$pr"

# --- comment ------------------------------------------------------------------

if [ "$(bool comment "$INPUT_COMMENT")" = true ]; then
  if [ -z "$pr" ]; then
    warn "no open pull request has head $head_sha (it may have been pushed to or closed since); not commenting"
  else
    marker="<!-- tak-action:$INPUT_COMMENT_KEY -->"
    comment_file="$TAK_ACTION_DIR/comment.md"
    {
      echo "$marker"
      echo "### tak: $title"
      echo
      # The report is text from the pull request's job: a zero-width space
      # after every @ keeps it from mentioning people or teams.
      sed 's/@/@\xe2\x80\x8b/g' "$body_file"
      echo
      printf '<sub>`%s`%s · [compare run](%s) · measured in the pull request'"'"'s workflow and not pushed to the history.</sub>\n' \
        "${head_sha:0:12}" "${base_sha:+ compared with \`${base_sha:0:12}\`}" "$run_url"
    } >"$comment_file"

    # One comment per pull request, edited in place: a new one per push buries
    # the conversation. Only a bot's comment counts, so a person quoting the
    # marker does not get their comment overwritten.
    existing=$(gh api "repos/$repo/issues/$pr/comments" --paginate |
      jq -r --arg m "$marker" '.[] | select(.user.type == "Bot" and (.body | startswith($m))) | .id' | tail -n1)
    if [ -n "$existing" ]; then
      url=$(jq -n --rawfile body "$comment_file" '{body: $body}' |
        gh api --method PATCH "repos/$repo/issues/comments/$existing" --input - --jq .html_url)
    else
      url=$(jq -n --rawfile body "$comment_file" '{body: $body}' |
        gh api --method POST "repos/$repo/issues/$pr/comments" --input - --jq .html_url)
    fi
    output comment-url "$url"
    echo "Commented: $url"
  fi
fi

# --- check --------------------------------------------------------------------

# A workflow_run job's own status is attached to the default branch, not to
# the pull request, so the result reaches the pull request as a check run on
# its head commit.
if [ "$(bool check "$INPUT_CHECK")" = true ]; then
  check_file="$TAK_ACTION_DIR/check.json"
  jq -n \
    --arg name "$INPUT_CHECK_NAME" \
    --arg head_sha "$head_sha" \
    --arg conclusion "$conclusion" \
    --arg details_url "$run_url" \
    --arg title "$title" \
    --rawfile summary "$body_file" \
    '{name: $name, head_sha: $head_sha, external_id: "tak-action", status: "completed",
      conclusion: $conclusion, details_url: $details_url,
      output: {title: $title, summary: $summary}}' >"$check_file"
  # One check per name per commit. A rerun of the compare workflow for the
  # same commit updates the check this action created before, rather than
  # stacking a second result with the same name beside it. Only checks this
  # action created count (the GitHub Actions app, marked with external_id),
  # so a workflow job or another tool that shares the name is left alone.
  existing_check=$(gh api --method GET "repos/$repo/commits/$head_sha/check-runs" \
    -f check_name="$INPUT_CHECK_NAME" -f filter=latest --paginate |
    jq -r '.check_runs[] | select(.app.slug == "github-actions" and .external_id == "tak-action") | .id' | head -n1) || existing_check=""
  if [ -n "$existing_check" ]; then
    jq 'del(.head_sha)' "$check_file" |
      gh api --method PATCH "repos/$repo/check-runs/$existing_check" --input - --jq .html_url
  else
    gh api --method POST "repos/$repo/check-runs" --input - --jq .html_url <"$check_file"
  fi
fi

{
  echo "### tak: $title"
  echo
  cat "$body_file"
} >>"${GITHUB_STEP_SUMMARY:?}"
