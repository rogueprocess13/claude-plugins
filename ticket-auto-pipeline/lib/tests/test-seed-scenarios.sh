#!/usr/bin/env bash
# test-seed-scenarios.sh — lib/seed-scenarios.sh and its wiring (GitHub #601):
# a ticket's seeder scenarios run twice as a VERIFY precheck, inside VERIFY's
# locked section and before any criterion; implement only checks statically
# and never touches the shared stack or the verify lock.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS="$LIB_DIR/../skills"
VERIFY="$SKILLS/ticket-verify/SKILL.md"
IMPLEMENT="$SKILLS/ticket-implement/SKILL.md"
SCEN="$LIB_DIR/seed-scenarios.sh"

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
  echo "$d"
}

_scen() { (eval "$(bash "$SCEN" "$@" 2>/dev/null)" && printf '%s' "$SEED_SCENARIOS"); }

d=$(_mk plan)
printf -- '- [ ] 8.6 `seed.sh bto_167` local run\n- [ ] 8.7 reset with seed.sh baseline\n- [ ] 8.8 `seed.sh --reset bto_168`\n' >"$TMP/tasks.md"
_expect "scenarios from the plan; baseline and the --reset flag excluded" "bto_167 bto_168" "$(_scen "$d" "$TMP/tasks.md")"

d=$(_mk ctx)
printf '\n- [ ] `seed.sh bto_171` exits 0 on two runs\n' >>"$d/context.md"
_expect "scenario named in a context.md AC" "bto_171" "$(_scen "$d")"

d=$(_mk cmd)
printf '\nSeed command: make -C seed bto\n' >>"$d/context.md"
_expect "Seed command: line counts" "seed-command" "$(_scen "$d")"

d=$(_mk none)
_expect "no scenario -> empty" "" "$(_scen "$d")"
bash "$SCEN" "$d" >/dev/null
_expect "no scenario -> exit 0" 0 "$?"

bash "$SCEN" >/dev/null 2>&1
_expect "no ticket dir -> exit 2" 2 "$?"

# VERIFY wiring: Step 1.6d sits after seed-apply (1.6c, inside the lock) and
# before the pre-flight/criteria, releases the lock on failure and reports a
# normal FAIL with a REMEDIATION_BRIEF.
_line() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }
l16c=$(_line "$VERIFY" '^### 1.6c')
l16d=$(_line "$VERIFY" '^### 1.6d — Seeder precheck')
l17=$(_line "$VERIFY" '^## Step 1.7')
sec=$(sed -n '/^### 1.6d/,/^---$/p' "$VERIFY")
if [ -n "$l16d" ] && [ "$l16d" -gt "$l16c" ] && [ "$l16d" -lt "$l17" ] &&
  grep -q 'seed-scenarios.sh' <<<"$sec" && grep -q 'twice' <<<"$sec" &&
  grep -q 'verify_lock_release' <<<"$sec" && grep -q 'REMEDIATION_BRIEF' <<<"$sec" &&
  grep -q 'Step 7' <<<"$sec"; then
  _expect "ticket-verify runs the seeder precheck in the locked section before the criteria" ok ok
else
  _expect "ticket-verify runs the seeder precheck in the locked section before the criteria" ok missing
fi

# Implement: static checks plus a pointer, no stack, no lock, no reset.
if grep -q 'VERIFY Step 1.6d' "$IMPLEMENT" &&
  ! grep -qE 'verify_lock|seed-run-check|SEED_RESET_CMD|reset DB' "$IMPLEMENT"; then
  _expect "ticket-implement only checks statically and points at VERIFY 1.6d" ok ok
else
  _expect "ticket-implement only checks statically and points at VERIFY 1.6d" ok missing
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
