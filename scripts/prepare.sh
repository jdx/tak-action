#!/usr/bin/env bash
# The trusted half of a pull-request comparison: resolve the base commit and
# fetch it and the notes while a read-only token is available, then remove
# every credential the checkout left behind. Everything after this step may be
# running code from the pull request, so nothing after it gets a token.
# shellcheck source=scripts/lib.sh
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

# --- credentials ------------------------------------------------------------

strip_credentials() {
  local entry key value

  # actions/checkout up to v5 wrote the token straight into .git/config.
  while IFS= read -r -d '' entry; do
    key=${entry%%$'\n'*}
    git config --local --unset-all "$key" || true
  done < <(git config --local --null --get-regexp '^http\..*\.extraheader$' || true)

  # From v6 it writes the token to $RUNNER_TEMP/git-credentials-<uuid>.config
  # and includes that file from .git/config with includeIf. Unsetting the
  # extraheader key locally finds nothing in that layout (--local does not
  # follow includes), so remove the include and delete the file itself: the
  # token is in plain text there, readable without any include at all.
  while IFS= read -r -d '' entry; do
    key=${entry%%$'\n'*}
    value=${entry#*$'\n'}
    case "${value##*/}" in
      git-credentials-*.config)
        git config --local --unset-all "$key" || true
        rm -f -- "$value"
        ;;
    esac
  done < <(git config --local --null --get-regexp '^include(if\..*)?\.path$' || true)
  # Any other checkout in this job used the same layout for the same token.
  rm -f -- "${RUNNER_TEMP:?}"/git-credentials-*.config

  # Check the effective configuration, includes and every scope, rather than
  # trusting the removal above to have understood the layout.
  if git config --get-regexp '^http\..*\.extraheader$' >/dev/null 2>&1; then
    die "an http.extraheader credential is still configured after cleanup ($(git config --show-origin --name-only --get-regexp '^http\..*\.extraheader$' | tr '\n' ' ')); refusing to run project code with it in reach"
  fi
}

# Any failure in this step invalidates what an earlier prepare in the job
# resolved. Otherwise a compare step, which runs even after this one fails,
# would reuse a base and head that this invocation never checked.
invalidate_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    state_set PREPARED_WD ""
  fi
  return "$rc"
}
trap invalidate_on_failure EXIT

enter_working_directory

head=$(git rev-parse --verify 'HEAD^{commit}')

# The synthetic merge commit actions/checkout picks by default for a
# pull_request event exists only for this run and moves whenever the base
# branch does. A number recorded against it describes a commit nobody can
# check out, so measure the branch commit instead.
if [ -n "${INPUT_HEAD_SHA:-}" ] && [ "$head" != "$INPUT_HEAD_SHA" ]; then
  die "HEAD is $head but the pull request head is $INPUT_HEAD_SHA. Check out the branch commit rather than the merge commit: actions/checkout with ref: \${{ github.event.pull_request.head.sha }}"
fi

# The comparison this invocation asks for, resolved the same way whichever
# mode runs it, so a prepare step and the compare step after it can be
# checked against each other.
requested_base_ref=${INPUT_BASE_REF:-}
if [ -z "${INPUT_BASE:-}" ] && [ -z "$requested_base_ref" ] && [ -f "${GITHUB_EVENT_PATH:-}" ]; then
  requested_base_ref=$(jq -r '.pull_request.base.ref // empty' "$GITHUB_EVENT_PATH")
fi
request="base=${INPUT_BASE:-} base-ref=$requested_base_ref head-sha=${INPUT_HEAD_SHA:-}"

# A prepare-mode step earlier in this job already did the work for this
# checkout. Compare mode consumes that state and removes it, so a second
# comparison in the same job prepares afresh. Reused only for the same
# request: silently keeping the earlier base would report a comparison other
# than the one asked for.
if [ "$(state_get PREPARED_WD)" = "$PWD" ] && [ "$(state_get HEAD_SHA)" = "$head" ]; then
  prepared_request=$(state_get REQUEST)
  if [ "$prepared_request" != "$request" ]; then
    die "this step asks for '$request' but the prepare step before it resolved '$prepared_request'; pass the same base, base-ref and head-sha to both"
  fi
  echo "Already prepared by an earlier step in this job"
  # Again anyway: a step in between may have checked out afresh.
  strip_credentials
  exit 0
fi

# Whatever an earlier prepare in this job resolved no longer applies. Cleared
# before anything can fail, so a failure below leaves the compare step with
# nothing to reuse rather than a stale base.
state_set PREPARED_WD ""

token=${INPUT_TOKEN:-}
mask_token "$token"

fetch_quiet() {
  with_token "$token" git fetch --quiet --no-tags --no-write-fetch-head origin "$@"
}

# --- base commit ------------------------------------------------------------

if [ -n "${INPUT_BASE:-}" ]; then
  # A SHA only. A branch name here would be resolved against whatever local
  # ref happens to exist, which is how a stale branch gets compared against;
  # base-ref fetches the branch and takes the merge base instead.
  is_sha "$INPUT_BASE" || die "input 'base' must be a full commit SHA; use base-ref for a branch"
  if ! git cat-file -e "${INPUT_BASE}^{commit}" 2>/dev/null; then
    fetch_quiet "$INPUT_BASE" || die "could not fetch base commit $INPUT_BASE from origin"
  fi
  base=$(git rev-parse --verify "${INPUT_BASE}^{commit}") || die "base $INPUT_BASE is not a commit"
  base_ref=""
else
  base_ref=$requested_base_ref
  [ -n "$base_ref" ] ||
    die "no base to compare against: this is not a pull_request event, so set base-ref (a branch) or base (a commit)"
  git check-ref-format --branch "$base_ref" >/dev/null 2>&1 || die "base-ref '$base_ref' is not a valid branch name"

  # The merge base needs history on both sides. fetch-depth: 0 provides it;
  # a shallow checkout is deepened here rather than failing, since this is the
  # only step that still holds a token to deepen it with.
  shallow=()
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    shallow=(--unshallow)
  fi
  fetch_quiet "${shallow[@]}" "+refs/heads/$base_ref:refs/remotes/origin/$base_ref" ||
    die "could not fetch branch '$base_ref' from origin"
  # The merge base, not the branch tip. Comparing against a moving target
  # attributes everything that landed on the base branch since this branch was
  # created to the pull request.
  base=$(git merge-base "refs/remotes/origin/$base_ref" HEAD) ||
    die "HEAD shares no history with origin/$base_ref"
fi

# --- notes ------------------------------------------------------------------

# Into the scratch ref, then merged, exactly as tak does it: a fetch straight
# onto refs/notes/tak would discard anything recorded locally and not pushed.
# Depth 1 is enough: the notes tree names commits by path, so its tip holds the
# whole history.
if fetch_quiet --depth 1 '+refs/notes/tak:refs/notes/tak-remote' 2>"$TAK_ACTION_DIR/notes-fetch.err"; then
  if git rev-parse --verify --quiet refs/notes/tak >/dev/null; then
    git -c user.name=tak -c user.email=tak@localhost \
      notes --ref=tak merge --quiet -s cat_sort_uniq refs/notes/tak-remote
  else
    git update-ref refs/notes/tak refs/notes/tak-remote
  fi
  echo "Fetched refs/notes/tak from origin"
else
  # Not fatal here: a repository that has never recorded has no notes ref, and
  # the comparison then reports "nothing was compared", which fails by default.
  warn "could not fetch refs/notes/tak from origin, so the base has no recorded measurements to compare against: $(tr '\n' ' ' <"$TAK_ACTION_DIR/notes-fetch.err")"
fi

strip_credentials
echo "Removed checkout credentials; nothing after this step receives a token"

state_set PREPARED_WD "$PWD"
state_set HEAD_SHA "$head"
state_set BASE_SHA "$base"
state_set BASE_REF "$base_ref"
state_set REQUEST "$request"
output head-sha "$head"
output base-sha "$base"
echo "Comparing $head against $base${base_ref:+ (merge base with origin/$base_ref)}"
