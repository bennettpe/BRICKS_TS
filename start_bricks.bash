#!/usr/bin/env bash
# start_bricks.bash — bootstrap and launch the bricks server.
#
# Usage:
#   ./start_bricks.bash [extra bricks args...]
#
# What it does, in order:
#   1. Detects this machine's OS/architecture.
#   2. Creates ./bin if needed.
#   3. Checks https://github.com/moshix/BRICKS_TS/releases for the latest
#      release and downloads bricks plus every auxiliary binary
#      (brickscompile, bricksconvert, bricksdesigner, bricksload,
#      brickspw, idcams) for this platform — but only if they are
#      missing or a newer version is available.
#   4. Launches bricks against ./bricks.cnf.
#
# If there is no internet connection the script uses whatever binaries are
# already in ./bin; if none are present it prints the releases URL and the
# exact filenames to download by hand, then exits.
#
# Extra arguments are forwarded to bricks (e.g. -no-console). The config
# defaults to ./bricks.cnf; pass `-conf <path>` to override it. The script
# operates from its own directory, so ./bin, ./bricks.cnf and the
# runtime/ + data/ trees are resolved there regardless of the caller's cwd.
#
# Honors NO_COLOR (disable ANSI colors).

set -euo pipefail

cd -- "$(dirname -- "$0")"

# ---------------------------------------------------------------------------
# Release / download configuration
# ---------------------------------------------------------------------------
REPO="moshix/BRICKS_TS"
RELEASES_URL="https://github.com/${REPO}/releases"
API_LATEST="https://api.github.com/repos/${REPO}/releases/latest"

# Every binary that makes up a complete bricks install. build.bash and the
# release name them <tool>-<version>-<goos>-<goarch>[.exe].
TOOLS=(bricks brickscompile bricksconvert bricksdesigner bricksload brickspw idcams)

# Globals populated by sync_binaries / its helpers.
RELEASE_JSON=""
TAG=""
WANT_VER=""

# ---------------------------------------------------------------------------
# Colored, stderr-only logging (stdout stays clean for piping)
# ---------------------------------------------------------------------------
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
error()   { printf '%s %s\n' "${C_RED}${C_BOLD}✗ error:${C_RESET}" "$*" >&2; }

# ---------------------------------------------------------------------------
# HTTP helpers (curl preferred, wget fallback)
# ---------------------------------------------------------------------------
HTTP_TOOL=""
if command -v curl >/dev/null 2>&1; then
  HTTP_TOOL=curl
elif command -v wget >/dev/null 2>&1; then
  HTTP_TOOL=wget
fi

# http_get_stdout URL — print the response body on stdout, non-zero on error.
http_get_stdout() {
  case "$HTTP_TOOL" in
    curl) curl -fsSL --connect-timeout 10 --max-time 30 "$1" ;;
    wget) wget -qO- --timeout=10 "$1" ;;
    *) return 1 ;;
  esac
}

# http_download URL OUTFILE — download to OUTFILE (with a progress bar),
# non-zero on any HTTP/transport error so the caller can fall back.
http_download() {
  case "$HTTP_TOOL" in
    curl) curl -fL --progress-bar --connect-timeout 10 -o "$2" "$1" ;;
    wget) wget -q --show-progress --timeout=10 -O "$2" "$1" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Platform detection — map the running machine onto the release naming
# (<tool>-<version>-<goos>-<goarch>[.exe]). Empty output => unsupported.
# ---------------------------------------------------------------------------
detect_goos() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo darwin ;;
    Linux) echo linux ;;
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    *) echo "" ;;
  esac
}

detect_goarch() {
  # build.bash names the 32-bit ARM target "armv7" (GOARCH=arm + GOARM=7).
  case "$(uname -m 2>/dev/null)" in
    arm64 | aarch64) echo arm64 ;;
    x86_64 | amd64) echo amd64 ;;
    armv7l | armv6l | armv7 | armhf) echo armv7 ;;
    *) echo "" ;;
  esac
}

GOOS=$(detect_goos)
GOARCH=$(detect_goarch)
EXT=""
[[ "$GOOS" == "windows" ]] && EXT=".exe"

# ---------------------------------------------------------------------------
# Version / inventory helpers
# ---------------------------------------------------------------------------

# version_lt A B — true (0) when version A is strictly older than B.
version_lt() {
  [[ "$1" == "$2" ]] && return 1
  local lo
  lo=$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)
  [[ "$lo" == "$1" ]]
}

# installed_version — print the highest bricks version present in ./bin for
# this platform (empty if none).
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

# asset_exists NAME — true when the latest release advertises an asset NAME.
asset_exists() {
  printf '%s' "$RELEASE_JSON" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$1\""
}

# list_platforms — the goos-goarch combos the latest release ships bricks for.
list_platforms() {
  printf '%s' "$RELEASE_JSON" \
    | grep -oE '"bricks-[0-9][^"]*"' \
    | tr -d '"' \
    | sed -E 's/^bricks-[0-9][0-9.]*-//; s/\.exe$//' \
    | sort -u
}

# manual_download_hint VERSION — tell the user exactly what to fetch by hand.
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

# download_release — fetch every TOOL for WANT_VER/TAG into ./bin.
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
    error "failed to download ${#failed[@]} file(s): ${failed[*]}"
    manual_download_hint "$WANT_VER"
    return 1
  fi
  return 0
}

# cleanup_old_versions — drop stale per-tool binaries for this platform so
# only WANT_VER remains (keeps ./bin tidy across upgrades).
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
# platform. Returns 0 when usable binaries are present afterwards, non-zero
# (after printing guidance) when they are not.
sync_binaries() {
  if [[ -z "$GOOS" || -z "$GOARCH" ]]; then
    error "unsupported platform: $(uname -s 2>/dev/null)/$(uname -m 2>/dev/null)"
    printf '%s\n' "bricks ships binaries for: darwin/arm64, linux/amd64, linux/armv7, windows/amd64." >&2
    manual_download_hint "<version>"
    return 1
  fi

  mkdir -p bin

  local installed
  installed=$(installed_version)

  # Reach GitHub for the latest release (also our connectivity probe).
  local online=0
  RELEASE_JSON=""
  if [[ -n "$HTTP_TOOL" ]] && RELEASE_JSON=$(http_get_stdout "$API_LATEST" 2>/dev/null); then
    online=1
  fi
  if ((online)); then
    TAG=$(printf '%s' "$RELEASE_JSON" | grep -m1 '"tag_name"' \
          | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/') || TAG=""
    [[ -n "$TAG" ]] || online=0   # reachable but unparsable — treat as offline
  fi

  if ((online)); then
    WANT_VER=${TAG#v}
    if ! asset_exists "bricks-${WANT_VER}-${GOOS}-${GOARCH}${EXT}"; then
      if [[ -n "$installed" ]] && have_all_tools "$installed"; then
        warn "release ${TAG} has no binaries for ${GOOS}/${GOARCH}; using installed ${installed}."
        return 0
      fi
      error "release ${TAG} has no prebuilt binaries for ${GOOS}/${GOARCH}."
      local plats; plats=$(list_platforms) || true
      [[ -n "$plats" ]] && printf 'Platforms available in %s:\n%s\n' "$TAG" "$plats" >&2
      manual_download_hint "$WANT_VER"
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
  error "no internet connection and ./bin has no usable bricks for ${GOOS}/${GOARCH}."
  manual_download_hint "${installed:-<version>}"
  return 1
}

# ---------------------------------------------------------------------------
# 1-3. Make sure the binaries are present and current.
# ---------------------------------------------------------------------------
sync_binaries || exit 1

# ---------------------------------------------------------------------------
# 4. Locate the arch-matched bricks server and launch it.
# ---------------------------------------------------------------------------
# find_bricks prints the path to the arch-matched bricks server binary in
# bin/ and returns 0; returns 1 when none is found and 2 when a match exists
# but isn't executable. The literal "bricks-" (with the dash) excludes the
# sibling helpers brickscompile / bricksconvert / bricksdesigner / bricksload
# / brickspw, whose names have no dash right after "bricks".
find_bricks() {
  [[ -z "$GOOS" || -z "$GOARCH" ]] && return 1
  local matches=()
  shopt -s nullglob
  matches=(bin/bricks-*-"${GOOS}-${GOARCH}${EXT}")
  shopt -u nullglob
  ((${#matches[@]})) || return 1
  local bin
  bin=$(printf '%s\n' "${matches[@]}" | sort -V | tail -1)
  if [[ ! -x "$bin" ]]; then
    printf '%s\n' "$bin"
    return 2
  fi
  printf '%s\n' "$bin"
  return 0
}

rc=0
BIN=$(find_bricks) || rc=$?
if [[ $rc -ne 0 && $rc -ne 2 ]]; then
  error "no bricks server for ${GOOS:-?}/${GOARCH:-?} found in ./bin."
  manual_download_hint "${WANT_VER:-<version>}"
  exit 1
fi

# rc==2: the matched binary exists but isn't executable. Make it so — unlike
# a temporary tool run, we exec into the server, so the chmod is permanent.
if [[ $rc -eq 2 ]]; then
  if ! chmod +x "$BIN" 2>/dev/null; then
    error "'$BIN' is not executable and chmod failed; run: chmod +x '$BIN'"
    exit 1
  fi
  warn "'$BIN' was not executable; made it executable."
fi

# The local config (and the runtime/ + data/ trees referenced from it).
CONF="bricks.cnf"
if [[ ! -f "$CONF" ]]; then
  error "$CONF not found in $(pwd)"
  exit 1
fi

info "starting bricks: ${C_BOLD}$BIN -conf $CONF $*${C_RESET}"
# exec so bricks replaces this shell: signals (Ctrl-C, SIGTERM) and the PID
# pass straight through to the server with no wrapper process.
exec "$BIN" -conf "$CONF" "$@"
