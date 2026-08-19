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

# One line in the migrations cannot run against a plain Postgres: `create
# extension pg_cron`, whose control file only the hosted project has. The
# `cron.schedule` calls around it are stubbed in stub-project.sql and do run, so
# the scheduling still has to be right — it is only the extension that is
# skipped. Done on a copy so the migrations themselves are never edited.
staged="$data/migrations"
mkdir -p "$staged"
cp "$migrations"/*.sql "$staged"/
sed -i.bak 's|^create extension if not exists pg_cron.*$|-- pg_cron: skipped by supabase/tests/run.sh|' "$staged"/*.sql
rm -f "$staged"/*.bak

for f in "$staged"/*.sql; do
    printf 'applying %s\n' "$(basename "$f")"
    # Not `|| true`. A migration that aborts halfway leaves every function after
    # the failure unapplied and the tests then check a schema nobody will ever
    # deploy — which is exactly how the pg_cron failure above went unnoticed.
    if ! out=$(run -f "$f" 2>&1); then
        echo "$out" | grep -v '^NOTICE' >&2
        echo "FAILED applying $(basename "$f")" >&2
        exit 1
    fi
done

# Every behaviour file in this directory, not just the first one somebody
# thought of. Each decides for itself whether a failing statement is fatal:
# profiles.sql turns ON_ERROR_STOP off because half of what it checks is a
# denial, and live_status.sql leaves it on because every check there is an
# assertion that should stop the run.
status=0
for f in "$here"/*.sql; do
    [ "$(basename "$f")" = 'stub-project.sql' ] && continue
    echo
    echo "--- $(basename "$f" .sql)"
    run -f "$f" || status=1
done

exit $status
