#!/usr/bin/env bash
# test-verify-env-up.sh — lib/verify-env-up.sh, ticket-verify Step 1.6
# bring-up (skill-deterministic-extraction 4, staged).
#
# fixtures/verify-env-up/<case>.log / .err / .rc were produced by running the
# pre-extraction ticket-verify SKILL.md Step 1.6 blocks (main @ eacacbf) over
# the workspaces built below — never by the script. Timestamps are masked to
# TS and the workspace path to $WS.
#
# Each workspace runs a copy of lib/ in $WS/lib, where verify-worktree.sh is
# a thin stub over the real file (verify-worktree-real.sh): with
# STUB_SERVED_RC set it replaces the port probe, so the served-check branches
# run without a listening dev server. The old blocks reached the same copy
# through $HOME/.claude/skills/lib.
#
# With VERIFY_ENV_UP_TEST_LIB_ONLY=1 the file only defines its helpers.
set -eo pipefail

VE_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VE_LIB_DIR="$(cd "$VE_TEST_DIR/.." && pwd)"
VE_FX="$VE_TEST_DIR/fixtures/verify-env-up"
TID="T-4"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION \
  VERIFY_SERVED_PORTS VERIFY_SERVED_WORKTREE_ENFORCE VERIFY_SERVED_WORKTREE_STRICT LINEAR_API_KEY

# Served-check cases: rc, message, extra env.
VE_SERVED_CASES="sv_ok sv_wrong sv_wrong_noenforce sv_noworktree sv_noworktree_strict sv_undecided sv_undecided_strict"

_ws_new() {
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/logs" "$WS/home/.claude/skills" "$WS/repos" "$WS/lib"
  mkdir -m 700 "$WS/scratch"
  cp "$VE_LIB_DIR"/*.sh "$WS/lib/"
  mv "$WS/lib/verify-worktree.sh" "$WS/lib/verify-worktree-real.sh"
  cat >"$WS/lib/verify-worktree.sh" <<'STUB'
source "$(dirname "${BASH_SOURCE[0]}")/verify-worktree-real.sh"
if [ -n "${STUB_SERVED_RC:-}" ]; then
  verify_served_ports() { echo "${STUB_PORTS:-3000}"; }
  verify_served_check_ports() {
    printf '%b' "${STUB_SERVED_MSG:-}"
    return "$STUB_SERVED_RC"
  }
fi
STUB
  ln -s "$WS/lib" "$WS/home/.claude/skills/lib"
  export HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch" CLAUDE_SKILLS_LIB="$WS/lib"
  export VERIFY_LOCK_FILE="$WS/scratch/ticket-verify.lock" VERIFY_LOCK_TIMEOUT_SECS=5 VERIFY_LOCK_OWNER_PID=$$
  export TAP_LOG="$WS/logs/$TID-pipeline.log"
  : >"$TAP_LOG"
  printf 'REPOS_ROOT = %s\nLOCAL_URL = http://localhost:3000\n' "$WS/repos" >"$WS/CLAUDE.md"
  VEU="$WS/lib/verify-env-up.sh"
}
_ws_rm() {
  [ -n "${WS:-}" ] || return 0
  (source "$WS/lib/verify-lock.sh" && verify_lock_release) >/dev/null 2>&1 || true
  rm -rf "$WS" 2>/dev/null || true
}
_mask() { sed -e "s|$WS|\$WS|g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g'; }
_lock_take() { (source "$WS/lib/verify-lock.sh" && verify_lock_acquire "$TID" 5) >/dev/null 2>&1; }
_lock_held() { (source "$WS/lib/verify-lock.sh" && verify_lock_status) >/dev/null 2>&1; }

_sv_env() { # case -> exports STUB_* and policy env
  export STUB_SERVED_MSG='port 3000: pid 42 cwd=/x|y\nbranch=feat/T-4' STUB_PORTS=3000
  case "$1" in
  sv_ok) export STUB_SERVED_RC=0 ;;
  sv_wrong) export STUB_SERVED_RC=1 ;;
  sv_wrong_noenforce) export STUB_SERVED_RC=1 VERIFY_SERVED_WORKTREE_ENFORCE=false ;;
  sv_noworktree) export STUB_SERVED_RC=4 ;;
  sv_noworktree_strict) export STUB_SERVED_RC=4 VERIFY_SERVED_WORKTREE_STRICT=true ;;
  sv_undecided) export STUB_SERVED_RC=3 ;;
  sv_undecided_strict) export STUB_SERVED_RC=3 VERIFY_SERVED_WORKTREE_STRICT=true ;;
  esac
}
_sv_unenv() { unset STUB_SERVED_RC STUB_SERVED_MSG STUB_PORTS VERIFY_SERVED_WORKTREE_ENFORCE VERIFY_SERVED_WORKTREE_STRICT; }

[ "${VERIFY_ENV_UP_TEST_LIB_ONLY:-0}" = 1 ] && return 0

PASS=0 FAIL=0
_ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
_ko() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}
_same() { # label want got
  if [ "$2" = "$3" ]; then _ok "$1"; else
    _ko "$1"
    diff <(echo "$2") <(echo "$3") | sed 's/^/    /' || true
  fi
}

echo "=== stage 1: served-check parity with the Step 1.6b served block ==="
for c in $VE_SERVED_CASES; do
  _ws_new
  _lock_take
  _sv_env "$c"
  rc=0
  (cd "$WS" && bash "$VEU" served-check "$TID" --local-url "http://localhost:3000") 2>"$WS/err" || rc=$?
  _sv_unenv
  _same "$c: log" "$(cat "$VE_FX/$c.log")" "$(_mask <"$TAP_LOG")"
  _same "$c: stderr" "$(cat "$VE_FX/$c.err")" "$(_mask <"$WS/err")"
  _same "$c: exit" "$(cat "$VE_FX/$c.rc")" "$rc"
  held=free
  _lock_held && held=held
  _same "$c: lock" "$(cat "$VE_FX/$c.lock")" "$held"
  _ws_rm
done

echo "=== usage ==="
_ws_new
rc=0
bash "$VEU" served-check >/dev/null 2>&1 || rc=$?
_same "served-check without a ticket -> exit 2" 2 "$rc"
rc=0
bash "$VEU" bogus "$TID" >/dev/null 2>&1 || rc=$?
_same "unknown subcommand -> exit 2" 2 "$rc"
_ws_rm

echo ""
echo "verify-env-up: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
