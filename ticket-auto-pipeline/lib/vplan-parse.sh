#!/usr/bin/env bash
# vplan-parse.sh — shared Verification-Plan table parser (dor-readiness-gate-
# foundation, task 3.1). Sourceable bash library. Does NOT set -euo pipefail
# at file scope (caller controls error handling) — unlike audit-ac-
# testability.sh/audit-test-data-check.sh's pre-existing unconditional
# `set -eo pipefail` leak (task 4.5 fixes that leak; this is a fresh file
# written without it from the start).
#
# One parser for the `### Per-Criterion Verification` table, shared by
# gate-check.sh Check 2.6 and lib/dor-check.sh — see design.md Decision 5
# ("one Verification-Plan parser, extracted rather than added"). Before this
# file, Check 2.6 held the only implementation (gate-check.sh:445-467);
# adding a second independent parser in dor-check.sh would have guaranteed
# the two disagree about what "a complete row" means, on a channel that
# gates work.
#
# VPLAN_VERIFIABLE is a verbatim extraction of Check 2.6's existing logic —
# genuine behaviour-preserving parity, pinned by Check 2.6's own tests
# (test-gate-check.sh's Verification Plan suite, tests 16-21).
#
# VPLAN_ROWS is NEW logic, not an extraction (design.md Decision 5,
# revision 2026-09-27): Check 2.6 has never had a concept of "total
# criterion rows" separate from "how many ✓/Y matches exist" — a 5-row
# table with 1 checked mark and a 1-row table with 1 checked mark behave
# identically in the pre-existing code. lib/tests/test-vplan-parse.sh
# designs its own row-counting test cases rather than treating this half as
# pinned by pre-existing fixtures.

# vplan_parse <text>
# Reads the full markdown text of a notes.md/body.md-shaped document (or
# stdin when no argument is given, matching audit-ac-testability.sh's
# convention) and extracts the `### Per-Criterion Verification` table under
# a `## Verification Plan` section.
#
# Sets two globals (uppercase, sourced-function convention — see
# audit-ac-testability.sh/audit-test-data-check.sh):
#   VPLAN_ROWS       — count of table rows in the per-criterion table (see
#                       row-counting rule below). 0 when the table section
#                       exists but has no data rows, or when there is no
#                       table at all — the exit code is what distinguishes
#                       "0 rows in a present table" from "no table".
#   VPLAN_VERIFIABLE — count of ✓/Y matches in the extracted section
#                       (verbatim from Check 2.6's existing
#                       `grep -ciP '[✓Y]'`).
#
# Row-counting rule: a row is any line in the extracted section that starts
# with `|` (allowing leading whitespace) and is neither the header row
# (matched by its leading `| # |` cell — the documented schema's first
# column is always the row number, so this is precise where a substring
# match on the word "criterion" is not: a real data row's own criterion
# text can legitimately contain that word, e.g. "Vague criterion") nor the
# separator row (a line whose only non-whitespace characters between the
# outer `|`s are `-`, `:`, and `|`). A malformed row — wrong cell count,
# blank cells — still counts as one row: it is evidence a criterion was
# attempted, which is exactly what the advisory code VPLAN_ROW_GAP needs to
# compare against the ticket's AC count.
#
# Exit 0 — a `## Verification Plan` section and a non-empty
#          `### Per-Criterion Verification` subsection were both found
#          (VPLAN_ROWS may still be 0 if the table has no data rows).
# Exit 1 — no usable table: empty input, no `## Verification Plan` heading,
#          or no `### Per-Criterion Verification` subsection under it.
vplan_parse() {
  local text="${1:-$(cat)}"

  VPLAN_ROWS=0
  VPLAN_VERIFIABLE=0

  [ -n "$text" ] || return 1
  echo "$text" | grep -q '## Verification Plan' 2>/dev/null || return 1

  local vplan_section
  vplan_section=$(echo "$text" | awk '/^### Per-Criterion Verification$/,/^## /' 2>/dev/null || true)
  [ -n "$vplan_section" ] || return 1

  VPLAN_VERIFIABLE=$(echo "$vplan_section" | grep -ciP '[✓Y]' 2>/dev/null || true)
  [[ "$VPLAN_VERIFIABLE" =~ ^[0-9]+$ ]] || VPLAN_VERIFIABLE=0

  VPLAN_ROWS=$(echo "$vplan_section" | grep -E '^[[:space:]]*\|' 2>/dev/null |
    grep -viE '^[[:space:]]*\|[-:| ]+\|[[:space:]]*$' |
    grep -vE '^[[:space:]]*\|[[:space:]]*#[[:space:]]*\|' | wc -l | tr -d ' ') || true
  [[ "$VPLAN_ROWS" =~ ^[0-9]+$ ]] || VPLAN_ROWS=0

  return 0
}

# ── Self-test mode ────────────────────────────────────────────────────────

if [ "${1:-}" = "--self-test" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "Running self-tests..."

  full_table='## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Attorney clicks Send | global | /handover/ | none | Handover created | ✓ |
| 2 | Admin views handovers | role: admin | /admin/ | seed data: 3 | Handovers displayed | ✓ |
'
  vplan_parse "$full_table"
  [ "$VPLAN_ROWS" = "2" ] && echo "✓ VPLAN_ROWS counts data rows" || echo "✗ VPLAN_ROWS should be 2, got $VPLAN_ROWS"
  [ "$VPLAN_VERIFIABLE" = "2" ] && echo "✓ VPLAN_VERIFIABLE counts ✓/Y marks" || echo "✗ VPLAN_VERIFIABLE should be 2, got $VPLAN_VERIFIABLE"

  rc=0
  vplan_parse "no verification plan here" || rc=$?
  [ "$rc" = "1" ] && echo "✓ absent section is exit 1" || echo "✗ absent section should be exit 1 (got $rc)"

  rc=0
  vplan_parse "## Verification Plan
**Date:** today" || rc=$?
  [ "$rc" = "1" ] && echo "✓ heading without per-criterion subsection is exit 1" || echo "✗ should be exit 1 (got $rc)"

  echo "Self-tests complete — run test-vplan-parse.sh for full coverage."
  exit 0
fi
