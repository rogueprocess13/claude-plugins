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
# VPLAN_VERIFIABLE started as a verbatim extraction of Check 2.6's
# `grep -ciP '[✓Y]'` over the whole section. Because of `-i` that matched
# any y/Y anywhere in a row ("Agency", "yearly"), so VPLAN_UNVERIFIABLE
# almost never fired (#514). It now reads only the Verifiable column — see
# the verifiable-cell rule below.
#
# VPLAN_ROWS is NEW logic, not an extraction (design.md Decision 5,
# revision 2026-09-27): Check 2.6 has never had a concept of "total
# criterion rows" separate from "how many verifiable rows exist" — a 5-row
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
#   VPLAN_VERIFIABLE — count of data rows whose Verifiable cell is a "yes"
#                       mark (see verifiable-cell rule below).
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
# Verifiable-cell rule (#514): each table (a run of consecutive `|` lines)
# takes its first row as its header. The Verifiable column is the header cell
# whose text, with `*`/`_`/backtick markup stripped and lower-cased, starts
# with "verifiable"; columns may come in any order. Only that cell of each
# data row is read. It counts when, trimmed, markup-stripped and case-folded,
# it is exactly `✓`, `✔` (with or without the emoji variation selector), `y`
# or `yes`. Anything else — blank, `✗`, `x`, `n`, `partial`, prose — does
# not count. What the writers emit: ticket-appraise-exec writes `✓`/`✗`;
# ticket-planner's planner_ticketgen_vplan writes `✓` or a blank cell;
# hand-written plans use `Y`/`Yes`. Cells are split on unescaped `|` only:
# `\|` (how the #499 composer escapes a pipe inside a cell) is swapped for a
# sentinel first, as dor-check.sh's _dor_td_items does. A row too short to
# reach the Verifiable column does not count.
#
# No Verifiable column: a table whose header has no Verifiable cell adds 0
# to VPLAN_VERIFIABLE (its rows still count toward VPLAN_ROWS). There is no
# column to read, and guessing from the whole row is exactly the #514 bug.
# This fails in the safe direction: the ticket reads as "nothing marked
# verifiable" (advisory VPLAN_UNVERIFIABLE unless DOR_STRICT_VPLAN; Check
# 2.6 falls back to the plan artifact), never as falsely verifiable.
#
# Fenced code blocks (``` lines) inside the section are skipped for both
# counts: an example table quoted in a fence is not the plan.
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

  # CRLF bodies (pasted from a web editor) would otherwise miss the anchored
  # subsection heading below.
  text=${text//$'\r'/}
  [ -n "$text" ] || return 1
  echo "$text" | grep -q '## Verification Plan' 2>/dev/null || return 1

  local vplan_section
  vplan_section=$(echo "$text" | awk '/^### Per-Criterion Verification$/,/^## /' 2>/dev/null || true)
  [ -n "$vplan_section" ] || return 1

  # LC_ALL=C: compare the ✓/✔ marks byte-for-byte, and keep tolower ASCII-only.
  local counts
  counts=$(printf '%s\n' "$vplan_section" | LC_ALL=C awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function norm(s) { gsub(/[*_`]/, "", s); return tolower(trim(s)) }
    function cells(line, arr,   n, i) {
      line = trim(line); gsub(/\\\|/, "\001", line)
      sub(/^\|/, "", line); sub(/\|$/, "", line)
      n = split(line, arr, "|")
      for (i = 1; i <= n; i++) gsub(/\001/, "|", arr[i])
      return n
    }
    function yes(v) {
      v = norm(v)
      return v == "y" || v == "yes" || v == "\342\234\223" || v == "\342\234\224" || v == "\342\234\224\357\270\217"
    }
    /^[ \t]*```/ { fence = !fence; intable = 0; next }
    fence { next }
    !/^[ \t]*\|/ { intable = 0; next }
    /^[ \t]*\|[-:| \t]+\|?[ \t]*$/ { next }
    {
      n = cells($0, c)
      if (!intable) {
        intable = 1; vcol = 0
        for (i = 1; i <= n; i++) if (index(norm(c[i]), "verifiable") == 1) { vcol = i; break }
      }
      if ($0 ~ /^[ \t]*\|[ \t]*#[ \t]*\|/) next
      rows++
      if (vcol && vcol <= n && yes(c[vcol])) ver++
    }
    END { printf "%d %d\n", rows, ver }
  ' 2>/dev/null) || counts="0 0"
  VPLAN_ROWS=${counts% *}
  VPLAN_VERIFIABLE=${counts#* }
  [[ "$VPLAN_ROWS" =~ ^[0-9]+$ ]] || VPLAN_ROWS=0
  [[ "$VPLAN_VERIFIABLE" =~ ^[0-9]+$ ]] || VPLAN_VERIFIABLE=0

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
  [ "$VPLAN_VERIFIABLE" = "2" ] && echo "✓ VPLAN_VERIFIABLE counts Verifiable-column marks" || echo "✗ VPLAN_VERIFIABLE should be 2, got $VPLAN_VERIFIABLE"

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
