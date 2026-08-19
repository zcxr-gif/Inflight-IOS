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

# `|| true` on purpose: a couple of migrations need things a bare PostgreSQL
# has not got (pg_cron, and a function that lives outside this repo), and
# stopping on those would mean nobody could run the suite at all. The cost is
# that a migration which is simply *broken* scrolls past in the same way — which
# is how a truncated `grant` once shipped from here looking fine. So the
# failures are collected and named at the end, where they cannot be missed.
failed=()
for f in "$migrations"/*.sql; do
    printf 'applying %s\n' "$(basename "$f")"
    # Output and status captured separately, and deliberately. Piping straight
    # into `grep -v` would report the *grep's* status, and `grep -v` exits 1
    # when it filters everything away — so every migration that applied in
    # silence would be recorded as a failure.
    out=$(run -f "$f" 2>&1) && status=0 || status=$?
    printf '%s\n' "$out" | grep -v '^NOTICE' || true
    if [ "$status" -ne 0 ]; then
        failed+=("$(basename "$f")")
    fi
done

if [ ${#failed[@]} -gt 0 ]; then
    echo
    echo "--- migrations that did NOT apply cleanly"
    printf '    %s\n' "${failed[@]}"
    echo "    (pg_cron and pilot_landing_board are expected here; anything else is a bug)"
fi

echo
echo '--- behaviour'
psql -h /tmp -p "$port" -U postgres -f "$here/profiles.sql" 2>&1 \
    | grep -v '^SET$\|^RESET$'
