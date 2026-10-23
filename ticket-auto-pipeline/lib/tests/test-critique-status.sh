#!/usr/bin/env bash
# test-critique-status.sh — critique-status.sh (DET-AP-1 bug part): a
# critique BLOCKED with no BLOCKER finding must still take the needs-info
# action, and the skill's act-on-results must branch on status.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
CS="$LIB_DIR/critique-status.sh"

PASS=0
FAIL=0
ok() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
nok() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

# expect <name> <score> <blockers> <warnings> <status> <reason> <action> <verdict> <criteria>
expect() {
  local name="$1" out got
  out=$(bash "$CS" --score "$2" --blockers "$3" --warnings "$4" 2>&1) || {
    nok "$name (rc!=0: $out)"
    return
  }
  got=$( (eval "$out" && printf '%s %s %s %s %s' "$CRITIQUE_STATUS" "$CRITIQUE_BLOCK_REASON" "$CRITIQUE_ACTION" "$CRITIQUE_VERDICT" "$CRITIQUE_CRITERIA_MET"))
  if [ "$got" = "$5 $6 $7 $8 $9" ]; then ok "$name"; else nok "$name: got '$got'"; fi
}

expect "no findings → CLEAR" 100 0 0 CLEAR none clear PASS 10
expect "one BLOCKER at ceiling 70 → BLOCKED" 70 1 0 BLOCKED blocker needs-info BLOCK 7
expect "score 39, no BLOCKER → BLOCKED needs-info" 39 0 0 BLOCKED low-score needs-info BLOCK 3
expect "3 WARNINGs, no BLOCKER, score 85 → BLOCKED needs-info" 85 0 3 BLOCKED cumulative-warnings needs-info BLOCK 8
expect "BLOCKER beats escalation" 50 2 4 BLOCKED blocker needs-info BLOCK 5
expect "score 40 → WARNINGS" 40 0 2 WARNINGS none warn WARN 4
expect "score 69 → WARNINGS" 69 0 0 WARNINGS none warn WARN 6
expect "score 70 with 2 WARNINGs → CLEAR" 70 0 2 CLEAR none clear PASS 7
expect "score 0 → BLOCKED" 0 0 0 BLOCKED low-score needs-info BLOCK 0

for bad in "--score x --blockers 0 --warnings 0" "--score 101 --blockers 0 --warnings 0" "--score 50 --blockers 0" "--bogus 1"; do
  # shellcheck disable=SC2086
  if bash "$CS" $bad >/dev/null 2>&1; then nok "usage error: $bad"; else
    # shellcheck disable=SC2086
    bash "$CS" $bad >/dev/null 2>&1
    if [ $? -eq 2 ]; then ok "usage error exits 2: $bad"; else nok "usage error exits 2: $bad"; fi
  fi
done

# The skill's act-on-results branches on status, not on "any BLOCKERs found".
SKILL="$PLUGIN_DIR/skills/ticket-critique/SKILL.md"
if grep -q '^### If any BLOCKERs found' "$SKILL"; then
  nok "ticket-critique acts on BLOCKED status, not BLOCKER count"
elif grep -q 'critique-status.sh' "$SKILL" && grep -q '^### If `CRITIQUE_ACTION=needs-info`' "$SKILL"; then
  ok "ticket-critique acts on BLOCKED status, not BLOCKER count"
else
  nok "ticket-critique acts on BLOCKED status, not BLOCKER count (script not wired)"
fi
if grep -q 'across all checks (0-5)' "$SKILL"; then
  nok "WARNING escalation counts Check 6"
else
  ok "WARNING escalation counts Check 6"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
