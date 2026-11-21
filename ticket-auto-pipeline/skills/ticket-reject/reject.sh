#!/usr/bin/env bash
# ticket-reject: the sole actuator for human rejection (tracker-approval-
# by-script). An operator script: a person runs it in their own terminal.
#
#   bash ~/.claude/skills/ticket-reject/reject.sh <TICKET-ID>
#
# Run it from the tickets root. REPOS_ROOT comes from the environment, else
# the ticket's env file, else ./CLAUDE.md.
#
# It asks on the controlling terminal for the ticket id to be typed back,
# then runs `flow.sh <TID> human-reject` and clears the approval fact
# directly — human-reject's own trigger definition returns the ticket to
# Todo for re-appraisal but is not one of flow.sh's approval-clearing
# triggers (only re-claim is, per the ticket-local-manifest spec), so this
# script clears the fact itself rather than depending on flow.sh plumbing
# that a previously-approved reject target would otherwise miss.
#
# Who may run it: the same two checks as ticket-approve/approve.sh
# (lib/human-terminal.sh), refused with exit 4 — no agent or fleetd-worker
# session, and a controlling terminal; no flag skips either. flow.sh refuses
# the human-reject trigger the same way. The same limits apply: a process
# with its own pseudo-terminal, or one that writes the manifest directly, is
# not stopped.
#
# Exit: 0 rejected, 1 usage, 2 flow.sh or a library not found, 3 manifest
#       not addressable, 4 agent context or no terminal, 5 the manifest still
#       shows an approval, 6 the typed id did not match (nothing recorded),
#       else flow.sh's code.
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
source "$LIB_DIR/human-terminal.sh" 2>/dev/null ||
  source "$SCRIPT_DIR/../../lib/human-terminal.sh" 2>/dev/null || {
  echo "ticket-reject: lib/human-terminal.sh not found — reinstall the plugin" >&2
  exit 2
}
human_terminal_require "ticket-reject" "reject $TICKET_ID" || exit 4

source "$LIB_DIR/manifest-write.sh"

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
  echo "ticket-reject: flow.sh not found — reinstall the plugin" >&2
  exit 2
fi

ensure_ticket_manifest "$TICKET_ID" || {
  echo "ticket-reject: could not make $TICKET_ID manifest-addressable" >&2
  exit 3
}

_stage=$(get_ticket_manifest_field "$TICKET_ID" stage 2>/dev/null || true)
[[ "$_stage" =~ ^[A-Za-z]+$ ]] || _stage="unknown"
_c_rc=0
human_terminal_confirm "$TICKET_ID" \
  "Reject the plan of $TICKET_ID — current stage: $_stage." \
  "This clears any approval and returns it to Todo for re-appraisal." || _c_rc=$?
if [ "$_c_rc" -eq 4 ]; then
  echo "ticket-reject: no terminal. Nothing was recorded." >&2
  exit 4
elif [ "$_c_rc" -ne 0 ]; then
  echo "ticket-reject: not rejected — the id typed did not match. Nothing was recorded." >&2
  exit 6
fi

_rc=0
bash "$FLOW_SH" "$TICKET_ID" human-reject || _rc=$?
if [ "$_rc" -ne 0 ]; then
  echo "ticket-reject: flow.sh human-reject failed (exit $_rc)" >&2
  exit "$_rc"
fi

set_ticket_approval "$TICKET_ID" false 2>/dev/null || true

APPROVED=$(get_ticket_manifest_field "$TICKET_ID" approved 2>/dev/null || true)
PROVENANCE=$(get_ticket_manifest_field "$TICKET_ID" approval_provenance 2>/dev/null || true)
STAGE=$(get_ticket_manifest_field "$TICKET_ID" stage 2>/dev/null || true)

echo "approved=${APPROVED:-false}"
echo "approval_provenance=${PROVENANCE:-}"
echo "stage=${STAGE:-}"

if [ -n "$APPROVED" ] && [ "$APPROVED" != "false" ]; then
  echo "ticket-reject: manifest still records an approval after clearing" >&2
  exit 5
fi

exit 0
