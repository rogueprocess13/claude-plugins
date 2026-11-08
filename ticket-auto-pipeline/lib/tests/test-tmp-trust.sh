#!/usr/bin/env bash
# test-tmp-trust.sh — GitHub #624: the pipeline's remaining shared-/tmp sites.
#
#   1. verify-lock.sh: the lock lives in the private scratch dir by default;
#      a symlink, a loose mode or a foreign-owned directory at the lock path
#      (or a sidecar) is refused, and nothing is written through a symlink.
#   2. fence-check.sh: the /tmp/<tid>-fence fallback is gone — a fence file
#      planted there is never read; ./logs is the fallback instead.
#   3. Skill prose and libs name no fixed /tmp scratch file any more.
#
# A foreign-owned *file* cannot be created without root. The foreign-owner
# case is exercised through a root-owned directory (/etc) instead, which
# runs through the same refusal as a symlink or a loose mode.
#
# Usage: bash test-tmp-trust.sh
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
REPO_DIR="$(cd "$PLUGIN_DIR/.." && pwd)"

PASS=0
FAIL=0
pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
fail() {
  echo "FAIL: $1${2:+ — $2}"
  ((FAIL++)) || true
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Run one verify-lock call in a fresh shell, so each case starts from clean
# config. Prints "<rc>|<stdout>".
vl() {
  local fn="$1"
  shift
  (
    set +e
    unset VERIFY_LOCK_FILE
    export "$@"
    export VERIFY_LOCK_TIMEOUT_SECS=3 VERIFY_LOCK_MAX_HOLD_SECS=6
    # shellcheck source=../config.sh
    source "$LIB_DIR/config.sh"
    # shellcheck source=../verify-lock.sh
    source "$LIB_DIR/verify-lock.sh"
    out=$("$fn" T-1 2>/dev/null)
    rc=$?
    [ "$fn" = verify_lock_acquire ] && [ "$rc" = 0 ] && verify_lock_release >/dev/null 2>&1
    printf '%s|%s' "$rc" "$out"
  )
}

# ── 1. verify-lock ───────────────────────────────────────────────────────────
mkdir -m 700 "$T/scratch"

# 1a. Default path is the scratch dir, and acquire/release works there.
r=$(
  unset VERIFY_LOCK_FILE
  export TICKET_TMP_DIR="$T/scratch"
  source "$LIB_DIR/config.sh"
  source "$LIB_DIR/verify-lock.sh"
  _verify_lock_file 2>/dev/null
)
[ "$r" = "$T/scratch/ticket-verify.lock" ] && pass "1a: default lock path is in the scratch dir" ||
  fail "1a: default lock path is in the scratch dir" "got '$r'"
r=$(vl verify_lock_acquire TICKET_TMP_DIR="$T/scratch")
[ "${r%%|*}" = 0 ] && pass "1b: acquire/release in the scratch dir" || fail "1b: acquire/release in the scratch dir" "$r"
m=$(stat -c %a "$T/scratch/ticket-verify.lock" 2>/dev/null || stat -f %Lp "$T/scratch/ticket-verify.lock")
[ "$m" = 600 ] && pass "1c: lock file is created 0600" || fail "1c: lock file is created 0600" "mode $m"

# 1d. A loose scratch dir refuses the default lock.
mkdir -m 777 "$T/loose-scratch"
chmod 777 "$T/loose-scratch"
r=$(vl verify_lock_acquire TICKET_TMP_DIR="$T/loose-scratch")
[ "${r%%|*}" = 1 ] && [ ! -e "$T/loose-scratch/ticket-verify.lock" ] &&
  pass "1d: loose scratch dir refused" || fail "1d: loose scratch dir refused" "$r"

# 1e. A symlink at the lock path is refused and its target never written.
mkdir -m 700 "$T/o1"
echo keep >"$T/victim"
ln -s "$T/victim" "$T/o1/ticket-verify.lock"
r=$(vl verify_lock_acquire VERIFY_LOCK_FILE="$T/o1/ticket-verify.lock")
[ "${r%%|*}" = 1 ] && [ "$(cat "$T/victim")" = keep ] &&
  pass "1e: symlinked lock file refused" || fail "1e: symlinked lock file refused" "$r"

# 1f. A symlinked sidecar (.holder) is refused, target untouched.
mkdir -m 700 "$T/o2"
ln -s "$T/victim" "$T/o2/ticket-verify.lock.holder"
r=$(vl verify_lock_acquire VERIFY_LOCK_FILE="$T/o2/ticket-verify.lock")
[ "${r%%|*}" = 1 ] && [ "$(cat "$T/victim")" = keep ] &&
  pass "1f: symlinked .holder refused" || fail "1f: symlinked .holder refused" "$r"

# 1g. A group/other-writable sidecar (.info) is refused.
mkdir -m 700 "$T/o3"
echo "ticket=FORGED" >"$T/o3/ticket-verify.lock.info"
chmod 666 "$T/o3/ticket-verify.lock.info"
r=$(vl verify_lock_acquire VERIFY_LOCK_FILE="$T/o3/ticket-verify.lock")
[ "${r%%|*}" = 1 ] && pass "1g: loose .info refused" || fail "1g: loose .info refused" "$r"

# 1h. A group/other-writable lock directory is refused.
mkdir "$T/o4"
chmod 777 "$T/o4"
r=$(vl verify_lock_acquire VERIFY_LOCK_FILE="$T/o4/ticket-verify.lock")
[ "${r%%|*}" = 1 ] && [ ! -e "$T/o4/ticket-verify.lock" ] &&
  pass "1h: world-writable lock dir refused" || fail "1h: world-writable lock dir refused" "$r"

# 1i. A lock directory owned by someone else is refused.
if [ "$(id -u)" != 0 ] && [ -d /etc ] && [ ! -O /etc ]; then
  r=$(vl verify_lock_acquire VERIFY_LOCK_FILE="/etc/ticket-verify-test-$$.lock")
  [ "${r%%|*}" = 1 ] && pass "1i: foreign-owned lock dir refused" || fail "1i: foreign-owned lock dir refused" "$r"
else
  pass "1i: skipped (running as root)"
fi

# 1j. release on a refused path does nothing (no stop file through the link)
#     and returns 0; status reads a refused path as held (exit 0).
echo keep >"$T/victim"
r=$(vl verify_lock_release VERIFY_LOCK_FILE="$T/o2/ticket-verify.lock")
[ "${r%%|*}" = 0 ] && [ "$(cat "$T/victim")" = keep ] && [ ! -e "$T/o2/ticket-verify.lock.stop" ] &&
  pass "1j: release on a refused path is a no-op" || fail "1j: release on a refused path is a no-op" "$r"
r=$(vl verify_lock_status VERIFY_LOCK_FILE="$T/o2/ticket-verify.lock")
[ "${r%%|*}" = 0 ] && pass "1k: status reports a refused path as held" || fail "1k: status reports a refused path as held" "$r"

# ── 2. fence-check fallback ──────────────────────────────────────────────────
# Copy fence-check.sh where no fleet-config.sh can be found, so the fallback
# branch runs, and point HOME away from any installed plugin.
mkdir -p "$T/iso/lib" "$T/home" "$T/ws/logs"
cp "$LIB_DIR/fence-check.sh" "$T/iso/lib/"
tid="TMPTRUST$$${RANDOM}"
planted="/tmp/${tid}-fence"
fc() {
  (
    cd "$T/ws"
    export HOME="$T/home" FLEET_FENCE_ENFORCE=true FLEET_WORKER_PID=1
    source "$T/iso/lib/fence-check.sh"
    set +e
    check_generation_fence "$tid" 5 "${1:-}"
    printf '%s|%s' "$?" "$FENCE_CHECK_STATUS"
  )
}
if [ ! -e "$planted" ] && [ ! -L "$planted" ]; then
  echo '{"fenced_generation": 99}' >"$planted"
  r=$(fc "")
  rm -f "$planted"
  [ "$r" = "0|unfenced" ] && pass "2a: a fence planted in /tmp is never read" || fail "2a: a fence planted in /tmp is never read" "$r"
else
  fail "2a: could not plant a fresh /tmp fence for the test" "$planted exists"
fi
echo '{"fenced_generation": 99}' >"$T/ws/logs/${tid}-fence"
r=$(fc "")
[ "$r" = "10|superseded" ] && pass "2b: fallback reads ./logs/<tid>-fence" || fail "2b: fallback reads ./logs/<tid>-fence" "$r"
rm -f "$T/ws/logs/${tid}-fence"
mkdir -p "$T/state"
echo '{"fenced_generation": 99}' >"$T/state/${tid}-fence"
r=$(fc "$T/state")
[ "$r" = "10|superseded" ] && pass "2c: fallback honours the caller's state dir" || fail "2c: fallback honours the caller's state dir" "$r"

# ── 3. No fixed /tmp scratch names left in prose or libs ─────────────────────
# Each pattern is a former write target in shared /tmp (GitHub #624).
hits=$(cd "$REPO_DIR" && git grep -nE \
  '/tmp/(ticket-verify|issue-body-|evidence-|claude-log-|gitnexus-(clusters|routes|processes)|ticket-audit-|env-check-output|fleet-env-check-output|fleet-features-output|retro-hist-sorted)|/tmp/\$\{ticket_id\}-fence' \
  -- ticket-auto-pipeline fleet-controller ':!*/tests/*' ':!*CHANGELOG*' ':!*retro.sh' 2>/dev/null || true)
[ -z "$hits" ] && pass "3a: no fixed /tmp scratch names in skills or libs" || fail "3a: no fixed /tmp scratch names in skills or libs" "$hits"
# retro.sh may name its old temp file only in a comment.
hits=$(grep -nE '^[^#]*/tmp/retro-hist' "$PLUGIN_DIR/skills/ticket-retro/retro.sh" || true)
[ -z "$hits" ] && pass "3b: retro.sh writes no /tmp temp file" || fail "3b: retro.sh writes no /tmp temp file" "$hits"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
