#!/usr/bin/env bash
# test-planner-refinement.sh — Tests for planner-refinement.sh
# (planner-refinement-phase).
#
# Run: bash ticket-planner/lib/tests/test-planner-refinement.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
FIXTURES_DIR="${LIB_DIR}/../../ticket-auto-pipeline/lib/tests/fixtures/dor"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-refinement.sh"

# Pull dor-check.sh/dor-semantic.sh/manifest-write.sh into this shell too —
# the test scaffolding needs write_ticket_manifest/write_epic_manifest/
# add_epic_manifest_child/check_ticket_ready/_dor_body_hash directly.
_planner_refinement_source_deps

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}

echo "=== planner-refinement tests ==="

INIT_ID="INIT-1700000000-1234"
EPIC_ID="PRO-100"

_planner_dir() {
  echo "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_ID}/tickets/${1}/planner"
}

_setup_epic() {
  planner_state_init "$INIT_ID" "test idea for refinement"
  planner_state_write "$INIT_ID" "EpicGen" "create" "done" "EPIC_ID=${EPIC_ID}"
  planner_state_write "$INIT_ID" "TicketGen" "verify" "done" "N tickets verified."
  write_epic_manifest "$EPIC_ID" "" "per-ticket" "" '[]' >/dev/null
}

# _add_child <TID> <fixture-basename-without-.md>
_add_child() {
  local tid="$1" fixture="$2"
  write_ticket_manifest "$tid" "$INIT_ID" "feature" '[]' >/dev/null
  add_epic_manifest_child "$EPIC_ID" "$tid" >/dev/null
  local pdir
  pdir=$(_planner_dir "$tid")
  mkdir -p "$pdir"
  cp "${FIXTURES_DIR}/${fixture}.md" "${pdir}/body.md"
}

_body_hash() {
  local tid="$1"
  _dor_body_hash "$(cat "$(_planner_dir "$tid")/body.md")"
}

_write_clean_scan() {
  local tid="$1" hash="$2"
  cat >"$(_planner_dir "$tid")/semantic-scan-result.txt" <<EOF
=== DOR_SEMANTIC_SCAN ===
SCHEMA_VERSION: 1
TICKET: ${tid}
BODY_HASH: ${hash}
GAP_REQUIREMENT_COMPLETENESS: clear
GAP_REQUIREMENT_COMPLETENESS_REASON: covered
GAP_CONTRADICTORY_REQUIREMENTS: clear
GAP_CONTRADICTORY_REQUIREMENTS_REASON: covered
GAP_DEEP_SCOPE_AMBIGUITY: clear
GAP_DEEP_SCOPE_AMBIGUITY_REASON: covered
GAP_EDGE_CASE_SUFFICIENCY: clear
GAP_EDGE_CASE_SUFFICIENCY_REASON: covered
=== END DOR_SEMANTIC_SCAN ===
EOF
}

_write_blocking_scan() {
  local tid="$1" hash="$2" quote="$3"
  cat >"$(_planner_dir "$tid")/semantic-scan-result.txt" <<EOF
=== DOR_SEMANTIC_SCAN ===
SCHEMA_VERSION: 1
TICKET: ${tid}
BODY_HASH: ${hash}
FINDING_1_CODE: MISSING_CORE_AC
FINDING_1_QUOTE: ${quote}
FINDING_1_DETAIL: no acceptance criterion covers this behavior
GAP_REQUIREMENT_COMPLETENESS: finding
GAP_REQUIREMENT_COMPLETENESS_REASON: see FINDING_1
GAP_CONTRADICTORY_REQUIREMENTS: clear
GAP_CONTRADICTORY_REQUIREMENTS_REASON: covered
GAP_DEEP_SCOPE_AMBIGUITY: clear
GAP_DEEP_SCOPE_AMBIGUITY_REASON: covered
GAP_EDGE_CASE_SUFFICIENCY: clear
GAP_EDGE_CASE_SUFFICIENCY_REASON: covered
=== END DOR_SEMANTIC_SCAN ===
EOF
}

_write_clean_audit() {
  local tid="$1" hash="$2"
  cat >"$(_planner_dir "$tid")/semantic-audit-result.txt" <<EOF
=== DOR_SEMANTIC_AUDIT ===
SCHEMA_VERSION: 1
TICKET: ${tid}
BODY_HASH: ${hash}
SCORE_PLAUSIBLE: yes
SCORE_REASON: matches
=== END DOR_SEMANTIC_AUDIT ===
EOF
}

_write_disputed_audit() {
  local tid="$1" hash="$2" code="$3" reason="$4"
  cat >"$(_planner_dir "$tid")/semantic-audit-result.txt" <<EOF
=== DOR_SEMANTIC_AUDIT ===
SCHEMA_VERSION: 1
TICKET: ${tid}
BODY_HASH: ${hash}
AUDIT_1_CODE: ${code}
AUDIT_1_VERDICT: disputed
AUDIT_1_REASON: ${reason}
SCORE_PLAUSIBLE: yes
SCORE_REASON: matches
=== END DOR_SEMANTIC_AUDIT ===
EOF
}

# ── 7.6: epic id resolved from the state log / missing EPIC_ID halts ───────

echo "--- epic id resolution ---"

planner_state_init "$INIT_ID" "no epic gen yet"
if ! planner_epic_id "$INIT_ID" >/dev/null 2>&1; then
  pass "planner_epic_id: empty log has no EPIC_ID"
else
  fail "planner_epic_id: empty log has no EPIC_ID" "unexpectedly resolved"
fi

if ! planner_refinement_gate "$INIT_ID" >/dev/null 2>&1; then
  pass "planner_refinement_gate: no EPIC_ID halts (return 1)"
else
  fail "planner_refinement_gate: no EPIC_ID halts (return 1)" "returned 0"
fi
log_file=$(planner_state_log "$INIT_ID")
if grep -q '|META|refinement-gate|fail|no EpicGen EPIC_ID' "$log_file"; then
  pass "planner_refinement_gate: no-EPIC_ID failure logged as META (not phase-named)"
else
  fail "planner_refinement_gate: no-EPIC_ID failure logged as META (not phase-named)" "line missing"
fi
report=$(planner_refinement_report "$INIT_ID")
if echo "$report" | grep -qi "no EpicGen EPIC_ID"; then
  pass "planner_refinement_report: no-EPIC_ID case reported"
else
  fail "planner_refinement_report: no-EPIC_ID case reported" "got: $report"
fi

# Fresh initiative for the rest of the suite.
rm -f "$log_file"
_setup_epic

# ── 7.3 / 7.2: all ready → gate done, epic stamped, position advances ─────

echo "--- all ready ---"

_add_child "PRO-101" "01-excellent"
_add_child "PRO-102" "02-minimal"

needs=$(planner_refinement_scan "$INIT_ID")
if [ "$(echo "$needs" | grep -c .)" = "2" ]; then
  pass "planner_refinement_scan: both fresh tickets need a semantic pass"
else
  fail "planner_refinement_scan: both fresh tickets need a semantic pass" "got: $needs"
fi

for tid in PRO-101 PRO-102; do
  h=$(_body_hash "$tid")
  _write_clean_scan "$tid" "$h"
  _write_clean_audit "$tid" "$h"
  if planner_refinement_apply "$INIT_ID" "$tid"; then
    pass "planner_refinement_apply: clean result applies for $tid"
  else
    fail "planner_refinement_apply: clean result applies for $tid" "returned nonzero"
  fi
done

if planner_refinement_gate "$INIT_ID"; then
  pass "planner_refinement_gate: all ready returns 0"
else
  fail "planner_refinement_gate: all ready returns 0" "returned nonzero"
fi
if grep -q "|Refinement|gate|done|" "$log_file"; then
  pass "planner_refinement_gate: writes Refinement|gate|done"
else
  fail "planner_refinement_gate: writes Refinement|gate|done" "line missing"
fi
if [ "$(get_epic_manifest_field "$EPIC_ID" dispatch 2>/dev/null)" = "true" ]; then
  pass "planner_refinement_gate: epic manifest dispatch=true"
else
  fail "planner_refinement_gate: epic manifest dispatch=true" "not stamped"
fi
if [ "$(planner_position_derive "$INIT_ID")" = "Completed" ]; then
  pass "position after Refinement|gate|done is Completed"
else
  fail "position after Refinement|gate|done is Completed" "got $(planner_position_derive "$INIT_ID")"
fi

# ── 7.5: resume reuses cached verdict for an unchanged body ────────────────

echo "--- resume reuse ---"

needs2=$(planner_refinement_scan "$INIT_ID")
if [ -z "$needs2" ]; then
  pass "planner_refinement_scan: unchanged bodies need no re-evaluation"
else
  fail "planner_refinement_scan: unchanged bodies need no re-evaluation" "got: $needs2"
fi

# Changed body re-lists the ticket.
echo "## Acceptance Criteria" >>"$(_planner_dir "PRO-101")/body.md"
echo "- a newly added, testable criterion" >>"$(_planner_dir "PRO-101")/body.md"
needs3=$(planner_refinement_scan "$INIT_ID")
if [ "$needs3" = "PRO-101" ]; then
  pass "planner_refinement_scan: changed body re-lists only that ticket"
else
  fail "planner_refinement_scan: changed body re-lists only that ticket" "got: $needs3"
fi
# Re-clean it so later tests in this file see a consistent ready state.
h=$(_body_hash "PRO-101")
_write_clean_scan "PRO-101" "$h"
_write_clean_audit "PRO-101" "$h"
planner_refinement_apply "$INIT_ID" "PRO-101" >/dev/null

# SEMANTIC_STALE forces a re-list even with an unchanged body hash.
h=$(_body_hash "PRO-102")
ready_json=$(get_ticket_manifest_field "PRO-102" ready 2>/dev/null)
stale_json=$(echo "$ready_json" | jq -c '.missing += ["SEMANTIC_STALE"] | .missing |= unique')
manifest_path=$(get_ticket_manifest_path "PRO-102" 2>/dev/null)
jq --argjson r "$stale_json" '.ready = $r' "$manifest_path" >"${manifest_path}.tmp" && mv "${manifest_path}.tmp" "$manifest_path"
needs4=$(planner_refinement_scan "$INIT_ID")
if echo "$needs4" | grep -q "^PRO-102$"; then
  pass "planner_refinement_scan: SEMANTIC_STALE re-lists the ticket"
else
  fail "planner_refinement_scan: SEMANTIC_STALE re-lists the ticket" "got: $needs4"
fi
h=$(_body_hash "PRO-102")
_write_clean_scan "PRO-102" "$h"
_write_clean_audit "PRO-102" "$h"
planner_refinement_apply "$INIT_ID" "PRO-102" >/dev/null

# ── 7.4: mixed readiness → epic stamped, halt, not-ready ticket listed ────
# A fresh initiative — reusing INIT_ID would carry forward the
# Refinement|gate|done already written by the "all ready" block above, which
# would make position derivation report Completed regardless of this halt.

echo "--- mixed readiness ---"

MIXED_INIT="INIT-1700000002-2222"
MIXED_EPIC="PRO-400"
planner_state_init "$MIXED_INIT" "mixed readiness idea"
planner_state_write "$MIXED_INIT" "EpicGen" "create" "done" "EPIC_ID=${MIXED_EPIC}"
planner_state_write "$MIXED_INIT" "TicketGen" "verify" "done" "ok"
write_epic_manifest "$MIXED_EPIC" "" "per-ticket" "" '[]' >/dev/null
mixed_log=$(planner_state_log "$MIXED_INIT")

_mixed_add_child() {
  local tid="$1" fixture="$2"
  write_ticket_manifest "$tid" "$MIXED_INIT" "feature" '[]' >/dev/null
  add_epic_manifest_child "$MIXED_EPIC" "$tid" >/dev/null
  local pdir="${REPOS_ROOT}/.ticket-auto/initiatives/${MIXED_INIT}/tickets/${tid}/planner"
  mkdir -p "$pdir"
  cp "${FIXTURES_DIR}/${fixture}.md" "$pdir/body.md"
  echo "$pdir"
}

for tid_fixture in "PRO-401:01-excellent" "PRO-402:02-minimal"; do
  tid="${tid_fixture%%:*}"
  fixture="${tid_fixture#*:}"
  pdir=$(_mixed_add_child "$tid" "$fixture")
  check_ticket_ready "$tid" --body "$pdir/body.md" --type feature --no-fetch >/dev/null 2>&1
  h=$(_dor_body_hash "$(cat "$pdir/body.md")")
  extras=$(jq -nc --argjson score "${DOR_SCORE:-null}" --argjson dims "${DOR_DIMENSIONS:-null}" \
    --argjson gaps "${DOR_GAPS:-null}" --arg hash "$h" \
    '{score: $score, dimensions: $dims, gaps: $gaps} + (if $hash != "" then {body_hash: $hash} else {} end)')
  set_ticket_readiness "$tid" "$DOR_STATUS" "${DOR_MISSING:-[]}" "${DOR_ADVISORY:-[]}" "$extras" >/dev/null
  cat >"$pdir/semantic-scan-result.txt" <<EOF
=== DOR_SEMANTIC_SCAN ===
SCHEMA_VERSION: 1
TICKET: ${tid}
BODY_HASH: ${h}
GAP_REQUIREMENT_COMPLETENESS: clear
GAP_REQUIREMENT_COMPLETENESS_REASON: covered
GAP_CONTRADICTORY_REQUIREMENTS: clear
GAP_CONTRADICTORY_REQUIREMENTS_REASON: covered
GAP_DEEP_SCOPE_AMBIGUITY: clear
GAP_DEEP_SCOPE_AMBIGUITY_REASON: covered
GAP_EDGE_CASE_SUFFICIENCY: clear
GAP_EDGE_CASE_SUFFICIENCY_REASON: covered
=== END DOR_SEMANTIC_SCAN ===
EOF
  cat >"$pdir/semantic-audit-result.txt" <<EOF
=== DOR_SEMANTIC_AUDIT ===
SCHEMA_VERSION: 1
TICKET: ${tid}
BODY_HASH: ${h}
SCORE_PLAUSIBLE: yes
SCORE_REASON: matches
=== END DOR_SEMANTIC_AUDIT ===
EOF
  bash "${LIB_DIR}/../../ticket-auto-pipeline/lib/dor-semantic-parse.sh" --kind scan --result-file "$pdir/semantic-scan-result.txt" >/dev/null
  scan_json=$(bash "${LIB_DIR}/../../ticket-auto-pipeline/lib/dor-semantic-parse.sh" --kind scan --result-file "$pdir/semantic-scan-result.txt")
  audit_json=$(bash "${LIB_DIR}/../../ticket-auto-pipeline/lib/dor-semantic-parse.sh" --kind audit --result-file "$pdir/semantic-audit-result.txt")
  dor_semantic_apply "$tid" "$pdir/body.md" "$scan_json" "$audit_json" >/dev/null
done

pdir=$(_mixed_add_child "PRO-403" "04-useless-scope")
check_ticket_ready "PRO-403" --body "$pdir/body.md" --type feature --no-fetch >/dev/null 2>&1
h403="$DOR_BODY_HASH"
extras=$(jq -nc --argjson score "${DOR_SCORE:-null}" --argjson dims "${DOR_DIMENSIONS:-null}" \
  --argjson gaps "${DOR_GAPS:-null}" --arg hash "$h403" \
  '{score: $score, dimensions: $dims, gaps: $gaps} + (if $hash != "" then {body_hash: $hash} else {} end)')
set_ticket_readiness "PRO-403" "$DOR_STATUS" "${DOR_MISSING:-[]}" "${DOR_ADVISORY:-[]}" "$extras" >/dev/null
quote=$(grep -m1 '^-' "${FIXTURES_DIR}/04-useless-scope.md" | sed 's/^- *//')
cat >"$pdir/semantic-scan-result.txt" <<EOF
=== DOR_SEMANTIC_SCAN ===
SCHEMA_VERSION: 1
TICKET: PRO-403
BODY_HASH: ${h403}
FINDING_1_CODE: MISSING_CORE_AC
FINDING_1_QUOTE: ${quote}
FINDING_1_DETAIL: no acceptance criterion covers this behavior
GAP_REQUIREMENT_COMPLETENESS: finding
GAP_REQUIREMENT_COMPLETENESS_REASON: see FINDING_1
GAP_CONTRADICTORY_REQUIREMENTS: clear
GAP_CONTRADICTORY_REQUIREMENTS_REASON: covered
GAP_DEEP_SCOPE_AMBIGUITY: clear
GAP_DEEP_SCOPE_AMBIGUITY_REASON: covered
GAP_EDGE_CASE_SUFFICIENCY: clear
GAP_EDGE_CASE_SUFFICIENCY_REASON: covered
=== END DOR_SEMANTIC_SCAN ===
EOF
cat >"$pdir/semantic-audit-result.txt" <<EOF
=== DOR_SEMANTIC_AUDIT ===
SCHEMA_VERSION: 1
TICKET: PRO-403
BODY_HASH: ${h403}
SCORE_PLAUSIBLE: yes
SCORE_REASON: matches
=== END DOR_SEMANTIC_AUDIT ===
EOF
scan_json=$(bash "${LIB_DIR}/../../ticket-auto-pipeline/lib/dor-semantic-parse.sh" --kind scan --result-file "$pdir/semantic-scan-result.txt")
audit_json=$(bash "${LIB_DIR}/../../ticket-auto-pipeline/lib/dor-semantic-parse.sh" --kind audit --result-file "$pdir/semantic-audit-result.txt")
dor_semantic_apply "PRO-403" "$pdir/body.md" "$scan_json" "$audit_json" >/dev/null

if ! planner_refinement_gate "$MIXED_INIT"; then
  pass "planner_refinement_gate: mixed readiness returns 1 (halt)"
else
  fail "planner_refinement_gate: mixed readiness returns 1 (halt)" "returned 0"
fi
if [ "$(get_epic_manifest_field "$MIXED_EPIC" dispatch 2>/dev/null)" = "true" ]; then
  pass "planner_refinement_gate: epic stays stamped even while one child is held"
else
  fail "planner_refinement_gate: epic stays stamped even while one child is held" "not stamped"
fi
if grep -q "|META|refinement-gate|fail|1 of 3 not ready" "$mixed_log"; then
  pass "planner_refinement_gate: META|refinement-gate|fail records the count"
else
  fail "planner_refinement_gate: META|refinement-gate|fail records the count" "line missing"
fi

# 7.2: halt leaves position at Refinement; no retry-budget consumption.
if [ "$(planner_position_derive "$MIXED_INIT")" = "Refinement" ]; then
  pass "position after a Refinement halt is Refinement"
else
  fail "position after a Refinement halt is Refinement" "got $(planner_position_derive "$MIXED_INIT")"
fi
if [ "$(planner_phase_fail_count "$MIXED_INIT" "Refinement")" = "0" ]; then
  pass "planner_phase_fail_count(Refinement) is 0 after a halt"
else
  fail "planner_phase_fail_count(Refinement) is 0 after a halt" "got $(planner_phase_fail_count "$MIXED_INIT" "Refinement")"
fi
if ! grep -q "|Refinement|.*|fail|" "$mixed_log"; then
  pass "no Refinement|...|fail| line is ever written"
else
  fail "no Refinement|...|fail| line is ever written" "found one"
fi

report=$(planner_refinement_report "$MIXED_INIT")
if echo "$report" | grep -q "## PRO-403" && echo "$report" | grep -qi "Semantic finding.*MISSING_CORE_AC"; then
  pass "planner_refinement_report: lists the not-ready ticket with its semantic finding"
else
  fail "planner_refinement_report: lists the not-ready ticket with its semantic finding" "got: $report"
fi
if echo "$report" | grep -q "refresh-bodies"; then
  pass "planner_refinement_report: closes with the --refresh-bodies note"
else
  fail "planner_refinement_report: closes with the --refresh-bodies note" "note missing"
fi

# ── 7.9: disputed deterministic code stays blocking until waived ──────────
# Own initiative too, so its report/waive assertions are not entangled with
# the mixed-readiness epic's other children.

echo "--- disputed deterministic code ---"

DISPUTE_INIT="INIT-1700000003-3333"
DISPUTE_EPIC="PRO-500"
planner_state_init "$DISPUTE_INIT" "disputed code idea"
planner_state_write "$DISPUTE_INIT" "EpicGen" "create" "done" "EPIC_ID=${DISPUTE_EPIC}"
planner_state_write "$DISPUTE_INIT" "TicketGen" "verify" "done" "ok"
write_epic_manifest "$DISPUTE_EPIC" "" "per-ticket" "" '[]' >/dev/null

write_ticket_manifest "PRO-501" "$DISPUTE_INIT" "feature" '[]' >/dev/null
add_epic_manifest_child "$DISPUTE_EPIC" "PRO-501" >/dev/null
dispute_pdir="${REPOS_ROOT}/.ticket-auto/initiatives/${DISPUTE_INIT}/tickets/PRO-501/planner"
mkdir -p "$dispute_pdir"
cat >"$dispute_pdir/body.md" <<'EOF'
## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | api     | export |

## Test User

qa@example.com / password123

## Navigation Path

Menu > Export

## Why

Finance needs invoice data outside Linear to reconcile against the bank feed.

## Proposed Behaviour

An export action on the invoice list downloads a CSV of the visible rows.

## Summary

Exports invoices to CSV.
EOF

check_ticket_ready "PRO-501" --body "$dispute_pdir/body.md" --type feature --no-fetch >/dev/null 2>&1
h501="$DOR_BODY_HASH"
extras=$(jq -nc --argjson score "${DOR_SCORE:-null}" --argjson dims "${DOR_DIMENSIONS:-null}" \
  --argjson gaps "${DOR_GAPS:-null}" --arg hash "$h501" \
  '{score: $score, dimensions: $dims, gaps: $gaps} + (if $hash != "" then {body_hash: $hash} else {} end)')
set_ticket_readiness "PRO-501" "$DOR_STATUS" "${DOR_MISSING:-[]}" "${DOR_ADVISORY:-[]}" "$extras" >/dev/null
jq -nc --argjson missing "${DOR_MISSING:-[]}" --argjson advisory "${DOR_ADVISORY:-[]}" --arg status "$DOR_STATUS" \
  '{missing:$missing, advisory:$advisory, status:$status}' >"$dispute_pdir/dor-result.json"

if [ "$(echo "${DOR_MISSING:-[]}" | jq -c .)" = '["AC_MISSING"]' ]; then
  pass "fixture PRO-501: deterministic check flags exactly AC_MISSING"
else
  fail "fixture PRO-501: deterministic check flags exactly AC_MISSING" "missing=$DOR_MISSING"
fi

cat >"$dispute_pdir/semantic-scan-result.txt" <<EOF
=== DOR_SEMANTIC_SCAN ===
SCHEMA_VERSION: 1
TICKET: PRO-501
BODY_HASH: ${h501}
GAP_REQUIREMENT_COMPLETENESS: clear
GAP_REQUIREMENT_COMPLETENESS_REASON: covered
GAP_CONTRADICTORY_REQUIREMENTS: clear
GAP_CONTRADICTORY_REQUIREMENTS_REASON: covered
GAP_DEEP_SCOPE_AMBIGUITY: clear
GAP_DEEP_SCOPE_AMBIGUITY_REASON: covered
GAP_EDGE_CASE_SUFFICIENCY: clear
GAP_EDGE_CASE_SUFFICIENCY_REASON: covered
=== END DOR_SEMANTIC_SCAN ===
EOF
cat >"$dispute_pdir/semantic-audit-result.txt" <<EOF
=== DOR_SEMANTIC_AUDIT ===
SCHEMA_VERSION: 1
TICKET: PRO-501
BODY_HASH: ${h501}
AUDIT_1_CODE: AC_MISSING
AUDIT_1_VERDICT: disputed
AUDIT_1_REASON: the Proposed Behaviour sentence is itself a single, atomic, testable behavior
SCORE_PLAUSIBLE: yes
SCORE_REASON: matches
=== END DOR_SEMANTIC_AUDIT ===
EOF
if planner_refinement_apply "$DISPUTE_INIT" "PRO-501"; then
  pass "planner_refinement_apply: disputed-code audit still applies cleanly"
else
  fail "planner_refinement_apply: disputed-code audit still applies cleanly" "returned nonzero"
fi

ready501=$(get_ticket_manifest_field "PRO-501" ready 2>/dev/null)
if echo "$ready501" | jq -e '.missing | index("AC_MISSING") != null' >/dev/null 2>&1; then
  pass "disputed code stays in ready.missing until waived"
else
  fail "disputed code stays in ready.missing until waived" "got: $ready501"
fi

report501=$(planner_refinement_report "$DISPUTE_INIT")
if echo "$report501" | grep -q "Disputed: AC_MISSING" && echo "$report501" | grep -q 'dor-check.sh --waive PRO-501 AC_MISSING'; then
  pass "report shows the disputed code and the exact waive command"
else
  fail "report shows the disputed code and the exact waive command" "got: $report501"
fi

waive_ticket_readiness_code "PRO-501" "AC_MISSING" "operator" "documented exception" >/dev/null
if [ "$(get_ticket_manifest_field "PRO-501" ready 2>/dev/null | jq -r '.status')" = "ready" ]; then
  pass "waiving the disputed code releases the ticket"
else
  fail "waiving the disputed code releases the ticket" "still not-ready"
fi

# ── 7.8: two invalid results → SEMANTIC_UNAVAILABLE ────────────────────────

echo "--- semantic unavailable after two failed attempts ---"

_add_child "PRO-105" "11-contradictory-acs"
h105=$(_body_hash "PRO-105")
check_ticket_ready "PRO-105" --body "$(_planner_dir "PRO-105")/body.md" --type feature --no-fetch >/dev/null 2>&1
extras=$(jq -nc --argjson score "${DOR_SCORE:-null}" --argjson dims "${DOR_DIMENSIONS:-null}" \
  --argjson gaps "${DOR_GAPS:-null}" --arg hash "$h105" \
  '{score: $score, dimensions: $dims, gaps: $gaps} + (if $hash != "" then {body_hash: $hash} else {} end)')
set_ticket_readiness "PRO-105" "$DOR_STATUS" "${DOR_MISSING:-[]}" "${DOR_ADVISORY:-[]}" "$extras" >/dev/null
jq -nc --argjson missing "${DOR_MISSING:-[]}" --argjson advisory "${DOR_ADVISORY:-[]}" --arg status "$DOR_STATUS" \
  '{missing:$missing, advisory:$advisory, status:$status}' >"$(_planner_dir "PRO-105")/dor-result.json"

# No result files written at all — two attempts, both invalid.
rc1=0
planner_refinement_apply "$INIT_ID" "PRO-105" >/dev/null 2>&1 || rc1=$?
rc2=0
planner_refinement_apply "$INIT_ID" "PRO-105" >/dev/null 2>&1 || rc2=$?
if [ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ]; then
  pass "planner_refinement_apply: fails on both attempts with no result files"
else
  fail "planner_refinement_apply: fails on both attempts with no result files" "rc1=$rc1 rc2=$rc2"
fi
planner_refinement_unavailable "$INIT_ID" "PRO-105" >/dev/null
ready105=$(get_ticket_manifest_field "PRO-105" ready 2>/dev/null)
if echo "$ready105" | jq -e '.missing | index("SEMANTIC_UNAVAILABLE") != null' >/dev/null 2>&1 &&
  [ "$(echo "$ready105" | jq -r '.status')" = "not-ready" ]; then
  pass "planner_refinement_unavailable: records SEMANTIC_UNAVAILABLE, status not-ready"
else
  fail "planner_refinement_unavailable: records SEMANTIC_UNAVAILABLE, status not-ready" "got: $ready105"
fi

# ── 7.7: missing body.md fetched from a stubbed planner_linear_get_issue ──

echo "--- missing body fetched from Linear (stub) ---"

write_ticket_manifest "PRO-106" "$INIT_ID" "feature" '[]' >/dev/null
add_epic_manifest_child "$EPIC_ID" "PRO-106" >/dev/null
# No body.md written — scan must fetch it.
STUB_DESCRIPTION='## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | api     | x    |

## Test User

qa@example.com / pw

## Navigation Path

Menu > X

## Acceptance Criteria

- a fetched, testable criterion'
planner_linear_get_issue() {
  jq -nc --arg d "$STUB_DESCRIPTION" '{data:{issue:{description:$d}}}'
}
planner_refinement_scan "$INIT_ID" >/dev/null
if [ -f "$(_planner_dir "PRO-106")/body.md" ] && grep -q "fetched, testable criterion" "$(_planner_dir "PRO-106")/body.md"; then
  pass "planner_refinement_scan: missing body.md fetched via the stub"
else
  fail "planner_refinement_scan: missing body.md fetched via the stub" "file missing or wrong content"
fi

# --refresh-bodies overwrites a not-ready ticket's body from the same stub,
# and writes nothing to Linear (the stub has no mutation function to call).
echo "different content forcing a re-check" >"$(_planner_dir "PRO-106")/body.md"
set_ticket_readiness "PRO-106" "not-ready" '["AC_MISSING"]' '[]' >/dev/null
old_content=$(cat "$(_planner_dir "PRO-106")/body.md")
planner_refinement_refresh_bodies "$INIT_ID" >/dev/null
new_content=$(cat "$(_planner_dir "PRO-106")/body.md")
if [ "$new_content" != "$old_content" ] && echo "$new_content" | grep -q "fetched, testable criterion"; then
  pass "planner_refinement_refresh_bodies: overwrites a not-ready ticket's body"
else
  fail "planner_refinement_refresh_bodies: overwrites a not-ready ticket's body" "unchanged or wrong content"
fi
unset -f planner_linear_get_issue

# ── 7.10: legacy pass-through ───────────────────────────────────────────────

echo "--- legacy pass-through ---"

LEGACY_INIT="INIT-1600000000-9999"
planner_state_init "$LEGACY_INIT" "legacy initiative"
planner_state_write "$LEGACY_INIT" "EpicGen" "create" "done" "EPIC_ID=PRO-200"
planner_state_write "$LEGACY_INIT" "TicketGen" "dispatch-gate" "done" "legacy stamp"
if planner_refinement_legacy "$LEGACY_INIT"; then
  pass "planner_refinement_legacy: detects the retired dispatch-gate line"
else
  fail "planner_refinement_legacy: detects the retired dispatch-gate line" "returned nonzero"
fi
planner_state_write "$LEGACY_INIT" "META" "refinement" "skip" "legacy"
planner_state_write "$LEGACY_INIT" "Refinement" "gate" "skip" "legacy initiative"
if [ "$(planner_position_derive "$LEGACY_INIT")" = "Completed" ]; then
  pass "legacy skip advances position to Completed"
else
  fail "legacy skip advances position to Completed" "got $(planner_position_derive "$LEGACY_INIT")"
fi
planner_state_write "$LEGACY_INIT" "Completed" "summarize" "done" "done"
if [ -z "$(planner_position_derive "$LEGACY_INIT")" ]; then
  pass "an already-Completed initiative stays complete"
else
  fail "an already-Completed initiative stays complete" "got $(planner_position_derive "$LEGACY_INIT")"
fi

if ! planner_refinement_legacy "$INIT_ID"; then
  pass "planner_refinement_legacy: false for a non-legacy initiative"
else
  fail "planner_refinement_legacy: false for a non-legacy initiative" "returned 0"
fi

# ── 7.11: PLANNER_REFINEMENT_SEMANTIC=false gates on deterministic only ───

echo "--- semantic disabled ---"

NOSEM_INIT="INIT-1700000001-1111"
NOSEM_EPIC="PRO-300"
planner_state_init "$NOSEM_INIT" "no semantic idea"
planner_state_write "$NOSEM_INIT" "EpicGen" "create" "done" "EPIC_ID=${NOSEM_EPIC}"
planner_state_write "$NOSEM_INIT" "TicketGen" "verify" "done" "ok"
write_epic_manifest "$NOSEM_EPIC" "" "per-ticket" "" '[]' >/dev/null

write_ticket_manifest "PRO-301" "$NOSEM_INIT" "feature" '[]' >/dev/null
add_epic_manifest_child "$NOSEM_EPIC" "PRO-301" >/dev/null
mkdir -p "${REPOS_ROOT}/.ticket-auto/initiatives/${NOSEM_INIT}/tickets/PRO-301/planner"
cp "${FIXTURES_DIR}/14-typo-fix.md" "${REPOS_ROOT}/.ticket-auto/initiatives/${NOSEM_INIT}/tickets/PRO-301/planner/body.md"

check_ticket_ready "PRO-301" --body "${REPOS_ROOT}/.ticket-auto/initiatives/${NOSEM_INIT}/tickets/PRO-301/planner/body.md" --type feature --no-fetch >/dev/null 2>&1
extras=$(jq -nc --argjson score "${DOR_SCORE:-null}" --argjson dims "${DOR_DIMENSIONS:-null}" \
  --argjson gaps "${DOR_GAPS:-null}" --arg hash "${DOR_BODY_HASH:-}" \
  '{score: $score, dimensions: $dims, gaps: $gaps} + (if $hash != "" then {body_hash: $hash} else {} end)')
set_ticket_readiness "PRO-301" "$DOR_STATUS" "${DOR_MISSING:-[]}" "${DOR_ADVISORY:-[]}" "$extras" >/dev/null

PLANNER_REFINEMENT_SEMANTIC=false
if planner_refinement_gate "$NOSEM_INIT"; then
  pass "planner_refinement_gate: PLANNER_REFINEMENT_SEMANTIC=false gates on the deterministic verdict alone"
else
  fail "planner_refinement_gate: PLANNER_REFINEMENT_SEMANTIC=false gates on the deterministic verdict alone" "returned nonzero"
fi
unset PLANNER_REFINEMENT_SEMANTIC

# ── 7.12: sourcing leaves the caller's SCRIPT_DIR and errexit unchanged ───

echo "--- SCRIPT_DIR / errexit non-leak ---"

(
  SCRIPT_DIR="/sentinel/path"
  set +e
  source "${LIB_DIR}/planner-refinement.sh"
  planner_refinement_scan "$INIT_ID" >/dev/null 2>&1
  if [ "$SCRIPT_DIR" = "/sentinel/path" ]; then
    echo "SCRIPT_DIR_OK"
  else
    echo "SCRIPT_DIR_BAD:$SCRIPT_DIR"
  fi
  case $- in
  *e*) echo "ERREXIT_BAD" ;;
  *) echo "ERREXIT_OK" ;;
  esac
) >"$TMPDIR/subshell-out.txt" 2>&1
if grep -q "SCRIPT_DIR_OK" "$TMPDIR/subshell-out.txt"; then
  pass "sourcing + calling a function leaves the caller's SCRIPT_DIR unchanged"
else
  fail "sourcing + calling a function leaves the caller's SCRIPT_DIR unchanged" "$(cat "$TMPDIR/subshell-out.txt")"
fi
if grep -q "ERREXIT_OK" "$TMPDIR/subshell-out.txt"; then
  pass "sourcing does not enable errexit in the caller"
else
  fail "sourcing does not enable errexit in the caller" "$(cat "$TMPDIR/subshell-out.txt")"
fi

# ── 7.13: the scan prompt is blind — no det-result path, no code names ────

echo "--- scan prompt blindness ---"

scan_prompt=$(planner_refinement_prompt "$INIT_ID" "PRO-101" scan)
if ! echo "$scan_prompt" | grep -q "dor-result.json"; then
  pass "scan prompt contains no dor-result.json path"
else
  fail "scan prompt contains no dor-result.json path" "found a reference"
fi
if ! echo "$scan_prompt" | grep -qE "SCOPE_MISSING|AC_MISSING|TEST_USER_MISSING"; then
  pass "scan prompt contains no deterministic code name"
else
  fail "scan prompt contains no deterministic code name" "found one"
fi

audit_prompt=$(planner_refinement_prompt "$INIT_ID" "PRO-101" audit)
if echo "$audit_prompt" | grep -q "dor-result.json"; then
  pass "audit prompt DOES reference dor-result.json"
else
  fail "audit prompt DOES reference dor-result.json" "reference missing"
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
