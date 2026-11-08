#!/usr/bin/env bash
# test-seed-run-check.sh — lib/seed-run-check.sh (GitHub #601): a ticket that
# ships a seeder scenario must run it in implement, under the verify lock,
# reset only by the project's SEED_RESET_CMD, and the check must count only
# this implement cycle's record.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$LIB_DIR/../skills/ticket-implement/SKILL.md"
CHECK="$LIB_DIR/seed-run-check.sh"

PASS=0
FAIL=0
TMP=$(mktemp -d)
export VERIFY_LOCK_FILE="$TMP/ticket-verify.lock"
_cleanup() {
  (source "$LIB_DIR/verify-lock.sh" && verify_lock_release) >/dev/null 2>&1
  rm -rf "$TMP"
}
trap _cleanup EXIT

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
printf -- '- [ ] 8.6 `seed.sh bto_167` local run\n- [ ] 8.7 reset with seed.sh baseline\n- [ ] 8.8 `seed.sh --reset bto_168`\n' >"$TMP/tasks.md"
out=$(bash "$CHECK" "$d" "$TMP/tasks.md" --log-file "$d/pipeline.log")
rc=$?
_expect "unrun scenario -> exit 1" 1 "$rc"
_expect "scenarios found; baseline and the --reset flag excluded" "SEED_SCENARIOS=bto_167 bto_168" "$(grep '^SEED_SCENARIOS=' <<<"$out")"
_expect "status missing" "SEED_RUN_STATUS=missing" "$(grep '^SEED_RUN_STATUS=' <<<"$out")"
_expect "SEED_RUN_MISSING logged as an info gate-warn (retro counts info)" 1 "$(grep -c '|META|gate-warn|info|SEED_RUN_MISSING' "$d/pipeline.log")"

# Records via `record` carry a timestamp; the last one wins.
bash "$CHECK" record "$d" consumed-db "(reused verify DB)"
out=$(bash "$CHECK" check "$d" "$TMP/tasks.md" --log-file "$d/pipeline.log")
_expect "consumed-db record -> status consumed-db" "SEED_RUN_STATUS=consumed-db" "$(grep '^SEED_RUN_STATUS=' <<<"$out")"
_expect "consumed-db logged as info" 1 "$(grep -c '|META|gate-warn|info|SEED_RUN_CONSUMED_DB' "$d/pipeline.log")"
bash "$CHECK" record "$d" clean "bto_167 x2"
bash "$CHECK" "$d" "$TMP/tasks.md" >/dev/null
_expect "clean record -> exit 0" 0 "$?"
_expect "record writes a timestamp" 1 "$(grep -cE 'seed-run: clean bto_167 x2 \(at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\)' "$d/notes.md")"

# A record from an earlier implement cycle does not count for the next one.
d=$(_mk stale)
printf -- '- seed-run: clean bto_167 x2 (at 2026-11-01T10:00:00Z)\n- seed-run: clean bto_167 x2\n' >>"$d/notes.md"
printf '2026-11-01T09:00:00Z|IMPLEMENT|implement|start|cycle 1\n2026-11-02T09:00:00Z|IMPLEMENT|implement|waiting|cycle 2\n' >"$d/pipeline.log"
out=$(bash "$CHECK" "$d" "$TMP/tasks.md" --log-file "$d/pipeline.log")
_expect "record older than the current IMPLEMENT start (and an untimestamped one) -> missing" "SEED_RUN_STATUS=missing" "$(grep '^SEED_RUN_STATUS=' <<<"$out")"
printf -- '- seed-run: clean bto_167 x2 (at 2026-11-02T10:00:00Z)\n' >>"$d/notes.md"
out=$(bash "$CHECK" "$d" "$TMP/tasks.md" --log-file "$d/pipeline.log")
_expect "record after the current IMPLEMENT start -> clean" "SEED_RUN_STATUS=clean" "$(grep '^SEED_RUN_STATUS=' <<<"$out")"

# Seed command line in the ticket body.
d=$(_mk static)
printf '\nSeed command: make -C seed bto\n' >>"$d/context.md"
bash "$CHECK" record "$d" static-only "(stack cannot start)"
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
_expect "no arguments -> exit 2" 2 "$?"

# prepare: no project reset command -> never improvise, record static-only.
d=$(_mk noreset)
printf 'REPOS_ROOT = /x\n' >"$TMP/CLAUDE-noreset.md"
out=$(bash "$CHECK" prepare T-1 "$d" --claude-md "$TMP/CLAUDE-noreset.md")
rc=$?
_expect "prepare without SEED_RESET_CMD -> exit 1" 1 "$rc"
_expect "prepare without SEED_RESET_CMD -> static-only" "SEED_RUN_PREPARE=static-only" "$(grep '^SEED_RUN_PREPARE=' <<<"$out")"
_expect "no-reset static-only recorded in notes.md" 1 "$(grep -c 'seed-run: static-only (no SEED_RESET_CMD' "$d/notes.md")"

# prepare: lock free -> locked with the configured command; release frees it.
printf 'SEED_RESET_CMD: `bash env-reset.sh --db`\n' >"$TMP/CLAUDE.md"
d=$(_mk locked)
out=$(bash "$CHECK" prepare T-2 "$d" --claude-md "$TMP/CLAUDE.md" --lock-timeout 5)
rc=$?
_expect "prepare with a free lock -> exit 0" 0 "$rc"
_expect "prepare -> locked" "SEED_RUN_PREPARE=locked" "$(grep '^SEED_RUN_PREPARE=' <<<"$out")"
eval "$(grep '^SEED_RESET_CMD=' <<<"$out")"
_expect "prepare hands back the configured reset command verbatim" "bash env-reset.sh --db" "${SEED_RESET_CMD:-}"

# prepare while the lock is held (VERIFY running) -> static-only (stack busy).
d=$(_mk busy)
out=$(bash "$CHECK" prepare T-3 "$d" --claude-md "$TMP/CLAUDE.md" --lock-timeout 1 2>/dev/null)
rc=$?
_expect "lock busy -> exit 1" 1 "$rc"
_expect "lock busy -> static-only" "SEED_RUN_PREPARE=static-only" "$(grep '^SEED_RUN_PREPARE=' <<<"$out")"
_expect "lock busy recorded as static-only (stack busy)" 1 "$(grep -c 'seed-run: static-only (stack busy' "$d/notes.md")"

bash "$CHECK" release >/dev/null 2>&1
d=$(_mk afterrelease)
out=$(bash "$CHECK" prepare T-4 "$d" --claude-md "$TMP/CLAUDE.md" --lock-timeout 5)
_expect "after release the lock is free again" "SEED_RUN_PREPARE=locked" "$(grep '^SEED_RUN_PREPARE=' <<<"$out")"
bash "$CHECK" release >/dev/null 2>&1

# Skill wiring: the run sits after the code review (Step 4b), not in Step 2,
# and goes through prepare/release.
_line() { grep -n "$1" "$SKILL" | head -1 | cut -d: -f1; }
seeder=$(_line '^\*\*Seeder run (#601)')
review=$(_line '^### Code review')
step4c=$(_line '^## Step 4c')
if [ -n "$seeder" ] && [ -n "$review" ] && [ -n "$step4c" ] &&
  [ "$seeder" -gt "$review" ] && [ "$seeder" -lt "$step4c" ] &&
  grep -q 'seed-run-check.sh prepare' "$SKILL" && grep -q 'seed-run-check.sh release' "$SKILL" &&
  grep -q 'exit 1 is advisory' "$SKILL"; then
  _expect "ticket-implement runs the seeder in Step 4b under the verify lock" ok ok
else
  _expect "ticket-implement runs the seeder in Step 4b under the verify lock" ok missing
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
