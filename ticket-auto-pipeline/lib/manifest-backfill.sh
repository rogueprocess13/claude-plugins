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
# planned-ticket-check.sh -> branch-directive-check.sh -> epic-branch.sh's
# _parse_directive, needed by the epic-manifest backfill pass below (2.1)
# to read a live epic's Branch Directive without an eval of untrusted text.
source "$LIB_DIR/planned-ticket-check.sh"
source "$LIB_DIR/branch-directive-check.sh"
source "$LIB_DIR/epic-branch.sh"

# tracker-planner-and-fallback-cutover (2.1): the six type labels a ticket
# may carry — same set template-select.sh resolves templates from.
_BACKFILL_KNOWN_TYPES=("bug" "feature" "improvement" "security" "chore" "refactor")

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
# tracker-planner-and-fallback-cutover (2.2): per-field dry-run coverage
# counts, so an operator can confirm coverage before committing rather than
# reading through every "WOULD SEED" line by hand.
dry_type_count=0
dry_init_count=0
dry_blocked_count=0
dry_flags_count=0

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

  # tracker-planner-and-fallback-cutover (2.1): type/initiative/blocked_by/
  # flags, seeded from the same live labels for the last time. `|| true` on
  # every grep-fed assignment below: under `set -eo pipefail`, a `grep`
  # that legitimately finds nothing (e.g. a ticket with no INIT-* label)
  # exits 1, and pipefail promotes that into the pipeline's own exit
  # status even though a later stage (head/jq) succeeded — without the
  # guard that kills the whole backfill run on this ticket's normal,
  # expected "no match" case.
  live_labels=$(echo "$issue_json" | jq -r '[.labels.nodes[]?.name? // empty] | .[]' 2>/dev/null)
  live_type=""
  for _t in "${_BACKFILL_KNOWN_TYPES[@]}"; do
    if echo "$live_labels" | grep -qx "$_t"; then
      live_type="$_t"
      break
    fi
  done
  live_init=$(echo "$live_labels" | grep -E '^INIT-[0-9]+$' | head -1) || true
  live_blocked_by=$(echo "$live_labels" | grep -oE '^blocked-by:[A-Z]+-[0-9]+$' |
    sed 's/^blocked-by://' | jq -R -s -c 'split("\n") | map(select(length > 0))') || true
  live_flags=$(echo "$live_labels" |
    grep -E '^(needs-info|needs-adr|rejected|reviewed)$' |
    jq -R -s -c 'split("\n") | map(select(length > 0))') || true

  if $DRY_RUN; then
    echo "$tid: WOULD SEED stage=${live_state:-<none>} approved=${live_approved} provenance=$([ "$live_approved" = "true" ] && echo human || echo "<none>") type=${live_type:-<none>} initiative=${live_init:-<none>} blocked_by=$live_blocked_by flags=$live_flags"
    seeded=$((seeded + 1))
    [ -n "$live_type" ] && dry_type_count=$((dry_type_count + 1))
    [ -n "$live_init" ] && dry_init_count=$((dry_init_count + 1))
    [ "$live_blocked_by" != "[]" ] && [ -n "$live_blocked_by" ] && dry_blocked_count=$((dry_blocked_count + 1))
    [ "$live_flags" != "[]" ] && [ -n "$live_flags" ] && dry_flags_count=$((dry_flags_count + 1))
    continue
  fi

  if [ -n "$live_state" ]; then
    set_ticket_stage "$tid" "$live_state" 2>/dev/null || true
  fi
  if [ "$live_approved" = "true" ]; then
    set_ticket_approval "$tid" true human 2>/dev/null || true
  fi
  backfill_ticket_fields "$tid" "$live_type" "$live_init" "$live_blocked_by" "$live_flags" 2>/dev/null || true

  echo "$tid: SEEDED stage=${live_state:-<none>} approved=${live_approved} type=${live_type:-<none>} initiative=${live_init:-<none>} blocked_by=$live_blocked_by flags=$live_flags"
  seeded=$((seeded + 1))
done

echo "---"
if $DRY_RUN; then
  echo "manifest-backfill (dry-run): $seeded would be seeded, $skipped already complete, $failed failed"
  echo "manifest-backfill (dry-run) field coverage: $dry_type_count would gain type, $dry_init_count would gain initiative, $dry_blocked_count would gain blocked_by, $dry_flags_count would gain flags"
else
  echo "manifest-backfill: $seeded seeded, $skipped already complete, $failed failed"
fi

# ── Epic dispatch stamp (tracker-planner-and-fallback-cutover, 2.1) ─────────────
# Mandatory (design D6): an epic planned before this change has no `dispatch`
# stamp and is never enumerated by fleet_local_epics after group 3 lands —
# reads as an idle fleet, not an error. Seeded from state:execution — the
# last read this label ever gets — plus each epic's live Branch Directive
# and children, so D-11/D-12/D-18's manifest population matches the live
# population this same run would otherwise still be able to see.
echo "---"
echo "Epic dispatch stamp (state:execution epics):"

epic_seeded=0
epic_skipped=0
epic_failed=0

epics_json=$(get_epics_by_label "state:execution" "full" 2>/dev/null) || epics_json=""
if [ -n "$epics_json" ] && echo "$epics_json" | jq -e . >/dev/null 2>&1 &&
  [ "$(echo "$epics_json" | jq -r 'length // 0' 2>/dev/null)" -gt 0 ]; then
  epic_count=$(echo "$epics_json" | jq -r 'length // 0' 2>/dev/null)
  for i in $(seq 0 $((epic_count - 1))); do
    epic_id=$(echo "$epics_json" | jq -r ".[$i].identifier // empty" 2>/dev/null)
    [ -z "$epic_id" ] && continue

    existing_dispatch_rc=0
    existing_dispatch=$(get_epic_manifest_field "$epic_id" dispatch 2>/dev/null) || existing_dispatch_rc=$?
    if [ "$existing_dispatch_rc" -eq 0 ] && [ "$existing_dispatch" = "true" ]; then
      echo "$epic_id: SKIP (already stamped dispatch:true)"
      epic_skipped=$((epic_skipped + 1))
      continue
    fi

    epic_description=$(echo "$epics_json" | jq -r ".[$i].description // \"\"" 2>/dev/null)
    children_json=$(echo "$epics_json" | jq -c "[.[$i].children.nodes[]?.identifier // empty] | map(select(length > 0))" 2>/dev/null)
    [ -z "$children_json" ] && children_json='[]'

    branch="" uat_policy="per-ticket" merge_policy=""
    if _parse_directive "$epic_description"; then
      branch="$_DIRECTIVE_BRANCH"
      uat_policy="${_DIRECTIVE_UAT_POLICY:-per-ticket}"
      merge_policy="$_DIRECTIVE_MERGE_POLICY"
    fi

    if $DRY_RUN; then
      echo "$epic_id: WOULD SEED dispatch=true branch=${branch:-<none>} children=$(echo "$children_json" | jq -r 'length' 2>/dev/null)"
      epic_seeded=$((epic_seeded + 1))
      continue
    fi

    if ! backfill_epic_manifest "$epic_id" "$branch" "$uat_policy" "$merge_policy" "$children_json" 2>/dev/null; then
      echo "$epic_id: FAIL (could not write epic manifest)"
      epic_failed=$((epic_failed + 1))
      continue
    fi

    echo "$epic_id: SEEDED dispatch=true branch=${branch:-<none>} children=$(echo "$children_json" | jq -r 'length' 2>/dev/null)"
    epic_seeded=$((epic_seeded + 1))
  done
else
  echo "(no state:execution epics found, or the query failed — nothing to seed)"
fi

echo "---"
if $DRY_RUN; then
  echo "manifest-backfill epics (dry-run): $epic_seeded would be seeded, $epic_skipped already complete, $epic_failed failed"
else
  echo "manifest-backfill epics: $epic_seeded seeded, $epic_skipped already complete, $epic_failed failed"
fi

[ "$failed" -eq 0 ] && [ "$epic_failed" -eq 0 ]
