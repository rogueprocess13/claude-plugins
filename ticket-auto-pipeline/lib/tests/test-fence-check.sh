#!/usr/bin/env bash
# test-fence-check.sh — unit tests for lib/fence-check.sh
# Usage: bash test-fence-check.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
FC="$LIB_DIR/fence-check.sh"

source "$FC"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc)"
    ((FAIL++)) || true
  fi
}

_ws=""
_setup() { _ws=$(mktemp -d); }
_teardown() { rm -rf "$_ws" 2>/dev/null || true; }

_write_fence() {
  local tid="$1" gen="$2"
  mkdir -p "$_ws/state"
  jq -n --argjson g "$gen" '{fenced_generation: $g}' >"$_ws/state/${tid}-fence"
}

test_disabled_when_fence_enforce_false() {
  _setup
  FLEET_FENCE_ENFORCE=false check_generation_fence "T-1" "" "$_ws/state"
  local rc=$?
  _teardown
  [ "$rc" -eq 0 ] && [ "$FENCE_CHECK_STATUS" = "disabled" ]
}

test_unfenced_when_no_marker() {
  _setup
  check_generation_fence "T-1" "5" "$_ws/state"
  local rc=$?
  _teardown
  [ "$rc" -eq 0 ] && [ "$FENCE_CHECK_STATUS" = "unfenced" ]
}

test_missing_generation_on_fenced_ticket() {
  _setup
  _write_fence "T-1" 3
  set +e
  check_generation_fence "T-1" "" "$_ws/state"
  local rc=$?
  set -e
  _teardown
  [ "$rc" -eq 9 ] && [ "$FENCE_CHECK_STATUS" = "missing-generation" ] && [ "$FENCE_CHECK_FENCED_GEN" = "3" ]
}

test_superseded_generation_rejected() {
  _setup
  _write_fence "T-1" 5
  set +e
  check_generation_fence "T-1" "5" "$_ws/state"
  local rc=$?
  set -e
  _teardown
  [ "$rc" -eq 10 ] && [ "$FENCE_CHECK_STATUS" = "superseded" ]
}

test_older_generation_rejected() {
  _setup
  _write_fence "T-1" 5
  set +e
  check_generation_fence "T-1" "2" "$_ws/state"
  local rc=$?
  set -e
  _teardown
  [ "$rc" -eq 10 ]
}

test_current_generation_allowed() {
  _setup
  _write_fence "T-1" 5
  check_generation_fence "T-1" "6" "$_ws/state"
  local rc=$?
  _teardown
  [ "$rc" -eq 0 ] && [ "$FENCE_CHECK_STATUS" = "current" ]
}

test_different_tickets_independent() {
  _setup
  _write_fence "T-1" 5
  # T-2 has no fence marker at all — must be unaffected by T-1's.
  check_generation_fence "T-2" "" "$_ws/state"
  local rc=$?
  _teardown
  [ "$rc" -eq 0 ] && [ "$FENCE_CHECK_STATUS" = "unfenced" ]
}

# ── sourcing fence-check.sh must not mutate the caller's shell flags ───────
# fence-check.sh is sourced unconditionally at file scope by lib/events.sh,
# which is itself sourced by epic-branch.sh/fleet-intervene.sh — the same
# leak class fleet-dispatch.sh already works around for linear-api.sh.
test_sourcing_does_not_leak_shell_flags() {
  bash -c "
    source '$FC' >/dev/null 2>&1
    case \$- in
      *e*) exit 1 ;;
    esac
    case \$(set +o | grep -w pipefail) in
      'set +o pipefail') ;;
      *) exit 1 ;;
    esac
    exit 0
  "
}

_run "sourcing fence-check.sh does not leak -e/pipefail" test_sourcing_does_not_leak_shell_flags
_run "disabled when FLEET_FENCE_ENFORCE=false" test_disabled_when_fence_enforce_false
_run "unfenced when no marker file exists" test_unfenced_when_no_marker
_run "missing generation token on fenced ticket -> 9" test_missing_generation_on_fenced_ticket
_run "generation == fenced -> superseded (10)" test_superseded_generation_rejected
_run "generation < fenced -> superseded (10)" test_older_generation_rejected
_run "generation > fenced -> allowed" test_current_generation_allowed
_run "different ticket ids do not share fence state" test_different_tickets_independent

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
