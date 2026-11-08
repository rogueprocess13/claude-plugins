#!/usr/bin/env bash
# seed-run.sh — run one seeder command contained: own process group, a
# timeout that kills the whole group, and a sweep afterwards for anything
# the command started that left the group (GitHub #621). Shared by
# lib/seed-precheck.sh (Step 1.6d) and lib/seed-apply.sh (Step 1.6c).
# Sourceable library; sets no shell options at file scope.
#
# Why: a timeout that signals only the direct child (coreutils `timeout`)
# orphans every grandchild, and a process-group kill misses any descendant
# that called setsid (a daemonising tool, `setsid x &`, `nohup` + setsid).
# Such survivors can hold DB connections, ports or locks VERIFY needs next.
#
# Public API:
#   seed_run [--timeout SECS] [--grace SECS] [--cwd DIR] -- CMD [ARGS...]
#     Runs CMD as an argv list (no shell, no eval), stdin from /dev/null,
#     stdout to our stderr, from DIR (default: current dir), as a background
#     job under `set -m` so it leads its own process group. A unique marker,
#     TICKET_SEED_RUN_ID=<id>, is exported into CMD's environment only, and
#     every descendant inherits it, whatever group or session it moves to.
#     --timeout SECS  0 = none (default 0). On expiry: TERM to the group,
#                     up to --grace SECS (default 10), then KILL; rc 124.
#     After every run (pass, fail or timeout) the sweep runs: every process
#     owned by our uid whose /proc/<pid>/environ carries the marker gets
#     TERM, a short grace (SEED_RUN_SWEEP_GRACE_SECS, default 2), then KILL.
#     It re-scans every 0.2s until two passes in a row find nothing, so a
#     stray still starting (mid-execve, environ not yet readable) when the
#     command exits is caught on a later pass; SEED_RUN_SWEEP_SETTLE_SECS
#     (default 2) bounds that wait. Where /proc is absent the sweep is
#     skipped quietly (count 0).
#     A TERM/INT delivered to the calling shell during the run kills the
#     group and sweeps before exiting 143/130; the caller's own TERM/INT
#     traps are restored when the run returns.
#     Returns CMD's exit code, or 124 on a timeout. Sets:
#       SEED_RUN_ID          the marker value of this run
#       SEED_RUN_SURVIVORS   processes the sweep found (and killed); the
#                            caller logs a warn line when it is non-zero
#     rc 2 on a usage error.
#
# There is no "intentional long-lived service" escape hatch: a seeder loads
# data, and the stack it needs is started by env-start.sh, not by it. A
# process that scrubs its own environment (env -i, a container started
# through a daemon) is out of reach of the sweep.

_SEED_RUN_PGID=""
_SEED_RUN_MARK=""

# _seed_run_new_id — a run id unique across concurrent runs on this host.
_seed_run_new_id() {
  local u=""
  [ -r /proc/sys/kernel/random/uuid ] && u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
  [ -n "$u" ] || u="$$-${RANDOM}${RANDOM}-$(date +%s)"
  printf 'seed-%s\n' "$u"
}

# _seed_run_pid_of <"/proc/<pid>/environ"> — sets _SR_PID to <pid> when it
# is ours and not this shell; rc 1 otherwise. No fork: called per hit.
_seed_run_pid_of() {
  _SR_PID="${1#/proc/}"
  _SR_PID="${_SR_PID%/environ}"
  [ "$_SR_PID" = "$$" ] && return 1
  [ "$_SR_PID" = "${BASHPID:-}" ] && return 1
  [ -O "/proc/$_SR_PID" ]
}

# _seed_run_scan <id> — one pass over /proc. Sets:
#   _SR_MARKED  pids owned by our uid whose environ carries the marker
#   _SR_UNSURE  1 when some process of ours that is not a zombie reads an
#               empty environ, else 0
# An empty environ is what a process shows mid-execve: the kernel installs
# the new mm before it records env_start/env_end, so for that window (which
# spans loading ld.so, longer on a cold-cache host) a marked stray reads as
# unmarked. A setsid stray passes through several execs (setsid, env,
# bash) right after it forks, exactly when a sweep starts (#621 follow-up).
# Both greps run in command substitutions, never in a pipeline: a pipeline
# stage still in its own execve would read empty and look unsure.
_seed_run_scan() {
  _SR_MARKED="" _SR_UNSURE=0
  [ -d /proc/self ] || return 0
  local out f st
  # -z: NUL-separated entries; -x: whole entry. Other users' files are
  # unreadable and skipped.
  out=$(grep -lzxF -- "TICKET_SEED_RUN_ID=$1" /proc/[0-9]*/environ 2>/dev/null)
  for f in $out; do
    _seed_run_pid_of "$f" && _SR_MARKED="$_SR_MARKED $_SR_PID"
  done
  # grep -c '' prints <file>:0 only for an empty file.
  out=$(grep -c '' /proc/[0-9]*/environ 2>/dev/null)
  for f in $out; do
    case "$f" in *:0) ;; *) continue ;; esac
    _seed_run_pid_of "${f%:0}" || continue
    read -r st 2>/dev/null <"/proc/$_SR_PID/stat" || continue
    st="${st##*) }"
    case "${st%% *}" in Z | X) continue ;; esac
    _SR_UNSURE=1
    break
  done
}

# _seed_run_marked <id> — the marked pids, one per line (abort path, tests).
_seed_run_marked() {
  _seed_run_scan "$1"
  local p
  for p in $_SR_MARKED; do printf '%s\n' "$p"; done
}

# _seed_run_sweep <id> — scan every 0.2s until two passes in a row are
# quiet. A marked pid gets TERM when first seen and KILL once it has
# outlived SEED_RUN_SWEEP_GRACE_SECS (default 2). For the first
# SEED_RUN_SWEEP_SETTLE_SECS (default 2) a pass with an unsure process is
# not quiet, so a stray caught mid-exec is scanned again once it has an
# environ; past that window unsure processes are ignored (they may be an
# unrelated env -i process of this user). Hard stop at settle + grace: a
# final KILL of whatever is still marked. A clean run costs two scans and
# one 0.2s sleep. Echoes how many distinct marked pids were found.
_seed_run_sweep() {
  local id="$1" grace="${SEED_RUN_SWEEP_GRACE_SECS:-2}" settle="${SEED_RUN_SWEEP_SETTLE_SECS:-2}"
  case "$grace" in '' | *[!0-9]*) grace=2 ;; esac
  case "$settle" in '' | *[!0-9]*) settle=2 ;; esac
  if [ ! -d /proc/self ]; then
    echo 0
    return 0
  fi
  local -A seen=()
  local n=0 t=0 quiet=0 p round
  local grace_t=$((grace * 5)) settle_t=$((settle * 5))
  local stop_t=$((settle_t + grace_t))
  while :; do
    _seed_run_scan "$id"
    if [ -z "$_SR_MARKED" ] && { [ "$_SR_UNSURE" = 0 ] || [ "$t" -ge "$settle_t" ]; }; then
      quiet=$((quiet + 1))
      [ "$quiet" -ge 2 ] && break
    else
      quiet=0
      for p in $_SR_MARKED; do
        if [ -z "${seen[$p]+x}" ]; then
          seen[$p]=$t
          n=$((n + 1))
          kill -TERM "$p" 2>/dev/null || true
        elif [ $((t - seen[$p])) -ge "$grace_t" ]; then
          kill -KILL "$p" 2>/dev/null || true
        fi
      done
    fi
    if [ "$t" -ge "$stop_t" ]; then
      round=0
      while [ "$round" -lt 5 ]; do
        _seed_run_scan "$id"
        [ -n "$_SR_MARKED" ] || break
        for p in $_SR_MARKED; do
          [ -n "${seen[$p]+x}" ] || n=$((n + 1))
          seen[$p]=$t
          kill -KILL "$p" 2>/dev/null || true
        done
        sleep 0.1
        round=$((round + 1))
      done
      break
    fi
    sleep 0.2
    t=$((t + 1))
  done
  echo "$n"
}

# _seed_run_kill_group <grace-secs> — TERM the run's group, grace, KILL.
_seed_run_kill_group() {
  [ -n "$_SEED_RUN_PGID" ] || return 0
  kill -TERM -- "-$_SEED_RUN_PGID" 2>/dev/null || return 0
  local g=0 limit=$(($1 * 10))
  while [ "$g" -lt "$limit" ] && kill -0 -- "-$_SEED_RUN_PGID" 2>/dev/null; do
    sleep 0.1
    g=$((g + 1))
  done
  kill -KILL -- "-$_SEED_RUN_PGID" 2>/dev/null || true
}

# _seed_run_abort <rc> — the calling shell got TERM/INT mid-run.
_seed_run_abort() {
  _seed_run_kill_group 2
  [ -n "$_SEED_RUN_MARK" ] && _seed_run_sweep "$_SEED_RUN_MARK" >/dev/null
  exit "$1"
}

seed_run() {
  local secs=0 grace=10 cwd="."
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --timeout | --grace | --cwd)
      [ "$#" -ge 2 ] || return 2
      case "$1" in
      --timeout) secs="$2" ;;
      --grace) grace="$2" ;;
      --cwd) cwd="$2" ;;
      esac
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) return 2 ;;
    esac
  done
  [ "$#" -ge 1 ] || return 2
  case "$secs" in '' | *[!0-9]*) return 2 ;; esac
  case "$grace" in '' | *[!0-9]*) return 2 ;; esac

  SEED_RUN_ID=$(_seed_run_new_id)
  SEED_RUN_SURVIVORS=0
  _SEED_RUN_MARK="$SEED_RUN_ID"

  local old_term old_int had_m=false pid rc=0 ticks=0 limit=$((secs * 10))
  old_term=$(trap -p TERM)
  old_int=$(trap -p INT)
  trap '_seed_run_abort 143' TERM
  trap '_seed_run_abort 130' INT

  case $- in *m*) had_m=true ;; esac
  set -m
  (cd "$cwd" && export TICKET_SEED_RUN_ID="$SEED_RUN_ID" && exec "$@") </dev/null >&2 &
  pid=$!
  [ "$had_m" = true ] || set +m
  _SEED_RUN_PGID="$pid"

  if [ "$secs" != 0 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$ticks" -ge "$limit" ]; then
        _seed_run_kill_group "$grace"
        rc=124
        break
      fi
      sleep 0.1
      ticks=$((ticks + 1))
    done
  fi
  if [ "$rc" = 124 ]; then
    wait "$pid" 2>/dev/null || true
  else
    wait "$pid" || rc=$?
  fi
  _SEED_RUN_PGID=""

  SEED_RUN_SURVIVORS=$(_seed_run_sweep "$SEED_RUN_ID")
  _SEED_RUN_MARK=""

  # Restore the caller's traps (empty = there was none).
  trap - TERM INT
  [ -n "$old_term" ] && eval "$old_term"
  [ -n "$old_int" ] && eval "$old_int"
  return "$rc"
}
