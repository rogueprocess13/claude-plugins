#!/usr/bin/env bash
# test-dor-audit-demotion.sh — audit-dispute demotion, shipped dark
# (planner-refinement-convergence group 3, design D5): dor-semantic.sh
# dor_audit_demote and manifest-write.sh set_ticket_demotions, the
# body-hash-bound keep/drop in set_ticket_readiness, and the BODY_* waive
# refusal in waive_ticket_readiness_code.
# Usage: bash test-dor-audit-demotion.sh
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"

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
unset DOR_AUDIT_DEMOTABLE_CODES DOR_AUDIT_DEMOTE_MAX DOR_SEMANTIC_INERT_SECTIONS \
  DOR_SEMANTIC_MAX_ROUNDS DOR_SEMANTIC_DRIFT_DEMOTE DOR_SEMANTIC_STRUCTURAL_CODES \
  DOR_SEMANTIC_ADVISORY_CODES DOR_STRICT_VPLAN DOR_STRICT_TEST_DATA

FIXTURE="$TEST_DIR/fixtures/dor/29-vplan-row-gap-dispute.md"
AC_QUOTE='- [ ] Criteria 2 and 3 are verified together in Verification Plan row 2'
SUMMARY_QUOTE='Show save feedback on the handover settings page.'
NAV_QUOTE='Settings > Handovers'
VPLAN_QUOTE='| 2 | Failed save toast with Retry | attorney | Settings > Handovers | none | toast names the field; Retry re-submits | ✓ |'
TD_QUOTE='None — no acceptance criterion needs test data.'

_ALL_CLEAR_GAPS='{"requirement_completeness":{"verdict":"clear","reason":"r"},"contradictory_requirements":{"verdict":"clear","reason":"r"},"deep_scope_ambiguity":{"verdict":"clear","reason":"r"},"edge_case_sufficiency":{"verdict":"clear","reason":"r"}}'

# _seed <TID> <missing-json> [<body-file>] — copies the body to the ticket's
# body file and writes a not-ready deterministic verdict bound to its hash.
_seed() {
  local tid="$1" missing="$2" src="${3:-$FIXTURE}"
  local f="$TMP_ROOT/${tid}.md" h
  cp "$src" "$f"
  h=$(_dor_body_hash "$(cat "$f")")
  if [ -z "$(get_ticket_manifest_field "$tid" type 2>/dev/null)" ]; then
    write_ticket_manifest "$tid" "INIT-1" "feature" '[]' >/dev/null
  fi
  set_ticket_readiness "$tid" "not-ready" "$missing" '[]' "$(jq -nc --arg h "$h" '{body_hash: $h}')" >/dev/null
}

# _apply <TID> <audit-array> — applies a clean scan plus <audit-array> to the
# ticket's current body file (the first apply on a hash stores first_audit).
_apply() {
  local tid="$1" audit="$2"
  local f="$TMP_ROOT/${tid}.md" h scan audit_json
  h=$(_dor_body_hash "$(cat "$f")")
  scan=$(jq -nc --arg t "$tid" --arg h "$h" --argjson g "$_ALL_CLEAR_GAPS" \
    '{schema_version:1, kind:"scan", ticket:$t, body_hash:$h, findings:[], gaps:$g, parse_status:"ok", parse_error:""}')
  audit_json=$(jq -nc --arg t "$tid" --arg h "$h" --argjson a "$audit" \
    '{schema_version:1, kind:"audit", ticket:$t, body_hash:$h, audit:$a, missed:[],
      score_plausible:true, score_reason:"ok", parse_status:"ok", parse_error:""}')
  dor_semantic_apply "$tid" "$f" "$scan" "$audit_json"
}

# _a <code> <verdict> [<quote>] — one audit entry.
_a() {
  jq -nc --arg c "$1" --arg v "$2" --arg q "${3:-}" \
    '{code: $c, verdict: $v, reason: "the ticket text shows otherwise"} + (if $q != "" then {quote: $q} else {} end)'
}
_arr() { printf '%s\n' "$@" | jq -sc .; }

_ready() { get_ticket_manifest_field "$1" ready; }
_in_missing() { _ready "$1" | jq -e --arg c "$2" '(.missing // []) | index($c) != null' >/dev/null; }
_demoted() { _ready "$1" | jq -e --arg c "$2" '(.demoted // {}) | has($c)' >/dev/null; }

# _demote <TID> — runs dor_audit_demote, capturing stdout in DOUT and rc in DRC.
_demote() {
  DRC=0
  DOUT=$(dor_audit_demote "$1" "$TMP_ROOT/$1.md" 2>"$TMP_ROOT/$1.err") || DRC=$?
}

# ── 1. A quote in the code's section demotes (real deterministic check) ───

f="$TMP_ROOT/DEM-1.md"
cp "$FIXTURE" "$f"
write_ticket_manifest "DEM-1" "INIT-1" "feature" '[]' >/dev/null
rc=0
DOR_STRICT_VPLAN=true DOR_STRICT_TEST_DATA=true \
  check_ticket_ready "DEM-1" --body "$f" --type feature --no-fetch || rc=$?
[ "$DOR_MISSING" = '["VPLAN_ROW_GAP"]' ] &&
  _pass "fixture 29: the strict check reports only VPLAN_ROW_GAP" ||
  _fail "fixture 29: expected [\"VPLAN_ROW_GAP\"], got $DOR_MISSING"
set_ticket_readiness "DEM-1" "$DOR_STATUS" "$DOR_MISSING" "$DOR_ADVISORY" "$(_dor_readiness_extras planner-strict)" >/dev/null
h1=$(_dor_body_hash "$(cat "$f")")
_apply "DEM-1" "$(_arr "$(_a VPLAN_ROW_GAP disputed "$AC_QUOTE")")"

# Shipped dark: the apply alone never demotes, whatever the audit says.
_in_missing "DEM-1" VPLAN_ROW_GAP && ! _demoted "DEM-1" VPLAN_ROW_GAP &&
  _pass "dark: dor_semantic_apply alone leaves a disputed code blocking" ||
  _fail "dark: the apply must not demote (ready=$(_ready DEM-1 | jq -c '{missing, demoted}'))"
_ready "DEM-1" | jq -e '.lineage.first_audit.audit[0].quote == "- [ ] Criteria 2 and 3 are verified together in Verification Plan row 2"' >/dev/null &&
  _pass "first_audit stores the dispute's quote" ||
  _fail "first_audit quote missing (got $(_ready DEM-1 | jq -c .lineage.first_audit))"

_demote "DEM-1"
[ "$DRC" = "0" ] && ! _in_missing "DEM-1" VPLAN_ROW_GAP &&
  _ready "DEM-1" | jq -e --arg h "$h1" --arg q "$AC_QUOTE" '
    .demoted.VPLAN_ROW_GAP.by == "dor-semantic-audit"
    and .demoted.VPLAN_ROW_GAP.quote == $q
    and .demoted.VPLAN_ROW_GAP.body_hash == $h
    and .demoted.VPLAN_ROW_GAP.evaluator == "dor-semantic-v3"
    and (.demoted.VPLAN_ROW_GAP.reason | length > 0)
    and ((.advisory // []) | index("VPLAN_ROW_GAP") != null)
    and .status == "ready"' >/dev/null &&
  _pass "a quote in the AC section demotes VPLAN_ROW_GAP to advisory (status ready)" ||
  _fail "demotion expected (rc=$DRC ready=$(_ready DEM-1 | jq -c '{status, missing, advisory, demoted}'))"
[ "$DOUT" = "VPLAN_ROW_GAP" ] &&
  _pass "dor_audit_demote prints each demoted code" ||
  _fail "stdout expected VPLAN_ROW_GAP, got '$DOUT'"

# A Verification Plan row is also in VPLAN_ROW_GAP's sections.
_seed "DEM-1b" '["VPLAN_ROW_GAP"]'
_apply "DEM-1b" "$(_arr "$(_a VPLAN_ROW_GAP disputed "$VPLAN_QUOTE")")"
_demote "DEM-1b"
[ "$DRC" = "0" ] && _demoted "DEM-1b" VPLAN_ROW_GAP &&
  _pass "a quote in the Verification Plan demotes VPLAN_ROW_GAP" ||
  _fail "Verification Plan quote should qualify (rc=$DRC $(cat "$TMP_ROOT/DEM-1b.err"))"

# ── 2. A quote outside the code's sections does not qualify ───────────────

_seed "DEM-2" '["VPLAN_ROW_GAP"]'
_apply "DEM-2" "$(_arr "$(_a VPLAN_ROW_GAP disputed "$SUMMARY_QUOTE")")"
_demote "DEM-2"
[ "$DRC" = "0" ] && _in_missing "DEM-2" VPLAN_ROW_GAP && ! _demoted "DEM-2" VPLAN_ROW_GAP && [ -z "$DOUT" ] &&
  _pass "a quote found only in the Summary does not demote" ||
  _fail "Summary quote must not qualify (rc=$DRC out=$DOUT)"

# AC_VAGUE reads only the AC section: the Verification Plan does not count.
_seed "DEM-2b" '["AC_VAGUE"]'
_apply "DEM-2b" "$(_arr "$(_a AC_VAGUE disputed "$VPLAN_QUOTE")")"
_demote "DEM-2b"
_in_missing "DEM-2b" AC_VAGUE && ! _demoted "DEM-2b" AC_VAGUE &&
  _pass "AC_VAGUE: a Verification Plan quote does not qualify" ||
  _fail "AC_VAGUE must be bound to the AC section"

# ── 3. A missing or unverifiable quote does not qualify ───────────────────

_seed "DEM-3" '["VPLAN_ROW_GAP"]'
_apply "DEM-3" "$(_arr "$(_a VPLAN_ROW_GAP disputed)")"
_demote "DEM-3"
[ "$DRC" = "0" ] && _in_missing "DEM-3" VPLAN_ROW_GAP && ! _demoted "DEM-3" VPLAN_ROW_GAP &&
  _pass "a dispute with no quote does not demote" ||
  _fail "no-quote dispute must not demote (rc=$DRC)"

_seed "DEM-3b" '["VPLAN_ROW_GAP"]'
_apply "DEM-3b" "$(_arr "$(_a VPLAN_ROW_GAP disputed "- [ ] Every row covers exactly one criterion")")"
_demote "DEM-3b"
_in_missing "DEM-3b" VPLAN_ROW_GAP && ! _demoted "DEM-3b" VPLAN_ROW_GAP &&
  _pass "a quote not in the body does not demote" ||
  _fail "a fabricated quote must not demote"

_seed "DEM-3c" '["VPLAN_ROW_GAP"]'
_apply "DEM-3c" "$(_arr "$(_a VPLAN_ROW_GAP agree "$AC_QUOTE")")"
_demote "DEM-3c"
_in_missing "DEM-3c" VPLAN_ROW_GAP && ! _demoted "DEM-3c" VPLAN_ROW_GAP &&
  _pass "an agree verdict never demotes, even with a quote" ||
  _fail "only disputed entries qualify"

# A code not in ready.missing (advisory under the host profile) is skipped.
_seed "DEM-3d" '[]'
_apply "DEM-3d" "$(_arr "$(_a VPLAN_ROW_GAP disputed "$AC_QUOTE")")"
_demote "DEM-3d"
[ "$DRC" = "0" ] && ! _demoted "DEM-3d" VPLAN_ROW_GAP &&
  _pass "a code absent from ready.missing is not demoted" ||
  _fail "only blocking codes are demoted (rc=$DRC)"

# A code outside the allow-list is skipped.
_seed "DEM-3e" '["SCOPE_MISSING"]'
_apply "DEM-3e" "$(_arr "$(_a SCOPE_MISSING disputed "$AC_QUOTE")")"
_demote "DEM-3e"
_in_missing "DEM-3e" SCOPE_MISSING && ! _demoted "DEM-3e" SCOPE_MISSING &&
  _pass "a code outside DOR_AUDIT_DEMOTABLE_CODES is not demoted" ||
  _fail "SCOPE_MISSING must not be demoted"

# ── 4. Never-demote codes win over the allow-list ─────────────────────────

for c in AC_MISSING INTENT_MISSING SCOPE_MISSING REPRO_MISSING REPRO_NO_EXPECTED_ACTUAL VPLAN_MISSING \
  TEST_DATA_MISSING TEST_DATA_UNSOURCED TEST_DATA_UNSEEDED TEST_USER_MISSING TEST_USER_UNRESOLVED \
  CATALOG_ABSENT VERIFICATION_REQUIRED_NOT_SELF_VERIFYING FLAG_NEEDS_INFO BODY_UNAVAILABLE \
  BODY_DRIFT BODY_UNVERIFIED; do
  _dor_semantic_in_list "$c" "$DOR_AUDIT_NEVER_DEMOTE" || {
    _fail "DOR_AUDIT_NEVER_DEMOTE lacks $c"
    continue
  }
done
_dor_audit_never_demote SEMANTIC_STALE && _dor_audit_never_demote SEMANTIC_EDGE_CASES &&
  _dor_audit_never_demote BODY_DRIFT && ! _dor_audit_never_demote VPLAN_ROW_GAP &&
  _pass "never-demote: the fixed list plus every SEMANTIC_* code" ||
  _fail "never-demote predicate wrong"

_seed "DEM-4" '["TEST_DATA_UNSOURCED","VPLAN_ROW_GAP"]'
err=$(DOR_AUDIT_DEMOTABLE_CODES="TEST_DATA_UNSOURCED VPLAN_ROW_GAP" \
  _apply "DEM-4" "$(_arr "$(_a TEST_DATA_UNSOURCED disputed "$TD_QUOTE")" "$(_a VPLAN_ROW_GAP disputed "$AC_QUOTE")")" 2>&1 >/dev/null)
echo "$err" | grep -q 'DOR_AUDIT_DEMOTABLE_CODES' &&
  _pass "policy: an overridden demotable list warns on stderr" ||
  _fail "policy: override should warn (got '$err')"
_ready "DEM-4" | jq -e '.lineage.policy.audit_demotable == ["TEST_DATA_UNSOURCED","VPLAN_ROW_GAP"]
  and .lineage.policy.audit_demotable_overridden == true' >/dev/null &&
  _pass "policy: the overridden demotable list is snapshotted" ||
  _fail "policy: snapshot wrong (got $(_ready DEM-4 | jq -c .lineage.policy))"
DRC=0
DOUT=$(DOR_AUDIT_DEMOTABLE_CODES="TEST_DATA_UNSOURCED VPLAN_ROW_GAP" dor_audit_demote "DEM-4" "$TMP_ROOT/DEM-4.md" 2>/dev/null) || DRC=$?
[ "$DRC" = "0" ] && _in_missing "DEM-4" TEST_DATA_UNSOURCED && ! _demoted "DEM-4" TEST_DATA_UNSOURCED &&
  _demoted "DEM-4" VPLAN_ROW_GAP &&
  _pass "a never-demote code in the allow-list is ignored; the other dispute still demotes" ||
  _fail "TEST_DATA_UNSOURCED must stay blocking (rc=$DRC ready=$(_ready DEM-4 | jq -c '{missing, demoted}'))"

err=$(_apply "DEM-1b" "$(_arr "$(_a VPLAN_ROW_GAP disputed "$VPLAN_QUOTE")")" 2>&1 >/dev/null)
echo "$err" | grep -qi 'policy override' &&
  _fail "policy: the default demotable list must not warn (got $err)" ||
  _pass "policy: the default demotable list does not warn"
_ready "DEM-1b" | jq -e '.lineage.policy.audit_demotable == ["VPLAN_ROW_GAP","VPLAN_UNVERIFIABLE","AC_VAGUE","AC_IMPLEMENTATION_ONLY","NAV_PATH_MISSING"]
  and .lineage.policy.audit_demotable_overridden == false' >/dev/null &&
  _pass "policy: the default demotable list is snapshotted" ||
  _fail "policy: default snapshot wrong (got $(_ready DEM-1b | jq -c .lineage.policy))"

# ── 5. A waived code is skipped ───────────────────────────────────────────

_seed "DEM-5" '["VPLAN_ROW_GAP"]'
waive_ticket_readiness_code "DEM-5" VPLAN_ROW_GAP "operator" "reviewed"
_apply "DEM-5" "$(_arr "$(_a VPLAN_ROW_GAP disputed "$AC_QUOTE")")"
_demote "DEM-5"
[ "$DRC" = "0" ] && ! _demoted "DEM-5" VPLAN_ROW_GAP && [ -z "$DOUT" ] &&
  _ready "DEM-5" | jq -e '.waived | has("VPLAN_ROW_GAP")' >/dev/null &&
  _pass "a waived code is skipped (the waiver stays)" ||
  _fail "waived code must not be demoted (rc=$DRC out=$DOUT)"

# ── 6. The cap ────────────────────────────────────────────────────────────

three=$(_arr "$(_a VPLAN_ROW_GAP disputed "$AC_QUOTE")" "$(_a AC_VAGUE disputed "$AC_QUOTE")" \
  "$(_a NAV_PATH_MISSING disputed "$NAV_QUOTE")")
_seed "DEM-6" '["AC_VAGUE","NAV_PATH_MISSING","VPLAN_ROW_GAP"]'
_apply "DEM-6" "$three"
_demote "DEM-6"
[ "$DRC" = "4" ] && [ -z "$DOUT" ] &&
  _ready "DEM-6" | jq -e '(.missing == ["AC_VAGUE","NAV_PATH_MISSING","VPLAN_ROW_GAP"]) and ((.demoted // {}) == {})' >/dev/null &&
  _pass "three qualifying disputes over a cap of 2 demote nothing and return 4" ||
  _fail "cap: expected rc 4 and nothing demoted (rc=$DRC ready=$(_ready DEM-6 | jq -c '{missing, demoted}'))"
grep -q 'DOR_AUDIT_DEMOTE_MAX' "$TMP_ROOT/DEM-6.err" &&
  _pass "cap: the refusal names DOR_AUDIT_DEMOTE_MAX on stderr" ||
  _fail "cap: stderr should explain the refusal (got $(cat "$TMP_ROOT/DEM-6.err"))"

_seed "DEM-6b" '["AC_VAGUE","VPLAN_ROW_GAP"]'
_apply "DEM-6b" "$(_arr "$(_a VPLAN_ROW_GAP disputed "$AC_QUOTE")" "$(_a AC_VAGUE disputed "$AC_QUOTE")")"
_demote "DEM-6b"
[ "$DRC" = "0" ] && _demoted "DEM-6b" VPLAN_ROW_GAP && _demoted "DEM-6b" AC_VAGUE &&
  [ "$(printf '%s\n' "$DOUT" | sort | tr '\n' ' ')" = "AC_VAGUE VPLAN_ROW_GAP " ] &&
  _pass "two qualifying disputes (the cap) are both demoted" ||
  _fail "cap: two should demote (rc=$DRC out=$DOUT)"

_seed "DEM-6c" '["AC_VAGUE","NAV_PATH_MISSING","VPLAN_ROW_GAP"]'
_apply "DEM-6c" "$three"
DRC=0
DOR_AUDIT_DEMOTE_MAX=3 dor_audit_demote "DEM-6c" "$TMP_ROOT/DEM-6c.md" >/dev/null 2>&1 || DRC=$?
[ "$DRC" = "0" ] && _demoted "DEM-6c" NAV_PATH_MISSING &&
  _ready "DEM-6c" | jq -e '.missing == [] and .status == "ready"' >/dev/null &&
  _pass "DOR_AUDIT_DEMOTE_MAX=3 lifts the cap; a Navigation Path quote demotes NAV_PATH_MISSING" ||
  _fail "cap override failed (rc=$DRC)"

# ── 7. A re-rolled audit on the same hash is ignored ──────────────────────

_seed "DEM-7" '["AC_VAGUE"]'
_apply "DEM-7" "$(_arr "$(_a AC_VAGUE agree)")"
_apply "DEM-7" "$(_arr "$(_a AC_VAGUE disputed "$AC_QUOTE")")"
_ready "DEM-7" | jq -e '.semantic.audit[0].verdict == "disputed" and .lineage.first_audit.audit[0].verdict == "agree"' >/dev/null &&
  _pass "re-roll: the second audit is stored on the verdict, the first stays first_audit" ||
  _fail "re-roll setup wrong (got $(_ready DEM-7 | jq -c '{a: .semantic.audit, f: .lineage.first_audit}'))"
_demote "DEM-7"
[ "$DRC" = "0" ] && _in_missing "DEM-7" AC_VAGUE && ! _demoted "DEM-7" AC_VAGUE &&
  _pass "re-roll: a later dispute on the same hash is ignored" ||
  _fail "re-roll: AC_VAGUE must not be demoted (rc=$DRC)"

# No first_audit for this body hash (body edited after the audit): nothing.
_seed "DEM-7b" '["VPLAN_ROW_GAP"]'
_apply "DEM-7b" "$(_arr "$(_a VPLAN_ROW_GAP disputed "$AC_QUOTE")")"
printf '\n## Related Tickets\n- none\n' >>"$TMP_ROOT/DEM-7b.md"
h7=$(_dor_body_hash "$(cat "$TMP_ROOT/DEM-7b.md")")
set_ticket_readiness "DEM-7b" "not-ready" '["VPLAN_ROW_GAP"]' '[]' "$(jq -nc --arg h "$h7" '{body_hash: $h}')" >/dev/null
_demote "DEM-7b"
[ "$DRC" = "0" ] && ! _demoted "DEM-7b" VPLAN_ROW_GAP &&
  _pass "an audit for an earlier body hash is never used" ||
  _fail "stale first_audit must not demote (rc=$DRC)"

# ── 8. The same hash keeps the demotion; an edit drops it ─────────────────

set_ticket_readiness "DEM-1" "not-ready" '["VPLAN_ROW_GAP"]' '[]' "$(jq -nc --arg h "$h1" '{body_hash: $h}')" >/dev/null
! _in_missing "DEM-1" VPLAN_ROW_GAP && _demoted "DEM-1" VPLAN_ROW_GAP &&
  _ready "DEM-1" | jq -e '((.advisory // []) | index("VPLAN_ROW_GAP") != null) and .status == "ready"' >/dev/null &&
  _pass "a recheck on the same hash re-applies the kept demotion" ||
  _fail "same hash should keep the demotion (ready=$(_ready DEM-1 | jq -c '{status, missing, advisory, demoted}'))"

set_ticket_readiness "DEM-1" "not-ready" '["VPLAN_ROW_GAP"]' '[]' >/dev/null
_in_missing "DEM-1" VPLAN_ROW_GAP && ! _demoted "DEM-1" VPLAN_ROW_GAP &&
  _pass "a verdict with no body hash drops the demotion" ||
  _fail "no-hash rewrite must drop the demotion"

# Re-demote, then edit the body.
set_ticket_readiness "DEM-1" "not-ready" '["VPLAN_ROW_GAP"]' '[]' "$(jq -nc --arg h "$h1" '{body_hash: $h}')" >/dev/null
_demote "DEM-1"
_demoted "DEM-1" VPLAN_ROW_GAP || _fail "re-demote setup failed (rc=$DRC)"
printf '\nOne more line of background.\n' >>"$TMP_ROOT/DEM-1.md"
h1b=$(_dor_body_hash "$(cat "$TMP_ROOT/DEM-1.md")")
set_ticket_readiness "DEM-1" "not-ready" '["VPLAN_ROW_GAP"]' '[]' "$(jq -nc --arg h "$h1b" '{body_hash: $h}')" >/dev/null
_in_missing "DEM-1" VPLAN_ROW_GAP && ! _demoted "DEM-1" VPLAN_ROW_GAP &&
  _ready "DEM-1" | jq -e '.status == "not-ready" and ((.advisory // []) | index("VPLAN_ROW_GAP") == null)' >/dev/null &&
  _pass "an edited body drops the demotion and the code blocks again" ||
  _fail "edit should drop the demotion (ready=$(_ready DEM-1 | jq -c '{status, missing, advisory, demoted}'))"

# ── 9. set_ticket_demotions guards ────────────────────────────────────────

_seed "DEM-9" '["VPLAN_ROW_GAP"]'
h9=$(_dor_body_hash "$(cat "$TMP_ROOT/DEM-9.md")")
rc=0
set_ticket_demotions "DEM-9" '{"VPLAN_ROW_GAP":{"by":"x","reason":"r","quote":"q","body_hash":"sha256:other","evaluator":"e"}}' 2>/dev/null || rc=$?
[ "$rc" = "3" ] && _in_missing "DEM-9" VPLAN_ROW_GAP &&
  _pass "set_ticket_demotions: a body_hash other than ready.body_hash is refused (exit 3)" ||
  _fail "set_ticket_demotions: hash mismatch should exit 3 (rc=$rc)"
rc=0
set_ticket_demotions "DEM-9" "$(jq -nc --arg h "$h9" '{BODY_DRIFT: {by: "x", reason: "r", quote: "q", body_hash: $h, evaluator: "e"}}')" 2>/dev/null || rc=$?
[ "$rc" = "3" ] && _pass "set_ticket_demotions: a BODY_* code is refused" ||
  _fail "set_ticket_demotions: BODY_DRIFT should exit 3 (rc=$rc)"
rc=0
set_ticket_demotions "DEM-9" '["VPLAN_ROW_GAP"]' 2>/dev/null || rc=$?
[ "$rc" = "3" ] && _pass "set_ticket_demotions: a non-object is refused" ||
  _fail "set_ticket_demotions: array should exit 3 (rc=$rc)"
rc=0
set_ticket_demotions "DEM-9" "$(jq -nc --arg h "$h9" '{VPLAN_ROW_GAP: {by: "x", reason: "r", quote: "q", body_hash: $h, evaluator: "e"}}')" || rc=$?
[ "$rc" = "0" ] && ! _in_missing "DEM-9" VPLAN_ROW_GAP && _demoted "DEM-9" VPLAN_ROW_GAP &&
  _pass "set_ticket_demotions: moves the code from missing to advisory" ||
  _fail "set_ticket_demotions: write failed (rc=$rc)"

# ── 10. BODY_DRIFT and BODY_UNVERIFIED cannot be waived ───────────────────

_seed "DEM-10" '["BODY_DRIFT","BODY_UNVERIFIED"]'
for c in BODY_DRIFT BODY_UNVERIFIED; do
  rc=0
  waive_ticket_readiness_code "DEM-10" "$c" "operator" "please" 2>/dev/null || rc=$?
  [ "$rc" = "3" ] && ! _ready "DEM-10" | jq -e --arg c "$c" '.waived | has($c)' >/dev/null &&
    _pass "--waive of $c fails (exit 3, no waiver)" ||
    _fail "--waive of $c should fail (rc=$rc)"
done
_ready "DEM-10" | jq -e '.status == "not-ready"' >/dev/null &&
  _pass "the refused waivers leave the ticket not-ready" ||
  _fail "the refused waivers changed the status"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
