#!/usr/bin/env bash
# test-planner-repos-root-required.sh — Regression tests for #459.
#
# planner_state_write (and the other state/intent helpers) used to fall back to
# ${HOME}/repos when REPOS_ROOT was unset, so a phase agent whose shell lost the
# variable wrote its state entries into a stray ~/repos/.ticket-auto tree nobody
# reads. They must now fail loudly and create nothing. Phase prompts must also
# carry the dispatcher's REPOS_ROOT as a literal export.
#
# Each case runs in a fresh `bash -c` with REPOS_ROOT removed from the
# environment and HOME pointed at a temp dir, so the old fallback would land
# somewhere this test can observe.
#
# Run: bash ticket-planner/lib/tests/test-planner-repos-root-required.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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

INIT="INIT-1700000000-0459"

# Run a snippet with REPOS_ROOT unset and HOME redirected to a fresh fake home.
# Usage: run_unset <fake_home> <snippet>
# Sets RC and ERR.
run_unset() {
  local fake_home="$1" snippet="$2"
  mkdir -p "$fake_home"
  RC=0
  ERR=$(env -u REPOS_ROOT HOME="$fake_home" LIB_DIR="$LIB_DIR" INIT="$INIT" \
    bash -c "$snippet" 2>&1 >/dev/null) || RC=$?
}

echo "=== REPOS_ROOT required (#459) ==="

# ── Test 1: planner_state_write fails and creates nothing ───────────────────────
echo "--- Test 1: planner_state_write with REPOS_ROOT unset ---"
H1="${TMP}/home1"
run_unset "$H1" 'source "$LIB_DIR/planner-state.sh"
planner_state_write "$INIT" Consensus resolve start "Resolving findings"'
if [ "$RC" -ne 0 ]; then
  pass "returns non-zero"
else
  fail "returns non-zero" "rc=0"
fi
if [ ! -e "${H1}/repos" ]; then
  pass "creates no ~/repos tree"
else
  fail "creates no ~/repos tree" "$(find "${H1}/repos" | head -5 | tr '\n' ' ')"
fi
if [ ! -e "/state.log" ] && [ ! -e "/state.log.lock" ]; then
  pass "does not fall through to /state.log"
else
  fail "does not fall through to /state.log" "/state.log exists"
fi
if printf '%s' "$ERR" | grep -q 'REPOS_ROOT'; then
  pass "error names REPOS_ROOT"
else
  fail "error names REPOS_ROOT" "stderr: $ERR"
fi

# ── Test 2: set -e caller sees a handleable failure, not a silent death ────────
echo "--- Test 2: set -e caller can handle the failure ---"
H2="${TMP}/home2"
OUT=$(env -u REPOS_ROOT HOME="$H2" LIB_DIR="$LIB_DIR" INIT="$INIT" bash -c '
set -euo pipefail
source "$LIB_DIR/planner-state.sh"
if ! planner_state_write "$INIT" Review critique start "x" 2>/dev/null; then
  echo handled
fi' 2>/dev/null) || true
if [ "$OUT" = "handled" ]; then
  pass "failure is observable by an if-guarded set -e caller"
else
  fail "failure is observable by an if-guarded set -e caller" "got '$OUT'"
fi

# ── Test 3: dir init, state init and intent recording also refuse ──────────────
echo "--- Test 3: other writers refuse ---"
H3="${TMP}/home3"
# Usage: expect_refused <label>  (reads RC from the last run_unset)
expect_refused() {
  if [ "$RC" -ne 0 ] && [ ! -e "${H3}/repos" ]; then
    pass "$1 refuses"
  else
    fail "$1 refuses" "rc=$RC, ~/repos exists: $([ -e "${H3}/repos" ] && echo yes || echo no)"
  fi
}

run_unset "$H3" 'source "$LIB_DIR/planner-state.sh"
planner_initiative_dir_init "$INIT"'
expect_refused planner_initiative_dir_init

run_unset "$H3" 'source "$LIB_DIR/planner-state.sh"
planner_state_init "$INIT" "idea"'
expect_refused planner_state_init

run_unset "$H3" 'source "$LIB_DIR/planner-state.sh"
source "$LIB_DIR/planner-ticket-validate.sh"
planner_record_intent "$INIT" EpicGen epic epic-main'
expect_refused planner_record_intent

# ── Test 4: read-only Crosscheck helpers do not silently pass ──────────────────
echo "--- Test 4: Crosscheck helpers refuse instead of reading ~/repos ---"
H4="${TMP}/home4"
# Seed the old fallback location so a guessing helper would find something.
mkdir -p "${H4}/repos/.ticket-auto/initiatives/${INIT}/artifacts/specs"
run_unset "$H4" 'source "$LIB_DIR/planner-state.sh"
source "$LIB_DIR/planner-crosscheck-deps.sh"
planner_crosscheck_deps "$INIT"'
if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -q 'REPOS_ROOT'; then
  pass "planner_crosscheck_deps fails naming REPOS_ROOT"
else
  fail "planner_crosscheck_deps fails naming REPOS_ROOT" "rc=$RC stderr: $ERR"
fi

# ── Test 5: set REPOS_ROOT still works ──────────────────────────────────────────
echo "--- Test 5: REPOS_ROOT set still writes the real log ---"
REAL="${TMP}/real-root"
mkdir -p "$REAL"
RC=0
env REPOS_ROOT="$REAL" HOME="${TMP}/home5" LIB_DIR="$LIB_DIR" INIT="$INIT" bash -c '
set -euo pipefail
source "$LIB_DIR/planner-state.sh"
planner_state_write "$INIT" Consensus resolve start "Resolving findings"' || RC=$?
if [ "$RC" -eq 0 ] && grep -q '|Consensus|resolve|start|' "${REAL}/.ticket-auto/initiatives/${INIT}/state.log" 2>/dev/null; then
  pass "entry lands in \$REPOS_ROOT/.ticket-auto/initiatives/<ID>/state.log"
else
  fail "entry lands in the real log" "rc=$RC"
fi

# ── Test 6: phase prompts export REPOS_ROOT as a literal ───────────────────────
echo "--- Test 6: phase prompts carry a literal REPOS_ROOT export ---"
PROMPT_ROOT="${TMP}/prompt root"
mkdir -p "$PROMPT_ROOT"
PROMPT=$(env REPOS_ROOT="$PROMPT_ROOT" LIB_DIR="$LIB_DIR" INIT="$INIT" bash -c '
source "$LIB_DIR/planner-state.sh"
source "$LIB_DIR/planner-phase-prompts.sh"
planner_prompt_for_phase Consensus "$INIT" "an idea" "$REPOS_ROOT/.ticket-auto/initiatives/$INIT"' 2>/dev/null) || true
expected="export REPOS_ROOT=$(printf '%q' "$PROMPT_ROOT")"
if printf '%s\n' "$PROMPT" | grep -qxF "$expected"; then
  pass "Consensus prompt contains '$expected'"
else
  fail "Consensus prompt contains literal export" "missing '$expected'"
fi

# Every preamble that exports CLAUDE_PLUGIN_ROOT must also export REPOS_ROOT.
missing=""
for phase in Appraisal Discovery Architecture Specify Review Consensus EpicGen TicketGen Completed; do
  p=$(env REPOS_ROOT="$PROMPT_ROOT" LIB_DIR="$LIB_DIR" INIT="$INIT" PHASE="$phase" bash -c '
source "$LIB_DIR/planner-state.sh"
source "$LIB_DIR/planner-phase-prompts.sh"
planner_prompt_for_phase "$PHASE" "$INIT" "an idea" "$REPOS_ROOT/.ticket-auto/initiatives/$INIT"' 2>/dev/null) || true
  n_plugin=$(printf '%s\n' "$p" | grep -cx 'export CLAUDE_PLUGIN_ROOT' || true)
  n_repos=$(printf '%s\n' "$p" | grep -cxF "$expected" || true)
  if [ "$n_plugin" -eq 0 ] || [ "$n_repos" -lt "$n_plugin" ]; then
    missing="${missing} ${phase}(plugin=${n_plugin},repos=${n_repos})"
  fi
done
if [ -z "$missing" ]; then
  pass "every phase preamble exports REPOS_ROOT"
else
  fail "every phase preamble exports REPOS_ROOT" "$missing"
fi

# A generator with no REPOS_ROOT emits a guard, not an empty export.
PROMPT_UNSET=$(env -u REPOS_ROOT LIB_DIR="$LIB_DIR" INIT="$INIT" bash -c '
source "$LIB_DIR/planner-state.sh"
source "$LIB_DIR/planner-phase-prompts.sh"
planner_prompt_for_phase Consensus "$INIT" "an idea" "/nonexistent"' 2>/dev/null) || true
if printf '%s\n' "$PROMPT_UNSET" | grep -q 'FATAL: REPOS_ROOT is not set' &&
  ! printf '%s\n' "$PROMPT_UNSET" | grep -qx "export REPOS_ROOT=''"; then
  pass "unset generator emits a fail-loud guard"
else
  fail "unset generator emits a fail-loud guard" "no guard line found"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
