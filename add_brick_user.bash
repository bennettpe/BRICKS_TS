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

# ===========================================================================
# Release auto-download — keep ./bin stocked with the latest bricks toolchain
# so the user never has to build or fetch binaries by hand. Mirrors
# start_bricks.bash so either script can bootstrap a fresh checkout.
# ===========================================================================
REPO="moshix/BRICKS_TS"
RELEASES_URL="https://github.com/${REPO}/releases"
ISSUES_URL="https://github.com/${REPO}/issues"
API_LATEST="https://api.github.com/repos/${REPO}/releases/latest"

# Every binary that makes up a complete bricks install, named
# <tool>-<version>-<goos>-<goarch>[.exe] in the release.
TOOLS=(bricks brickscompile bricksconvert bricksdesigner bricksload brickspw idcams)

# Globals populated by sync_binaries / its helpers.
RELEASE_JSON=""
TAG=""
WANT_VER=""

# Colored, stderr-only logging (stdout stays clean for the user-facing
# "added user ..." line). Honors NO_COLOR.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_CYAN=""
fi

info()    { printf '%s %s\n' "${C_BLUE}${C_BOLD}==>${C_RESET}" "$*" >&2; }
step()    { printf '%s %s\n' "${C_DIM}  ·${C_RESET}" "${C_DIM}$*${C_RESET}" >&2; }
success() { printf '%s %s\n' "${C_GREEN}${C_BOLD}✓${C_RESET}" "$*" >&2; }
warn()    { printf '%s %s\n' "${C_YELLOW}${C_BOLD}!${C_RESET}" "$*" >&2; }
err_msg() { printf '%s %s\n' "${C_RED}${C_BOLD}✗ error:${C_RESET}" "$*" >&2; }

# HTTP helpers (curl preferred, wget fallback).
HTTP_TOOL=""
if command -v curl >/dev/null 2>&1; then
  HTTP_TOOL=curl
elif command -v wget >/dev/null 2>&1; then
  HTTP_TOOL=wget
fi

http_get_stdout() {
  case "$HTTP_TOOL" in
    curl) curl -fsSL --connect-timeout 10 --max-time 30 "$1" ;;
    wget) wget -qO- --timeout=10 "$1" ;;
    *) return 1 ;;
  esac
}

http_download() {
  case "$HTTP_TOOL" in
    curl) curl -fL --progress-bar --connect-timeout 10 -o "$2" "$1" ;;
    wget) wget -q --show-progress --timeout=10 -O "$2" "$1" ;;
    *) return 1 ;;
  esac
}

GOOS=$(detect_goos)
GOARCH=$(detect_goarch)
EXT=""
[[ "$GOOS" == "windows" ]] && EXT=".exe"

# version_lt A B — true (0) when version A is strictly older than B.
version_lt() {
  [[ "$1" == "$2" ]] && return 1
  local lo
  lo=$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)
  [[ "$lo" == "$1" ]]
}

# installed_version — highest bricks version present in ./bin for this
# platform (empty if none).
installed_version() {
  shopt -s nullglob
  local matches=(bin/bricks-*-"${GOOS}-${GOARCH}${EXT}")
  shopt -u nullglob
  ((${#matches[@]})) || return 0
  local f b versions=()
  for f in "${matches[@]}"; do
    b=${f#bin/bricks-}
    b=${b%-"${GOOS}-${GOARCH}${EXT}"}
    versions+=("$b")
  done
  printf '%s\n' "${versions[@]}" | sort -V | tail -n1
}

# have_all_tools VERSION — true when every TOOL is present for this platform.
have_all_tools() {
  local v="$1" t
  for t in "${TOOLS[@]}"; do
    [[ -f "bin/${t}-${v}-${GOOS}-${GOARCH}${EXT}" ]] || return 1
  done
  return 0
}

asset_exists() {
  printf '%s' "$RELEASE_JSON" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$1\""
}

list_platforms() {
  printf '%s' "$RELEASE_JSON" \
    | grep -oE '"bricks-[0-9][^"]*"' \
    | tr -d '"' \
    | sed -E 's/^bricks-[0-9][0-9.]*-//; s/\.exe$//' \
    | sort -u
}

arch_issue_notice() {
  {
    printf '\n'
    printf '%s\n' "${C_YELLOW}${C_BOLD}No prebuilt bricks binaries exist for ${1}.${C_RESET}"
    printf '%s\n' "Please open an issue requesting a ${1} build at:"
    printf '    %s\n' "${C_CYAN}${ISSUES_URL}${C_RESET}"
    printf '\n'
  } >&2
}

manual_download_hint() {
  local v="$1" t
  {
    printf '\n'
    printf '%s\n' "${C_BOLD}Download the latest release manually from:${C_RESET}"
    printf '    %s\n' "${C_CYAN}${RELEASES_URL}${C_RESET}"
    printf '\n'
    printf '%s\n' "Then place these files into ${C_BOLD}./bin${C_RESET} (use the newest version):"
    for t in "${TOOLS[@]}"; do
      printf '    %s\n' "${t}-${v}-${GOOS}-${GOARCH}${EXT}"
    done
    printf '\n'
    printf '%s\n' "Make them executable (chmod +x ./bin/*) and re-run this script."
  } >&2
}

download_release() {
  local base="${RELEASES_URL}/download/${TAG}"
  local t name url out tmp failed=()
  info "downloading bricks ${WANT_VER} for ${GOOS}/${GOARCH} ..."
  for t in "${TOOLS[@]}"; do
    name="${t}-${WANT_VER}-${GOOS}-${GOARCH}${EXT}"
    url="${base}/${name}"
    out="bin/${name}"
    tmp="${out}.part"
    step "${name}"
    if http_download "$url" "$tmp"; then
      mv -f "$tmp" "$out"
      chmod +x "$out" 2>/dev/null || true
    else
      rm -f "$tmp"
      failed+=("$name")
    fi
  done
  if ((${#failed[@]})); then
    err_msg "failed to download ${#failed[@]} file(s): ${failed[*]}"
    manual_download_hint "$WANT_VER"
    return 1
  fi
  return 0
}

cleanup_old_versions() {
  local t f
  shopt -s nullglob
  for t in "${TOOLS[@]}"; do
    for f in bin/"${t}"-*-"${GOOS}-${GOARCH}${EXT}"; do
      [[ "$f" == "bin/${t}-${WANT_VER}-${GOOS}-${GOARCH}${EXT}" ]] || rm -f "$f"
    done
  done
  shopt -u nullglob
}

# sync_binaries — ensure ./bin has the latest bricks toolchain for this
# platform (download when missing or outdated). Returns 0 when usable
# binaries are present afterwards, non-zero (after guidance) when not.
sync_binaries() {
  if [[ -z "$GOOS" || -z "$GOARCH" ]]; then
    local plat; plat="$(uname -s 2>/dev/null)/$(uname -m 2>/dev/null)"
    err_msg "unsupported platform: ${plat}"
    printf '%s\n' "bricks publishes binaries for: darwin/arm64, linux/amd64, linux/armv7, windows/amd64." >&2
    arch_issue_notice "${plat}"
    return 1
  fi

  mkdir -p bin

  local installed
  installed=$(installed_version)

  local online=0
  RELEASE_JSON=""
  if [[ -n "$HTTP_TOOL" ]] && RELEASE_JSON=$(http_get_stdout "$API_LATEST" 2>/dev/null); then
    online=1
  fi
  if ((online)); then
    TAG=$(printf '%s' "$RELEASE_JSON" | grep -m1 '"tag_name"' \
          | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/') || TAG=""
    [[ -n "$TAG" ]] || online=0
  fi

  if ((online)); then
    WANT_VER=${TAG#v}
    if ! asset_exists "bricks-${WANT_VER}-${GOOS}-${GOARCH}${EXT}"; then
      if [[ -n "$installed" ]] && have_all_tools "$installed"; then
        warn "release ${TAG} has no binaries for ${GOOS}/${GOARCH}; using installed ${installed}."
        return 0
      fi
      err_msg "release ${TAG} has no prebuilt binaries for ${GOOS}/${GOARCH}."
      local plats; plats=$(list_platforms) || true
      [[ -n "$plats" ]] && printf 'Platforms available in %s:\n%s\n' "$TAG" "$plats" >&2
      arch_issue_notice "${GOOS}/${GOARCH}"
      return 1
    fi

    if [[ -n "$installed" ]] && have_all_tools "$installed" && ! version_lt "$installed" "$WANT_VER"; then
      success "bricks ${installed} is up to date."
      return 0
    fi

    if [[ -z "$installed" ]]; then
      info "no local install found — fetching bricks ${WANT_VER}."
    elif version_lt "$installed" "$WANT_VER"; then
      info "newer version available: ${installed} → ${WANT_VER}."
    else
      info "completing bricks ${WANT_VER} install (some binaries were missing)."
    fi

    download_release || return 1
    cleanup_old_versions
    success "bricks ${WANT_VER} binaries ready in ./bin."
    return 0
  fi

  # ---- offline ----
  if [[ -n "$installed" ]] && have_all_tools "$installed"; then
    warn "could not reach GitHub (no internet?). Skipping update check; using installed bricks ${installed}."
    return 0
  fi
  err_msg "no internet connection and ./bin has no usable bricks for ${GOOS}/${GOARCH}."
  manual_download_hint "${installed:-<version>}"
  return 1
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

# Make sure ./bin has the latest bricks binaries (download if missing or out
# of date); on no network, point the user at the releases page and stop.
sync_binaries || exit 1

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
