#!/usr/bin/env bash
#
# Applies every migration to a throwaway PostgreSQL cluster and runs the
# behaviour tests against it.
#
# Worth having because the interesting half of this schema is not its shape but
# its rules — who may write a Pro column, what a signed-out reader is allowed to
# see, when a report hides a profile — and none of that is visible in a diff.
# Two of the bugs these tests exist for were exactly that kind: a `security
# definer` function that returned NULL for anonymous readers and so failed open,
# and an auto-hide that a write guard silently reverted.
#
#   ./supabase/tests/run.sh
#
# Needs a local PostgreSQL 14+ (`initdb`, `pg_ctl`, `psql` on PATH) and nothing
# else. Never touches the real project.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
migrations="$here/../migrations"
port="${PGTESTPORT:-55432}"
data="${PGTESTDATA:-$(mktemp -d)/pg}"

cleanup() { pg_ctl -D "$data" -m immediate stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

initdb -D "$data" -A trust -U postgres >/dev/null
pg_ctl -D "$data" -l "$data/server.log" -o "-p $port -k /tmp" start >/dev/null
sleep 1

run() { psql -h /tmp -p "$port" -U postgres -v ON_ERROR_STOP=1 -q "$@"; }

# `auth`, `storage`, `profiles`, `subscriptions` — enough of a Supabase project
# for the migrations to have something to attach to.
run -f "$here/stub-project.sql"

for f in "$migrations"/*.sql; do
    printf 'applying %s\n' "$(basename "$f")"
    run -f "$f" 2>&1 | grep -v '^NOTICE' || true
done

echo
echo '--- behaviour'
psql -h /tmp -p "$port" -U postgres -f "$here/profiles.sql" 2>&1 \
    | grep -v '^SET$\|^RESET$'
