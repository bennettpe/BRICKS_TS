#!/usr/bin/env bash
# add_brick_user.bash — add (or update) a user in runtime/users.conf.
#
# Usage:
#   ./add_brick_user.bash <username> <password> [groups]
#   ./add_brick_user.bash --update <username> <password> [groups]
#
#   groups is a comma-separated list (e.g. admin,users). Defaults to "users".
#
# The password is hashed with bcrypt before being written, using the
# prebuilt brickspw helper in ./bin that matches this machine's OS and
# architecture (e.g. bin/brickspw-2.8.0-linux-amd64) -- no Go toolchain
# needed. If ./bin has no brickspw for this platform, the script tells
# you to run ./build.bash or to add the user from inside bricks (CSSN
# sign-on, then CEDA USER).
# Without --update the script refuses to overwrite an existing user.

set -euo pipefail

usage() {
  cat >&2 <<EOF
usage: $0 [--update] <username> <password> [groups]

  --update    replace an existing user's hash/groups instead of refusing
  groups      comma-separated, defaults to 'users'

Reads/writes runtime/users.conf relative to the script's directory.
EOF
  exit 2
}

# detect_goos / detect_goarch map the running platform onto the naming
# build.bash uses for bin/ artifacts (<name>-<version>-<goos>-<goarch>).
# Each prints the empty string for a platform build.bash doesn't target,
# which find_brickspw treats as "no prebuilt binary".
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

# find_brickspw prints the path to the arch-matched brickspw binary in
# bin/ and returns 0; returns non-zero when none is found. A match that
# exists but isn't executable is reported (rc=2) so the caller can give
# a chmod hint instead of a "not built" message.
find_brickspw() {
  local goos goarch ext=""
  goos=$(detect_goos)
  goarch=$(detect_goarch)
  if [[ -z "$goos" || -z "$goarch" ]]; then
    return 1
  fi
  [[ "$goos" == "windows" ]] && ext=".exe"

  local matches=()
  shopt -s nullglob
  matches=(bin/brickspw-*-"${goos}-${goarch}${ext}")
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

# restore_pwbin_mode reverts the temporary +x applied to PWBIN when the
# arch-matched binary was found non-executable. PWBIN / PWBIN_RESTORE_MODE
# are set by the hashing step below. Safe to call more than once (it's a
# no-op once restored) so the EXIT trap and the normal path can both call
# it without double-chmod.
restore_pwbin_mode() {
  [[ -n "${PWBIN_RESTORE_MODE:-}" ]] || return 0
  if [[ "$PWBIN_RESTORE_MODE" == "-" ]]; then
    # Original octal mode couldn't be read; just drop the +x we added.
    chmod -x "$PWBIN" 2>/dev/null || true
  else
    chmod "$PWBIN_RESTORE_MODE" "$PWBIN" 2>/dev/null || true
  fi
  PWBIN_RESTORE_MODE=""
}

UPDATE=0
if [[ ${1:-} == "--update" ]]; then
  UPDATE=1
  shift
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
fi

USER="$1"
PASS="$2"
ROLES="${3:-users}"

# Username sanity: no colons (field separator), no whitespace, non-empty.
if [[ -z "$USER" ]]; then
  echo "error: username is empty" >&2
  exit 1
fi
if [[ "$USER" == *:* ]]; then
  echo "error: username may not contain ':'" >&2
  exit 1
fi
if [[ "$USER" =~ [[:space:]] ]]; then
  echo "error: username may not contain whitespace" >&2
  exit 1
fi
if [[ "$ROLES" == *:* ]]; then
  echo "error: groups may not contain ':'" >&2
  exit 1
fi

cd -- "$(dirname -- "$0")"

USERS_FILE="runtime/users.conf"
if [[ ! -f "$USERS_FILE" ]]; then
  mkdir -p "$(dirname "$USERS_FILE")"
  : > "$USERS_FILE"
fi

# Existing entry? Match "username:" at start of line, ignoring comments.
existing_line=$(grep -n -E "^${USER}:" "$USERS_FILE" || true)
if [[ -n "$existing_line" && $UPDATE -eq 0 ]]; then
  echo "error: user '$USER' already exists (line ${existing_line%%:*}). Use --update to replace." >&2
  exit 1
fi

# Hash the password with the arch-matched brickspw helper from ./bin.
# `|| rc=$?` keeps `set -e` from aborting on a non-zero return so we can
# branch on it (a failing command substitution in a bare assignment
# would otherwise exit the script before we read $?).
rc=0
PWBIN=$(find_brickspw) || rc=$?
if [[ $rc -ne 0 && $rc -ne 2 ]]; then
  cat >&2 <<EOF
error: no prebuilt brickspw for $(uname -s)/$(uname -m) found in ./bin.
  Option A: build it for this platform:   ./build.bash
  Option B: add the user from inside bricks instead of this script:
            connect with a 3270 emulator, sign on with CSSN
            (default admin / admin), then use CEDA USER (CEDA U)
            to add or alter the user.
EOF
  exit 1
fi

# rc==2: the matched binary exists but isn't executable. Make it
# executable just for this run and restore its original mode afterward
# (the EXIT trap guarantees restoration even if hashing fails), so we
# never leave a persistent permissions change behind.
PWBIN_RESTORE_MODE=""
if [[ $rc -eq 2 ]]; then
  # stat -c is GNU (Linux); stat -f '%Lp' is BSD (macOS). "-" marks the
  # mode as unknown so restore falls back to just removing +x.
  PWBIN_RESTORE_MODE=$(stat -c '%a' "$PWBIN" 2>/dev/null || stat -f '%Lp' "$PWBIN" 2>/dev/null || echo "-")
  if ! chmod u+x "$PWBIN" 2>/dev/null; then
    echo "error: '$PWBIN' is not executable and chmod failed; run: chmod +x '$PWBIN'" >&2
    exit 1
  fi
  echo "note: '$PWBIN' was not executable; made it temporarily executable for this run" >&2
  trap restore_pwbin_mode EXIT
fi

HASH=$("$PWBIN" "$PASS")

if [[ $rc -eq 2 ]]; then
  restore_pwbin_mode
  trap - EXIT
fi

if [[ -z "$HASH" ]]; then
  echo "error: failed to generate bcrypt hash (via $PWBIN)" >&2
  exit 1
fi

NEW_LINE="${USER}:${HASH}:${ROLES}"

if [[ -n "$existing_line" ]]; then
  # In-place replace using a tmp file (avoids GNU/BSD sed -i differences).
  tmp=$(mktemp)
  awk -v user="$USER" -v line="$NEW_LINE" '
    BEGIN { replaced = 0 }
    {
      if ($0 ~ "^"user":") {
        print line
        replaced = 1
      } else {
        print $0
      }
    }
    END {
      if (!replaced) print line
    }
  ' "$USERS_FILE" > "$tmp"
  mv "$tmp" "$USERS_FILE"
  echo "updated user '$USER' (groups=$ROLES)"
else
  # Make sure the file ends with a newline before appending.
  if [[ -s "$USERS_FILE" ]] && [[ "$(tail -c 1 "$USERS_FILE")" != "" ]]; then
    printf '\n' >> "$USERS_FILE"
  fi
  printf '%s\n' "$NEW_LINE" >> "$USERS_FILE"
  echo "added user '$USER' (groups=$ROLES)"
fi

chmod 600 "$USERS_FILE" 2>/dev/null || true
