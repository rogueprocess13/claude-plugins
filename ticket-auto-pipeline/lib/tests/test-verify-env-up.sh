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
  cat >>"$WS/lib/seed-apply.sh" <<'STUB'
if [ -n "${STUB_SEED_RC:-}" ]; then
  seed_apply() {
    SEED_APPLY_MSG="${STUB_SEED_MSG:-}"
    return "$STUB_SEED_RC"
  }
fi
STUB
  ln -s "$WS/lib" "$WS/home/.claude/skills/lib"
  mkdir -p "$WS/home/.claude/skills/ticket-flow" "$WS/tickets"
  cp "$VE_LIB_DIR/../skills/ticket-flow/workflow.json" "$WS/home/.claude/skills/ticket-flow/"
  export FLEET_PIPELINE_LOG_DIR="$WS/logs"
  # env-start.sh stub: records its args and the verify exports, sleeps
  # STUB_ENVSTART_SLEEP, exits STUB_ENVSTART_RC.
  cat >"$WS/tickets/env-start.sh" <<'STUB'
#!/usr/bin/env bash
# reads VERIFY_REPO_PATH_*
{
  echo "args: $*"
  env | grep -E '^(VERIFY_TICKET_ID|VERIFY_REPO_PATH_)' | sort
} >>"${STUB_CALLS:-/dev/null}"
[ -n "${STUB_ENVSTART_SLEEP:-}" ] && sleep "$STUB_ENVSTART_SLEEP"
exit "${STUB_ENVSTART_RC:-0}"
STUB
  export STUB_CALLS="$WS/env-start.calls"
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
# Worktree cases (stage 2).
VE_WT_CASES="wt_two wt_fallback wt_none wt_bad_branch wt_no_repos_root wt_wired"
VE_BRANCH="feat/T-4-fix"

_mk_repo() { # name: a repo under $WS/repos with $VE_BRANCH pushed to its origin
  local r="$WS/repos/$1" o="$WS/origins/$1.git"
  mkdir -p "$r" "$WS/origins"
  git init -q -b main "$r" 2>/dev/null || git init -q "$r"
  git -C "$r" config user.email t@t
  git -C "$r" config user.name T
  echo hi >"$r/README.md"
  git -C "$r" add -A
  git -C "$r" commit -qm init --no-gpg-sign
  git init -q --bare "$o"
  git -C "$r" remote add origin "$o"
  git -C "$r" push -q origin main 2>/dev/null
  git -C "$r" checkout -qb "$VE_BRANCH"
  echo change >"$r/f.txt"
  git -C "$r" add -A
  git -C "$r" commit -qm change --no-gpg-sign
  git -C "$r" push -q origin "$VE_BRANCH" 2>/dev/null
  git -C "$r" checkout -q main
}

# Sets WT_SERVICES (what the old block's placeholder held), WT_ARGS (the
# script's extra flags) and WT_BRANCH.
_wt_case() {
  WT_BRANCH="$VE_BRANCH" WT_ARGS=() WT_SERVICES=""
  printf '#!/bin/sh\necho start\n' >"$WS/tickets/env-start.sh"
  case "$1" in
  wt_two)
    _mk_repo svc-a
    _mk_repo svc-b
    WT_SERVICES="svc-a svc-b"
    WT_ARGS=(--services "svc-a svc-b")
    ;;
  wt_fallback)
    _mk_repo svc-a
    _mk_repo svc-b
    mkdir -p "$WS/repos/not-a-repo"
    WT_SERVICES="svc-a svc-b"
    ;;
  wt_none)
    WT_SERVICES="nope"
    WT_ARGS=(--services "nope")
    ;;
  wt_bad_branch)
    _mk_repo svc-a
    WT_BRANCH="feat/T-4-missing"
    WT_SERVICES="svc-a"
    WT_ARGS=(--services "svc-a")
    ;;
  wt_no_repos_root)
    printf 'LOCAL_URL = http://localhost:3000\n' >"$WS/CLAUDE.md"
    WT_SERVICES="svc-a"
    WT_ARGS=(--services "svc-a")
    ;;
  wt_wired)
    _mk_repo svc-a
    printf '#!/bin/sh\n: "${VERIFY_REPO_PATH_SVC_A:-}"\n' >"$WS/tickets/env-start.sh"
    WT_SERVICES="svc-a"
    WT_ARGS=(--services "svc-a")
    ;;
  esac
}

# up cases (stage 3). Sets UP_SERVICES and the stub env.
VE_UP_CASES="up_ok_all up_ok_services up_envstart_fail up_served_wrong up_seed_fail up_lock_busy"
_up_case() {
  UP_SERVICES=""
  _mk_repo svc-a
  _mk_repo svc-b
  export STUB_SERVED_RC=0 STUB_SERVED_MSG='port 3000: ok' STUB_PORTS=3000
  case "$1" in
  up_ok_services) UP_SERVICES="svc-a" ;;
  up_envstart_fail) export STUB_ENVSTART_RC=7 ;;
  up_served_wrong) export STUB_SERVED_RC=1 STUB_SERVED_MSG='port 3000: other checkout' ;;
  up_seed_fail) export STUB_SEED_RC=1 STUB_SEED_MSG='T-3: make seed-demo exited 2' ;;
  up_lock_busy)
    (VERIFY_LOCK_OWNER_PID=$$ source "$WS/lib/verify-lock.sh" && verify_lock_acquire T-9 5) >/dev/null 2>&1
    export VERIFY_LOCK_TIMEOUT_SECS=1
    ;;
  esac
}
_up_unenv() { unset STUB_SERVED_RC STUB_SERVED_MSG STUB_PORTS STUB_ENVSTART_RC STUB_SEED_RC STUB_SEED_MSG STUB_ENVSTART_SLEEP; }
_lock_ticket() { sed -n 's/^ticket=//p' "$VERIFY_LOCK_FILE.info" 2>/dev/null || true; }
_outbox() { jq -c '[.event, .data.reason]' "$WS/logs/$TID-outbox.jsonl" 2>/dev/null || true; }

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

echo "=== stage 2: worktrees parity with the Step 1.6a4 block ==="
for c in $VE_WT_CASES; do
  _ws_new
  _lock_take
  _wt_case "$c"
  rc=0
  (cd "$WS" && bash "$VEU" worktrees "$TID" --branch "$WT_BRANCH" "${WT_ARGS[@]}" --tickets-root "$WS/tickets") 2>"$WS/err" || rc=$?
  _same "$c: log" "$(cat "$VE_FX/$c.log")" "$(_mask <"$TAP_LOG")"
  _same "$c: exit" "$(cat "$VE_FX/$c.rc")" "$rc"
  held=free
  _lock_held && held=held
  _same "$c: lock" "$(cat "$VE_FX/$c.lock")" "$held"
  case "$c" in
  wt_two | wt_fallback)
    [ -d "$WS/repos/.verify-worktrees/svc-a/$TID" ] && [ -d "$WS/repos/.verify-worktrees/svc-b/$TID" ] &&
      _ok "$c: both worktrees exist" || _ko "$c: worktrees missing"
    [ "$(git -C "$WS/repos/.verify-worktrees/svc-a/$TID" rev-parse HEAD)" = "$(git -C "$WS/repos/svc-a" rev-parse "$VE_BRANCH")" ] &&
      _ok "$c: worktree is at the ticket branch" || _ko "$c: worktree HEAD"
    ;;
  esac
  _ws_rm
done

echo "=== stage 3: up parity with Steps 1.6a3 to 1.6c ==="
for c in $VE_UP_CASES; do
  _ws_new
  _up_case "$c"
  rc=0
  (cd "$WS" && bash "$VEU" up "$TID" --branch "$VE_BRANCH" --services "$UP_SERVICES" --tickets-root "$WS/tickets" --local-url "http://localhost:3000") 2>"$WS/err" || rc=$?
  _up_unenv
  _same "$c: log" "$(cat "$VE_FX/$c.log")" "$(_mask <"$TAP_LOG")"
  _same "$c: exit" "$(cat "$VE_FX/$c.rc")" "$rc"
  _same "$c: lock holder" "$(cat "$VE_FX/$c.lock")" "$(_lock_ticket)"
  calls=""
  [ -f "$STUB_CALLS" ] && calls=$(_mask <"$STUB_CALLS")
  _same "$c: env-start calls" "$(cat "$VE_FX/$c.calls")" "$calls"
  _same "$c: outbox" "$(cat "$VE_FX/$c.outbox")" "$(_outbox)"
  _ws_rm
done

echo "=== stage 3: the lock is released on every exit path ==="
# SIGTERM while env-start.sh runs: the trap releases the lock and stops the child.
_ws_new
_up_case up_ok_all
export STUB_ENVSTART_SLEEP=30
(cd "$WS" && exec bash "$VEU" up "$TID" --branch "$VE_BRANCH" --tickets-root "$WS/tickets" --local-url "http://localhost:3000") 2>/dev/null &
pid=$!
for _ in $(seq 1 100); do
  [ -s "$STUB_CALLS" ] && break
  sleep 0.1
done
[ "$(_lock_ticket)" = "$TID" ] && _ok "mid-run: lock held while env-start.sh runs" || _ko "mid-run: lock not held"
kill -TERM "$pid"
rc=0
wait "$pid" || rc=$?
_up_unenv
_same "SIGTERM mid-run -> exit 143" 143 "$rc"
sleep 1
_lock_held && _ko "SIGTERM mid-run: lock still held" || _ok "SIGTERM mid-run: lock released"
pgrep -f "sleep 30" >/dev/null 2>&1 && pgrep -f "$WS/tickets/env-start.sh" >/dev/null 2>&1 &&
  _ko "SIGTERM mid-run: env-start.sh child left running" || _ok "SIGTERM mid-run: env-start.sh child stopped"
_ws_rm

# SIGTERM while waiting for another ticket's lock: that lock is never touched.
_ws_new
(VERIFY_LOCK_OWNER_PID=$$ source "$WS/lib/verify-lock.sh" && verify_lock_acquire T-9 5) >/dev/null 2>&1
export VERIFY_LOCK_TIMEOUT_SECS=30
(cd "$WS" && exec bash "$VEU" up "$TID" --branch "$VE_BRANCH" --tickets-root "$WS/tickets" --local-url "http://localhost:3000") 2>/dev/null &
pid=$!
sleep 2
kill -TERM "$pid"
wait "$pid" || true
_same "SIGTERM while queued: the other ticket keeps its lock" T-9 "$(_lock_ticket)"
[ ! -s "$STUB_CALLS" ] && [ ! -d "$WS/repos/.verify-worktrees" ] &&
  _ok "SIGTERM while queued: no worktree resync, no env-start before the lock" || _ko "work done before the lock"
_ws_rm

# lock alone (resume past Step 1.6).
_ws_new
rc=0
(cd "$WS" && bash "$VEU" lock "$TID") 2>/dev/null || rc=$?
_same "lock: acquires and logs" "0|TS|VERIFY|verify-lock|done|acquired" "$rc|$(_mask <"$TAP_LOG")"
_same "lock: still held after the call returns" "$TID" "$(_lock_ticket)"
_ws_rm

echo "=== usage ==="
_ws_new
rc=0
bash "$VEU" served-check >/dev/null 2>&1 || rc=$?
_same "served-check without a ticket -> exit 2" 2 "$rc"
rc=0
bash "$VEU" bogus "$TID" >/dev/null 2>&1 || rc=$?
_same "unknown subcommand -> exit 2" 2 "$rc"
rc=0
bash "$VEU" worktrees "$TID" >/dev/null 2>&1 || rc=$?
_same "worktrees without --branch -> exit 2" 2 "$rc"
rc=0
bash "$VEU" up "$TID" --branch b >/dev/null 2>&1 || rc=$?
_same "up without --tickets-root -> exit 2" 2 "$rc"
_ws_rm

echo ""
echo "verify-env-up: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
