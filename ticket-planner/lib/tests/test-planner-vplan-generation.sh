#!/usr/bin/env bash
# test-planner-vplan-generation.sh — planner-ready-by-construction.
#
# Shape tests against the REAL ticket-auto-pipeline vplan-parse.sh, not an
# LLM-output test: proves the table shape TicketGen's prompt instructs is
# genuinely parseable by the parser it will be scored against, not just
# plausible-looking prose. Also asserts the prompt's own literal example
# table (the one TicketGen is told to mirror) round-trips through the real
# parser — a drift between the two would mean the prompt is teaching an
# agent to fail its own downstream check.
#
# Run: bash ticket-planner/lib/tests/test-planner-vplan-generation.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
VPLAN_PARSE="${LIB_DIR}/../../ticket-auto-pipeline/lib/vplan-parse.sh"

if [ ! -f "$VPLAN_PARSE" ]; then
  echo "SKIP: ticket-auto-pipeline/lib/vplan-parse.sh not found at ${VPLAN_PARSE} (sibling checkout only)"
  exit 0
fi

source "$VPLAN_PARSE"
source "${LIB_DIR}/planner-phase-prompts.sh"

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

echo "=== planner-vplan-generation tests ==="

echo "--- a body matching the instructed shape parses cleanly ---"

synthetic_body='## Acceptance Criteria
- [ ] The export button appears on the invoice list
- [ ] The exported file reflects the current filter

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|-----------|-----------|------------------|-------------------|--------------------|------------|
| 1 | Export button appears | finance | Billing > Invoices | none | button is visible | Y |
| 2 | Export reflects filter | finance | Billing > Invoices | 5 seeded invoices, 2 matching filter | downloaded file has exactly 2 rows | Y |
'

if vplan_parse "$synthetic_body"; then
  pass "vplan_parse accepts the instructed table shape"
else
  fail "vplan_parse accepts the instructed table shape" "returned nonzero"
fi
if [ "${VPLAN_ROWS:-0}" -eq 2 ]; then
  pass "VPLAN_ROWS == 2 (one per AC line)"
else
  fail "VPLAN_ROWS == 2" "got ${VPLAN_ROWS:-unset}"
fi
if [ "${VPLAN_VERIFIABLE:-0}" -eq 2 ]; then
  pass "VPLAN_VERIFIABLE == 2 (both rows marked Y)"
else
  fail "VPLAN_VERIFIABLE == 2" "got ${VPLAN_VERIFIABLE:-unset}"
fi

echo "--- a row left honestly blank still parses and counts toward the row total ---"

# vplan-parse.sh's VPLAN_VERIFIABLE is a per-LINE grep for [✓Y] (case-
# insensitive) across the whole extracted section (lib/vplan-parse.sh:76) —
# not a per-column check. A stray lowercase "y" anywhere in a row's prose
# (e.g. "any user") would be miscounted as a verifiable mark, so this test
# deliberately keeps every word in the blank row free of the letter "y" to
# isolate what it's actually testing: that leaving the Verifiable cell empty
# doesn't break parsing, not the parser's own column-blindness (out of
# scope — design.md's own Non-Goal: no change to vplan-parse.sh's contract).
mixed_body='## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|-----------|-----------|------------------|-------------------|--------------------|------------|
| 1 | Screen shows no clutter | all users | n/a | none | requires human judgment |   |
| 2 | Export downloads a CSV | finance | Billing > Invoices | none | invoices.csv downloaded | Y |
'
if vplan_parse "$mixed_body" && [ "${VPLAN_ROWS:-0}" -eq 2 ] && [ "${VPLAN_VERIFIABLE:-0}" -eq 1 ]; then
  pass "an honest blank Verifiable cell still parses; only the marked row counts"
else
  fail "an honest blank Verifiable cell still parses; only the marked row counts" "rows=${VPLAN_ROWS:-unset} verifiable=${VPLAN_VERIFIABLE:-unset}"
fi

echo "--- the prompt's own literal example table round-trips through the real parser ---"

tg_prompt=$(planner_prompt_ticketgen "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")
example_table=$(awk '
  /^## Verification Plan$/ { grab = 1 }
  grab { print }
  grab && /^```$/ && started { exit }
  grab && /^```$/ { started = 1; next }
' <<<"$tg_prompt")

if [ -n "$example_table" ] && vplan_parse "$example_table"; then
  pass "TicketGen prompt's own fenced example table is genuinely parseable"
else
  fail "TicketGen prompt's own fenced example table is genuinely parseable" "vplan_parse rejected it or nothing was extracted"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
