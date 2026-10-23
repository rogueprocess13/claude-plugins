#!/usr/bin/env bash
# Fleet monitor script — deterministic detection + intervention loop.
#
# Sourceable: when sourced, defines fleet_monitor_cycle and fleet_monitor_loop
#   functions without executing them.
# Executable: when run directly (bash lib/fleet-monitor.sh <workspace>),
#   invokes fleet_monitor_loop with the first argument as workspace path.
#
# The monitor never starts workers. Only fleetd with FLEETD_SPAWN_ENABLED=1
# spawns. A restart decision is written to the spawn queue, and queued
# entries are left in place for fleetd: the monitor only reports them
# (PENDING:spawn lines) and drops stale entries whose pipeline already
# finished. It used to remove entries, write a PID=0 owner record and print
# ACTION:spawn-* lines that nothing acted on, so queued work vanished.
#
# NOTE: Does NOT set -euo pipefail — this is a sourceable library.
# Callers are responsible for shell flags.

_MONITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies with declare-guard pattern
if [ -f "$_MONITOR_DIR/fleet-config.sh" ]; then
  source "$_MONITOR_DIR/fleet-config.sh"
fi

# Bridge: heartbeat.sh uses HB_LOG_FILE; fleet controller uses FLEET_HB_LOG_FILE.
[ -z "${HB_LOG_FILE:-}" ] && HB_LOG_FILE="${FLEET_HB_LOG_FILE:-}"

# Source heartbeat from canonical path (synced by ticket-auto-pipeline SessionStart hook)
if ! declare -f _plog >/dev/null 2>&1; then
  for _hp in "$_MONITOR_DIR/heartbeat.sh" "$HOME/.claude/skills/lib/heartbeat.sh"; do
    [ -f "$_hp" ] && source "$_hp" && break
  done
fi

# _source_if_missing is defined by heartbeat.sh — a stripped environment
# without the canonical heartbeat source (CI runners, hosts where the
# ticket-auto-pipeline SessionStart hook never ran) must still get the
# helper, or every dependency below silently fails to source (undefined
# function in a no-`set -e` shell is a suppressed error, not a stop).
if ! declare -f _source_if_missing >/dev/null 2>&1; then
  _source_if_missing() { declare -f "$1" >/dev/null 2>&1 || source "$2"; }
fi

_source_if_missing fleet_detect_all "$_MONITOR_DIR/fleet-detect.sh"
_source_if_missing fleet_kill_pipeline "$_MONITOR_DIR/fleet-intervene.sh"
_source_if_missing fleet_render_dashboard_from_data "$_MONITOR_DIR/fleet-dashboard.sh"
# Source registry/fence helpers if available
[ -f "$_MONITOR_DIR/fleet-registry.sh" ] && source "$_MONITOR_DIR/fleet-registry.sh"
# Campaign-resume: live-only capacity helper shared with dispatch — the
# monitor consume path must agree with fleetd on what consumes a slot.
# (fleet-dispatch.sh sources fleet-reconcile.sh for the classifier; all of
# its sources are declare -f-guarded, so no re-execution here.)
_source_if_missing _active_pipeline_count "$_MONITOR_DIR/fleet-dispatch.sh"

# Source worktree.sh for garbage collection of terminal-state worktrees
_TAP_LIB="$_MONITOR_DIR/../../ticket-auto-pipeline/lib"
if ! declare -f worktree_gc >/dev/null 2>&1; then
  [ -f "$_TAP_LIB/worktree.sh" ] && source "$_TAP_LIB/worktree.sh"
fi

# ── Fleet controller log writer ───────────────────────────────────────────────────
# Write a timestamped entry to the fleet controller's own log file.
# Usage: fl_write <level> <component> <msg>
fl_write() {
  local level="$1"
  local component="$2"
  local msg="$3"
  local log_file="${FLEET_LOG_FILE:-./logs/fleet-controller.log}"
  if [ "${FLEET_LOG_FILE:-}" = "/dev/null" ]; then
    return 0
  fi
  _ensure_dir_for "$log_file"
  echo "$(_iso_now)|${level}|${component}|${msg}" >>"$log_file"
}

# ── Spawn helpers ────────────────────────────────────────────────────────────────

# Write a restart entry to the cron spawn queue JSONL file.
# No-op in interactive mode (CLAUDE_CODE_SESSION_ID is set).
# Args: tid reason restarts [workspace]
_spawn_queue_write() {
  local tid="$1"
  local reason="$2"
  local restarts="${3:-0}"
  local workspace="${4:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local queue_file
  queue_file=$(_fleet_queue_file "$workspace")
  local entry
  entry=$(jq -nc \
    --arg tid "$tid" \
    --arg reason "$reason" \
    --arg timestamp "$(_iso_now)" \
    --argjson restarts "$restarts" \
    --argjson generation "$((restarts + 1))" \
    '{tid: $tid, reason: $reason, timestamp: $timestamp, restarts: $restarts, generation: $generation}')

  echo "$entry" >>"$queue_file"
}

# Request a restart: always written to the spawn queue, which fleetd
# (FLEETD_SPAWN_ENABLED=1) drains. The monitor itself never spawns. An
# interactive session used to get only an ACTION:spawn-restart stdout line
# that nothing acted on, so the restart was lost.
# Args: tid reason [restarts] [workspace]
_spawn_restart() {
  local tid="$1"
  local reason="$2"
  local restarts="${3:-0}"
  local workspace="${4:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  _spawn_queue_write "$tid" "$reason" "$restarts" "$workspace"
  echo "PENDING:spawn tid=${tid} reason=${reason} (queued for fleetd; monitor does not start workers)"
}

# ── Spawn queue consumption ─────────────────────────────────────────────────────

# Inspect the spawn queue on the monitor's behalf. The monitor cannot spawn
# workers, so it must not consume entries (PO-2): every live entry stays in
# the queue for fleetd, no run-registry owner record is written, and one
# `PENDING:spawn tid=...` line per entry is printed to stdout so an undrained
# queue is visible. The only entries removed are stale ones whose pipeline
# log is already terminal (`done`) — the same drop fleetd's consume applies,
# harmless because such an entry can never legitimately spawn.
# The read+rewrite is serialized under flock to prevent the race where
# fleet-dispatch.sh appends an entry between read and rewrite (which would
# destroy the newly appended entry). The name is kept for its callers.
# Usage: _spawn_queue_consume <workspace> <active_count>
_spawn_queue_consume() {
  local workspace="$1"
  local active_count="${2:-0}"
  local instance_id="${FLEET_INSTANCE_ID:-default}"
  local state_dir
  state_dir=$(_fleet_state_dir "$workspace")
  local queue_file="${state_dir}/fleet-${instance_id}-spawn-queue.jsonl"
  local lock_file="${queue_file}.lock"
  local max_concurrent="${FLEET_MAX_CONCURRENT:-3}"
  local lock_timeout="${FLEET_QUEUE_LOCK_TIMEOUT:-5}"

  if [ ! -f "$queue_file" ] || [ ! -s "$queue_file" ]; then
    return 0
  fi

  local slots_available=$((max_concurrent - active_count))
  # No early return at zero slots: stale entries whose logs are terminal
  # must still be dropped, or they reserve a capacity slot forever via
  # _fleet_queued_count_for_epic. Zero slots only means nothing spawns.

  # Acquire exclusive lock for read+rewrite. On timeout, skip this cycle
  # rather than blocking the monitor loop indefinitely.
  (
    if ! flock -w "$lock_timeout" 9 2>/dev/null; then
      fl_write "WARN" "queue" "flock timeout on spawn queue — skipping cycle"
      exit 0
    fi

    local consumed=0 pending=0
    local remaining_entries=""

    while IFS= read -r line; do
      [ -z "$line" ] && continue

      # Parse the JSONL entry
      local tid reason
      tid=$(echo "$line" | jq -r '.tid // empty' 2>/dev/null)
      [ -z "$tid" ] && remaining_entries="${remaining_entries}${line}"$'\n' && continue

      # Kill-aware terminal skip — same rule as fleetd's consume loop (the
      # Python twin is _log_reached_terminal + _consume_queue_locked). A
      # stale entry for a pipeline whose log already reached `done` (the
      # crash window between spawn and queue removal leaves exactly such
      # entries behind) must be dropped, never spawned: re-spawning
      # re-executes a finished ticket. Only a true `done` — genuine
      # completion or a dead-letter — is dropped. Killed, gate-held and
      # gate-stopped logs stay spawnable: the kill is a pause, the gate is
      # a wait, and a gate-stop's condition may since have been fixed (a
      # scoped campaign resume enqueues exactly such entries, so dropping
      # them here would silently defeat it).
      #
      # override_terminal: true (GitHub #332) is the deliberate operator
      # bypass stamped only by fleet_requeue_dead_letter (fleet-dispatch.sh)
      # — never by normal dispatch or reconciliation. It must be honored
      # HERE, at the call site, not inside fleet_ticket_terminal_state
      # itself: that function stays a pure classifier (its Python mirror,
      # _log_reached_terminal, applies the identical contract at ITS call
      # site in _consume_queue_locked — keep the two in sync).
      local override_terminal
      override_terminal=$(echo "$line" | jq -r '.override_terminal // false' 2>/dev/null)
      if [ "$override_terminal" = "true" ]; then
        fl_write "INFO" "queue" "override_terminal set on queue entry, bypassing terminal-state check: ${tid} (fleet-requeue-override|tid=${tid})"
      elif declare -f fleet_ticket_terminal_state >/dev/null 2>&1; then
        local term_state
        term_state=$(fleet_ticket_terminal_state "$tid" "${state_dir}/${tid}-pipeline.log")
        if [ "$term_state" = "done" ]; then
          fl_write "INFO" "queue" "Dropping stale queue entry: ${tid} (log terminal) (fleet-stale-queue-drop|tid=${tid}|reason=pipeline-log-terminal)"
          consumed=$((consumed + 1))
          continue
        fi
      fi

      # Live entry: leave it for fleetd. No registry write, no removal.
      reason=$(echo "$line" | jq -r '.reason // "dispatched"' 2>/dev/null)
      generation=$(echo "$line" | jq -r '.generation // 1' 2>/dev/null)
      pending=$((pending + 1))
      echo "PENDING:spawn tid=${tid} reason=${reason} generation=${generation} (not started: monitor does not start workers; run fleetd with FLEETD_SPAWN_ENABLED=1)"
      remaining_entries="${remaining_entries}${line}"$'\n'
    done <"$queue_file"

    # Rewrite queue with remaining (unconsumed) entries — atomic rename.
    # Protected by flock so concurrent appends cannot be lost.
    if [ "$consumed" -gt 0 ]; then
      if [ -n "$remaining_entries" ]; then
        local tmp_queue="${queue_file}.tmp.$$"
        echo -n "$remaining_entries" >"$tmp_queue"
        mv "$tmp_queue" "$queue_file"
      else
        rm -f "$queue_file"
      fi
    fi

    [ "$consumed" -gt 0 ] && fl_write "INFO" "queue" "Dropped ${consumed} stale queue entries"
    if [ "$pending" -gt 0 ]; then
      fl_write "WARN" "queue" "${pending} spawn queue entries waiting (${slots_available} slots free); monitor does not start workers, run fleetd with FLEETD_SPAWN_ENABLED=1 (fleet-monitor-pending|count=${pending})"
    fi
  ) 9>"$lock_file"

  return 0
}

# ── fleet_monitor_cycle ──────────────────────────────────────────────────────────
# Run one complete detection + intervention cycle.
# Returns JSON detection results to stdout.
# Usage: fleet_monitor_cycle <workspace>
fleet_monitor_cycle() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  fl_write "INFO" "monitor" "Starting monitor cycle"

  # Run detection ONCE per cycle
  local data
  if ! data=$(fleet_detect_all "$workspace" 2>/dev/null); then
    fl_write "ERROR" "monitor" "fleet_detect_all failed"
    echo '{"pipelines":[],"fleet_wide":[],"summary":{"total":0,"healthy":0,"warn":0,"kill":0,"restart":0}}'
    return 1
  fi

  # Render dashboard + report from the same detection data
  fleet_render_dashboard_from_data "$data" "$workspace" 2>/dev/null || true
  fleet_write_report_from_data "$data" "$workspace" 2>/dev/null || true

  # Execute interventions for KILL and KILL+RESTART severities
  local pipelines_json
  pipelines_json=$(echo "$data" | jq -c '.pipelines')

  echo "$pipelines_json" | jq -c '.[]' 2>/dev/null | while read -r pipeline; do
    local tid sev
    tid=$(echo "$pipeline" | jq -r '.tid')
    sev=$(echo "$pipeline" | jq -r '.severity')

    if [ "$sev" -ge 2 ]; then
      # Emit anomaly-detected heartbeat for WARN+ level pipelines
      local anomalies
      anomalies=$(echo "$pipeline" | jq -r '.anomalies')
      hb_fleet_action "anomaly-detected" "fired" "Pipeline anomaly detected" \
        "{\"tid\":\"$tid\",\"severity\":$sev,\"anomalies\":\"$anomalies\"}"

      if [ "$sev" -eq 3 ]; then
        # KILL+RESTART
        if fleet_restart_pipeline "$tid" "auto-restart" "$workspace" 2>/dev/null; then
          # Scan for fresh restart-intent markers
          if command grep -q "META|fleet-restart-marker|info|restart-intent" "${workspace}/${tid}-pipeline.log" 2>/dev/null; then
            fl_write "INFO" "monitor" "Spawning restart for ${tid}"
            _spawn_restart "$tid" "auto-restart" 0 "$workspace" >&2
          fi
        fi
      else
        # KILL only (severity 2). The triggering anomaly rides along in the
        # reason string (run-failure-classification SC7/task 9.1) so a stall
        # or watchdog kill is distinguishable from any other kill by reading
        # the pipeline log alone — "auto-kill" stays a literal prefix so any
        # existing consumer matching that bare string still matches.
        fleet_kill_pipeline "$tid" "auto-kill: ${anomalies}" "$workspace" 2>/dev/null || true
      fi
    fi
  done

  # Garbage-collect worktrees for tickets in terminal Linear states.
  # Non-fatal: a failure warns and the cycle continues.
  if declare -f worktree_gc >/dev/null 2>&1; then
    worktree_gc 2>/dev/null || {
      fl_write "WARN" "monitor" "Worktree GC failed — continuing"
    }
  fi

  fl_write "INFO" "monitor" "Monitor cycle complete"

  # Consume spawn queue (dispatch + restart entries). Slot math uses the
  # live-only pipeline count — the same helper dispatch's Step 4 uses — so
  # a dead log never consumes a capacity slot here either (fleetd's consume
  # and the monitor must agree on capacity). The dashboard's `summary.total`
  # display count is unchanged: it reports logs, not slots.
  local active_count
  active_count=$(_active_pipeline_count "$workspace" 2>/dev/null || echo "0")
  # PENDING:spawn lines go to stderr so stdout stays the detection JSON;
  # fleet_monitor_loop forwards them to the operator.
  _spawn_queue_consume "$workspace" "${active_count:-0}" >&2 2>/dev/null || true

  # Return the detection data for fleet-summary gating in the loop
  echo "$data"
}

# ── fleet_monitor_loop ───────────────────────────────────────────────────────────
# Continuous detection + intervention loop with fleet-summary state-transition
# gating. Exits cleanly when the namespaced stop file exists.
# Usage: fleet_monitor_loop <workspace>
fleet_monitor_loop() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local instance_id="${FLEET_INSTANCE_ID:-default}"
  local state_dir
  state_dir=$(_fleet_state_dir "$workspace")
  local stop_file="${state_dir}/fleet-${instance_id}-controller-stop"
  local poll_interval="${FLEET_POLL_INTERVAL:-30}"
  local summary_interval="${FLEET_SUMMARY_INTERVAL_CYCLES:-10}"

  fl_write "INFO" "monitor" "Starting monitor loop (instance=${instance_id}, interval=${poll_interval}s, stop_file=${stop_file})"
  hb_fleet_scan "cycle-start" "ok" "Monitor loop started" "{\"instance\":\"$instance_id\"}"
  echo "fleet monitor: detection and intervention only. It does not start workers; queued tickets run only under fleetd with FLEETD_SPAWN_ENABLED=1." >&2

  # Initialize fleet summary state-transition gating
  local prev_summary=""
  local cycles_since_summary=0

  while true; do
    # Check namespaced stop file before each cycle
    if [ -f "$stop_file" ]; then
      fl_write "INFO" "monitor" "Stop file detected, exiting monitor loop"
      hb_fleet_scan "cycle-end" "ok" "Monitor loop stopped (stop file)" \
        "{\"instance\":\"$instance_id\"}"
      break
    fi

    # Run one cycle
    local cycle_data
    # stderr is discarded except the PENDING:spawn lines, which tell the
    # operator that queued work is waiting for fleetd.
    cycle_data=$(fleet_monitor_cycle "$workspace" 2> >(command grep --line-buffered '^PENDING:' >&2) || true)

    # Extract current summary for state-transition gating
    local current_summary
    current_summary=$(echo "$cycle_data" | jq -c '.summary' 2>/dev/null || echo "{}")

    cycles_since_summary=$((cycles_since_summary + 1))

    # Emit fleet-summary on state change OR forced interval
    local should_emit=false
    if [ -n "$current_summary" ] && [ "$current_summary" != "$prev_summary" ]; then
      should_emit=true
    fi
    if [ "$cycles_since_summary" -ge "$summary_interval" ]; then
      should_emit=true
    fi

    if [ "$should_emit" = "true" ]; then
      local total healthy warn kill restart
      total=$(echo "$current_summary" | jq -r '.total // 0')
      healthy=$(echo "$current_summary" | jq -r '.healthy // 0')
      warn=$(echo "$current_summary" | jq -r '.warn // 0')
      kill=$(echo "$current_summary" | jq -r '.kill // 0')
      restart=$(echo "$current_summary" | jq -r '.restart // 0')

      hb_fleet_scan "fleet-summary" "info" "Fleet health summary" \
        "{\"total\":$total,\"healthy\":$healthy,\"warn\":$warn,\"kill\":$kill,\"restart\":$restart,\"cycles_since_last\":$cycles_since_summary}"

      prev_summary="$current_summary"
      cycles_since_summary=0
    fi

    sleep "$poll_interval"
  done
}

# ── Sourceable/executable guard ──────────────────────────────────────────────────
# When executed directly (not sourced), run the monitor loop.
# ${BASH_SOURCE[0]} == "$0" means this script is the entry point.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  WORKSPACE="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  fleet_monitor_loop "$WORKSPACE"
fi
