#!/usr/bin/env bash
# test-planner-lib-root.sh — Tests for plugin-root resolution and prompt preambles.
#
# Covers the gap that let issue #138 ship: no suite exercised prompt-emitted bash,
# so a fallback path that could never resolve went unnoticed through 142 tests.
#
# Run: bash ticket-planner/lib/tests/test-planner-lib-root.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
PLUGIN_ROOT="${SCRIPT_DIR}/../.."

source "${LIB_DIR}/planner-lib-root.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

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

echo "=== planner-lib-root.sh tests ==="

# ── Test 1: a valid CLAUDE_PLUGIN_ROOT is honoured ──────────────────────────────

echo "--- Test 1: valid CLAUDE_PLUGIN_ROOT wins ---"

mkdir -p "${TMPDIR}/fake-root/lib"
touch "${TMPDIR}/fake-root/lib/planner-state.sh"

got=$(CLAUDE_PLUGIN_ROOT="${TMPDIR}/fake-root" planner_resolve_lib_root)
if [ "$got" = "${TMPDIR}/fake-root" ]; then
  pass "a CLAUDE_PLUGIN_ROOT holding lib/planner-state.sh is used as-is"
else
  fail "valid CLAUDE_PLUGIN_ROOT is used as-is" "got '$got'"
fi

# ── Test 2: an invalid CLAUDE_PLUGIN_ROOT does not shadow a good candidate ──────

echo "--- Test 2: invalid CLAUDE_PLUGIN_ROOT falls through ---"

got=$(CLAUDE_PLUGIN_ROOT="${TMPDIR}/does-not-exist" HOME="$TMPDIR" planner_resolve_lib_root)
if [ "$got" = "$(cd "$PLUGIN_ROOT" && pwd)" ]; then
  pass "an inherited-but-wrong root falls through to the source checkout"
else
  fail "invalid root falls through" "got '$got'"
fi

# ── Test 3: the marketplace cache layout resolves ────────────────────────────────

echo "--- Test 3: versioned marketplace cache layout ---"

cache="${TMPDIR}/home1/.claude/plugins/cache/willard-pro-claude-plugins/ticket-planner"
mkdir -p "${cache}/0.4.0/lib" "${cache}/0.5.0/lib"
touch "${cache}/0.4.0/lib/planner-state.sh" "${cache}/0.5.0/lib/planner-state.sh"

got=$(env -u CLAUDE_PLUGIN_ROOT HOME="${TMPDIR}/home1" bash -c \
  "source '${LIB_DIR}/planner-lib-root.sh'; planner_resolve_lib_root")
if [ "$got" = "${cache}/0.5.0" ]; then
  pass "resolves the newest version under {marketplace}/{plugin}/{version}/"
else
  fail "resolves newest cached version" "got '$got'"
fi

# ── Test 4: the ~/.claude/skills/lib copy resolves ───────────────────────────────

echo "--- Test 4: SessionStart hook skills/lib copy ---"

mkdir -p "${TMPDIR}/home2/.claude/skills/lib" "${TMPDIR}/home2/.claude/plugins/cache"
touch "${TMPDIR}/home2/.claude/skills/lib/planner-state.sh"

got=$(env -u CLAUDE_PLUGIN_ROOT HOME="${TMPDIR}/home2" bash -c \
  "source '${LIB_DIR}/planner-lib-root.sh'; planner_resolve_lib_root")
if [ "$got" = "${TMPDIR}/home2/.claude/skills" ]; then
  pass "falls back to ~/.claude/skills (its lib/ is populated by the SessionStart hook)"
else
  fail "falls back to skills lib" "got '$got'"
fi

# ── Test 5: the old fallback path is gone from the tree ─────────────────────────

echo "--- Test 5: dead fallback path is gone ---"

# Assembled from parts so this file does not match its own search.
DEAD_PATH="cache/ticket-planner/""current"
hits=$(grep -rl "$DEAD_PATH" "$PLUGIN_ROOT" 2>/dev/null | grep -v "$(basename "${BASH_SOURCE[0]}")" || true)
if [ -n "$hits" ]; then
  fail "no reference to the non-existent fallback path remains" "$(echo "$hits" | tr '\n' ' ')"
else
  pass "no reference to the non-existent fallback path remains"
fi

# ── Test 6: every phase prompt emits a resolvable preamble ──────────────────────

echo "--- Test 6: prompt preambles point at a real lib dir ---"

source "${LIB_DIR}/planner-phase-prompts.sh"

# Every phase except Crosscheck has a prompt function — Crosscheck is
# deterministic bash (planner-crosscheck.sh), not an agent spawn.
ALL_PHASES=()
planner_phase_sequence ALL_PHASES
PHASES=()
for _p in "${ALL_PHASES[@]}"; do
  [ "$_p" = "Crosscheck" ] && continue
  PHASES+=("$_p")
done

for phase in "${PHASES[@]}"; do
  prompt=$(planner_prompt_for_phase "$phase" "INIT-TEST" "an idea" "${TMPDIR}/state")

  # Pull the resolved root out of the emitted preamble and check it really exists.
  # grep -m1 into a here-string (not `echo | grep`) — under pipefail, grep
  # closing early after its first match can SIGPIPE an upstream echo still
  # mid-write on a large multi-KB prompt, intermittently corrupting this
  # pipeline's reported exit status regardless of whether the match was
  # actually found (see the task 5.4 humanizer-test fix for the full story).
  root=$(grep -m1 '^CLAUDE_PLUGIN_ROOT=' <<<"$prompt" | sed 's/^CLAUDE_PLUGIN_ROOT="//;s/"$//')
  if [ -n "$root" ] && [ -f "${root}/lib/planner-state.sh" ]; then
    pass "${phase} preamble resolves to a real lib dir"
  else
    fail "${phase} preamble resolves" "root='${root}'"
  fi
done

# ── Test 7: prompt generation leaks nothing to stderr ───────────────────────────
#
# An unescaped $(...) or backtick inside these unquoted heredocs executes at
# prompt-generation time instead of being emitted for the agent. That silently
# blanked the whole deterministic confidence block in the TicketGen prompt.

echo "--- Test 7: no generation-time command substitution leaks ---"

for phase in "${PHASES[@]}"; do
  leak=$(planner_prompt_for_phase "$phase" "INIT-TEST" "an idea" "${TMPDIR}/state" 2>&1 >/dev/null)
  if [ -z "$leak" ]; then
    pass "${phase} prompt generates with no stderr"
  else
    fail "${phase} prompt generates with no stderr" "$leak"
  fi
done

# ── Test 8: the TicketGen confidence block survives to the agent ────────────────

echo "--- Test 8: TicketGen confidence block is emitted, not executed ---"

tg=$(planner_prompt_ticketgen "INIT-TEST" "an idea" "${TMPDIR}/state")

for needle in \
  'confidence=$(planner_confidence_derive' \
  'planner_context=$(planner_context_generate' \
  'signals_json=$(sed -n'; do
  if grep -qF "$needle" <<<"$tg"; then
    pass "emits: ${needle}"
  else
    fail "emits: ${needle}" "assignment was evaluated at generation time (empty in prompt)"
  fi
done

# ── Test 9: no generator-only variable survives into an emitted prompt ─────────
#
# The mirror image of Test 8. There, an *unescaped* $(...) executed at generation
# time and vanished from the prompt. Here, an *over-escaped* ${var} reaches the
# agent's shell — where the variable does not exist, because it is a local of the
# generating function. It expands to empty and the agent operates on a truncated
# path with no error.
#
# That was ENTITY_KEY="epic-${initiative_id}" (idempotency key became "epic-") and,
# worse, TicketGen reading "${state_dir}/state.log" — which resolves to
# "/state.log", so EPIC_ID came back empty and the phase hard-exited on every run.
#
# These names exist only in the prompt-building functions, so their appearance in
# emitted text is always a bug, in prose as much as in bash.

echo "--- Test 9: no generator-only variables reach the agent ---"

GENERATOR_LOCALS=(state_dir initiative_id safe_idea team_ref project_ref milestone_ref branch_override)

for phase in "${PHASES[@]}"; do
  prompt=$(planner_prompt_for_phase "$phase" "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")
  found=""
  for var in "${GENERATOR_LOCALS[@]}"; do
    if grep -qE "\\\$\{?${var}\\b" <<<"$prompt"; then
      found="${found}${var} "
    fi
  done
  if [ -z "$found" ]; then
    pass "${phase} prompt references no generator-only variable"
  else
    fail "${phase} prompt references no generator-only variable" "leaked: ${found}"
  fi
done

# The positive half: the interpolated values must actually be there, or the fix
# above could be "satisfied" by deleting the references entirely.
tg=$(planner_prompt_ticketgen "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")
if grep -qF '"/repos/.ticket-auto/initiatives/INIT-TEST/state.log"' <<<"$tg"; then
  pass "TicketGen reads the epic id from the real state log path"
else
  fail "TicketGen reads the real state log path" "path not interpolated"
fi

eg=$(planner_prompt_epicgen "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")
if grep -qF 'ENTITY_KEY="epic-INIT-TEST"' <<<"$eg"; then
  pass "the EpicGen idempotency key carries the initiative id"
else
  fail "EpicGen idempotency key carries the initiative id" "$(grep -m1 'ENTITY_KEY=' <<<"$eg")"
fi

# …and the genuinely agent-owned variables must stay escaped. ticket_slug is a
# loop variable in the agent's shell, so interpolating it here would be the
# opposite mistake.
if grep -qF 'ENTITY_KEY="ticket-${ticket_slug}"' <<<"$tg"; then
  pass "agent-owned loop variables stay escaped"
else
  fail "agent-owned loop variables stay escaped" "ticket_slug was interpolated at generation time"
fi

# TEAM_ID is used by both creating phases and was never assigned anywhere.
for phase in EpicGen TicketGen; do
  prompt=$(planner_prompt_for_phase "$phase" "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")
  assign=$(grep -m1 -n '^TEAM_ID=' <<<"$prompt" | cut -d: -f1)
  use=$(grep -m1 -n '"\$TEAM_ID"' <<<"$prompt" | cut -d: -f1)
  if [ -n "$assign" ] && [ -n "$use" ] && [ "$assign" -lt "$use" ]; then
    pass "${phase} assigns TEAM_ID before it is used"
  else
    fail "${phase} assigns TEAM_ID before use" "assign='${assign}' first-use='${use}'"
  fi
done

# tracker-planner-and-fallback-cutover (5.4): both creating phases pass an
# empty label array to planner_linear_create_issue — no planned/INIT-*/type/
# epic marker/pre-approved/blocked-by:* label is ever set at creation time.
if grep -qF "\"\$(jq -nc '[]')\"" <<<"$eg"; then
  pass "EpicGen creates the epic with an empty label array"
else
  fail "EpicGen creates the epic with an empty label array" "no literal empty-array label arg found"
fi
if grep -qF "LABELS='[]'" <<<"$tg"; then
  pass "TicketGen creates tickets with an empty label array"
else
  fail "TicketGen creates tickets with an empty label array" "LABELS is not hardcoded to '[]'"
fi
for retired in 'planner_linear_ensure_label "\$TEAM_ID" "\$INIT_LABEL"' 'planner_linear_ensure_label "\$TEAM_ID" "\$DEP_LABEL"'; do
  if grep -qF "$retired" <<<"$tg$eg"; then
    fail "no retired dynamic-label ensure call remains" "found: $retired"
  else
    pass "no retired dynamic-label ensure call remains ($retired)"
  fi
done

# ── Test 10: rendered "phase N of M" matches the derivation helpers ────────────
#
# planner-phase-count-derivation: every prompt computes its position from
# planner_phase_position/planner_phase_count rather than a literal. This test
# is the guard against a literal creeping back in.

echo "--- Test 10: prompt-reported phase position/count match the helpers ---"

EXPECTED_COUNT=$(planner_phase_count)

for phase in "${PHASES[@]}"; do
  prompt=$(planner_prompt_for_phase "$phase" "INIT-TEST" "an idea" "${TMPDIR}/state")
  expected_pos=$(planner_phase_position "$phase")

  reported=$(grep -m1 -oE '[0-9]+ of [0-9]+' <<<"$prompt" || true)
  reported_pos=$(echo "$reported" | cut -d' ' -f1)
  reported_count=$(echo "$reported" | cut -d' ' -f3)

  if [ "$reported_pos" = "$expected_pos" ] && [ "$reported_count" = "$EXPECTED_COUNT" ]; then
    pass "${phase} reports phase ${expected_pos} of ${EXPECTED_COUNT}"
  else
    fail "${phase} reports phase ${expected_pos} of ${EXPECTED_COUNT}" "got '${reported}'"
  fi
done

echo ""
echo "=== planner-lib-root.sh: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
