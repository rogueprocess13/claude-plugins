#!/usr/bin/env bash
# test-planner-draft-readiness-gate-flow.sh — planner-draft-readiness slice
# S2b, scenarios 1–3 of the halt-only draft readiness gate. Split from
# test-planner-draft-readiness-gate.sh with the scenario bodies unchanged;
# shared setup and stubs live in draft-readiness-gate-harness.sh.
#
# Covers:
#   1. A first run lists a scan per draft, then an audit, then `done 0`;
#      every draft gets a verdict and the gate passes. No ticket manifest, no
#      _index entry and no Linear call.
#   2. A second run on unchanged specs spawns nothing; both runs write their
#      own `draft-readiness|done` line.
#   3. Editing one spec re-evaluates only that spec.
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-readiness-gate-flow.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/draft-readiness-gate-harness.sh"

echo "=== planner draft readiness gate (S2b): flow ==="

# ── 1. first run ─────────────────────────────────────────────────────────
echo "--- 1. first run: scan, audit, verdicts ---"
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1
l1=$(planner_draft_readiness_next "$INIT")
if [ "$(printf '%s\n' "$l1" | cut -f1,2 | tr '\t\n' ': ')" = "a-schema:scan b-api:scan " ]; then
  pass "first list: one scan per draft"
else
  fail "first list" "$l1"
fi
_spawn_list "$l1"
planner_draft_readiness_apply "$INIT"
l2=$(planner_draft_readiness_next "$INIT")
if [ "$(printf '%s\n' "$l2" | cut -f2 | sort -u)" = "audit" ] && [ "$(printf '%s\n' "$l2" | grep -c .)" = 2 ]; then
  pass "second list: the audits, built after the scans returned"
else
  fail "second list" "$l2"
fi
_spawn_list "$l2"
planner_draft_readiness_apply "$INIT"
l3=$(planner_draft_readiness_next "$INIT")
rc=0
planner_draft_readiness_gate "$INIT" >/dev/null 2>&1 || rc=$?
if [ "$l3" = "done 0" ] && [ "$rc" -eq 0 ] &&
  grep -q '|META|draft-readiness|done|ready 2/2$' "$LOG" &&
  [ "$(cut -d' ' -f3 "${DR}/a-schema/verdict")" = "ready" ] && [ -s "${DR}/b-api/semantic.json" ]; then
  pass "done 0, verdicts ready, gate passes with ready 2/2"
else
  fail "first gate" "l3=$l3 rc=$rc $(tail -3 "$LOG")"
fi
if [ ! -e "${REPOS_ROOT}/.ticket-auto/initiatives/_index" ] && [ ! -e "${IDIR}/tickets" ] &&
  [ ! -s "$LINEAR_CALLS" ] && [ -z "$(ls -A "$TMPDIR")" ]; then
  pass "no ticket manifest, no _index entry, no Linear call, sandbox removed"
else
  fail "side effects" "$(find "$REPOS_ROOT" -name manifest.json) $(ls -A "$TMPDIR")"
fi

# ── 2. cache ─────────────────────────────────────────────────────────────
echo "--- 2. unchanged specs: cache hit ---"
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$SPAWNS" -eq 0 ] && [ "$(_done_count)" -eq 2 ]; then
  pass "second run spawns nothing; both runs wrote their own done line"
else
  fail "cache" "rc=$GATE_RC spawns=$SPAWNS done=$(_done_count)"
fi

# ── 3. one spec edited ───────────────────────────────────────────────────
echo "--- 3. one edited spec ---"
sed -i 's/The Export button appears on the invoice list/The Export button appears on the invoice list toolbar/' "${SPECS}/a-schema.md"
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1
l=$(planner_draft_readiness_next "$INIT")
if [ "$(printf '%s\n' "$l" | cut -f1,2)" = "$(printf 'a-schema\tscan')" ]; then
  pass "only the edited spec is re-evaluated"
else
  fail "edit" "$l"
fi
_spawn_list "$l"
planner_draft_readiness_apply "$INIT"
_spawn_list "$(planner_draft_readiness_next "$INIT")"
planner_draft_readiness_apply "$INIT"
planner_draft_readiness_gate "$INIT" >/dev/null 2>&1
[ "$(wc -l <"$CROSSCHECK_CALLS")" -eq 0 ] && pass "no blocked run before: Crosscheck not re-run" ||
  fail "crosscheck rerun" "$(wc -l <"$CROSSCHECK_CALLS")"

# A spawn list from a crashed run is dropped by begin (no failed attempt),
# and every list is strictly spawn rows or `done N`.
sed -i 's/invoice list toolbar/invoice list toolbar menu/' "${SPECS}/a-schema.md"
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1
planner_draft_readiness_next "$INIT" >/dev/null 2>&1 # crash: no agent ran
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1
l=$(planner_draft_readiness_next "$INIT" 2>/dev/null)
if [ ! -e "${DR}/a-schema/attempts" ] && grep -q $'^a-schema\tscan\t' <<<"$l" &&
  printf '%s\n' "$l" | awk -F'\t' 'NF != 5 { bad = 1 } END { exit bad }'; then
  pass "begin drops a stale spawn list; list rows have 5 fields"
else
  fail "stale pending" "attempts=$(cat "${DR}/a-schema/attempts" 2>/dev/null) l=$l"
fi
_spawn_list "$l"
planner_draft_readiness_apply "$INIT"
_spawn_list "$(planner_draft_readiness_next "$INIT")"
planner_draft_readiness_apply "$INIT"
planner_draft_readiness_gate "$INIT" >/dev/null 2>&1

_gate_finish 4
