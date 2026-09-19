#!/usr/bin/env bash
# fence-check.sh — shared generation-fence decision logic.
#
# Extracted verbatim (decision logic only, no logging side effects) from
# flow.sh's inline fence guard (originally lines 275-335) so that both
# flow.sh's Linear mutations and lib/events.sh's outbox emissions reject a
# stale-generation call identically (tracker-event-vocabulary-and-emitter,
# design.md "Fence check is extracted into a shared helper, not duplicated").
#
# check_generation_fence never logs or echoes user-facing diagnostics itself —
# each caller owns its own log lines (flow.sh's _log/hb_gate, events.sh's
# stderr message) so this file has no logging-library dependency and stays a
# pure decision function.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention.
set -eo pipefail

_FENCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# check_generation_fence <TICKET_ID> <CALLER_GENERATION> <FLEET_STATE_DIR>
#
# Sets on return:
#   FENCE_CHECK_STATUS      one of: disabled | unfenced | current | missing-generation | superseded
#   FENCE_CHECK_FENCED_GEN  the fenced_generation value found in the marker (0 if none)
#
# Return codes:
#   0  allowed  (FENCE_CHECK_STATUS: disabled, unfenced, or current)
#   9  missing generation token on a fenced ticket
#   10 caller generation superseded by the fenced generation
check_generation_fence() {
  local ticket_id="$1"
  local caller_generation="$2"
  local fleet_state_dir="$3"

  FENCE_CHECK_STATUS="unfenced"
  FENCE_CHECK_FENCED_GEN=0

  local fence_enforce="${FLEET_FENCE_ENFORCE:-true}"
  if [ "$fence_enforce" != "true" ]; then
    FENCE_CHECK_STATUS="disabled"
    return 0
  fi

  # Discover and source fleet-config.sh (renamed from config.sh to avoid the
  # SessionStart lib-sync collision) for _fleet_fence_file constructor.
  # Look relative to this file (monorepo), then installed plugin paths.
  # The old config.sh name is kept as a fallback for installed pre-rename
  # fleet-controller versions.
  local _fence_config_sh=""
  local _cand
  for _cand in \
    "$_FENCE_LIB_DIR/../../fleet-controller/lib/fleet-config.sh" \
    "$HOME/.claude/skills/fleet-controller/lib/fleet-config.sh" \
    "$HOME/.claude/plugins/fleet-controller/lib/fleet-config.sh" \
    "$_FENCE_LIB_DIR/../../fleet-controller/lib/config.sh" \
    "$HOME/.claude/skills/fleet-controller/lib/config.sh" \
    "$HOME/.claude/plugins/fleet-controller/lib/config.sh"; do
    [ -f "$_cand" ] && {
      _fence_config_sh="$_cand"
      break
    }
  done

  local _fence_file
  if [ -n "$_fence_config_sh" ]; then
    source "$_fence_config_sh"
    _fence_file=$(_fleet_fence_file "$ticket_id" "${fleet_state_dir:-./logs}")
  else
    # Fallback: match config.sh resolution logic — FLEET_STATE_DIR takes
    # precedence, workspace-derived path second, /tmp last (backward compat).
    if [ -n "$fleet_state_dir" ]; then
      _fence_file="${fleet_state_dir}/${ticket_id}-fence"
    else
      _fence_file="/tmp/${ticket_id}-fence"
    fi
  fi

  if [ ! -f "$_fence_file" ]; then
    FENCE_CHECK_STATUS="unfenced"
    return 0
  fi

  local _fenced_gen
  _fenced_gen=$(jq -r '.fenced_generation // 0' "$_fence_file" 2>/dev/null || echo "0")
  FENCE_CHECK_FENCED_GEN="$_fenced_gen"

  # Missing generation token on a fenced ticket → refuse
  if [ -z "$caller_generation" ]; then
    FENCE_CHECK_STATUS="missing-generation"
    return 9
  fi

  # caller_gen <= fenced_gen → superseded, refuse
  if [ "$caller_generation" -le "$_fenced_gen" ] 2>/dev/null; then
    FENCE_CHECK_STATUS="superseded"
    return 10
  fi

  # caller_gen > fenced_gen → current generation, allowed
  FENCE_CHECK_STATUS="current"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  check_generation_fence "$@"
  rc=$?
  echo "FENCE_CHECK_STATUS=${FENCE_CHECK_STATUS}"
  echo "FENCE_CHECK_FENCED_GEN=${FENCE_CHECK_FENCED_GEN}"
  exit "$rc"
fi
