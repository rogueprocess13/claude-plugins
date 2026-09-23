#!/usr/bin/env bash
# ticket-reject: the sole actuator for human rejection (tracker-approval-
# by-script). Wraps `flow.sh <TID> human-reject` and then clears the
# approval fact directly — human-reject's own trigger definition returns the
# ticket to Todo for re-appraisal but is not one of flow.sh's approval-
# clearing triggers (only re-claim is, per the ticket-local-manifest spec),
# so this script clears the fact itself rather than depending on flow.sh
# plumbing that a previously-approved reject target would otherwise miss.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
source "$LIB_DIR/manifest-write.sh"

usage() {
  echo "Usage: $0 <TICKET-ID>" >&2
  exit 1
}

TICKET_ID="${1:-}"
[ -n "$TICKET_ID" ] || usage

# ── Resolve flow.sh (standard _flow_sh pattern, lib/skill-preamble-auto.md) ─
# FLOW_SH, if already set by the caller (tests), is respected as-is.

if [ -z "${FLOW_SH:-}" ]; then
  FLOW_SH="$HOME/.claude/skills/ticket-flow/flow.sh"
  [ -f "$FLOW_SH" ] || FLOW_SH=$(find "$HOME/.claude/plugins/cache" -name "flow.sh" \
    -path "*/ticket-auto-pipeline/*/skills/ticket-flow/flow.sh" 2>/dev/null | sort | tail -1)
fi
if [ -z "$FLOW_SH" ] || [ ! -f "$FLOW_SH" ]; then
  echo "ticket-reject: flow.sh not found — reinstall the plugin" >&2
  exit 2
fi

ensure_ticket_manifest "$TICKET_ID" || {
  echo "ticket-reject: could not make $TICKET_ID manifest-addressable" >&2
  exit 3
}

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
  exit 4
fi

exit 0
