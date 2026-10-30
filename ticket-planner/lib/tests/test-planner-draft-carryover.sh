#!/usr/bin/env bash
# test-planner-draft-carryover.sh — planner-draft-readiness slice S4
# (design D13, D14): Refinement carries the draft readiness verdict, and
# EpicGen's "Revised by draft readiness" summary.
#
# Covers:
#   1. Import: a Linear-re-rendered body (CRLF, trailing spaces, sibling id as
#      a Linear link) equivalent to its draft imports the draft verdict with
#      no semantic pass listed; a round-limit demotion stays advisory; a
#      DRAFT-<slug> quote that no longer locates is dropped with no
#      SEMANTIC_UNVERIFIED; the import line is logged.
#   2. Draft-passed scan: a body with an edited criterion is listed for a
#      pass, its lineage is seeded from the draft (rebuilt from semantic.json
#      when the gate kept no lineage.json), and the apply runs the
#      draft-passed policy: non-structural → `draft-passed`, structural on an
#      unchanged unit → `draft-passed-structural`, structural on the changed
#      criterion still blocks; no reset; marker cleared.
#   3. A ticket that already has a semantic verdict is untouched.
#   4. PLANNER_DRAFT_VERDICT_IMPORT=false and a missing draft directory take
#      the old path.
#   5. Draft status: stale, accepted.
#   6. Epic summary: rounds, added/extended criteria, demotions; nothing when
#      there is nothing to report; never in a ticket body; wired into the
#      EpicGen prompt.
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-carryover.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TAP_LIB="$(cd "${LIB_DIR}/../../ticket-auto-pipeline/lib" && pwd)"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Hermetic: never resolve an installed plugin cache or skills-lib copy.
export HOME="${TMP_ROOT}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${TMP_ROOT}/repos"
export TMPDIR="${TMP_ROOT}/tmp"
mkdir -p "$TMPDIR"
unset PLANNER_DRAFT_VERDICT_IMPORT PLANNER_REFINEMENT_SEMANTIC
export PLANNER_REFINEMENT_DRIFT_CHECK=false

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-draft-carryover.sh"
_planner_refinement_source_deps || exit 1
PARSE="${TAP_LIB}/dor-semantic-parse.sh"

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

echo "=== planner draft carry-over (S4) ==="

INIT="INIT-DC1"
IDIR="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
SPECS="${IDIR}/artifacts/specs"
mkdir -p "$SPECS"

# _spec <slug> <title> <labels-line> <ac-lines>
_spec() {
  local slug="$1" title="$2" labels="$3" acs="$4" ac crit rows=""
  while IFS= read -r ac; do
    crit="${ac#- \[ \] }"
    rows+="| ${crit} | finance user | none | | done | yes |"$'\n'
  done <<<"$acs"
  cat >"${SPECS}/${slug}.md" <<SPEC
# ${slug}

## Title

${title}

## Description

## Summary

${title}, in plain language.

## Outcome

**Serves:** O1

**Outcome:** Invoices can be exported.

## Proposed Behaviour

An Export action on the invoice list. Only finance users may export.

## Technical Context

- Route \`GET /api/invoices/export\`.

## Acceptance Criteria

${acs}

## Out of Scope

Scheduled exports.

## Related Tickets

None

## Labels

${labels}

## Signals

\`\`\`json
{
  "services_identified": 2,
  "symbols_resolved": 3,
  "prior_art_found": true,
  "Strategy": "Balanced",
  "Decision": "Add an export route",
  "AffectedServices": "web",
  "TargetSymbols": "exportInvoices:web/src/invoices.ts:10",
  "Kind": "business",
  "Serves": ["O1"],
  "Enables": []
}
\`\`\`

## Verification Notes

| Criterion | Role | Test data | Navigation path | Expected | Verifiable |
|---|---|---|---|---|---|
${rows}
SPEC
}

_spec "a-schema" "Persist invoice exports" "planned, feature" \
  "- [ ] The Export button appears on the invoice list
- [ ] Exports are stored for 30 days"
_spec "b-api" "Finance can export invoices" "planned, feature, blocked-by:a" \
  "- [ ] Export responds with 200
- [ ] Export downloads a file named invoices.csv"

planner_state_init "$INIT" "export invoices" >/dev/null
planner_state_write "$INIT" "Crosscheck" "check" "done" "clean"

# ── the draft gate's output, judged with S1's pure evaluator ──────────────

ROOT=$(planner_draft_readiness_root "$INIT")
planner_draft_readiness_refresh "$INIT" >/dev/null

# _scan_result <tid> <hash> <findings-lines>
_scan_result() {
  local tid="$1" hash="$2" findings="$3"
  local rc="clear" cr="clear" ec="clear"
  case "$findings" in *MISSING_CORE_AC*) rc="finding" ;; esac
  case "$findings" in *CONTRADICTORY_REQUIREMENTS*) cr="finding" ;; esac
  case "$findings" in *EDGE_CASE_GAP*) ec="finding" ;; esac
  cat <<EOF
=== DOR_SEMANTIC_SCAN ===
SCHEMA_VERSION: 1
TICKET: ${tid}
BODY_HASH: ${hash}
${findings}
GAP_REQUIREMENT_COMPLETENESS: ${rc}
GAP_REQUIREMENT_COMPLETENESS_REASON: see findings
GAP_CONTRADICTORY_REQUIREMENTS: ${cr}
GAP_CONTRADICTORY_REQUIREMENTS_REASON: see findings
GAP_DEEP_SCOPE_AMBIGUITY: clear
GAP_DEEP_SCOPE_AMBIGUITY_REASON: covered
GAP_EDGE_CASE_SUFFICIENCY: ${ec}
GAP_EDGE_CASE_SUFFICIENCY_REASON: see findings
=== END DOR_SEMANTIC_SCAN ===
EOF
}
_audit_result() {
  cat <<EOF
=== DOR_SEMANTIC_AUDIT ===
SCHEMA_VERSION: 1
TICKET: $1
BODY_HASH: $2
SCORE_PLAUSIBLE: yes
SCORE_REASON: matches
=== END DOR_SEMANTIC_AUDIT ===
EOF
}

# _draft_judge <slug> <findings-lines> — semantic.json + lineage.json + verdict.
_draft_judge() {
  local slug="$1" findings="$2" dir tid hash body scan audit judged built sem
  dir="${ROOT}/${slug}"
  tid="DRAFT-${slug}"
  body=$(cat "${dir}/body.md")
  hash=$(_dor_body_hash "$body")
  echo '{"missing":[],"advisory":[],"status":"ready"}' >"${dir}/dor-result.json"
  _scan_result "$tid" "$hash" "$findings" >"${dir}/scan-result.txt"
  _audit_result "$tid" "$hash" >"${dir}/audit-result.txt"
  scan=$(bash "$PARSE" --kind scan --result-file "${dir}/scan-result.txt") || return 1
  audit=$(bash "$PARSE" --kind audit --result-file "${dir}/audit-result.txt" --det-result "${dir}/dor-result.json") || return 1
  judged=$(dor_semantic_findings "$tid" "$body" "$scan" "$audit") || return 1
  built=$(dor_semantic_lineage_from null "$body" "$hash" "$(echo "$judged" | jq -c .findings)" '[]') || return 1
  sem=$(dor_semantic_assemble "$hash" "$(echo "$built" | jq -c .findings)" \
    "$(echo "$judged" | jq -c .unverified_gaps)" "$scan" "$audit") || return 1
  echo "$sem" >"${dir}/semantic.json"
  echo "$built" | jq -c .lineage >"${dir}/lineage.json"
  planner_draft_readiness_verdict_write "$INIT" "$slug" "$hash" "$DOR_SEMANTIC_EVALUATOR" ready
}

# b-api: an edge-case finding the loop demoted at its round limit, and a
# finding quoting the draft sibling id.
_draft_judge b-api "FINDING_1_CODE: EDGE_CASE_GAP
FINDING_1_QUOTE: Export downloads a file named invoices.csv
FINDING_1_DETAIL: no criterion for an empty invoice list
FINDING_2_CODE: MISSING_CORE_AC
FINDING_2_QUOTE: Blocked by DRAFT-a-schema
FINDING_2_DETAIL: the dependency outcome is not a criterion" || fail "fixture" "b-api judge"
jq -c '.findings |= map(if .code == "EDGE_CASE_GAP"
  then . + {severity: "advisory", demoted: "round-limit", demote_reason: "revised"} else . end)' \
  "${ROOT}/b-api/semantic.json" >"${TMP_ROOT}/s.json" && mv "${TMP_ROOT}/s.json" "${ROOT}/b-api/semantic.json"
# Its draft passed: the MISSING_CORE_AC finding was demoted too.
jq -c '.findings |= map(if .code == "MISSING_CORE_AC"
  then . + {severity: "advisory", demoted: "round-limit", demote_reason: "rebutted"} else . end)' \
  "${ROOT}/b-api/semantic.json" >"${TMP_ROOT}/s.json" && mv "${TMP_ROOT}/s.json" "${ROOT}/b-api/semantic.json"
# a-schema: a clean draft, and no lineage.json (the halt-only gate keeps none).
_draft_judge a-schema "" || fail "fixture" "a-schema judge"
rm -f "${ROOT}/a-schema/lineage.json"

# ── EpicGen + TicketGen ───────────────────────────────────────────────────
EPIC="CRE-10"
planner_state_write "$INIT" "EpicGen" "create" "done" "EPIC_ID=${EPIC}"
write_epic_manifest "$EPIC" "" "per-ticket" "" '[]' >/dev/null
_ticket() {
  local slug="$1" tid="$2"
  planner_record_intent "$INIT" "TicketGen" "ticket" "ticket-${slug}" >/dev/null
  planner_entity_mark_created "$INIT" "ticket-${slug}" "$tid" >/dev/null
  write_ticket_manifest "$tid" "$INIT" "feature" '[]' >/dev/null
  add_epic_manifest_child "$EPIC" "$tid" >/dev/null
  mkdir -p "${IDIR}/tickets/${tid}/planner"
}
_ticket a-schema CRE-11
_ticket b-api CRE-12
PA="${IDIR}/tickets/CRE-11/planner"
PB="${IDIR}/tickets/CRE-12/planner"
planner_ticketgen_body "$INIT" "$EPIC" a-schema >"${PA}/tg.md" 2>/dev/null
planner_ticketgen_body "$INIT" "$EPIC" b-api >"${PB}/tg.md" 2>/dev/null
planner_state_write "$INIT" "TicketGen" "verify" "done" "2 tickets verified."

# b-api body as Linear stored it: CRLF, trailing spaces, sibling id as a link.
sed -e 's/CRE-11 —/[CRE-11](https:\/\/linear.app\/acme\/issue\/CRE-11\/persist-invoice-exports) —/' \
  -e 's/$/  \r/' "${PB}/tg.md" >"${PB}/body.md"
grep -qF '[CRE-11](https://linear.app' "${PB}/body.md" || fail "fixture" "link not injected"
# a-schema body: one criterion edited after the gate.
sed 's/^- \[ \] Exports are stored for 30 days$/- [ ] Exports are stored for 90 days/' "${PA}/tg.md" >"${PA}/body.md"
grep -qF 'stored for 90 days' "${PA}/body.md" || fail "fixture" "criterion not edited"

LOG="${IDIR}/state.log"

# ── 1. import ─────────────────────────────────────────────────────────────
echo "--- 1. import on an equivalent (Linear-re-rendered) body ---"
listed=$(planner_refinement_scan "$INIT")
if ! grep -qx CRE-12 <<<"$listed"; then
  pass "equivalent body: no semantic pass listed (zero spawns)"
else
  fail "import spawn" "$listed"
fi
readyB=$(get_ticket_manifest_field CRE-12 ready)
if echo "$readyB" | jq -e --arg e "$DOR_SEMANTIC_EVALUATOR" '.semantic.imported_from != null and .semantic.evaluator == $e' >/dev/null 2>&1; then
  pass "draft verdict imported (imported_from set)"
else
  fail "imported" "$readyB"
fi
if echo "$readyB" | jq -e '[.semantic.findings[] | select(.code == "EDGE_CASE_GAP" and .severity == "advisory" and .demoted == "round-limit")] | length == 1' >/dev/null; then
  pass "round-limit demotion kept advisory"
else
  fail "demotion" "$(echo "$readyB" | jq -c '.semantic.findings')"
fi
if echo "$readyB" | jq -e '[.semantic.findings[] | select(.code == "MISSING_CORE_AC")] | length == 0' >/dev/null &&
  ! echo "$readyB" | jq -e '(.missing // []) | map(select(startswith("SEMANTIC_"))) | length > 0' >/dev/null; then
  pass "DRAFT-<slug> quote that no longer locates is dropped; no SEMANTIC_* code"
else
  fail "dropped quote" "$(echo "$readyB" | jq -c '{missing, f: .semantic.findings}')"
fi
if grep -qE '\|META\|refinement-draft-import\|done\|CRE-12 from=DRAFT-b-api round=1 demoted=1 dropped=1$' "$LOG"; then
  pass "import line logged with round/demoted/dropped"
else
  fail "import line" "$(grep refinement-draft-import "$LOG")"
fi
[ "$(echo "$readyB" | jq -r '.lineage.round')" = 1 ] && pass "import adds no round" || fail "import round" "$(echo "$readyB" | jq -c .lineage.round)"

# ── 2. draft-passed scan ──────────────────────────────────────────────────
echo "--- 2. draft-passed scan on a non-equivalent body ---"
if grep -qx CRE-11 <<<"$listed"; then
  pass "non-equivalent body is listed for a semantic pass"
else
  fail "draft-passed listed" "$listed"
fi
[ -f "${PA}/draft-passed" ] && pass "draft-passed marker written" || fail "marker" "missing"
readyA=$(get_ticket_manifest_field CRE-11 ready)
if echo "$readyA" | jq -e '.lineage.seeded_from == "draft" and .lineage.round == 1' >/dev/null 2>&1; then
  pass "prior lineage seeded from the draft (rebuilt without lineage.json)"
else
  fail "seed" "$(echo "$readyA" | jq -c .lineage)"
fi
grep -qE '\|META\|refinement-draft-import\|skip\|CRE-11 not-equivalent draft-passed round=2$' "$LOG" &&
  pass "skip line logged" || fail "skip line" "$(grep refinement-draft-import "$LOG")"

hashA=$(_dor_body_hash "$(cat "${PA}/body.md")")
_scan_result CRE-11 "$hashA" "FINDING_1_CODE: MISSING_CORE_AC
FINDING_1_QUOTE: Only finance users may export
FINDING_1_DETAIL: no criterion for a non-finance user
FINDING_2_CODE: CONTRADICTORY_REQUIREMENTS
FINDING_2_QUOTE: Scheduled exports
FINDING_2_QUOTE_B: An Export action on the invoice list
FINDING_2_DETAIL: out of scope conflicts with stored exports
FINDING_3_CODE: CONTRADICTORY_REQUIREMENTS
FINDING_3_QUOTE: Exports are stored for 90 days
FINDING_3_QUOTE_B: Scheduled exports
FINDING_3_DETAIL: retention conflicts with the summary" >"${PA}/semantic-scan-result.txt"
_audit_result CRE-11 "$hashA" >"${PA}/semantic-audit-result.txt"
# The audit judges hard codes; this fixture body has none it must judge.
echo '{"missing":[],"advisory":[],"status":"ready"}' >"${PA}/dor-result.json"
if planner_refinement_apply "$INIT" CRE-11 >/dev/null 2>"${TMP_ROOT}/apply.err"; then
  pass "apply succeeded"
else
  fail "apply" "$(cat "${TMP_ROOT}/apply.err")"
fi
readyA=$(get_ticket_manifest_field CRE-11 ready)
f_of() { echo "$readyA" | jq -c --arg q "$1" '[.semantic.findings[] | select(.quote == $q)][0]'; }
if echo "$(f_of 'Only finance users may export')" | jq -e '.severity == "advisory" and .demoted == "draft-passed"' >/dev/null; then
  pass "non-structural finding → draft-passed advisory"
else
  fail "draft-passed" "$(f_of 'Only finance users may export')"
fi
if echo "$(f_of 'Scheduled exports')" | jq -e '.severity == "advisory" and .demoted == "draft-passed-structural" and .demote_reason == "unchanged-unit"' >/dev/null; then
  pass "new structural finding on an unchanged unit → draft-passed-structural with a reason"
else
  fail "structural unchanged" "$(f_of 'Scheduled exports')"
fi
if echo "$(f_of 'Exports are stored for 90 days')" | jq -e '.severity == "blocking" and .demoted == null' >/dev/null &&
  echo "$readyA" | jq -e '.missing | index("SEMANTIC_ACCEPTANCE_CRITERIA") != null' >/dev/null; then
  pass "structural finding on the changed criterion still blocks"
else
  fail "structural changed" "$(f_of 'Exports are stored for 90 days') $(echo "$readyA" | jq -c .missing)"
fi
if echo "$readyA" | jq -e '.lineage.reset == false and .lineage.round == 2 and .lineage.policy.prior_passed == true' >/dev/null; then
  pass "no reset; round n+1; policy records prior_passed"
else
  fail "reset" "$(echo "$readyA" | jq -c '.lineage | {round, reset, p: .policy.prior_passed}')"
fi
[ ! -f "${PA}/draft-passed" ] && pass "marker cleared after the apply" || fail "marker cleared" "still there"

# ── 3. existing verdict untouched ─────────────────────────────────────────
echo "--- 3. existing verdict ---"
before=$(get_ticket_manifest_field CRE-12 ready | jq -c .semantic)
nlines=$(grep -c refinement-draft-import "$LOG")
planner_refinement_scan "$INIT" >/dev/null
after=$(get_ticket_manifest_field CRE-12 ready | jq -c .semantic)
if [ "$before" = "$after" ] && [ "$(grep -c refinement-draft-import "$LOG")" = "$nlines" ]; then
  pass "a ticket with a semantic verdict is not re-imported or re-seeded"
else
  fail "existing verdict" "lines $(grep -c refinement-draft-import "$LOG") vs $nlines"
fi

# ── 4. switch off / no draft directory ────────────────────────────────────
echo "--- 4. old path ---"
_reset_b() {
  rm -f "$(get_ticket_manifest_path CRE-12)"
  write_ticket_manifest CRE-12 "$INIT" "feature" '[]' >/dev/null
}
_reset_b
listed=$(PLANNER_DRAFT_VERDICT_IMPORT=false planner_refinement_scan "$INIT")
if grep -qx CRE-12 <<<"$listed" &&
  ! get_ticket_manifest_field CRE-12 ready | jq -e '.semantic' >/dev/null 2>&1 &&
  [ "$(grep -c refinement-draft-import "$LOG")" = "$nlines" ]; then
  pass "PLANNER_DRAFT_VERDICT_IMPORT=false: no import, ticket listed"
else
  fail "switch off" "$listed"
fi
_reset_b
touch "${PA}/draft-passed"
mv "$ROOT" "${TMP_ROOT}/dr-saved"
listed=$(planner_refinement_scan "$INIT")
if grep -qx CRE-12 <<<"$listed" && ! get_ticket_manifest_field CRE-12 ready | jq -e '.semantic' >/dev/null 2>&1; then
  pass "no draft directory: old path"
else
  fail "no draft dir" "$listed"
fi
mv "${TMP_ROOT}/dr-saved" "$ROOT"
rm -f "${PA}/draft-passed"

# ── 5. draft status ───────────────────────────────────────────────────────
echo "--- 5. draft status ---"
[ "$(planner_draft_carryover_status "$INIT" b-api)" = ready ] && pass "status ready" || fail "ready" "$(planner_draft_carryover_status "$INIT" b-api)"
hb=$(cut -d' ' -f1 "${ROOT}/b-api/verdict")
planner_draft_readiness_verdict_write "$INIT" b-api "$hb" "$DOR_SEMANTIC_EVALUATOR" blocked
[ "$(planner_draft_carryover_status "$INIT" b-api)" = blocked ] && pass "status blocked" || fail "blocked" "x"
planner_draft_readiness_accept "$INIT" "known gap" >/dev/null
[ "$(planner_draft_carryover_status "$INIT" b-api)" = accepted ] && pass "blocked + accept on current drafts → accepted" || fail "accepted" "x"
planner_draft_readiness_verdict_write "$INIT" b-api "sha256:0000" "$DOR_SEMANTIC_EVALUATOR" ready
[ "$(planner_draft_carryover_status "$INIT" b-api)" = stale ] && pass "verdict for another body → stale (old path)" || fail "stale" "x"
[ "$(planner_draft_carryover_status "$INIT" nope)" = none ] && pass "no verdict → none" || fail "none" "x"

# ── 6. epic summary ───────────────────────────────────────────────────────
echo "--- 6. epic summary ---"
INIT2="INIT-DC2"
mkdir -p "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT2}/artifacts"
cp -r "$SPECS" "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT2}/artifacts/specs"
planner_state_init "$INIT2" "export invoices" >/dev/null
[ -z "$(planner_draft_readiness_epic_summary "$INIT2")" ] && pass "no draft directory: no summary" || fail "empty" "printed"
R2="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT2}/artifacts/draft-readiness"
mkdir -p "${R2}/a-schema" "${R2}/b-api"
echo '{"findings":[{"code":"EDGE_CASE_GAP","severity":"advisory","verified":true}]}' >"${R2}/b-api/semantic.json"
[ -z "$(planner_draft_readiness_epic_summary "$INIT2")" ] && pass "no revision, no demotion: no summary" || fail "empty2" "printed"
S2="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT2}/artifacts/specs"
cp "${S2}/a-schema.md" "${R2}/a-schema/spec.r0.md"
echo applied >"${R2}/a-schema/revise.r1.status"
echo unchanged >"${R2}/a-schema/revise.r2.status"
sed -i 's/^- \[ \] Exports are stored for 30 days$/- [ ] Exports are stored for 30 days after the last download\n- [ ] A non-finance user gets 403 from the export route/' "${S2}/a-schema.md"
echo '{"findings":[{"code":"MISSING_CORE_AC","severity":"advisory","demoted":"round-limit","demote_reason":"revised","verified":true}]}' \
  >"${R2}/a-schema/semantic.json"
sum=$(planner_draft_readiness_epic_summary "$INIT2")
if grep -qx '## Revised by draft readiness' <<<"$sum" &&
  grep -qx '### Persist invoice exports' <<<"$sum" &&
  grep -qxF -- '- Revision rounds: 2 (applied, unchanged)' <<<"$sum" &&
  grep -qxF -- '- Extended criterion: Exports are stored for 30 days after the last download' <<<"$sum" &&
  grep -qxF -- '- Added criterion: A non-finance user gets 403 from the export route' <<<"$sum" &&
  grep -qxF -- '- Demoted MISSING_CORE_AC: round-limit, revised' <<<"$sum"; then
  pass "summary: rounds, extended and added criteria, demotion with reason class"
else
  fail "summary" "$sum"
fi
if ! grep -q 'Finance can export invoices' <<<"$sum"; then
  pass "a spec with nothing to report is not listed"
else
  fail "unlisted spec" "$sum"
fi
planner_state_write "$INIT2" "Crosscheck" "check" "done" "clean"
planner_state_write "$INIT2" "EpicGen" "create" "done" "EPIC_ID=CRE-20"
leak=0
for s in a-schema b-api; do
  planner_ticketgen_body "$INIT2" "CRE-20" "$s" 2>/dev/null | grep -q 'Revised by draft readiness' && leak=1
done
[ "$leak" = 0 ] && pass "no ticket body carries the summary" || fail "ticket body" "summary leaked"
source "${LIB_DIR}/planner-phase-prompts.sh"
if planner_prompt_epicgen "$INIT2" "export invoices" "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT2}" 2>/dev/null |
  grep -q 'planner_draft_readiness_epic_summary "INIT-DC2"'; then
  pass "EpicGen prompt appends the summary to the epic description"
else
  fail "epicgen prompt" "not wired"
fi

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
