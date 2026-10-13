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
# _scaffold_verify_plan_no_table). VPLAN_VERIFIABLE began as an extraction of
# Check 2.6's whole-row `grep -ciP '[✓Y]'`; since #514 it reads only the
# Verifiable column, and these well-formed fixtures still give the same counts.

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

# ── Verifiable column only (#514) ──────────────────────────────────────────
# The old whole-row `grep -ciP '[✓Y]'` counted any y/Y anywhere in a row.

# _vp <text> -> "rows verifiable" (exit status ignored)
_vp() {
  vplan_parse "$1" || true
  echo "$VPLAN_ROWS $VPLAN_VERIFIABLE"
}

_hdr='## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|'

all_unverifiable="$_hdr
| 1 | Agency sees yearly summary | role: collection-agency | Reports > Yearly | any company | Summary displayed |  |
| 2 | Yes button works | any user | /survey | Yearly survey | Survey says Yes | ✗ |
| 3 | Policy copy is friendly | everyone | n/a | none | Tone feels right | n |
"
[ "$(_vp "$all_unverifiable")" = "3 0" ] &&
  _pass "#514: y/Y/Yes in other cells never count; all-unverifiable table is 0" ||
  _fail "#514: all-unverifiable should be '3 0' (got '$(_vp "$all_unverifiable")')"

marks="$_hdr
| 1 | a | b | c | none | d | ✓ |
| 2 | a | b | c | none | d | Y |
| 3 | a | b | c | none | d | Yes |
| 4 | a | b | c | none | d |  yes  |
| 5 | a | b | c | none | d | **✓** |
| 6 | a | b | c | none | d | ✔ |
| 7 | a | b | c | none | d | ✔️ |
| 8 | a | b | c | none | d | \`Y\` |
| 9 | a | b | c | none | d | x |
| 10 | a | b | c | none | d | Yes, mostly |
| 11 | a | b | c | none | d | ✗ |
| 12 | a | b | c | none | d | true |
"
[ "$(_vp "$marks")" = "12 8" ] &&
  _pass "#514: ✓/✔/Y/Yes (trimmed, case-folded, markup-stripped) count; x/✗/true/prose do not" ||
  _fail "#514: marks table should be '12 8' (got '$(_vp "$marks")')"

reordered='## Verification Plan

### Per-Criterion Verification

| # | Verifiable | Criterion | Expected behavior |
|:-:|:----------:|:----------|------------------:|
| 1 | Y | Agency report | yearly total |
| 2 |   | Daily report | Yes shown |
'
[ "$(_vp "$reordered")" = "2 1" ] &&
  _pass "#514: Verifiable column found by header name in any position, alignment colons ok" ||
  _fail "#514: reordered should be '2 1' (got '$(_vp "$reordered")')"

escaped="$_hdr
| 1 | x \\| y | b | c | none | Y |  |
| 2 | ok | b | c | none | d | ✓ |
"
[ "$(_vp "$escaped")" = "2 1" ] &&
  _pass "#514: escaped \\| inside a cell does not shift the Verifiable column" ||
  _fail "#514: escaped-pipe table should be '2 1' (got '$(_vp "$escaped")')"

short_row="$_hdr
| 1 | truncated row | Y
| 2 | a | b | c | none | d | ✓ | extra | Y |
"
[ "$(_vp "$short_row")" = "2 1" ] &&
  _pass "#514: a row too short to reach Verifiable does not count; extra cells are ignored" ||
  _fail "#514: short/extra-cell table should be '2 1' (got '$(_vp "$short_row")')"

no_column='## Verification Plan

### Per-Criterion Verification

| # | Criterion | Expected behavior |
|---|-----------|-------------------|
| 1 | Yearly export | Y |
| 2 | Agency view | ✓ |
'
rc=0
vplan_parse "$no_column" || rc=$?
[ "$rc" = "0" ] && [ "$VPLAN_ROWS" = "2" ] && [ "$VPLAN_VERIFIABLE" = "0" ] &&
  _pass "#514: no Verifiable header — rows still counted, verifiable is 0 (safe direction)" ||
  _fail "#514: no-column table should be rc 0 / 2 rows / 0 verifiable (got rc=$rc $VPLAN_ROWS $VPLAN_VERIFIABLE)"

fenced="$_hdr
| 1 | real row | b | c | none | d |  |

\`\`\`
| # | Criterion | Verifiable |
|---|-----------|------------|
| 1 | example | ✓ |
\`\`\`
"
[ "$(_vp "$fenced")" = "1 0" ] &&
  _pass "#514: a table inside a fenced code block is not counted" ||
  _fail "#514: fenced table should be '1 0' (got '$(_vp "$fenced")')"

crlf=$(printf '%s\r\n' '## Verification Plan' '' '### Per-Criterion Verification' '' \
  '| # | Criterion | Verifiable |' '|---|---|---|' '| 1 | a | Y |')
[ "$(_vp "$crlf")" = "1 1" ] &&
  _pass "#514: CRLF line endings do not hide a trailing Verifiable mark" ||
  _fail "#514: CRLF table should be '1 1' (got '$(_vp "$crlf")')"

pipecell="$_hdr
| 1 | open menu | admin | Settings | Users | none | list shown | ✓ |
| 2 | other | admin | Home | none | shown | ✗ |
"
[ "$(_vp "$pipecell")" = "2 1" ] &&
  _pass "#514 review: unescaped | in an earlier cell still reads the last-column mark" ||
  _fail "#514 review: pipe-in-cell table should be '2 1' (got '$(_vp "$pipecell")')"

marks="$_hdr
| 1 | a | r | n | d | e | ✅ |
| 2 | b | r | n | d | e | "$' '"✓"$' '" |
| 3 | c | r | n | d | e | ✓ (manual) |
"
[ "$(_vp "$marks")" = "3 2" ] &&
  _pass "#514 review: ✅ and no-break-space-padded ✓ count, '✓ (manual)' does not" ||
  _fail "#514 review: marks table should be '3 2' (got '$(_vp "$marks")')"

out=$(printf 'stdin text' | {
  vplan_parse "" || true
  cat
})
[ "$out" = "stdin text" ] &&
  _pass "#514 review: an empty argument does not read stdin" ||
  _fail "#514 review: empty argument consumed stdin (got '$out')"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
