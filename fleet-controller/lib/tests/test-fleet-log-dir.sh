#!/usr/bin/env bash
# test-fleet-log-dir.sh — fleet-controller's bash readers take their default
# per-ticket log dir from ticket-auto-pipeline's lib/log-dir.sh resolver
# (state-root-anchor, PR B, task 5.1), through lib/fleet-log-dir.sh.
# Each case runs in a subshell with a temp REPOS_ROOT and a foreign cwd.
# Usage: bash test-fleet-log-dir.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if ("$@") 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# _sandbox — sets ROOT (REPOS_ROOT), ANCHORED (anchored log dir), FOREIGN (a
# cwd whose ./logs is not the anchored dir), cds to FOREIGN. Subshell only.
_sandbox() {
  ROOT=$(cd "$(mktemp -d)" && pwd -P)
  ANCHORED="$ROOT/ws/logs"
  FOREIGN="$ROOT/repo-a/src"
  mkdir -p "$ANCHORED" "$FOREIGN" "$ROOT/.ticket-auto"
  printf '%s\n' "$ANCHORED" >"$ROOT/.ticket-auto/log-dir"
  unset FLEET_PIPELINE_LOG_DIR FLEET_STATE_DIR STATE_ROOT_STRICT
  export REPOS_ROOT="$ROOT"
  cd "$FOREIGN"
  trap 'rm -rf "$ROOT"' EXIT
}

_need() {
  declare -f "$1" >/dev/null || {
    echo "$1 missing" >&2
    return 1
  }
}

test_helper_resolves_anchor_env_and_fallback() {
  _sandbox
  [ -f "$LIB_DIR/fleet-log-dir.sh" ] || return 1
  source "$LIB_DIR/fleet-log-dir.sh"
  _need fleet_log_dir_or || return 1
  [ "$(fleet_log_dir_or ./logs)" = "$ANCHORED" ] || return 1
  [ "$(FLEET_PIPELINE_LOG_DIR=./rel fleet_log_dir_or ./rel)" = "$ANCHORED" ] || return 1
  [ "$(FLEET_PIPELINE_LOG_DIR=/abs fleet_log_dir_or ./logs)" = "/abs" ] || return 1
  rm "$ROOT/.ticket-auto/log-dir"
  [ "$(fleet_log_dir_or ./logs)" = "./logs" ] || return 1
  [ "$(FLEET_PIPELINE_LOG_DIR=rel-x fleet_log_dir_or "${FLEET_PIPELINE_LOG_DIR:-./logs}")" = "./logs" ] || return 1
  # quiet: no legacy warning, no strict refusal
  [ -z "$(STATE_ROOT_STRICT=true fleet_log_dir_or ./logs 2>&1 >/dev/null)" ]
}

test_detect_workspace_guard_reads_anchor() {
  _sandbox
  source "$LIB_DIR/fleet-detect.sh"
  local out
  out=$(_fleet_workspace_guard)
  [ "$(echo "$out" | jq -r '.severity')" = "0" ] || return 1
  [ ! -e "$FOREIGN/logs" ]
}

test_detect_all_reads_anchor() {
  _sandbox
  source "$LIB_DIR/fleet-detect.sh"
  local out
  out=$(fleet_detect_all 2>/dev/null) || return 1
  # The workspace guard would report "does not exist" for ./logs.
  [[ "$out" != *"does not exist"* ]] || return 1
  [ ! -e "$FOREIGN/logs" ]
}

test_dashboard_report_goes_to_anchor() {
  _sandbox
  source "$LIB_DIR/fleet-dashboard.sh"
  fleet_write_report >/dev/null 2>&1 || true
  [ -f "$ANCHORED/reports/fleet-dashboard.md" ] || return 1
  [ ! -e "$FOREIGN/logs" ]
}

test_store_path_uses_anchor() {
  _sandbox
  source "$LIB_DIR/fleet-store.sh"
  [ "$(_fleet_store_path)" = "$ANCHORED/fleet-state.db" ] || return 1
  # FLEET_STATE_DIR still wins (Non-Goal: fleetd's own setting).
  [ "$(FLEET_STATE_DIR=/state _fleet_store_path)" = "/state/fleet-state.db" ]
}

test_registry_default_uses_anchor() {
  _sandbox
  source "$LIB_DIR/fleet-registry.sh"
  printf '{"tid":"T-1","pid":"1","generation":2}\n' >"$ANCHORED/T-1-run.json"
  [ "$(registry_generation T-1)" = "2" ]
}

test_monitor_and_dispatch_defaults_use_anchor() {
  _sandbox
  source "$LIB_DIR/fleet-monitor.sh"
  source "$LIB_DIR/fleet-dispatch.sh"
  _need fleet_log_dir_or || return 1
  # Every former ${FLEET_PIPELINE_LOG_DIR:-./logs} default in the D7 readers
  # now goes through the resolver.
  local f
  for f in fleet-detect fleet-dashboard fleet-monitor fleet-dispatch \
    fleet-intervene fleet-feedback fleet-registry fleet-store; do
    if grep -nE '(\$\{[0-9]:-\$\{FLEET_PIPELINE_LOG_DIR:-\./logs\}\}|="\$\{FLEET_PIPELINE_LOG_DIR:-\./logs\}"|:-\./logs\}"$|_fleet_state_dir \./logs\))' \
      "$LIB_DIR/$f.sh" >&2; then
      echo "$f.sh still defaults to ./logs" >&2
      return 1
    fi
  done
}

test_unanchored_keeps_todays_default() {
  _sandbox
  rm "$ROOT/.ticket-auto/log-dir"
  source "$LIB_DIR/fleet-store.sh"
  [ "$(_fleet_store_path)" = "./logs/fleet-state.db" ] || return 1
  [ "$(FLEET_PIPELINE_LOG_DIR=rel-x _fleet_store_path)" = "rel-x/fleet-state.db" ]
}

FILTER="${1:-}"
for fn in \
  test_helper_resolves_anchor_env_and_fallback \
  test_detect_workspace_guard_reads_anchor \
  test_detect_all_reads_anchor \
  test_dashboard_report_goes_to_anchor \
  test_store_path_uses_anchor \
  test_registry_default_uses_anchor \
  test_monitor_and_dispatch_defaults_use_anchor \
  test_unanchored_keeps_todays_default; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
