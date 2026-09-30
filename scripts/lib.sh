# Shared helpers, sourced by every step script. Not executable on its own.
# shellcheck shell=bash

set -euo pipefail

# Everything this action writes lives under one directory, so a later step in
# the same job (prepare, then compare) can find what an earlier one left.
TAK_ACTION_DIR="${RUNNER_TEMP:?RUNNER_TEMP is not set; this script runs inside GitHub Actions}/tak-action"
TAK_ACTION_STATE="$TAK_ACTION_DIR/state"
# shellcheck disable=SC2034 # used by the scripts that source this file
TAK_ACTION_REPORT_DIR="$TAK_ACTION_DIR/report"
mkdir -p "$TAK_ACTION_DIR"

# Version of the files in the report artifact. The comment job may run a
# different release of this action than the compare job did (it runs from the
# default branch; the compare job runs whatever the pull request pins), so it
# checks this before reading anything else.
# shellcheck disable=SC2034 # used by the scripts that source this file
TAK_ACTION_REPORT_FORMAT=1

die() {
  # The annotation is what shows on the run page; the plain line is for logs
  # read without annotations.
  echo "::error title=tak-action::$*"
  exit 1
}

warn() {
  echo "::warning title=tak-action::$*"
}

# Parse a boolean input strictly. A typo like `ture` silently meaning false
# would switch off a gate without anyone noticing.
bool() {
  local name=$1 value=$2
  case "$value" in
    true | True | TRUE) echo true ;;
    false | False | FALSE) echo false ;;
    *) die "input '$name' must be 'true' or 'false', got '$value'" ;;
  esac
}

# fail-on-nothing-compared, normalised to auto, true or false. Validated up
# front, so anything else here is a bug.
nothing_compared_policy() {
  case "$1" in
    auto | Auto | AUTO) echo auto ;;
    *) bool fail-on-nothing-compared "$1" ;;
  esac
}

# The check-run conclusion comment mode publishes for a status, given its
# own fail-on-regression and fail-on-nothing-compared inputs. A function of
# its arguments alone, so test/conclusions.sh can check every combination
# without the GitHub API.
check_conclusion() {
  local status=$1 on_regression=$2 on_nothing=$3
  case "$status" in
    pass) echo success ;;
    regressed)
      [ "$(bool fail-on-regression "$on_regression")" = true ] && echo failure || echo neutral
      ;;
    nothing-compared)
      [ "$(nothing_compared_policy "$on_nothing")" != false ] && echo failure || echo neutral
      ;;
    nothing-compared-allowed)
      # Neutral, not success: the gate checked nothing, and a green check
      # would read as if it had.
      [ "$(nothing_compared_policy "$on_nothing")" = true ] && echo failure || echo neutral
      ;;
    *) echo failure ;;
  esac
}

check_title() {
  case "$1" in
    pass) echo "No instruction-count regression beyond the gate" ;;
    regressed) echo "An instruction count rose beyond the gate" ;;
    nothing-compared) echo "Nothing was compared" ;;
    nothing-compared-allowed) echo "Nothing was compared (allowed by allow_empty)" ;;
    *) echo "The comparison did not run" ;;
  esac
}

output() {
  echo "$1=$2" >>"${GITHUB_OUTPUT:?}"
}

# key=value lines. Values are validated by whoever reads them, because the
# measure step runs project code in between and could have rewritten the file.
state_set() {
  local key=$1 value=$2
  touch "$TAK_ACTION_STATE"
  grep -v "^${key}=" "$TAK_ACTION_STATE" >"$TAK_ACTION_STATE.tmp" || true
  printf '%s=%s\n' "$key" "$value" >>"$TAK_ACTION_STATE.tmp"
  mv "$TAK_ACTION_STATE.tmp" "$TAK_ACTION_STATE"
}

state_get() {
  local key=$1
  [ -f "$TAK_ACTION_STATE" ] || return 0
  sed -n "s/^${key}=//p" "$TAK_ACTION_STATE" | tail -n1
}

is_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ || "$1" =~ ^[0-9a-f]{64}$ ]]
}

enter_working_directory() {
  local dir=${INPUT_WORKING_DIRECTORY:-.}
  cd "$dir" || die "working-directory '$dir' does not exist"
  git rev-parse --git-dir >/dev/null 2>&1 ||
    die "working-directory '$dir' is not inside a git repository; check out the repository first (actions/checkout)"
}

basic_auth() {
  printf 'x-access-token:%s' "$1" | base64 | tr -d '\n'
}

# The token is masked by the runner already, but the base64 form git sends is
# a different string. Called once, before any output is redirected: a mask
# command that lands in a file instead of on stdout masks nothing.
mask_token() {
  [ -z "$1" ] || echo "::add-mask::$(basic_auth "$1")"
}

# Credentials for one git invocation, passed through the environment rather
# than written to .git/config, so nothing on disk outlives the step. The empty
# first value resets any extraheader already configured (for example by
# actions/checkout with persist-credentials), so git sends exactly one
# Authorization header.
with_token() {
  local token=$1
  shift
  if [ -z "$token" ]; then
    GIT_TERMINAL_PROMPT=0 "$@"
    return
  fi
  local server=${GITHUB_SERVER_URL:-https://github.com}
  GIT_TERMINAL_PROMPT=0 \
    GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0="http.${server}/.extraheader" \
    GIT_CONFIG_VALUE_0="" \
    GIT_CONFIG_KEY_1="http.${server}/.extraheader" \
    GIT_CONFIG_VALUE_1="AUTHORIZATION: basic $(basic_auth "$token")" \
    "$@"
}

# Put the tak the install step chose first on PATH. GITHUB_PATH would do this
# for later steps too, but the run command must get this tak even if the job
# already had another one on PATH before this action ran.
use_tak() {
  local tak
  tak=$(state_get TAK)
  [ -n "$tak" ] && [ -x "$tak" ] || die "tak was not installed; an earlier step of this action failed"
  PATH="$(dirname "$tak"):$PATH"
  export PATH
}
