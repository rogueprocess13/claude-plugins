#!/usr/bin/env bash
# test-planner-body-template-humanizer.sh — Tests for issue #285.
#
# Covers the two things that are mechanically testable from #285:
#   1. TicketGen's and EpicGen's generated prompt text contains the canonical
#      ticket-body section headings ticket-auto-pipeline's gate-check (Check
#      2.7c, planned-ticket-body-check.sh) requires per type.
#   2. TicketGen's and EpicGen's generated prompt text contains an explicit
#      instruction to run the composed description through the humanizer
#      skill before any create/save call.
#
# Whether an agent actually follows the prompt is not testable here — this
# guards that the instruction text itself is present and survives future
# edits to planner-phase-prompts.sh. (See test-planner-generation.sh for the
# mechanical planner_validate_ticket / check_planned_body wiring tests, and
# test-planner-lib-root.sh Test 7/9 for the escaping guard that also covers
# these same heredoc edits.)
#
# Usage: bash lib/tests/test-planner-body-template-humanizer.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

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

echo "=== planner body-template + humanizer tests (issue #285) ==="

TICKETGEN_PROMPT=$(planner_prompt_ticketgen "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")
EPICGEN_PROMPT=$(planner_prompt_epicgen "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")

# ── Canonical section headings (TicketGen) ──────────────────────────────────

echo "--- TicketGen prompt names the universal required headings ---"
for heading in '## Acceptance Criteria' '## Test User' '## Scope'; do
  if grep -qF "$heading" <<<"$TICKETGEN_PROMPT"; then
    pass "TicketGen prompt mentions '${heading}'"
  else
    fail "TicketGen prompt mentions '${heading}'" "heading not found in generated prompt"
  fi
done

echo "--- TicketGen prompt names the feature/improvement-only heading ---"
if grep -qF '## Navigation Path' <<<"$TICKETGEN_PROMPT"; then
  pass "TicketGen prompt mentions '## Navigation Path'"
else
  fail "TicketGen prompt mentions '## Navigation Path'" "heading not found"
fi

echo "--- TicketGen prompt names the bug-only heading ---"
if grep -qF '## Steps to Reproduce' <<<"$TICKETGEN_PROMPT"; then
  pass "TicketGen prompt mentions '## Steps to Reproduce'"
else
  fail "TicketGen prompt mentions '## Steps to Reproduce'" "heading not found"
fi

echo "--- TicketGen prompt names the universal (planner-ready-by-construction widened) heading ---"
if grep -qF '## Test Data Prerequisites' <<<"$TICKETGEN_PROMPT"; then
  pass "TicketGen prompt mentions '## Test Data Prerequisites'"
else
  fail "TicketGen prompt mentions '## Test Data Prerequisites'" "heading not found"
fi

echo "--- TicketGen prompt references the issue and the gate-check it front-runs ---"
if grep -qF '#285' <<<"$TICKETGEN_PROMPT"; then
  pass "TicketGen prompt cites issue #285"
else
  fail "TicketGen prompt cites issue #285" "not found"
fi
if grep -qF 'planned-ticket-body-check.sh' <<<"$TICKETGEN_PROMPT"; then
  pass "TicketGen prompt names planned-ticket-body-check.sh"
else
  fail "TicketGen prompt names planned-ticket-body-check.sh" "not found"
fi

# ── planner_validate_ticket is called with the ticket type ──────────────────

echo "--- TicketGen prompt passes the ticket type to planner_validate_ticket ---"
if grep -qF 'planner_validate_ticket "$description" "true" "$TYPE_LABEL"' <<<"$TICKETGEN_PROMPT"; then
  pass "planner_validate_ticket is called with \$TYPE_LABEL as the third argument"
else
  fail "planner_validate_ticket is called with \$TYPE_LABEL" "call site not found or signature changed"
fi

# ── Humanizer instruction (TicketGen + EpicGen) ──────────────────────────────

# Normalized (newline-collapsed) copies for phrase checks that may wrap across
# lines in the rendered prompt text.
TICKETGEN_FLAT=$(echo "$TICKETGEN_PROMPT" | tr '\n' ' ')
EPICGEN_FLAT=$(echo "$EPICGEN_PROMPT" | tr '\n' ' ')

echo "--- TicketGen prompt instructs running the body through the humanizer skill ---"
if grep -qi 'humanizer' <<<"$TICKETGEN_PROMPT"; then
  pass "TicketGen prompt mentions the humanizer skill"
else
  fail "TicketGen prompt mentions the humanizer skill" "not found"
fi
if grep -qF '$description' <<<"$TICKETGEN_FLAT"; then
  pass "TicketGen humanizer instruction is scoped to \$description"
else
  fail "TicketGen humanizer instruction is scoped to \$description" "\$description not referenced near the humanizer step"
fi

echo "--- TicketGen humanizer instruction preserves facts / structure (no invented content) ---"
if grep -qi 'keep every fact' <<<"$TICKETGEN_FLAT"; then
  pass "TicketGen humanizer instruction says to keep every fact/claim intact"
else
  fail "TicketGen humanizer instruction says to keep every fact/claim intact" "not found"
fi
if grep -qi 'invent nothing' <<<"$TICKETGEN_FLAT"; then
  pass "TicketGen humanizer instruction says to invent nothing"
else
  fail "TicketGen humanizer instruction says to invent nothing" "not found"
fi
if grep -qi 'preserve every' <<<"$TICKETGEN_FLAT"; then
  pass "TicketGen humanizer instruction says to preserve headings/structure"
else
  fail "TicketGen humanizer instruction says to preserve headings/structure" "not found"
fi

echo "--- EpicGen prompt instructs running the epic description through the humanizer skill ---"
if grep -qi 'humanizer' <<<"$EPICGEN_PROMPT"; then
  pass "EpicGen prompt mentions the humanizer skill"
else
  fail "EpicGen prompt mentions the humanizer skill" "not found"
fi
if grep -qF '#285' <<<"$EPICGEN_PROMPT"; then
  pass "EpicGen prompt cites issue #285"
else
  fail "EpicGen prompt cites issue #285" "not found"
fi
if grep -qi 'keep every fact' <<<"$EPICGEN_FLAT"; then
  pass "EpicGen humanizer instruction says to keep every fact/claim intact"
else
  fail "EpicGen humanizer instruction says to keep every fact/claim intact" "not found"
fi
if grep -qi 'invent nothing' <<<"$EPICGEN_FLAT"; then
  pass "EpicGen humanizer instruction says to invent nothing"
else
  fail "EpicGen humanizer instruction says to invent nothing" "not found"
fi

# ── Ordering sanity: humanizer instruction precedes the real create call ────
#
# Both prompts also *mention* planner_linear_create_issue by name inside the
# humanizer instruction's own prose (e.g. "before it is passed to ..."), so a
# bare name search for the first occurrence would find that prose mention, not
# the real call site. The real call is distinctively shaped
# `planner_linear_create_issue \` (a line-continuation backslash opening its
# argument list) — search for that instead.

echo "--- TicketGen: humanizer instruction appears before the real create call ---"
# grep -m1 (not `| head -1`) — grep itself stops after one match, so it never
# has a second line to write once a downstream reader has gone away; a
# here-string avoids the same SIGPIPE race on the echo->grep hop. Piping a
# multi-match grep into `head -1` under `pipefail` is genuinely racy: grep
# can get SIGPIPE writing its second match after head has already closed,
# which pipefail then reports as this whole assignment's exit status —
# intermittently, depending on write/read scheduling, not on content.
humanize_line=$(grep -m1 -in 'humanizer' <<<"$TICKETGEN_PROMPT" | cut -d: -f1)
create_line=$(grep -m1 -nF 'planner_linear_create_issue \' <<<"$TICKETGEN_PROMPT" | cut -d: -f1)
if [ -n "$humanize_line" ] && [ -n "$create_line" ] && [ "$humanize_line" -lt "$create_line" ]; then
  pass "humanizer instruction precedes the real create call in TicketGen prompt"
else
  fail "humanizer instruction precedes the real create call" "humanize_line=$humanize_line create_line=$create_line"
fi

echo "--- EpicGen: humanizer instruction appears before the real create call ---"
humanize_line=$(grep -m1 -in 'humanizer' <<<"$EPICGEN_PROMPT" | cut -d: -f1)
create_line=$(grep -m1 -nF 'planner_linear_create_issue \' <<<"$EPICGEN_PROMPT" | cut -d: -f1)
if [ -n "$humanize_line" ] && [ -n "$create_line" ] && [ "$humanize_line" -lt "$create_line" ]; then
  pass "humanizer instruction precedes the real create call in EpicGen prompt"
else
  fail "humanizer instruction precedes the real create call" "humanize_line=$humanize_line create_line=$create_line"
fi

# ── SKILL.md documents the cross-plugin body-check dependency ───────────────

SKILL_MD="${LIB_DIR}/../skills/ticket-planner/SKILL.md"
echo "--- SKILL.md documents planned-ticket-body-check.sh as a cross-plugin validator ---"
if grep -qF 'planned-ticket-body-check.sh' "$SKILL_MD"; then
  pass "SKILL.md's cross-plugin validators table lists planned-ticket-body-check.sh"
else
  fail "SKILL.md lists planned-ticket-body-check.sh" "not found in $SKILL_MD"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
