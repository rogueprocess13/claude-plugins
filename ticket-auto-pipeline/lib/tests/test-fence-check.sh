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
  # A fleetd worker (FLEET_WORKER_PID set) with no generation token is
  # refused: it is a fenced participant that lost its token.
  FLEET_WORKER_PID=$$ check_generation_fence "T-1" "" "$_ws/state"
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

# ── non-participant: no generation AND not a fleetd worker ─────────────────
# A human at a terminal (/ticket-approve) or fleetd itself (gate_hold.py's
# needs-info-resolved) carries neither FLEET_WORKER_PID nor FLEET_GENERATION.
# It was never a fleetd generation, so it cannot be a superseded one
# (review ARCH-1). Before the fix it was refused with 9 forever, because the
# fence marker is never cleared.
test_non_participant_allowed_on_fenced_ticket() {
  _setup
  _write_fence "T-1" 3
  local rc=0 st
  (
    unset FLEET_WORKER_PID
    check_generation_fence "T-1" "" "$_ws/state" || exit $?
    [ "$FENCE_CHECK_STATUS" = "non-participant" ]
  ) || rc=$?
  _teardown
  [ "$rc" -eq 0 ]
}

# ── malformed values must refuse, never fail open (review QA-6) ────────────
test_non_numeric_caller_generation_refused() {
  _setup
  _write_fence "T-1" 5
  local ok=0 g rc
  for g in abc -1x 7.5 " 9"; do
    rc=0
    check_generation_fence "T-1" "$g" "$_ws/state" || rc=$?
    if [ "$rc" -ne 10 ] || [ "$FENCE_CHECK_STATUS" != "malformed" ]; then
      echo "  caller generation '$g' -> rc=$rc status=$FENCE_CHECK_STATUS" >&2
      ok=1
    fi
  done
  _teardown
  return $ok
}

test_non_integer_fenced_value_refused() {
  _setup
  mkdir -p "$_ws/state"
  echo '{"fenced_generation":5.5}' >"$_ws/state/T-1-fence"
  local rc=0
  check_generation_fence "T-1" "2" "$_ws/state" || rc=$?
  local st="$FENCE_CHECK_STATUS"
  _teardown
  [ "$rc" -eq 10 ] && [ "$st" = "malformed" ]
}

test_corrupt_fence_file_refused() {
  _setup
  mkdir -p "$_ws/state"
  printf '{"fenced_generation":' >"$_ws/state/T-1-fence"
  local rc=0
  check_generation_fence "T-1" "2" "$_ws/state" || rc=$?
  local st="$FENCE_CHECK_STATUS"
  _teardown
  [ "$rc" -eq 10 ] && [ "$st" = "malformed" ]
}

# The CLI must print its verdict even when it refuses (it used to exit
# under set -e before echoing anything).
test_cli_prints_status_on_refusal() {
  _setup
  _write_fence "T-1" 5
  local out rc=0
  out=$(FLEET_FENCE_ENFORCE=true bash "$FC" "T-1" "2" "$_ws/state" 2>/dev/null) || rc=$?
  _teardown
  [ "$rc" -eq 10 ] && printf '%s\n' "$out" | grep -qx 'FENCE_CHECK_STATUS=superseded'
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
_run "non-participant (no worker pid, no generation) allowed" test_non_participant_allowed_on_fenced_ticket
_run "non-numeric caller generation -> refused (10)" test_non_numeric_caller_generation_refused
_run "non-integer fenced value -> refused (10)" test_non_integer_fenced_value_refused
_run "corrupt fence file -> refused (10)" test_corrupt_fence_file_refused
_run "CLI prints status on refusal" test_cli_prints_status_on_refusal

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
