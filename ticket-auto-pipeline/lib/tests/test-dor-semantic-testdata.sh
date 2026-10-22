#!/usr/bin/env bash
# test-dor-semantic-testdata.sh — the TEST_DATA_GAP semantic code
# (dor-semantic-test-data-gap). Deterministic: canned scan/audit blocks under
# fixtures/dor/semantic/ stand in for the dor-semantic-agent, so no model runs.
# Usage: bash test-dor-semantic-testdata.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$LIB_DIR/tests/fixtures/dor"
SEMANTIC_DIR="$FIXTURES_DIR/semantic"
PARSER="$LIB_DIR/dor-semantic-parse.sh"

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
unset DOR_SEMANTIC_ADVISORY_CODES DOR_STRICT_TEST_DATA

# _body <fixture-nn> — path of the fixture body.
_body() {
  local nn="$1" f
  for f in "$FIXTURES_DIR/${nn}"-*.md; do
    echo "$f"
    return 0
  done
}

# _render <canned-file> <tid> <hash> <out-file> — substitute the placeholders.
_render() {
  sed -e "s|@TICKET@|$2|" -e "s|@BODY_HASH@|$3|" "$1" >"$4"
}

# _manifest <tid> <type> <body-file> — a fresh manifest with a deterministic
# verdict; prints the body hash.
_manifest() {
  local tid="$1" type="$2" body_file="$3" hash
  hash=$(_dor_body_hash "$(cat "$body_file")")
  write_ticket_manifest "$tid" "INIT-1" "$type" '[]' >/dev/null
  set_ticket_readiness "$tid" "ready" '[]' '[]' "{\"body_hash\": \"${hash}\"}" >/dev/null
  echo "$hash"
}

# _apply <tid> <nn> <type> [scan-file] — parse the canned blocks for fixture
# <nn> (or an explicit scan file) and apply them. Returns apply's rc.
_apply() {
  local tid="$1" nn="$2" type="$3" scan_src="${4:-$SEMANTIC_DIR/$2-scan.txt}"
  local body hash scan_json audit_json
  body=$(_body "$nn")
  hash=$(_manifest "$tid" "$type" "$body")
  _render "$scan_src" "$tid" "$hash" "$TMP_ROOT/$tid-scan.txt"
  _render "$SEMANTIC_DIR/$nn-audit.txt" "$tid" "$hash" "$TMP_ROOT/$tid-audit.txt"
  scan_json=$(bash "$PARSER" --kind scan --result-file "$TMP_ROOT/$tid-scan.txt" 2>/dev/null) || return 10
  audit_json=$(bash "$PARSER" --kind audit --result-file "$TMP_ROOT/$tid-audit.txt" 2>/dev/null) || return 11
  dor_semantic_apply "$tid" "$body" "$scan_json" "$audit_json" >/dev/null 2>&1
}

_ready() { get_ticket_manifest_field "$1" ready; }

# ── (a) parse 26-scan ───────────────────────────────────────────────────────

hash26=$(_dor_body_hash "$(cat "$(_body 26)")")
_render "$SEMANTIC_DIR/26-scan.txt" "TD-A" "$hash26" "$TMP_ROOT/a-scan.txt"
rc=0
out=$(bash "$PARSER" --kind scan --result-file "$TMP_ROOT/a-scan.txt" 2>&1) || rc=$?
if [ "$rc" = "0" ] && [ "$(echo "$out" | jq -r '.findings[0].code')" = "TEST_DATA_GAP" ] &&
  [ "$(echo "$out" | jq -r '.findings[0].dimension')" = "test_uat" ]; then
  _pass "(a) 26-scan parses: TEST_DATA_GAP in dimension test_uat"
else
  _fail "(a) 26-scan should parse with dimension test_uat (rc=$rc out=$out)"
fi

# ── (b) TEST_DATA_GAP without DETAIL is rejected ────────────────────────────

grep -v '^FINDING_1_DETAIL:' "$TMP_ROOT/a-scan.txt" >"$TMP_ROOT/b-scan.txt"
rc=0
out=$(bash "$PARSER" --kind scan --result-file "$TMP_ROOT/b-scan.txt" 2>&1) || rc=$?
if [ "$rc" = "1" ] && echo "$out" | grep -q 'FINDING_1' && echo "$out" | grep -q 'DETAIL'; then
  _pass "(b) TEST_DATA_GAP without DETAIL: exit 1 naming FINDING_1"
else
  _fail "(b) TEST_DATA_GAP without DETAIL should exit 1 naming the finding (rc=$rc out=$out)"
fi

# ── (c) 26 and 27 apply as feature: advisory, never SEMANTIC_TEST_UAT ───────

for nn in 26 27; do
  tid="TD-C$nn"
  rc=0
  _apply "$tid" "$nn" feature || rc=$?
  r=$(_ready "$tid")
  if [ "$rc" = "0" ] &&
    [ "$(echo "$r" | jq -r '.semantic.findings[0].severity')" = "advisory" ] &&
    [ "$(echo "$r" | jq -r '.semantic.findings[0].verified')" = "true" ] &&
    [ "$(echo "$r" | jq -r '(.missing // []) | index("SEMANTIC_TEST_UAT") == null')" = "true" ] &&
    [ "$(echo "$r" | jq -r '.status')" = "ready" ]; then
    _pass "(c) fixture $nn: verified TEST_DATA_GAP is advisory, ticket ready"
  else
    _fail "(c) fixture $nn: expected advisory + ready (rc=$rc ready=$r)"
  fi
done

# ── (d) no env or ticket type makes it blocking ─────────────────────────────

_d_check() {
  local label="$1" tid="$2" r
  r=$(_ready "$tid")
  if [ "$(echo "$r" | jq -r '.semantic.findings[0].severity')" = "advisory" ] &&
    [ "$(echo "$r" | jq -r '(.missing // []) | index("SEMANTIC_TEST_UAT") == null')" = "true" ]; then
    _pass "(d) $label: still advisory"
  else
    _fail "(d) $label: should stay advisory (ready=$r)"
  fi
}
DOR_STRICT_TEST_DATA=true _apply "TD-D1" 27 feature || true
_d_check "DOR_STRICT_TEST_DATA=true" "TD-D1"
DOR_SEMANTIC_ADVISORY_CODES=EDGE_CASE_GAP _apply "TD-D2" 27 feature || true
_d_check "DOR_SEMANTIC_ADVISORY_CODES=EDGE_CASE_GAP" "TD-D2"
_apply "TD-D3" 27 chore || true
_d_check "manifest type chore" "TD-D3"
sev=$(DOR_SEMANTIC_ADVISORY_CODES="" _dor_semantic_severity TEST_DATA_GAP)
[ "$sev" = "advisory" ] && _pass "(d) _dor_semantic_severity TEST_DATA_GAP is advisory with an empty advisory list" ||
  _fail "(d) _dor_semantic_severity TEST_DATA_GAP should be advisory (got $sev)"
sev=$(_dor_semantic_severity EDGE_CASE_GAP)
[ "$sev" = "blocking" ] && _pass "(d) other codes keep their severity (EDGE_CASE_GAP blocking)" ||
  _fail "(d) EDGE_CASE_GAP should stay blocking (got $sev)"

# ── (e) non-verbatim quote → SEMANTIC_UNVERIFIED, never SEMANTIC_TEST_UAT ───

sed 's|creates a draft copy with the same line items|creates a draft copy with the identical line items|' \
  "$SEMANTIC_DIR/27-scan.txt" >"$TMP_ROOT/e-scan.txt"
_apply "TD-E" 27 feature "$TMP_ROOT/e-scan.txt" || true
r=$(_ready "TD-E")
if [ "$(echo "$r" | jq -r '.semantic.findings[0].verified')" = "false" ] &&
  [ "$(echo "$r" | jq -r '(.missing // []) | index("SEMANTIC_UNVERIFIED") != null')" = "true" ] &&
  [ "$(echo "$r" | jq -r '(.missing // []) | index("SEMANTIC_TEST_UAT") == null')" = "true" ]; then
  _pass "(e) non-verbatim quote: verified:false, SEMANTIC_UNVERIFIED, no SEMANTIC_TEST_UAT"
else
  _fail "(e) non-verbatim quote should raise SEMANTIC_UNVERIFIED only (ready=$r)"
fi

# ── (f) a co-present verified MISSING_CORE_AC still blocks ──────────────────

awk '
  /^FINDING_1_DETAIL:/ {
    print
    print "FINDING_2_CODE: MISSING_CORE_AC"
    print "FINDING_2_QUOTE: Archiving a handover from its detail page moves it to the Archived tab"
    print "FINDING_2_DETAIL: no criterion says whether an archived handover can be restored"
    next
  }
  /^GAP_REQUIREMENT_COMPLETENESS:/ { print "GAP_REQUIREMENT_COMPLETENESS: finding"; next }
  { print }
' "$SEMANTIC_DIR/27-scan.txt" >"$TMP_ROOT/f-scan.txt"
_apply "TD-F" 27 feature "$TMP_ROOT/f-scan.txt" || true
r=$(_ready "TD-F")
if [ "$(echo "$r" | jq -r '(.missing // []) | index("SEMANTIC_REQUIREMENT_COMPLETENESS") != null')" = "true" ] &&
  [ "$(echo "$r" | jq -r '(.missing // []) | index("SEMANTIC_TEST_UAT") == null')" = "true" ] &&
  [ "$(echo "$r" | jq -r '.status')" = "not-ready" ]; then
  _pass "(f) co-present MISSING_CORE_AC blocks on SEMANTIC_REQUIREMENT_COMPLETENESS"
else
  _fail "(f) MISSING_CORE_AC should still block (ready=$r)"
fi

# ── (g) 28 applies clean ────────────────────────────────────────────────────

rc=0
_apply "TD-G" 28 feature || rc=$?
r=$(_ready "TD-G")
if [ "$rc" = "0" ] && [ "$(echo "$r" | jq -r '.semantic.findings | length')" = "0" ] &&
  [ "$(echo "$r" | jq -r '.status')" = "ready" ]; then
  _pass "(g) fixture 28 (threshold-only, none): no findings, ready"
else
  _fail "(g) fixture 28 should apply clean (rc=$rc ready=$r)"
fi

# ── (h) prompt: order, UNSTATED_DEPENDENCY narrowed, schema unchanged ───────

prompt=$(dor_semantic_prompt scan "TD-H" "$(_body 27)" "$TMP_ROOT/h-result.txt" 2>/dev/null) || prompt=""
ln_edge=$(echo "$prompt" | grep -n 'EDGE_CASE_GAP —' | head -1 | cut -d: -f1) || ln_edge=""
ln_td=$(echo "$prompt" | grep -n 'TEST_DATA_GAP —' | head -1 | cut -d: -f1) || ln_td=""
ln_dep=$(echo "$prompt" | grep -n 'UNSTATED_DEPENDENCY —' | head -1 | cut -d: -f1) || ln_dep=""
if [ -n "$ln_edge" ] && [ -n "$ln_td" ] && [ -n "$ln_dep" ] &&
  [ "$ln_edge" -lt "$ln_td" ] && [ "$ln_td" -lt "$ln_dep" ]; then
  _pass "(h) prompt lists TEST_DATA_GAP between EDGE_CASE_GAP and UNSTATED_DEPENDENCY"
else
  _fail "(h) TEST_DATA_GAP should sit between EDGE_CASE_GAP and UNSTATED_DEPENDENCY (edge=$ln_edge td=$ln_td dep=$ln_dep)"
fi
dep_text=$(echo "$prompt" | awk '/UNSTATED_DEPENDENCY —/{p=1} p&&/^[0-9]+\. AC_NOT_TESTABLE/{exit} p{print}') || dep_text=""
if [ -n "$dep_text" ] && ! echo "$dep_text" | grep -qi 'prior state'; then
  _pass "(h) UNSTATED_DEPENDENCY no longer mentions prior state"
else
  _fail "(h) UNSTATED_DEPENDENCY should not mention prior state (got: $dep_text)"
fi
prompt_flat=$(echo "$prompt" | tr '\n' ' ' | tr -s ' ')
if echo "$prompt_flat" | grep -qi 'a threshold, a timeout, an attempt count or an HTTP status is not data'; then
  _pass "(h) prompt says thresholds/timeouts/attempt counts/HTTP statuses are not data"
else
  _fail "(h) prompt should carve out thresholds, timeouts, attempt counts and HTTP statuses"
fi
n_gaps=$(echo "$prompt" | grep -oE '^GAP_[A-Z_]+:' | grep -vc '_REASON:') || n_gaps=0
if echo "$prompt" | grep -q '^SCHEMA_VERSION: 1$' && [ "$n_gaps" = "4" ]; then
  _pass "(h) scan template keeps SCHEMA_VERSION: 1 and exactly four GAP_ lines"
else
  _fail "(h) scan template should keep SCHEMA_VERSION: 1 and four gaps"
fi

# ── (i) evaluator string ────────────────────────────────────────────────────

ev=$(_ready "TD-C27" | jq -r '.semantic.evaluator')
[ "$ev" = "dor-semantic-v2" ] && _pass "(i) stored evaluator is dor-semantic-v2" ||
  _fail "(i) stored evaluator should be dor-semantic-v2 (got $ev)"

# ── (j) a waive survives the v1 → v2 re-run ─────────────────────────────────

awk '
  /^FINDING_1_CODE:/ { print "FINDING_1_CODE: EDGE_CASE_GAP"; next }
  /^FINDING_1_QUOTE:/ { print "FINDING_1_QUOTE: Archiving a handover from its detail page moves it to the Archived tab"; next }
  /^FINDING_1_DETAIL:/ { print "FINDING_1_DETAIL: archiving a handover that is still a draft is not addressed"; next }
  /^GAP_EDGE_CASE_SUFFICIENCY:/ { print "GAP_EDGE_CASE_SUFFICIENCY: finding"; next }
  { print }
' "$SEMANTIC_DIR/27-scan.txt" >"$TMP_ROOT/j-scan.txt"
body27=$(_body 27)
hash27=$(_manifest "TD-J" feature "$body27")
_render "$TMP_ROOT/j-scan.txt" "TD-J" "$hash27" "$TMP_ROOT/j-scan-r.txt"
_render "$SEMANTIC_DIR/27-audit.txt" "TD-J" "$hash27" "$TMP_ROOT/j-audit-r.txt"
j_scan=$(bash "$PARSER" --kind scan --result-file "$TMP_ROOT/j-scan-r.txt" 2>/dev/null) || j_scan=""
j_audit=$(bash "$PARSER" --kind audit --result-file "$TMP_ROOT/j-audit-r.txt" 2>/dev/null) || j_audit=""
DOR_SEMANTIC_EVALUATOR="dor-semantic-v1" dor_semantic_apply "TD-J" "$body27" "$j_scan" "$j_audit" >/dev/null 2>&1 || true
j1=$(_ready "TD-J")
waive_ticket_readiness_code "TD-J" "SEMANTIC_EDGE_CASES" "tester" "draft archiving is out of scope" >/dev/null 2>&1 || true
dor_semantic_apply "TD-J" "$body27" "$j_scan" "$j_audit" >/dev/null 2>&1 || true
j2=$(_ready "TD-J")
if [ "$(echo "$j1" | jq -r '.semantic.evaluator')" = "dor-semantic-v1" ] &&
  [ "$(echo "$j1" | jq -r '(.missing // []) | index("SEMANTIC_EDGE_CASES") != null')" = "true" ] &&
  [ "$(echo "$j2" | jq -r '.semantic.evaluator')" = "dor-semantic-v2" ] &&
  [ "$(echo "$j2" | jq -r '.waived | has("SEMANTIC_EDGE_CASES")')" = "true" ] &&
  [ "$(echo "$j2" | jq -r '.status')" = "ready" ]; then
  _pass "(j) waived SEMANTIC_EDGE_CASES survives the v2 re-run, ticket ready"
else
  _fail "(j) waive should survive the v2 re-run (v1=$j1 v2=$j2)"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
