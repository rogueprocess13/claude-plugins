#!/usr/bin/env bash
# test-planner-ac-checklist.sh — the generator-side acceptance-criteria
# checklist (planner_ac_checklist) stays in step with the Definition-of-Ready
# rubric that judges the criteria, and reaches the prompts that write them.
#
# Covers:
#   1. Drift: every code in the semantic evaluator's closed vocabulary
#      (DOR_SEMANTIC_CODE_ORDER, read from ticket-auto-pipeline's
#      dor-semantic.sh) is either named by a checklist rule or listed in
#      PLANNER_AC_CHECKLIST_SEMANTIC_NA — exactly once — and the checklist
#      names no semantic code the evaluator does not have.
#   2. Every non-semantic code a rule names is a real deterministic DoR code
#      in dor-check.sh.
#   3. The rendered checklist carries the five binary rules.
#   4. The Specify and Consensus prompts (where criteria are first written and
#      later amended) render the checklist.
#
# Usage: bash ticket-planner/lib/tests/test-planner-ac-checklist.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
TAP_LIB_DIR="$(cd "${LIB_DIR}/../../ticket-auto-pipeline/lib" && pwd)"

source "${LIB_DIR}/planner-phase-prompts.sh"

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

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

echo "=== planner acceptance-criteria checklist tests ==="

# ── 1. Drift against the semantic evaluator's code list ─────────────────────
echo "--- drift against DOR_SEMANTIC_CODE_ORDER ---"

# Parsed from the file, not sourced: dor-semantic.sh pulls in manifest-write.sh
# and friends, and the array literal is all this test needs.
evaluator_codes=$(awk '/^DOR_SEMANTIC_CODE_ORDER=\(/ {f=1; next} f && /^\)/ {exit} f {gsub(/[[:space:]]/, ""); if ($0 != "") print}' \
  "${TAP_LIB_DIR}/dor-semantic.sh" | sort)
if [ "$(echo "$evaluator_codes" | wc -l)" -ge 5 ]; then
  pass "evaluator code list parsed ($(echo "$evaluator_codes" | wc -l) codes)"
else
  fail "evaluator code list parsed" "got: $evaluator_codes"
fi

rule_codes=""
for entry in "${PLANNER_AC_CHECKLIST_RULES[@]}"; do
  rule_codes="$rule_codes ${entry%%|*}"
done

# Semantic codes the checklist accounts for: those a rule names that are in the
# evaluator's vocabulary, plus the declared not-applicable set.
covered=""
for c in $rule_codes; do
  echo "$evaluator_codes" | grep -qx "$c" && covered="$covered $c"
done
accounted=$(printf '%s\n' $covered $PLANNER_AC_CHECKLIST_SEMANTIC_NA | sort)

if [ "$accounted" = "$evaluator_codes" ]; then
  pass "every evaluator code is covered by a rule or declared not-applicable, exactly once"
else
  fail "checklist accounts for the evaluator's codes" \
    "diff (< evaluator, > checklist): $(diff <(echo "$evaluator_codes") <(echo "$accounted") | grep '^[<>]' | tr '\n' ' ')"
fi

for c in $PLANNER_AC_CHECKLIST_SEMANTIC_NA; do
  if echo "$evaluator_codes" | grep -qx "$c"; then
    pass "not-applicable code $c is a real evaluator code"
  else
    fail "not-applicable code $c" "not in DOR_SEMANTIC_CODE_ORDER"
  fi
done

# ── 2. Deterministic codes are real ─────────────────────────────────────────
echo "--- deterministic codes named by rules exist in dor-check.sh ---"
for c in $rule_codes; do
  echo "$evaluator_codes" | grep -qx "$c" && continue
  if grep -q "\b${c}\b" "${TAP_LIB_DIR}/dor-check.sh"; then
    pass "deterministic code $c exists in dor-check.sh"
  else
    fail "deterministic code $c" "not found in dor-check.sh"
  fi
done

# ── 2b. The AC_VAGUE rule tracks the deterministic vague-word patterns ──────
echo "--- AC_VAGUE rule tracks dor-check.sh / audit-ac-testability.sh ---"
# Pinned hash of the two pattern sources AC_VAGUE uses. When either changes,
# update the AC_VAGUE rule's word list in planner-phase-prompts.sh (and the
# probe list below), then re-pin this hash.
VAGUE_SOURCES_SHA_PINNED="93c42d5fe83e96745201a4b98466eaa08cffb4e5f372506e138a1bfa8ccaae84"
vague_sources=$(
  grep '^_DOR_VAGUE_WIDENED_RE=' "${TAP_LIB_DIR}/dor-check.sh"
  awk '/^  vague_patterns=\(/ {f=1} f {print} f && /^  \)/ {exit}' "${TAP_LIB_DIR}/audit-ac-testability.sh"
)
vague_sha=$(printf '%s\n' "$vague_sources" | sha256sum | cut -d' ' -f1)
if [ "$vague_sha" = "$VAGUE_SOURCES_SHA_PINNED" ]; then
  pass "vague-word pattern sources unchanged since the AC_VAGUE rule was written"
else
  fail "vague-word pattern sources changed" "review the AC_VAGUE rule, then re-pin VAGUE_SOURCES_SHA_PINNED=$vague_sha"
fi
vague_rule=""
for entry in "${PLANNER_AC_CHECKLIST_RULES[@]}"; do
  [ "${entry%%|*}" = "AC_VAGUE" ] && vague_rule="${entry#*|}"
done
# One probe per pattern family; each must be named in the rule.
for probe in handle properly correctly appropriately reasonably sufficiently robust intuitive seamlessly gracefully \
  "as expected" "should work" "no errors" "looks good" "is fixed" "seems fine"; do
  if [[ "$vague_rule" == *"\"$probe"* ]]; then
    pass "AC_VAGUE rule names \"$probe\""
  else
    fail "AC_VAGUE rule names \"$probe\"" "missing"
  fi
done

# ── 3. Rendered checklist ───────────────────────────────────────────────────
echo "--- rendered checklist ---"
CHECKLIST=$(planner_ac_checklist)
for phrase in "Observable pass/fail" "Names its input" "Names its check" "No vague verbs" "One behaviour per criterion" \
  '"handle(s/d)"' '"support(s)"' '"properly"' '"appropriately"'; do
  if echo "$CHECKLIST" | grep -qF -- "$phrase"; then
    pass "checklist carries $phrase"
  else
    fail "checklist carries $phrase" "missing"
  fi
done
n_rules=$(echo "$CHECKLIST" | grep -c '^- ')
if [ "$n_rules" -eq "${#PLANNER_AC_CHECKLIST_RULES[@]}" ]; then
  pass "one rendered line per rule ($n_rules)"
else
  fail "one rendered line per rule" "rendered $n_rules, table has ${#PLANNER_AC_CHECKLIST_RULES[@]}"
fi
if echo "$CHECKLIST" | grep -qF '[AC_NOT_TESTABLE, AC_IMPLEMENTATION_ONLY]'; then
  pass "rules are tagged with their DoR codes"
else
  fail "rules are tagged with their DoR codes" "tag missing"
fi

# ── 4. Present in the criteria-writing prompts ──────────────────────────────
echo "--- prompts render the checklist ---"
STATE="/repos/.ticket-auto/initiatives/INIT-TEST"
SPECIFY_PROMPT=$(planner_prompt_specify "INIT-TEST" "an idea" "$STATE")
CONSENSUS_PROMPT=$(planner_prompt_consensus "INIT-TEST" "an idea" "$STATE")
for name in SPECIFY_PROMPT CONSENSUS_PROMPT; do
  if [[ "${!name}" == *"$CHECKLIST"* ]]; then
    pass "$name contains the full rendered checklist"
  else
    fail "$name contains the full rendered checklist" "missing or altered"
  fi
done
if echo "$SPECIFY_PROMPT" | grep -qF "passes every rule of the acceptance criteria checklist"; then
  pass "Specify constraints require the checklist"
else
  fail "Specify constraints require the checklist" "missing"
fi
# The checklist sits before the Verification Notes section it refers to.
spec_cl=$(echo "$SPECIFY_PROMPT" | grep -n '^### Acceptance criteria checklist' | head -1 | cut -d: -f1)
spec_vn=$(echo "$SPECIFY_PROMPT" | grep -n '^### Verification Notes' | head -1 | cut -d: -f1)
if [ -n "$spec_cl" ] && [ -n "$spec_vn" ] && [ "$spec_cl" -lt "$spec_vn" ]; then
  pass "Specify renders the checklist before Verification Notes"
else
  fail "Specify renders the checklist before Verification Notes" "checklist=$spec_cl notes=$spec_vn"
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
