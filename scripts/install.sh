#!/usr/bin/env bash
# Install tak from a GitHub release, and valgrind from apt.
# shellcheck source=scripts/lib.sh
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

# Linux only, and not because tak is: valgrind is what counts instructions, and
# there is no usable valgrind on Apple Silicon or Windows. Without it tak
# records wall time alone, which is too noisy to gate on, so a macOS job would
# produce a comparison that can never fail and looks like it passed.
[ "${RUNNER_OS:-}" = Linux ] ||
  die "tak-action supports Linux runners only (this is ${RUNNER_OS:-an unknown OS}): instruction counting needs valgrind, which has no usable port to Apple Silicon or Windows"

install_tak() {
  local version=${INPUT_VERSION#v}
  local arch libc target asset base dir
  case "${RUNNER_ARCH:-}" in
    X64) arch=x86_64 ;;
    ARM64) arch=aarch64 ;;
    *) die "no tak release build for runner architecture '${RUNNER_ARCH:-unknown}'" ;;
  esac
  # The musl build is static, so it also runs in containers without glibc.
  # Prefer the gnu build where glibc exists: that is what most users install
  # locally, and there is no reason to measure with a different binary in CI.
  libc=gnu
  if ! ldd --version 2>&1 | grep -qi 'gnu\|glibc'; then
    libc=musl
  fi
  target="$arch-unknown-linux-$libc"
  asset="tak-$target.tar.gz"
  base="https://github.com/jdx/tak/releases/download/v$version"
  dir="$TAK_ACTION_DIR/tak-$version-$target"

  if [ ! -x "$dir/tak" ]; then
    local tmp
    tmp=$(mktemp -d "$TAK_ACTION_DIR/download.XXXXXX")
    echo "Downloading $base/$asset"
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$tmp/$asset" "$base/$asset" ||
      die "could not download $asset for tak $version; check that release v$version exists at https://github.com/jdx/tak/releases"
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" ||
      die "tak $version publishes no SHA256SUMS, so its download cannot be verified"
    # Exactly one line naming exactly this asset. sha256sum -c on the whole
    # file with --ignore-missing would pass if the asset's line were absent.
    local expected
    expected=$(awk -v f="$asset" '$2 == f || $2 == "*"f { print $1 }' "$tmp/SHA256SUMS")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "SHA256SUMS for tak $version has no single entry for $asset"
    echo "$expected  $tmp/$asset" | sha256sum -c --quiet - || die "checksum mismatch for $asset"
    mkdir -p "$tmp/x"
    tar -xzf "$tmp/$asset" -C "$tmp/x"
    [ -f "$tmp/x/tak" ] || die "$asset does not contain a tak binary at its root"
    mkdir -p "$dir"
    install -m 0755 "$tmp/x/tak" "$dir/tak"
    rm -rf "$tmp"
  fi

  local reported
  reported=$("$dir/tak" --version | awk '{print $2}')
  [ "$reported" = "$version" ] || die "downloaded tak reports version '$reported', expected '$version'"
  echo "$dir" >>"${GITHUB_PATH:?}"
  state_set TAK "$dir/tak"
  echo "Installed tak $version ($target) to $dir"
}

use_existing_tak() {
  local found reported
  found=$(command -v tak) || die "install is false but no tak is on PATH; install it first (for example with jdx/mise-action) or set install: true"
  if [ -n "${INPUT_VERSION:-}" ]; then
    reported=$(tak --version | awk '{print $2}')
    [ "$reported" = "${INPUT_VERSION#v}" ] ||
      die "tak on PATH ($found) is version '$reported', but input 'version' asks for '${INPUT_VERSION#v}'"
  fi
  state_set TAK "$found"
  echo "Using $found ($(tak --version))"
}

install_valgrind() {
  if command -v valgrind >/dev/null 2>&1; then
    echo "Using $(command -v valgrind) ($(valgrind --version))"
    return
  fi
  [ "$(bool install-valgrind "$INPUT_INSTALL_VALGRIND")" = true ] ||
    die "valgrind is not installed and install-valgrind is false; tak cannot count instructions without it"
  command -v apt-get >/dev/null 2>&1 ||
    die "valgrind is not installed and this runner has no apt-get to install it with; install valgrind in an earlier step"
  local sudo=()
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "installing valgrind needs root or sudo"
    sudo=(sudo -n)
  fi
  echo "Installing valgrind with apt-get"
  "${sudo[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null
  "${sudo[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends valgrind >/dev/null
  command -v valgrind >/dev/null 2>&1 || die "apt-get finished but valgrind is still not on PATH"
  echo "Installed $(valgrind --version)"
}

if [ "$(bool install "$INPUT_INSTALL")" = true ]; then
  install_tak
elif [ "${INPUT_MODE:-}" = prepare ]; then
  # prepare runs only git. With install: false, tak typically arrives in a
  # later step (mise-action reading mise.toml), after the credentials are gone.
  echo "install is false; prepare does not need tak"
else
  use_existing_tak
fi
install_valgrind
