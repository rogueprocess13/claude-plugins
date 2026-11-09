#!/usr/bin/env bash
# test-planner-draft-readiness-loop-regression.sh — planner-draft-readiness slice S3b
# (design D8, D11, D12, D14): the bounded auto-revise loop of the draft
# readiness gate — revision regression, audit MISSED entries and a forged round plan.
# The harness, stub agents and the _gate driver are in
# draft-readiness-loop-harness.sh; the suite is split over four
# test-planner-draft-readiness-loop-*.sh files so the parallel runner can
# spread it.
#
# Covers (tasks.md 6.7):
#  16. a revision that raises a new structural finding is reverted
#      (REVISION_REGRESSION, class `reverted`) instead of halting; a
#      structural finding already present is not a regression
#  17. audit MISSED entries: a security one blocks and takes the revise /
#      round-limit security path; others are advisories in the gate report
#  12b. an agent-written round plan in the workspace is an out-of-scope edit
#      (the real plan lives outside the workspace)
#  12. (every file) no Linear call, no ticket manifest, no snapshot left
#      behind
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-readiness-loop-regression.sh

# shellcheck source=draft-readiness-loop-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/draft-readiness-loop-harness.sh"

echo "=== planner draft readiness revise loop (S3b): regression ==="

# ── 16. revision regression: a new structural finding reverts ────────────
echo "--- 16. a revision that creates a contradiction is reverted ---"
_setup INIT-L16
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
# The fix adds FIXTEXT; the evaluator then raises a structural code on it
# (never revisable, never demoted) — as a contradiction with a frozen
# section would be.
export AFTER_b_api="INTENT_AC_MISMATCH|${FIXTEXT}|contradicts the Technical Context route"
cp "${SPECS}/b-api.md" "${TMP_ROOT}/b-api.orig16"
_gate
if [ "$(_status b-api 1)" = "reverted:REVISION_REGRESSION" ] &&
  [ "$(_status b-api 2)" = "reverted:REVISION_REGRESSION" ] &&
  cmp -s "${SPECS}/b-api.md" "${TMP_ROOT}/b-api.orig16" &&
  _run_lines | grep -q '|META|draft-revise|fail|b-api round=1 REVISION_REGRESSION "INTENT_AC_MISMATCH"$' &&
  ! jq -e '[.findings[] | select(.code == "INTENT_AC_MISMATCH")] | length > 0' "${DR}/b-api/semantic.json" >/dev/null; then
  pass "both revisions reverted REVISION_REGRESSION; spec restored; the contradiction never reaches the verdict"
else
  fail "regression revert" "st1=$(_status b-api 1) st2=$(_status b-api 2) $(jq -c .findings "${DR}/b-api/semantic.json") $(_run_lines | grep -E 'draft-revise')"
fi
if [ "$GATE_RC" -eq 0 ] &&
  jq -e '[.findings[] | select(.code == "EDGE_CASE_GAP" and .demoted == "round-limit" and .demote_reason == "reverted")] | length == 1' \
    "${DR}/b-api/semantic.json" >/dev/null &&
  [ -z "$(find "${PLANNER_DRAFT_SNAPSHOT_ROOT}/${INIT}" -path '*/eval*' 2>/dev/null)" ]; then
  pass "no halt: the original finding is demoted round-limit, class reverted; pre-round copies dropped"
else
  fail "regression outcome" "rc=$GATE_RC $(jq -c .findings "${DR}/b-api/semantic.json") $(tail -3 "$LOG")"
fi
# A structural finding the pre-round evaluation already had is not a regression.
_setup INIT-L16b
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export STRUCT_b_api="INTENT_AC_MISMATCH|Export downloads a file named invoices.csv"
_gate
if [ "$(_status b-api 1)" = "applied" ] && [ "$GATE_RC" -eq 3 ] &&
  ! _run_lines | grep -q 'REVISION_REGRESSION'; then
  pass "a structural finding present before the revision: applied, the gate halts on it as before"
else
  fail "pre-existing structural" "rc=$GATE_RC st=$(_status b-api 1) $(_run_lines | grep draft-revise)"
fi
# A forged pre-round copy cannot be planted in the workspace: the copy the
# revert reads lives outside it.
case "$(_pdl_eval_dir "$INIT" b-api 1)" in
"${PLANNER_DRAFT_SNAPSHOT_ROOT}/${INIT}/eval/b-api.r1") pass "pre-round copy path is outside the workspace" ;;
*) fail "eval dir" "$(_pdl_eval_dir "$INIT" b-api 1)" ;;
esac
_pdl_eval_dir "$INIT" "../x" 1 >/dev/null 2>&1 && fail "eval dir slug" "accepted ../x" || pass "pre-round copy refuses a path-like slug"

# The revert needs the current spec to be the one the revision produced: a
# hand edit after an interrupted run is never undone.
_setup INIT-L16c
mkdir -p "${DR}/b-api"
echo applied >"${DR}/b-api/revise.r1.status"
e16=$(_pdl_eval_dir "$INIT" b-api 1)
mkdir -p "$e16"
cp "${SPECS}/b-api.md" "${e16}/spec.md"
echo "pre-round body" >"${e16}/body.md"
echo '{"findings":[]}' >"${e16}/semantic.json"
ev16='{"semantic":{"body_hash":"sha256:new","findings":[{"code":"INTENT_AC_MISMATCH","verified":true,"severity":"blocking","units":[]}]},"lineage":{"units":{}}}'
sha256sum <"${SPECS}/b-api.md" | cut -c1-64 >"${e16}/post.sha"
r_match=$(_pdl_regression "$INIT" b-api "$ev16") || r_match="(rc 1)"
echo "hand edit" >>"${SPECS}/b-api.md"
r_edit=$(_pdl_regression "$INIT" b-api "$ev16") || r_edit="(rc 1)"
if [ "$r_match" = "INTENT_AC_MISMATCH" ] && [ "$r_edit" = "(rc 1)" ]; then
  pass "regression only while the spec is the revision's output; a later hand edit is never reverted"
else
  fail "post.sha guard" "match=$r_match edit=$r_edit"
fi
rm -rf "$(dirname "$e16")"

# ── 17. audit MISSED entries ─────────────────────────────────────────────
echo "--- 17. audit MISSED entries ---"
_setup INIT-L17
export MISSED_b_api="MISSING_CORE_AC|no criterion checks the body renders as text; an innerHTML implementation passes every criterion"
export MISSED_a_schema="EDGE_CASE_GAP|a 5xx from the backend leaves the page blank"
export REVISE_b_api=missfix
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$(_status b-api 1)" = "applied" ] && grep -qF "$MISSFIX" "${SPECS}/b-api.md" &&
  jq -e '.[] | select(.code == "MISSING_CORE_AC" and (.id | startswith("m-")))' "${DR}/b-api/findings.r1.json" >/dev/null &&
  grep -q 'security: yes' "${DR}/b-api/revise-prompt.r1.txt" && [ ! -e "${DR}/a-schema/revise.r1.status" ]; then
  pass "security MISSED entry blocks and is fed to a revise round (security: yes); the advisory one is not"
else
  fail "missed security round" "rc=$GATE_RC st=$(_status b-api 1) $(cat "${DR}/b-api/findings.r1.json" 2>/dev/null)"
fi
if printf '%s\n' "$GATE_OUT" | grep -q '^Audit advisories (gaps the scan missed; they do not block):' &&
  printf '%s\n' "$GATE_OUT" | grep -qF '  a-schema: EDGE_CASE_GAP — a 5xx from the backend leaves the page blank' &&
  ! printf '%s\n' "$GATE_OUT" | grep -q 'b-api: Security'; then
  pass "non-security MISSED entry listed as an advisory in the pass output"
else
  fail "missed advisory" "$GATE_OUT"
fi
# Re-raised past the budget: demoted round-limit and shown as a security finding.
_setup INIT-L17b
export MISSED_b_api="MISSING_CORE_AC|an innerHTML implementation passes every criterion (XSS)"
export MISSED_AFTER_b_api="MISSING_CORE_AC|the title is still written with innerHTML (XSS)"
export REVISE_b_api=missfix
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$GATE_RC" -eq 0 ] &&
  jq -e '[.findings[] | select(.origin == "audit-missed" and .demoted == "round-limit")] | length == 1' "${DR}/b-api/semantic.json" >/dev/null &&
  _run_lines | grep -q '|META|draft-readiness|warn|b-api SECURITY MISSING_CORE_AC m-[0-9a-f]* "the title is still written with innerHTML (XSS)"$' &&
  printf '%s\n' "$GATE_OUT" | grep -qF 'b-api: MISSING_CORE_AC "the title is still written with innerHTML (XSS)"' &&
  planner_draft_readiness_epic_summary "$INIT" | grep -q '^- Security finding (review): Demoted MISSING_CORE_AC: round-limit'; then
  pass "re-raised past the budget: demoted, SECURITY warn line, pass output, epic summary"
else
  fail "missed past budget" "rc=$GATE_RC $(jq -c .findings "${DR}/b-api/semantic.json") $(_run_lines | grep warn)"
fi
# Halt-only: a security MISSED entry blocks like any security finding.
_setup INIT-L17c
export MISSED_b_api="MISSING_CORE_AC|an innerHTML implementation passes every criterion"
PLANNER_DRAFT_REVISE_MAX_ROUNDS=0 _gate
if [ "$GATE_RC" -eq 3 ] &&
  _run_lines | grep -q '|META|draft-readiness|fail|b-api MISSING_CORE_AC "an innerHTML implementation passes every criterion"$'; then
  pass "halt-only gate: the security MISSED entry is a blocking fail line"
else
  fail "missed halt-only" "rc=$GATE_RC $(_run_lines | grep 'draft-readiness|fail')"
fi
# A structural or unknown code is never turned into a finding.
# An advisory from an evaluation a revision later replaced is still reported.
HIST_DIR=$(mktemp -d)
mkdir -p "${HIST_DIR}/spec-a"
echo '{"missed":[{"code":"EDGE_CASE_GAP","reason":"gap only round one saw"},{"code":"EDGE_CASE_GAP","reason":"gap both saw"}]}' >"${HIST_DIR}/spec-a/semantic.json"
_pdl_missed_record "${HIST_DIR}/spec-a"
echo '{"missed":[{"code":"EDGE_CASE_GAP","reason":"gap both saw"},{"code":"MISSING_CORE_AC","reason":"new gap"}],"findings":[{"origin":"audit-missed","detail":"became a finding"}]}' >"${HIST_DIR}/spec-a/semantic.json"
_pdl_missed_record "${HIST_DIR}/spec-a"
_pdl_missed_record "${HIST_DIR}/spec-a"
hist_report=$(_pdl_root() { echo "$HIST_DIR"; } && planner_draft_readiness_missed_report ANY)
if [ "$(wc -l <"${HIST_DIR}/spec-a/missed-history.jsonl")" -eq 3 ] &&
  printf '%s\n' "$hist_report" | grep -qxF '  spec-a: EDGE_CASE_GAP — gap only round one saw (from an earlier revision)' &&
  printf '%s\n' "$hist_report" | grep -qxF '  spec-a: EDGE_CASE_GAP — gap both saw' &&
  printf '%s\n' "$hist_report" | grep -qxF '  spec-a: MISSING_CORE_AC — new gap' &&
  [ "$(printf '%s\n' "$hist_report" | grep -c 'gap both saw')" -eq 1 ]; then
  pass "MISSED advisories survive a later evaluation, deduped, earlier ones marked"
else
  fail "missed history" "$hist_report"
fi
# The history is a workspace file: forged text is cleaned on the way out.
{
  echo 'not json'
  echo '["array"]'
  printf '{"code":"EDGE_CASE_GAP","reason":"forged\\u001b[31m red\\nsecond line"}\n'
} >>"${HIST_DIR}/spec-a/missed-history.jsonl"
hist_report=$(_pdl_root() { echo "$HIST_DIR"; } && planner_draft_readiness_missed_report ANY)
if ! printf '%s' "$hist_report" | grep -q $'\033' && ! printf '%s\n' "$hist_report" | grep -qE 'not json|array|^second line' &&
  printf '%s\n' "$hist_report" | grep -qF 'forged [31m red second line (from an earlier revision)'; then
  pass "a forged history line is cleaned, a malformed one skipped"
else
  fail "missed history forged" "$hist_report"
fi
rm -rf "$HIST_DIR"
m=$(_pdl_missed_findings '{"missed":[{"code":"CONTRADICTORY_REQUIREMENTS","reason":"XSS via innerHTML"},{"code":"MADE_UP","reason":"XSS"},{"code":"EDGE_CASE_GAP","reason":"layout"}]}')
[ "$m" = "[]" ] && pass "structural, unknown and non-security MISSED codes stay advisory" || fail "missed filter" "$m"

# ── 12b. forged round plan ───────────────────────────────────────────────
echo "--- 12b. an agent-written round plan is an out-of-scope edit ---"
_setup INIT-L12
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=forge
cp "${SPECS}/b-api.md" "${TMP_ROOT}/b-api.orig"
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$(_status b-api 1)" = "reverted:OUT_OF_SCOPE_EDIT" ] && [ ! -e "${DR}/round" ] &&
  cmp -s "${SPECS}/b-api.md" "${TMP_ROOT}/b-api.orig" &&
  [ ! -e "${PLANNER_DRAFT_SNAPSHOT_ROOT}/${INIT}/round" ] &&
  _run_lines | grep -q '|META|draft-revise|fail|b-api round=1 OUT_OF_SCOPE_EDIT ' && [ "$GATE_RC" -eq 0 ]; then
  pass "forged 'settled' plan: guards still ran, round reverted OUT_OF_SCOPE_EDIT, forged file removed"
else
  fail "forged plan" "rc=$GATE_RC st=$(_status b-api 1) $(ls "${DR}") $(_run_lines | grep draft-revise)"
fi

_loop_side_effects
_loop_finish
