#!/usr/bin/env bash
# test-planner-draft-carryover-e2e.sh — planner-draft-readiness S3b → S4
# integration: the revise loop's real on-disk output feeds Refinement's
# carry-over and the epic summary.
#
# The gate is driven exactly as SKILL.md steps 1d + 1e drive it, with the
# stubbed agents of test-planner-draft-readiness-loop.sh (a scan that raises
# a fixed finding until the spec holds a fix text; a revise agent that adds a
# criterion without fixing it). Then TicketGen bodies are written as Linear
# stores them and planner_refinement_scan runs over them.
#
# Covers:
#   1. A spec revised twice and demoted at the limit (round-limit / revised)
#      passes the gate with lineage.json round 3; its Linear-re-rendered
#      ticket imports that verdict: no pass listed, the demotion and its
#      reason class kept, lineage round unchanged, no SEMANTIC_* code.
#   2. A clean spec whose ticket body was edited is seeded from the gate's
#      real lineage.json (evaluator matches, so the drift test applies) and
#      scanned with the draft-passed policy.
#   3. The epic summary reads the loop's revise history and demotion reasons.
#   4. An accepted (blocked) draft with an equivalent body is NOT imported —
#      it takes the draft-passed scan, so the accepted structural finding is
#      advisory on the unchanged unit.
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-carryover-e2e.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="${TMP_ROOT}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${TMP_ROOT}/repos"
export TMPDIR="${TMP_ROOT}/tmp"
mkdir -p "$TMPDIR"
export PLANNER_DRAFT_SNAPSHOT_ROOT="${TMP_ROOT}/snaps"
export PLANNER_REFINEMENT_DRIFT_CHECK=false
unset PLANNER_DRAFT_REVISE_MAX_ROUNDS PLANNER_DRAFT_SPAWN_BUDGET PLANNER_DRAFT_DEMOTE_CEILING
unset PLANNER_DRAFT_VERDICT_IMPORT PLANNER_REFINEMENT_SEMANTIC

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-draft-carryover.sh"
_planner_refinement_source_deps || exit 1
PARSE="$(_planner_refinement_resolve dor-semantic-parse.sh)"

# Crosscheck and Linear are stubbed: the loop re-runs Crosscheck after an
# applied round; nothing here may reach Linear.
planner_crosscheck_run() {
  planner_state_write "$1" "Crosscheck" "check" "start" ""
  planner_state_write "$1" "Crosscheck" "check" "done" "clean"
}
planner_crosscheck_findings_report() { echo "CROSSCHECK REPORT"; }
planner_linear_graphql() { return 1; }

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

echo "=== planner draft carry-over end to end (S3b → S4) ==="

FIXTEXT="Export shows a progress message while the download starts"
SOURCE_QUOTE="Finance staff rebuild the invoice list by hand for every audit."

_spec() {
  local slug="$1" title="$2" labels="$3" acs="$4" ac crit rows=""
  while IFS= read -r ac; do
    crit="${ac#- \[ \] }"
    rows+="| ${crit} | finance user | none | Invoices > Export | done | yes |"$'\n'
  done <<<"$acs"
  cat >"${SPECS}/${slug}.md" <<SPEC
# ${slug}

## Title

${title}

## Description

## Summary

${title}, in plain language.

## Why

${SOURCE_QUOTE}

## Scope

| Layer | Service | Change |
|---|---|---|
| BE | web | export route |

## Outcome

**Serves:** O1

**Outcome:** Invoices can be exported.

## Proposed Behaviour

An Export action on the invoice list.

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
{"services_identified": 2, "symbols_resolved": 3, "prior_art_found": true, "complexity": "simple", "exploration_depth": "standard", "Strategy": "Balanced", "Decision": "Add an export route", "AffectedServices": "web", "TargetSymbols": "exportInvoices:web/src/invoices.ts:10", "Kind": "business", "Serves": ["O1"], "Enables": []}
\`\`\`

## Verification Notes

| Criterion | Role | Test data | Navigation path | Expected | Verifiable |
|---|---|---|---|---|---|
${rows}
SPEC
}

_setup() {
  INIT="$1"
  IDIR="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
  SPECS="${IDIR}/artifacts/specs"
  LOG="${IDIR}/state.log"
  DR="${IDIR}/artifacts/draft-readiness"
  mkdir -p "$SPECS"
  _spec "a-schema" "Persist invoice exports" "planned, feature" \
    "- [ ] The Export button appears on the invoice list
- [ ] Exports are stored for 30 days"
  _spec "b-api" "Finance can export invoices" "planned, feature, blocked-by:a" \
    "- [ ] Export responds with 200
- [ ] Export downloads a file named invoices.csv"
  {
    echo "2026-10-01T00:00:00Z|META|schema|done|1"
    for p in Appraisal Discovery Architecture Specify Review Consensus; do
      echo "2026-10-01T00:00:00Z|${p}|run|start|"
      echo "2026-10-01T00:00:00Z|${p}|run|done|"
    done
    echo "2026-10-01T00:00:01Z|Crosscheck|check|start|"
    echo "2026-10-01T00:00:01Z|Crosscheck|check|done|clean"
  } >"$LOG"
  unset FINDINGS_a_schema FINDINGS_b_api STRUCT_a_schema STRUCT_b_api REVISE_a_schema REVISE_b_api
}

# ── stub agents (as in test-planner-draft-readiness-loop.sh) ─────────────
_hash_of() { planner_draft_readiness_body_hash "${DR}/$1/body.md"; }
_scan_block() {
  local slug="$1" tid="DRAFT-$1" h body var i=0 f g
  h=$(_hash_of "$slug")
  body=$(cat "${DR}/${slug}/body.md")
  local -a list=()
  var="FINDINGS_${slug//-/_}"
  [[ "$body" == *"$FIXTEXT"* ]] && var="AFTER_${slug//-/_}"
  [ -n "${!var:-}" ] && list+=("${!var}")
  var="STRUCT_${slug//-/_}"
  [ -n "${!var:-}" ] && list+=("${!var}")
  echo "=== DOR_SEMANTIC_SCAN ==="
  echo "SCHEMA_VERSION: 1"
  echo "TICKET: ${tid}"
  echo "BODY_HASH: ${h}"
  for f in "${list[@]}"; do
    i=$((i + 1))
    echo "FINDING_${i}_CODE: ${f%%|*}"
    echo "FINDING_${i}_QUOTE: ${f#*|}"
    echo "FINDING_${i}_DETAIL: fixture gap"
  done
  for g in REQUIREMENT_COMPLETENESS CONTRADICTORY_REQUIREMENTS DEEP_SCOPE_AMBIGUITY EDGE_CASE_SUFFICIENCY; do
    echo "GAP_${g}: clear"
    echo "GAP_${g}_REASON: fixture"
  done
  echo "=== END DOR_SEMANTIC_SCAN ==="
}
_audit_block() {
  echo "=== DOR_SEMANTIC_AUDIT ==="
  echo "SCHEMA_VERSION: 1"
  echo "TICKET: DRAFT-$1"
  echo "BODY_HASH: $(_hash_of "$1")"
  echo "SCORE_PLAUSIBLE: yes"
  echo "SCORE_REASON: fixture"
  echo "=== END DOR_SEMANTIC_AUDIT ==="
}
_add_criterion() {
  python3 - "$1" "$2" <<'PY'
import sys
p, t = sys.argv[1], sys.argv[2]
lines = open(p).read().split("\n")
sec, last_ac = None, None
for i, l in enumerate(lines):
    if l.startswith("## "):
        sec = l[3:].strip()
    if sec == "Acceptance Criteria" and l.startswith("- [ ]"):
        last_ac = i
lines.insert(last_ac + 1, "- [ ] " + t)
sec, last_row = None, None
for i, l in enumerate(lines):
    if l.startswith("## "):
        sec = l[3:].strip()
    if sec == "Verification Notes" and l.startswith("|"):
        last_row = i
lines.insert(last_row + 1, "| %s | finance user | none | Invoices > Export | done | yes |" % t)
open(p, "w").write("\n".join(lines))
PY
}
_revise_agent() {
  local slug="$1" rf="$2" n ff id
  n="${rf##*/revise.r}"
  n="${n%.md}"
  ff="$(dirname "$rf")/findings.r${n}.json"
  _add_criterion "${SPECS}/${slug}.md" "The export file name includes the date in round ${n}"
  : >"$rf"
  for id in $(jq -r '.[] | .id // .code' "$ff"); do
    echo "RESOLVED ${id} — added a criterion — source: \"${SOURCE_QUOTE}\"" >>"$rf"
  done
}
_spawn_list() {
  local slug kind type pf rf
  while IFS=$'\t' read -r slug kind type pf rf; do
    [ -n "$slug" ] || continue
    case "$kind" in
    scan) _scan_block "$slug" >"$rf" ;;
    audit) _audit_block "$slug" >"$rf" ;;
    revise) _revise_agent "$slug" "$rf" ;;
    esac
  done <<<"$1"
}
# SKILL.md step 1d + 1e: begin → (next → spawn → apply)* → gate.
_gate() {
  local list rc=0 i
  planner_draft_readiness_begin "$INIT" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    for ((i = 1; i <= 30; i++)); do
      list=$(planner_draft_readiness_next "$INIT" 2>/dev/null) || {
        rc=1
        break
      }
      [ "$list" = "done 0" ] && break
      _spawn_list "$list"
      planner_draft_readiness_apply "$INIT" >/dev/null 2>&1 || rc=1
    done
    [ "$rc" -eq 0 ] && { planner_draft_readiness_gate "$INIT" >/dev/null 2>&1 || rc=$?; }
  fi
  GATE_RC=$rc
}

# _ticketgen <EPIC> — EpicGen + TicketGen as far as Refinement needs them:
# epic manifest, ticket manifests, intent ids, TicketGen bodies in tg.md.
_ticketgen() {
  local epic="$1" n=0 slug tid
  planner_state_write "$INIT" "EpicGen" "create" "done" "EPIC_ID=${epic}"
  write_epic_manifest "$epic" "" "per-ticket" "" '[]' >/dev/null
  for slug in a-schema b-api; do
    n=$((n + 1))
    tid="${epic%-*}-$((${epic##*-} + n))"
    planner_record_intent "$INIT" "TicketGen" "ticket" "ticket-${slug}" >/dev/null
    planner_entity_mark_created "$INIT" "ticket-${slug}" "$tid" >/dev/null
    write_ticket_manifest "$tid" "$INIT" "feature" '[]' >/dev/null
    add_epic_manifest_child "$epic" "$tid" >/dev/null
    mkdir -p "${IDIR}/tickets/${tid}/planner"
  done
  for slug in a-schema b-api; do
    tid=$(planner_entity_get_id "$INIT" "ticket-${slug}")
    planner_ticketgen_body "$INIT" "$epic" "$slug" >"${IDIR}/tickets/${tid}/planner/tg.md" 2>/dev/null
  done
  planner_state_write "$INIT" "TicketGen" "verify" "done" "2 tickets verified."
}
# _linear_render <src> <dst> <linked-id> — CRLF, trailing spaces, the sibling
# id rendered as a Linear link.
_linear_render() {
  sed -e "s/$3 —/[$3](https:\/\/linear.app\/acme\/issue\/$3\/x) —/" -e 's/$/  \r/' "$1" >"$2"
}

# ── 1. revised + demoted spec → import ───────────────────────────────────
echo "--- 1. S3b loop output imported on an equivalent ticket body ---"
_setup INIT-E1
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
_gate
vb=$(planner_draft_readiness_verdict_read "$INIT" b-api)
if [ "$GATE_RC" -eq 0 ] && [ "${vb##* }" = ready ] &&
  [ "$(planner_draft_revise_rounds_used "$INIT" b-api)" -eq 2 ] &&
  [ "$(jq -r .round "${DR}/b-api/lineage.json")" = 3 ] &&
  jq -e '[.findings[] | select(.code == "EDGE_CASE_GAP" and .demoted == "round-limit" and .demote_reason == "revised")] | length == 1' \
    "${DR}/b-api/semantic.json" >/dev/null &&
  [ -s "${DR}/a-schema/lineage.json" ] && [ "$(planner_draft_carryover_status "$INIT" b-api)" = ready ]; then
  pass "loop: b-api revised twice, demoted round-limit/revised, ready; lineage.json round 3"
else
  fail "loop fixture" "rc=$GATE_RC verdict=$vb $(jq -c '.findings' "${DR}/b-api/semantic.json" 2>/dev/null)"
fi

_ticketgen CRE-10
PA="${IDIR}/tickets/CRE-11/planner"
PB="${IDIR}/tickets/CRE-12/planner"
_linear_render "${PB}/tg.md" "${PB}/body.md" CRE-11
sed 's/^- \[ \] Exports are stored for 30 days$/- [ ] Exports are stored for 90 days/' "${PA}/tg.md" >"${PA}/body.md"

listed=$(planner_refinement_scan "$INIT")
readyB=$(get_ticket_manifest_field CRE-12 ready)
if ! grep -qx CRE-12 <<<"$listed" &&
  echo "$readyB" | jq -e '.semantic.imported_from != null
    and ([.semantic.findings[] | select(.code == "EDGE_CASE_GAP" and .severity == "advisory"
         and .demoted == "round-limit" and .demote_reason == "revised")] | length == 1)
    and .lineage.round == 3
    and (((.missing // []) | map(select(startswith("SEMANTIC_")))) | length == 0)' >/dev/null; then
  pass "import: zero spawns, lineage-time demotion + loop's reason class kept, round 3 kept, no SEMANTIC_*"
else
  fail "import" "listed=$listed $(echo "$readyB" | jq -c '{m: .missing, r: .lineage.round, f: .semantic.findings}')"
fi
grep -qE '\|META\|refinement-draft-import\|done\|CRE-12 from=DRAFT-b-api round=3 demoted=1 dropped=0$' "$LOG" &&
  pass "import line" || fail "import line" "$(grep refinement-draft-import "$LOG")"

# ── 2. clean spec, edited ticket → seeded from the real lineage.json ─────
echo "--- 2. draft-passed scan seeded from the gate's lineage.json ---"
readyA=$(get_ticket_manifest_field CRE-11 ready)
if grep -qx CRE-11 <<<"$listed" && [ -f "${PA}/draft-passed" ] &&
  echo "$readyA" | jq -e --arg e "$DOR_SEMANTIC_EVALUATOR" \
    '.lineage.seeded_from == "draft" and .lineage.evaluator == $e and .lineage.round == 1' >/dev/null; then
  pass "edited body listed; lineage seeded from lineage.json (evaluator matches)"
else
  fail "seed" "listed=$listed $(echo "$readyA" | jq -c '.lineage | {seeded_from, evaluator, round}')"
fi
hashA=$(_dor_body_hash "$(cat "${PA}/body.md")")
{
  echo "=== DOR_SEMANTIC_SCAN ==="
  echo "SCHEMA_VERSION: 1"
  echo "TICKET: CRE-11"
  echo "BODY_HASH: ${hashA}"
  echo "FINDING_1_CODE: EDGE_CASE_GAP"
  echo "FINDING_1_QUOTE: The Export button appears on the invoice list"
  echo "FINDING_1_DETAIL: no criterion for an empty list"
  echo "FINDING_2_CODE: INTENT_AC_MISMATCH"
  echo "FINDING_2_QUOTE: Exports are stored for 90 days"
  echo "FINDING_2_DETAIL: retention not in the intent"
  for g in REQUIREMENT_COMPLETENESS CONTRADICTORY_REQUIREMENTS DEEP_SCOPE_AMBIGUITY EDGE_CASE_SUFFICIENCY; do
    echo "GAP_${g}: clear"
    echo "GAP_${g}_REASON: fixture"
  done
  echo "=== END DOR_SEMANTIC_SCAN ==="
} >"${PA}/semantic-scan-result.txt"
{
  echo "=== DOR_SEMANTIC_AUDIT ==="
  echo "SCHEMA_VERSION: 1"
  echo "TICKET: CRE-11"
  echo "BODY_HASH: ${hashA}"
  echo "SCORE_PLAUSIBLE: yes"
  echo "SCORE_REASON: fixture"
  echo "=== END DOR_SEMANTIC_AUDIT ==="
} >"${PA}/semantic-audit-result.txt"
echo '{"missing":[],"advisory":[],"status":"ready"}' >"${PA}/dor-result.json"
planner_refinement_apply "$INIT" CRE-11 >/dev/null 2>&1
readyA=$(get_ticket_manifest_field CRE-11 ready)
if echo "$readyA" | jq -e '
    ([.semantic.findings[] | select(.code == "EDGE_CASE_GAP" and .demoted == "draft-passed")] | length == 1)
    and ([.semantic.findings[] | select(.code == "INTENT_AC_MISMATCH" and .severity == "blocking")] | length == 1)
    and .lineage.round == 2 and .lineage.reset == false' >/dev/null; then
  pass "draft-passed: non-structural advisory; structural on the edited criterion blocks; round 2, no reset"
else
  fail "draft-passed apply" "$(echo "$readyA" | jq -c '{r: .lineage.round, f: [.semantic.findings[] | {code, severity, demoted}]}')"
fi

# ── 3. epic summary from the loop's history ──────────────────────────────
echo "--- 3. epic summary ---"
sum=$(planner_draft_readiness_epic_summary "$INIT")
if grep -qx '### Finance can export invoices' <<<"$sum" &&
  grep -qxF -- '- Revision rounds: 2 (applied, applied)' <<<"$sum" &&
  grep -qxF -- '- Added criterion: The export file name includes the date in round 1' <<<"$sum" &&
  grep -qxF -- '- Added criterion: The export file name includes the date in round 2' <<<"$sum" &&
  grep -qxF -- '- Demoted EDGE_CASE_GAP: round-limit, revised' <<<"$sum" &&
  ! grep -q 'Persist invoice exports' <<<"$sum"; then
  pass "summary lists the loop's rounds, added criteria and demotion reason; clean spec omitted"
else
  fail "summary" "$sum"
fi
if ! grep -q 'Revised by draft readiness' "${PA}/tg.md" "${PB}/tg.md"; then
  pass "no ticket body carries the summary"
else
  fail "ticket body" "leaked"
fi

# ── 4. accepted blocked draft → draft-passed scan, never import ──────────
echo "--- 4. accepted draft is scanned, not imported ---"
_setup INIT-E2
export STRUCT_a_schema="INTENT_AC_MISMATCH|Scheduled exports"
_gate
va=$(planner_draft_readiness_verdict_read "$INIT" a-schema)
planner_draft_readiness_accept "$INIT" "retention is the product decision" >/dev/null 2>&1
if [ "$GATE_RC" -eq 3 ] && [ "${va##* }" = blocked ] && [ "$(planner_draft_carryover_status "$INIT" a-schema)" = accepted ]; then
  pass "gate blocks on a structural finding; the accept makes the draft status accepted"
else
  fail "accepted fixture" "rc=$GATE_RC verdict=$va status=$(planner_draft_carryover_status "$INIT" a-schema)"
fi
_ticketgen CRE-20
PA2="${IDIR}/tickets/CRE-21/planner"
cp "${PA2}/tg.md" "${PA2}/body.md"
cp "${IDIR}/tickets/CRE-22/planner/tg.md" "${IDIR}/tickets/CRE-22/planner/body.md"
listed=$(planner_refinement_scan "$INIT")
if grep -qx CRE-21 <<<"$listed" && [ -f "${PA2}/draft-passed" ] &&
  ! get_ticket_manifest_field CRE-21 ready | jq -e '.semantic' >/dev/null 2>&1 &&
  grep -qE '\|META\|refinement-draft-import\|skip\|CRE-21 accepted draft-passed round=2$' "$LOG" &&
  grep -qE '\|META\|refinement-draft-import\|done\|CRE-22 from=DRAFT-b-api ' "$LOG"; then
  pass "accepted draft with an equivalent body: seeded and scanned; the ready sibling imported"
else
  fail "accepted path" "listed=$listed $(grep refinement-draft-import "$LOG")"
fi
hashA2=$(_dor_body_hash "$(cat "${PA2}/body.md")")
{
  echo "=== DOR_SEMANTIC_SCAN ==="
  echo "SCHEMA_VERSION: 1"
  echo "TICKET: CRE-21"
  echo "BODY_HASH: ${hashA2}"
  echo "FINDING_1_CODE: INTENT_AC_MISMATCH"
  echo "FINDING_1_QUOTE: Scheduled exports"
  echo "FINDING_1_DETAIL: fixture gap"
  for g in REQUIREMENT_COMPLETENESS CONTRADICTORY_REQUIREMENTS DEEP_SCOPE_AMBIGUITY EDGE_CASE_SUFFICIENCY; do
    echo "GAP_${g}: clear"
    echo "GAP_${g}_REASON: fixture"
  done
  echo "=== END DOR_SEMANTIC_SCAN ==="
} >"${PA2}/semantic-scan-result.txt"
{
  echo "=== DOR_SEMANTIC_AUDIT ==="
  echo "SCHEMA_VERSION: 1"
  echo "TICKET: CRE-21"
  echo "BODY_HASH: ${hashA2}"
  echo "SCORE_PLAUSIBLE: yes"
  echo "SCORE_REASON: fixture"
  echo "=== END DOR_SEMANTIC_AUDIT ==="
} >"${PA2}/semantic-audit-result.txt"
echo '{"missing":[],"advisory":[],"status":"ready"}' >"${PA2}/dor-result.json"
planner_refinement_apply "$INIT" CRE-21 >/dev/null 2>&1
# The accepted (blocking) finding left the seeded prior, so its re-raise on
# the unchanged unit is new and demoted: the accept travels to Refinement
# instead of re-halting on the same gap.
if get_ticket_manifest_field CRE-21 ready | jq -e '
    ([.semantic.findings[] | select(.code == "INTENT_AC_MISMATCH" and .severity == "advisory"
      and .lineage != "carried" and .demoted == "draft-passed-structural")] | length == 1)
    and (((.missing // []) | map(select(startswith("SEMANTIC_")))) | length == 0)' >/dev/null; then
  pass "accepted structural finding on the unchanged unit: draft-passed-structural, no SEMANTIC_*"
else
  fail "accepted structural" "$(get_ticket_manifest_field CRE-21 ready | jq -c '{m: .missing, f: [.semantic.findings[] | {code, severity, lineage, demoted}]}')"
fi

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
