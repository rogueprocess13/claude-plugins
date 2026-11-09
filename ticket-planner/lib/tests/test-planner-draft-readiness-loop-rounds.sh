#!/usr/bin/env bash
# test-planner-draft-readiness-loop-rounds.sh — planner-draft-readiness slice S3b
# (design D8, D11, D12, D14): the bounded auto-revise loop of the draft
# readiness gate — rounds, rebuttal and the guard revert.
# The harness, stub agents and the _gate driver are in
# draft-readiness-loop-harness.sh; the suite is split over four
# test-planner-draft-readiness-loop-*.sh files so the parallel runner can
# spread it.
#
# Covers (tasks.md 6.7):
#  1. converges in one round; a cached re-run spawns nothing
#  2. budget of 2 rounds honoured across a simulated resume; round 3 is
#     demoted round-limit with reason class `revised`
#  3. a fixable spec is revised before a structural halt in another spec
#  4. rebuttal: no re-evaluation, no second revision, demoted `rebutted`
#  5. guard revert: spec restored, demoted `reverted`; DEMOTE_CEILING halts
#  12. (every file) no Linear call, no ticket manifest, no snapshot left
#      behind
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-readiness-loop-rounds.sh

# shellcheck source=draft-readiness-loop-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/draft-readiness-loop-harness.sh"

echo "=== planner draft readiness revise loop (S3b): rounds ==="

# ── 1. converges ─────────────────────────────────────────────────────────
echo "--- 1. converges in one round ---"
_setup INIT-L1
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$SPAWNS" -eq 7 ] && [ "$REVISES" -eq 1 ] &&
  [ "$(_status b-api 1)" = "applied" ] && grep -qF "$FIXTEXT" "${SPECS}/b-api.md" &&
  [ -s "${DR}/b-api/revise.r1.diff" ] && [ -s "${DR}/b-api/spec.r0.md" ] && [ -s "${DR}/b-api/findings.r1.json" ] &&
  [ ! -e "${PLANNER_DRAFT_SNAPSHOT_ROOT}/${INIT}/round" ] && [ ! -e "${DR}/a-schema/revise.r1.status" ]; then
  pass "4 evaluation spawns, 1 revise, 2 re-evaluation spawns (b-api only); applied; passes"
else
  fail "converge" "rc=$GATE_RC spawns=$SPAWNS revises=$REVISES status=$(_status b-api 1) $(tail -5 "$LOG")"
fi
if [ "$(wc -l <"$CROSSCHECK_CALLS")" -eq 1 ] && [ -s "${DR}/b-api/lineage.json" ] &&
  [ "$(jq -r .round "${DR}/b-api/lineage.json")" = 2 ] && [ -s "${DR}/b-api/lineage.prev.json" ] &&
  _run_lines | grep -q '|META|draft-revise|start|b-api round=1 findings=1$' &&
  _run_lines | grep -q '|META|draft-revise|done|b-api round=1 status=applied resolved=1 rebutted=0 unaddressed=0 added=1 extended=0$' &&
  _run_lines | grep -q '|META|draft-readiness|info|round=1 revise=1 reevaluate=0 spawns=5/16$'; then
  pass "Crosscheck re-ran once; draft lineage round 2 on disk; start/done/info lines"
else
  fail "converge details" "xc=$(wc -l <"$CROSSCHECK_CALLS") $(_run_lines | grep -E 'draft-revise|info')"
fi
if grep -q '^Revision history:' <<<"$GATE_OUT" && grep -q 'b-api: 1 revision(s): applied' <<<"$GATE_OUT"; then
  pass "pass summary lists the revision history"
else
  fail "pass summary" "$GATE_OUT"
fi
_gate
[ "$GATE_RC" -eq 0 ] && [ "$SPAWNS" -eq 0 ] && pass "cached re-run: no spawn, still passes" ||
  fail "cache" "rc=$GATE_RC spawns=$SPAWNS"

# ── 2. max rounds across a resume ────────────────────────────────────────
echo "--- 2. budget of 2 honoured across a resume ---"
_setup INIT-L2
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=nofix
# Crash after the first revise round settles (iterations: scan, audit,
# revise, then stop before re-evaluating).
MAXITER=3 _gate
r1=$(planner_draft_revise_rounds_used "$INIT" b-api)
_gate
if [ "$r1" -eq 1 ] && [ "$GATE_RC" -eq 0 ] && [ "$(planner_draft_revise_rounds_used "$INIT" b-api)" -eq 2 ] &&
  [ ! -e "${DR}/b-api/revise.r3.status" ] && [ "$(jq -r .round "${DR}/b-api/lineage.json")" = 3 ]; then
  pass "two revisions in total across the resume; round 3 evaluation, no third revision"
else
  fail "max rounds" "r1=$r1 rc=$GATE_RC used=$(planner_draft_revise_rounds_used "$INIT" b-api) $(tail -4 "$LOG")"
fi
if jq -e '[.findings[] | select(.code == "EDGE_CASE_GAP" and .severity == "advisory" and .demoted == "round-limit" and .demote_reason == "revised")] | length == 1' \
  "${DR}/b-api/semantic.json" >/dev/null &&
  _run_lines | grep -q '|META|draft-readiness|info|b-api DEMOTED EDGE_CASE_GAP round-limit revised '; then
  pass "the remaining finding is demoted round-limit, reason class revised, and logged"
else
  fail "demotion revised" "$(jq -c '.findings' "${DR}/b-api/semantic.json")"
fi

# ── 3. structural halt after revising the fixable spec ───────────────────
echo "--- 3. fixable spec revised before a structural halt ---"
_setup INIT-L3
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export STRUCT_a_schema="INTENT_AC_MISMATCH|The Export button appears on the invoice list"
_gate
if [ "$GATE_RC" -eq 3 ] && [ "$(_status b-api 1)" = "applied" ] && [ ! -e "${DR}/a-schema/findings.r1.json" ] &&
  _run_lines | grep -q '|META|draft-readiness|fail|a-schema INTENT_AC_MISMATCH ' &&
  ! _run_lines | grep -q '|META|draft-readiness|fail|b-api ' &&
  _run_lines | grep -q '|META|draft-readiness|done|blocked 1/2$'; then
  pass "b-api revised and ready; a-schema never revised; halt on its structural finding"
else
  fail "structural" "rc=$GATE_RC b=$(_status b-api 1) $(_run_lines | grep -E 'fail|done')"
fi
desc=$(planner_stop_describe_json "$INIT")
[ "$(echo "$desc" | jq -r .reason)" = "DRAFT_NOT_READY" ] && pass "describer: DRAFT_NOT_READY" || fail "describer" "$desc"

# ── 4. rebuttal ──────────────────────────────────────────────────────────
echo "--- 4. rebuttal ---"
_setup INIT-L4
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=rebut
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$SPAWNS" -eq 5 ] && [ "$(_status b-api 1)" = "unchanged" ] &&
  [ ! -e "${DR}/b-api/revise.r2.status" ] &&
  _run_lines | grep -q '|META|draft-revise|info|b-api REBUTTAL EDGE_CASE_GAP ' &&
  jq -e '[.findings[] | select(.demote_reason == "rebutted" and .demoted == "round-limit")] | length == 1' "${DR}/b-api/semantic.json" >/dev/null; then
  pass "unchanged: no re-evaluation, no second revision, demoted with reason rebutted"
else
  fail "rebuttal" "rc=$GATE_RC spawns=$SPAWNS st=$(_status b-api 1) $(jq -c .findings "${DR}/b-api/semantic.json")"
fi

# ── 5. guard revert and the demotion ceiling ─────────────────────────────
echo "--- 5. guard revert, demotion ceiling ---"
_setup INIT-L5
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=frozen
cp "${SPECS}/b-api.md" "${TMP_ROOT}/b-api.orig"
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$(_status b-api 1)" = "reverted:FROZEN_CHANGED" ] &&
  [ "$(_status b-api 2)" = "reverted:FROZEN_CHANGED" ] && cmp -s "${SPECS}/b-api.md" "${TMP_ROOT}/b-api.orig" &&
  [ "$(wc -l <"$CROSSCHECK_CALLS")" -eq 0 ] &&
  _run_lines | grep -q '|META|draft-revise|fail|b-api round=1 FROZEN_CHANGED ' &&
  jq -e '[.findings[] | select(.demote_reason == "reverted")] | length == 1' "${DR}/b-api/semantic.json" >/dev/null; then
  pass "both rounds reverted, spec byte-identical, no Crosscheck, demoted reverted (1/2 = ceiling, passes)"
else
  fail "revert" "rc=$GATE_RC $(_status b-api 1) $(_status b-api 2) xc=$(wc -l <"$CROSSCHECK_CALLS")"
fi
PLANNER_DRAFT_DEMOTE_CEILING=0.4 _gate
if [ "$GATE_RC" -eq 3 ] && [ "$SPAWNS" -eq 0 ] &&
  _run_lines | grep -q '|META|draft-readiness|fail|(run) DEMOTE_CEILING "1/2 specs' &&
  _run_lines | grep -q '|META|draft-readiness|done|blocked 0/2 DEMOTE_CEILING$'; then
  pass "a ceiling of 0.4 halts with DEMOTE_CEILING"
else
  fail "ceiling" "rc=$GATE_RC $(_run_lines | grep -E 'fail|done')"
fi
desc=$(planner_stop_describe_json "$INIT")
if echo "$desc" | jq -e '[.questions[].id] | index("draft-run") != null' >/dev/null; then
  pass "describer names the run-level halt"
else
  fail "describer run" "$desc"
fi

_loop_side_effects
_loop_finish
