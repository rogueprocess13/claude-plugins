#!/usr/bin/env bash
# test-verify-lock.sh — unit tests for lib/verify-lock.sh
# Exercises the flock-based single-flight mutex: acquire/release,
# concurrent-acquirer serialization, queued-waiter handoff, the
# crash/max-hold backstop, and status reporting.
# Usage: bash test-verify-lock.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ─────────────────────────────────────────────────
if ! declare -f _plog >/dev/null 2>&1; then
  _plog() { :; }
fi
if ! declare -f hb_gate >/dev/null 2>&1; then
  hb_gate() { :; }
fi

source "$LIB_DIR/config.sh"
source "$LIB_DIR/verify-lock.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_setup_fixture() {
  FIXTURE_DIR=$(mktemp -d)
  export VERIFY_LOCK_FILE="$FIXTURE_DIR/ticket-verify.lock"
  export VERIFY_LOCK_TIMEOUT_SECS=3
  # Small on purpose: bounds how long any straggler holder process from
  # this test can outlive a teardown that (e.g. under scheduler
  # contention) doesn't reach it within the release() grace window —
  # good test hygiene, not something a real verify run needs (config.sh's
  # own default is 3600s).
  export VERIFY_LOCK_MAX_HOLD_SECS=8
  rm -f "$VERIFY_LOCK_FILE" "$VERIFY_LOCK_FILE.holder" "$VERIFY_LOCK_FILE.info" "$VERIFY_LOCK_FILE.stop"
}

_teardown_fixture() {
  verify_lock_release >/dev/null 2>&1 || true
  rm -rf "$FIXTURE_DIR" 2>/dev/null || true
  unset VERIFY_LOCK_FILE VERIFY_LOCK_TIMEOUT_SECS VERIFY_LOCK_MAX_HOLD_SECS
}

echo "=== Core acquire/release ==="
echo ""

test_acquire_then_release() {
  _setup_fixture
  verify_lock_acquire "CRE-1" || {
    _teardown_fixture
    return 1
  }
  [ -f "${VERIFY_LOCK_FILE}.holder" ] || {
    echo "  no token file after acquire" >&2
    _teardown_fixture
    return 1
  }
  verify_lock_release
  [ ! -f "${VERIFY_LOCK_FILE}.holder" ] || {
    echo "  token file survived release" >&2
    _teardown_fixture
    return 1
  }
  _teardown_fixture
  return 0
}
_run "acquire creates token, release clears it" test_acquire_then_release

test_release_idempotent_when_never_acquired() {
  _setup_fixture
  local rc=0
  verify_lock_release || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "  release without a prior acquire should exit 0, got $rc" >&2
    _teardown_fixture
    return 1
  }
  _teardown_fixture
  return 0
}
_run "release with no prior acquire exits 0" test_release_idempotent_when_never_acquired

test_reacquire_after_release() {
  _setup_fixture
  verify_lock_acquire "CRE-1" >/dev/null || {
    _teardown_fixture
    return 1
  }
  verify_lock_release
  verify_lock_acquire "CRE-2" >/dev/null || {
    echo "  second acquire after release failed" >&2
    _teardown_fixture
    return 1
  }
  _teardown_fixture
  return 0
}
_run "lock is reusable — acquire, release, acquire again" test_reacquire_after_release

echo ""
echo "=== Mutual exclusion ==="
echo ""

test_second_acquirer_blocks_and_times_out() {
  _setup_fixture
  verify_lock_acquire "HOLDER" >/dev/null || {
    _teardown_fixture
    return 1
  }

  local start end elapsed rc=0
  start=$(date +%s)
  verify_lock_acquire "WAITER" >/dev/null 2>&1 || rc=$?
  end=$(date +%s)
  elapsed=$((end - start))

  [ "$rc" -ne 0 ] || {
    echo "  second acquirer should have failed while the first still holds the lock" >&2
    _teardown_fixture
    return 1
  }
  # Should time out at ~VERIFY_LOCK_TIMEOUT_SECS (3s), not instantly and
  # not indefinitely.
  [ "$elapsed" -ge 2 ] || {
    echo "  second acquirer failed too fast ($elapsed s) — did it even wait?" >&2
    _teardown_fixture
    return 1
  }
  [ "$elapsed" -le 10 ] || {
    echo "  second acquirer took $elapsed s — should give up near the ${VERIFY_LOCK_TIMEOUT_SECS}s timeout" >&2
    _teardown_fixture
    return 1
  }
  _teardown_fixture
  return 0
}
_run "concurrent acquirer blocks then times out with the lock still held" test_second_acquirer_blocks_and_times_out

test_timeout_message_names_holder() {
  _setup_fixture
  verify_lock_acquire "HOLDER-X" >/dev/null || {
    _teardown_fixture
    return 1
  }
  local err
  err=$(verify_lock_acquire "WAITER" 2>&1 >/dev/null) || true
  echo "$err" | grep -q "HOLDER-X" || {
    echo "  timeout message did not name the current holder: $err" >&2
    _teardown_fixture
    return 1
  }
  _teardown_fixture
  return 0
}
_run "timeout diagnostic names the current holder" test_timeout_message_names_holder

test_release_does_not_disturb_unrelated_live_holder() {
  # Regression: an acquire attempt must never delete another *live*
  # holder's bookkeeping files just because it lost the race — only a
  # dead holder's leftovers are stale.
  _setup_fixture
  verify_lock_acquire "HOLDER" >/dev/null || {
    _teardown_fixture
    return 1
  }
  local holder_pid
  holder_pid=$(cat "${VERIFY_LOCK_FILE}.holder")

  verify_lock_acquire "COMPETITOR" >/dev/null 2>&1 || true

  [ -f "${VERIFY_LOCK_FILE}.holder" ] || {
    echo "  a losing acquirer erased the live holder's token file" >&2
    _teardown_fixture
    return 1
  }
  [ "$(cat "${VERIFY_LOCK_FILE}.holder")" = "$holder_pid" ] || {
    echo "  token file now names a different pid than the original live holder" >&2
    _teardown_fixture
    return 1
  }
  kill -0 "$holder_pid" 2>/dev/null || {
    echo "  original holder process is unexpectedly dead" >&2
    _teardown_fixture
    return 1
  }
  _teardown_fixture
  return 0
}
_run "a losing acquirer never touches a live holder's bookkeeping" test_release_does_not_disturb_unrelated_live_holder

test_release_never_deletes_a_new_holders_bookkeeping_mid_wait() {
  # Regression (Finding 1, adversarial review of PR #338): deterministically
  # reproduces the exact race — a verify_lock_release() call still mid-wait
  # for an OLD holder's token to disappear, while a NEW holder has already
  # won the lock and overwritten token_file/info_file with its own
  # identity. Manufactures the "OLD-HOLDER" bookkeeping directly (bypassing
  # verify_lock_acquire) so there's no real competing background process to
  # race against — this isolates release()'s own identity-check logic from
  # actual `flock` timing, which is what makes the race reproducible on
  # every run rather than only occasionally.
  _setup_fixture
  echo "111111" >"${VERIFY_LOCK_FILE}.holder"
  printf 'ticket=OLD-HOLDER\npid=111111\n' >"${VERIFY_LOCK_FILE}.info"

  verify_lock_release &
  local release_pid=$!

  # Let release() snapshot "111111" (its intended identity), touch
  # stop_file, and enter its poll loop before we pull the rug.
  sleep 0.2

  # Simulate the race: a brand-new holder wins the lock and overwrites the
  # bookkeeping while the backgrounded release() call — still bound to the
  # OLD token by its snapshot — is mid-wait.
  echo "222222" >"${VERIFY_LOCK_FILE}.holder"
  printf 'ticket=NEW-HOLDER\npid=222222\n' >"${VERIFY_LOCK_FILE}.info"

  wait "$release_pid" 2>/dev/null || true

  [ "$(cat "${VERIFY_LOCK_FILE}.holder" 2>/dev/null)" = "222222" ] || {
    echo "  release() deleted or overwrote the NEW holder's token file" >&2
    rm -f "${VERIFY_LOCK_FILE}.holder" "${VERIFY_LOCK_FILE}.info" "${VERIFY_LOCK_FILE}.stop"
    _teardown_fixture
    return 1
  }
  grep -q "NEW-HOLDER" "${VERIFY_LOCK_FILE}.info" 2>/dev/null || {
    echo "  release() deleted or overwrote the NEW holder's info file" >&2
    rm -f "${VERIFY_LOCK_FILE}.holder" "${VERIFY_LOCK_FILE}.info" "${VERIFY_LOCK_FILE}.stop"
    _teardown_fixture
    return 1
  }

  rm -f "${VERIFY_LOCK_FILE}.holder" "${VERIFY_LOCK_FILE}.info" "${VERIFY_LOCK_FILE}.stop"
  _teardown_fixture
  return 0
}
_run "release() never deletes a new holder's bookkeeping mid-wait" test_release_never_deletes_a_new_holders_bookkeeping_mid_wait

echo ""
echo "=== Queued waiter handoff ==="
echo ""

test_waiter_succeeds_once_released() {
  _setup_fixture
  VERIFY_LOCK_TIMEOUT_SECS=20 verify_lock_acquire "HOLDER" >/dev/null || {
    _teardown_fixture
    return 1
  }
  local holder_pid
  holder_pid=$(cat "${VERIFY_LOCK_FILE}.holder" 2>/dev/null)

  (
    sleep 2
    verify_lock_release
  ) &
  local releaser_pid=$!

  local start end elapsed rc=0
  start=$(date +%s)
  VERIFY_LOCK_TIMEOUT_SECS=20 verify_lock_acquire "WAITER" >/dev/null 2>&1 || rc=$?
  end=$(date +%s)
  elapsed=$((end - start))
  wait "$releaser_pid" 2>/dev/null || true

  [ "$rc" -eq 0 ] || {
    echo "  waiter never acquired the lock after it was released" >&2
    _teardown_fixture
    return 1
  }
  [ "$elapsed" -lt 20 ] || {
    echo "  waiter took the full timeout instead of picking up the release" >&2
    _teardown_fixture
    return 1
  }

  # Regression (Finding 1): the OLD holder's verify_lock_release call
  # (backgrounded above, releasing HOLDER) can still be mid-wait at the
  # moment WAITER wins — its release loop must recognize the token no
  # longer names HOLDER and back off, never deleting WAITER's live
  # bookkeeping. Assert WAITER's own token/info are intact well after that
  # backgrounded release call has fully returned (`wait` above already
  # guarantees it has).
  local waiter_pid
  waiter_pid=$(cat "${VERIFY_LOCK_FILE}.holder" 2>/dev/null)
  [ -n "$waiter_pid" ] || {
    echo "  WAITER's token file is missing after HOLDER's release() returned — corrupted by the old release call" >&2
    _teardown_fixture
    return 1
  }
  [ "$waiter_pid" != "$holder_pid" ] || {
    echo "  token file still names HOLDER's pid ($holder_pid) — WAITER never actually became the holder of record" >&2
    _teardown_fixture
    return 1
  }
  kill -0 "$waiter_pid" 2>/dev/null || {
    echo "  WAITER's own holder process is unexpectedly dead" >&2
    _teardown_fixture
    return 1
  }
  grep -q "ticket=WAITER" "${VERIFY_LOCK_FILE}.info" 2>/dev/null || {
    echo "  WAITER's info file is missing or was overwritten/deleted" >&2
    _teardown_fixture
    return 1
  }
  _teardown_fixture
  return 0
}
_run "a queued waiter acquires promptly once the holder releases" test_waiter_succeeds_once_released

echo ""
echo "=== Crash / max-hold backstop ==="
echo ""

test_max_hold_self_expires() {
  _setup_fixture
  VERIFY_LOCK_MAX_HOLD_SECS=2 VERIFY_LOCK_TIMEOUT_SECS=1 verify_lock_acquire "LEAKED" >/dev/null || {
    _teardown_fixture
    return 1
  }
  # Deliberately never call verify_lock_release — simulates a killed agent.
  sleep 4

  local rc=0
  VERIFY_LOCK_TIMEOUT_SECS=5 verify_lock_acquire "AFTER-LEAK" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "  lock did not self-expire past VERIFY_LOCK_MAX_HOLD_SECS" >&2
    _teardown_fixture
    return 1
  }
  _teardown_fixture
  return 0
}
_run "an unreleased lock self-expires past VERIFY_LOCK_MAX_HOLD_SECS" test_max_hold_self_expires

echo ""
echo "=== Status ==="
echo ""

test_status_free() {
  _setup_fixture
  local rc=0
  verify_lock_status >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "  status should report free (exit 1) when never acquired, got $rc" >&2
    _teardown_fixture
    return 1
  }
  _teardown_fixture
  return 0
}
_run "status reports free when not held" test_status_free

test_status_held() {
  _setup_fixture
  verify_lock_acquire "CRE-9" >/dev/null || {
    _teardown_fixture
    return 1
  }
  local rc=0
  local out
  out=$(verify_lock_status) || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "  status should report held (exit 0), got $rc" >&2
    _teardown_fixture
    return 1
  }
  echo "$out" | grep -q "CRE-9" || {
    echo "  status output did not name the holding ticket: $out" >&2
    _teardown_fixture
    return 1
  }
  _teardown_fixture
  return 0
}
_run "status reports the holding ticket when held" test_status_held

echo ""
echo "=== Missing dependency ==="
echo ""

test_missing_flock_binary() {
  _setup_fixture
  local scratch_bin
  scratch_bin=$(mktemp -d)
  local rc=0
  PATH="$scratch_bin" verify_lock_acquire "CRE-1" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "  acquire should fail cleanly when flock is unavailable" >&2
    rm -rf "$scratch_bin"
    _teardown_fixture
    return 1
  }
  rm -rf "$scratch_bin"
  _teardown_fixture
  return 0
}
_run "acquire fails cleanly when 'flock' is not on PATH" test_missing_flock_binary

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
