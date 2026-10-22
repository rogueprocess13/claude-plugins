#!/usr/bin/env bash
# test-dor-semantic-lineage.sh — finding identity, lineage, rounds, drift and
# round-limit demotion, the policy snapshot, the v2 → v3 migration and the
# scoped-rescan prompt hint (planner-refinement-convergence, group 2:
# dor-semantic.sh dor_semantic_apply / _dor_unit_of /
# _dor_semantic_finding_id / dor_semantic_migrate_v2 / dor_semantic_prompt).
# Usage: bash test-dor-semantic-lineage.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LIB_DIR/dor-semantic.sh"

PASS=0
FAIL=0
_pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_fail() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
unset DOR_SEMANTIC_INERT_SECTIONS DOR_SEMANTIC_MAX_ROUNDS DOR_SEMANTIC_DRIFT_DEMOTE \
  DOR_SEMANTIC_ROUND_RESET_SHARE DOR_SEMANTIC_STRUCTURAL_CODES DOR_SEMANTIC_ADVISORY_CODES

# Four non-inert sections (Summary, Background, Acceptance Criteria, Scope)
# plus the inert Related Tickets.
base_body='## Summary
Save handovers reliably from the settings page.

## Background
Attorneys report the Save button silently failing on the settings page.

## Acceptance Criteria
- [ ] Save button stores the handover
- [ ] Error toast appears on a failed save
- [ ] Confirmation toast appears on success

## Scope
Frontend settings page only.

## Related Tickets
- none
'

_ALL_CLEAR_GAPS='{"requirement_completeness":{"verdict":"clear","reason":"r"},"contradictory_requirements":{"verdict":"clear","reason":"r"},"deep_scope_ambiguity":{"verdict":"clear","reason":"r"},"edge_case_sufficiency":{"verdict":"clear","reason":"r"}}'

# _f <code> <quote> [<quote_b>] — one scan finding.
_f() {
  local code="$1" quote="$2" quote_b="${3:-}"
  jq -nc --arg c "$code" --arg d "${DOR_SEMANTIC_CODES[$1]}" --arg q "$quote" --arg qb "$quote_b" \
    '{code: $c, dimension: $d, quote: $q, detail: "a specific gap"} + (if $qb != "" then {quote_b: $qb} else {} end)'
}

# _write_body <TID> <body> — writes body.md and the deterministic verdict a
# rescan would record for it (body + section + unit hashes).
_write_body() {
  local tid="$1" body="$2"
  local f="$TMP_ROOT/${tid}.md"
  printf '%s' "$body" >"$f"
  body=$(cat "$f") # the text dor_semantic_apply hashes
  local h s u
  h=$(_dor_body_hash "$body")
  s=$(_dor_section_hashes "$body")
  u=$(_dor_unit_hashes "$body")
  if [ -z "$(get_ticket_manifest_field "$tid" type 2>/dev/null)" ]; then
    write_ticket_manifest "$tid" "INIT-1" "feature" '[]' >/dev/null
  fi
  set_ticket_readiness "$tid" "ready" '[]' '[]' \
    "$(jq -nc --arg h "$h" --argjson s "$s" --argjson u "$u" '{body_hash: $h, section_hashes: $s, unit_hashes: $u}')" >/dev/null
}

# _apply <TID> <findings-json> [<audit-array>] — applies a canned verdict to
# the ticket's current body.md.
_apply() {
  local tid="$1" findings="$2" audit="${3:-[]}"
  local f="$TMP_ROOT/${tid}.md" h
  h=$(_dor_body_hash "$(cat "$f")")
  local scan audit_json
  scan=$(jq -nc --arg t "$tid" --arg h "$h" --argjson f "$findings" --argjson g "$_ALL_CLEAR_GAPS" \
    '{schema_version:1, kind:"scan", ticket:$t, body_hash:$h, findings:$f, gaps:$g, parse_status:"ok", parse_error:""}')
  audit_json=$(jq -nc --arg t "$tid" --arg h "$h" --argjson a "$audit" \
    '{schema_version:1, kind:"audit", ticket:$t, body_hash:$h, audit:$a, missed:[],
      score_plausible:true, score_reason:"ok", parse_status:"ok", parse_error:""}')
  dor_semantic_apply "$tid" "$f" "$scan" "$audit_json"
}

_ready() { get_ticket_manifest_field "$1" ready; }
_round() { _ready "$1" | jq -r '.lineage.round // "none"'; }
# _lab <TID> <code> — lineage label of the (first) finding with <code>.
_lab() { _ready "$1" | jq -r --arg c "$2" '[.semantic.findings[] | select(.code == $c)][0].lineage // "none"'; }
_sev() { _ready "$1" | jq -r --arg c "$2" '[.semantic.findings[] | select(.code == $c)][0].severity // "none"'; }
_dem() { _ready "$1" | jq -r --arg c "$2" '[.semantic.findings[] | select(.code == $c)][0].demoted // "none"'; }

ac_item_edit=${base_body/Confirmation toast appears on success/Confirmation toast appears within 2s of success}
reset_body=${base_body/Save handovers reliably from the settings page./Rewrite: archive handovers instead.}
reset_body=${reset_body/Attorneys report the Save button silently failing on the settings page./New background entirely./}
reset_body=${reset_body/Frontend settings page only./Backend archive service and frontend list./}

# ── 1. Helpers: _dor_unit_of and _dor_semantic_finding_id ─────────────────

units_out=$(_dor_unit_of "$base_body" "toast appears")
n_units=$(printf '%s\n' "$units_out" | grep -c . || true)
first_unit=$(printf '%s\n' "$units_out" | head -n1)
err_key=$(_dor_unit_of "$base_body" "Error toast appears on a failed save" | head -n1)
[ "$n_units" = "2" ] && [[ "$err_key" == "Acceptance Criteria/ac:"* ]] && [ "$first_unit" = "$err_key" ] &&
  _dor_unit_hashes "$base_body" | jq -e --arg k "$err_key" 'has($k)' >/dev/null &&
  _pass "_dor_unit_of: a quote in two AC items yields both units, the first in body order first" ||
  _fail "_dor_unit_of: expected 2 units with the Error-toast item first (got: $units_out / err=$err_key)"

[ "$(_dor_unit_of "$base_body" "- [ ] Save button stores the handover" | head -n1)" = \
  "$(_dor_unit_of "$base_body" "save button stores the handover" | head -n1)" ] &&
  [[ "$(_dor_unit_of "$base_body" "Save button stores the handover" | head -n1)" == "Acceptance Criteria/ac:"* ]] &&
  _pass "_dor_unit_of: list/checkbox markers and case do not change the AC anchor" ||
  _fail "_dor_unit_of: marker/case should not change the anchor"

[ "$(_dor_unit_of "$base_body" "Frontend settings page only")" = "Scope" ] &&
  _pass "_dor_unit_of: a non-AC quote anchors to its section" ||
  _fail "_dor_unit_of: Scope quote should anchor to Scope (got $(_dor_unit_of "$base_body" "Frontend settings page only"))"

[ -z "$(_dor_unit_of "$base_body" "text nowhere in the body")" ] &&
  _pass "_dor_unit_of: an absent quote has no unit" ||
  _fail "_dor_unit_of: an absent quote should print nothing"

id1=$(_dor_semantic_finding_id EDGE_CASE_GAP "Scope" "Frontend settings page only")
id2=$(_dor_semantic_finding_id EDGE_CASE_GAP "Scope" "  frontend   settings page only ")
id3=$(_dor_semantic_finding_id AC_NOT_TESTABLE "Scope" "Frontend settings page only")
[[ "$id1" =~ ^f-[0-9a-f]{12}$ ]] && [ "$id1" = "$id2" ] && [ "$id1" != "$id3" ] &&
  _pass "_dor_semantic_finding_id: f-<12 hex>, stable under normalisation, code-sensitive" ||
  _fail "_dor_semantic_finding_id: got $id1 / $id2 / $id3"

# ── 2. Round table ─────────────────────────────────────────────────────────

_write_body "RND-1" "$base_body"
_apply "RND-1" "[$(_f EDGE_CASE_GAP "Save button stores the handover")]" >/dev/null
[ "$(_round RND-1)" = "1" ] && _pass "round: the first verdict is round 1" ||
  _fail "round: first verdict should be round 1 (got $(_round RND-1))"
_ready RND-1 | jq -e --arg e "$DOR_SEMANTIC_EVALUATOR" '.lineage.evaluator == $e and (.lineage.body_hash | startswith("sha256:"))
    and (.lineage.units | type == "object") and (.lineage.section_hashes | type == "object")' >/dev/null &&
  _pass "lineage: evaluator, body_hash, units and section_hashes recorded" ||
  _fail "lineage: missing keys (got $(_ready RND-1 | jq -c .lineage))"

_apply "RND-1" "[$(_f EDGE_CASE_GAP "Save button stores the handover")]" >/dev/null
[ "$(_round RND-1)" = "1" ] && _pass "round: a re-apply on the same body keeps the round" ||
  _fail "round: same hash should keep the round (got $(_round RND-1))"

_write_body "RND-1" "$ac_item_edit"
_apply "RND-1" "[$(_f EDGE_CASE_GAP "Save button stores the handover")]" >/dev/null
[ "$(_round RND-1)" = "2" ] && [ "$(_ready RND-1 | jq -r '.lineage.reset')" = "false" ] &&
  _pass "round: an edit to one of four non-inert sections is +1" ||
  _fail "round: expected round 2 without reset (got $(_ready RND-1 | jq -c '.lineage | {round, reset}'))"

_write_body "RND-1" "$reset_body"
_apply "RND-1" "[]" >/dev/null
[ "$(_round RND-1)" = "1" ] && [ "$(_ready RND-1 | jq -r '.lineage.reset')" = "true" ] &&
  _pass "round: three of four non-inert sections changed resets to 1" ||
  _fail "round: expected reset to 1 (got $(_ready RND-1 | jq -c '.lineage | {round, reset}'))"

# An evaluator change restarts the count.
_write_body "RND-2" "$base_body"
_apply "RND-2" "[]" >/dev/null
_write_body "RND-2" "$ac_item_edit"
_apply "RND-2" "[]" >/dev/null
set_ticket_lineage "RND-2" "$(_ready RND-2 | jq -c '.lineage + {evaluator: "dor-semantic-v0"}')"
_write_body "RND-2" "$base_body"
_apply "RND-2" "[]" >/dev/null
[ "$(_round RND-2)" = "1" ] && _pass "round: a different lineage evaluator restarts at 1" ||
  _fail "round: evaluator change should restart at 1 (got $(_round RND-2))"

# A rebased verdict (Related Tickets only) is not a new round.
_write_body "RND-3" "$base_body"
_apply "RND-3" "[]" >/dev/null
_write_body "RND-3" "$ac_item_edit"
_apply "RND-3" "[]" >/dev/null
_write_body "RND-3" "${ac_item_edit/- none/- PRO-0}"
_ready RND-3 | jq -e '.missing | index("SEMANTIC_STALE") | not' >/dev/null || _fail "round: Related Tickets edit should rebase"
_apply "RND-3" "[]" >/dev/null
[ "$(_round RND-3)" = "2" ] && _pass "round: an apply after an inert-only rebase keeps the round" ||
  _fail "round: rebase should not count as a round (got $(_round RND-3))"

# ── 3. Lineage labels ──────────────────────────────────────────────────────

_write_body "LIN-1" "$base_body"
_apply "LIN-1" "[$(_f EDGE_CASE_GAP "Save button stores the handover")]" >/dev/null
[ "$(_lab LIN-1 EDGE_CASE_GAP)" = "new" ] && _pass "lineage: round 1 findings are new" ||
  _fail "lineage: round 1 should be new (got $(_lab LIN-1 EDGE_CASE_GAP))"
_ready LIN-1 | jq -e '.semantic.findings[0] | (.id | test("^f-[0-9a-f]{12}$")) and (.unit | startswith("Acceptance Criteria/ac:")) and (.units | length == 1) and .first_round == 1' >/dev/null &&
  _pass "lineage: findings carry id, unit, units and first_round" ||
  _fail "lineage: finding annotation missing (got $(_ready LIN-1 | jq -c '.semantic.findings[0]'))"
first_id=$(_ready LIN-1 | jq -r '.semantic.findings[0].id')

# Round 2 after editing the Confirmation item: the Save finding is carried,
# a new AC_NOT_TESTABLE on the untouched Error item is drift, a new
# MISSING_CORE_AC on the carried Save item is new (open carried finding),
# and a SCOPE_AMBIGUOUS on the edited item is new.
_write_body "LIN-1" "$ac_item_edit"
_apply "LIN-1" "[$(_f EDGE_CASE_GAP "Save button stores the handover"),$(_f AC_NOT_TESTABLE "Error toast appears on a failed save"),$(_f MISSING_CORE_AC "Save button stores the handover"),$(_f SCOPE_AMBIGUOUS "Confirmation toast appears within 2s of success")]" >/dev/null
[ "$(_lab LIN-1 EDGE_CASE_GAP)" = "carried" ] &&
  _ready LIN-1 | jq -e '[.semantic.findings[] | select(.code == "EDGE_CASE_GAP")][0].first_round == 1' >/dev/null &&
  _pass "lineage: a repeated finding is carried with first_round 1" ||
  _fail "lineage: expected carried/first_round 1 (got $(_ready LIN-1 | jq -c '.semantic.findings[0]'))"
[ "$(_lab LIN-1 AC_NOT_TESTABLE)" = "drift" ] &&
  _pass "lineage: a new finding on an unchanged, unflagged AC item is drift" ||
  _fail "lineage: AC_NOT_TESTABLE should be drift (got $(_lab LIN-1 AC_NOT_TESTABLE))"
[ "$(_lab LIN-1 MISSING_CORE_AC)" = "new" ] &&
  _pass "lineage: a new finding in a unit with an open carried finding is new, not drift" ||
  _fail "lineage: MISSING_CORE_AC should be new (got $(_lab LIN-1 MISSING_CORE_AC))"
[ "$(_lab LIN-1 SCOPE_AMBIGUOUS)" = "new" ] &&
  _pass "lineage: a finding on an edited item is new" ||
  _fail "lineage: SCOPE_AMBIGUOUS should be new (got $(_lab LIN-1 SCOPE_AMBIGUOUS))"
[ "$(_sev LIN-1 AC_NOT_TESTABLE)" = "blocking" ] && [ "$(_dem LIN-1 AC_NOT_TESTABLE)" = "none" ] &&
  _pass "drift: not demoted when DOR_SEMANTIC_DRIFT_DEMOTE is unset (library default)" ||
  _fail "drift: should stay blocking by default (got $(_sev LIN-1 AC_NOT_TESTABLE))"
_ready LIN-1 | jq -e '.lineage.counts == {new: 2, carried: 1, drift: 1, resolved: 0, unverified: 0}' >/dev/null &&
  _pass "lineage: counts recorded" ||
  _fail "lineage: counts wrong (got $(_ready LIN-1 | jq -c .lineage.counts))"

# Round 3: the carried finding is gone → resolved.
_write_body "LIN-1" "${ac_item_edit/Frontend settings page only./Frontend settings page only, desktop.}"
_apply "LIN-1" "[$(_f AC_NOT_TESTABLE "Error toast appears on a failed save")]" >/dev/null
_ready LIN-1 | jq -e --arg id "$first_id" '.lineage.resolved | index($id) != null' >/dev/null &&
  _pass "lineage: a prior id absent now is listed in resolved" ||
  _fail "lineage: resolved should hold $first_id (got $(_ready LIN-1 | jq -c .lineage.resolved))"
[ "$(_round LIN-1)" = "3" ] || _fail "lineage: LIN-1 should be at round 3 (got $(_round LIN-1))"

# Quote found in several units: one edited → new; all unchanged → drift.
_write_body "MULTI-1" "$base_body"
_apply "MULTI-1" "[]" >/dev/null
_write_body "MULTI-1" "$ac_item_edit"
_apply "MULTI-1" "[$(_f AC_NOT_TESTABLE "toast appears")]" >/dev/null
[ "$(_lab MULTI-1 AC_NOT_TESTABLE)" = "new" ] &&
  _ready MULTI-1 | jq -e '.semantic.findings[0].units | length == 2' >/dev/null &&
  _pass "lineage: a quote in an unchanged and an edited unit is new" ||
  _fail "lineage: multi-unit quote with an edited unit should be new (got $(_ready MULTI-1 | jq -c '.semantic.findings[0]'))"
_write_body "MULTI-2" "$base_body"
_apply "MULTI-2" "[]" >/dev/null
_write_body "MULTI-2" "${base_body/Frontend settings page only./Frontend settings page only, desktop.}"
_apply "MULTI-2" "[$(_f AC_NOT_TESTABLE "toast appears")]" >/dev/null
[ "$(_lab MULTI-2 AC_NOT_TESTABLE)" = "drift" ] &&
  _pass "lineage: a quote whose every containing unit is unchanged is drift" ||
  _fail "lineage: multi-unit quote, all unchanged, should be drift (got $(_lab MULTI-2 AC_NOT_TESTABLE))"

# Contradiction drift needs both quotes' units unchanged.
_write_body "CON-1" "$base_body"
_apply "CON-1" "[]" >/dev/null
_write_body "CON-1" "${base_body/Attorneys report/Users report}"
_apply "CON-1" "[$(_f CONTRADICTORY_REQUIREMENTS "Save handovers reliably from the settings page" "Frontend settings page only")]" >/dev/null
[ "$(_lab CON-1 CONTRADICTORY_REQUIREMENTS)" = "drift" ] &&
  _pass "lineage: contradiction with both quotes in unchanged units is drift" ||
  _fail "lineage: contradiction should be drift (got $(_lab CON-1 CONTRADICTORY_REQUIREMENTS))"
_write_body "CON-2" "$base_body"
_apply "CON-2" "[]" >/dev/null
_write_body "CON-2" "${base_body/Frontend settings page only./Frontend settings page only, desktop.}"
_apply "CON-2" "[$(_f CONTRADICTORY_REQUIREMENTS "Save handovers reliably from the settings page" "Frontend settings page only")]" >/dev/null
[ "$(_lab CON-2 CONTRADICTORY_REQUIREMENTS)" = "new" ] &&
  _pass "lineage: contradiction whose QUOTE_B unit changed is new" ||
  _fail "lineage: contradiction with an edited QUOTE_B unit should be new (got $(_lab CON-2 CONTRADICTORY_REQUIREMENTS))"

# Unverified findings: new, no anchor, counted.
_write_body "UNV-1" "$base_body"
_apply "UNV-1" "[$(_f EDGE_CASE_GAP "this text is not in the body")]" >/dev/null
_ready UNV-1 | jq -e '.semantic.findings[0] | .verified == false and .lineage == "new" and (.unit == null)' >/dev/null &&
  _ready UNV-1 | jq -e '.lineage.counts.unverified == 1 and (.lineage.findings | length == 0)' >/dev/null &&
  _pass "lineage: an unverified finding is new, unanchored, counted and kept out of lineage.findings" ||
  _fail "lineage: unverified handling wrong (got $(_ready UNV-1 | jq -c '{f: .semantic.findings, l: .lineage.counts}'))"

# ── 4. Drift demotion, round limit, structural codes ──────────────────────

_write_body "DRF-1" "$base_body"
_apply "DRF-1" "[]" >/dev/null
_write_body "DRF-1" "$ac_item_edit"
DOR_SEMANTIC_DRIFT_DEMOTE=true _apply "DRF-1" "[$(_f AC_NOT_TESTABLE "Error toast appears on a failed save")]" >/dev/null
[ "$(_sev DRF-1 AC_NOT_TESTABLE)" = "advisory" ] && [ "$(_dem DRF-1 AC_NOT_TESTABLE)" = "drift" ] &&
  _ready DRF-1 | jq -e '.missing | index("SEMANTIC_VERIFICATION") | not' >/dev/null &&
  _pass "drift: demoted to advisory with demoted:drift when DOR_SEMANTIC_DRIFT_DEMOTE=true" ||
  _fail "drift: should be demoted (got $(_ready DRF-1 | jq -c '{f: .semantic.findings, m: .missing}'))"

# Round limit: MAX=2 → round 2 still blocks, round 3 demotes.
_write_body "LIM-1" "$base_body"
DOR_SEMANTIC_MAX_ROUNDS=2 _apply "LIM-1" "[$(_f EDGE_CASE_GAP "Scope")]" >/dev/null
_write_body "LIM-1" "$ac_item_edit"
DOR_SEMANTIC_MAX_ROUNDS=2 _apply "LIM-1" "[$(_f EDGE_CASE_GAP "Save button stores the handover")]" >/dev/null
[ "$(_round LIM-1)" = "2" ] && [ "$(_sev LIM-1 EDGE_CASE_GAP)" = "blocking" ] &&
  _pass "round limit: round MAX still blocks" ||
  _fail "round limit: round 2 with MAX=2 should block (got round $(_round LIM-1), $(_sev LIM-1 EDGE_CASE_GAP))"
_write_body "LIM-1" "${ac_item_edit/Frontend settings page only./Frontend settings page only, desktop.}"
DOR_SEMANTIC_MAX_ROUNDS=2 _apply "LIM-1" "[$(_f EDGE_CASE_GAP "Save button stores the handover"),$(_f MISSING_CORE_AC "Background"),$(_f NEEDS_HUMAN_DECISION "Save handovers reliably from the settings page"),$(_f CONTRADICTORY_REQUIREMENTS "Frontend settings page only, desktop" "Save handovers reliably from the settings page"),$(_f UNSTATED_DEPENDENCY "Attorneys report the Save button"),$(_f INTENT_AC_MISMATCH "Error toast appears on a failed save")]" >/dev/null
[ "$(_round LIM-1)" = "3" ] && [ "$(_sev LIM-1 EDGE_CASE_GAP)" = "advisory" ] && [ "$(_dem LIM-1 EDGE_CASE_GAP)" = "round-limit" ] &&
  _pass "round limit: round MAX+1 demotes a non-structural finding (round-limit)" ||
  _fail "round limit: EDGE_CASE_GAP should be round-limit at round 3 (got $(_round LIM-1)/$(_sev LIM-1 EDGE_CASE_GAP)/$(_dem LIM-1 EDGE_CASE_GAP))"
[ "$(_dem LIM-1 MISSING_CORE_AC)" = "round-limit" ] &&
  _ready LIM-1 | jq -e '.missing | (index("SEMANTIC_EDGE_CASES") | not)' >/dev/null &&
  _pass "round limit: MISSING_CORE_AC is demoted and SEMANTIC_EDGE_CASES leaves missing" ||
  _fail "round limit: MISSING_CORE_AC should be demoted (got $(_ready LIM-1 | jq -c '{f: [.semantic.findings[] | {code, severity, demoted}], m: .missing}'))"
all_struct_block=1
for c in NEEDS_HUMAN_DECISION CONTRADICTORY_REQUIREMENTS UNSTATED_DEPENDENCY INTENT_AC_MISMATCH; do
  if [ "$(_sev LIM-1 "$c")" != "blocking" ] || [ "$(_dem LIM-1 "$c")" != "none" ]; then
    all_struct_block=0
    echo "  structural $c: $(_sev LIM-1 "$c") / $(_dem LIM-1 "$c")"
  fi
done
[ "$all_struct_block" = "1" ] &&
  _ready LIM-1 | jq -e '.missing | index("SEMANTIC_DEPENDENCIES") != null' >/dev/null &&
  _pass "structural: the 4 structural codes are never demoted by the round limit" ||
  _fail "structural: structural codes should keep blocking (missing $(_ready LIM-1 | jq -c .missing))"

# Limit unset: round 3 still blocks.
_write_body "LIM-2" "$base_body"
_apply "LIM-2" "[]" >/dev/null
_write_body "LIM-2" "$ac_item_edit"
_apply "LIM-2" "[]" >/dev/null
_write_body "LIM-2" "${ac_item_edit/Frontend settings page only./Frontend settings page only, desktop.}"
_apply "LIM-2" "[$(_f EDGE_CASE_GAP "Save button stores the handover")]" >/dev/null
[ "$(_round LIM-2)" = "3" ] && [ "$(_sev LIM-2 EDGE_CASE_GAP)" = "blocking" ] &&
  _pass "round limit: nothing is demoted when DOR_SEMANTIC_MAX_ROUNDS is unset" ||
  _fail "round limit: unset limit should not demote (got $(_sev LIM-2 EDGE_CASE_GAP))"

# Structural drift keeps blocking; drift beats round-limit.
_write_body "DRF-2" "$base_body"
_apply "DRF-2" "[]" >/dev/null
_write_body "DRF-2" "$ac_item_edit"
_apply "DRF-2" "[]" >/dev/null
_write_body "DRF-2" "${ac_item_edit/Attorneys report/Users report}"
DOR_SEMANTIC_MAX_ROUNDS=2 DOR_SEMANTIC_DRIFT_DEMOTE=true _apply "DRF-2" "[$(_f AC_NOT_TESTABLE "Error toast appears on a failed save"),$(_f UNSTATED_DEPENDENCY "Save button stores the handover")]" >/dev/null
[ "$(_dem DRF-2 AC_NOT_TESTABLE)" = "drift" ] &&
  _pass "drift: drift takes precedence over round-limit" ||
  _fail "drift: expected demoted:drift at round 3 (got $(_dem DRF-2 AC_NOT_TESTABLE))"
[ "$(_lab DRF-2 UNSTATED_DEPENDENCY)" = "drift" ] && [ "$(_sev DRF-2 UNSTATED_DEPENDENCY)" = "blocking" ] &&
  _pass "drift: a structural drift finding keeps its label and stays blocking" ||
  _fail "drift: structural drift should block (got $(_lab DRF-2 UNSTATED_DEPENDENCY)/$(_sev DRF-2 UNSTATED_DEPENDENCY))"

# ── 5. Policy override warning and snapshot ────────────────────────────────

_write_body "POL-1" "$base_body"
err=$(_apply "POL-1" "[]" 2>&1 >/dev/null)
echo "$err" | grep -qi 'policy override' &&
  _fail "policy: no warning expected with the default list (got $err)" ||
  _pass "policy: the default structural list does not warn"
_ready POL-1 | jq -e '.lineage.policy.structural == ["NEEDS_HUMAN_DECISION","CONTRADICTORY_REQUIREMENTS","UNSTATED_DEPENDENCY","INTENT_AC_MISMATCH"] and .lineage.policy.overridden == false' >/dev/null &&
  _pass "policy: the default structural list is snapshotted" ||
  _fail "policy: snapshot wrong (got $(_ready POL-1 | jq -c .lineage.policy))"
[ "$DOR_SEMANTIC_STRUCTURAL_CODES_DEFAULT" = "NEEDS_HUMAN_DECISION CONTRADICTORY_REQUIREMENTS UNSTATED_DEPENDENCY INTENT_AC_MISMATCH" ] &&
  _pass "policy: DOR_SEMANTIC_STRUCTURAL_CODES_DEFAULT holds the 4 codes" ||
  _fail "policy: default constant wrong ($DOR_SEMANTIC_STRUCTURAL_CODES_DEFAULT)"

_write_body "POL-2" "$base_body"
err=$(DOR_SEMANTIC_STRUCTURAL_CODES="NEEDS_HUMAN_DECISION" _apply "POL-2" "[]" 2>&1 >/dev/null)
echo "$err" | grep -qi 'policy override' &&
  _pass "policy: an overridden structural list warns on stderr" ||
  _fail "policy: override should warn (got '$err')"
_ready POL-2 | jq -e '.lineage.policy.structural == ["NEEDS_HUMAN_DECISION"] and .lineage.policy.overridden == true' >/dev/null &&
  _pass "policy: the overridden list is snapshotted into lineage.policy" ||
  _fail "policy: override snapshot wrong (got $(_ready POL-2 | jq -c .lineage.policy))"

# A readiness write must not swallow the caller's own stderr afterwards
# (_manifest_readiness_unlock once ran `exec 200>&- 2>/dev/null`, which made
# every later warning in the same shell vanish).
{
  _write_body "POL-3" "$base_body"
  echo "stderr-probe" >&2
} 2>"$TMP_ROOT/probe.err"
grep -q 'stderr-probe' "$TMP_ROOT/probe.err" &&
  _pass "policy: stderr still reaches the caller after a readiness write" ||
  _fail "policy: a readiness write swallowed the caller's stderr"

# ── 6. first_audit ─────────────────────────────────────────────────────────

_write_body "AUD-1" "$base_body"
_apply "AUD-1" "[]" '[{"code":"AC_VAGUE","verdict":"disputed","reason":"first"}]' >/dev/null
_apply "AUD-1" "[]" '[{"code":"AC_VAGUE","verdict":"agree","reason":"second"}]' >/dev/null
_ready AUD-1 | jq -e '.lineage.first_audit.audit[0].reason == "first" and (.lineage.first_audit.body_hash == .lineage.body_hash)' >/dev/null &&
  _pass "first_audit: the first audit for a body hash is kept on a re-apply" ||
  _fail "first_audit: should keep the first audit (got $(_ready AUD-1 | jq -c .lineage.first_audit))"
_write_body "AUD-1" "$ac_item_edit"
_apply "AUD-1" "[]" '[{"code":"AC_VAGUE","verdict":"agree","reason":"third"}]' >/dev/null
_ready AUD-1 | jq -e '.lineage.first_audit.audit[0].reason == "third"' >/dev/null &&
  _pass "first_audit: a new body hash records a new first audit" ||
  _fail "first_audit: should be replaced on a new body (got $(_ready AUD-1 | jq -c .lineage.first_audit))"

# ── 7. v2 → v3 migration ───────────────────────────────────────────────────

[ "$DOR_SEMANTIC_EVALUATOR" = "dor-semantic-v3" ] && _pass "evaluator: DOR_SEMANTIC_EVALUATOR is dor-semantic-v3" ||
  _fail "evaluator: expected dor-semantic-v3 (got $DOR_SEMANTIC_EVALUATOR)"

_needs_pass() {
  local r h
  r=$(_ready "$1")
  h=$(_dor_body_hash "$(cat "$TMP_ROOT/$1.md")")
  if [ "$(echo "$r" | jq -r '.semantic.body_hash')" = "$h" ] &&
    [ "$(echo "$r" | jq -r '.semantic.evaluator')" = "$DOR_SEMANTIC_EVALUATOR" ] &&
    echo "$r" | jq -e '.missing | index("SEMANTIC_STALE") | not' >/dev/null; then
    echo "false"
  else
    echo "true"
  fi
}

_write_body "MIG-1" "$base_body"
mig_h=$(_dor_body_hash "$(cat "$TMP_ROOT/MIG-1.md")")
set_ticket_semantic "MIG-1" "$(jq -nc --arg h "$mig_h" \
  '{evaluator: "dor-semantic-v2", checked_at: "2026-10-01T00:00:00Z", body_hash: $h,
    findings: [{code: "EDGE_CASE_GAP", dimension: "edge_cases", severity: "blocking",
                quote: "Save button stores the handover", detail: "d", verified: true}],
    gaps: {}, audit: [{code: "AC_VAGUE", verdict: "disputed", reason: "r"}], missed: []}')" >/dev/null
rc=0
dor_semantic_migrate_v2 "MIG-1" "$TMP_ROOT/MIG-1.md" >/dev/null 2>&1 || rc=$?
r=$(_ready MIG-1)
[ "$rc" = "0" ] &&
  echo "$r" | jq -e '.semantic.evaluator == "dor-semantic-v3" and .semantic.migrated_from == "dor-semantic-v2"
     and .semantic.findings[0].lineage == "new" and (.semantic.findings[0].id | startswith("f-"))
     and .lineage.round == 1 and .lineage.evaluator == "dor-semantic-v3" and .lineage.migrated_from == "dor-semantic-v2"
     and (.missing | index("SEMANTIC_EDGE_CASES") != null)' >/dev/null &&
  [ "$(_needs_pass MIG-1)" = "false" ] &&
  _pass "migrate: an unchanged v2 verdict becomes v3 in place, round 1, no pass needed" ||
  _fail "migrate: unchanged v2 should migrate (rc=$rc, got $(echo "$r" | jq -c '{s: .semantic, l: .lineage, m: .missing}'))"

_write_body "MIG-2" "$base_body"
set_ticket_semantic "MIG-2" "$(jq -nc --arg h "$mig_h" \
  '{evaluator: "dor-semantic-v2", body_hash: $h, findings: [], gaps: {}, audit: [], missed: []}')" >/dev/null
_write_body "MIG-2" "$ac_item_edit"
rc=0
dor_semantic_migrate_v2 "MIG-2" "$TMP_ROOT/MIG-2.md" >/dev/null 2>&1 || rc=$?
[ "$rc" = "2" ] && [ "$(_ready MIG-2 | jq -r '.semantic.evaluator')" = "dor-semantic-v2" ] &&
  [ "$(_needs_pass MIG-2)" = "true" ] &&
  _pass "migrate: a v2 verdict on a changed body is left alone and still needs a pass" ||
  _fail "migrate: changed body should not migrate (rc=$rc, eval=$(_ready MIG-2 | jq -r '.semantic.evaluator'))"

rc=0
dor_semantic_migrate_v2 "MIG-1" "$TMP_ROOT/MIG-1.md" >/dev/null 2>&1 || rc=$?
[ "$rc" = "2" ] && _pass "migrate: an already-v3 verdict is a no-op (rc 2)" ||
  _fail "migrate: v3 verdict should be a no-op (rc=$rc)"

# ── 8. Scoped-rescan prompt hint ───────────────────────────────────────────

p=$(dor_semantic_prompt scan "HINT-1" "$TMP_ROOT/RND-1.md" "$TMP_ROOT/out.txt" --changed-sections "Acceptance Criteria|Planner Context")
echo "$p" | grep -q 'Changed sections' && echo "$p" | grep -q -- '- Acceptance Criteria' &&
  echo "$p" | grep -q -- '- Planner Context' &&
  _pass "prompt: --changed-sections lists each changed section" ||
  _fail "prompt: changed sections hint missing"
echo "$p" | grep -q 'dor-result.json' &&
  _fail "prompt: the scan must stay blind (dor-result.json referenced)" ||
  _pass "prompt: the hinted scan does not reference dor-result.json"
p0=$(dor_semantic_prompt scan "HINT-1" "$TMP_ROOT/RND-1.md" "$TMP_ROOT/out.txt")
echo "$p0" | grep -q 'Changed sections' &&
  _fail "prompt: no hint expected without --changed-sections" ||
  _pass "prompt: no hint without --changed-sections"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
