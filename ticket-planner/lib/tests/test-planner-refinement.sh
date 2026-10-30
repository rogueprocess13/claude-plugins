#!/usr/bin/env bash
# test-planner-refinement.sh — Tests for planner-refinement.sh
# (planner-refinement-phase).
#
# Run: bash ticket-planner/lib/tests/test-planner-refinement.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
FIXTURES_DIR="${LIB_DIR}/../../ticket-auto-pipeline/lib/tests/fixtures/dor"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# _planner_refinement_resolve prefers an installed plugin cache and
# ~/.claude/skills/lib over this checkout. An empty HOME makes both miss, so
# every dependency resolves to the sibling ticket-auto-pipeline/lib under test
# — as it does in CI, where no plugin is installed.
export HOME="${TMPDIR}/home"
mkdir -p "$HOME"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-refinement.sh"

# Pull dor-check.sh/dor-semantic.sh/manifest-write.sh into this shell too —
# the test scaffolding needs write_ticket_manifest/write_epic_manifest/
# add_epic_manifest_child/check_ticket_ready/_dor_body_hash directly.
_planner_refinement_source_deps

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

# Refinement scans strictly (DOR_STRICT_TEST_DATA/DOR_STRICT_VPLAN, planner-
# test-data-derivation 6.5), so a "ready" child needs a body that carries a
# sourced Test Data section and a Verification Plan, as TicketGen now writes.
# Fixture 22 (every test-data item sourced) is ready under both flags; both
# children use it (the ticket id, not the body, keys every assertion below).
_add_child "PRO-101" "22-sourced-contract"
_add_child "PRO-102" "22-sourced-contract"

needs=$(planner_refinement_scan "$INIT_ID")
if [ "$(echo "$needs" | grep -c .)" = "2" ]; then
  pass "planner_refinement_scan: both fresh tickets need a semantic pass"
else
  fail "planner_refinement_scan: both fresh tickets need a semantic pass" "got: $needs"
fi

# planner-refinement-convergence D4/D9: the scan records its strict profile
# and the section/unit hashes, so a dispatch recompute stays strict and an
# edit can be scoped to the sections it touched.
if get_ticket_manifest_field "PRO-101" ready 2>/dev/null |
  jq -e '.check_profile == "planner-strict" and (.section_hashes | type) == "object"
         and (.section_hashes | has("Acceptance Criteria")) and (.unit_hashes | type) == "object"' >/dev/null; then
  pass "planner_refinement_scan: records check_profile planner-strict and section/unit hashes"
else
  fail "planner_refinement_scan: records check_profile planner-strict and section/unit hashes" \
    "got: $(get_ticket_manifest_field "PRO-101" ready 2>/dev/null | jq -c '{check_profile, s: (.section_hashes | keys?)}')"
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
# planner-refinement-convergence D3: blocking findings are labelled by
# lineage ("Blocking (new)" on a first verdict), and a ticket held by a
# non-structural one is offered the no-rescan converge.
if echo "$report" | grep -q "## PRO-403" && echo "$report" | grep -qF "Blocking (new) MISSING_CORE_AC"; then
  pass "planner_refinement_report: lists the not-ready ticket with its semantic finding"
else
  fail "planner_refinement_report: lists the not-ready ticket with its semantic finding" "got: $report"
fi
if echo "$report" | grep -qF -- "--converge --only PRO-403"; then
  pass "planner_refinement_report: offers converge for a non-structural blocking finding"
else
  fail "planner_refinement_report: offers converge for a non-structural blocking finding" "got: $report"
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

# ── 6.5 (planner-test-data-derivation): Refinement scans strictly ─────────
# A child with no Verification Plan and fewer than half of its criteria
# self-verifying: ticket-auto's default treats VPLAN_MISSING as advisory, but
# Refinement passes DOR_STRICT_VPLAN=true (and DOR_STRICT_TEST_DATA=true), so
# the code is hard, the run halts and the report names it.

echo "--- strict scan: VPLAN_MISSING halts Refinement ---"

STRICT_INIT="INIT-1700000004-4444"
STRICT_EPIC="PRO-600"
planner_state_init "$STRICT_INIT" "strict refinement idea"
planner_state_write "$STRICT_INIT" "EpicGen" "create" "done" "EPIC_ID=${STRICT_EPIC}"
planner_state_write "$STRICT_INIT" "TicketGen" "verify" "done" "ok"
write_epic_manifest "$STRICT_EPIC" "" "per-ticket" "" '[]' >/dev/null
write_ticket_manifest "PRO-601" "$STRICT_INIT" "feature" '[]' >/dev/null
add_epic_manifest_child "$STRICT_EPIC" "PRO-601" >/dev/null
strict_pdir="${REPOS_ROOT}/.ticket-auto/initiatives/${STRICT_INIT}/tickets/PRO-601/planner"
mkdir -p "$strict_pdir"
cp "${FIXTURES_DIR}/14-typo-fix.md" "${strict_pdir}/body.md"

(
  unset DOR_STRICT_TEST_DATA DOR_STRICT_VPLAN
  check_ticket_ready "PRO-601" --body "${strict_pdir}/body.md" --type feature --no-fetch >/dev/null 2>&1
  echo "$DOR_MISSING|$DOR_ADVISORY"
) >"${TMPDIR}/strict-control.txt"
if grep -q '^[^|]*|.*"VPLAN_MISSING"' "${TMPDIR}/strict-control.txt" &&
  ! grep -q '^[^|]*VPLAN_MISSING[^|]*|' "${TMPDIR}/strict-control.txt"; then
  pass "control: without the strict flags VPLAN_MISSING is only advisory"
else
  fail "control: without the strict flags VPLAN_MISSING is only advisory" "$(cat "${TMPDIR}/strict-control.txt")"
fi

unset DOR_STRICT_TEST_DATA
DOR_STRICT_VPLAN="caller-value"
PLANNER_REFINEMENT_SEMANTIC=false
planner_refinement_scan "$STRICT_INIT" >/dev/null
if [ "${DOR_STRICT_VPLAN}" = "caller-value" ] && [ -z "${DOR_STRICT_TEST_DATA+set}" ]; then
  pass "planner_refinement_scan: the strict flags do not leak into the caller's environment"
else
  fail "planner_refinement_scan: the strict flags do not leak" \
    "DOR_STRICT_VPLAN=${DOR_STRICT_VPLAN-<unset>} DOR_STRICT_TEST_DATA=${DOR_STRICT_TEST_DATA-<unset>}"
fi
unset DOR_STRICT_VPLAN

if get_ticket_manifest_field "PRO-601" ready 2>/dev/null | jq -e '.status == "not-ready" and (.missing | index("VPLAN_MISSING"))' >/dev/null; then
  pass "planner_refinement_scan: VPLAN_MISSING recorded as a hard code"
else
  fail "planner_refinement_scan: VPLAN_MISSING recorded as a hard code" "$(get_ticket_manifest_field "PRO-601" ready 2>/dev/null)"
fi
if ! planner_refinement_gate "$STRICT_INIT"; then
  pass "planner_refinement_gate: strict VPLAN_MISSING halts Refinement"
else
  fail "planner_refinement_gate: strict VPLAN_MISSING halts Refinement" "returned 0"
fi
unset PLANNER_REFINEMENT_SEMANTIC
strict_report=$(planner_refinement_report "$STRICT_INIT")
if echo "$strict_report" | grep -q "## PRO-601" && echo "$strict_report" | grep -q "VPLAN_MISSING"; then
  pass "planner_refinement_report: lists VPLAN_MISSING for the child"
else
  fail "planner_refinement_report: lists VPLAN_MISSING for the child" "got: $strict_report"
fi

# ── dor-semantic-test-data-gap: advisory TEST_DATA_GAP findings ───────────
# Canned scan blocks (ticket-auto-pipeline fixtures/dor/semantic/) stand in
# for the dor-semantic-agent. A verified TEST_DATA_GAP is advisory: it never
# blocks, but Refinement records it once per ticket per body hash and reports
# it, ready child or not.

echo "--- advisory TEST_DATA_GAP findings ---"

SEMANTIC_FIXTURES_DIR="${FIXTURES_DIR}/semantic"

# _tdg_pdir <INIT> <TID>
_tdg_pdir() {
  echo "${REPOS_ROOT}/.ticket-auto/initiatives/${1}/tickets/${2}/planner"
}

# _tdg_setup <INIT> <EPIC>
_tdg_setup() {
  planner_state_init "$1" "test-data gap idea"
  planner_state_write "$1" "EpicGen" "create" "done" "EPIC_ID=${2}"
  planner_state_write "$1" "TicketGen" "verify" "done" "ok"
  write_epic_manifest "$2" "" "per-ticket" "" '[]' >/dev/null
}

# _tdg_child <INIT> <EPIC> <TID> <fixture-basename>
_tdg_child() {
  local pdir
  write_ticket_manifest "$3" "$1" "feature" '[]' >/dev/null
  add_epic_manifest_child "$2" "$3" >/dev/null
  pdir=$(_tdg_pdir "$1" "$3")
  mkdir -p "$pdir"
  cp "${FIXTURES_DIR}/${4}.md" "${pdir}/body.md"
}

# _tdg_canned <INIT> <TID> <scan-file> <audit-file> — render the canned blocks
# against the child's current body hash.
_tdg_canned() {
  local pdir hash
  pdir=$(_tdg_pdir "$1" "$2")
  hash=$(_dor_body_hash "$(cat "${pdir}/body.md")")
  sed -e "s|@TICKET@|${2}|" -e "s|@BODY_HASH@|${hash}|" "$3" >"${pdir}/semantic-scan-result.txt"
  sed -e "s|@TICKET@|${2}|" -e "s|@BODY_HASH@|${hash}|" "$4" >"${pdir}/semantic-audit-result.txt"
}

# _tdg_warns <INIT> [TID] — count of refinement-testdata warn lines.
_tdg_warns() {
  local log
  log=$(planner_state_log "$1")
  if [ -n "${2:-}" ]; then
    grep -F '|META|refinement-testdata|warn|' "$log" 2>/dev/null | grep -cF "${2} TEST_DATA_GAP" || true
  else
    grep -cF '|META|refinement-testdata|warn|' "$log" 2>/dev/null || true
  fi
}

TDG_INIT="INIT-1700000005-5555"
TDG_EPIC="PRO-700"
TDG_QUOTE="Duplicating a handover from the list creates a draft copy with the same line items"
_tdg_setup "$TDG_INIT" "$TDG_EPIC"
_tdg_child "$TDG_INIT" "$TDG_EPIC" "PRO-701" "27-planned-all-none-miss"
_tdg_child "$TDG_INIT" "$TDG_EPIC" "PRO-702" "22-sourced-contract"
planner_refinement_scan "$TDG_INIT" >/dev/null
_tdg_canned "$TDG_INIT" "PRO-701" "${SEMANTIC_FIXTURES_DIR}/27-scan.txt" "${SEMANTIC_FIXTURES_DIR}/27-audit.txt"
_tdg_canned "$TDG_INIT" "PRO-702" "${SEMANTIC_FIXTURES_DIR}/28-scan.txt" "${SEMANTIC_FIXTURES_DIR}/28-audit.txt"

# (a) ready, gate passes, exactly one warn line naming the tid and the quote
rc701=0
planner_refinement_apply "$TDG_INIT" "PRO-701" || rc701=$?
planner_refinement_apply "$TDG_INIT" "PRO-702" >/dev/null 2>&1 || true
tdg_log=$(planner_state_log "$TDG_INIT")
if [ "$rc701" = "0" ] &&
  get_ticket_manifest_field "PRO-701" ready 2>/dev/null | jq -e '.status == "ready"' >/dev/null; then
  pass "TEST_DATA_GAP: the all-none child with an advisory finding is ready"
else
  fail "TEST_DATA_GAP: the all-none child with an advisory finding is ready" \
    "rc=$rc701 ready=$(get_ticket_manifest_field "PRO-701" ready 2>/dev/null)"
fi
if planner_refinement_gate "$TDG_INIT"; then
  pass "TEST_DATA_GAP: the gate passes with an advisory finding"
else
  fail "TEST_DATA_GAP: the gate passes with an advisory finding" "returned nonzero"
fi
warn_line=$(grep -F '|META|refinement-testdata|warn|' "$tdg_log" 2>/dev/null || true)
if [ "$(_tdg_warns "$TDG_INIT")" = "1" ] && echo "$warn_line" | grep -qF "PRO-701 TEST_DATA_GAP" &&
  echo "$warn_line" | grep -qF "$TDG_QUOTE"; then
  pass "TEST_DATA_GAP: exactly one warn line naming the tid and the quote"
else
  fail "TEST_DATA_GAP: exactly one warn line naming the tid and the quote" "lines: $warn_line"
fi

# (b) apply again on the unchanged body: still one line
planner_refinement_apply "$TDG_INIT" "PRO-701" >/dev/null 2>&1 || true
if [ "$(_tdg_warns "$TDG_INIT" "PRO-701")" = "1" ]; then
  pass "TEST_DATA_GAP: re-apply on an unchanged body writes no second warn line"
else
  fail "TEST_DATA_GAP: re-apply on an unchanged body writes no second warn line" "count=$(_tdg_warns "$TDG_INIT" "PRO-701")"
fi

# (c) an edited body records again, with the new hash8
pdir701=$(_tdg_pdir "$TDG_INIT" "PRO-701")
printf '\nEdited after review.\n' >>"${pdir701}/body.md"
_tdg_canned "$TDG_INIT" "PRO-701" "${SEMANTIC_FIXTURES_DIR}/27-scan.txt" "${SEMANTIC_FIXTURES_DIR}/27-audit.txt"
planner_refinement_apply "$TDG_INIT" "PRO-701" >/dev/null 2>&1 || true
new_hash8=$(_dor_body_hash "$(cat "${pdir701}/body.md")" | sed 's/^sha256://' | cut -c1-8)
if [ "$(_tdg_warns "$TDG_INIT" "PRO-701")" = "2" ] &&
  grep -F '|META|refinement-testdata|warn|' "$tdg_log" | tail -1 | grep -qF "[${new_hash8}]"; then
  pass "TEST_DATA_GAP: an edited body writes a second warn line with the new hash8"
else
  fail "TEST_DATA_GAP: an edited body writes a second warn line with the new hash8" \
    "count=$(_tdg_warns "$TDG_INIT" "PRO-701") hash8=$new_hash8"
fi

# (d) the summary: one line for the finding, nothing for an initiative without
summary=$(planner_refinement_advisory_summary "$TDG_INIT" 2>/dev/null) || summary=""
if [ "$(echo "$summary" | grep -c 'Advisory (does not block)')" = "1" ] &&
  echo "$summary" | grep -qF "PRO-701 TEST_DATA_GAP: \"${TDG_QUOTE}\""; then
  pass "planner_refinement_advisory_summary: one Advisory line for the ready child"
else
  fail "planner_refinement_advisory_summary: one Advisory line for the ready child" "got: $summary"
fi
# (e) audit MISSED entries are listed (security ones marked), never silent
mpath=$(get_ticket_manifest_path PRO-701)
jq '.ready.semantic.missed = [{"code":"MISSING_CORE_AC","reason":"an innerHTML implementation passes every criterion"},{"code":"EDGE_CASE_GAP","reason":"a 5xx leaves the page blank"}]' \
  "$mpath" >"${mpath}.tmp" && mv "${mpath}.tmp" "$mpath"
summary_m=$(planner_refinement_advisory_summary "$TDG_INIT" 2>/dev/null) || summary_m=""
if echo "$summary_m" | grep -qxF "Advisory (does not block) PRO-701 Security MISSED MISSING_CORE_AC: an innerHTML implementation passes every criterion" &&
  echo "$summary_m" | grep -qxF "Advisory (does not block) PRO-701 MISSED EDGE_CASE_GAP: a 5xx leaves the page blank"; then
  pass "planner_refinement_advisory_summary: audit MISSED entries listed, security one marked"
else
  fail "planner_refinement_advisory_summary: audit MISSED entries" "got: $summary_m"
fi
summary_none=$(planner_refinement_advisory_summary "$INIT_ID" 2>/dev/null) || summary_none="(rc!=0)"
if [ -z "$summary_none" ]; then
  pass "planner_refinement_advisory_summary: prints nothing for an initiative with no finding"
else
  fail "planner_refinement_advisory_summary: prints nothing for an initiative with no finding" "got: $summary_none"
fi
report_none=$(planner_refinement_report "$INIT_ID")
if ! echo "$report_none" | grep -q "Advisory test-data findings"; then
  pass "planner_refinement_report: no advisory heading when there is no finding"
else
  fail "planner_refinement_report: no advisory heading when there is no finding" "got: $report_none"
fi

# (e) a halt: another child not ready on a deterministic code
_tdg_child "$TDG_INIT" "$TDG_EPIC" "PRO-703" "14-typo-fix"
planner_refinement_scan "$TDG_INIT" >/dev/null
if ! planner_refinement_gate "$TDG_INIT"; then
  pass "TEST_DATA_GAP halt setup: the strict VPLAN_MISSING child halts the gate"
else
  fail "TEST_DATA_GAP halt setup: the strict VPLAN_MISSING child halts the gate" "returned 0"
fi
tdg_report=$(planner_refinement_report "$TDG_INIT")
advisory_section=$(echo "$tdg_report" | sed -n '/^## Advisory test-data findings/,$p')
if echo "$tdg_report" | grep -q "^## PRO-703" && [ -n "$advisory_section" ] &&
  echo "$advisory_section" | grep -qF "PRO-701 TEST_DATA_GAP"; then
  pass "planner_refinement_report: halt report carries an advisory section naming the ready child"
else
  fail "planner_refinement_report: halt report carries an advisory section naming the ready child" "got: $tdg_report"
fi

# (f) a non-verbatim quote: no warn line, not ready on SEMANTIC_UNVERIFIED
TDG2_INIT="INIT-1700000006-6666"
TDG2_EPIC="PRO-710"
_tdg_setup "$TDG2_INIT" "$TDG2_EPIC"
_tdg_child "$TDG2_INIT" "$TDG2_EPIC" "PRO-711" "27-planned-all-none-miss"
_tdg_child "$TDG2_INIT" "$TDG2_EPIC" "PRO-712" "28-threshold-only-none"
planner_refinement_scan "$TDG2_INIT" >/dev/null
sed 's|creates a draft copy with the same line items|creates a draft copy with the identical line items|' \
  "${SEMANTIC_FIXTURES_DIR}/27-scan.txt" >"${TMPDIR}/tdg-unverified-scan.txt"
_tdg_canned "$TDG2_INIT" "PRO-711" "${TMPDIR}/tdg-unverified-scan.txt" "${SEMANTIC_FIXTURES_DIR}/27-audit.txt"
planner_refinement_apply "$TDG2_INIT" "PRO-711" >/dev/null 2>&1 || true
if [ "$(_tdg_warns "$TDG2_INIT")" = "0" ] &&
  get_ticket_manifest_field "PRO-711" ready 2>/dev/null |
  jq -e '.status == "not-ready" and ((.missing // []) | index("SEMANTIC_UNVERIFIED") != null)' >/dev/null; then
  pass "TEST_DATA_GAP: a non-verbatim quote writes no warn line and blocks on SEMANTIC_UNVERIFIED"
else
  fail "TEST_DATA_GAP: a non-verbatim quote writes no warn line and blocks on SEMANTIC_UNVERIFIED" \
    "warns=$(_tdg_warns "$TDG2_INIT") ready=$(get_ticket_manifest_field "PRO-711" ready 2>/dev/null)"
fi

# (g) a cached dor-semantic-v1 verdict re-runs once, then converges. Only
# v2 verdicts are migrated in place (dor_semantic_migrate_v2, design D8 —
# see test-planner-refinement-convergence.sh); a v1 one is rescanned.
_tdg_canned "$TDG2_INIT" "PRO-712" "${SEMANTIC_FIXTURES_DIR}/28-scan.txt" "${SEMANTIC_FIXTURES_DIR}/28-audit.txt"
DOR_SEMANTIC_EVALUATOR="dor-semantic-v1" planner_refinement_apply "$TDG2_INIT" "PRO-712" >/dev/null 2>&1 || true
needs_v1=$(planner_refinement_scan "$TDG2_INIT")
planner_refinement_apply "$TDG2_INIT" "PRO-712" >/dev/null 2>&1 || true
needs_v3=$(planner_refinement_scan "$TDG2_INIT")
if echo "$needs_v1" | grep -qx "PRO-712" && ! echo "$needs_v3" | grep -qx "PRO-712" &&
  get_ticket_manifest_field "PRO-712" ready 2>/dev/null | jq -e '.semantic.evaluator == "dor-semantic-v3"' >/dev/null; then
  pass "TEST_DATA_GAP: a cached v1 verdict is re-run once and then converges on v3"
else
  fail "TEST_DATA_GAP: a cached v1 verdict is re-run once and then converges on v3" "v1 scan: $needs_v1 / v3 scan: $needs_v3"
fi

# (h) the warn write failing does not change planner_refinement_apply's rc
_tdg_child "$TDG2_INIT" "$TDG2_EPIC" "PRO-713" "26-contract-implied-miss"
planner_refinement_scan "$TDG2_INIT" >/dev/null
_tdg_canned "$TDG2_INIT" "PRO-713" "${SEMANTIC_FIXTURES_DIR}/26-scan.txt" "${SEMANTIC_FIXTURES_DIR}/26-audit.txt"
_saved_state_write=$(declare -f planner_state_write)
# Stubbed through eval: a literal redefinition here makes shellcheck treat
# every earlier call as a call to a function "only defined later" (SC2218).
eval 'planner_state_write() { return 1; }'
rc713=0
planner_refinement_apply "$TDG2_INIT" "PRO-713" >/dev/null 2>&1 || rc713=$?
eval "$_saved_state_write"
if [ "$rc713" = "0" ] && [ "$(_tdg_warns "$TDG2_INIT" "PRO-713")" = "0" ]; then
  pass "TEST_DATA_GAP: a failing warn write leaves planner_refinement_apply's rc at 0"
else
  fail "TEST_DATA_GAP: a failing warn write leaves planner_refinement_apply's rc at 0" \
    "rc=$rc713 warns=$(_tdg_warns "$TDG2_INIT" "PRO-713")"
fi

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

# ── #497: a Read/Write-only agent can satisfy the BODY_HASH binding ──────
# The evaluator has no shell, so it cannot compute a SHA-256. The prompt must
# hand it the hash as a literal; an agent that copies that literal verbatim
# must be accepted, and a body edited after the prompt was built must still
# be rejected.

echo "--- #497: body hash handed to the agent in the prompt ---"

_add_child "PRO-190" "22-sourced-contract"
planner_refinement_scan "$INIT_ID" >/dev/null

_hash_from_prompt() {
  echo "$1" | sed -n 's/^\*\*Body hash\*\*: //p' | head -1
}

p497_scan=$(planner_refinement_prompt "$INIT_ID" "PRO-190" scan)
p497_audit=$(planner_refinement_prompt "$INIT_ID" "PRO-190" audit)
h497_scan=$(_hash_from_prompt "$p497_scan")
h497_audit=$(_hash_from_prompt "$p497_audit")
h497_real=$(_body_hash "PRO-190")

if [ -n "$h497_real" ] && [ "$h497_scan" = "$h497_real" ] && [ "$h497_audit" = "$h497_real" ]; then
  pass "scan and audit prompts carry the body hash as a literal"
else
  fail "scan and audit prompts carry the body hash as a literal" "scan=$h497_scan audit=$h497_audit want=$h497_real"
fi
if ! echo "$p497_scan$p497_audit" | grep -qi "compute this yourself"; then
  pass "prompts no longer ask the agent to compute the hash"
else
  fail "prompts no longer ask the agent to compute the hash" "found the old instruction"
fi

# Simulated Read/Write-only agent: copies the hash from the prompt verbatim.
_write_clean_scan "PRO-190" "$h497_scan"
_write_clean_audit "PRO-190" "$h497_audit"
if planner_refinement_apply "$INIT_ID" "PRO-190" 2>/dev/null; then
  pass "result echoing the prompt's body hash is accepted by planner_refinement_apply"
else
  fail "result echoing the prompt's body hash is accepted by planner_refinement_apply" "returned nonzero"
fi

# Body edited after the prompt was built: the same results are now stale.
echo "- a criterion added after the scan" >>"$(_planner_dir "PRO-190")/body.md"
stale_rc=0
stale_err=$(planner_refinement_apply "$INIT_ID" "PRO-190" 2>&1 >/dev/null) || stale_rc=$?
if [ "$stale_rc" -ne 0 ] && echo "$stale_err" | grep -q "BODY_HASH mismatch"; then
  pass "body edited after the scan still fails the binding check"
else
  fail "body edited after the scan still fails the binding check" "rc=$stale_rc err=$stale_err"
fi

# ── planner-draft-readiness S2b task 4.1: step 1b's spawn-list driver ────

echo "--- spawn-list driver (prepare / next / apply_pending) ---"

SL_INIT="INIT-1700000002-2222"
SL_EPIC="PRO-400"
planner_state_init "$SL_INIT" "spawn list idea"
planner_state_write "$SL_INIT" "EpicGen" "create" "done" "EPIC_ID=${SL_EPIC}"
planner_state_write "$SL_INIT" "TicketGen" "verify" "done" "ok"
write_epic_manifest "$SL_EPIC" "" "per-ticket" "" '[]' >/dev/null
_sl_dir() { echo "${REPOS_ROOT}/.ticket-auto/initiatives/${SL_INIT}/tickets/${1}/planner"; }
for tid in PRO-401 PRO-402; do
  write_ticket_manifest "$tid" "$SL_INIT" "feature" '[]' >/dev/null
  add_epic_manifest_child "$SL_EPIC" "$tid" >/dev/null
  mkdir -p "$(_sl_dir "$tid")"
  cp "${FIXTURES_DIR}/22-sourced-contract.md" "$(_sl_dir "$tid")/body.md"
done
# A stale result from an earlier run must never be applied.
echo "stale" >"$(_sl_dir PRO-401)/semantic-scan-result.txt"

# Writes the canned results for a spawn list, through the test's own
# _write_* helpers (which key on INIT_ID's ticket dirs — point them here).
_sl_spawn() {
  local tid kind agent pf rf h
  while IFS=$'\t' read -r tid kind agent pf rf; do
    [ -n "$tid" ] || continue
    [ "${SL_SKIP:-}" = "$tid" ] && continue
    h=$(_dor_body_hash "$(cat "$(_sl_dir "$tid")/body.md")")
    if [ "$kind" = "scan" ]; then
      INIT_ID="$SL_INIT" _write_clean_scan "$tid" "$h"
    else
      INIT_ID="$SL_INIT" _write_clean_audit "$tid" "$h"
    fi
  done <<<"$1"
}

sl_rc=0
PLANNER_REFINEMENT_DRIFT_CHECK=false planner_refinement_prepare "$SL_INIT" >/dev/null 2>&1 || sl_rc=$?
pass_file="${REPOS_ROOT}/.ticket-auto/initiatives/${SL_INIT}/refinement-pass"
if [ "$sl_rc" -eq 0 ] && [ "$(grep -c . "$pass_file")" = 2 ] && [ ! -e "$(_sl_dir PRO-401)/semantic-scan-result.txt" ]; then
  pass "prepare: both children listed, stale results cleared"
else
  fail "prepare" "rc=$sl_rc $(cat "$pass_file" 2>/dev/null)"
fi
l1=$(planner_refinement_next "$SL_INIT")
if [ "$(printf '%s\n' "$l1" | cut -f1,2,3 | tr '\t\n' ': ')" = "PRO-401:scan:ticket-auto-pipeline:dor-semantic-agent PRO-402:scan:ticket-auto-pipeline:dor-semantic-agent " ] &&
  [ -s "$(printf '%s\n' "$l1" | head -1 | cut -f4)" ]; then
  pass "next: one scan per listed ticket, prompt written to the named file"
else
  fail "next scans" "$l1"
fi
_sl_spawn "$l1"
planner_refinement_apply_pending "$SL_INIT"
l2=$(planner_refinement_next "$SL_INIT")
[ "$(printf '%s\n' "$l2" | cut -f2 | sort -u)" = "audit" ] && pass "next: then the audits" || fail "next audits" "$l2"
_sl_spawn "$l2"
planner_refinement_apply_pending "$SL_INIT"
l3=$(planner_refinement_next "$SL_INIT")
if [ "$l3" = "done 0" ] && [ ! -s "$pass_file" ] &&
  get_ticket_manifest_field "PRO-401" ready 2>/dev/null | jq -e '.semantic.findings == []' >/dev/null &&
  planner_refinement_gate "$SL_INIT" >/dev/null 2>&1; then
  pass "apply_pending: verdicts stored, pass list empty, done 0, gate passes"
else
  fail "apply_pending" "l3=$l3 pass=$(cat "$pass_file")"
fi

# An agent that never writes its result: one retry, then unavailable.
echo "- an edit" >>"$(_sl_dir PRO-402)/body.md"
PLANNER_REFINEMENT_DRIFT_CHECK=false planner_refinement_prepare "$SL_INIT" >/dev/null 2>&1
SL_SKIP="PRO-402"
for _i in 1 2 3 4; do
  l=$(planner_refinement_next "$SL_INIT")
  [ "$l" = "done 0" ] && break
  _sl_spawn "$l"
  planner_refinement_apply_pending "$SL_INIT"
done
unset SL_SKIP
if [ "$l" = "done 0" ] &&
  get_ticket_manifest_field "PRO-402" ready 2>/dev/null | jq -e '.missing | index("SEMANTIC_UNAVAILABLE") != null' >/dev/null; then
  pass "missing result twice: SEMANTIC_UNAVAILABLE, ticket leaves the list"
else
  fail "missing result twice" "l=$l $(get_ticket_manifest_field "PRO-402" ready 2>/dev/null | jq -c .missing)"
fi

# Strict list contract (step 1e): whatever apply prints never reaches the
# spawn list — only 5-field rows or `done N`.
eval "$(declare -f planner_refinement_apply | sed '1s/planner_refinement_apply/_sl_real_apply/')"
# (eval, so shellcheck does not read this as the function's only definition)
eval 'planner_refinement_apply() { echo "round=1 demoted=0 dropped=0"; _sl_real_apply "$@"; }'
_sl_strict() { printf '%s\n' "$1" | awk -F'\t' '!(NF == 5 || /^done [0-9]+$/) { bad = 1 } END { exit bad }'; }
sed -i "s/before import\.$/before import (v2)./" "$(_sl_dir PRO-401)/body.md"
PLANNER_REFINEMENT_DRIFT_CHECK=false planner_refinement_prepare "$SL_INIT" >/dev/null 2>&1
sl_strict_ok=1
for _i in 1 2 3 4 5 6; do
  l=$(planner_refinement_next "$SL_INIT" 2>/dev/null)
  _sl_strict "$l" || sl_strict_ok=0
  [ "$l" = "done 0" ] && break
  _sl_spawn "$l"
  planner_refinement_apply_pending "$SL_INIT" >/dev/null 2>&1
done
if [ "$sl_strict_ok" -eq 1 ] && [ "$l" = "done 0" ]; then
  pass "next prints only spawn rows or done N, even when apply prints to stdout"
else
  fail "strict list" "$l"
fi
eval "$(declare -f _sl_real_apply | sed '1s/_sl_real_apply/planner_refinement_apply/')"

# A spawn list left by a crashed run is dropped by prepare: it must not
# count as a failed attempt for every listed ticket.
sed -i "s/before import (v2)\.$/before import (v3)./" "$(_sl_dir PRO-401)/body.md"
PLANNER_REFINEMENT_DRIFT_CHECK=false planner_refinement_prepare "$SL_INIT" >/dev/null 2>&1
planner_refinement_next "$SL_INIT" >/dev/null 2>&1 # leaves .pending, no agent runs
PLANNER_REFINEMENT_DRIFT_CHECK=false planner_refinement_prepare "$SL_INIT" >/dev/null 2>&1
l=$(planner_refinement_next "$SL_INIT" 2>/dev/null)
if [ ! -e "$(_sl_dir PRO-401)/semantic-attempts" ] && printf '%s\n' "$l" | grep -q $'^PRO-401\tscan\t'; then
  pass "prepare drops a stale spawn list: no failed attempt counted"
else
  fail "stale pending" "attempts=$(cat "$(_sl_dir PRO-401)/semantic-attempts" 2>/dev/null) l=$l"
fi
rm -f "${pass_file}.pending"
# Semantic off: an empty list, NEXT done at once. Legacy: rc 2, nothing else.
PLANNER_REFINEMENT_SEMANTIC=false PLANNER_REFINEMENT_DRIFT_CHECK=false planner_refinement_prepare "$SL_INIT" >/dev/null 2>&1
[ "$(planner_refinement_next "$SL_INIT")" = "done 0" ] && pass "semantic off: done at once" ||
  fail "semantic off" "$(planner_refinement_next "$SL_INIT")"
sl_rc=0
planner_refinement_prepare "$LEGACY_INIT" >/dev/null 2>&1 || sl_rc=$?
[ "$sl_rc" -eq 2 ] && pass "prepare: legacy initiative rc 2" || fail "prepare legacy" "rc=$sl_rc"

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
