#!/usr/bin/env bash
# appraise-handoff-check.sh — ticket-appraise Step 5's pre-handoff
# completeness gate (skill-deterministic-extraction 6a): is notes.md ready
# for ticket-appraise-exec?
#
# Usage:
#   appraise-handoff-check.sh <TICKET-DIR>
#
# Checks, both always run, each failure logged through plog.sh:
#   - `## Complexity` has a `**Score:**` line naming simple or complex (in
#     the 5 lines after the heading) ->
#     APPRAISE|handoff|fail|notes.md missing ## Complexity with Score
#   - `## Initial Investigation` has 2+ non-blank lines ->
#     APPRAISE|handoff|fail|notes.md ## Initial Investigation is empty or stub
# The Score check keeps its own grep on purpose: it is the same rule the
# inline gate used, and get_complexity (notes-parse.sh) resolves the score
# differently (a behaviour change, not an extraction).
#
# Exit codes: 0 ready, 1 a section is incomplete (stop; do not run
# /ticket-appraise-exec), 2 usage.

[ $# -eq 1 ] && [ -n "$1" ] || {
  sed -n '6,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
_AH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTES_FILE="$1/notes.md"
_rc=0
_score=$(grep -A5 "^## Complexity" "$NOTES_FILE" 2>/dev/null | grep "^\*\*Score:\*\*" | grep -oi "simple\|complex" | head -1)
if [ -z "$_score" ]; then
  bash "$_AH_DIR/plog.sh" APPRAISE handoff fail "notes.md missing ## Complexity with Score"
  _rc=1
fi
_inv_lines=$(awk '/^## Initial Investigation/{found=1; next} found && /^## /{exit} found{print}' "$NOTES_FILE" 2>/dev/null | grep -vc "^\s*$")
if [ "${_inv_lines:-0}" -lt 2 ]; then
  bash "$_AH_DIR/plog.sh" APPRAISE handoff fail "notes.md ## Initial Investigation is empty or stub"
  _rc=1
fi
exit "$_rc"
