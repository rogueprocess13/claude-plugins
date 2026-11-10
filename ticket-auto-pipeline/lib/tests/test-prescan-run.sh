#!/usr/bin/env bash
# test-prescan-run.sh — unit tests for lib/prescan-run.sh, the ticket-auto
# router's prescan gate (skill-deterministic-extraction 3).
#
# The expected logs in fixtures/prescan-run/ were produced by running the
# pre-extraction ticket-auto SKILL.md prescan blocks (main @ 3f64658) over the
# workspaces built below — never by this script. Timestamps are masked to TS
# and the workspace path to $WS. prescan-check.sh is stubbed through
# PRESCAN_CHECK_SH: a repo named <x>-<status> reports <status>.
#
# Also carries the behavioural replacements for the prescan prose tests that
# lived in test-pipeline-phases.sh (late-resume skip, spawn only for stale,
# success judged by the returned content).
#
# Usage: bash test-prescan-run.sh [test_name_filter]
# With PRESCAN_RUN_TEST_LIB_ONLY=1 the file only defines its helpers.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

PR_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_LIB_DIR="$(cd "$PR_TEST_DIR/.." && pwd)"
PRS="$PR_LIB_DIR/prescan-run.sh"
PR_FX="$PR_TEST_DIR/fixtures/prescan-run"
TID="T-2"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION

# Repos of the full-loop scenario. bb and dd are stale: bb's agent reports
# "scanned", dd's does not; gg is stale but its lock is held by someone else.
PR_REPOS="aa-fresh bb-stale cc-decayed dd-stale ee-missing ff-bogus gg-stale"

_ws_new() {
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/logs" "$WS/home" "$WS/repos"
  mkdir -m 700 "$WS/scratch"
  export WS HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch" CLAUDE_SKILLS_LIB="$PR_LIB_DIR"
  LOG="$WS/logs/$TID-pipeline.log"
  printf '%s\n' '2026-11-10T10:00:00Z|META|schema|info|1' >"$LOG"
  cat >"$WS/check.sh" <<'EOF'
#!/usr/bin/env bash
printf 'PRESCAN_STATUS=%s\nPRESCAN_REASON=stub\nCHANGED_FILES=\nSTALENESS_SCORE=\nDIRTY=false\n' "${1##*-}"
[ "${1##*-}" = fresh ] || exit 1
EOF
  chmod +x "$WS/check.sh"
  export PRESCAN_CHECK_SH="$WS/check.sh"
}
_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }

_mask() {
  sed -e "s|$WS|\$WS|g" \
    -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g' "$1"
}

_repos() { # names...
  local r
  for r in "$@"; do mkdir -p "$WS/repos/$r/.git"; done
}

# The agent's return for a repo: bb scans, everything else fails.
_agent_return() { # slug
  if [ "$1" = bb-stale ]; then
    printf '=== PRESCAN_RESULT ===\n%s: scanned (stale → fresh)\n=== END ===\n' "$1"
  else
    printf '=== PRESCAN_RESULT ===\n%s: failed — docs not written\n=== END ===\n' "$1"
  fi >"$WS/logs/$TID-agent-return.txt"
}

# The spawn_agent_pre call the skill keeps (no heartbeat log, so no pinger).
_pre() { # repo slug status
  (
    source "$PR_LIB_DIR/spawn-helper.sh"
    spawn_agent_pre PHASE=MAINTENANCE STEP=prescan TICKET_ID=$TID \
      LOG_FILE="$LOG" SKILL=/ticket-auto-pipeline:ticket-prescan FLAGS="--from-auto" \
      AGENT_TYPE="ticket-auto-pipeline:ticket-prescan-agent" \
      DESCRIPTION="Refresh prescan docs for $2 ($3)" \
      INSTRUCTIONS="Run /ticket-auto-pipeline:ticket-prescan --from-auto on $1. Repo slug: $2. Cadence: $3." >/dev/null 2>&1
  ) || true
}

_hold_lock() { # slug — holds the slug's lock in this shell (fd in PR_HELD_FD)
  mkdir -p "$WS/repos/.ticket-auto/$1"
  exec {PR_HELD_FD}>"$WS/repos/.ticket-auto/$1/.lock"
  flock -n "$PR_HELD_FD"
}
_drop_lock() { [ -n "${PR_HELD_FD:-}" ] && exec {PR_HELD_FD}>&- || true; }

[ "${PRESCAN_RUN_TEST_LIB_ONLY:-}" = 1 ] && return 0

PASS=0
FAIL=0
FILTER="${1:-}"
_run() {
  local name="$1"
  shift
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return 0
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_same() {
  local want="$PR_FX/$1" got
  got=$(_mask "$2")
  if [ "$got" != "$(cat "$want")" ]; then
    echo "  mismatch vs fixtures/prescan-run/$1:" >&2
    diff <(cat "$want") <(printf '%s\n' "$got") >&2 || true
    return 1
  fi
}

# The router's loop as SKILL.md now runs it: gate → spawn → done → gate --after.
_new_loop() {
  local after=() PRESCAN_REPO PRESCAN_SLUG PRESCAN_STATUS n=0
  while :; do
    eval "$(bash "$PRS" gate --log-file "$LOG" --repos-root "$WS/repos" \
      --branch develop --resume-step STEP_1 "${after[@]}")"
    [ -n "$PRESCAN_REPO" ] || break
    _pre "$PRESCAN_REPO" "$PRESCAN_SLUG" "$PRESCAN_STATUS"
    _agent_return "$PRESCAN_SLUG"
    bash "$PRS" done $TID --slug "$PRESCAN_SLUG" --status "$PRESCAN_STATUS" --log-file "$LOG" >/dev/null 2>&1
    after=(--after "$PRESCAN_REPO")
    n=$((n + 1))
    [ $n -lt 20 ] || return 1
  done
}

test_full_loop() {
  local rc=0
  _ws_new
  # shellcheck disable=SC2086
  _repos $PR_REPOS
  _hold_lock gg-stale
  (cd "$WS" && _new_loop) || rc=1
  _drop_lock
  _same full-loop.log "$LOG" || rc=1
  _ws_rm
  return $rc
}

test_late_resume_skip() {
  local rc=0 out
  _ws_new
  _repos bb-stale
  out=$(bash "$PRS" gate --log-file "$LOG" --repos-root "$WS/repos" --resume-step STEP_5) || rc=1
  grep -qx "PRESCAN_REPO=''" <<<"$out" || rc=1
  _same late-resume.log "$LOG" || rc=1
  # every late step skips; an early one walks the repos
  local s
  for s in STEP_4 STEP_4_5 STEP_4_6 STEP_5_5 STEP_6 done; do
    out=$(bash "$PRS" gate --log-file "$LOG" --repos-root "$WS/repos" --resume-step $s)
    grep -qx "PRESCAN_REPO=''" <<<"$out" || rc=1
  done
  out=$(bash "$PRS" gate --log-file "$LOG" --repos-root "$WS/repos" --resume-step STEP_2_5)
  grep -q "^PRESCAN_REPO=.*bb-stale" <<<"$out" || rc=1
  _ws_rm
  return $rc
}

test_no_repos() {
  local rc=0
  _ws_new
  bash "$PRS" gate --log-file "$LOG" --repos-root "$WS/repos" >/dev/null || rc=1
  _same no-repos.log "$LOG" || rc=1
  _ws_rm
  return $rc
}

# Issue #411 as behaviour: only `stale` is ever offered for a spawn.
test_spawns_only_for_stale() {
  local rc=0 st out
  for st in fresh decayed missing bogus; do
    _ws_new
    _repos "r-$st"
    out=$(bash "$PRS" gate --log-file "$LOG" --repos-root "$WS/repos")
    grep -qx "PRESCAN_REPO=''" <<<"$out" || rc=1
    _ws_rm
  done
  _ws_new
  _repos r-stale
  out=$(bash "$PRS" gate --log-file "$LOG" --repos-root "$WS/repos")
  grep -q '^PRESCAN_STATUS=stale$' <<<"$out" && grep -q '^PRESCAN_SLUG=r-stale$' <<<"$out" || rc=1
  _ws_rm
  return $rc
}

# Success is judged by the returned content, never by spawn_capture's status.
test_done_judged_by_content() {
  local rc=0
  _ws_new
  (cd "$WS" && _agent_return dd-stale && bash "$PRS" done $TID --slug dd-stale --status stale --log-file "$LOG" >/dev/null 2>&1) || rc=1
  grep -q '|MAINTENANCE|prescan|fail|dd-stale prescan failed$' "$LOG" || rc=1
  (cd "$WS" && _agent_return bb-stale && bash "$PRS" done $TID --slug bb-stale --status stale --log-file "$LOG" >/dev/null 2>&1) || rc=1
  grep -q '|MAINTENANCE|prescan|done|bb-stale prescan complete$' "$LOG" || rc=1
  _ws_rm
  return $rc
}

# The lock is released on every exit path, including a kill mid-run: the
# waiting line is written while the lock is held, so a FIFO as the log file
# parks the script there.
test_lock_released_when_killed() {
  local rc=0 pid fifo
  _ws_new
  _repos bb-stale
  fifo="$WS/logs/fifo-pipeline.log"
  mkfifo "$fifo"
  bash "$PRS" gate --log-file "$fifo" --repos-root "$WS/repos" >/dev/null 2>&1 &
  pid=$!
  local lock="$WS/repos/.ticket-auto/bb-stale/.lock" i held=false
  for i in $(seq 1 50); do
    if [ -f "$lock" ] && ! flock -n "$lock" true 2>/dev/null; then
      held=true
      break
    fi
    sleep 0.1
  done
  [ "$held" = true ] || rc=1
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  timeout 2 cat "$fifo" >/dev/null 2>&1 || true # unblock the orphaned writer
  flock -n "$lock" true || rc=1
  _ws_rm
  return $rc
}

test_lock_released_on_normal_exit() {
  local rc=0
  _ws_new
  _repos bb-stale
  bash "$PRS" gate --log-file "$LOG" --repos-root "$WS/repos" >/dev/null || rc=1
  flock -n "$WS/repos/.ticket-auto/bb-stale/.lock" true || rc=1
  _ws_rm
  return $rc
}

test_check_error_is_unknown_not_stale() {
  local rc=0 out
  _ws_new
  _repos aa-stale bb-x
  printf '#!/usr/bin/env bash\ncase "$1" in *aa-stale) echo PRESCAN_STATUS=stale; exit 1;; esac\nexit 2\n' >"$WS/check.sh"
  out=$(bash "$PRS" gate --log-file "$LOG" --repos-root "$WS/repos" --after "$WS/repos/aa-stale")
  grep -qx "PRESCAN_REPO=''" <<<"$out" || rc=1
  grep -q "|MAINTENANCE|prescan|skip|bb-x unknown prescan status '' — not spawning" "$LOG" || rc=1
  _ws_rm
  return $rc
}

test_usage() {
  local rc=0
  bash "$PRS" >/dev/null 2>&1 || rc=$?
  [ $rc = 2 ] || return 1
  rc=0
  bash "$PRS" gate >/dev/null 2>&1 || rc=$?
  [ $rc = 2 ] || return 1
  rc=0
  bash "$PRS" done "{TICKET-ID}" --slug s --log-file x >/dev/null 2>&1 || rc=$?
  [ $rc = 2 ]
}

# The skill keeps the spawn and calls the script for everything else.
test_skill_uses_prescan_run() {
  local skill="$PR_LIB_DIR/../skills/ticket-auto/SKILL.md"
  grep -q 'prescan-run.sh gate' "$skill" &&
    grep -q 'prescan-run.sh done' "$skill" &&
    grep -q 'STEP=prescan' "$skill" &&
    ! grep -q 'flock -n "$lock_fd"' "$skill" &&
    ! grep -q 'grep -q "\$slug: scanned"' "$skill" &&
    ! grep -v '^[[:space:]]*#' "$PRS" | grep -qE 'spawn_agent_pre|subagent_type'
}

_run "full loop matches the pre-extraction blocks" test_full_loop
_run "late resume skips the gate" test_late_resume_skip
_run "no repos under REPOS_ROOT" test_no_repos
_run "#411: only stale repos are offered for a spawn" test_spawns_only_for_stale
_run "done judges success by returned content" test_done_judged_by_content
_run "lock released when killed mid-run" test_lock_released_when_killed
_run "lock released on normal exit" test_lock_released_on_normal_exit
_run "a failing prescan-check reads as unknown, never stale" test_check_error_is_unknown_not_stale
_run "usage errors exit 2" test_usage
_run "ticket-auto SKILL.md calls prescan-run.sh, keeps the spawn" test_skill_uses_prescan_run

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
