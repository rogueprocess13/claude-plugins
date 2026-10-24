#!/usr/bin/env bash
# test-planner-consensus-gate.sh — Tests for planner-consensus-gate.sh
# (DET-PL-11: Consensus `Readiness: blocked` was never read, so a blocked
# plan went on to Crosscheck and, with --create, into Linear).
#
# Pinned here:
#   1. The Readiness parse: label and heading forms, bold/backticks/case,
#      fenced lines ignored, the closed value set, missing → rc 1, no file → rc 2.
#   2. The gate: rc 3 only for `blocked`; everything else proceeds (rc 0).
#   3. The describer names CONSENSUS_BLOCKED at position Crosscheck and the
#      block parses as a valid v2 human-hold; after the edit it no longer does.
#
# Every case is guarded on the function it needs, so on a checkout without
# the lib this file prints FAIL lines and a non-zero summary.
#
# Run: bash ticket-planner/lib/tests/test-planner-consensus-gate.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CG_LIB="${LIB_DIR}/planner-consensus-gate.sh"
HOLD_PARSER="${LIB_DIR}/../../ticket-auto-pipeline/lib/human-hold-parse.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "$REPOS_ROOT"
export CLAUDE_PLUGIN_ROOT
CLAUDE_PLUGIN_ROOT="$(cd "$LIB_DIR/.." && pwd)"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
[ -f "$CG_LIB" ] && source "$CG_LIB"
source "${LIB_DIR}/planner-stop-describe.sh"

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
need() {
  local name="$1" fn
  shift
  for fn in "$@"; do
    if ! declare -f "$fn" >/dev/null; then
      fail "$name" "$fn missing"
      return 1
    fi
  done
  return 0
}

N=0
fresh() {
  N=$((N + 1))
  INIT="INIT-1700000000-$((5000 + N))"
  planner_state_init "$INIT" "classify client documents" >/dev/null
  IDIR=$(planner_initiative_dir "$INIT")
  CONS="${IDIR}/artifacts/consensus.md"
}

# readiness_case <name> <expected value|rc:N> — consensus.md from stdin
readiness_case() {
  local name="$1" want="$2" got rc=0
  fresh
  cat >"$CONS"
  need "$name" planner_consensus_readiness || return 0
  got=$(planner_consensus_readiness "$INIT") || rc=$?
  if [ "${want#rc:}" != "$want" ]; then
    [ "$rc" = "${want#rc:}" ] && pass "$name" || fail "$name" "rc=$rc got='$got'"
  else
    [ "$rc" = 0 ] && [ "$got" = "$want" ] && pass "$name" || fail "$name" "rc=$rc got='$got'"
  fi
}

echo "=== planner-consensus-gate tests ==="
echo "--- readiness parse ---"

readiness_case "bold label: **Readiness:** blocked" blocked <<'EOF'
# Consensus
**Readiness:** blocked — R1 unresolved
EOF
readiness_case "list label with em dash: - **Readiness** — blocked" blocked <<'EOF'
- **Findings Addressed** — 3 accepted
- **Readiness** — blocked: needs a data-owner decision
EOF
readiness_case "heading form, next non-blank line" blocked <<'EOF'
## Readiness

Blocked. The tenant-scoping finding has no safe resolution.
EOF
readiness_case "backticked, mixed case" blocked <<'EOF'
Readiness: `BLOCKED`
EOF
readiness_case "ready-for-spec" ready-for-spec <<'EOF'
## Readiness
**ready-for-spec** — all findings resolved
EOF
readiness_case "ready for spec (spaces)" ready-for-spec <<'EOF'
**Readiness:** Ready for spec
EOF
readiness_case "needs-further-discovery" needs-further-discovery <<'EOF'
**Readiness:** needs-further-discovery
EOF
readiness_case "fenced example ignored" ready-for-spec <<'EOF'
```
**Readiness:** blocked
```
**Readiness:** ready-for-spec
EOF
readiness_case "field missing → rc 1" rc:1 <<'EOF'
# Consensus
## Findings Addressed
- R1 accepted; nothing about readiness here, not even blocked.
EOF
readiness_case "value outside the set → rc 1" rc:1 <<'EOF'
**Readiness:** mostly fine
EOF
readiness_case "'blockedness' is not blocked" rc:1 <<'EOF'
**Readiness:** blockedness unclear
EOF

fresh
if need "no consensus.md → rc 2" planner_consensus_readiness; then
  rc=0
  planner_consensus_readiness "$INIT" >/dev/null || rc=$?
  [ "$rc" = 2 ] && pass "no consensus.md → rc 2" || fail "no consensus.md → rc 2" "rc=$rc"
fi

echo "--- gate ---"
gate_case() {
  local name="$1" want="$2" rc=0
  fresh
  cat >"$CONS"
  need "$name" planner_consensus_gate || return 0
  planner_consensus_gate "$INIT" || rc=$?
  [ "$rc" = "$want" ] && pass "$name" || fail "$name" "rc=$rc"
}
gate_case "blocked → rc 3" 3 <<<'**Readiness:** blocked'
gate_case "ready-for-spec → rc 0" 0 <<<'**Readiness:** ready-for-spec'
gate_case "needs-further-discovery → rc 0 (proceeds as before)" 0 <<<'**Readiness:** needs-further-discovery'
gate_case "missing field → rc 0 (proceeds as before)" 0 <<<'# Consensus'
fresh
if need "gate: no consensus.md → rc 0" planner_consensus_gate; then
  rc=0
  planner_consensus_gate "$INIT" || rc=$?
  [ "$rc" = 0 ] && pass "gate: no consensus.md → rc 0" || fail "gate: no consensus.md → rc 0" "rc=$rc"
fi
# set -euo pipefail caller survives rc 3 when it captures it the SKILL way
fresh
echo '**Readiness:** blocked' >"$CONS"
out=$(bash -c 'set -euo pipefail; source "$1"; _cg_rc=0; planner_consensus_gate "$2" || _cg_rc=$?; echo "rc=$_cg_rc"' _ "$CG_LIB" "$INIT" 2>&1)
[ "$out" = "rc=3" ] && pass "strict-mode caller captures rc 3" || fail "strict-mode caller captures rc 3" "$out"

echo "--- describer ---"
fresh
for p in Appraisal Discovery Architecture Specify Review Consensus; do
  planner_state_write "$INIT" "$p" "run" "start" "fixture"
  planner_state_write "$INIT" "$p" "run" "done" "fixture"
done
printf '## Readiness\nblocked — R1 needs a decision\n' >"$CONS"
got=$(planner_stop_describe_json "$INIT" | jq -r '.reason')
[ "$got" = CONSENSUS_BLOCKED ] && pass "describer names CONSENSUS_BLOCKED at Crosscheck" ||
  fail "describer names CONSENSUS_BLOCKED at Crosscheck" "got '$got'"
planner_stop_describe "$INIT" >"${WORK}/cb.hold"
parsed=$(bash "$HOLD_PARSER" --phase PLANNER --return-file "${WORK}/cb.hold" 2>&1)
if [ "$(printf '%s' "$parsed" | jq -r '.parse_status' 2>/dev/null)" = ok ] &&
  [ "$(printf '%s' "$parsed" | jq -r '.reason')" = CONSENSUS_BLOCKED ] &&
  [ "$(printf '%s' "$parsed" | jq -r '.questions[0].binding')" = note ]; then
  pass "CONSENSUS_BLOCKED block parses as a valid v2 human-hold"
else
  fail "CONSENSUS_BLOCKED block parses as a valid v2 human-hold" "$parsed"
fi
printf '## Readiness\nready-for-spec\n' >"$CONS"
got=$(planner_stop_describe_json "$INIT" | jq -r '.reason')
[ "$got" != CONSENSUS_BLOCKED ] && pass "after the edit the describer no longer holds ($got)" ||
  fail "after the edit the describer no longer holds" "got '$got'"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
