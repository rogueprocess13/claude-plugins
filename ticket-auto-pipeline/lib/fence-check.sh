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
#
# set -eo pipefail only when executed directly, never when sourced — this is
# a sourceable library (flow.sh and lib/events.sh both source it
# unconditionally at file scope), and check_generation_fence already handles
# its own failure paths explicitly. Same fix as lib/events.sh — see its
# comment for the fuller rationale.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -eo pipefail
fi

_FENCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# check_generation_fence <TICKET_ID> <CALLER_GENERATION> <FLEET_STATE_DIR>
#
# Sets on return:
#   FENCE_CHECK_STATUS      one of: disabled | unfenced | current | non-participant
#                           | missing-generation | superseded | malformed
#   FENCE_CHECK_FENCED_GEN  the fenced_generation value found in the marker (0 if none)
#
# Return codes:
#   0  allowed  (FENCE_CHECK_STATUS: disabled, unfenced, current, or
#      non-participant)
#   9  missing generation token on a fenced ticket, from a fleetd worker
#   10 caller generation superseded by the fenced generation, or either
#      value is not a non-negative integer (malformed — refuse, never allow)
#
# Who is fenced. The fence exists to stop a superseded fleetd worker from
# writing after fleetd killed it. Every fleetd worker carries both
# FLEET_WORKER_PID and FLEET_GENERATION (fleetd/supervisor.py spawn_worker),
# and every process it starts inherits them. A caller with no generation
# token AND no FLEET_WORKER_PID was never a fleetd generation — a human
# running /ticket-approve, or fleetd itself running a hold-release trigger —
# so it cannot be a superseded one, and is allowed as "non-participant".
# Refusing it (the old behaviour) locked every such caller out of a ticket
# for good once it had been killed even once, since the fence marker is a
# monotonic watermark that is never cleared (review ARCH-1). A worker that
# has FLEET_WORKER_PID but lost its token is still refused with 9.
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
  # A marker that does not parse is "malformed", not generation 0: reading
  # it as 0 let every caller through (review QA-6).
  _fenced_gen=$(jq -r '.fenced_generation // 0' "$_fence_file" 2>/dev/null) || _fenced_gen="malformed"
  FENCE_CHECK_FENCED_GEN="$_fenced_gen"

  # Missing generation token on a fenced ticket. A non-participant (no
  # FLEET_WORKER_PID either) is allowed — see the header comment.
  if [ -z "$caller_generation" ]; then
    if [ -z "${FLEET_WORKER_PID:-}" ]; then
      FENCE_CHECK_STATUS="non-participant"
      return 0
    fi
    FENCE_CHECK_STATUS="missing-generation"
    return 9
  fi

  # Both values must be plain non-negative integers. Anything else used to
  # make the `-le` test error out, which read as "not superseded" and
  # allowed the write. Refuse instead.
  if ! [[ "$caller_generation" =~ ^[0-9]+$ ]] || ! [[ "$_fenced_gen" =~ ^[0-9]+$ ]]; then
    FENCE_CHECK_STATUS="malformed"
    return 10
  fi

  # caller_gen <= fenced_gen → superseded, refuse
  if [ "$((10#$caller_generation))" -le "$((10#$_fenced_gen))" ]; then
    FENCE_CHECK_STATUS="superseded"
    return 10
  fi

  # caller_gen > fenced_gen → current generation, allowed
  FENCE_CHECK_STATUS="current"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  # `|| rc=$?`, not a bare call: under set -e a refusal (9/10) used to exit
  # here before the status lines below were printed (review QA-6).
  rc=0
  check_generation_fence "$@" || rc=$?
  echo "FENCE_CHECK_STATUS=${FENCE_CHECK_STATUS}"
  echo "FENCE_CHECK_FENCED_GEN=${FENCE_CHECK_FENCED_GEN}"
  exit "$rc"
fi
