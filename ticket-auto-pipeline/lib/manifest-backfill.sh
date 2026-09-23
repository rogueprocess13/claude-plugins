#!/usr/bin/env bash
# manifest-backfill.sh — one-shot, idempotent seed of approved/
# approval_provenance/stage from the tracker for tickets already in flight
# when tracker-approval-by-script lands (design D5). Operator-invoked only
# — never auto-run at fleetd start, so a tracker outage at boot never looks
# like mass un-approval. The last tracker read of approval state the system
# ever performs; every decision read after this ships is manifest-only.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$SCRIPT_DIR}"
source "$LIB_DIR/manifest-write.sh"
source "$LIB_DIR/linear-api.sh"

usage() {
  echo "Usage: $0 [--dry-run] [LOG-DIR]" >&2
  echo "  LOG-DIR defaults to \$FLEET_PIPELINE_LOG_DIR, else ./logs" >&2
  exit 1
}

DRY_RUN=false
LOG_DIR=""
for arg in "$@"; do
  case "$arg" in
  --dry-run) DRY_RUN=true ;;
  -h | --help) usage ;;
  -*)
    echo "manifest-backfill: unknown flag '$arg'" >&2
    usage
    ;;
  *) LOG_DIR="$arg" ;;
  esac
done
LOG_DIR="${LOG_DIR:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

[ -d "$LOG_DIR" ] || {
  echo "manifest-backfill: no such log directory: $LOG_DIR" >&2
  exit 1
}

seeded=0
skipped=0
failed=0

for log_file in "$LOG_DIR"/*-pipeline.log; do
  [ -f "$log_file" ] || continue
  tid=$(basename "$log_file")
  tid="${tid%-pipeline.log}"
  [ -n "$tid" ] || continue

  # Already carrying both fields — idempotent skip. ensure_ticket_manifest
  # first so an ad-hoc ticket (no prior manifest at all) is addressable
  # before this check reads it. Dry-run skips it deliberately — it must
  # never create the ad-hoc index entry it's only reporting on; reading a
  # not-yet-provisioned ticket's fields below just falls through to
  # "would seed", same as any other missing-manifest ticket.
  if ! $DRY_RUN; then
    ensure_ticket_manifest "$tid" || {
      echo "$tid: FAIL (could not make manifest-addressable)"
      failed=$((failed + 1))
      continue
    }
  fi

  # Idempotency marker: `stage` alone, not `stage` AND `approved` together.
  # `approved` is only ever present when the live read found the ticket
  # actually approved — set_ticket_approval deletes rather than falsing it
  # (manifest-write.sh) — so a not-yet-approved ticket would never carry an
  # `approved` field even after a completed backfill, and requiring both
  # fields would re-fetch it, unproductively, on every single re-run.
  # `stage` is written unconditionally whenever the live state resolves, so
  # its presence alone proves this ticket has already been processed.
  existing_stage_rc=0
  existing_stage=$(get_ticket_manifest_field "$tid" stage 2>/dev/null) || existing_stage_rc=$?

  if [ "$existing_stage_rc" -eq 0 ] && [ -n "$existing_stage" ]; then
    echo "$tid: SKIP (already carries stage)"
    skipped=$((skipped + 1))
    continue
  fi

  issue_json=$(get_issue "$tid" 2>/dev/null) || issue_json=""
  if [ -z "$issue_json" ] || ! echo "$issue_json" | jq -e . >/dev/null 2>&1; then
    echo "$tid: FAIL (get_issue failed or returned malformed payload)"
    failed=$((failed + 1))
    continue
  fi

  live_state=$(echo "$issue_json" | jq -r '.state.name // empty' 2>/dev/null)
  live_approved=$(echo "$issue_json" | jq -r \
    '[.labels.nodes[]?.name? // empty | ascii_downcase] | index("approved") != null' 2>/dev/null || echo 'false')

  if $DRY_RUN; then
    echo "$tid: WOULD SEED stage=${live_state:-<none>} approved=${live_approved} provenance=$([ "$live_approved" = "true" ] && echo human || echo "<none>")"
    seeded=$((seeded + 1))
    continue
  fi

  if [ -n "$live_state" ]; then
    set_ticket_stage "$tid" "$live_state" 2>/dev/null || true
  fi
  if [ "$live_approved" = "true" ]; then
    set_ticket_approval "$tid" true human 2>/dev/null || true
  fi

  echo "$tid: SEEDED stage=${live_state:-<none>} approved=${live_approved}"
  seeded=$((seeded + 1))
done

echo "---"
if $DRY_RUN; then
  echo "manifest-backfill (dry-run): $seeded would be seeded, $skipped already complete, $failed failed"
else
  echo "manifest-backfill: $seeded seeded, $skipped already complete, $failed failed"
fi

[ "$failed" -eq 0 ]
