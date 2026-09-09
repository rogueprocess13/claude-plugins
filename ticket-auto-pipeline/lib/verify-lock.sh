#!/usr/bin/env bash
# verify-lock.sh — single-flight flock-based mutex around ticket-verify's
# local app stack. Sourceable bash library. Does NOT set -euo pipefail
# (caller controls error handling — mirrors lib/worktree.sh's convention).
#
# Why this exists: the local dev stack (see tickets/env-start.sh in the
# CONSUMING workspace, not this repo) hardcodes ports — gateway:8080,
# bom:8081, credit-report:8082, bridge-endpoint:8085, debt-collection:8088,
# gateway-fe:9000. Two verify runs' app stacks up at once means two sets of
# JVMs racing on those same ports, plus shared memory/disk/CPU. Full
# per-run port namespacing is a much bigger, riskier change than warranted
# right now, so this instead serializes: only one verify's app stack is
# ever up at a time, and a concurrent request queues/waits its turn.
#
# Why not a plain `exec N>lockfile; flock N`: ticket-verify's SKILL.md runs
# as a sequence of independently-invoked bash blocks over the life of one
# verify session — a new process per Bash-tool call, not one continuous
# shell — so a flock held via `exec` in one invocation releases the instant
# that invocation's process exits, before the next step even starts. The
# lock is instead held by a small detached companion process (mirrors
# spawn-helper.sh's spawn_watchdog_start: `( ... ) & disown`, a stop-file
# for cooperative shutdown, and a bounded max-hold time as the crash
# backstop instead of an unbounded `sleep infinity`) — spawned at acquire
# time, released at release time. Because the flock is tied to that
# process's own open file descriptor, the kernel drops it the instant the
# process exits for *any* reason — including a crash or a killed agent —
# so a stale lock never needs a staleness check: a dead holder is, by
# definition, an unlocked lockfile. The bounded max-hold time
# (VERIFY_LOCK_MAX_HOLD_SECS, default 1h) is a second, independent
# backstop for the case release is never called at all (e.g. the calling
# agent itself is killed) — the holder self-terminates well past the
# documented 30-minute verify phase timeout instead of holding the lock
# forever.
#
# Path/timeouts: VERIFY_LOCK_FILE, VERIFY_LOCK_TIMEOUT_SECS and
# VERIFY_LOCK_MAX_HOLD_SECS come from config.sh.
#
# Usage:
#   source lib/verify-lock.sh
#   verify_lock_acquire "CRE-123" || exit 1   # blocks (polling) up to the timeout
#   ...                                        # start stack, run checks
#   verify_lock_release                        # idempotent — call on every exit path

_verify_lock_file() { echo "${VERIFY_LOCK_FILE:-/tmp/ticket-verify.lock}"; }
_verify_lock_token_file() { echo "$(_verify_lock_file).holder"; }
_verify_lock_info_file() { echo "$(_verify_lock_file).info"; }
_verify_lock_stop_file() { echo "$(_verify_lock_file).stop"; }

# verify_lock_acquire <TICKET_ID> [timeout_secs]
# Blocks (polling once a second) until the lock is acquired or
# <timeout_secs> (default VERIFY_LOCK_TIMEOUT_SECS) elapses.
# Exit 0 acquired, 1 timed out or failed — prints a clear diagnostic
# naming the current holder (when known) rather than hanging forever.
verify_lock_acquire() {
  local ticket_id="${1:-unknown}"
  local timeout="${2:-${VERIFY_LOCK_TIMEOUT_SECS:-2400}}"
  local max_hold="${VERIFY_LOCK_MAX_HOLD_SECS:-3600}"
  local lockfile token_file info_file stop_file
  lockfile=$(_verify_lock_file)
  token_file=$(_verify_lock_token_file)
  info_file=$(_verify_lock_info_file)
  stop_file=$(_verify_lock_stop_file)

  if ! command -v flock >/dev/null 2>&1; then
    echo "verify-lock: 'flock' is not available on this host — cannot serialize the app stack. Install util-linux (Linux) or a flock equivalent." >&2
    return 1
  fi

  mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true
  # Clear leftover bookkeeping ONLY when the pid it names is no longer
  # alive. This must never touch a live holder's files: two acquirers can
  # race here (one holding the flock, another about to wait on it), and
  # blindly rm-ing on every call would erase the live holder's own
  # token/info — leaving verify_lock_release with nothing to signal even
  # though that holder's fd (and the flock) is still very much open. A
  # stale file (pid dead, or corrupt/unreadable) is a genuine leftover
  # from a holder that exited before its own cleanup ran and is safe to
  # clear.
  if [ -f "$token_file" ]; then
    local _prev_pid
    _prev_pid=$(cat "$token_file" 2>/dev/null || true)
    if [ -z "$_prev_pid" ] || ! kill -0 "$_prev_pid" 2>/dev/null; then
      rm -f "$token_file" "$info_file" "$stop_file" 2>/dev/null || true
    fi
  else
    rm -f "$info_file" "$stop_file" 2>/dev/null || true
  fi

  (
    set +e
    exec 9>"$lockfile"
    if ! flock -w "$timeout" 9; then
      exit 1
    fi
    # Winning the flock makes this process the sole legitimate holder, so
    # any stop_file already sitting here is necessarily stale — leftover
    # from a previous holder that was killed before it could reach its own
    # cleanup (SIGKILL closes fd 9 and drops the flock instantly, but skips
    # every line after it, including the final `rm -f` below). Without
    # this, a freshly-won lock could see a dead holder's old stop_file on
    # its very first poll tick and immediately, spuriously, release itself.
    rm -f "$stop_file" 2>/dev/null || true
    echo "$BASHPID" >"$token_file"
    {
      printf 'ticket=%s\n' "$ticket_id"
      printf 'acquired_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'pid=%s\n' "$BASHPID"
    } >"$info_file"
    # 0.5s ticks (not 1s): halves worst-case latency between
    # verify_lock_release touching the stop file and this loop noticing it.
    # Also exits if the lockfile's own directory disappears (mirrors
    # spawn-helper.sh's spawn_watchdog_start "workspace removed" exit
    # condition) — otherwise a removed REPOS_ROOT, or a test fixture's
    # `rm -rf`, leaves this process polling a path that can never exist
    # again until the bounded max-hold backstop finally catches it.
    local _lockdir
    _lockdir=$(dirname "$lockfile")
    local _ticks=0
    local _max_ticks=$((max_hold * 2))
    while true; do
      sleep 0.5
      [ -f "$stop_file" ] && break
      [ -d "$_lockdir" ] || break
      _ticks=$((_ticks + 1))
      [ "$_ticks" -ge "$_max_ticks" ] && break
    done
    rm -f "$token_file" "$info_file" "$stop_file" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  local holder_bg_pid=$!
  disown 2>/dev/null || true

  local waited=0
  local grace=5
  while true; do
    # Must match on content, not mere existence: a still-live *previous*
    # holder's token file can legitimately be sitting right there while
    # this attempt is still waiting its turn (we deliberately never touch
    # a live holder's bookkeeping above) — only a token file naming *this*
    # attempt's own holder pid means this specific call won the lock.
    if [ -f "$token_file" ] && [ "$(cat "$token_file" 2>/dev/null)" = "$holder_bg_pid" ]; then
      return 0
    fi
    if ! kill -0 "$holder_bg_pid" 2>/dev/null; then
      # Holder exited without ever acquiring — flock itself gave up.
      break
    fi
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -ge "$((timeout + grace))" ] && break
  done

  local holder_info=""
  [ -f "$info_file" ] && holder_info=" — currently held by: $(tr '\n' ' ' <"$info_file" 2>/dev/null)"
  echo "verify-lock: timed out after ${timeout}s waiting for the ticket-verify lock ($lockfile) for ticket ${ticket_id}${holder_info}. Another verify run is using the local app stack — retry later, or investigate a stuck holder (only remove ${lockfile}.holder/.info/.stop after confirming that pid is actually gone)." >&2
  return 1
}

# verify_lock_release
# Signals the detached holder to stop (cooperative — touches the stop
# file) and waits briefly for it to exit, so the lock is free for the next
# waiter promptly rather than only after its next poll tick. Idempotent —
# safe to call when no lock is held, and never fails the caller: release
# is cleanup, not a correctness gate, so it always returns 0.
#
# Identity-safe by construction: this function can only ever have one
# holder in mind — whichever pid token_file names the instant this call
# starts, snapshotted BEFORE stop_file is even touched. From then on it
# only ever acts on token_file/info_file/stop_file while their content
# still matches that exact snapshot. This matters because release() can
# legitimately overlap with a brand-new holder winning the lock: the
# instant our holder notices stop_file and exits, its fd 9 closes, the
# kernel drops the flock, and a completely different, already-waiting
# acquirer can win and write ITS OWN token/info within milliseconds — long
# before this loop's next 0.5s poll tick. An existence-only check
# ("does token_file exist?") can't tell that apart from our own holder
# simply taking a moment to notice — so it would keep waiting, then
# eventually force-delete on timeout, destroying the new holder's live
# bookkeeping and leaking the lock (from the new holder's own
# now-signal-less perspective) for up to VERIFY_LOCK_MAX_HOLD_SECS.
verify_lock_release() {
  local lockfile token_file info_file stop_file
  lockfile=$(_verify_lock_file)
  token_file=$(_verify_lock_token_file)
  info_file=$(_verify_lock_info_file)
  stop_file=$(_verify_lock_stop_file)

  # Snapshot identity before touching anything.
  local _my_token
  _my_token=$(cat "$token_file" 2>/dev/null || true)

  if [ -z "$_my_token" ]; then
    # No live holder recorded — nothing to signal. A leftover info/stop
    # file with no token is definitionally stale.
    rm -f "$info_file" "$stop_file" 2>/dev/null || true
    return 0
  fi

  touch "$stop_file" 2>/dev/null || true

  # 0.5s ticks for ~6s total — matches the holder's own 0.5s poll tick
  # (see verify_lock_acquire). Bail out the instant token_file's content
  # no longer matches our snapshot: either our own holder already cleaned
  # up after itself (content now empty — the common, fast case), or a
  # brand-new holder has already won the lock and written its own token
  # (the race this function exists to guard against). Either way, this
  # call's job ends the moment that's true — it must never act on a
  # token/info/stop set that isn't provably still "our" holder's.
  local _ticks=0
  while [ "$_ticks" -lt 12 ]; do
    local _cur
    _cur=$(cat "$token_file" 2>/dev/null || true)
    [ "$_cur" = "$_my_token" ] || return 0
    sleep 0.5
    _ticks=$((_ticks + 1))
  done

  # Still seeing our own token after the full wait — the holder is
  # unusually slow to notice stop_file (scheduler contention), but nothing
  # else has claimed the lock in the meantime. Re-check immediately before
  # deleting (narrows, though does not fully eliminate, the gap between
  # this check and the rm below) and only clean up if it still matches.
  local _final
  _final=$(cat "$token_file" 2>/dev/null || true)
  if [ "$_final" = "$_my_token" ]; then
    rm -f "$token_file" "$info_file" "$stop_file" 2>/dev/null || true
  fi
  return 0
}

# verify_lock_status
# Prints holder info to stdout when held, "ticket-verify lock is free"
# otherwise. Exit 0 held, 1 free. Diagnostic only — never mutates state.
verify_lock_status() {
  local token_file info_file
  token_file=$(_verify_lock_token_file)
  info_file=$(_verify_lock_info_file)

  if [ -f "$token_file" ]; then
    local pid
    pid=$(cat "$token_file" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      cat "$info_file" 2>/dev/null || echo "ticket-verify lock held (pid $pid)"
      return 0
    fi
  fi

  echo "ticket-verify lock is free"
  return 1
}
