#!/usr/bin/env bash
# bank_schema.bash -- create the BANK demo database and apply
# bank_schema.sql against it. Idempotent: re-running is safe.
#
# Edit the connection variables below for your local Postgres, or
# override them at the shell:
#
#     BANK_HOST=db.local BANK_USER=alice bash bank_schema.bash
#
# The script needs a Postgres role that can CREATE DATABASE -- the
# usual "bricks" / "postgres" superuser works. The bank_schema.sql
# DDL itself is run as $BANK_USER, who must own the database after
# creation (the script grants ownership explicitly).

set -euo pipefail

# ---- editable connection settings -----------------------------------
BANK_HOST="${BANK_HOST:-localhost}"
BANK_PORT="${BANK_PORT:-5432}"
BANK_USER="${BANK_USER:-bricks}"
BANK_PASS="${BANK_PASS:-bricks}"
BANK_DB="${BANK_DB:-bank}"
# ---------------------------------------------------------------------

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
SCHEMA_SQL="$SCRIPT_DIR/bank_schema.sql"

if [[ ! -f "$SCHEMA_SQL" ]]; then
    echo "bank_schema.bash: $SCHEMA_SQL not found" >&2
    exit 1
fi

export PGPASSWORD="$BANK_PASS"
PSQL_BASE=(psql -h "$BANK_HOST" -p "$BANK_PORT" -U "$BANK_USER"
           -v ON_ERROR_STOP=1 --no-psqlrc)

echo "bank_schema: host=$BANK_HOST port=$BANK_PORT user=$BANK_USER db=$BANK_DB"

# Create the database if it doesn't already exist. CREATE DATABASE
# can't run inside a transaction block, so this is a separate -c.
if "${PSQL_BASE[@]}" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname = '$BANK_DB'" \
        | grep -q '^1$'; then
    echo "bank_schema: database '$BANK_DB' already exists"
else
    echo "bank_schema: creating database '$BANK_DB'"
    "${PSQL_BASE[@]}" -d postgres -c "CREATE DATABASE \"$BANK_DB\""
fi

# Apply the DDL. CREATE TABLE IF NOT EXISTS / ON CONFLICT DO NOTHING
# keep this idempotent.
echo "bank_schema: applying $SCHEMA_SQL"
"${PSQL_BASE[@]}" -d "$BANK_DB" -f "$SCHEMA_SQL"

# Quick post-condition. If any table is missing the schema apply
# silently failed -- surface that rather than reporting success.
TABLE_COUNT=$("${PSQL_BASE[@]}" -d "$BANK_DB" -tAc \
    "SELECT count(*) FROM information_schema.tables
     WHERE table_schema = 'public'
       AND table_name IN ('accounts','transactions',
                          'account_salary','vendors','employers')")
if [[ "$TABLE_COUNT" -ne 5 ]]; then
    echo "bank_schema: expected 5 tables, found $TABLE_COUNT" >&2
    exit 1
fi

echo "bank_schema: ok -- 5/5 tables present"
