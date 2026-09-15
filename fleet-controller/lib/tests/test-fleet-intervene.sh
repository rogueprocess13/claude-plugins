#!/usr/bin/env bash
# test-fleet-intervene.sh — unit tests for lib/fleet-intervene.sh
# Usage: bash test-fleet-intervene.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ── Helpers ──────────────────────────────────────────────────────────────────────

_setup_workspace() {
  mktemp -d
}

_make_pipeline_log() {
  local dir="$1" tid="$2"
  mkdir -p "$dir"
  echo "2026-06-02T10:00:00Z|META|schema|info|1" >"${dir}/${tid}-pipeline.log"
  echo "2026-06-02T10:01:00Z|APPRAISE|appraise|done|scored" >>"${dir}/${tid}-pipeline.log"
}

# ── CI-safe stubs ───────────────────────────────────────────────────────────────
# heartbeat.sh may not be available in CI (no SessionStart hook). Provide
# functional stubs so intervene tests don't depend on external sourcing.

if ! declare -f _plog >/dev/null 2>&1; then
  _plog() {
    local file="$1" phase="$2" step="$3" status="$4" msg="$5"
    mkdir -p "$(dirname "$file")"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|${phase}|${step}|${status}|${msg}" >>"$file"
  }
fi

if ! declare -f hb_decision >/dev/null 2>&1; then
  hb_decision() { return 0; }
fi

if ! declare -f _iso_now >/dev/null 2>&1; then
  _iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fi

if ! declare -f _ensure_dir_for >/dev/null 2>&1; then
  _ensure_dir_for() { mkdir -p "$(dirname "$1")" 2>/dev/null || true; }
fi

# ── _flow_mutex_held tests ───────────────────────────────────────────────────────

test_flow_mutex_held_lockfile_absent() {
  local ws
  ws=$(_setup_workspace)
  # Ensure no lockfile exists in the workspace
  source "$LIB_DIR/fleet-intervene.sh"
  # Use ./logs path from workspace
  local tid="TEST-MUTEX-01"
  local lockfile="./logs/.ticket-flow-${tid}.lock"
  # Override: cd to temp dir so ./logs resolves there
  (
    cd "$ws"
    mkdir -p logs
    # No lockfile → should return 1
    if _flow_mutex_held "$tid"; then
      false
    else
      true
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_flow_mutex_held_lock_held() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    source "$LIB_DIR/fleet-intervene.sh"
    local tid="TEST-MUTEX-02"
    # _flow_mutex_held resolves lock dir from TICKET_FLOW_LOCK_DIR
    # or falls back to $HOME/.claude/skills/ticket-flow/locks.
    # Point it at our temp workspace so it finds the lock we create.
    export TICKET_FLOW_LOCK_DIR="./logs"
    local lockfile="./logs/.ticket-flow-${tid}.lock"
    touch "$lockfile"
    # Acquire lock in a background subshell
    (
      exec 9>"$lockfile"
      flock -x 9
      sleep 5
    ) &
    local holder_pid=$!
    sleep 0.5 # let holder acquire lock
    local rc=0
    _flow_mutex_held "$tid" || rc=$?
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    rm -rf "$ws"
    [ "$rc" -eq 0 ] # mutex should be detected as held
  )
  local outer_rc=$?
  [ "$outer_rc" -eq 0 ]
}

test_flow_mutex_held_stale_lockfile() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    source "$LIB_DIR/fleet-intervene.sh"
    local tid="TEST-MUTEX-03"
    local lockfile="./logs/.ticket-flow-${tid}.lock"
    touch "$lockfile"
    # Lockfile exists but no process holds flock (stale from crash)
    if _flow_mutex_held "$tid"; then
      false # should NOT detect mutex as held
    else
      true
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

# ── fleet_kill_pipeline tests ────────────────────────────────────────────────────

test_fleet_kill_pipeline_nonexistent_ticket() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    source "$LIB_DIR/fleet-intervene.sh"
    local out
    if out=$(fleet_kill_pipeline "NOEXIST-99" "test" "./logs" 2>&1); then
      false # should return non-zero
    else
      echo "$out" | grep -q "no pipeline log" || false
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_fleet_kill_pipeline_normal() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    source "$LIB_DIR/fleet-intervene.sh"
    fleet_kill_pipeline "CRE-47" "test-kill" "./logs"
    # Verify intervention entry written
    grep -q "META|fleet-intervention|warn|KILL; reason=test-kill" "./logs/CRE-47-pipeline.log" || {
      echo "missing intervention entry" >&2
      exit 1
    }
    # Verify outcome entry written
    grep -q "META|outcome|info|stopped: fleet-kill" "./logs/CRE-47-pipeline.log" || {
      echo "missing outcome entry" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_fleet_kill_pipeline_dry_run_does_not_mutate() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    source "$LIB_DIR/fleet-intervene.sh"
    export FLEET_DRY_RUN=true
    local before_count
    before_count=$(wc -l <"./logs/CRE-47-pipeline.log")
    fleet_kill_pipeline "CRE-47" "test" "./logs"
    local after_count
    after_count=$(wc -l <"./logs/CRE-47-pipeline.log")
    [ "$before_count" -eq "$after_count" ]
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_fleet_kill_pipeline_sigint_rung_kills_plain_worker() {
  # worker-reap-recovery task 4.3: a registered PID with no signal handling
  # (default SIGINT disposition terminates immediately) is confirmed dead
  # at the SIGINT rung — before ever reaching SIGTERM.
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-48"
    source "$LIB_DIR/fleet-registry.sh"
    source "$LIB_DIR/fleet-intervene.sh"

    # Bash sets SIGINT to ignore on backgrounded jobs by default (so Ctrl-C
    # in the foreground doesn't kill them) — reset it to default disposition
    # before exec'ing into sleep, or this "plain" worker would ignore SIGINT
    # for the same reason a real ignoring-worker does, defeating the test.
    (
      trap - INT
      exec sleep 30
    ) &
    local worker_pid=$!
    registry_write "CRE-48" "$worker_pid" 1 "test" "./logs"

    FLEET_KILL_GRACE_SECS=1 fleet_kill_pipeline "CRE-48" "test-sigint" "./logs"
    wait "$worker_pid" 2>/dev/null || true

    grep -q "META|outcome|info|stopped: fleet-kill (SIGINT)" "./logs/CRE-48-pipeline.log" || {
      echo "expected SIGINT outcome entry, got:" >&2
      cat "./logs/CRE-48-pipeline.log" >&2
      exit 1
    }
    kill -0 "$worker_pid" 2>/dev/null && {
      echo "worker still alive after SIGINT rung" >&2
      kill -9 "$worker_pid" 2>/dev/null || true
      exit 1
    }
    exit 0
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_fleet_kill_pipeline_ignoring_worker_escalates_to_sigkill() {
  # A worker that ignores SIGINT and SIGTERM is escalated all the way to
  # SIGKILL — the SIGINT rung must not be a dead end for an unresponsive
  # worker.
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-49"
    source "$LIB_DIR/fleet-registry.sh"
    source "$LIB_DIR/fleet-intervene.sh"

    bash -c 'trap "" INT TERM; sleep 30' &
    local worker_pid=$!
    registry_write "CRE-49" "$worker_pid" 1 "test" "./logs"

    FLEET_KILL_GRACE_SECS=1 fleet_kill_pipeline "CRE-49" "test-sigkill" "./logs"
    wait "$worker_pid" 2>/dev/null || true

    grep -q "META|outcome|info|stopped: fleet-kill (SIGKILL)" "./logs/CRE-49-pipeline.log" || {
      echo "expected SIGKILL outcome entry, got:" >&2
      cat "./logs/CRE-49-pipeline.log" >&2
      exit 1
    }
    kill -0 "$worker_pid" 2>/dev/null && {
      echo "unresponsive worker still alive after full escalation" >&2
      kill -9 "$worker_pid" 2>/dev/null || true
      exit 1
    }
    exit 0
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

# ── _count_restarts regression tests ─────────────────────────────────────────────

test_count_restarts_single_restart_counts_one() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    # Add one fleet-restart + one fleet-restart-marker (the exact bug trigger)
    echo "2026-06-02T10:05:00Z|META|fleet-restart|info|restart test-reason" >>"./logs/CRE-47-pipeline.log"
    echo "2026-06-02T10:05:01Z|META|fleet-restart-marker|info|restart-intent test-reason" >>"./logs/CRE-47-pipeline.log"
    source "$LIB_DIR/fleet-intervene.sh"
    local count
    count=$(_count_restarts "./logs/CRE-47-pipeline.log")
    [ "$count" -eq 1 ] || {
      echo "expected 1 restart, got $count" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

# Regression: zero restart markers must emit exactly one "0" line. The old
# `grep -c ... || echo "0"` pattern printed grep's "0" AND echoed another,
# producing "0\n0" — which broke the integer comparison in fleet_can_restart.
test_count_restarts_zero_matches_single_zero_line() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-48"
    source "$LIB_DIR/fleet-intervene.sh"
    local count lines
    count=$(_count_restarts "./logs/CRE-48-pipeline.log")
    lines=$(printf '%s\n' "$count" | wc -l)
    [ "$count" = "0" ] && [ "$lines" = "1" ] || {
      echo "expected exactly one '0' line, got [$count] (${lines} lines)" >&2
      exit 1
    }
    # And the exact failure it caused: fleet_can_restart must make a clean
    # integer comparison when the log has zero restarts.
    export FLEET_AUTO_RESTART=true
    export FLEET_MAX_RESTARTS=0
    if fleet_can_restart "CRE-48" "./logs" 2>/dev/null; then
      echo "expected cap reached at 0 restarts with MAX=0" >&2
      exit 1
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

# ── _count_restarts orphan-reap exemption (GitHub #364) ──────────────────────
# WIL-77/78/79/80 dead-lettered after repeated restarts, each one consumed
# entirely by cleaning up a leftover orphaned pinger/watchdog with no chance
# to reach a real phase terminal.
#
# These fixtures are built by calling the REAL spawn_agent_pre/
# spawn_agent_post (ticket-auto-pipeline/lib/spawn-helper.sh) instead of
# hand-writing log lines. An earlier version of this test file hand-crafted
# fixtures with orphan-reaped and NO waiting line anywhere in the window —
# a shape real code never produces, since phase_bracket_open's |waiting|
# line is always written immediately before spawn_sweep_orphans' own
# orphan-reaped line (both run back to back inside spawn_agent_pre). That
# mismatch between fixture and reality is exactly how the first cut of the
# exemption shipped with a predicate that could never fire. Driving these
# fixtures through the real writer keeps that from happening again.

# Absolute path to ticket-auto-pipeline/lib — spawn_agent_pre/post live
# there, not in this plugin. Monorepo-relative, matching the pattern
# spawn-helper.sh itself uses to find fleet-config.sh the other way.
_tap_lib_dir() {
  echo "$LIB_DIR/../../ticket-auto-pipeline/lib"
}

# Seeds a live process into TID's background-process ledger — exactly the
# shape a crashed prior attempt's un-reaped pinger/watchdog leaves for the
# next attempt's proactive spawn_sweep_orphans call to find. Echoes the
# seeded pid so the caller can assert it either was or wasn't reaped, and
# can guarantee its own cleanup (the sleep survives independently of this
# function once it returns).
_seed_leaked_orphan() {
  local ws="$1" tid="$2" type="${3:-pinger}"
  # Redirected: this function is always called via `pid=$(_seed_leaked_orphan ...)`
  # (command substitution, which captures via a pipe). An unredirected `&`
  # job inherits that same pipe's write end; the substitution then blocks
  # until EVERY writer closes it, including this background sleep — so the
  # caller would hang for up to the sleep's own duration before ever seeing
  # the echoed pid, regardless of how quickly this function itself returns.
  sleep 30 >/dev/null 2>&1 &
  local pid=$!
  (
    export FLEET_STATE_DIR="$ws/logs"
    unset -f _plog hb_decision _iso_now _ensure_dir_for 2>/dev/null || true
    source "$(_tap_lib_dir)/spawn-helper.sh" 2>/dev/null
    local ticks ledger
    ticks=$(_proc_start_ticks "$pid")
    ledger=$(_worker_bg_ledger "$tid")
    mkdir -p "$(dirname "$ledger")"
    echo "${pid}:${ticks}:${type}" >>"$ledger"
  )
  echo "$pid"
}

# Real spawn_agent_pre only — opens a phase bracket and (proactively) sweeps
# any ledgered orphan for TID, exactly as a fresh attempt does. HB_LOG_FILE
# is deliberately left unset: spawn_agent_pre's own pinger/watchdog block is
# gated on it, so nothing is started that would need reaping afterward —
# only the bracket-open/sweep write path under test runs. Never calling
# spawn_agent_post simulates "this attempt crashed again immediately," the
# WIL-77-style repeat-crash shape.
_real_attempt_no_terminal() {
  local ws="$1" tid="$2" log="$3"
  (
    unset HB_LOG_FILE
    unset -f _plog hb_decision _iso_now _ensure_dir_for 2>/dev/null || true
    source "$(_tap_lib_dir)/spawn-helper.sh" 2>/dev/null
    export TICKET_ID="$tid"
    export FLEET_STATE_DIR="$ws/logs"
    spawn_agent_pre PHASE=IMPLEMENT STEP=IMPLEMENT LOG_FILE="$log" TICKET_ID="$tid" SKILL=/ticket-implement >/dev/null 2>&1
  )
}

# Real spawn_agent_pre THEN spawn_agent_post RESULT=fail — a genuine attempt
# that reaches its own terminal, orphan evidence or not.
_real_attempt_with_terminal() {
  local ws="$1" tid="$2" log="$3"
  (
    unset HB_LOG_FILE
    unset -f _plog hb_decision _iso_now _ensure_dir_for 2>/dev/null || true
    source "$(_tap_lib_dir)/spawn-helper.sh" 2>/dev/null
    export TICKET_ID="$tid"
    export FLEET_STATE_DIR="$ws/logs"
    spawn_agent_pre PHASE=IMPLEMENT STEP=IMPLEMENT LOG_FILE="$log" TICKET_ID="$tid" SKILL=/ticket-implement >/dev/null 2>&1
    spawn_agent_post TICKET_ID="$tid" RESULT=fail PHASE=IMPLEMENT STEP=IMPLEMENT LOG_FILE="$log" >/dev/null 2>&1
  )
}

test_count_restarts_excludes_orphan_only_restart() {
  # The reviewer's own live-verification shape: a leaked pinger seeded from
  # a "crashed prior attempt," a real fleet-restart marker, then the REAL
  # spawn_agent_pre for the next attempt — which reaps the orphan and then
  # (simulated by never calling spawn_agent_post) crashes again immediately.
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    tid="CRE-60"
    log="./logs/${tid}-pipeline.log"
    _make_pipeline_log "./logs" "$tid"
    leaked_pid=$(_seed_leaked_orphan "$ws" "$tid" pinger)
    trap 'kill -9 "$leaked_pid" 2>/dev/null || true' EXIT
    source "$LIB_DIR/fleet-intervene.sh"
    _log_pipeline "$log" "META" "fleet-restart" "info" "restart orphan-reconciliation"
    _real_attempt_no_terminal "$ws" "$tid" "$log"
    if kill -0 "$leaked_pid" 2>/dev/null; then
      echo "seeded orphan was not reaped by the real sweep" >&2
      exit 1
    fi
    command grep -q '|META|orphan-reaped|' "$log" || {
      echo "no orphan-reaped evidence in the log — fixture didn't exercise the real sweep" >&2
      exit 1
    }
    command grep -q '|waiting|' "$log" || {
      echo "no waiting line either — this fixture is not the real write shape" >&2
      exit 1
    }
    local count
    count=$(_count_restarts "$log")
    [ "$count" -eq 0 ] || {
      echo "expected 0 restarts (orphan-only, no terminal reached), got $count" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_count_restarts_counts_restart_with_real_work_despite_orphan_reap() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    tid="CRE-61"
    log="./logs/${tid}-pipeline.log"
    _make_pipeline_log "./logs" "$tid"
    leaked_pid=$(_seed_leaked_orphan "$ws" "$tid" pinger)
    trap 'kill -9 "$leaked_pid" 2>/dev/null || true' EXIT
    source "$LIB_DIR/fleet-intervene.sh"
    _log_pipeline "$log" "META" "fleet-restart" "info" "restart orphan-reconciliation"
    _real_attempt_with_terminal "$ws" "$tid" "$log"
    command grep -q '|fail|' "$log" || {
      echo "no fail terminal in the log — fixture didn't reach spawn_agent_post" >&2
      exit 1
    }
    local count
    count=$(_count_restarts "$log")
    [ "$count" -eq 1 ] || {
      echo "expected 1 restart (real phase work reached a terminal), got $count" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_count_restarts_mixed_orphan_and_genuine_restarts() {
  # First restart is orphan-only (exempt, no terminal); second is a genuine
  # attempt that reaches a terminal (counted). A ticket that keeps failing
  # for real reasons must still be able to reach the cap.
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    tid="CRE-62"
    log="./logs/${tid}-pipeline.log"
    _make_pipeline_log "./logs" "$tid"
    leaked_pid=$(_seed_leaked_orphan "$ws" "$tid" watchdog)
    trap 'kill -9 "$leaked_pid" 2>/dev/null || true' EXIT
    source "$LIB_DIR/fleet-intervene.sh"

    _log_pipeline "$log" "META" "fleet-restart" "info" "restart orphan-reconciliation"
    _real_attempt_no_terminal "$ws" "$tid" "$log"

    _log_pipeline "$log" "META" "fleet-restart" "info" "restart worker-exit"
    _real_attempt_with_terminal "$ws" "$tid" "$log"

    local count
    count=$(_count_restarts "$log")
    [ "$count" -eq 1 ] || {
      echo "expected 1 restart (1 exempt orphan-only + 1 genuine), got $count" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_count_restarts_no_orphan_evidence_counts_normally() {
  # Pre-#364 behaviour, unaffected: a restart with no orphan-reaped line at
  # all always counts, exactly as before this change — even with no
  # terminal reached, since exemption requires orphan evidence first.
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    tid="CRE-63"
    log="./logs/${tid}-pipeline.log"
    _make_pipeline_log "./logs" "$tid"
    source "$LIB_DIR/fleet-intervene.sh"
    _log_pipeline "$log" "META" "fleet-restart" "info" "restart worker-exit"
    _real_attempt_no_terminal "$ws" "$tid" "$log"
    command grep -q '|META|orphan-reaped|' "$log" && {
      echo "unexpected orphan-reaped line — nothing was seeded to find" >&2
      exit 1
    }
    local count
    count=$(_count_restarts "$log")
    [ "$count" -eq 1 ] || {
      echo "expected 1 restart (no orphan evidence), got $count" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_count_restarts_orphan_exemption_flows_through_fleet_can_restart() {
  # End-to-end: an orphan-only restart must not push fleet_can_restart to
  # refuse at the cap.
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    tid="CRE-64"
    log="./logs/${tid}-pipeline.log"
    _make_pipeline_log "./logs" "$tid"
    leaked_pid=$(_seed_leaked_orphan "$ws" "$tid" pinger)
    trap 'kill -9 "$leaked_pid" 2>/dev/null || true' EXIT
    source "$LIB_DIR/fleet-intervene.sh"
    _log_pipeline "$log" "META" "fleet-restart" "info" "restart orphan-reconciliation"
    _real_attempt_no_terminal "$ws" "$tid" "$log"
    export FLEET_AUTO_RESTART=true
    export FLEET_MAX_RESTARTS=1
    fleet_can_restart "$tid" "./logs" >/dev/null 2>&1 || {
      echo "fleet_can_restart refused a ticket whose only restart was orphan-only" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_count_restarts_does_not_exempt_past_the_grace_period() {
  # Safety net for the "must not mask genuine stalls" constraint: even with
  # orphan evidence and no terminal, a window that stays open longer than
  # FLEET_ORPHAN_RESTART_GRACE_SECS always counts. Uses a real, tiny elapsed
  # wall-clock delay (not a fabricated timestamp) against a grace period
  # forced to 0 so the test is fast and deterministic without waiting out
  # the real ~1800s a genuine stall takes.
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    tid="CRE-65"
    log="./logs/${tid}-pipeline.log"
    _make_pipeline_log "./logs" "$tid"
    leaked_pid=$(_seed_leaked_orphan "$ws" "$tid" pinger)
    trap 'kill -9 "$leaked_pid" 2>/dev/null || true' EXIT
    source "$LIB_DIR/fleet-intervene.sh"
    _log_pipeline "$log" "META" "fleet-restart" "info" "restart orphan-reconciliation"
    _real_attempt_no_terminal "$ws" "$tid" "$log"
    sleep 2
    local count
    count=$(FLEET_ORPHAN_RESTART_GRACE_SECS=0 _count_restarts "$log")
    [ "$count" -eq 1 ] || {
      echo "expected 1 restart (window ran past the grace period), got $count" >&2
      exit 1
    }
    # And the default grace period (60s) exempts the exact same fixture,
    # since 2 real seconds is nowhere near it — confirms the boundary
    # itself, not just that a huge grace value is meaningless.
    count=$(_count_restarts "$log")
    [ "$count" -eq 0 ] || {
      echo "expected 0 restarts under the default grace period, got $count" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_count_restarts_genuinely_hung_phase_reaches_cap_after_8_restarts() {
  # Reviewer scenario (a): a genuinely hung phase (never orphan-related —
  # no ledger entry is ever seeded) restarted repeatedly still accumulates
  # every restart and reaches the cap. Real spawn_agent_pre calls; no
  # spawn_agent_post, matching a phase that never finishes.
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    tid="CRE-66"
    log="./logs/${tid}-pipeline.log"
    _make_pipeline_log "./logs" "$tid"
    source "$LIB_DIR/fleet-intervene.sh"
    local n
    for n in 1 2 3 4 5 6 7 8; do
      _log_pipeline "$log" "META" "fleet-restart" "info" "restart worker-exit-${n}"
      _real_attempt_no_terminal "$ws" "$tid" "$log"
    done
    command grep -q '|META|orphan-reaped|' "$log" && {
      echo "unexpected orphan-reaped line — this scenario never seeds one" >&2
      exit 1
    }
    local count
    count=$(_count_restarts "$log")
    [ "$count" -eq 8 ] || {
      echo "expected 8 restarts (none orphan-related), got $count" >&2
      exit 1
    }
    export FLEET_AUTO_RESTART=true
    export FLEET_MAX_RESTARTS=2
    if fleet_can_restart "$tid" "./logs" >/dev/null 2>&1; then
      echo "fleet_can_restart granted another restart past the cap" >&2
      exit 1
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_count_restarts_4_orphan_only_interleaved_with_4_genuine_counts_4() {
  # Reviewer scenario (b): 4 orphan-reap-only restarts interleaved with 4
  # genuine (terminal-reaching) attempts must count only the 4 genuine ones.
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    tid="CRE-67"
    log="./logs/${tid}-pipeline.log"
    _make_pipeline_log "./logs" "$tid"
    source "$LIB_DIR/fleet-intervene.sh"
    local -a leaked_pids=()
    trap 'for p in "${leaked_pids[@]}"; do kill -9 "$p" 2>/dev/null || true; done' EXIT
    local n
    for n in 1 2 3 4; do
      local leaked_pid
      leaked_pid=$(_seed_leaked_orphan "$ws" "$tid" pinger)
      leaked_pids+=("$leaked_pid")
      _log_pipeline "$log" "META" "fleet-restart" "info" "restart orphan-${n}"
      _real_attempt_no_terminal "$ws" "$tid" "$log"

      _log_pipeline "$log" "META" "fleet-restart" "info" "restart genuine-${n}"
      _real_attempt_with_terminal "$ws" "$tid" "$log"
    done
    local orphan_lines
    orphan_lines=$(command grep -c '|META|orphan-reaped|' "$log" 2>/dev/null || echo 0)
    [ "$orphan_lines" -eq 4 ] || {
      echo "expected 4 orphan-reaped lines (one per seeded leak), got $orphan_lines" >&2
      exit 1
    }
    local count
    count=$(_count_restarts "$log")
    [ "$count" -eq 4 ] || {
      echo "expected 4 restarts (only the 4 genuine ones), got $count" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_fleet_can_restart_not_exhausted_after_single_restart() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    # One fleet-restart + companion marker (should count as 1, not 2)
    echo "2026-06-02T10:05:00Z|META|fleet-restart|info|restart test-reason" >>"./logs/CRE-47-pipeline.log"
    echo "2026-06-02T10:05:01Z|META|fleet-restart-marker|info|restart-intent test-reason" >>"./logs/CRE-47-pipeline.log"
    source "$LIB_DIR/fleet-intervene.sh"
    export FLEET_AUTO_RESTART=true
    export FLEET_MAX_RESTARTS=2
    if fleet_can_restart "CRE-47" "./logs" 2>/dev/null; then
      true # should be eligible
    else
      echo "cap should NOT be reached after 1 restart with MAX=2" >&2
      exit 1
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

# ── fleet_restart_pipeline contract tests ────────────────────────────────────────

test_fleet_restart_pipeline_no_restart_eligible_stdout() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    source "$LIB_DIR/fleet-intervene.sh"
    export FLEET_AUTO_RESTART=true
    local stdout
    stdout=$(fleet_restart_pipeline "CRE-47" "test-restart" "./logs" 2>&1) || true
    # Should NOT contain "RESTART_ELIGIBLE="
    if echo "$stdout" | grep -q "RESTART_ELIGIBLE="; then
      echo "unexpected RESTART_ELIGIBLE in output: $stdout" >&2
      false
    else
      true
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_fleet_restart_pipeline_writes_restart_marker() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    source "$LIB_DIR/fleet-intervene.sh"
    export FLEET_AUTO_RESTART=true
    fleet_restart_pipeline "CRE-47" "test-restart" "./logs" 2>/dev/null || true
    grep -q "META|fleet-restart-marker|info|restart-intent" "./logs/CRE-47-pipeline.log" || {
      echo "missing restart marker" >&2
      false
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_fleet_restart_pipeline_auto_restart_off_returns_1() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    source "$LIB_DIR/fleet-intervene.sh"
    export FLEET_AUTO_RESTART=false
    if fleet_restart_pipeline "CRE-47" "test-restart" "./logs" 2>/dev/null; then
      false # should fail when auto-restart is disabled
    else
      true
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

# ── Stop-file path equality tests ──────────────────────────────────────────────
# Verifies fleet-intervene.sh and spawn-helper.sh resolve stop-file paths to
# the same directory. Without this, cooperative kill silently fails because
# the intervention writes to one directory while the worker watches another.

test_stop_file_path_equality_default() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    source "$LIB_DIR/fleet-config.sh"
    source "$LIB_DIR/fleet-intervene.sh"

    # Simulate what fleet_stop_background does
    local fleet_pinger
    fleet_pinger=$(_fleet_stop_file "TEST-TID" "pinger" "./logs")

    # Simulate what _worker_stop_file in spawn-helper.sh does when fleet-config.sh is
    # available — same constructor, same workspace default (FLEET_PIPELINE_LOG_DIR
    # unset → ./logs). After the spawn-helper fix, the FLEET_STATE_DIR guard is
    # removed, so both call sites resolve through _fleet_stop_file.
    local worker_pinger
    worker_pinger=$(_fleet_stop_file "TEST-TID" "pinger" "${FLEET_PIPELINE_LOG_DIR:-./logs}")

    [ "$fleet_pinger" = "$worker_pinger" ] || {
      echo "MISMATCH (default): fleet=$fleet_pinger worker=$worker_pinger" >&2
      exit 1
    }
    # Verify both paths are under the state directory, not /tmp
    echo "$fleet_pinger" | grep -qv "/tmp" || {
      echo "stop file path should not be under /tmp (default config): $fleet_pinger" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_stop_file_path_equality_fleet_state_dir_set() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    source "$LIB_DIR/fleet-config.sh"
    source "$LIB_DIR/fleet-intervene.sh"

    export FLEET_STATE_DIR="/var/fleet/state"

    local fleet_pinger
    fleet_pinger=$(_fleet_stop_file "TEST-TID" "pinger" "./logs")

    local worker_pinger
    worker_pinger=$(_fleet_stop_file "TEST-TID" "pinger" "${FLEET_PIPELINE_LOG_DIR:-./logs}")

    [ "$fleet_pinger" = "$worker_pinger" ] || {
      echo "MISMATCH (FLEET_STATE_DIR): fleet=$fleet_pinger worker=$worker_pinger" >&2
      exit 1
    }
    # Verify both paths honour FLEET_STATE_DIR
    echo "$fleet_pinger" | grep -q "/var/fleet/state" || {
      echo "stop file path should honour FLEET_STATE_DIR: $fleet_pinger" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_stop_file_path_equality_both_types() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    source "$LIB_DIR/fleet-config.sh"

    for stype in pinger watchdog; do
      local fleet_path worker_path
      fleet_path=$(_fleet_stop_file "TEST-TID" "$stype" "./logs")
      worker_path=$(_fleet_stop_file "TEST-TID" "$stype" "${FLEET_PIPELINE_LOG_DIR:-./logs}")

      [ "$fleet_path" = "$worker_path" ] || {
        echo "MISMATCH ($stype): fleet=$fleet_path worker=$worker_path" >&2
        exit 1
      }
    done
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

# ── Dispatcher ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_flow_mutex_held_lockfile_absent \
  test_flow_mutex_held_lock_held \
  test_flow_mutex_held_stale_lockfile \
  test_fleet_kill_pipeline_nonexistent_ticket \
  test_fleet_kill_pipeline_normal \
  test_fleet_kill_pipeline_dry_run_does_not_mutate \
  test_fleet_kill_pipeline_sigint_rung_kills_plain_worker \
  test_fleet_kill_pipeline_ignoring_worker_escalates_to_sigkill \
  test_count_restarts_single_restart_counts_one \
  test_count_restarts_zero_matches_single_zero_line \
  test_count_restarts_excludes_orphan_only_restart \
  test_count_restarts_counts_restart_with_real_work_despite_orphan_reap \
  test_count_restarts_mixed_orphan_and_genuine_restarts \
  test_count_restarts_no_orphan_evidence_counts_normally \
  test_count_restarts_orphan_exemption_flows_through_fleet_can_restart \
  test_count_restarts_does_not_exempt_past_the_grace_period \
  test_count_restarts_genuinely_hung_phase_reaches_cap_after_8_restarts \
  test_count_restarts_4_orphan_only_interleaved_with_4_genuine_counts_4 \
  test_fleet_can_restart_not_exhausted_after_single_restart \
  test_fleet_restart_pipeline_no_restart_eligible_stdout \
  test_fleet_restart_pipeline_writes_restart_marker \
  test_fleet_restart_pipeline_auto_restart_off_returns_1 \
  test_stop_file_path_equality_default \
  test_stop_file_path_equality_fleet_state_dir_set \
  test_stop_file_path_equality_both_types; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
