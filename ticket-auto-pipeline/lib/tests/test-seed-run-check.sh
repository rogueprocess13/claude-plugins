#!/usr/bin/env bash
# test-seed-run-check.sh — lib/seed-run-check.sh (GitHub #601): a ticket that
# ships a seeder scenario must have a clean implement-time run on record.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$LIB_DIR/../skills/ticket-implement/SKILL.md"
CHECK="$LIB_DIR/seed-run-check.sh"

PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

_expect() {
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $1 — want [$2] got [$3]"
    FAIL=$((FAIL + 1))
  fi
}

_mk() {
  local d="$TMP/$1"
  mkdir -p "$d"
  printf '# T\n\n## Acceptance Criteria\n\n- [ ] Feature works\n' >"$d/context.md"
  printf '## Session Log\n' >"$d/notes.md"
  echo "$d"
}

# Feature ticket, scenario only in the plan (tasks.md), never run.
d=$(_mk missing)
printf -- '- [ ] 8.6 `seed.sh bto_167` local run\n- [ ] 8.7 reset with seed.sh baseline\n' >"$TMP/tasks.md"
out=$(bash "$CHECK" "$d" "$TMP/tasks.md" --log-file "$d/pipeline.log")
rc=$?
_expect "unrun scenario -> exit 1" 1 "$rc"
_expect "scenario found, baseline excluded" "SEED_SCENARIOS=bto_167" "$(grep '^SEED_SCENARIOS=' <<<"$out")"
_expect "status missing" "SEED_RUN_STATUS=missing" "$(grep '^SEED_RUN_STATUS=' <<<"$out")"
_expect "SEED_RUN_MISSING gate-warn logged" 1 "$(grep -c '|META|gate-warn|warn|SEED_RUN_MISSING' "$d/pipeline.log")"

# Ran on a consumed DB, then on a clean baseline: the last record wins.
printf -- '- seed-run: consumed-db (reused verify DB)\n' >>"$d/notes.md"
out=$(bash "$CHECK" "$d" "$TMP/tasks.md" --log-file "$d/pipeline.log")
_expect "consumed-db record -> status consumed-db" "SEED_RUN_STATUS=consumed-db" "$(grep '^SEED_RUN_STATUS=' <<<"$out")"
_expect "consumed-db logged as info" 1 "$(grep -c '|META|gate-warn|info|SEED_RUN_CONSUMED_DB' "$d/pipeline.log")"
printf -- '- seed-run: clean bto_167 x2\n' >>"$d/notes.md"
bash "$CHECK" "$d" "$TMP/tasks.md" >/dev/null
_expect "clean record -> exit 0" 0 "$?"

# Seed command line in the ticket body, static-only record.
d=$(_mk static)
printf '\nSeed command: make -C seed bto\n' >>"$d/context.md"
printf -- '- seed-run: static-only (stack cannot start)\n' >>"$d/notes.md"
out=$(bash "$CHECK" "$d")
_expect "Seed command: line counts as a scenario" "SEED_SCENARIOS=seed-command" "$(grep '^SEED_SCENARIOS=' <<<"$out")"
_expect "static-only status" "SEED_RUN_STATUS=static-only" "$(grep '^SEED_RUN_STATUS=' <<<"$out")"

# No scenario at all.
d=$(_mk none)
out=$(bash "$CHECK" "$d")
rc=$?
_expect "no scenario -> exit 0" 0 "$rc"
_expect "no scenario -> none" "SEED_RUN_STATUS=none" "$(grep '^SEED_RUN_STATUS=' <<<"$out")"

bash "$CHECK" >/dev/null 2>&1
_expect "no ticket dir -> exit 2" 2 "$?"

# The rule must cover every ticket with a seeder scenario, not only
# test-data-engineer tickets.
if grep -q 'seed-run-check.sh' "$SKILL" && grep -q 'Seeder scenario on any ticket' "$SKILL"; then
  _expect "ticket-implement runs seed-run-check.sh for any seeder scenario" ok ok
else
  _expect "ticket-implement runs seed-run-check.sh for any seeder scenario" ok missing
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
