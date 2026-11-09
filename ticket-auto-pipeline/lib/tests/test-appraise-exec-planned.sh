#!/usr/bin/env bash
# test-appraise-exec-planned.sh — unit tests for lib/appraise-exec-planned.sh
# Usage: bash test-appraise-exec-planned.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ───────────────────────────────────────────────────
if ! declare -f get_issue >/dev/null 2>&1; then
  get_issue() { echo '{"description":"","labels":{"nodes":[]}}'; }
fi
if ! declare -f _plog >/dev/null 2>&1; then
  _plog() { :; }
fi

# Own scratch root: never an inherited REPOS_ROOT (this test rm -rf's its
# .ticket-auto) and never a fixed path a parallel test also writes.
REPOS_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/test-repos-root.XXXXXX")
export REPOS_ROOT
trap 'rm -rf "$REPOS_ROOT"' EXIT

source "$LIB_DIR/planned-ticket-check.sh"
source "$LIB_DIR/planner-artifacts.sh"
source "$LIB_DIR/appraise-exec-planned.sh"

PASS=0
FAIL=0

# _run_in_dir <work-dir> <func> <args...>
# Runs a function inside a temp directory, capturing its exit code.
# Works around set -e by using set +e inside the subshell.
_run_in_dir() {
  local dir="$1" func="$2"
  shift 2
  (
    set +e
    cd "$dir"
    "$func" "$@" 2>/dev/null
  )
}

# ── Setup test plane ─────────────────────────────────────────────────────────

PLANE_DIR="$REPOS_ROOT/.ticket-auto/initiatives/INIT-42/tickets/TEST-1/planner"
rm -rf "$PLANE_DIR"
mkdir -p "$PLANE_DIR"
echo "# Planner Proposal for TEST-1" >"$PLANE_DIR/proposal.md"

# Stub planner-artifacts functions to use the test plane directly (bypasses
# get_issue → description → Planner Context block chain that can't resolve
# in CI with the empty-description get_issue stub).
has_planner_proposal() {
  [ -f "$PLANE_DIR/proposal.md" ]
}
resolve_planner_dir() {
  if [ -d "$PLANE_DIR" ]; then
    echo "$PLANE_DIR"
    return 0
  fi
  return 1
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# Test 1: Successful proposal adoption
WORK_DIR=$(mktemp -d)
rc=0
_run_in_dir "$WORK_DIR" adopt_planner_proposal "TEST-1" "test-1-fix-bug" "$WORK_DIR/TEST-1-pipeline.log" || rc=$?
if [ "$rc" = "0" ] && [ -f "$WORK_DIR/openspec/changes/test-1-fix-bug/proposal.md" ]; then
  echo "PASS: successful proposal adoption (exit=0, file created)"
  ((PASS++)) || true
else
  echo "FAIL: successful proposal adoption (exit=$rc, file=$(ls "$WORK_DIR/openspec/changes/test-1-fix-bug/proposal.md" 2>/dev/null || echo 'missing'))"
  ((FAIL++)) || true
fi
rm -rf "$WORK_DIR"

# Test 2: No proposal → exit 1
rm -f "$PLANE_DIR/proposal.md"
WORK_DIR=$(mktemp -d)
rc=0
_run_in_dir "$WORK_DIR" adopt_planner_proposal "TEST-1" "test-1-fix" "" || rc=$?
[ "$rc" = "1" ] && echo "PASS: no proposal → exit 1" && ((PASS++)) || true
[ "$rc" != "1" ] && echo "FAIL: no proposal → exit $rc (expected 1)" && ((FAIL++)) || true
rm -rf "$WORK_DIR"

# Test 3: Missing args → exit 1
rc=0
adopt_planner_proposal "" "name" 2>/dev/null || rc=$?
[ "$rc" = "1" ] && echo "PASS: missing ticket-id → exit 1" && ((PASS++)) || true
[ "$rc" != "1" ] && echo "FAIL: missing ticket-id → exit $rc (expected 1)" && ((FAIL++)) || true

# Test 4: resolve_planner_dir fails → exit 2
# Restore proposal so has_planner_proposal returns true
echo "# Restored" >"$PLANE_DIR/proposal.md"
WORK_DIR=$(mktemp -d)
rc=0
# Override resolve_planner_dir to simulate failure
resolve_planner_dir() {
  echo "mock failure" >&2
  return 2
}
_run_in_dir "$WORK_DIR" adopt_planner_proposal "TEST-FAIL" "test-fail" "" || rc=$?
[ "$rc" = "2" ] && echo "PASS: resolve failure → exit 2" && ((PASS++)) || true
[ "$rc" != "2" ] && echo "FAIL: resolve failure → exit $rc (expected 2)" && ((FAIL++)) || true
rm -rf "$WORK_DIR"

# Restore stubs for Test 5
has_planner_proposal() {
  [ -f "$PLANE_DIR/proposal.md" ]
}
resolve_planner_dir() {
  if [ -d "$PLANE_DIR" ]; then
    echo "$PLANE_DIR"
    return 0
  fi
  return 1
}

# Test 5: Log file written on successful adoption
WORK_DIR=$(mktemp -d)
LOG_DIR=$(mktemp -d)
LOG_FILE="$LOG_DIR/TEST-1-pipeline.log"
rc=0
_run_in_dir "$WORK_DIR" adopt_planner_proposal "TEST-1" "test-1-log" "$LOG_FILE" || rc=$?
if [ "$rc" = "0" ] && [ -f "$LOG_FILE" ] && grep -q "planner proposal reused" "$LOG_FILE"; then
  echo "PASS: log file written with adoption marker"
  ((PASS++)) || true
else
  echo "FAIL: log file missing or missing adoption marker (rc=$rc)"
  ((FAIL++)) || true
fi
rm -rf "$WORK_DIR"

# Test 6 (GitHub #624): the log path must be a *-pipeline.log that is not a
# symlink, and an existing file must be ours and not group/other writable.
# Each case must refuse with exit 2 and leave the target untouched.
VICTIM="$LOG_DIR/victim.txt"
echo "keep" >"$VICTIM"
ln -s "$VICTIM" "$LOG_DIR/LINK-pipeline.log"
echo "x" >"$LOG_DIR/LOOSE-pipeline.log"
chmod 666 "$LOG_DIR/LOOSE-pipeline.log"
for bad in "$LOG_DIR/not-a-log.txt" "$LOG_DIR/LINK-pipeline.log" "$LOG_DIR/LOOSE-pipeline.log"; do
  WORK_DIR=$(mktemp -d)
  rc=0
  _run_in_dir "$WORK_DIR" adopt_planner_proposal "TEST-1" "test-1-bad" "$bad" 2>/dev/null || rc=$?
  if [ "$rc" = "2" ] && [ "$(cat "$VICTIM")" = "keep" ] && ! grep -q "planner proposal reused" "$bad" 2>/dev/null; then
    echo "PASS: log path refused: $(basename "$bad")"
    ((PASS++)) || true
  else
    echo "FAIL: log path not refused: $(basename "$bad") (rc=$rc)"
    ((FAIL++)) || true
  fi
  rm -rf "$WORK_DIR"
done
# A foreign-owned log cannot be created without root; the -O test sits in the
# same refusal branch as the loose-mode case above.
rm -rf "$LOG_DIR"

# Cleanup
rm -rf "$REPOS_ROOT/.ticket-auto"

# ── Summary ───────────────────────────────────────────────────────────────────

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
