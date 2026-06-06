#!/usr/bin/env bash
# start_bricks.bash — launch the bricks server using the prebuilt binary
# in ./bin that matches this machine's OS/architecture, against the
# bricks.cnf in this directory.
#
# Usage:
#   ./start_bricks.bash [extra bricks args...]
#
# Extra arguments are forwarded to bricks (e.g. -no-console). The config
# defaults to ./bricks.cnf; pass `-conf <path>` to override it (the last
# -conf wins). The script operates from its own directory, so ./bin,
# ./bricks.cnf and the runtime/ + data/ trees bricks expects are all
# resolved there regardless of where you invoke it from.
#
# The matching binary is bin/bricks-<version>-<goos>-<goarch>[.exe]
# (produced by build.bash). If it isn't executable, the script makes it
# executable. If ./bin has no bricks for this platform, it tells you to
# run ./build.bash.

set -euo pipefail

cd -- "$(dirname -- "$0")"

# detect_goos / detect_goarch map the running platform onto the naming
# build.bash uses for bin/ artifacts (<name>-<version>-<goos>-<goarch>).
# Each prints the empty string for a platform build.bash doesn't target,
# which find_bricks treats as "no prebuilt binary".
detect_goos() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo darwin ;;
    Linux) echo linux ;;
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    *) echo "" ;;
  esac
}

detect_goarch() {
  # NB: build.bash names the 32-bit ARM target "armv7" (GOARCH=arm +
  # GOARM=7), so emit armv7 here, not the raw GOARCH "arm".
  case "$(uname -m 2>/dev/null)" in
    arm64 | aarch64) echo arm64 ;;
    x86_64 | amd64) echo amd64 ;;
    armv7l | armv6l | armv7 | armhf) echo armv7 ;;
    *) echo "" ;;
  esac
}

# find_bricks prints the path to the arch-matched bricks server binary in
# bin/ and returns 0; returns 1 when none is found and 2 when a match
# exists but isn't executable. The glob's literal "bricks-" (with the
# dash) excludes the sibling helpers brickscompile / bricksconvert /
# bricksdesigner / bricksload / brickspw, whose names have no dash right
# after "bricks".
find_bricks() {
  local goos goarch ext=""
  goos=$(detect_goos)
  goarch=$(detect_goarch)
  if [[ -z "$goos" || -z "$goarch" ]]; then
    return 1
  fi
  [[ "$goos" == "windows" ]] && ext=".exe"

  local matches=()
  shopt -s nullglob
  matches=(bin/bricks-*-"${goos}-${goarch}${ext}")
  shopt -u nullglob
  if [[ ${#matches[@]} -eq 0 ]]; then
    return 1
  fi

  # bin/ normally holds one version (build.bash wipes it first); if
  # several ever coexist, take the highest version.
  local bin
  bin=$(printf '%s\n' "${matches[@]}" | sort -V | tail -1)
  if [[ ! -x "$bin" ]]; then
    printf '%s\n' "$bin"
    return 2
  fi
  printf '%s\n' "$bin"
  return 0
}

# Locate the binary. `|| rc=$?` keeps `set -e` from aborting on a
# non-zero return so we can branch on it.
rc=0
BIN=$(find_bricks) || rc=$?
if [[ $rc -ne 0 && $rc -ne 2 ]]; then
  cat >&2 <<EOF
error: no prebuilt bricks for $(uname -s)/$(uname -m) found in ./bin.
  Build it for this platform:   ./build.bash
EOF
  exit 1
fi

# rc==2: the matched binary exists but isn't executable. Make it so.
# Unlike add_brick_user.bash this is a permanent chmod (not restored),
# because we exec into the server -- there is no "after" in which to
# revert, and a server binary you launch should stay executable.
if [[ $rc -eq 2 ]]; then
  if ! chmod +x "$BIN" 2>/dev/null; then
    echo "error: '$BIN' is not executable and chmod failed; run: chmod +x '$BIN'" >&2
    exit 1
  fi
  echo "note: '$BIN' was not executable; made it executable" >&2
fi

# The local config (and the runtime/ + data/ trees referenced from it).
CONF="bricks.cnf"
if [[ ! -f "$CONF" ]]; then
  echo "error: $CONF not found in $(pwd)" >&2
  exit 1
fi

echo "starting bricks: $BIN -conf $CONF $*" >&2
# exec so bricks replaces this shell: signals (Ctrl-C, SIGTERM) and the
# PID pass straight through to the server with no wrapper process.
exec "$BIN" -conf "$CONF" "$@"
