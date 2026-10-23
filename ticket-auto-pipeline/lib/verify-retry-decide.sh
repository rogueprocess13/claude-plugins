#!/usr/bin/env bash
# verify-retry-decide.sh — the router's post-VERIFY retry/advance decision.
#
# Usage: verify-retry-decide.sh [--table <dispatch-table.json>] <LOG-FILE>
#
# Replaces the prose block after STEP_4_5's verify spawn in
# ticket-auto/SKILL.md, which grepped the WHOLE log for any
# `VERIFY|verify|fail|` line and compared a `{VERIFY_ATTEMPTS}` placeholder
# read BEFORE the attempt it was judging (review finding DET-RV-3). After
# "attempt 1 FAIL, attempt 2 PASS" the grep still matched attempt 1's line and
# the stale counter (1) was under the cap, so the block said "re-implement"
# after a PASS. With a stale counter a second FAIL also got one extra
# re-implement before VERIFY_EXHAUSTED.
#
# Decision — everything recomputed from the log at call time:
#   * The LATEST attempt is the last `|VERIFY|verify|done|` or
#     `|VERIFY|verify|fail|` terminal line. `done` → advance (PR review).
#   * Otherwise (latest is `fail`, or no terminal at all — a not-passed
#     attempt is never advanced) VERIFY_ATTEMPTS = count of
#     `|VERIFY|verify|fail|` lines, the same pattern detect-resume.sh and
#     fleetd's resolve_loop_counters use. VERIFY_ATTEMPTS >= cap → exhausted,
#     else retry (re-implement, then verify again).
#   * The cap is STEP_4_5's `loop.max_iterations` in dispatch-table.json (the
#     same field fleetd's evaluate_loop reads), checked post-dispatch. Falls
#     back to 2 when the table cannot be read.
#
# Output (stdout, eval-safe):
#   VERIFY_DECISION=advance|retry|exhausted
#   VERIFY_LATEST=done|fail|none
#   VERIFY_ATTEMPTS=<n>
#   VERIFY_CAP=<n>
# Exit 0 on any decision; 2 on usage error. Writes nothing — the router owns
# the gate-stop line and pipeline-finalize.sh on `exhausted`.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_VRD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_vrd_usage() {
  echo "Usage: verify-retry-decide.sh [--table <dispatch-table.json>] <LOG-FILE>" >&2
  exit 2
}

# _vrd_table_path — dispatch-table.json: sibling skills tree when run from the
# repo/plugin, else the installed plugin cache (plugin-cache.sh), else empty.
_vrd_table_path() {
  local cand="$_VRD_DIR/../skills/ticket-flow/dispatch-table.json"
  if [ -f "$cand" ]; then
    echo "$cand"
    return 0
  fi
  if [ -f "$_VRD_DIR/plugin-cache.sh" ]; then
    # shellcheck source=plugin-cache.sh
    source "$_VRD_DIR/plugin-cache.sh" 2>/dev/null || true
    if declare -f tap_cache_find >/dev/null 2>&1; then
      tap_cache_find ticket-auto-pipeline skills/ticket-flow/dispatch-table.json 2>/dev/null || true
    fi
  fi
}

verify_retry_decide() {
  local table=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --table)
      [ $# -ge 2 ] || _vrd_usage
      table="$2"
      shift 2
      ;;
    -*) _vrd_usage ;;
    *) break ;;
    esac
  done
  [ $# -eq 1 ] && [ -n "$1" ] || _vrd_usage
  local log="$1"

  [ -n "$table" ] || table=$(_vrd_table_path)
  local cap=""
  if [ -n "$table" ] && [ -f "$table" ]; then
    cap=$(jq -r '.steps[]? | select(.step_id == "STEP_4_5") | .loop.max_iterations // empty' "$table" 2>/dev/null | head -1) || cap=""
  fi
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=2

  local latest
  latest=$(grep -E '^[^|]*\|VERIFY\|verify\|(done|fail)\|' "$log" 2>/dev/null | tail -1 | awk -F'|' '{print $4}') || latest=""
  [ -n "$latest" ] || latest="none"

  local attempts
  attempts=$(grep -Ec '^[^|]*\|VERIFY\|verify\|fail\|' "$log" 2>/dev/null) || attempts=0
  attempts=${attempts:-0}

  local decision
  if [ "$latest" = "done" ]; then
    decision="advance"
  elif [ "$attempts" -ge "$cap" ]; then
    decision="exhausted"
  else
    decision="retry"
  fi

  echo "VERIFY_DECISION=$decision"
  echo "VERIFY_LATEST=$latest"
  echo "VERIFY_ATTEMPTS=$attempts"
  echo "VERIFY_CAP=$cap"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  verify_retry_decide "$@"
fi
