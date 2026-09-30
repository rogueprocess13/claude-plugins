#!/usr/bin/env bash
# test-dor-semantic-parse.sh — unit tests for lib/dor-semantic-parse.sh
# Usage: bash test-dor-semantic-parse.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PARSER="$LIB_DIR/dor-semantic-parse.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc)"
    ((FAIL++)) || true
  fi
}

_ws=""
_setup() {
  _ws=$(mktemp -d)
}
_teardown() {
  [ -n "$_ws" ] && rm -rf "$_ws"
  _ws=""
}

_OUT=""
_RC=0
_parse() {
  local kind="$1" file="$2" det="${3:-}"
  set +e
  if [ -n "$det" ]; then
    _OUT=$(bash "$PARSER" --kind "$kind" --result-file "$file" --det-result "$det" 2>&1)
  else
    _OUT=$(bash "$PARSER" --kind "$kind" --result-file "$file" 2>&1)
  fi
  _RC=$?
  set -e
}

_canonical_scan() {
  cat >"$_ws/scan.txt" <<'EOF'
=== DOR_SEMANTIC_SCAN ===
SCHEMA_VERSION: 1
TICKET: WIL-123
BODY_HASH: sha256:abc123
FINDING_1_CODE: MISSING_CORE_AC
FINDING_1_QUOTE: the export should work correctly
FINDING_1_DETAIL: no AC states what correctly means
GAP_REQUIREMENT_COMPLETENESS: finding
GAP_REQUIREMENT_COMPLETENESS_REASON: see FINDING_1
GAP_CONTRADICTORY_REQUIREMENTS: clear
GAP_CONTRADICTORY_REQUIREMENTS_REASON: only one AC exists
GAP_DEEP_SCOPE_AMBIGUITY: clear
GAP_DEEP_SCOPE_AMBIGUITY_REASON: scope table names exactly two screens
GAP_EDGE_CASE_SUFFICIENCY: not-applicable
GAP_EDGE_CASE_SUFFICIENCY_REASON: no branching behaviour
=== END DOR_SEMANTIC_SCAN ===
EOF
}

_canonical_audit() {
  cat >"$_ws/audit.txt" <<'EOF'
=== DOR_SEMANTIC_AUDIT ===
SCHEMA_VERSION: 1
TICKET: WIL-123
BODY_HASH: sha256:abc123
AUDIT_1_CODE: AC_VAGUE
AUDIT_1_VERDICT: agree
AUDIT_1_REASON: matches the vague-term pattern
SCORE_PLAUSIBLE: yes
SCORE_REASON: matches a ticket with AC present but no vplan
=== END DOR_SEMANTIC_AUDIT ===
EOF
}

# ── 3.1: transport / extraction ─────────────────────────────────────────────

test_canonical_scan_valid() {
  _setup
  _canonical_scan
  _parse scan "$_ws/scan.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"ok"' || ok=0
  echo "$_OUT" | grep -q '"code":"MISSING_CORE_AC"' || ok=0
  echo "$_OUT" | grep -q '"requirement_completeness":{"verdict":"finding"' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_canonical_audit_valid() {
  _setup
  _canonical_audit
  _parse audit "$_ws/audit.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"ok"' || ok=0
  echo "$_OUT" | grep -q '"code":"AC_VAGUE","verdict":"agree"' || ok=0
  echo "$_OUT" | grep -q '"score_plausible":true' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_block_after_prose() {
  _setup
  {
    echo "Some reasoning prose about the ticket first."
    echo ""
    _canonical_scan >/dev/null
    cat "$_ws/scan.txt"
  } >"$_ws/prosed.txt"
  _parse scan "$_ws/prosed.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"ok"' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_reordered_fields_accepted() {
  _setup
  cat >"$_ws/scan.txt" <<'EOF'
=== DOR_SEMANTIC_SCAN ===
TICKET: WIL-123
GAP_EDGE_CASE_SUFFICIENCY: clear
GAP_EDGE_CASE_SUFFICIENCY_REASON: covered
GAP_DEEP_SCOPE_AMBIGUITY: clear
GAP_DEEP_SCOPE_AMBIGUITY_REASON: covered
GAP_CONTRADICTORY_REQUIREMENTS: clear
GAP_CONTRADICTORY_REQUIREMENTS_REASON: covered
GAP_REQUIREMENT_COMPLETENESS: clear
GAP_REQUIREMENT_COMPLETENESS_REASON: covered
BODY_HASH: sha256:abc123
SCHEMA_VERSION: 1
=== END DOR_SEMANTIC_SCAN ===
EOF
  _parse scan "$_ws/scan.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '"findings":\[\]' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_crlf_accepted() {
  _setup
  _canonical_scan
  sed 's/$/\r/' "$_ws/scan.txt" >"$_ws/scan-crlf.txt"
  _parse scan "$_ws/scan-crlf.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"ok"' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_indented_markers_accepted() {
  _setup
  _canonical_scan
  sed '1s/^/  /; $s/^/  /' "$_ws/scan.txt" >"$_ws/scan-indent.txt"
  _parse scan "$_ws/scan-indent.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_last_block_wins() {
  _setup
  {
    echo "=== DOR_SEMANTIC_SCAN ==="
    echo "SCHEMA_VERSION: 1"
    echo "TICKET: WIL-000-FIRST"
    echo "BODY_HASH: sha256:first"
    echo "GAP_REQUIREMENT_COMPLETENESS: clear"
    echo "GAP_REQUIREMENT_COMPLETENESS_REASON: r"
    echo "GAP_CONTRADICTORY_REQUIREMENTS: clear"
    echo "GAP_CONTRADICTORY_REQUIREMENTS_REASON: r"
    echo "GAP_DEEP_SCOPE_AMBIGUITY: clear"
    echo "GAP_DEEP_SCOPE_AMBIGUITY_REASON: r"
    echo "GAP_EDGE_CASE_SUFFICIENCY: clear"
    echo "GAP_EDGE_CASE_SUFFICIENCY_REASON: r"
    echo "=== END DOR_SEMANTIC_SCAN ==="
    echo ""
    cat "$_ws"/../nonexistent 2>/dev/null || true
  } >"$_ws/two.txt"
  _canonical_scan
  cat "$_ws/scan.txt" >>"$_ws/two.txt"
  _parse scan "$_ws/two.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '"ticket":"WIL-123"' || ok=0
  echo "$_OUT" | grep -qv 'WIL-000-FIRST' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_truncated_last_block_uses_prior_complete() {
  _setup
  _canonical_scan
  {
    cat "$_ws/scan.txt"
    echo ""
    echo "=== DOR_SEMANTIC_SCAN ==="
    echo "SCHEMA_VERSION: 1"
    echo "TICKET: WIL-999-TRUNCATED"
  } >"$_ws/trunc.txt"
  _parse scan "$_ws/trunc.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '"ticket":"WIL-123"' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_lowercase_key_rejected() {
  _setup
  _canonical_scan
  sed 's/^TICKET:/ticket:/' "$_ws/scan.txt" >"$_ws/scan-lc.txt"
  _parse scan "$_ws/scan-lc.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"invalid"' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_dashed_key_rejected() {
  _setup
  _canonical_scan
  sed 's/^TICKET:/TICK-ET:/' "$_ws/scan.txt" >"$_ws/scan-dash.txt"
  _parse scan "$_ws/scan-dash.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_duplicate_key_rejected() {
  _setup
  _canonical_scan
  echo "TICKET: WIL-DUP" >>"$_ws/scan.txt.tmp"
  sed '/^=== END/i TICKET: WIL-DUP' "$_ws/scan.txt" >"$_ws/scan-dup.txt"
  _parse scan "$_ws/scan-dup.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q 'duplicate' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_json_envelope_accepted() {
  _setup
  _canonical_scan
  local body
  body=$(cat "$_ws/scan.txt")
  jq -n --arg result "$body" '{result: $result, type: "result"}' >"$_ws/scan-json.txt"
  _parse scan "$_ws/scan-json.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"ok"' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_stream_json_envelope_accepted() {
  _setup
  _canonical_scan
  local body
  body=$(cat "$_ws/scan.txt")
  {
    jq -nc '{type: "system", subtype: "init"}'
    jq -nc --arg result "$body" '{type: "result", result: $result}'
  } >"$_ws/scan-stream.txt"
  _parse scan "$_ws/scan-stream.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_unknown_code_rejected() {
  _setup
  _canonical_scan
  sed 's/FINDING_1_CODE: MISSING_CORE_AC/FINDING_1_CODE: LOOKS_WEIRD/' "$_ws/scan.txt" >"$_ws/scan-unk.txt"
  _parse scan "$_ws/scan-unk.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q 'not a known code' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_gap_enum_violation_rejected() {
  _setup
  _canonical_scan
  sed 's/GAP_EDGE_CASE_SUFFICIENCY: not-applicable/GAP_EDGE_CASE_SUFFICIENCY: nonsense/' "$_ws/scan.txt" >"$_ws/scan-badgap.txt"
  _parse scan "$_ws/scan-badgap.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_wrong_schema_version_rejected() {
  _setup
  _canonical_scan
  sed 's/SCHEMA_VERSION: 1/SCHEMA_VERSION: 2/' "$_ws/scan.txt" >"$_ws/scan-v2.txt"
  _parse scan "$_ws/scan-v2.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q 'SCHEMA_VERSION' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_absent_block_is_exit_1() {
  _setup
  echo "No block here, just prose." >"$_ws/none.txt"
  _parse scan "$_ws/none.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"invalid"' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_missing_file_is_parser_error() {
  _setup
  _parse scan "$_ws/does-not-exist.txt"
  local ok=1
  [ "$_RC" -eq 2 ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_shell_metachars_inert() {
  _setup
  _canonical_scan
  sed 's/no AC states what correctly means/$(touch \/tmp\/dor-semantic-pwned)/' "$_ws/scan.txt" >"$_ws/scan-inj.txt"
  rm -f /tmp/dor-semantic-pwned
  _parse scan "$_ws/scan-inj.txt"
  local ok=1
  [ ! -f /tmp/dor-semantic-pwned ] || ok=0
  echo "$_OUT" | grep -qF '$(touch /tmp/dor-semantic-pwned)' || ok=0
  rm -f /tmp/dor-semantic-pwned
  _teardown
  [ "$ok" = "1" ]
}

test_unicode_values_preserved() {
  _setup
  _canonical_scan
  sed 's/no AC states what correctly means/no AC states 正しく means — 日本語 café/' "$_ws/scan.txt" >"$_ws/scan-uni.txt"
  _parse scan "$_ws/scan-uni.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '日本語' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── 3.2: contract cases ──────────────────────────────────────────────────

test_missing_gap_verdict_rejected() {
  _setup
  _canonical_scan
  grep -v '^GAP_EDGE_CASE_SUFFICIENCY' "$_ws/scan.txt" >"$_ws/scan-nogap.txt"
  # re-close block
  sed -i '/=== END/d' "$_ws/scan-nogap.txt"
  echo "=== END DOR_SEMANTIC_SCAN ===" >>"$_ws/scan-nogap.txt"
  _parse scan "$_ws/scan-nogap.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q 'GAP_EDGE_CASE_SUFFICIENCY' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_contradiction_without_quote_b_rejected() {
  _setup
  cat >"$_ws/scan.txt" <<'EOF'
=== DOR_SEMANTIC_SCAN ===
SCHEMA_VERSION: 1
TICKET: WIL-123
BODY_HASH: sha256:abc123
FINDING_1_CODE: CONTRADICTORY_REQUIREMENTS
FINDING_1_QUOTE: all fields are optional
GAP_REQUIREMENT_COMPLETENESS: clear
GAP_REQUIREMENT_COMPLETENESS_REASON: r
GAP_CONTRADICTORY_REQUIREMENTS: finding
GAP_CONTRADICTORY_REQUIREMENTS_REASON: see FINDING_1
GAP_DEEP_SCOPE_AMBIGUITY: clear
GAP_DEEP_SCOPE_AMBIGUITY_REASON: r
GAP_EDGE_CASE_SUFFICIENCY: clear
GAP_EDGE_CASE_SUFFICIENCY_REASON: r
=== END DOR_SEMANTIC_SCAN ===
EOF
  _parse scan "$_ws/scan.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q 'QUOTE_B' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_hard_code_not_audited_rejected() {
  _setup
  echo '{"missing": ["SCOPE_MISSING"], "advisory": []}' >"$_ws/det.json"
  _canonical_audit
  _parse audit "$_ws/audit.txt" "$_ws/det.json"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q 'not audited\|AUDIT_n entry' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_advisory_code_not_audited_accepted() {
  _setup
  echo '{"missing": ["AC_VAGUE"], "advisory": ["VPLAN_MISSING"]}' >"$_ws/det.json"
  _canonical_audit
  _parse audit "$_ws/audit.txt" "$_ws/det.json"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_disputed_without_reason_rejected() {
  _setup
  cat >"$_ws/audit.txt" <<'EOF'
=== DOR_SEMANTIC_AUDIT ===
SCHEMA_VERSION: 1
TICKET: WIL-123
BODY_HASH: sha256:abc123
AUDIT_1_CODE: AC_VAGUE
AUDIT_1_VERDICT: disputed
AUDIT_1_REASON:
SCORE_PLAUSIBLE: yes
SCORE_REASON: ok
=== END DOR_SEMANTIC_AUDIT ===
EOF
  _parse audit "$_ws/audit.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q 'disputed' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_secret_shaped_value_redacted() {
  _setup
  cat >"$_ws/audit.txt" <<'EOF'
=== DOR_SEMANTIC_AUDIT ===
SCHEMA_VERSION: 1
TICKET: WIL-123
BODY_HASH: sha256:abc123
AUDIT_1_CODE: AC_VAGUE
AUDIT_1_VERDICT: agree
AUDIT_1_REASON: leaked token ghp_1234567890abcdefghij1234567890 in the reason
SCORE_PLAUSIBLE: yes
SCORE_REASON: ok
=== END DOR_SEMANTIC_AUDIT ===
EOF
  _parse audit "$_ws/audit.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -qv 'ghp_1234567890abcdefghij1234567890' || ok=0
  echo "$_OUT" | grep -q 'REDACTED' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── 3.3: sourcing / drift guards ─────────────────────────────────────────

test_sourcing_does_not_enable_errexit() {
  local out
  out=$(bash -c '
    set +e
    source "'"$PARSER"'"
    case "$-" in *e*) echo LEAKED ;; *) echo CLEAN ;; esac
  ')
  [ "$out" = "CLEAN" ]
}

test_schema_doc_enums_match_parser() {
  local schema_doc="$LIB_DIR/../docs/dor-semantic-schema.md"
  [ -f "$schema_doc" ] || return 1
  local ok=1
  local c
  for c in MISSING_CORE_AC NEEDS_HUMAN_DECISION INTENT_AC_MISMATCH \
    CONTRADICTORY_REQUIREMENTS SCOPE_AMBIGUOUS EDGE_CASE_GAP \
    UNSTATED_DEPENDENCY AC_NOT_TESTABLE; do
    grep -q "$c" "$schema_doc" || {
      echo "code $c not in schema doc" >&2
      ok=0
    }
  done
  for v in agree disputed uncertain; do
    grep -q "$v" "$schema_doc" || {
      echo "verdict $v not in schema doc" >&2
      ok=0
    }
  done
  for v in clear finding not-applicable; do
    grep -q "$v" "$schema_doc" || {
      echo "gap verdict $v not in schema doc" >&2
      ok=0
    }
  done
  [ "$ok" = "1" ]
}

# ── run ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"
for t in test_canonical_scan_valid test_canonical_audit_valid \
  test_block_after_prose test_reordered_fields_accepted test_crlf_accepted \
  test_indented_markers_accepted test_last_block_wins \
  test_truncated_last_block_uses_prior_complete test_lowercase_key_rejected \
  test_dashed_key_rejected test_duplicate_key_rejected \
  test_json_envelope_accepted test_stream_json_envelope_accepted \
  test_unknown_code_rejected test_gap_enum_violation_rejected \
  test_wrong_schema_version_rejected test_absent_block_is_exit_1 \
  test_missing_file_is_parser_error test_shell_metachars_inert \
  test_unicode_values_preserved test_missing_gap_verdict_rejected \
  test_contradiction_without_quote_b_rejected test_hard_code_not_audited_rejected \
  test_advisory_code_not_audited_accepted test_disputed_without_reason_rejected \
  test_secret_shaped_value_redacted test_sourcing_does_not_enable_errexit \
  test_schema_doc_enums_match_parser; do
  if [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]]; then continue; fi
  _run "$t" "$t"
done

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
