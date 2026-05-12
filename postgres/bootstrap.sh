#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh
#
# Apply postgres/schema.sql to a Postgres database, parameterized by schema
# name. Default schema is `prod_bronze` (matches the TDM PoC dictionary).
#
# Usage:
#   ./postgres/bootstrap.sh [SCHEMA_NAME]
#
# Required env:
#   DSN  Postgres DSN, e.g. postgresql://user:pass@host:5432/db?sslmode=require
#
# Optional env:
#   PSQL  Path to psql binary (default: psql on $PATH)
#
# Examples:
#   DSN='postgresql://tdm:secret@db.neon.tech:5432/tdm?sslmode=require' \
#       ./postgres/bootstrap.sh prod_bronze
#
#   DSN='postgresql://tdm:secret@db.neon.tech:5432/tdm?sslmode=require' \
#       ./postgres/bootstrap.sh lower_bronze
#
# Exit codes:
#   0  schema applied successfully
#   1  argument / env validation failed
#   2  psql failed
# =============================================================================
set -euo pipefail

SCHEMA="${1:-prod_bronze}"
PSQL="${PSQL:-psql}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_TEMPLATE="$HERE/schema.sql"

if [[ -z "${DSN:-}" ]]; then
  echo "ERROR: DSN env var is required." >&2
  echo "       Example: export DSN='postgresql://user:pass@host:5432/db?sslmode=require'" >&2
  exit 1
fi

if [[ ! -f "$SQL_TEMPLATE" ]]; then
  echo "ERROR: $SQL_TEMPLATE not found." >&2
  exit 1
fi

if ! command -v "$PSQL" >/dev/null 2>&1; then
  echo "ERROR: '$PSQL' not found on PATH. Install postgresql-client." >&2
  exit 1
fi

case "$SCHEMA" in
  *[!a-zA-Z0-9_]*)
    echo "ERROR: SCHEMA must match [A-Za-z0-9_]+ (got: $SCHEMA)" >&2
    exit 1
    ;;
esac

echo "▸ Target schema   : $SCHEMA"
echo "▸ DSN host        : $(printf '%s' "$DSN" | sed -E 's#.*@([^/?]+).*#\1#')"
echo "▸ Source DDL      : $SQL_TEMPLATE"
echo

RENDERED="$(mktemp -t whacky-doodle-schema.XXXXXX.sql)"
trap 'rm -f "$RENDERED"' EXIT

sed "s/{schema}/$SCHEMA/g" "$SQL_TEMPLATE" > "$RENDERED"

echo "▸ Applying schema (this is idempotent — uses CREATE TABLE IF NOT EXISTS)..."
if "$PSQL" "$DSN" -v ON_ERROR_STOP=1 -f "$RENDERED" > /tmp/whacky-doodle-bootstrap.log 2>&1; then
  echo "✓ Schema $SCHEMA applied successfully."
  echo
  echo "Verify:"
  echo "  $PSQL \"\$DSN\" -c \"\\dt $SCHEMA.*\""
else
  echo "✗ psql failed. See /tmp/whacky-doodle-bootstrap.log for details." >&2
  tail -20 /tmp/whacky-doodle-bootstrap.log >&2
  exit 2
fi
