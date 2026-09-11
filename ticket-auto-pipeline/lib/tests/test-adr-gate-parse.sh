#!/usr/bin/env bash
# test-adr-gate-parse.sh — unit tests for lib/adr-gate-parse.sh
# Usage: bash test-adr-gate-parse.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PARSER="$LIB_DIR/adr-gate-parse.sh"

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
  set +e
  _OUT=$(bash "$PARSER" --result-file "$1" 2>&1)
  _RC=$?
  set -e
}

# ── test: well-formed block parses ok, exit 0 ───────────────────────────────
test_valid_result() {
  _setup
  cat >"$_ws/r.txt" <<'EOF'
Reasoning prose first.

=== ADR_GATE_RESULT ===
SCHEMA_VERSION: 1
ADR_REQUIRED: true
ADR_VERDICT: CREATED_PROPOSED
ADR_ID: ADR-0012
GOVERNING_ADR:
CONFLICT:
HUMAN_DECISION_REQUIRED: true
RATIONALE: Establishes a cross-cutting constraint.
=== END ADR_GATE_RESULT ===
EOF
  _parse "$_ws/r.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"ok"' || ok=0
  echo "$_OUT" | grep -q '"verdict":"CREATED_PROPOSED"' || ok=0
  echo "$_OUT" | grep -q '"adr_id":"ADR-0012"' || ok=0
  echo "$_OUT" | grep -q '"adr_required":true' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: cosmetic variation (whitespace, reordered fields, unknown field,
#          blank lines) is accepted — transport tolerance ─────────────────
test_cosmetic_variation_accepted() {
  _setup
  printf '=== ADR_GATE_RESULT ===\r\n' >"$_ws/r.txt"
  cat >>"$_ws/r.txt" <<'EOF'
RATIONALE: Library choice, reversible.
ADR_VERDICT: NOT_ARCHITECTURAL

SCHEMA_VERSION: 1
EXTRA_FIELD: ignored
ADR_REQUIRED: false
HUMAN_DECISION_REQUIRED: false
=== END ADR_GATE_RESULT ===
EOF
  _parse "$_ws/r.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"ok"' || ok=0
  echo "$_OUT" | grep -q '"verdict":"NOT_ARCHITECTURAL"' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: missing required field is rejected ────────────────────────────────
test_missing_required_field_rejected() {
  _setup
  cat >"$_ws/r.txt" <<'EOF'
=== ADR_GATE_RESULT ===
SCHEMA_VERSION: 1
ADR_REQUIRED: true
ADR_VERDICT: GOVERNED
ADR_ID: ADR-0003
GOVERNING_ADR: ADR-0003
HUMAN_DECISION_REQUIRED: false
=== END ADR_GATE_RESULT ===
EOF
  _parse "$_ws/r.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"invalid"' || ok=0
  echo "$_OUT" | grep -q 'missing required field: RATIONALE' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: verdict outside the closed set is rejected ────────────────────────
test_verdict_outside_closed_set_rejected() {
  _setup
  cat >"$_ws/r.txt" <<'EOF'
=== ADR_GATE_RESULT ===
SCHEMA_VERSION: 1
ADR_REQUIRED: false
ADR_VERDICT: MAYBE_ARCHITECTURAL
HUMAN_DECISION_REQUIRED: false
RATIONALE: whatever
=== END ADR_GATE_RESULT ===
EOF
  _parse "$_ws/r.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"invalid"' || ok=0
  echo "$_OUT" | grep -q "not in the closed set" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: CONFLICT without a named ADR is rejected ──────────────────────────
test_conflict_without_adr_id_rejected() {
  _setup
  cat >"$_ws/r.txt" <<'EOF'
=== ADR_GATE_RESULT ===
SCHEMA_VERSION: 1
ADR_REQUIRED: true
ADR_VERDICT: CONFLICT
ADR_ID:
CONFLICT:
HUMAN_DECISION_REQUIRED: true
RATIONALE: Contradicts an existing decision.
=== END ADR_GATE_RESULT ===
EOF
  _parse "$_ws/r.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"invalid"' || ok=0
  echo "$_OUT" | grep -q "CONFLICT requires a non-empty ADR_ID" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: CONFLICT with an ADR_ID but empty CONFLICT text is still rejected ─
test_conflict_without_conflict_text_rejected() {
  _setup
  cat >"$_ws/r.txt" <<'EOF'
=== ADR_GATE_RESULT ===
SCHEMA_VERSION: 1
ADR_REQUIRED: true
ADR_VERDICT: CONFLICT
ADR_ID: ADR-0009
CONFLICT:
HUMAN_DECISION_REQUIRED: true
RATIONALE: Contradicts an existing decision.
=== END ADR_GATE_RESULT ===
EOF
  _parse "$_ws/r.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"invalid"' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: a well-formed CONFLICT with both fields set parses ok ────────────
test_conflict_with_adr_id_accepted() {
  _setup
  cat >"$_ws/r.txt" <<'EOF'
=== ADR_GATE_RESULT ===
SCHEMA_VERSION: 1
ADR_REQUIRED: true
ADR_VERDICT: CONFLICT
ADR_ID: ADR-0009
CONFLICT: Proposed approach contradicts the accepted retry strategy.
HUMAN_DECISION_REQUIRED: true
RATIONALE: A ratified decision forbids this approach.
=== END ADR_GATE_RESULT ===
EOF
  _parse "$_ws/r.txt"
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"ok"' || ok=0
  echo "$_OUT" | grep -q '"verdict":"CONFLICT"' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: missing closing marker is rejected ─────────────────────────────────
test_missing_closing_marker_rejected() {
  _setup
  cat >"$_ws/r.txt" <<'EOF'
=== ADR_GATE_RESULT ===
SCHEMA_VERSION: 1
ADR_REQUIRED: false
ADR_VERDICT: NOT_ARCHITECTURAL
HUMAN_DECISION_REQUIRED: false
RATIONALE: Reversible implementation choice.
EOF
  _parse "$_ws/r.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"invalid"' || ok=0
  echo "$_OUT" | grep -q "missing closing marker" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: no block at all is rejected (NOT a silent non-event, unlike
#          human-hold — the gate is required to always emit one) ───────────
test_absent_block_rejected() {
  _setup
  echo "The gate reasoned about this but forgot to emit a block." >"$_ws/r.txt"
  _parse "$_ws/r.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q '"parse_status":"invalid"' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: ADR_REQUIRED with a non-boolean value is rejected ────────────────
test_non_boolean_adr_required_rejected() {
  _setup
  cat >"$_ws/r.txt" <<'EOF'
=== ADR_GATE_RESULT ===
SCHEMA_VERSION: 1
ADR_REQUIRED: yes
ADR_VERDICT: NOT_ARCHITECTURAL
HUMAN_DECISION_REQUIRED: false
RATIONALE: Reversible.
=== END ADR_GATE_RESULT ===
EOF
  _parse "$_ws/r.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q "ADR_REQUIRED must be 'true' or 'false'" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: unsupported SCHEMA_VERSION is rejected ────────────────────────────
test_unsupported_schema_version_rejected() {
  _setup
  cat >"$_ws/r.txt" <<'EOF'
=== ADR_GATE_RESULT ===
SCHEMA_VERSION: 99
ADR_REQUIRED: false
ADR_VERDICT: NOT_ARCHITECTURAL
HUMAN_DECISION_REQUIRED: false
RATIONALE: Reversible.
=== END ADR_GATE_RESULT ===
EOF
  _parse "$_ws/r.txt"
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q "unsupported SCHEMA_VERSION" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: a rejected result still writes a META|adr-gate log line ──────────
test_invalid_result_still_logged() {
  _setup
  cat >"$_ws/r.txt" <<'EOF'
=== ADR_GATE_RESULT ===
SCHEMA_VERSION: 1
ADR_REQUIRED: false
ADR_VERDICT: BOGUS
HUMAN_DECISION_REQUIRED: false
RATIONALE: whatever
=== END ADR_GATE_RESULT ===
EOF
  set +e
  bash "$PARSER" --result-file "$_ws/r.txt" --log-file "$_ws/pipeline.log" >/dev/null 2>&1
  set -e
  local ok=1
  [ -f "$_ws/pipeline.log" ] || ok=0
  grep -q '|META|adr-gate|info|' "$_ws/pipeline.log" || ok=0
  grep -q '"parse_status":"invalid"' "$_ws/pipeline.log" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: usage error (missing file) is exit 2, not 0 or 1 ─────────────────
test_missing_file_is_parser_error() {
  _setup
  set +e
  _OUT=$(bash "$PARSER" --result-file "$_ws/does-not-exist.txt" 2>&1)
  _RC=$?
  set -e
  local ok=1
  [ "$_RC" -eq 2 ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── run ──────────────────────────────────────────────────────────────────────

FILTER="${1:-}"
for t in test_valid_result test_cosmetic_variation_accepted \
  test_missing_required_field_rejected test_verdict_outside_closed_set_rejected \
  test_conflict_without_adr_id_rejected test_conflict_without_conflict_text_rejected \
  test_conflict_with_adr_id_accepted test_missing_closing_marker_rejected \
  test_absent_block_rejected test_non_boolean_adr_required_rejected \
  test_unsupported_schema_version_rejected test_invalid_result_still_logged \
  test_missing_file_is_parser_error; do
  if [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]]; then continue; fi
  _run "$t" "$t"
done

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
