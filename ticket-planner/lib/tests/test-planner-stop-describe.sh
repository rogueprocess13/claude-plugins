#!/usr/bin/env bash
# test-planner-stop-describe.sh — Tests for planner-stop-describe.sh
# (planner-headless-questions).
#
# Three things are pinned here:
#   1. Every real halt (halt-fixtures.sh runs each SKILL.md halt block
#      verbatim) still prints exactly its golden stdout/stderr/exit code —
#      the describer must not change any halt.
#   2. On the state each halt leaves behind, the describer names the same
#      reason the halt fired for, and its block parses as a valid
#      human-hold Schema-Version 2 block.
#   3. The terminal reasons, round numbering and byte-for-byte stability.
#
# Run: bash ticket-planner/lib/tests/test-planner-stop-describe.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
GOLDEN_DIR="${SCRIPT_DIR}/fixtures/halt-goldens"
HOLD_PARSER="${LIB_DIR}/../../ticket-auto-pipeline/lib/human-hold-parse.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# A scratch HOME, so the cross-plugin resolvers use this checkout's
# ticket-auto-pipeline — the same condition the goldens were captured under.
export HOME="${WORK}/home"
mkdir -p "$HOME"
export CLAUDE_PLUGIN_ROOT
CLAUDE_PLUGIN_ROOT="$(cd "$LIB_DIR/.." && pwd)"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-stop-describe.sh"
source "${SCRIPT_DIR}/halt-fixtures.sh"

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

INIT="INIT-1700000000-4242"

# fresh_root <name> — point REPOS_ROOT at an empty directory.
fresh_root() {
  export REPOS_ROOT="${WORK}/repos-$1"
  rm -rf "$REPOS_ROOT"
  mkdir -p "$REPOS_ROOT"
}

reason_of() {
  planner_stop_describe_json "$1" | jq -r '.reason'
}

echo "=== planner-stop-describe tests ==="

# ── 1 + 2: halt goldens and reason parity ──────────────────────────────────

echo "--- halts: goldens unchanged, describer agrees ---"

for pair in $HALT_FIXTURE_REASONS; do
  name="${pair%%:*}"
  expected="${pair#*:}"
  fresh_root "$name"
  halt_fixture_init "$name" "$INIT" >/dev/null
  halt_fixture_run "$name" "$INIT" "${WORK}/run"

  drift=""
  for ext in out err rc; do
    if ! cmp -s "${WORK}/run/${name}.${ext}" "${GOLDEN_DIR}/${name}.${ext}"; then
      drift="${drift} .${ext}"
    fi
  done
  if [ -z "$drift" ]; then
    pass "${name}: halt output matches its golden"
  else
    fail "${name}: halt output matches its golden" "differs in${drift} — diff ${WORK}/run/${name}.* ${GOLDEN_DIR}/"
  fi

  got=$(reason_of "$INIT")
  if [ "$got" = "$expected" ]; then
    pass "${name}: describer names ${expected}"
  else
    fail "${name}: describer names ${expected}" "got '${got}'"
  fi

  planner_stop_describe "$INIT" >"${WORK}/${name}.hold"
  parsed=$(bash "$HOLD_PARSER" --phase PLANNER --return-file "${WORK}/${name}.hold" 2>&1)
  if [ "$(printf '%s' "$parsed" | jq -r '.parse_status' 2>/dev/null)" = "ok" ] &&
    [ "$(printf '%s' "$parsed" | jq -r '.schema_version')" = "2" ] &&
    [ "$(printf '%s' "$parsed" | jq -r '.reason')" = "$expected" ] &&
    [ "$(printf '%s' "$parsed" | jq -r '.audience')" = "operator" ]; then
    pass "${name}: block parses as a valid v2 human-hold"
  else
    fail "${name}: block parses as a valid v2 human-hold" "$parsed"
  fi

  # Stability: same log, byte-identical output.
  if cmp -s "${WORK}/${name}.hold" <(planner_stop_describe "$INIT"); then
    pass "${name}: re-describing is byte-identical"
  else
    fail "${name}: re-describing is byte-identical" "output changed with no log change"
  fi
done

# ── per-reason question shape ──────────────────────────────────────────────

echo "--- question shapes ---"

fresh_root shape-create
halt_fixture_init create-gate-stop "$INIT" >/dev/null
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '.kind + " " + (.questions | length | tostring) + " " + .questions[0].id + " " + .questions[0].binding + " " + (.questions[0].options | join("|")) + " " + .questions[0].default')" = "approval 1 create flag:create yes|no no" ]; then
  pass "CREATE_GATE: one operator approval bound to flag:create, default no"
else
  fail "CREATE_GATE: one operator approval bound to flag:create, default no" "$m"
fi

fresh_root shape-cc
halt_fixture_init crosscheck "$INIT" >/dev/null
halt_fixture_run crosscheck "$INIT" "${WORK}/run" # records the findings
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '[.questions[].binding] | join(" ")')" = "flag:accept:CARVE_SCOPE_LOST flag:accept:CITATION_UNRESOLVED" ]; then
  pass "CROSSCHECK_BLOCKED: one question per blocking code; warn codes excluded"
else
  fail "CROSSCHECK_BLOCKED: one question per blocking code; warn codes excluded" "$m"
fi

source "${LIB_DIR}/planner-crosscheck.sh"
planner_crosscheck_accept_set "$INIT" "CARVE_SCOPE_LOST" "documented rescope"
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '[.questions[].id] | join(" ")')" = "accept-CITATION_UNRESOLVED" ]; then
  pass "CROSSCHECK_BLOCKED: an accepted code is no longer asked"
else
  fail "CROSSCHECK_BLOCKED: an accepted code is no longer asked" "$m"
fi

planner_crosscheck_accept_set "$INIT" "CITATION_UNRESOLVED" "known stale path"
if [ "$(reason_of "$INIT")" = "RUNNING" ]; then
  pass "CROSSCHECK_BLOCKED: every code accepted → RUNNING (resume re-runs Crosscheck)"
else
  fail "CROSSCHECK_BLOCKED: every code accepted → RUNNING (resume re-runs Crosscheck)" "$(reason_of "$INIT")"
fi

fresh_root shape-project
halt_fixture_init project-gate "$INIT" >/dev/null
halt_fixture_run project-gate "$INIT" "${WORK}/run"
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '.questions[0].binding + " " + (.questions[0].options | join("|"))')" = "flag:project Ledgerly|__none__" ]; then
  pass "PROJECT_GATE: options are the candidate plus __none__"
else
  fail "PROJECT_GATE: options are the candidate plus __none__" "$m"
fi

fresh_root shape-refinement
halt_fixture_init refinement "$INIT" >/dev/null
halt_fixture_run refinement "$INIT" "${WORK}/run"
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '[.questions[].binding] | join(" ")')" = "waive:PRO-102:INTENT_MISSING" ]; then
  pass "REFINEMENT_HALT: one waiver question per (not-ready ticket, code); ready tickets excluded"
else
  fail "REFINEMENT_HALT: one waiver question per (not-ready ticket, code); ready tickets excluded" "$m"
fi

fresh_root shape-adr
halt_fixture_init adr-gate "$INIT" >/dev/null
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '.questions[0].id + " " + .questions[0].binding')" = "adr-ADR-0007 note" ]; then
  pass "ADR_GATE: bound as note (adr-store accept refuses inside an agent session)"
else
  fail "ADR_GATE: bound as note (adr-store accept refuses inside an agent session)" "$m"
fi

# ── terminal reasons ───────────────────────────────────────────────────────

echo "--- terminal reasons ---"

fresh_root completed
planner_state_init "$INIT" "idea" >/dev/null
_halt_done "$INIT" Appraisal Discovery Architecture Specify Review Consensus Crosscheck EpicGen TicketGen Refinement Completed
out=$(planner_stop_describe "$INIT")
rc=$?
if [ "$out" = "REASON=COMPLETED" ] && [ "$rc" -eq 0 ]; then
  pass "COMPLETED: empty position prints REASON=COMPLETED, exit 0"
else
  fail "COMPLETED: empty position prints REASON=COMPLETED, exit 0" "rc=$rc out=$out"
fi

fresh_root running
planner_state_init "$INIT" "idea" >/dev/null
_halt_done "$INIT" Appraisal
planner_state_write "$INIT" "Discovery" "explore" "start" "x"
if [ "$(planner_stop_describe "$INIT")" = "REASON=RUNNING" ]; then
  pass "RUNNING: an interrupted phase needs only a resume"
else
  fail "RUNNING: an interrupted phase needs only a resume" "$(planner_stop_describe "$INIT")"
fi

echo "$$" >"$(planner_state_log "$INIT").phase-lock"
_halt_done "$INIT" Discovery Architecture Specify Review Consensus Crosscheck
if [ "$(planner_stop_describe "$INIT")" = "REASON=RUNNING" ]; then
  pass "RUNNING: a live phase lock wins over any gate"
else
  fail "RUNNING: a live phase lock wins over any gate" "$(planner_stop_describe "$INIT")"
fi
rm -f "$(planner_state_log "$INIT").phase-lock"

fresh_root exhausted
planner_state_init "$INIT" "idea" >/dev/null
_halt_done "$INIT" Appraisal
for _i in 1 2 3; do
  planner_state_write "$INIT" "Discovery" "explore" "start" "x"
  planner_state_write "$INIT" "Discovery" "explore" "fail" "boom"
done
if [ "$(planner_stop_describe "$INIT")" = "REASON=FAILED_RETRY_EXHAUSTED" ]; then
  pass "FAILED_RETRY_EXHAUSTED: a phase past PLANNER_MAX_PHASE_RETRIES"
else
  fail "FAILED_RETRY_EXHAUSTED: a phase past PLANNER_MAX_PHASE_RETRIES" "$(planner_stop_describe "$INIT")"
fi

# ── round numbering ────────────────────────────────────────────────────────

echo "--- rounds ---"

fresh_root rounds
halt_fixture_init create-gate-stop "$INIT" >/dev/null
r1=$(planner_stop_describe_json "$INIT" | jq -r '.round')
planner_state_write "$INIT" "META" "human-hold" "start" "round=1 sha=aaa"
planner_state_write "$INIT" "META" "human-hold" "done" "round=1 sha=aaa"
r2=$(planner_stop_describe_json "$INIT" | jq -r '.round')
if [ "$r1" = "1" ] && [ "$r2" = "2" ]; then
  pass "ROUND is one more than the count of META|human-hold|done lines"
else
  fail "ROUND is one more than the count of META|human-hold|done lines" "r1=$r1 r2=$r2"
fi

if planner_stop_describe "$INIT" | grep -qx 'QUESTION_1_ID: create'; then
  pass "question ids do not change between rounds"
else
  fail "question ids do not change between rounds" "$(planner_stop_describe "$INIT")"
fi

# ── CLI ────────────────────────────────────────────────────────────────────

echo "--- CLI ---"

if [ "$(bash "${LIB_DIR}/planner-stop-describe.sh" "$INIT" | head -1)" = "=== HUMAN_HOLD ===" ] &&
  bash "${LIB_DIR}/planner-stop-describe.sh" "$INIT" --json | jq -e '.reason == "CREATE_GATE"' >/dev/null; then
  pass "CLI prints the block, and the model with --json"
else
  fail "CLI prints the block, and the model with --json" "unexpected CLI output"
fi

if ! bash "${LIB_DIR}/planner-stop-describe.sh" "INIT-does-not-exist" >/dev/null 2>&1; then
  pass "CLI fails for an initiative with no state log"
else
  fail "CLI fails for an initiative with no state log" "exit 0"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
