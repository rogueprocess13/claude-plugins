#!/usr/bin/env bash
# ticket-approve: the sole actuator for human approval (tracker-approval-
# by-script). An operator script: a person runs it in their own terminal.
#
#   bash ~/.claude/skills/ticket-approve/approve.sh <TICKET-ID>
#
# Run it from the tickets root. REPOS_ROOT comes from the environment, else
# the ticket's env file, else ./CLAUDE.md.
#
# It shows the ticket and its current stage on the controlling terminal and
# asks for the ticket id to be typed back. Only a matching answer runs
# `flow.sh <TID> human-approve --provenance human` (Approve -> Ready,
# manifest approved: true / approval_provenance: human) and, when the
# manifest carries the needs-info flag, `flow.sh <TID> needs-info-resolved`.
# Applying the (now unread) `approved` label in the tracker's own UI does not
# approve a ticket: only this script does.
#
# Who may run it (lib/human-terminal.sh), both refused with exit 4:
#   1. CLAUDE_CODE_SESSION_ID, FLEET_WORKER_PID or FLEET_GENERATION is set
#      (an agent session or a fleetd worker).
#   2. There is no controlling terminal. The prompt is written to and the
#      answer read from /dev/tty, never stdin.
# There is no flag and no variable that skips either check, and flow.sh and
# the manifest writer apply the same refusal for provenance human, so calling
# them directly is no way round. The /ticket-approve skill therefore does not
# run this script: it prints the command for the person to run.
#
# What this guarantees: an unattended agent run, and an agent that only
# unsets the variables, cannot record a human approval. What it does not: a
# process that allocates its own pseudo-terminal and types the id can, and so
# can anything that writes the manifest file directly. Closing that needs a
# store the agent cannot write.
#
# Exit: 0 approved (or already approved), 1 usage, 2 flow.sh or a library
#       not found, 3 manifest not addressable, 4 agent context or no
#       terminal, 5 the manifest does not show the approval after the write,
#       6 the typed id did not match (nothing recorded), else flow.sh's code.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"

usage() {
  echo "Usage: $0 <TICKET-ID>" >&2
  exit 1
}

TICKET_ID="${1:-}"
[ -n "$TICKET_ID" ] || usage
[ $# -eq 1 ] || usage
[[ "$TICKET_ID" =~ ^[A-Z]+-[0-9]+$ ]] || usage

# ── A person, at a terminal ─────────────────────────────────────────────────
# First, before anything is read or written. A missing library is a refusal.
source "$LIB_DIR/human-terminal.sh" 2>/dev/null ||
  source "$SCRIPT_DIR/../../lib/human-terminal.sh" 2>/dev/null || {
  echo "ticket-approve: lib/human-terminal.sh not found — reinstall the plugin" >&2
  exit 2
}
human_terminal_require "ticket-approve" "approve $TICKET_ID" || exit 4

source "$LIB_DIR/manifest-write.sh"

# REPOS_ROOT in a person's own shell: the environment, else the ticket's env
# file, else the project CLAUDE.md in the current directory.
if [ -z "${REPOS_ROOT:-}" ] && [ -f "$LIB_DIR/ticket-env.sh" ]; then
  # shellcheck source=/dev/null
  source "$LIB_DIR/ticket-env.sh" "$TICKET_ID" 2>/dev/null || true
fi
if [ -z "${REPOS_ROOT:-}" ] && [ -f ./CLAUDE.md ]; then
  source "$LIB_DIR/claude-md-field.sh" 2>/dev/null ||
    source "$SCRIPT_DIR/../../lib/claude-md-field.sh" 2>/dev/null || true
  if declare -f claude_md_field >/dev/null 2>&1; then
    REPOS_ROOT=$(claude_md_field ./CLAUDE.md REPOS_ROOT 2>/dev/null) || REPOS_ROOT=""
  fi
fi
[ -z "${REPOS_ROOT:-}" ] || export REPOS_ROOT

# ── Resolve flow.sh (standard _flow_sh pattern, lib/skill-preamble-auto.md) ─
# FLOW_SH, if already set by the caller (tests), is respected as-is.

if [ -z "${FLOW_SH:-}" ]; then
  FLOW_SH="$HOME/.claude/skills/ticket-flow/flow.sh"
  if [ ! -f "$FLOW_SH" ]; then
    source "$LIB_DIR/plugin-cache.sh" 2>/dev/null ||
      source "$SCRIPT_DIR/../../lib/plugin-cache.sh" 2>/dev/null || true
    FLOW_SH=$(tap_cache_find ticket-auto-pipeline skills/ticket-flow/flow.sh 2>/dev/null || true)
  fi
fi
if [ -z "$FLOW_SH" ] || [ ! -f "$FLOW_SH" ]; then
  echo "ticket-approve: flow.sh not found — reinstall the plugin" >&2
  exit 2
fi

# Manifest-addressable before flow.sh runs, so a ticket created outside the
# planner is never silently no-op'd (D2). flow.sh calls this again itself —
# idempotent, so the duplicate call costs nothing and this script's own
# correctness doesn't depend on flow.sh's internals.
ensure_ticket_manifest "$TICKET_ID" || {
  echo "ticket-approve: could not make $TICKET_ID manifest-addressable" >&2
  exit 3
}

# One approval is one fact (GitHub #767). flow.sh emits an event on every
# invocation by design, so a second /ticket-approve on a ticket this script
# already approved used to write a second `human-approved` record with a new
# idem key. When the manifest already records exactly what this run would
# write — approved, by a human, at Ready — there is nothing to approve:
# report it and fire nothing. Anything that ends the approval (re-claim,
# /ticket-reject, implement-complete) clears the fact or moves the stage, so a
# real re-approval after a re-hold still fires, and a human approving over a
# policy approval still records the new provenance. A manifest still holding
# a pending_event (an earlier emit failed) goes through flow.sh, which
# replays it.
ALREADY_APPROVED="false"
_pending=$(get_ticket_manifest_field "$TICKET_ID" pending_event 2>/dev/null || true)
if { [ -z "$_pending" ] || [ "$_pending" = "null" ]; } &&
  [ "$(get_ticket_manifest_field "$TICKET_ID" approved 2>/dev/null || true)" = "true" ] &&
  [ "$(get_ticket_manifest_field "$TICKET_ID" approval_provenance 2>/dev/null || true)" = "human" ] &&
  [ "$(get_ticket_manifest_field "$TICKET_ID" stage 2>/dev/null || true)" = "Ready" ]; then
  ALREADY_APPROVED="true"
fi

# ── Confirmation ────────────────────────────────────────────────────────────
# Asked whenever this run would change anything: the approval itself, or the
# needs-info clear below. The stage is the manifest's; it is printed only
# when it is a plain word.
NEEDS_INFO_SET="false"
if declare -f ticket_dispatch_blocked_by_flags >/dev/null 2>&1 &&
  ticket_dispatch_blocked_by_flags "$TICKET_ID" 2>/dev/null; then
  NEEDS_INFO_SET="true"
fi
if [ "$ALREADY_APPROVED" != "true" ] || [ "$NEEDS_INFO_SET" = "true" ]; then
  _stage=$(get_ticket_manifest_field "$TICKET_ID" stage 2>/dev/null || true)
  [[ "$_stage" =~ ^[A-Za-z]+$ ]] || _stage="unknown"
  _lines=("Approve $TICKET_ID — current stage: $_stage.")
  if [ "$ALREADY_APPROVED" = "true" ]; then
    _lines+=("It is already approved. This clears its needs-info flag.")
  else
    _lines+=("This records your approval of its plan and moves it to Ready.")
    [ "$_stage" = "Approve" ] || _lines+=("Note: it is not at the Approve stage. Check that this is the ticket you mean.")
    [ "$NEEDS_INFO_SET" != "true" ] || _lines+=("It also clears the needs-info flag.")
  fi
  _lines+=("Read the plan and the appraisal comment first; answer open questions before you approve.")
  _c_rc=0
  human_terminal_confirm "$TICKET_ID" "${_lines[@]}" || _c_rc=$?
  if [ "$_c_rc" -eq 4 ]; then
    echo "ticket-approve: no terminal. Nothing was recorded." >&2
    exit 4
  elif [ "$_c_rc" -ne 0 ]; then
    echo "ticket-approve: not approved — the id typed did not match. Nothing was recorded." >&2
    exit 6
  fi
fi

if [ "$ALREADY_APPROVED" != "true" ]; then
  _rc=0
  bash "$FLOW_SH" "$TICKET_ID" human-approve --provenance human || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    echo "ticket-approve: flow.sh human-approve failed (exit $_rc)" >&2
    exit "$_rc"
  fi
fi

APPROVED=$(get_ticket_manifest_field "$TICKET_ID" approved 2>/dev/null || true)
PROVENANCE=$(get_ticket_manifest_field "$TICKET_ID" approval_provenance 2>/dev/null || true)
STAGE=$(get_ticket_manifest_field "$TICKET_ID" stage 2>/dev/null || true)

echo "approved=${APPROVED:-false}"
echo "approval_provenance=${PROVENANCE:-}"
echo "stage=${STAGE:-}"
echo "already_approved=${ALREADY_APPROVED}"

if [ "$APPROVED" != "true" ]; then
  echo "ticket-approve: manifest does not reflect the approval after flow.sh succeeded" >&2
  exit 5
fi

# needs-info clear (dor-readiness-gate-foundation task 6.3) — the first call
# site for the needs-info-resolved trigger, declared in workflow.json with
# zero callers before this change. Approval is the moment a human has, by
# definition, just looked at the ticket, so clearing the flag here is what
# lets a ticket gate-stopped at Check 2.7e for FLAG_NEEDS_INFO become
# dispatchable again immediately, regardless of whether its cached `ready`
# object is stale (design.md Decision 8, Decision 3). No-op when the flag
# isn't set.
NEEDS_INFO_CLEARED="false"
if [ "$NEEDS_INFO_SET" = "true" ]; then
  _ni_rc=0
  bash "$FLOW_SH" "$TICKET_ID" needs-info-resolved || _ni_rc=$?
  if [ "$_ni_rc" -eq 0 ]; then
    NEEDS_INFO_CLEARED="true"
  else
    echo "ticket-approve: flow.sh needs-info-resolved failed (exit $_ni_rc) — needs-info flag not cleared" >&2
  fi
fi
echo "needs_info_cleared=${NEEDS_INFO_CLEARED}"
echo "Re-run /ticket-auto $TICKET_ID to continue."

exit 0
