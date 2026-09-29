#!/usr/bin/env bash
# test-vplan-parse.sh — unit tests for lib/vplan-parse.sh
# Usage: bash test-vplan-parse.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LIB_DIR/vplan-parse.sh"

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

# ── VPLAN_VERIFIABLE parity fixtures ────────────────────────────────────────
# Lifted verbatim from lib/tests/test-gate-check.sh's Check 2.6 scaffolds
# (_scaffold_verify_plan_full / _scaffold_verify_plan_empty /
# _scaffold_verify_plan_no_table) — VPLAN_VERIFIABLE is a genuine extraction
# of Check 2.6's pre-existing `grep -ciP '[✓Y]'`, so these fixtures pin
# true parity (design.md Decision 5).

full_table='## Verification Plan
**Date:** 2026-06-24
**Derived by:** ticket-appraise-exec Step 3.7
**Overall role scope:** global

### Role Scope Assessment

| Feature area | Affected roles | Scope type | Confidence | Basis |
|-------------|---------------|-----------|-----------|-------|
| handover | all | global | low | heuristic |

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Attorney clicks Send to create handover | global | /handover/ | none | Handover created and visible in list | ✓ |
| 2 | Admin views all handovers | role: admin | /admin/ | seed data: 3 handovers | All handovers displayed in admin table | ✓ |
'

empty_table='## Verification Plan
**Date:** 2026-06-24
**Derived by:** ticket-appraise-exec Step 3.7
**Overall role scope:** unknown

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Vague criterion |  |  |  |  | ✗ |
'

heading_no_table='## Verification Plan
**Date:** 2026-06-24
**Derived by:** ticket-appraise-exec Step 3.7
**Overall role scope:** global
'

rc=0
vplan_parse "$full_table" || rc=$?
[ "$rc" = "0" ] && _pass "full table: exit 0" || _fail "full table: expected exit 0 (got $rc)"
[ "$VPLAN_VERIFIABLE" = "2" ] && _pass "full table: VPLAN_VERIFIABLE parity with Check 2.6 (2)" ||
  _fail "full table: VPLAN_VERIFIABLE should be 2 (got $VPLAN_VERIFIABLE)"

rc=0
vplan_parse "$empty_table" || rc=$?
[ "$rc" = "0" ] && _pass "empty table (✗ only): exit 0 — table present" ||
  _fail "empty table: expected exit 0 (got $rc)"
[ "$VPLAN_VERIFIABLE" = "0" ] && _pass "empty table: VPLAN_VERIFIABLE parity with Check 2.6 (0)" ||
  _fail "empty table: VPLAN_VERIFIABLE should be 0 (got $VPLAN_VERIFIABLE)"

rc=0
vplan_parse "$heading_no_table" || rc=$?
[ "$rc" = "1" ] && _pass "heading without per-criterion subsection: exit 1" ||
  _fail "heading without subsection: expected exit 1 (got $rc)"
[ "$VPLAN_VERIFIABLE" = "0" ] && _pass "heading without subsection: VPLAN_VERIFIABLE 0" ||
  _fail "heading without subsection: VPLAN_VERIFIABLE should be 0 (got $VPLAN_VERIFIABLE)"

# ── VPLAN_ROWS — new logic (design.md Decision 5, revision 2026-09-27) ─────
# No pre-existing behaviour to pin against; these test cases define what
# counts as a row.

[ "$(
  vplan_parse "$full_table"
  echo "$VPLAN_ROWS"
)" = "2" ] &&
  _pass "VPLAN_ROWS: counts each data row in a well-formed table (2)" ||
  _fail "VPLAN_ROWS: full table should count 2 rows"

# A row whose criterion text itself contains the word "criterion" must
# still count as data, not be mistaken for the header row (regression for
# the header-match-by-substring bug this test file's first draft caught).
[ "$(
  vplan_parse "$empty_table"
  echo "$VPLAN_ROWS"
)" = "1" ] &&
  _pass "VPLAN_ROWS: a row is counted even with blank/malformed cells" ||
  _fail "VPLAN_ROWS: empty-table fixture should still count 1 row (got $(
    vplan_parse "$empty_table"
    echo "$VPLAN_ROWS"
  ))"

# A present, well-formed table with zero data rows (header + separator only)
# is VPLAN_ROWS=0 with exit 0 — distinct from no table at all (exit 1).
zero_row_table='## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
'
rc=0
vplan_parse "$zero_row_table" || rc=$?
[ "$rc" = "0" ] && [ "$VPLAN_ROWS" = "0" ] &&
  _pass "VPLAN_ROWS: header+separator only is 0 rows, exit 0 (present-but-empty)" ||
  _fail "VPLAN_ROWS: header-only table should be 0 rows / exit 0 (got rc=$rc rows=$VPLAN_ROWS)"

rc=0
vplan_parse "no verification plan section at all" || rc=$?
[ "$rc" = "1" ] && [ "$VPLAN_ROWS" = "0" ] &&
  _pass "VPLAN_ROWS: absent table is 0 rows, exit 1 — distinguishable from present-but-empty via exit code" ||
  _fail "VPLAN_ROWS: absent table should be exit 1 with VPLAN_ROWS 0 (got rc=$rc rows=$VPLAN_ROWS)"

# A malformed row (fewer cells than the schema, e.g. a truncated table edit)
# still counts as one attempted row.
malformed_row_table='## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | truncated row missing trailing cells
'
[ "$(
  vplan_parse "$malformed_row_table"
  echo "$VPLAN_ROWS"
)" = "1" ] &&
  _pass "VPLAN_ROWS: a malformed (short) row still counts as one row" ||
  _fail "VPLAN_ROWS: malformed row should still count as 1 (got $(
    vplan_parse "$malformed_row_table"
    echo "$VPLAN_ROWS"
  ))"

# ── stdin input (audit-ac-testability.sh convention) ────────────────────────
# A pipe (`echo ... | vplan_parse`) would run the function in a subshell —
# its VPLAN_ROWS/VPLAN_VERIFIABLE assignments would never reach this shell.
# A here-string redirects stdin without forking, so it actually exercises
# the same `$(cat)` fallback a pipe would hit, without that trap.

rc=0
vplan_parse <<<"$full_table" || rc=$?
[ "$rc" = "0" ] && [ "$VPLAN_ROWS" = "2" ] && _pass "vplan_parse reads from stdin when no argument given" ||
  _fail "vplan_parse should read from stdin (got rc=$rc rows=$VPLAN_ROWS)"

# ── empty input ──────────────────────────────────────────────────────────

rc=0
vplan_parse "" || rc=$?
[ "$rc" = "1" ] && _pass "empty input: exit 1" || _fail "empty input should be exit 1 (got $rc)"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
