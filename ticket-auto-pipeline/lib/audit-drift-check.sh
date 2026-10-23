#!/usr/bin/env bash
# audit-drift-check.sh — Deterministic delta detection for ticket-audit re-runs.
# Compares current Linear response against snapshot inventory to find changed/new tickets.
# No LLM. Pure bash.
#
# Input (two JSON files):
#   $1: path to snapshot JSON (from ## Ticket Inventory section of previous report)
#   $2: path to current Linear response JSON (from get_milestone_issues or get_parent_with_children)
#
# Output (sourceable):
#   CHANGED_IDS="id1 id2 ..."   — tickets with newer updatedAt than snapshot
#   NEW_IDS="id3 id4 ..."       — tickets not in snapshot at all
#
# Usage:
#   source audit-drift-check.sh snapshot.json current.json
#   echo "Changed: $CHANGED_IDS"
#   echo "New: $NEW_IDS"

set -eo pipefail

audit_drift_check() {
  local snapshot_file="$1"
  local current_file="$2"

  if [ ! -f "$snapshot_file" ] || [ ! -f "$current_file" ]; then
    echo "audit-drift-check: missing input file(s)" >&2
    exit 1
  fi

  CHANGED_IDS=""
  NEW_IDS=""

  # Key on the human identifier (WIL-78), not Linear's internal UUID `.id`.
  # The snapshot comes from the report's `## Ticket Inventory` table, whose
  # ID column holds the identifier; the current Linear response carries both
  # `.id` (UUID) and `.identifier`. `(.identifier // .id)` keys both sides the
  # same way and stays compatible with callers that pre-normalized `.id`.
  local current_ids
  current_ids=$(jq -r '.[] | (.identifier // .id) // empty' "$current_file" 2>/dev/null || echo "")

  for cid in $current_ids; do
    # Get current updatedAt
    local curr_updated
    curr_updated=$(jq -r --arg id "$cid" 'first(.[] | select((.identifier // .id) == $id) | .updatedAt) // empty' "$current_file" 2>/dev/null || echo "")

    # Check if this ID exists in snapshot
    local snap_updated
    snap_updated=$(jq -r --arg id "$cid" 'first(.[] | select((.identifier // .id) == $id) | .updatedAt) // empty' "$snapshot_file" 2>/dev/null || echo "")

    if [ -z "$snap_updated" ]; then
      # Not in snapshot → new ticket
      NEW_IDS="$NEW_IDS $cid"
    elif [ -n "$curr_updated" ] && [ "$curr_updated" != "$snap_updated" ]; then
      # Legacy inventories store a date only (2026-05-01). Any full ISO
      # timestamp sorts lexicographically after a bare date, so comparing
      # them directly flagged every ticket touched on the snapshot day as
      # CHANGED. When the snapshot is date-only, compare at date precision.
      local curr_cmp="$curr_updated"
      if [[ "$snap_updated" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        curr_cmp="${curr_updated:0:10}"
      fi
      # Compare ISO timestamps lexicographically (works for ISO 8601)
      if [[ "$curr_cmp" > "$snap_updated" ]]; then
        CHANGED_IDS="$CHANGED_IDS $cid"
      fi
    fi
  done

  # Trim leading/trailing whitespace
  CHANGED_IDS=$(echo "$CHANGED_IDS" | xargs)
  NEW_IDS=$(echo "$NEW_IDS" | xargs)

  echo "CHANGED_IDS=\"$CHANGED_IDS\""
  echo "NEW_IDS=\"$NEW_IDS\""
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  audit_drift_check "$@"
fi
