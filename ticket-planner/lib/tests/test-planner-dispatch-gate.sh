#!/usr/bin/env bash
# test-planner-dispatch-gate.sh — planner_dispatch_gate (planner-router.sh)
# and planner_refinement_finish (planner-refinement.sh), the dispatch
# loop's halt blocks moved out of SKILL.md (skill-deterministic-extraction 1).
#
# Parity oracle: fixtures/halt-goldens/, captured from the SKILL.md halt
# blocks run verbatim before the extraction. halt-fixtures.sh now calls these
# functions, so every halt below must still print its golden byte for byte.
# The proceed and error paths the goldens do not cover are asserted directly.
#
# Run: bash ticket-planner/lib/tests/test-planner-dispatch-gate.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
GOLDEN_DIR="${SCRIPT_DIR}/fixtures/halt-goldens"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export CLAUDE_PLUGIN_ROOT
CLAUDE_PLUGIN_ROOT="$(cd "$LIB_DIR/.." && pwd)"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
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

fresh_root() {
  export REPOS_ROOT="${WORK}/repos-$1"
  rm -rf "$REPOS_ROOT"
  mkdir -p "$REPOS_ROOT"
}

# gate_run <gate> <phase> — run planner_dispatch_gate in a subshell; sets
# OUT, ERR, RC.
gate_run() {
  local state_dir
  state_dir=$(planner_initiative_dir "$INIT")
  RC=0
  (planner_dispatch_gate "$1" "$INIT" "$2" "$state_dir") >"${WORK}/g.out" 2>"${WORK}/g.err" || RC=$?
  OUT=$(cat "${WORK}/g.out")
  ERR=$(cat "${WORK}/g.err")
}

echo "=== planner dispatch gate tests ==="

# ── 1. every halt still prints its golden ────────────────────────────────────

echo "--- 1. halts match the goldens captured from SKILL.md ---"

for pair in $HALT_FIXTURE_REASONS; do
  name="${pair%%:*}"
  [ "$name" = project-gate ] && continue # an Epic Gen prompt gate, not a dispatch-loop block
  fresh_root "$name"
  halt_fixture_init "$name" "$INIT" >/dev/null
  halt_fixture_run "$name" "$INIT" "${WORK}/run"
  drift=""
  for ext in out err rc; do
    cmp -s "${WORK}/run/${name}.${ext}" "${GOLDEN_DIR}/${name}.${ext}" || drift="${drift} .${ext}"
  done
  if [ -z "$drift" ]; then
    pass "${name}: halt output matches its golden"
  else
    fail "${name}: halt output matches its golden" "differs in${drift}: $(diff "${WORK}/run/${name}.out" "${GOLDEN_DIR}/${name}.out" | head -5)"
  fi
done

# ── 2. proceed paths: rc 0, nothing printed ──────────────────────────────────

echo "--- 2. gates that do not fire proceed silently ---"

fresh_root proceed
planner_state_init "$INIT" "an idea" >/dev/null
_halt_done "$INIT" Appraisal Discovery Architecture Specify Review Consensus Crosscheck
for args in "pre Appraisal" "pre Crosscheck" "pre Review" "create TicketGen" "adr Architecture" \
  "adr Specify" "stop Review" "consensus Crosscheck" "specify Review"; do
  # shellcheck disable=SC2086
  set -- $args
  [ "$1" = create ] && planner_authorize_create "$INIT" "test" >/dev/null && planner_stop_after_set "$INIT" ""
  gate_run "$1" "$2"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
    pass "planner_dispatch_gate ${args} → rc 0, silent"
  else
    fail "planner_dispatch_gate ${args}" "rc=$RC out='$OUT' err='$ERR'"
  fi
done

# A consensus.md marked ready does not halt Crosscheck.
mkdir -p "$(planner_initiative_dir "$INIT")/artifacts"
printf '# Consensus\n\n**Readiness:** ready-for-spec\n' >"$(planner_initiative_dir "$INIT")/artifacts/consensus.md"
gate_run pre Crosscheck
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "a ready consensus.md proceeds to Crosscheck"
else
  fail "ready consensus proceeds" "rc=$RC out='$OUT'"
fi

# Crosscheck passing (stubbed) proceeds with the run's own output untouched.
(
  planner_crosscheck_run() { echo "crosscheck ran"; }
  gate_run crosscheck Crosscheck
  [ "$RC" -eq 0 ] && [ "$OUT" = "crosscheck ran" ]
) && pass "a passing Crosscheck proceeds (rc 0)" || fail "passing Crosscheck" "did not proceed"

# ── 3. error paths ───────────────────────────────────────────────────────────

echo "--- 3. errors return 1 ---"

mkdir -p "$(planner_initiative_dir "$INIT")/artifacts/proposal.md"
gate_run specify Review
if [ "$RC" -eq 1 ] && [ "$ERR" = "ERROR: Specify decision gate could not read proposal.md" ]; then
  pass "an unreadable proposal.md is an error (rc 1), not a halt"
else
  fail "specify error" "rc=$RC err='$ERR'"
fi
rmdir "$(planner_initiative_dir "$INIT")/artifacts/proposal.md"

gate_run bogus Review
if [ "$RC" -eq 1 ] && [ -n "$ERR" ]; then
  pass "an unknown gate name is rc 1"
else
  fail "unknown gate" "rc=$RC err='$ERR'"
fi

# ── 3b. Specify parameters at the Crosscheck position ────────────────────────

echo "--- 3b. second Specify stop at Crosscheck (planner-specify-parameters) ---"

# param_init <root> <contract|legacy> — Consensus done, an open failure row.
param_init() {
  fresh_root "$1"
  planner_state_init "$INIT" "an idea" >/dev/null
  _halt_done "$INIT" Appraisal Discovery Architecture Specify Review Consensus
  [ "$2" = contract ] && planner_state_write "$INIT" META contract start specify-parameters-v1
  mkdir -p "$(planner_initiative_dir "$INIT")/artifacts"
  cat >"$(planner_initiative_dir "$INIT")/artifacts/proposal.md" <<'PROPOSAL'
# Proposal

## Business Outcomes

### O1
**Outcome:** Finance users export invoices.

## Parameters

| Name | Key | Kind | Default | Value | Source |
|------|-----|------|---------|-------|--------|
| Export failure handling | `export.on_failure` | failure | retry twice, then email the operator | NEEDS_HUMAN_DECISION — what happens when an export fails? | — |
PROPOSAL
}

if declare -f planner_params_scan >/dev/null || [ -f "${LIB_DIR}/planner-specify-params.sh" ]; then
  param_init xc-contract contract
  gate_run pre Crosscheck
  log=$(planner_state_log "$INIT")
  if [ "$RC" -eq 3 ] &&
    [ "$(head -1 <<<"$OUT")" = "Consensus left 1 decision(s) open — this is a second stop, after Consensus and before Crosscheck." ] &&
    grep -qF "  export.on_failure  what happens when an export fails?" <<<"$OUT" &&
    ! grep -q '|Crosscheck|check|start|' "$log"; then
    pass "contract initiative: open row at Crosscheck halts (rc 3), no Crosscheck|check|start"
  else
    fail "contract Crosscheck stop" "rc=$RC out='$(head -3 <<<"$OUT")' err='$ERR'"
  fi

  param_init xc-legacy legacy
  gate_run pre Crosscheck
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
    pass "legacy initiative at Crosscheck: the specify gate does not run"
  else
    fail "legacy Crosscheck" "rc=$RC out='$OUT' err='$ERR'"
  fi

  param_init xc-review contract
  gate_run specify Review
  if [ "$RC" -eq 3 ] && grep -qF "Specify is waiting on 0 business decision(s) and 1 parameter value(s)" <<<"$OUT"; then
    pass "contract initiative at Review: a parameter-only open row halts"
  else
    fail "contract Review stop" "rc=$RC out='$(head -3 <<<"$OUT")'"
  fi

  if declare -f _planner_dispatch_contract_mark >/dev/null; then
    param_init mark legacy
    log=$(planner_state_log "$INIT")
    _planner_dispatch_contract_mark "$INIT" Review
    n0=$(grep -c 'specify-parameters-v1' "$log" || true)
    _planner_dispatch_contract_mark "$INIT" Specify
    _planner_dispatch_contract_mark "$INIT" Specify
    n1=$(grep -c 'specify-parameters-v1' "$log" || true)
    if [ "$n0" -eq 0 ] && [ "$n1" -eq 1 ]; then
      pass "contract mark: only for Specify, exactly once"
    else
      fail "contract mark" "before=$n0 after=$n1"
    fi
  else
    fail "contract mark" "_planner_dispatch_contract_mark missing"
  fi

  param_init mark-pre legacy
  log=$(planner_state_log "$INIT")
  gate_run pre Review
  n0=$(grep -c 'specify-parameters-v1' "$log" || true)
  gate_run pre Specify
  n1=$(grep -c 'specify-parameters-v1' "$log" || true)
  if [ "$RC" -eq 0 ] && [ "$n0" -eq 0 ] && [ "$n1" -eq 1 ]; then
    pass "pre gate writes the contract marker when Specify is next, only then"
  else
    fail "pre gate contract marker" "rc=$RC before=$n0 after=$n1 err='$ERR'"
  fi
else
  fail "second Specify stop" "planner-specify-params.sh missing"
fi

# ── 4. Refinement finish ─────────────────────────────────────────────────────

echo "--- 4. planner_refinement_finish ---"

source "${LIB_DIR}/planner-refinement.sh"

fresh_root after-completed
halt_fixture_init refinement "$INIT" >/dev/null
out=$(
  PLANNER_REFINEMENT_SEMANTIC=false
  planner_refinement_prepare "$INIT" >/dev/null 2>&1 || exit 9
  REFINEMENT_AFTER_COMPLETED=true planner_refinement_finish "$INIT" "$(planner_initiative_dir "$INIT")"
)
rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'not ready after re-running Refinement on a Completed initiative' <<<"$out"; then
  pass "finish after Completed reports without a gate (rc 0)"
else
  fail "finish after Completed" "rc=$rc out='$(head -3 <<<"$out")'"
fi
if ! grep -qF '|Refinement|gate|' "$(planner_state_log "$INIT")"; then
  pass "finish after Completed writes no Refinement|gate line"
else
  fail "finish after Completed gate line" "a Refinement|gate line was written"
fi

echo ""
echo "=== planner dispatch gate: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
