#!/usr/bin/env bash
# ticket-approve: the sole actuator for human approval (tracker-approval-
# by-script). Wraps `flow.sh <TID> human-approve --provenance human` and
# reports the resulting manifest fields. Applying the (now unread) `approved`
# label in the tracker's own UI does not approve a ticket — only this script
# does.
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

_rc=0
bash "$FLOW_SH" "$TICKET_ID" human-approve --provenance human || _rc=$?
if [ "$_rc" -ne 0 ]; then
  echo "ticket-approve: flow.sh human-approve failed (exit $_rc)" >&2
  exit "$_rc"
fi

APPROVED=$(get_ticket_manifest_field "$TICKET_ID" approved 2>/dev/null || true)
PROVENANCE=$(get_ticket_manifest_field "$TICKET_ID" approval_provenance 2>/dev/null || true)
STAGE=$(get_ticket_manifest_field "$TICKET_ID" stage 2>/dev/null || true)

echo "approved=${APPROVED:-false}"
echo "approval_provenance=${PROVENANCE:-}"
echo "stage=${STAGE:-}"

if [ "$APPROVED" != "true" ]; then
  echo "ticket-approve: manifest does not reflect the approval after flow.sh succeeded" >&2
  exit 4
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
if declare -f ticket_dispatch_blocked_by_flags >/dev/null 2>&1 &&
  ticket_dispatch_blocked_by_flags "$TICKET_ID" 2>/dev/null; then
  _ni_rc=0
  bash "$FLOW_SH" "$TICKET_ID" needs-info-resolved || _ni_rc=$?
  if [ "$_ni_rc" -eq 0 ]; then
    NEEDS_INFO_CLEARED="true"
  else
    echo "ticket-approve: flow.sh needs-info-resolved failed (exit $_ni_rc) — needs-info flag not cleared" >&2
  fi
fi
echo "needs_info_cleared=${NEEDS_INFO_CLEARED}"

exit 0
