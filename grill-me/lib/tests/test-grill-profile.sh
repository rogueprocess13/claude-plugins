#!/usr/bin/env bash
# ── test-grill-profile.sh ─────────────────────────────────────────────────────
# Test suite for grill-profile.sh — profile loading and validation.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PROFILES_DIR="$(cd "$LIB_DIR/../profiles" && pwd)"

# shellcheck source=../grill-profile.sh
source "$LIB_DIR/grill-profile.sh"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL $1: $2"
}

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    pass "$desc"
  else
    fail "$desc" "expected exit $expected, got $actual"
  fi
}

# ── Shipped profile passes its own validator ──────────────────────────────────
echo "=== Shipped profile validation ==="

PROFILE_JSON=$(grill_profile_load "$PROFILES_DIR/product-idea.json")
exit_code=$?
assert_exit "shipped profile loads" 0 $exit_code

if grill_profile_validate "$PROFILE_JSON"; then
  pass "shipped profile passes validator"
else
  fail "shipped profile passes validator" "expected exit 0, got $? — $(grill_profile_validate "$PROFILE_JSON" 2>&1 || true)"
fi

# ── Shipped profile: test_data dimension (grill-test-data-dimension) ─────────
echo "=== Shipped profile test_data dimension ==="

if [ "$(echo "$PROFILE_JSON" | jq -r '.version')" = "1.1.0" ]; then
  pass "shipped profile version is 1.1.0"
else
  fail "shipped profile version is 1.1.0" "got $(echo "$PROFILE_JSON" | jq -r '.version')"
fi

if [ "$(echo "$PROFILE_JSON" | jq '.dimensions | length')" -eq 11 ]; then
  pass "shipped profile has 11 dimensions"
else
  fail "shipped profile has 11 dimensions" "got $(echo "$PROFILE_JSON" | jq '.dimensions | length')"
fi

TD_DIM=$(echo "$PROFILE_JSON" | jq -c '.dimensions[] | select(.id == "test_data")')
if [ -n "$TD_DIM" ] && [ "$(echo "$TD_DIM" | jq -r '.weight')" = "6" ] &&
  [ "$(echo "$TD_DIM" | jq -r '.critical')" = "false" ] &&
  [ "$(echo "$TD_DIM" | jq -r '.label')" = "Test Data" ]; then
  pass "test_data: label Test Data, weight 6, not critical"
else
  fail "test_data: label Test Data, weight 6, not critical" "got: ${TD_DIM:-<absent>}"
fi

TD_AFTER=$(echo "$PROFILE_JSON" | jq -r '[.dimensions[].id] | (index("edge_cases")) as $e | .[$e + 1] // ""')
if [ "$TD_AFTER" = "test_data" ]; then
  pass "test_data sits immediately after edge_cases"
else
  fail "test_data sits immediately after edge_cases" "next after edge_cases: ${TD_AFTER:-<none>}"
fi

if echo "$TD_DIM" | jq -e '.probes | any(contains("realistic data for testing"))' >/dev/null 2>&1; then
  pass "test_data probe asks about realistic data for testing"
else
  fail "test_data probe asks about realistic data for testing" "no matching probe"
fi

if echo "$TD_DIM" | jq -e '.probes | any(contains("_No prepared data needed_"))' >/dev/null 2>&1; then
  pass "test_data probe carries the _No prepared data needed_ sentinel"
else
  fail "test_data probe carries the _No prepared data needed_ sentinel" "no matching probe"
fi

CRIT_SET=$(echo "$PROFILE_JSON" | jq -r '[.dimensions[] | select(.critical) | .id] | sort | join(",")')
if [ "$CRIT_SET" = "acceptance_criteria,objective,scope,success_criteria,users_problem" ]; then
  pass "critical set unchanged"
else
  fail "critical set unchanged" "got $CRIT_SET"
fi

WEIGHTS=$(echo "$PROFILE_JSON" | jq -r '[.dimensions[] | "\(.id)=\(.weight)"] | join(",")')
EXPECTED_WEIGHTS="objective=14,users_problem=14,success_criteria=14,scope=12,acceptance_criteria=12,constraints=6,dependencies=6,risks=8,edge_cases=4,test_data=6,assumptions=4"
if [ "$WEIGHTS" = "$EXPECTED_WEIGHTS" ]; then
  pass "every weight matches design Decision 2 (in profile order)"
else
  fail "every weight matches design Decision 2 (in profile order)" "got $WEIGHTS"
fi

# ── Weight sums ───────────────────────────────────────────────────────────────
echo "=== Weight sum validation ==="

# Sum = 100 (valid)
VALID_100=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":60,"critical":true},{"id":"b","label":"B","weight":40,"critical":false}],"flags":{}}
JSON
)
if grill_profile_validate "$VALID_100"; then
  pass "weight sum 100 is valid"
else
  fail "weight sum 100 is valid" "unexpected rejection"
fi

# Sum = 99 (invalid)
SUM_99=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":59,"critical":true},{"id":"b","label":"B","weight":40,"critical":false}],"flags":{}}
JSON
)
if ! grill_profile_validate "$SUM_99" 2>/dev/null; then
  pass "weight sum 99 is rejected"
else
  fail "weight sum 99 is rejected" "should have failed"
fi

# Sum = 101 (invalid)
SUM_101=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":61,"critical":true},{"id":"b","label":"B","weight":40,"critical":false}],"flags":{}}
JSON
)
if ! grill_profile_validate "$SUM_101" 2>/dev/null; then
  pass "weight sum 101 is rejected"
else
  fail "weight sum 101 is rejected" "should have failed"
fi

# ── Duplicate ids ─────────────────────────────────────────────────────────────
echo "=== Duplicate id detection ==="

DUP_IDS=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":50,"critical":true},{"id":"a","label":"A Dup","weight":50,"critical":false}],"flags":{}}
JSON
)
if ! grill_profile_validate "$DUP_IDS" 2>/dev/null; then
  pass "duplicate dimension ids rejected"
else
  fail "duplicate dimension ids rejected" "should have failed"
fi

# ── Zero critical dimensions ──────────────────────────────────────────────────
echo "=== Critical dimension requirement ==="

NO_CRITICAL=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":50,"critical":false},{"id":"b","label":"B","weight":50,"critical":false}],"flags":{}}
JSON
)
if ! grill_profile_validate "$NO_CRITICAL" 2>/dev/null; then
  pass "zero critical dimensions rejected"
else
  fail "zero critical dimensions rejected" "should have failed"
fi

# ── Inverted thresholds ───────────────────────────────────────────────────────
echo "=== Threshold ordering ==="

INVERTED=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":50,"warn":80},"dimensions":[{"id":"a","label":"A","weight":100,"critical":true}],"flags":{}}
JSON
)
if ! grill_profile_validate "$INVERTED" 2>/dev/null; then
  pass "inverted thresholds (warn > ready) rejected"
else
  fail "inverted thresholds (warn > ready) rejected" "should have failed"
fi

WARN_EQ_READY=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":80},"dimensions":[{"id":"a","label":"A","weight":100,"critical":true}],"flags":{}}
JSON
)
if ! grill_profile_validate "$WARN_EQ_READY" 2>/dev/null; then
  pass "warn == ready rejected"
else
  fail "warn == ready rejected" "should have failed"
fi

# ── Missing required fields ───────────────────────────────────────────────────
echo "=== Missing required fields ==="

NO_ID=$(
  cat <<'JSON'
{"label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":100,"critical":true}],"flags":{}}
JSON
)
if ! grill_profile_validate "$NO_ID" 2>/dev/null; then
  pass "missing id rejected"
else
  fail "missing id rejected" "should have failed"
fi

NO_DIMS=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[],"flags":{}}
JSON
)
if ! grill_profile_validate "$NO_DIMS" 2>/dev/null; then
  pass "empty dimensions rejected"
else
  fail "empty dimensions rejected" "should have failed"
fi

# ── Malformed profile halts — no fallback ─────────────────────────────────────
echo "=== File load errors ==="

if ! grill_profile_load "/nonexistent/path.json" 2>/dev/null; then
  pass "nonexistent profile exits non-zero"
else
  fail "nonexistent profile exits non-zero" "should have failed"
fi

# F27: a bare profile id (what --profile takes) loads the same file as its path.
BY_ID=$(grill_profile_load product-idea 2>/dev/null)
if [ -n "$BY_ID" ] && [ "$BY_ID" = "$(grill_profile_load "$PROFILES_DIR/product-idea.json")" ]; then
  pass "a profile id resolves to profiles/<id>.json"
else
  fail "a profile id resolves to profiles/<id>.json" "got: ${BY_ID:0:80}"
fi

if ! grill_profile_load no-such-profile 2>/dev/null; then
  pass "an unknown profile id exits non-zero"
else
  fail "an unknown profile id exits non-zero" "should have failed"
fi

# ── Non-integer weight rejected ───────────────────────────────────────────────
echo "=== Non-integer weight ==="

FRACTIONAL_WEIGHT=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":50.5,"critical":true},{"id":"b","label":"B","weight":49.5,"critical":false}],"flags":{}}
JSON
)
# jq would reject this during validation (weight 50 + 49 = 99 anyway, but the weight type check should catch it)
if ! grill_profile_validate "$FRACTIONAL_WEIGHT" 2>/dev/null; then
  pass "non-integer weight rejected"
else
  # This might pass weight sum but the floor check in validation should catch non-integer weights
  # Actually, 50.5 + 49.5 = 100.0 as floats. But the floor != value check should reject.
  fail "non-integer weight rejected" "should have failed — weights must be integers"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL test(s) failed"
  exit 1
fi
echo "All tests passed"
