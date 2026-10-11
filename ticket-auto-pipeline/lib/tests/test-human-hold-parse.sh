#!/usr/bin/env bash
# test-human-hold-parse.sh — unit tests for lib/human-hold-parse.sh
# Usage: bash test-human-hold-parse.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PARSER="$LIB_DIR/human-hold-parse.sh"

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
_setup() { _ws=$(mktemp -d); }
_teardown() {
  [ -n "$_ws" ] && rm -rf "$_ws"
  _ws=""
}

_write_ret() { cat >"$_ws/$1"; }

_OUT=""
_ERR=""
_RC=0
_parse() {
  local phase="$1" file="$2"
  shift 2
  set +e
  _OUT=$(bash "$PARSER" --phase "$phase" --return-file "$_ws/$file" \
    --log-file "$_ws/pipeline.log" "$@" 2>"$_ws/stderr.txt")
  _RC=$?
  set -e
  _ERR=$(cat "$_ws/stderr.txt")
}

_json() { printf '%s' "$_OUT" | jq -r "$1" 2>/dev/null; }

_canonical_block() {
  cat <<'EOF'
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#Acceptance-Criteria AC-2
QUESTION_1: Should the export include archived records?
=== END HUMAN_HOLD ===
EOF
}

# ── success cases ────────────────────────────────────────────────────────────

test_canonical_block() {
  _setup
  _canonical_block | _write_ret ret.txt
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 0 ] &&
    [ "$(_json .parse_status)" = "ok" ] &&
    [ "$(_json .phase)" = "APPRAISE" ] &&
    [ "$(_json .reason)" = "SCOPE_UNDEFINED" ] &&
    [ "$(_json '.questions | length')" = "1" ]
  local rc=$?
  _teardown
  return $rc
}

test_questions_retain_numbered_ids() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: EXEC
REASON: AC_CONFLICT
BLOCKS: notes.md#AC-1
QUESTION_2: second question
QUESTION_1: first question
QUESTION_3: third question
=== END HUMAN_HOLD ===
EOF
  _parse EXEC ret.txt
  [ "$_RC" -eq 0 ] &&
    [ "$(_json '.questions | length')" = "3" ] &&
    [ "$(_json '.questions[0].id')" = "1" ] &&
    [ "$(_json '.questions[0].text')" = "first question" ] &&
    [ "$(_json '.questions[2].id')" = "3" ]
  local rc=$?
  _teardown
  return $rc
}

test_supersedes_carried() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
SUPERSEDES: hold:CRE-9:g7:a1
QUESTION_1: which archive?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 0 ] && [ "$(_json .supersedes)" = "hold:CRE-9:g7:a1" ]
  local rc=$?
  _teardown
  return $rc
}

test_shell_metacharacters_are_data() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
QUESTION_1: expected "a $b" && got `c`; see $(pwd)/out.txt
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 0 ] &&
    [ "$(_json '.questions[0].text')" = 'expected "a $b" && got `c`; see $(pwd)/out.txt' ]
  local rc=$?
  _teardown
  return $rc
}

# ── rejection cases ───────────────────────────────────────────────────────────

test_out_of_enum_reason_rejected() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: NOT_A_REAL_REASON
BLOCKS: notes.md#AC-2
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_empty_blocks_rejected() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS:
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_missing_blocks_rejected() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_no_questions_rejected() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_position_field_refused() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
POSITION: STEP_4
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_held_at_field_refused() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
HELD_AT: 2026-09-06T00:00:00Z
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_hold_id_field_refused() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
HOLD_ID: hold:CRE-9:g1:a1
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_severity_field_refused() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
SEVERITY: high
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_truncated_block_is_invalid_not_absent() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
QUESTION_1: x?
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_no_block_is_absent_and_writes_nothing() {
  _setup
  printf 'Just ordinary prose, no block here.\n' | _write_ret ret.txt
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 0 ] && [ "$(_json .parse_status)" = "absent" ] &&
    [ ! -s "$_ws/pipeline.log" ]
  local rc=$?
  _teardown
  return $rc
}

test_malformed_block_is_logged_not_dropped() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
QUESTION_1: x?
EOF
  _parse APPRAISE ret.txt
  grep -q '|META|human-hold|waiting|' "$_ws/pipeline.log" 2>/dev/null &&
    grep -q '"parse_status":"invalid"' "$_ws/pipeline.log" 2>/dev/null
  local rc=$?
  _teardown
  return $rc
}

test_phase_mismatch_rejected() {
  _setup
  _canonical_block | _write_ret ret.txt
  _parse EXEC ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

# ── redaction ────────────────────────────────────────────────────────────────

test_secret_shaped_value_is_masked() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: EXEC
REASON: CREDENTIALS_MISSING
BLOCKS: notes.md#AC-3
QUESTION_1: use token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345
=== END HUMAN_HOLD ===
EOF
  _parse EXEC ret.txt
  [ "$_RC" -eq 0 ] &&
    [[ "$(_json '.questions[0].text')" == *'***REDACTED***'* ]] &&
    [[ "$(_json '.questions[0].text')" != *'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'* ]] &&
    ! grep -q 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345' "$_ws/pipeline.log"
  local rc=$?
  _teardown
  return $rc
}

test_redaction_applies_to_blocks_too() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: EXEC
REASON: CREDENTIALS_MISSING
BLOCKS: notes.md#token=abcSECRETvalue123
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse EXEC ret.txt
  [ "$_RC" -eq 0 ] && [[ "$(_json .blocks)" == *'***REDACTED***'* ]]
  local rc=$?
  _teardown
  return $rc
}

# ── invalid → no hold eligibility (documentation-level assertion) ────────────

test_invalid_record_carries_no_hold_id_field() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: NOPE
BLOCKS: notes.md#AC-2
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  # The record never carries a hold_id at all — minting is fleetd's job —
  # so an invalid record cannot be mistaken for a releasable one.
  [ "$_RC" -eq 1 ] && [ "$(_json 'has("hold_id")')" = "false" ]
  local rc=$?
  _teardown
  return $rc
}

# ── Schema-Version 2 (planner-headless-questions) ────────────────────────────

_FIXTURES="$TEST_DIR/fixtures/human-hold"

# Every v1 fixture's canonical JSON is byte-identical to the golden captured
# before version 2 existed.
test_v1_goldens_byte_identical() {
  local f ph out rc=0
  for f in "$_FIXTURES"/v1-*.txt; do
    ph=$(grep -m1 '^PHASE:' "$f" | sed 's/PHASE: *//') || true
    ph="${ph:-APPRAISE}"
    # The invalid fixture exits 1 by design; capture, then compare.
    out=$(bash "$PARSER" --phase "$ph" --return-file "$f" 2>/dev/null) || true
    if [ "$out" != "$(cat "${f%.txt}.golden.json")" ]; then
      echo "  golden drift: $(basename "$f")"
      rc=1
    fi
  done
  return $rc
}

_v2_block() {
  cat <<'EOF'
=== HUMAN_HOLD ===
SCHEMA_VERSION: 2
PHASE: PLANNER
REASON: CREATE_GATE
BLOCKS: state.log#Crosscheck
ROUND: 1
KIND: approval
AUDIENCE: operator
QUESTION_1: Authorize creating the epic and tickets in Linear?
QUESTION_1_ID: create
QUESTION_1_OPTIONS: yes|no
QUESTION_1_DEFAULT: no
QUESTION_1_BINDING: flag:create
=== END HUMAN_HOLD ===
EOF
}

test_v2_block_round_trip() {
  _setup
  _v2_block | _write_ret ret.txt
  _parse PLANNER ret.txt
  [ "$_RC" -eq 0 ] &&
    [ "$(_json .schema_version)" = "2" ] &&
    [ "$(_json .round)" = "1" ] &&
    [ "$(_json .kind)" = "approval" ] &&
    [ "$(_json .audience)" = "operator" ] &&
    [ "$(_json '.questions[0].id')" = "create" ] &&
    [ "$(_json '.questions[0].n')" = "1" ] &&
    [ "$(_json '.questions[0].options | join(",")')" = "yes,no" ] &&
    [ "$(_json '.questions[0].default')" = "no" ] &&
    [ "$(_json '.questions[0].binding')" = "flag:create" ]
  local rc=$?
  _teardown
  return $rc
}

# Optional keys are emitted only when present.
test_v2_optional_keys_absent_when_not_given() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 2
PHASE: GRILL
REASON: READINESS_GAPS
BLOCKS: intent.md#Objective
QUESTION_1: Who is the primary user?
=== END HUMAN_HOLD ===
EOF
  _parse GRILL ret.txt
  [ "$_RC" -eq 0 ] &&
    [ "$(_json 'has("round") or has("kind") or has("audience")')" = "false" ] &&
    [ "$(_json '.questions[0] | keys | join(",")')" = "id,n,text" ] &&
    [ "$(_json '.questions[0].id')" = "1" ]
  local rc=$?
  _teardown
  return $rc
}

# A v1 block may not borrow a v2-only enum value.
test_v1_block_rejects_v2_reason() {
  _setup
  _v2_block | sed 's/^SCHEMA_VERSION: 2/SCHEMA_VERSION: 1/' | _write_ret ret.txt
  _parse PLANNER ret.txt
  [ "$_RC" -eq 1 ] && [[ "$(_json .parse_error)" == *"not in the enum"* ]]
  local rc=$?
  _teardown
  return $rc
}

test_v2_values_with_shell_metacharacters_stay_inert() {
  _setup
  local marker="$_ws/pwned"
  cat <<EOF | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 2
PHASE: PLANNER
REASON: CROSSCHECK_BLOCKED
BLOCKS: state.log#Crosscheck \$(touch $marker)
ROUND: 2
KIND: approval
AUDIENCE: operator
QUESTION_1: Accept? \$(touch $marker) \`touch $marker\` a | b; c
QUESTION_1_ID: accept-CARVE_SCOPE_LOST
QUESTION_1_DEFAULT: \$(touch $marker)
QUESTION_1_BINDING: flag:accept:CARVE_SCOPE_LOST
=== END HUMAN_HOLD ===
EOF
  _parse PLANNER ret.txt
  [ "$_RC" -eq 0 ] && [ ! -e "$marker" ] &&
    [ "$(_json '.questions[0].text')" = "Accept? \$(touch $marker) \`touch $marker\` a | b; c" ] &&
    [ "$(_json '.questions[0].default')" = "\$(touch $marker)" ]
  local rc=$?
  _teardown
  return $rc
}

test_v2_rejects_bad_binding() {
  _setup
  _v2_block | sed 's/^QUESTION_1_BINDING: .*/QUESTION_1_BINDING: shell:rm -rf/' | _write_ret ret.txt
  _parse PLANNER ret.txt
  [ "$_RC" -eq 1 ] && [[ "$(_json .parse_error)" == *"binding grammar"* ]]
  local rc=$?
  _teardown
  return $rc
}

test_v2_rejects_attr_without_question() {
  _setup
  {
    _v2_block | sed '$d'
    printf 'QUESTION_7_ID: orphan\n=== END HUMAN_HOLD ===\n'
  } | _write_ret ret.txt
  _parse PLANNER ret.txt
  [ "$_RC" -eq 1 ] && [[ "$(_json .parse_error)" == *"names no QUESTION_7"* ]]
  local rc=$?
  _teardown
  return $rc
}

test_v2_rejects_duplicate_question_id() {
  _setup
  {
    _v2_block | sed '$d'
    printf 'QUESTION_2: again?\nQUESTION_2_ID: create\n=== END HUMAN_HOLD ===\n'
  } | _write_ret ret.txt
  _parse PLANNER ret.txt
  [ "$_RC" -eq 1 ] && [[ "$(_json .parse_error)" == *"duplicate question id"* ]]
  local rc=$?
  _teardown
  return $rc
}

test_v2_rejects_default_outside_options() {
  _setup
  _v2_block | sed 's/^QUESTION_1_DEFAULT: no/QUESTION_1_DEFAULT: maybe/' | _write_ret ret.txt
  _parse PLANNER ret.txt
  [ "$_RC" -eq 1 ] && [[ "$(_json .parse_error)" == *"not one of its OPTIONS"* ]]
  local rc=$?
  _teardown
  return $rc
}

test_v2_rejects_empty_option() {
  _setup
  _v2_block | sed 's/^QUESTION_1_OPTIONS: yes|no/QUESTION_1_OPTIONS: yes||no/' | _write_ret ret.txt
  _parse PLANNER ret.txt
  [ "$_RC" -eq 1 ] && [[ "$(_json .parse_error)" == *"empty option"* ]]
  local rc=$?
  _teardown
  return $rc
}

test_v2_rejects_bad_enums() {
  _setup
  local rc=0
  _v2_block | sed 's/^KIND: approval/KIND: vote/' | _write_ret a.txt
  _parse PLANNER a.txt
  [ "$_RC" -eq 1 ] || rc=1
  _v2_block | sed 's/^AUDIENCE: operator/AUDIENCE: anyone/' | _write_ret b.txt
  _parse PLANNER b.txt
  [ "$_RC" -eq 1 ] || rc=1
  _v2_block | sed 's/^ROUND: 1/ROUND: 0/' | _write_ret c.txt
  _parse PLANNER c.txt
  [ "$_RC" -eq 1 ] || rc=1
  _teardown
  return $rc
}

test_unknown_schema_version_rejected() {
  _setup
  _v2_block | sed 's/^SCHEMA_VERSION: 2/SCHEMA_VERSION: 3/' | _write_ret ret.txt
  _parse PLANNER ret.txt
  [ "$_RC" -eq 1 ] && [[ "$(_json .parse_error)" == *"unsupported SCHEMA_VERSION"* ]]
  local rc=$?
  _teardown
  return $rc
}

test_v2_options_and_default_are_redacted() {
  _setup
  printf '%s\n' '=== HUMAN_HOLD ===' 'SCHEMA_VERSION: 2' 'PHASE: PLANNER' 'REASON: CREATE_GATE' \
    'BLOCKS: state.log' 'QUESTION_1: Pick one' \
    'QUESTION_1_OPTIONS: token=abc123secret|ghp_abcdefghijklmnopqrstuvwxyz' \
    'QUESTION_1_DEFAULT: token=abc123secret' '=== END HUMAN_HOLD ===' | _write_ret ret.txt
  _parse PLANNER ret.txt
  [ "$_RC" -eq 0 ] &&
    [ "$(_json '.questions[0].options | join(",")')" = "token=***REDACTED***,ghp_***REDACTED***" ] &&
    [ "$(_json '.questions[0].default')" = "token=***REDACTED***" ] &&
    ! grep -q 'abc123secret\|abcdefghijklmnop' "$_ws/pipeline.log"
  local rc=$?
  _teardown
  return $rc
}

# ── run ──────────────────────────────────────────────────────────────────────

_filter="${1:-}"
for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
  if [ -n "$_filter" ] && [[ "$fn" != *"$_filter"* ]]; then
    continue
  fi
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
