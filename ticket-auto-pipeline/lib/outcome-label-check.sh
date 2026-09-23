#!/usr/bin/env bash
# outcome-label-check.sh — post-implement guard that verifies the
# Smooth/Rough/Hard outcome classification is recorded in the ticket's
# local manifest, writing it if missing.
#
# tracker-flow-projection-cutover: the outcome was never a real Linear
# label read (D10/the projection table names only needs-info/needs-adr/
# rejected/reviewed) — flow.sh's implement-outcome trigger has always had
# a null destination and, after the {outcome} placeholder strip, no label
# delta at all. This file's own live re-fetch of the "outcome label" was
# therefore a self-check on its own write, never on a real tracker
# mutation; it now reads/writes the manifest directly and no longer
# touches the tracker at all.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
source "$LIB_DIR/heartbeat.sh"
# manifest-write.sh (which sources manifest-read.sh) is the only external
# dependency now — no tracker client, no flow.sh resolution. Guarded — a
# fresh install syncs lib/*.sh together, but this file is also copied
# standalone in some test fixtures.
if [ -f "$LIB_DIR/manifest-write.sh" ]; then
  source "$LIB_DIR/manifest-write.sh"
elif [ -f "$SCRIPT_DIR/manifest-write.sh" ]; then
  source "$SCRIPT_DIR/manifest-write.sh"
fi

usage() {
  echo "Usage: $0 <TICKET-ID> <LOG-FILE>" >&2
  exit 1
}

# ── Core logic ─────────────────────────────────────────────────────────────────

OUTCOME_LABELS="Smooth Rough Hard"

# Extract OUTCOME from pipeline log IMPLEMENT|implement-outcome| line.
# This is written by the implement agent after flow.sh applies the label.
# Tightened from IMPLEMENT|implement|done| to avoid matching prose lines
# like "2 files changed" that share the same phase/step prefix but are not
# the outcome declaration.
_get_outcome_from_log() {
  local outcome
  outcome=$(grep '^[^|]*|IMPLEMENT|implement-outcome|info|' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5- || true)

  # Fallback: agents sometimes report the outcome only inside an
  # IMPLEMENT|implement|done| line and never invoke the flow.sh
  # implement-outcome trigger that writes the dedicated entry above
  # (WIL-78, 2026-09-10 — required a live router repair). Recover it, but
  # only as a standalone Smooth/Rough/Hard token so prose like "2 files
  # changed" still cannot match — the reason this matcher was tightened
  # away from IMPLEMENT|implement|done| in the first place.
  if [ -z "$outcome" ]; then
    outcome=$(grep '^[^|]*|IMPLEMENT|implement|done|' "$LOG_FILE" 2>/dev/null |
      grep -oE '\b(Smooth|Rough|Hard)\b' | tail -1 || true)
    if [ -n "$outcome" ]; then
      echo "outcome-label-check: recovered '$outcome' from IMPLEMENT|implement|done| (dedicated line absent)" >&2
    fi
  fi

  echo "$outcome"
}

# _manifest_has_outcome_label — true when the manifest already carries an
# outcome_label value. No tracker read: the manifest is the only place
# this value has ever been written.
_manifest_has_outcome_label() {
  declare -f get_ticket_manifest_field >/dev/null 2>&1 || return 1
  local current
  current=$(get_ticket_manifest_field "$TICKET_ID" outcome_label 2>/dev/null)
  [ -n "$current" ]
}

_outcome_label_check() {
  local outcome

  # Read outcome from pipeline log
  outcome=$(_get_outcome_from_log)
  if [ -z "$outcome" ]; then
    echo "No IMPLEMENT|implement-outcome|info| line found in pipeline log" >&2
    return 1
  fi

  # Validate outcome is one of Smooth/Rough/Hard
  local valid=false
  for ol in $OUTCOME_LABELS; do
    [ "$outcome" = "$ol" ] && valid=true
  done
  if [ "$valid" != "true" ]; then
    echo "Unknown outcome: $outcome (expected Smooth, Rough, or Hard)" >&2
    return 1
  fi

  # If outcome already recorded, exit clean
  if _manifest_has_outcome_label; then
    hb_gate "outcome-check" "ok" "outcome label already present" "{\"outcome\":\"$outcome\"}"
    _plog "$LOG_FILE" "META" "outcome-label" "info" "$outcome"
    return 0
  fi

  _mirror_outcome_to_manifest "$outcome"

  hb_gate "outcome-check" "ok" "outcome label applied" "{\"outcome\":\"$outcome\"}"
  # Authoritative source for auto-merge eligibility (ticket-auto/SKILL.md
  # Auto-merge logic) — the manifest's outcome_label, not the implement
  # terminal line.
  _plog "$LOG_FILE" "META" "outcome-label" "info" "$outcome"
  return 0
}

# _mirror_outcome_to_manifest <outcome>
# tracker-local-facts-read-migration (task 5.11/1.7), now the write of
# record (tracker-flow-projection-cutover task 8.5) — records the
# confirmed Smooth/Rough/Hard classification into the ticket's local
# manifest. A missing manifest (a ticket predating manifest addressability)
# is a silent no-op, never a failure of the outcome-label check itself.
_mirror_outcome_to_manifest() {
  local outcome="$1"
  declare -f write_ticket_outcome_label >/dev/null 2>&1 || return 0
  write_ticket_outcome_label "$TICKET_ID" "$outcome" 2>/dev/null || true
}

# ── Dispatch (only when executed directly) ─────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  TICKET_ID="${1:-}"
  LOG_FILE="${2:-}"

  [ -z "$TICKET_ID" ] && usage
  [ -z "$LOG_FILE" ] && usage

  hb_init
  _outcome_label_check
fi
