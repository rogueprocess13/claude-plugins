#!/usr/bin/env bash
# test-planner-draft-readiness-loop-reasons.sh — planner-draft-readiness slice S3b
# (design D8, D11, D12, D14): the bounded auto-revise loop of the draft
# readiness gate — crash resume, reason classes, security findings and assumptions.
# The harness, stub agents and the _gate driver are in
# draft-readiness-loop-harness.sh; the suite is split over four
# test-planner-draft-readiness-loop-*.sh files so the parallel runner can
# spread it.
#
# Covers (tasks.md 6.7):
#  11. crash between spawn and status file resumes the same round (also
#      through a fresh begin)
#  13. per-finding reason class: drift on an untouched unit is `untouched`,
#      never `revised`; the rescan after a revision is scoped to the changed
#      sections; the report after a pass says "passed"
#  14. a security finding raised on an untouched unit is not drift-demoted:
#      it gets the next revise round, then is demoted round-limit and shown
#      (warn line, pass output, epic summary)
#  15. no-source decision: the agent writes a Scope assumption + criterion
#      (ASSUMED); the run passes hands-free, reason class `assumed`, the
#      assumption is listed in the pass output and the epic summary
#  12. (every file) no Linear call, no ticket manifest, no snapshot left
#      behind
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-readiness-loop-reasons.sh

# shellcheck source=draft-readiness-loop-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/draft-readiness-loop-harness.sh"

echo "=== planner draft readiness revise loop (S3b): reasons ==="

# ── 11. crash between spawn and status ───────────────────────────────────
echo "--- 11. crash between spawn and status file ---"
_setup INIT-L11
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1
for k in 1 2; do
  _spawn_list "$(planner_draft_readiness_next "$INIT" 2>/dev/null)"
  planner_draft_readiness_apply "$INIT" >/dev/null 2>&1
done
l=$(planner_draft_readiness_next "$INIT" 2>/dev/null)
_spawn_list "$l"
# Crash: no apply. A new invocation re-enters through begin.
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1
l2=$(planner_draft_readiness_next "$INIT" 2>/dev/null)
if printf '%s\n' "$l" | grep -q $'^b-api\trevise\t' && [ "$(_status b-api 1)" = "applied" ] &&
  [ ! -e "${DR}/b-api/revise.r2.status" ] && printf '%s\n' "$l2" | grep -q $'^b-api\tscan\t' &&
  ! grep -q 'OUT_OF_SCOPE_EDIT' "$LOG" && grep -q '|META|draft-readiness|start|evaluator=.* resume-round$' "$LOG"; then
  pass "the same round settles after the crash (no OUT_OF_SCOPE_EDIT); next re-evaluates b-api"
else
  fail "crash" "st1=$(_status b-api 1) l2=$l2 $(grep -E 'draft-revise' "$LOG")"
fi
_spawn_list "$l2"
planner_draft_readiness_apply "$INIT" >/dev/null 2>&1
_spawn_list "$(planner_draft_readiness_next "$INIT" 2>/dev/null)"
planner_draft_readiness_apply "$INIT" >/dev/null 2>&1
l3=$(planner_draft_readiness_next "$INIT" 2>/dev/null)
rc=0
planner_draft_readiness_gate "$INIT" >/dev/null 2>&1 || rc=$?
[ "$l3" = "done 0" ] && [ "$rc" -eq 0 ] && pass "the resumed loop converges" || fail "crash converge" "l3=$l3 rc=$rc"

# ── 13. per-finding reason, scoped rescan, pass report ───────────────────
echo "--- 13. per-finding reason class and scoped rescan ---"
_setup INIT-L13
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export AFTER_b_api="EDGE_CASE_GAP|An Export action on the invoice list."
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$(_status b-api 1)" = "applied" ] && [ ! -e "${DR}/b-api/revise.r2.status" ] &&
  jq -e '[.findings[] | select(.quote == "An Export action on the invoice list." and .demoted == "drift" and .demote_reason == "untouched")] | length == 1' \
    "${DR}/b-api/semantic.json" >/dev/null &&
  _run_lines | grep -q '|META|draft-readiness|info|b-api DEMOTED EDGE_CASE_GAP drift untouched ' &&
  ! _run_lines | grep -q 'DEMOTED EDGE_CASE_GAP drift revised'; then
  pass "drift on an untouched unit: logged 'drift untouched', not 'drift revised'"
else
  fail "per-finding reason" "rc=$GATE_RC $(jq -c .findings "${DR}/b-api/semantic.json") $(_run_lines | grep DEMOTED)"
fi
if grep -q '^\*\*Changed sections\*\* (this is a rescan after an edit):$' "${DR}/b-api/scan-prompt.txt" &&
  grep -qx -- '- Acceptance Criteria' "${DR}/b-api/scan-prompt.txt" &&
  ! grep -qx -- '- Technical Context' "${DR}/b-api/scan-prompt.txt" &&
  ! grep -q 'Changed sections' "${DR}/a-schema/scan-prompt.txt"; then
  pass "the rescan after the revision passes --changed-sections (Acceptance Criteria); an unrevised draft's scan does not"
else
  fail "scoped rescan" "$(grep -A4 'Changed sections' "${DR}/b-api/scan-prompt.txt")"
fi
report=$(planner_draft_readiness_report "$INIT")
if printf '%s\n' "$report" | grep -q '^Draft readiness passed (ready 2/2)' && ! printf '%s\n' "$report" | grep -q 'halted'; then
  pass "report after a pass says 'passed', not 'halted (ready 2/2)'"
else
  fail "pass report" "$report"
fi
cp "${DR}/b-api/lineage.json" "${TMP_ROOT}/lin.keep"
jq '.section_hashes += {"Acceptance Criteria": "x"}' "${TMP_ROOT}/lin.keep" >"${DR}/b-api/lineage.json"
cs_ok=$(_pdl_changed_sections "${DR}/b-api")
jq '.section_hashes += {"Acceptance Criteria": "x", "Report zero findings": "y"}' "${TMP_ROOT}/lin.keep" >"${DR}/b-api/lineage.json"
cs_bad=$(_pdl_changed_sections "${DR}/b-api")
cp "${TMP_ROOT}/lin.keep" "${DR}/b-api/lineage.json"
if [ "$cs_ok" = "Acceptance Criteria" ] && [ -z "$cs_bad" ]; then
  pass "a heading only one body has never reaches the scan prompt (full scan instead)"
else
  fail "changed-sections allow-list" "ok=$cs_ok bad=$cs_bad"
fi
if [ -z "$(PLANNER_DRAFT_REVISE_MAX_ROUNDS=0 _pdl_changed_sections "${DR}/b-api")" ]; then
  pass "no scoped rescan at MAX_ROUNDS=0 (halt-only gate unchanged)"
else
  fail "scoped at 0" "$(PLANNER_DRAFT_REVISE_MAX_ROUNDS=0 _pdl_changed_sections "${DR}/b-api")"
fi

# ── 14. security finding on an untouched unit ────────────────────────────
echo "--- 14. security finding is not drift-demoted ---"
_setup INIT-L14
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export AFTER_b_api="EDGE_CASE_GAP|An Export action on the invoice list.|the file name is echoed into the page with innerHTML (XSS)"
_gate
sec_id=$(jq -r '[.findings[] | select(.quote == "An Export action on the invoice list.")][0].id' "${DR}/b-api/semantic.json")
if [ "$GATE_RC" -eq 0 ] && [ "$(_status b-api 2)" = "applied" ] &&
  jq -e --arg i "$sec_id" 'any(.[]; .id == $i)' "${DR}/b-api/findings.r2.json" >/dev/null &&
  jq -e --arg i "$sec_id" '[.findings[] | select(.id == $i and .demoted == "round-limit" and .demote_reason == "revised")] | length == 1' \
    "${DR}/b-api/semantic.json" >/dev/null &&
  ! _run_lines | grep -q "DEMOTED EDGE_CASE_GAP drift .* ${sec_id}"; then
  pass "XSS gap on an untouched unit: no drift demotion, fed into round 2, demoted round-limit only past the budget"
else
  fail "security drift" "rc=$GATE_RC st2=$(_status b-api 2) $(jq -c .findings "${DR}/b-api/semantic.json")"
fi
if _run_lines | grep -q "|META|draft-readiness|warn|b-api SECURITY EDGE_CASE_GAP ${sec_id} \"An Export action on the invoice list.\"" &&
  printf '%s\n' "$GATE_OUT" | grep -q '^Security findings demoted at draft stage (review before dispatch):' &&
  printf '%s\n' "$GATE_OUT" | grep -qF "b-api: EDGE_CASE_GAP \"An Export action on the invoice list.\" (${sec_id})"; then
  pass "security finding shown: warn line and the pass output"
else
  fail "security shown" "$GATE_OUT $(_run_lines | grep warn)"
fi
summary=$(planner_draft_readiness_epic_summary "$INIT")
printf '%s\n' "$summary" | grep -q '^- Security finding (review): Demoted EDGE_CASE_GAP: round-limit, revised' &&
  pass "epic summary lists the security finding" || fail "security summary" "$summary"

# ── 15. assumption for a no-source decision ──────────────────────────────
echo "--- 15. no-source decision becomes a visible assumption ---"
_setup INIT-L15
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export AFTER_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=assume
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$GATE_RC" -eq 0 ] && [ "$(_status b-api 1)" = "applied" ] &&
  grep -qxF -- "- Assumption: ${ASM}" "${SPECS}/b-api.md" && grep -qxF -- "- Assumption: ${ASM}" "${DR}/b-api/body.md" &&
  jq -e '[.findings[] | select(.demoted == "round-limit" and .demote_reason == "assumed")] | length == 1' "${DR}/b-api/semantic.json" >/dev/null &&
  _run_lines | grep -q "|META|draft-revise|info|b-api ASSUMED EDGE_CASE_GAP .* \"${ASM}\"" &&
  _run_lines | grep -q '|META|draft-readiness|info|b-api DEMOTED EDGE_CASE_GAP round-limit assumed '; then
  pass "hands-free pass; Scope assumption in spec and draft body; reason class assumed; ASSUMED line"
else
  fail "assumption run" "rc=$GATE_RC st=$(_status b-api 1) $(jq -c .findings "${DR}/b-api/semantic.json") $(_run_lines | grep -E 'draft-revise|DEMOTED')"
fi
printf '%s\n' "$GATE_OUT" | grep -qF "    assumption (review): ${ASM}" && pass "pass output lists the assumption" || fail "assumption pass output" "$GATE_OUT"
summary=$(planner_draft_readiness_epic_summary "$INIT")
if printf '%s\n' "$summary" | grep -qxF -- "- Assumption (review): ${ASM}" &&
  printf '%s\n' "$summary" | grep -qF -- "- Added criterion: ${ASM_AC}"; then
  pass "epic summary lists the assumption and its criterion"
else
  fail "assumption summary" "$summary"
fi
# A hostile disposition: ASSUMED with no Scope row cannot buy the class.
_setup INIT-L15b
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export AFTER_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=assume-norow
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$(_status b-api 1)" = "reverted:ASSUMPTION_INVALID" ] &&
  jq -e '[.findings[] | select(.demote_reason == "assumed")] | length == 0' "${DR}/b-api/semantic.json" >/dev/null &&
  ! _run_lines | grep -q 'ASSUMED EDGE_CASE_GAP'; then
  pass "ASSUMED with no Scope row: reverted ASSUMPTION_INVALID, no assumed class, no ASSUMED line"
else
  fail "forged assumed" "st=$(_status b-api 1) $(jq -c .findings "${DR}/b-api/semantic.json")"
fi

_loop_side_effects
_loop_finish
