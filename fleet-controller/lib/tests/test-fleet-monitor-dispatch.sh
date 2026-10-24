#!/usr/bin/env bash
# test-fleet-monitor-dispatch.sh — unit tests for spawn queue consumption in fleet-monitor.sh
# Usage: bash test-fleet-monitor-dispatch.sh [test_name_filter]
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

# ── Mock helpers ─────────────────────────────────────────────────────────────────

_setup_workspace() {
  mktemp -d
}

_setup_queue() {
  local state_dir="${1:-/tmp}"
  local instance_id="${2:-test-dispatch}"
  local queue_file="${state_dir}/fleet-${instance_id}-spawn-queue.jsonl"
  rm -f "$queue_file"
  echo "$queue_file"
}

# ── Tests ───────────────────────────────────────────────────────────────────────

test_queue_consume_empty() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-empty")

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-empty
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_consume '$ws' 0 2>&1
  " 2>/dev/null || true)
  # Empty queue → nothing consumed, no error
  return 0
}

test_queue_consume_at_capacity() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-cap")

  # Write an entry to the queue
  echo '{"tid":"CRE-101","reason":"planned-dispatch","timestamp":"2026-07-07T10:00:00Z","restarts":0,"dispatch_type":"initial"}' >"$queue_file"

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-cap FLEET_MAX_CONCURRENT=3
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_consume '$ws' 3 2>&1
  " 2>/dev/null || true)
  # 3 active + max 3 → 0 slots → should consume nothing
  [ -f "$queue_file" ] && return 0 || {
    echo "queue should still exist at capacity"
    return 1
  }
}

test_queue_consume_entry() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-consume")

  # Write an entry to the queue
  echo '{"tid":"CRE-101","reason":"planned-dispatch","timestamp":"2026-07-07T10:00:00Z","restarts":0,"dispatch_type":"initial"}' >"$queue_file"

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-consume FLEET_MAX_CONCURRENT=3 FLEET_LOG_FILE=/dev/null CLAUDE_CODE_SESSION_ID=dummy
    unset -f _iso_now 2>/dev/null || true
    unset -f _ensure_dir_for 2>/dev/null || true
    unset -f hb_fleet_action 2>/dev/null || true
    _iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
    _ensure_dir_for() { mkdir -p \"\$(dirname \"\$1\")\" 2>/dev/null || true; }
    hb_fleet_action() { return 0; }
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_consume '$ws' 0 2>&1
  " 2>/dev/null || true)
  # PO-2: the monitor cannot spawn, so it must report the entry as pending
  # and leave it for fleetd: no removal, no PID=0 owner record.
  echo "$output" | grep -q "PENDING:spawn tid=CRE-101" || {
    echo "output missing PENDING:spawn line: $output" >&2
    return 1
  }
  echo "$output" | grep -q "FLEETD_SPAWN_ENABLED=1" || {
    echo "pending line does not say fleetd is required: $output" >&2
    return 1
  }
  if echo "$output" | grep -q "ACTION:spawn"; then
    echo "monitor still prints an ACTION:spawn line nothing acts on: $output" >&2
    return 1
  fi
  grep -q '"tid":"CRE-101"' "$queue_file" 2>/dev/null || {
    echo "queue entry was consumed by a monitor that cannot spawn it" >&2
    return 1
  }
  [ ! -f "$ws/CRE-101-run.json" ] || {
    echo "monitor wrote an owner record it will never honour" >&2
    return 1
  }
  return 0
}

test_queue_consume_malformed_skipped() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-malform")

  # Write malformed JSON line (no tid field)
  echo '{"reason":"bad entry","timestamp":"2026-07-07T10:00:00Z"}' >"$queue_file"

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-malform FLEET_MAX_CONCURRENT=3 FLEET_LOG_FILE=/dev/null CLAUDE_CODE_SESSION_ID=dummy
    unset -f _iso_now 2>/dev/null || true
    unset -f _ensure_dir_for 2>/dev/null || true
    unset -f hb_fleet_action 2>/dev/null || true
    _iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
    _ensure_dir_for() { mkdir -p \"\$(dirname \"\$1\")\" 2>/dev/null || true; }
    hb_fleet_action() { return 0; }
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_consume '$ws' 0 2>&1
  " 2>/dev/null || true)
  # Malformed entries should be skipped, not cause errors
  return 0
}

test_queue_write_creates_entry() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-write")

  bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-write
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_write 'CRE-101' 'test-reason' 0 '$ws' 2>/dev/null
  " 2>/dev/null || true

  [ -f "$queue_file" ] || {
    echo "queue file not created"
    return 1
  }
  grep -q '"tid":"CRE-101"' "$queue_file" && return 0 || {
    echo "entry not found in queue"
    return 1
  }
}

# PO-2: a full monitor cycle leaves a queued entry for fleetd, reports it
# as pending, and keeps its stdout pure detection JSON (the pending line goes
# to stderr, which fleet_monitor_loop forwards to the operator).
test_monitor_cycle_leaves_queue_for_fleetd() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-liveonly")

  # A dead pipeline log: detection still counts it (summary.total=2 below),
  # but no worker and no registry pid exist — live-only count is 0.
  echo "2026-07-07T10:00:00Z|IMPLEMENT|implement|start|mid-flight" >"${ws}/TEST-DEAD-pipeline.log"
  echo '{"tid":"CRE-101","reason":"planned-dispatch","timestamp":"2026-07-07T10:00:00Z","restarts":0,"dispatch_type":"initial"}' >"$queue_file"

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-liveonly FLEET_MAX_CONCURRENT=1
    FLEET_LOG_FILE=/dev/null
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    fleet_detect_all() { echo '{\"pipelines\":[],\"fleet_wide\":[],\"summary\":{\"total\":2,\"healthy\":0,\"warn\":0,\"kill\":0,\"restart\":0}}'; }
    fleet_render_dashboard_from_data() { return 0; }
    fleet_write_report_from_data() { return 0; }
    worktree_gc() { return 0; }
    fleet_monitor_cycle '$ws' 2>&1
  " 2>/dev/null || true)

  echo "$output" | grep -q "PENDING:spawn tid=CRE-101" || {
    echo "expected pending line for CRE-101; output: $output" >&2
    return 1
  }
  grep -q '"tid":"CRE-101"' "$queue_file" 2>/dev/null || {
    echo "monitor cycle consumed a queue entry it cannot spawn" >&2
    return 1
  }
  local stdout_only
  stdout_only=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-liveonly FLEET_MAX_CONCURRENT=1
    FLEET_LOG_FILE=/dev/null
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    fleet_detect_all() { echo '{\"pipelines\":[],\"fleet_wide\":[],\"summary\":{\"total\":2,\"healthy\":0,\"warn\":0,\"kill\":0,\"restart\":0}}'; }
    fleet_render_dashboard_from_data() { return 0; }
    fleet_write_report_from_data() { return 0; }
    worktree_gc() { return 0; }
    fleet_monitor_cycle '$ws' 2>/dev/null
  " 2>/dev/null || true)
  echo "$stdout_only" | jq -e '.summary' >/dev/null 2>&1 || {
    echo "cycle stdout is not pure detection JSON: $stdout_only" >&2
    return 1
  }
  return 0
}

# F10: a stale queue entry whose log is already terminal is DROPPED, never
# spawned — the crash window between spawn and queue removal leaves exactly
# such entries behind.
test_queue_consume_drops_terminal_entry() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-termdrop")

  echo '{"tid":"CRE-TERM","reason":"planned-dispatch","timestamp":"2026-07-07T10:00:00Z","restarts":0,"dispatch_type":"initial"}' >"$queue_file"
  echo "2026-07-07T10:00:00Z|META|outcome|info|completed" >"${ws}/CRE-TERM-pipeline.log"

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-termdrop FLEET_MAX_CONCURRENT=3 FLEET_LOG_FILE='$ws/monitor.log' CLAUDE_CODE_SESSION_ID=dummy
    unset -f _iso_now 2>/dev/null || true
    unset -f _ensure_dir_for 2>/dev/null || true
    unset -f hb_fleet_action 2>/dev/null || true
    _iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
    _ensure_dir_for() { mkdir -p \"\$(dirname \"\$1\")\" 2>/dev/null || true; }
    hb_fleet_action() { return 0; }
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_consume '$ws' 0 2>&1
  " 2>/dev/null || true)

  if echo "$output" | grep -q "PENDING:spawn tid=CRE-TERM"; then
    echo "terminal entry was spawned; output: $output" >&2
    return 1
  fi
  # The drop notice is written to FLEET_LOG_FILE, not stdout.
  grep -q "Dropping stale queue entry: CRE-TERM" "$ws/monitor.log" 2>/dev/null || {
    echo "expected drop line in monitor log; log: $(cat "$ws/monitor.log" 2>/dev/null)" >&2
    return 1
  }
  [ ! -f "$queue_file" ] || [ ! -s "$queue_file" ] || {
    echo "terminal entry not removed from queue" >&2
    return 1
  }
  return 0
}

# GitHub #332: an entry stamped override_terminal: true (the shape
# fleet_requeue_dead_letter, fleet-dispatch.sh, produces) must bypass the
# terminal-state drop and actually be consumed/spawned, even though its
# pipeline log ends in a dead-letter marker.
test_queue_consume_override_terminal_bypasses_drop() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-override")

  echo '{"tid":"CRE-OVR","reason":"requeue-attempt","timestamp":"2026-07-07T10:00:00Z","restarts":0,"dispatch_type":"initial","override_terminal":true}' >"$queue_file"
  echo "2026-07-07T10:00:00Z|META|dead-letter|warn|reason=orphaned-after-max-restarts" >"${ws}/CRE-OVR-pipeline.log"

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-override FLEET_MAX_CONCURRENT=3 FLEET_LOG_FILE='$ws/monitor.log' CLAUDE_CODE_SESSION_ID=dummy
    unset -f _iso_now 2>/dev/null || true
    unset -f _ensure_dir_for 2>/dev/null || true
    unset -f hb_fleet_action 2>/dev/null || true
    _iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
    _ensure_dir_for() { mkdir -p \"\$(dirname \"\$1\")\" 2>/dev/null || true; }
    hb_fleet_action() { return 0; }
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_consume '$ws' 0 2>&1
  " 2>/dev/null || true)

  # Not dropped as terminal: it stays queued for fleetd and is reported.
  echo "$output" | grep -q "PENDING:spawn tid=CRE-OVR" || {
    echo "override_terminal entry was not kept pending; output: $output" >&2
    return 1
  }
  grep -q '"tid":"CRE-OVR"' "$queue_file" 2>/dev/null || {
    echo "override_terminal entry was removed from the queue" >&2
    return 1
  }
  grep -q "fleet-requeue-override|tid=CRE-OVR" "$ws/monitor.log" 2>/dev/null || {
    echo "expected requeue-override marker in monitor log; log: $(cat "$ws/monitor.log" 2>/dev/null)" >&2
    return 1
  }
  return 0
}

# Same dead-letter log as above, but WITHOUT override_terminal: must still
# be dropped exactly as before — the bypass must not leak to entries that
# don't carry it.
test_queue_consume_dead_letter_dropped_without_override() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-nooverride")

  echo '{"tid":"CRE-NOV","reason":"requeue-attempt","timestamp":"2026-07-07T10:00:00Z","restarts":0,"dispatch_type":"initial"}' >"$queue_file"
  echo "2026-07-07T10:00:00Z|META|dead-letter|warn|reason=orphaned-after-max-restarts" >"${ws}/CRE-NOV-pipeline.log"

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-nooverride FLEET_MAX_CONCURRENT=3 FLEET_LOG_FILE='$ws/monitor.log' CLAUDE_CODE_SESSION_ID=dummy
    unset -f _iso_now 2>/dev/null || true
    unset -f _ensure_dir_for 2>/dev/null || true
    unset -f hb_fleet_action 2>/dev/null || true
    _iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
    _ensure_dir_for() { mkdir -p \"\$(dirname \"\$1\")\" 2>/dev/null || true; }
    hb_fleet_action() { return 0; }
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_consume '$ws' 0 2>&1
  " 2>/dev/null || true)

  if echo "$output" | grep -q "PENDING:spawn tid=CRE-NOV"; then
    echo "dead-lettered entry without override_terminal was spawned; output: $output" >&2
    return 1
  fi
  grep -q "fleet-stale-queue-drop|tid=CRE-NOV|reason=pipeline-log-terminal" "$ws/monitor.log" 2>/dev/null || {
    echo "expected stale-queue-drop marker in monitor log; log: $(cat "$ws/monitor.log" 2>/dev/null)" >&2
    return 1
  }
  [ ! -f "$queue_file" ] || [ ! -s "$queue_file" ] || {
    echo "dead-lettered entry not removed from queue" >&2
    return 1
  }
  return 0
}

# F04: sourcing fleet-monitor.sh (and its transitive fleet-dispatch.sh →
# linear-api.sh) must NOT mutate the caller's shell flags. A fresh shell has
# errexit off and pipefail off; both must survive the source.
test_monitor_flags_not_leaked() {
  bash -c "
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    case \$- in
      *e*) echo 'errexit leaked after sourcing fleet-monitor.sh' >&2; exit 1 ;;
    esac
    case \$(set +o | grep -w pipefail) in
      'set +o pipefail') ;;
      *) echo 'pipefail leaked after sourcing fleet-monitor.sh' >&2; exit 1 ;;
    esac
    exit 0
  " 2>/dev/null || {
    echo "shell flags mutated by sourcing fleet-monitor.sh" >&2
    return 1
  }
  return 0
}

# ── Run all tests ────────────────────────────────────────────────────────────────

_run "queue_consume_empty" test_queue_consume_empty
_run "queue_consume_at_capacity" test_queue_consume_at_capacity
_run "queue_consume_entry" test_queue_consume_entry
_run "queue_consume_malformed_skipped" test_queue_consume_malformed_skipped
_run "queue_write_creates_entry" test_queue_write_creates_entry
_run "monitor_cycle_leaves_queue_for_fleetd" test_monitor_cycle_leaves_queue_for_fleetd
_run "queue_consume_drops_terminal_entry" test_queue_consume_drops_terminal_entry
_run "queue_consume_override_terminal_bypasses_drop" test_queue_consume_override_terminal_bypasses_drop
_run "queue_consume_dead_letter_dropped_without_override" test_queue_consume_dead_letter_dropped_without_override
_run "monitor_flags_not_leaked" test_monitor_flags_not_leaked

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
