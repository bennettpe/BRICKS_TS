#!/usr/bin/env bash
# add_brick_user.bash — add (or update) a user in runtime/users.conf.
#
# Usage:
#   ./add_brick_user.bash <username> <password> [groups]
#   ./add_brick_user.bash --update <username> <password> [groups]
#
#   groups is a comma-separated list (e.g. admin,users). Defaults to "users".
#
# The password is hashed with bcrypt via cmd/brickspw before being written.
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

HASH=$(go run ./cmd/brickspw "$PASS")
if [[ -z "$HASH" ]]; then
  echo "error: failed to generate bcrypt hash" >&2
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
