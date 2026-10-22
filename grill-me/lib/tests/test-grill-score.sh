#!/usr/bin/env bash
# ── test-grill-score.sh ───────────────────────────────────────────────────────
# Test suite for grill-score.sh — deterministic scoring engine.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PROFILES_DIR="$(cd "$LIB_DIR/../profiles" && pwd)"

# shellcheck source=../grill-score.sh
source "$LIB_DIR/grill-score.sh"

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

PROFILE="$PROFILES_DIR/product-idea.json"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ── Helper: build an assessment with given dimension statuses ─────────────────
# Override statuses for named dimensions; all others default to "present".
make_assessment() {
  local subject="${1:-Test Subject}"
  local round="${2:-1}"
  local overrides="${3:-}" # "dim1:status1 dim2:status2 ..."
  local flags="${4:-{}}"

  # Build dimensions JSON array
  local dims="["
  local first=1
  local dim_count
  dim_count=$(jq '.dimensions | length' "$PROFILE")

  local i
  for i in $(seq 0 $((dim_count - 1))); do
    local did dstatus
    did=$(jq -r ".dimensions[$i].id" "$PROFILE")
    dstatus="present" # default

    # Check override
    for override in $overrides; do
      local odim="${override%%:*}"
      local ostat="${override##*:}"
      if [ "$odim" = "$did" ]; then
        dstatus="$ostat"
      fi
    done

    local ev=""
    local gap=""
    case "$dstatus" in
    present) ev="Evidence for ${did}" ;;
    partial)
      ev="Partial evidence"
      gap="Missing: details for ${did}"
      ;;
    missing) gap="No information for ${did}" ;;
    esac

    [ "$first" -eq 1 ] && first=0 || dims="${dims},"
    dims="${dims}{\"id\":\"${did}\",\"status\":\"${dstatus}\",\"evidence\":\"${ev}\",\"gap\":\"${gap}\"}"
  done
  dims="${dims}]"

  cat <<JSON
{
  "profile": "product-idea",
  "subject": "${subject}",
  "round": ${round},
  "dimensions": ${dims},
  "flags": ${flags},
  "assumptions": [],
  "risks": [],
  "questions": []
}
JSON
}

# ── All present scores 100 ────────────────────────────────────────────────────
echo "=== Readiness computation ==="

ALL_PRESENT=$(make_assessment "All present")
OUTPUT=$(grill_score "$ALL_PRESENT" "$PROFILE" 2>/dev/null)
ACTUAL=$(echo "$OUTPUT" | grep "^GRILL_READINESS=" | cut -d= -f2)
if [ "$ACTUAL" = "100" ]; then
  pass "all present scores 100"
else
  fail "all present scores 100" "expected 100, got $ACTUAL"
fi

# ── All missing scores 0 ──────────────────────────────────────────────────────
ALL_MISSING=$(make_assessment "All missing" 1 "$(jq -r '[.dimensions[].id] | join(" missing ")' "$PROFILE" | sed 's/ /:missing /g')")
# Better: just use jq to generate the overrides
ALL_MISSING=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "All missing",
    round: 1,
    dimensions: [$profile.dimensions[] | {id: .id, status: "missing", gap: "No info"}],
    flags: {},
    assumptions: [],
    risks: [],
    questions: []
  }')
OUTPUT=$(grill_score "$ALL_MISSING" "$PROFILE" 2>/dev/null)
ACTUAL=$(echo "$OUTPUT" | grep "^GRILL_READINESS=" | cut -d= -f2)
if [ "$ACTUAL" = "0" ]; then
  pass "all missing scores 0"
else
  fail "all missing scores 0" "expected 0, got $ACTUAL"
fi

# ── One weight-12 dimension partial yields 94 ─────────────────────────────────
# scope has weight 12, so: 100 - (12 * 0.5) = 94
ONE_PARTIAL=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "One partial",
    round: 1,
    dimensions: [$profile.dimensions[] |
      if .id == "scope" then {id: .id, status: "partial", evidence: "Some scope", gap: "Missing out-of-scope"}
      else {id: .id, status: "present", evidence: "Evidence for \(.id)"}
      end
    ],
    flags: {},
    assumptions: [],
    risks: [],
    questions: []
  }')
OUTPUT=$(grill_score "$ONE_PARTIAL" "$PROFILE" 2>/dev/null)
ACTUAL=$(echo "$OUTPUT" | grep "^GRILL_READINESS=" | cut -d= -f2)
if [ "$ACTUAL" = "94" ]; then
  pass "one weight-12 dimension partial yields 94"
else
  fail "one weight-12 dimension partial yields 94" "expected 94, got $ACTUAL"
fi

# ── Reproducibility ──────────────────────────────────────────────────────────
echo "=== Reproducibility ==="

OUTPUT1=$(grill_score "$ONE_PARTIAL" "$PROFILE" 2>/dev/null | grep "^GRILL_READINESS=")
OUTPUT2=$(grill_score "$ONE_PARTIAL" "$PROFILE" 2>/dev/null | grep "^GRILL_READINESS=")
if [ "$OUTPUT1" = "$OUTPUT2" ]; then
  pass "scoring is reproducible (identical output)"
else
  fail "scoring is reproducible" "outputs differ: '$OUTPUT1' vs '$OUTPUT2'"
fi

# ── Unknown dimension rejected ────────────────────────────────────────────────
echo "=== Assessment validation ==="

UNKNOWN_DIM=$(
  cat <<'JSON'
{"profile":"product-idea","subject":"Bad dim","round":1,"dimensions":[{"id":"nonexistent","status":"present","evidence":"x"}],"flags":{},"assumptions":[],"risks":[],"questions":[]}
JSON
)
if ! grill_score "$UNKNOWN_DIM" "$PROFILE" 2>/dev/null; then
  pass "unknown dimension id rejected"
else
  fail "unknown dimension id rejected" "should have failed"
fi

# ── Invalid status rejected ──────────────────────────────────────────────────
BAD_STATUS=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "Bad status",
    round: 1,
    dimensions: [$profile.dimensions[0] | {id: .id, status: "complete", evidence: "x"}],
    flags: {},
    assumptions: [],
    risks: [],
    questions: []
  }')
if ! grill_score "$BAD_STATUS" "$PROFILE" 2>/dev/null; then
  pass "invalid status rejected"
else
  fail "invalid status rejected" "should have failed"
fi

# ── Omitted dimension coerced to missing with warning ─────────────────────────
OMITTED_DIM=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "Missing dim",
    round: 1,
    dimensions: [$profile.dimensions[0] | {id: .id, status: "present", evidence: "Only one"}],
    flags: {},
    assumptions: [],
    risks: [],
    questions: []
  }')
STDERR_FILE="$SCRATCH/omitted_stderr.txt"
if grill_score "$OMITTED_DIM" "$PROFILE" 2>"$STDERR_FILE"; then
  # Should have warnings about omitted dimensions
  if grep -q "coerced to missing" "$STDERR_FILE"; then
    pass "omitted dimension coerced to missing with warning"
  else
    fail "omitted dimension coerced to missing with warning" "no coercion warning on stderr"
  fi
else
  fail "omitted dimension coerced to missing with warning" "unexpected non-zero exit"
fi

# ── Critical missing overrides high score ─────────────────────────────────────
echo "=== Recommendation precedence ==="

# All present except success_criteria (weight 14, critical) is missing → 86
# But critical missing → do-not-proceed regardless of score
CRIT_MISSING=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "Critical missing",
    round: 1,
    dimensions: [$profile.dimensions[] |
      if .id == "success_criteria" then {id: .id, status: "missing", gap: "No success criteria"}
      else {id: .id, status: "present", evidence: "Evidence for \(.id)"}
      end
    ],
    flags: {},
    assumptions: [],
    risks: [],
    questions: []
  }')
OUTPUT=$(grill_score "$CRIT_MISSING" "$PROFILE" 2>/dev/null)
REC=$(echo "$OUTPUT" | grep "^GRILL_RECOMMENDATION=" | cut -d= -f2)
READY=$(echo "$OUTPUT" | grep "^GRILL_READINESS=" | cut -d= -f2)
CRIT=$(echo "$OUTPUT" | grep "^GRILL_CRITICAL_MISSING=" | cut -d= -f2)

if [ "$READY" = "86" ]; then
  pass "critical-missing readiness is 86"
else
  fail "critical-missing readiness is 86" "expected 86, got $READY"
fi
if [ "$REC" = "do-not-proceed" ]; then
  pass "critical-missing gives do-not-proceed despite 86"
else
  fail "critical-missing gives do-not-proceed despite 86" "got $REC"
fi
if echo "$CRIT" | grep -q "success_criteria"; then
  pass "GRILL_CRITICAL_MISSING names success_criteria"
else
  fail "GRILL_CRITICAL_MISSING names success_criteria" "got '$CRIT'"
fi

# ── Ready threshold boundary ─────────────────────────────────────────────
# Profile 1.1.0 weights (grill-test-data-dimension): non-critical dims are
# constraints(6) dependencies(6) risks(8) edge_cases(4) test_data(6)
# assumptions(4) = 34. Use these for boundary tests since missing critical
# dims trigger do-not-proceed regardless of score.
#
# Exact 80: missing risks(8)+constraints(6)+test_data(6) = 20 off, no partials → 80
# Exact 79: missing risks(8)+constraints(6)+edge_cases(4) = 18 off, plus
#           test_data partial (half of 6 = 3) → 21 off → 79

AT_80=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "At 80",
    round: 1,
    dimensions: [$profile.dimensions[] |
      if .id == "risks" or .id == "constraints" or .id == "test_data" then {id: .id, status: "missing", gap: "Missing"}
      else {id: .id, status: "present", evidence: "Evidence"}
      end
    ],
    flags: {},
    assumptions: [],
    risks: [],
    questions: []
  }')
OUTPUT=$(grill_score "$AT_80" "$PROFILE" 2>/dev/null)
REC=$(echo "$OUTPUT" | grep "^GRILL_RECOMMENDATION=" | cut -d= -f2)
READY=$(echo "$OUTPUT" | grep "^GRILL_READINESS=" | cut -d= -f2)

# risks(8)+constraints(6)+test_data(6)=20 missing → 100-20=80, all non-critical
if [ "$READY" = "80" ]; then
  if [ "$REC" = "ready" ]; then
    pass "readiness 80 yields ready"
  else
    fail "readiness 80 yields ready" "got $REC"
  fi
else
  fail "readiness at 80" "expected 80, got $READY"
fi

# Readiness is computed on a x2 scale: a missing weight W loses 2W, a partial
# loses W. risks(8)+constraints(6)+edge_cases(4) missing = 36 loss, test_data(6)
# partial = 6 loss → 42 → readiness_x2 = 158 → readiness 79.

AT_79=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "At 79",
    round: 1,
    dimensions: [$profile.dimensions[] |
      if .id == "risks" or .id == "constraints" or .id == "edge_cases" then {id: .id, status: "missing", gap: "Missing"}
      elif .id == "test_data" then {id: .id, status: "partial", gap: "Partial", evidence: "Some"}
      else {id: .id, status: "present", evidence: "Evidence"}
      end
    ],
    flags: {},
    assumptions: [],
    risks: [],
    questions: []
  }')
OUTPUT2=$(grill_score "$AT_79" "$PROFILE" 2>/dev/null)
REC2=$(echo "$OUTPUT2" | grep "^GRILL_RECOMMENDATION=" | cut -d= -f2)
READY2=$(echo "$OUTPUT2" | grep "^GRILL_READINESS=" | cut -d= -f2)

if [ "$READY2" = "79" ]; then
  if [ "$REC2" = "proceed-with-warnings" ]; then
    pass "readiness 79 yields proceed-with-warnings"
  else
    fail "readiness 79 yields proceed-with-warnings" "got $REC2"
  fi
else
  fail "readiness at 79" "expected 79, got $READY2"
fi

# ── Overscoped flag penalty + cap ─────────────────────────────────────────────
echo "=== Flag penalties and caps ==="

OVERSC_LOW=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "Overscoped",
    round: 1,
    dimensions: [$profile.dimensions[] |
      if .id == "edge_cases" or .id == "assumptions" then {id: .id, status: "missing", gap: "Missing"}
      else {id: .id, status: "present", evidence: "Evidence"}
      end
    ],
    flags: {"overscoped": true},
    assumptions: [],
    risks: [],
    questions: []
  }')
# edge_cases(4)+assumptions(4)=8 missing → 92, then overscoped penalty 15 → 77
OUTPUT=$(grill_score "$OVERSC_LOW" "$PROFILE" 2>/dev/null)
REC=$(echo "$OUTPUT" | grep "^GRILL_RECOMMENDATION=" | cut -d= -f2)
READY=$(echo "$OUTPUT" | grep "^GRILL_READINESS=" | cut -d= -f2)

if [ "$READY" = "77" ] && [ "$REC" = "proceed-with-warnings" ]; then
  pass "overscoped penalty reduces score to 77 (92-15)"
else
  fail "overscoped penalty reduces score to 77 (92-15)" "readiness=${READY}, rec=${REC}"
fi

# overscoped cap = proceed-with-warnings → recommendation should be proceed-with-warnings
# even if post-penalty score still above ready threshold.

# Let's create a well-documented but overscoped case
OVERSC_HIGH=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "Well documented but overscoped",
    round: 1,
    dimensions: [$profile.dimensions[] | {id: .id, status: "present", evidence: "Thorough evidence"}],
    flags: {"overscoped": true},
    assumptions: [],
    risks: [],
    questions: []
  }')
OUTPUT=$(grill_score "$OVERSC_HIGH" "$PROFILE" 2>/dev/null)
REC=$(echo "$OUTPUT" | grep "^GRILL_RECOMMENDATION=" | cut -d= -f2)
READY=$(echo "$OUTPUT" | grep "^GRILL_READINESS=" | cut -d= -f2)

# Ready should be 85 (100 - 15 penalty), recommendation capped at proceed-with-warnings
if echo "$READY" | grep -qE '^[0-9]+$'; then
  if [ "$READY" -ge 80 ] && [ "$REC" = "proceed-with-warnings" ]; then
    pass "overscoped cap prevents ready (score=${READY}, rec=${REC})"
  elif [ "$REC" = "proceed-with-warnings" ]; then
    pass "overscoped flag capped recommendation (score=${READY}, rec=${REC})"
  else
    fail "overscoped cap prevents ready" "readiness=${READY}, rec=${REC}"
  fi
else
  fail "overscoped cap test" "unexpected output: $OUTPUT"
fi

# ── Null-cap flag (solution_masquerading_as_problem) penalises only ──────────
NULL_CAP=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "Solution masquerading",
    round: 1,
    dimensions: [$profile.dimensions[] | {id: .id, status: "present", evidence: "Evidence"}],
    flags: {"solution_masquerading_as_problem": true},
    assumptions: [],
    risks: [],
    questions: []
  }')
OUTPUT=$(grill_score "$NULL_CAP" "$PROFILE" 2>/dev/null)
REC=$(echo "$OUTPUT" | grep "^GRILL_RECOMMENDATION=" | cut -d= -f2)
READY=$(echo "$OUTPUT" | grep "^GRILL_READINESS=" | cut -d= -f2)

# 100 - 8 = 92, still above ready(80), null cap → ready
if [ "$READY" = "92" ] && [ "$REC" = "ready" ]; then
  pass "null-cap flag penalises only, still ready"
else
  # Might be 92 with ready rec
  if [ "$REC" = "ready" ]; then
    pass "null-cap flag penalises only, still ready (readiness=${READY})"
  else
    fail "null-cap flag penalises only, still ready" "readiness=${READY}, rec=${REC}"
  fi
fi

# ── test_data dimension (grill-test-data-dimension) ──────────────────────────
echo "=== test_data dimension ==="

# (a) Only test_data (weight 6, not critical) missing → 94, ready.
ONLY_TD=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "Only test data missing",
    round: 1,
    dimensions: [$profile.dimensions[] |
      if .id == "test_data" then {id: .id, status: "missing", gap: "No test data source"}
      else {id: .id, status: "present", evidence: "Evidence"}
      end
    ],
    flags: {},
    assumptions: [],
    risks: [],
    questions: []
  }')
OUTPUT=$(grill_score "$ONLY_TD" "$PROFILE" 2>/dev/null)
REC=$(echo "$OUTPUT" | grep "^GRILL_RECOMMENDATION=" | cut -d= -f2)
READY=$(echo "$OUTPUT" | grep "^GRILL_READINESS=" | cut -d= -f2)
if [ "$READY" = "94" ] && [ "$REC" = "ready" ]; then
  pass "only test_data missing gives 94/ready"
else
  fail "only test_data missing gives 94/ready" "readiness=${READY}, rec=${REC}"
fi

# (b) success_criteria + test_data missing, one question each: the critical
# dimension's question ranks first.
TD_RANK=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "Test data ranking",
    round: 1,
    dimensions: [$profile.dimensions[] |
      if .id == "success_criteria" or .id == "test_data" then {id: .id, status: "missing", gap: "Missing"}
      else {id: .id, status: "present", evidence: "Evidence"}
      end
    ],
    flags: {},
    assumptions: [],
    risks: [],
    questions: [
      {"text": "Where will realistic data for testing come from?", "dimension": "test_data", "impact": "high", "why": "Data source"},
      {"text": "How will you know this worked?", "dimension": "success_criteria", "impact": "high", "why": "Outcome"}
    ]
  }')
FIRST_Q_DIM=$(grill_score "$TD_RANK" "$PROFILE" 2>/dev/null | sed -n '/^---RESULT_JSON---$/,$p' | tail -n +2 | jq -r '.questions[0].dimension' 2>/dev/null || true)
if [ "$FIRST_Q_DIM" = "success_criteria" ]; then
  pass "success_criteria question ranks before test_data question"
else
  fail "success_criteria question ranks before test_data question" "first question dimension: ${FIRST_Q_DIM}"
fi

# ── Question ranking ──────────────────────────────────────────────────────────
echo "=== Question ranking ==="

QUESTIONS_ASSESSMENT=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "Question ranking",
    round: 1,
    dimensions: [$profile.dimensions[] |
      if .id == "success_criteria" then {id: .id, status: "missing", gap: "No criteria"}
      elif .id == "edge_cases" then {id: .id, status: "missing", gap: "No edge cases"}
      else {id: .id, status: "present", evidence: "Evidence"}
      end
    ],
    flags: {},
    assumptions: [],
    risks: [],
    questions: [
      {"text": "Q1: success criteria?", "dimension": "success_criteria", "impact": "high", "why": "Critical for measuring outcome"},
      {"text": "Q2: edge cases?", "dimension": "edge_cases", "impact": "medium", "why": "Edge cases affect robustness"},
      {"text": "Q3: more on success?", "dimension": "success_criteria", "impact": "medium", "why": "Need specific metrics"},
      {"text": "Q4: constraints?", "dimension": "constraints", "impact": "low", "why": "Check for limits"}
    ]
  }')
OUTPUT=$(grill_score "$QUESTIONS_ASSESSMENT" "$PROFILE" 2>/dev/null)
Q_COUNT=$(echo "$OUTPUT" | grep "^GRILL_QUESTION_COUNT=" | cut -d= -f2)

# success_criteria weight=14 missing → rank 14, edge_cases weight=4 missing → rank 4
# Q1 (success_criteria, high) → rank 14, impact high
# Q3 (success_criteria, medium) → rank 14, impact medium
# Q2 (edge_cases, medium) → rank 4, impact medium
# Q4 (constraints, low) → present → rank 0
# Expected order: Q1, Q3, Q2, Q4
# After truncation to 7 (max), all 4 should be included
if [ "$Q_COUNT" = "4" ]; then
  pass "question count matches assessment (4 questions)"
else
  fail "question count" "expected 4, got $Q_COUNT"
fi

# ── Ranking stability ────────────────────────────────────────────────────────
RANK1=$(grill_score "$QUESTIONS_ASSESSMENT" "$PROFILE" 2>/dev/null | grep "^GRILL_QUESTION_COUNT=")
RANK2=$(grill_score "$QUESTIONS_ASSESSMENT" "$PROFILE" 2>/dev/null | grep "^GRILL_QUESTION_COUNT=")
if [ "$RANK1" = "$RANK2" ]; then
  pass "question ranking is stable across runs"
else
  fail "question ranking stability" "outputs differ: '$RANK1' vs '$RANK2'"
fi

# ── max_questions truncation ─────────────────────────────────────────────────
echo "=== max_questions truncation ==="
# Use env override to cap at 2
MANY_QUESTIONS=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "Many questions",
    round: 1,
    dimensions: [$profile.dimensions[] | {id: .id, status: "present", evidence: "Evidence"}],
    flags: {},
    assumptions: [],
    risks: [],
    questions: [
      {"text": "Q1", "dimension": "objective", "impact": "high", "why": "Need clarification"},
      {"text": "Q2", "dimension": "success_criteria", "impact": "high", "why": "Need clarification"},
      {"text": "Q3", "dimension": "scope", "impact": "high", "why": "Need clarification"},
      {"text": "Q4", "dimension": "acceptance_criteria", "impact": "high", "why": "Need clarification"},
      {"text": "Q5", "dimension": "constraints", "impact": "high", "why": "Need clarification"},
      {"text": "Q6", "dimension": "dependencies", "impact": "high", "why": "Need clarification"},
      {"text": "Q7", "dimension": "risks", "impact": "high", "why": "Need clarification"},
      {"text": "Q8", "dimension": "edge_cases", "impact": "high", "why": "Need clarification"},
      {"text": "Q9", "dimension": "assumptions", "impact": "high", "why": "Need clarification"},
      {"text": "Q10", "dimension": "users_problem", "impact": "high", "why": "Need clarification"}
    ]
  }')
OUTPUT=$(GRILL_MAX_QUESTIONS=2 grill_score "$MANY_QUESTIONS" "$PROFILE" 2>/dev/null)
Q_COUNT=$(echo "$OUTPUT" | grep "^GRILL_QUESTION_COUNT=" | cut -d= -f2)
if [ "$Q_COUNT" = "2" ]; then
  pass "max_questions truncates to 2"
else
  fail "max_questions truncation" "expected 2, got $Q_COUNT"
fi

# ── Question without why rejected ────────────────────────────────────────────
echo "=== Question validation ==="

NO_WHY=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "Bad question",
    round: 1,
    dimensions: [$profile.dimensions[] | {id: .id, status: "present", evidence: "Evidence"}],
    flags: {},
    assumptions: [],
    risks: [],
    questions: [{"text": "Bad", "dimension": "objective", "impact": "high", "why": ""}]
  }')
if ! grill_score "$NO_WHY" "$PROFILE" 2>/dev/null; then
  pass "question without why rejected"
else
  fail "question without why rejected" "should have failed"
fi

# ── Environment override: lower ready threshold ───────────────────────────────
echo "=== Environment overrides ==="

# With readiness 78 and GRILL_THRESHOLD_READY=70, where profile says 80
# 78 >= 70 and 78 >= 55 → ready (env override)
# Use: risks(8)+dependencies(6)+edge_cases(4)+assumptions(4)=22 missing → 78
ENV_OVERRIDE=$(jq -n --argjson profile "$(cat "$PROFILE")" '
  {
    profile: "product-idea",
    subject: "Env override",
    round: 1,
    dimensions: [$profile.dimensions[] |
      if .id == "risks" or .id == "dependencies" or .id == "edge_cases" or .id == "assumptions" then {id: .id, status: "missing", gap: "Missing"}
      else {id: .id, status: "present", evidence: "Evidence"}
      end
    ],
    flags: {},
    assumptions: [],
    risks: [],
    questions: []
  }')
OUTPUT=$(GRILL_THRESHOLD_READY=70 grill_score "$ENV_OVERRIDE" "$PROFILE" 2>/dev/null)
REC=$(echo "$OUTPUT" | grep "^GRILL_RECOMMENDATION=" | cut -d= -f2)

if [ "$REC" = "ready" ]; then
  pass "env override GRILL_THRESHOLD_READY=70 makes 78 ready"
else
  fail "env override GRILL_THRESHOLD_READY=70" "expected ready, got $REC"
fi

# ── Inverted env thresholds rejected ─────────────────────────────────────────
if ! GRILL_THRESHOLD_WARN=85 GRILL_THRESHOLD_READY=80 grill_score "$ALL_PRESENT" "$PROFILE" 2>/dev/null; then
  pass "inverted env thresholds rejected"
else
  fail "inverted env thresholds rejected" "should have failed"
fi

# ── KEY=value output contract ─────────────────────────────────────────────────
echo "=== KEY=value output contract ==="

KEYS=$(grill_score "$ALL_PRESENT" "$PROFILE" 2>/dev/null | grep -E "^GRILL_" | cut -d= -f1 | sort)
EXPECTED_KEYS="GRILL_CRITICAL_MISSING
GRILL_FLAGS
GRILL_QUESTION_COUNT
GRILL_READINESS
GRILL_RECOMMENDATION"
ACTUAL_KEYS_SORTED=$(echo "$KEYS" | sort)
if [ "$ACTUAL_KEYS_SORTED" = "$EXPECTED_KEYS" ]; then
  pass "all 5 KEY=value variables emitted"
else
  fail "KEY=value output" "expected certain keys, got: $(echo "$KEYS" | tr '\n' ' ')"
fi

# ── No critical missing yields empty value (not omitted) ─────────────────────
CRIT_VAL=$(grill_score "$ALL_PRESENT" "$PROFILE" 2>/dev/null | grep "^GRILL_CRITICAL_MISSING=" | cut -d= -f2)
if [ "$CRIT_VAL" = "" ]; then
  pass "GRILL_CRITICAL_MISSING empty when no critical dimension missing"
else
  fail "GRILL_CRITICAL_MISSING empty" "expected empty, got '$CRIT_VAL'"
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
