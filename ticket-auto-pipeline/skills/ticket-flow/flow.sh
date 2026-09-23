#!/usr/bin/env bash
# ticket-flow: deterministic LOCAL state-machine executor
# (tracker-flow-projection-cutover, Change 2 of the tracker-decoupling
# authority-flip programme).
#
# flow.sh performs NO tracker I/O. Its inputs are workflow.json and the
# ticket's local manifest; its outputs are the manifest and exactly one
# outbox event per invocation (flow-local-transitions spec). The tracker
# receives its column/label projection later, asynchronously, from
# lib/board-drivers/linear.sh via the outbox — never from this script.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
source "$LIB_DIR/heartbeat.sh"
# linear-api.sh is deliberately NOT sourced — flow.sh no longer fetches or
# mutates the issue, fetches the team, or resolves label/state ids.
source "$LIB_DIR/planned-ticket-check.sh" 2>/dev/null || true
source "$LIB_DIR/branch-directive-check.sh" 2>/dev/null || true
source "$LIB_DIR/epic-precondition.sh"
# verifier_latest_verdict backs the verdict gate below (issue #368).
if [ -f "$LIB_DIR/verifier-result.sh" ]; then
  source "$LIB_DIR/verifier-result.sh"
elif [ -f "$SCRIPT_DIR/../../lib/verifier-result.sh" ]; then
  source "$SCRIPT_DIR/../../lib/verifier-result.sh"
fi
# fence-check.sh backs the generation fence guard below.
if [ -f "$LIB_DIR/fence-check.sh" ]; then
  source "$LIB_DIR/fence-check.sh"
elif [ -f "$SCRIPT_DIR/../../lib/fence-check.sh" ]; then
  source "$SCRIPT_DIR/../../lib/fence-check.sh"
fi
# events.sh: the sole way a transition's fact reaches the outbox. No longer
# an optional dual-write side channel — every transition emits through it.
if [ -f "$LIB_DIR/events.sh" ]; then
  source "$LIB_DIR/events.sh"
elif [ -f "$SCRIPT_DIR/../../lib/events.sh" ]; then
  source "$SCRIPT_DIR/../../lib/events.sh"
fi
# manifest-write.sh: the manifest is now the only state flow.sh reads and
# writes. No longer optional — every transition depends on it.
if [ -f "$LIB_DIR/manifest-write.sh" ]; then
  source "$LIB_DIR/manifest-write.sh"
elif [ -f "$SCRIPT_DIR/../../lib/manifest-write.sh" ]; then
  source "$SCRIPT_DIR/../../lib/manifest-write.sh"
fi

SM="$SCRIPT_DIR/workflow.json"

usage() {
  echo "Usage: $0 <TICKET-ID> <TRIGGER> [--generation N] [--state-dir DIR] [--data key=value ...] [--dry-run] [--override REASON] [--provenance human|policy]" >&2
  echo "" >&2
  echo "  --generation N   Caller's generation token (required when fence is active)" >&2
  echo "  --state-dir DIR   Fleet state directory for fence marker lookup" >&2
  echo "  --override REASON   Force a verdict-gated trigger past a trailing FAIL/BLOCK verifier-result" >&2
  echo "  --provenance human|policy   Who approved (human-approve/pr-iterate only; default human)" >&2
  echo "" >&2
  echo "Valid triggers (from workflow.json):" >&2
  jq -r '.triggers | keys[]' "$SM" 2>/dev/null | sed 's/^/  /' >&2
  exit 1
}

TICKET_ID="${1:-}"
TRIGGER="${2:-}"
shift 2 2>/dev/null || true

[ -z "$TICKET_ID" ] && usage
[ -z "$TRIGGER" ] && usage
[[ "$TICKET_ID" =~ ^[A-Z]+-[0-9]+$ ]] || {
  echo "Invalid TICKET_ID: $TICKET_ID" >&2
  exit 1
}

# ── Concurrent-execution lock (flock FD 9) ──────────────────────────────────
FLOW_LOCK_DIR="${TICKET_FLOW_LOCK_DIR:-$SCRIPT_DIR/locks}"
mkdir -p "$FLOW_LOCK_DIR"
exec 9>"${FLOW_LOCK_DIR}/.ticket-flow-${TICKET_ID}.lock"
if ! flock -n -E 42 9; then
  echo "ticket already in flight: $TICKET_ID" >&2
  exit 42
fi

# ── Parse optional flags ────────────────────────────────────────────────────

DRY_RUN=false
CALLER_GENERATION=""
FLEET_STATE_DIR="${FLEET_STATE_DIR:-}"
OVERRIDE_REASON=""
PROVENANCE="human"
declare -A DATA=()
while [ $# -gt 0 ]; do
  case "$1" in
  --dry-run) DRY_RUN=true ;;
  --generation)
    CALLER_GENERATION="$2"
    shift
    ;;
  --state-dir)
    FLEET_STATE_DIR="$2"
    shift
    ;;
  --override)
    OVERRIDE_REASON="$2"
    shift
    ;;
  --provenance)
    PROVENANCE="$2"
    shift
    ;;
  --data)
    key="${2%%=*}"
    val="${2#*=}"
    DATA["$key"]="$val"
    shift
    ;;
  esac
  shift
done

# ── Pipeline log helper ─────────────────────────────────────────────────────

_log() {
  [ -n "${LOG_FILE:-}" ] || return 0
  IFS='|' read -r _ph _st _status _msg <<<"$1"
  _plog "$LOG_FILE" "$_ph" "$_st" "$_status" "$_msg"
}

_emit_schema_header() {
  [ -n "${LOG_FILE:-}" ] || return 0
  if [ ! -s "$LOG_FILE" ]; then
    _log "META|schema|info|1"
  fi
}

# ── Manifest bootstrap ───────────────────────────────────────────────────────
# Makes the ticket manifest-addressable before any manifest write. Epics
# always have a manifest from ticket-planner's write_epic_manifest — this is
# ticket-only. Fail-soft: a manifest-write failure must never silently
# corrupt flow.sh's own exit code beyond the manifest write's own failure
# path below.
_ensure_manifest() {
  declare -f ensure_ticket_manifest >/dev/null 2>&1 || return 0
  $IS_EPIC && return 0
  ensure_ticket_manifest "$TICKET_ID" 2>/dev/null || true
}

# ── Approval-provenance manifest write ──────────────────────────────────────
# Fail-soft — never alters flow.sh's own exit code or the caller-visible
# result.
_write_approval_manifest() {
  declare -f set_ticket_approval >/dev/null 2>&1 || return 0
  case "$TRIGGER" in
  human-approve | pr-iterate)
    set_ticket_approval "$TICKET_ID" true "$PROVENANCE" 2>/dev/null || true
    ;;
  re-claim | implement-complete)
    # implement-complete clearing the fact (Ready -> Review) is what makes
    # uat-fail's Review->Ready-without-reapproval path safe — a ticket that
    # loops UAT-fail back to Ready must never carry a stale approved:true,
    # since nothing re-approves it before it's dispatched again.
    set_ticket_approval "$TICKET_ID" false 2>/dev/null || true
    ;;
  esac
}

# ── Validate workflow.json ─────────────────────────────────────────────

if ! jq '.' "$SM" >/dev/null 2>&1; then
  echo "workflow.json is not valid JSON: $SM" >&2
  exit 1
fi

# ── Dispatch trigger via JSON ────────────────────────────────────────────────

def=$(jq --arg t "$TRIGGER" '.triggers[$t] // empty' "$SM")
if [ -z "$def" ]; then
  echo "Unknown trigger: $TRIGGER" >&2
  echo "Valid triggers:" >&2
  jq -r '.triggers | keys[]' "$SM" | sed 's/^/  /' >&2
  exit 3
fi

_emit_schema_header
_log "META|trigger-def|info|${TRIGGER}:$(echo "$def" | jq -c '.')"
hb_gate "trigger-dispatch" "fired" "trigger ${TRIGGER} dispatched" '{"trigger":"'"$TRIGGER"'"}'

# ── Derive state machine variables from trigger def ─────────────────────────

NEW_STATE_NAME=$(echo "$def" | jq -r '.to // empty')

ADD_LABEL_NAMES=()
while IFS= read -r label; do
  [ -z "$label" ] && continue
  ADD_LABEL_NAMES+=("$label")
done < <(echo "$def" | jq -r '.adds[]? // empty')

REMOVE_LABEL_NAMES=()
while IFS= read -r label; do
  [ -z "$label" ] && continue
  REMOVE_LABEL_NAMES+=("$label")
done < <(echo "$def" | jq -r '.removes[]? // empty')

# ── Epic discriminator (resolved from the manifest only — flow-local-
# transitions spec: "SHALL NOT require an issue payload fetched from the
# tracker"). The synthetic payload carries only the identifier, so
# is_epic_issue's manifest-existence check is the operative arm — every
# epic already has a manifest from write_epic_manifest before any flow.sh
# trigger fires against it, so the label/description fallback arms (which
# need real issue data this script no longer fetches) are never reached in
# practice.
EPIC_PAYLOAD=$(jq -nc --arg id "$TICKET_ID" '{identifier: $id}')
IS_EPIC=false
is_epic_issue "$EPIC_PAYLOAD" && IS_EPIC=true

_manifest_get() {
  if $IS_EPIC; then
    get_epic_manifest_field "$TICKET_ID" "$1" 2>/dev/null
  else
    get_ticket_manifest_field "$TICKET_ID" "$1" 2>/dev/null
  fi
}

_manifest_set_transition() {
  if $IS_EPIC; then
    set_epic_transition "$TICKET_ID" "$1" "$2" "$3"
  else
    set_ticket_transition "$TICKET_ID" "$1" "$2" "$3"
  fi
}

_manifest_clear_pending() {
  if $IS_EPIC; then
    clear_epic_pending_event "$TICKET_ID"
  else
    clear_pending_event "$TICKET_ID"
  fi
}

# Guarded with `|| true` — get_ticket_manifest_field/get_epic_manifest_field
# return 1 for "no manifest yet" (a brand-new ticket, before _ensure_manifest
# has run below), and a bare `var=$(failing_cmd)` under `set -e` aborts the
# whole script silently on that exit code (set-e-bare-and-guard-gotcha).
CURRENT_STAGE=$(_manifest_get stage) || true
CURRENT_FLAGS_JSON=$(_manifest_get flags) || true
echo "$CURRENT_FLAGS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 || CURRENT_FLAGS_JSON='[]'
CURRENT_REV=$(_manifest_get rev) || true
[[ "$CURRENT_REV" =~ ^[0-9]+$ ]] || CURRENT_REV=0

# ── Warn-only from-precondition check (D-2) ─────────────────────────────────
# Compares the trigger's declared origin against the manifest's stage —
# never a live tracker state. Still does not block the mutation.
EXPECTED_FROM=$(echo "$def" | jq -r '.from // empty')
if [ -n "$EXPECTED_FROM" ] && [ "$EXPECTED_FROM" != "null" ]; then
  _from_match=false
  if echo "$def" | jq -e '.from | type == "array"' >/dev/null 2>&1; then
    if echo "$def" | jq -e --arg state "$CURRENT_STAGE" '.from | index($state) != null' >/dev/null 2>&1; then
      _from_match=true
    fi
  else
    if [ "$CURRENT_STAGE" = "$EXPECTED_FROM" ]; then
      _from_match=true
    fi
  fi
  if ! $_from_match; then
    _log "META|flow-warn|info|ILLEGAL_TRANSITION — ${TICKET_ID} attempted ${TRIGGER} from ${CURRENT_STAGE:-<none>}, expected from ${EXPECTED_FROM}"
    hb_gate "flow-warn" "warn" "ILLEGAL_TRANSITION" "{\"ticket\":\"${TICKET_ID}\",\"trigger\":\"${TRIGGER}\",\"actual\":\"${CURRENT_STAGE}\",\"expected_from\":\"${EXPECTED_FROM}\"}"
  fi
fi

# ── Preconditions ────────────────────────────────────────────────────────────
# The discriminator and evaluator live in lib/epic-precondition.sh so that
# tests exercise this exact code path instead of re-implementing the
# condition. Resolved entirely from EPIC_PAYLOAD (manifest-backed) above —
# no tracker fetch.
_precondition_reject() {
  local _subject="$1"
  local _rc="$2"
  if [ "$_rc" -eq 9 ]; then
    echo "flow.sh: refusing to proceed — unknown precondition declared for '${_subject}'" >&2
    _log "META|precondition|fail|unknown precondition for ${_subject}"
  else
    echo "flow.sh: precondition failed for '${_subject}' on ${TICKET_ID}" >&2
    _log "META|precondition|fail|${_subject} rejected on ${TICKET_ID}"
    hb_gate "precondition" "fail" "${_subject} precondition rejected" "{\"ticket\":\"$TICKET_ID\",\"subject\":\"${_subject}\"}"
  fi
  exit 8
}

_trigger_precondition=$(echo "$def" | jq -r '.precondition // empty')
_pre_rc=0
check_precondition "$_trigger_precondition" "$TRIGGER" "$EPIC_PAYLOAD" || _pre_rc=$?
[ "$_pre_rc" -eq 0 ] || _precondition_reject "$TRIGGER" "$_pre_rc"

# ── Generation fence guard ────────────────────────────────────────────────────
_fence_rc=0
check_generation_fence "$TICKET_ID" "$CALLER_GENERATION" "${FLEET_STATE_DIR:-}" || _fence_rc=$?
case "$_fence_rc" in
0)
  if [ "$FENCE_CHECK_STATUS" = "current" ]; then
    _log "META|fence-guard|info|generation ${CALLER_GENERATION} > fenced ${FENCE_CHECK_FENCED_GEN}, allowed"
  fi
  ;;
9)
  echo "flow.sh: fence guard — missing generation token for fenced ticket ${TICKET_ID} (fenced at generation ${FENCE_CHECK_FENCED_GEN})" >&2
  _log "META|fence-guard|fail|missing generation token for fenced ticket ${TICKET_ID}"
  hb_gate "fence-guard" "fail" "missing generation token" "{\"ticket\":\"${TICKET_ID}\",\"fenced_gen\":${FENCE_CHECK_FENCED_GEN}}"
  exit 9
  ;;
10)
  echo "flow.sh: fence guard — generation ${CALLER_GENERATION} is superseded by fenced generation ${FENCE_CHECK_FENCED_GEN} for ${TICKET_ID}" >&2
  _log "META|fence-guard|fail|generation ${CALLER_GENERATION} <= fenced ${FENCE_CHECK_FENCED_GEN}"
  hb_gate "fence-guard" "fail" "superseded generation" "{\"ticket\":\"${TICKET_ID}\",\"caller_gen\":${CALLER_GENERATION},\"fenced_gen\":${FENCE_CHECK_FENCED_GEN}}"
  exit 10
  ;;
esac

# ── Verdict gate (VERDICT_FAIL_NOT_ENFORCED, issue #368) ────────────────────
_verdict_gate=$(echo "$def" | jq -r '.verdict_gate // false')
if [ "$_verdict_gate" = "true" ] && declare -f verifier_latest_verdict >/dev/null 2>&1 && [ -n "${LOG_FILE:-}" ]; then
  _failing_verdicts=$(verifier_latest_verdict "$LOG_FILE")
  if [ -n "$_failing_verdicts" ]; then
    _failing_summary=$(printf '%s' "$_failing_verdicts" | tr '|' ':' | tr '\n' ';' | sed 's/;$//')
    if [ -n "$OVERRIDE_REASON" ]; then
      _override_reason_safe="${OVERRIDE_REASON//|/ }"
      _log "META|verdict-override|info|trigger=${TRIGGER} reason=${_override_reason_safe} superseded=${_failing_summary}"
      hb_gate "verdict-override" "ok" "verdict gate overridden" "{\"ticket\":\"$TICKET_ID\",\"trigger\":\"$TRIGGER\"}"
    else
      echo "flow.sh: refusing '${TRIGGER}' for ${TICKET_ID} — trailing FAIL/BLOCK verifier-result(s): ${_failing_summary}. Pass --override <reason> to force past this." >&2
      _log "META|verdict-gate|fail|trigger=${TRIGGER} blocked by ${_failing_summary}"
      hb_gate "verdict-gate" "fail" "trailing FAIL/BLOCK verifier-result blocks trigger" "{\"ticket\":\"$TICKET_ID\",\"trigger\":\"$TRIGGER\"}"
      exit 11
    fi
  fi
fi

# ── Manifest bootstrap ───────────────────────────────────────────────────────
_ensure_manifest

# ── Emit-and-clear any pending_event found on entry ─────────────────────────
# A pending_event present at this point means a prior invocation crashed
# between writing the transition and the emission returning (or between the
# emission returning and clearing the marker — the idem key makes that
# re-emission a no-op). Its idem key is derived from CURRENT_REV, the exact
# revision it was written alongside.
_PENDING_JSON=$(_manifest_get pending_event) || true
if [ -n "$_PENDING_JSON" ] && [ "$_PENDING_JSON" != "null" ]; then
  _pending_event=$(echo "$_PENDING_JSON" | jq -r '.event // empty' 2>/dev/null)
  _pending_data=$(echo "$_PENDING_JSON" | jq -c '.data // {}' 2>/dev/null)
  if [ -n "$_pending_event" ] && declare -f emit_event >/dev/null 2>&1; then
    emit_event --idem "${TICKET_ID}:${CURRENT_REV}" "$TICKET_ID" "$_pending_event" "$_pending_data" 2>/dev/null || true
  fi
  _manifest_clear_pending 2>/dev/null || true
fi

# ── Compute the new (stage, flags) from the manifest and the trigger ───────
# flags is confined to the four human-signal labels the board driver is
# permitted to project (ticket-local-manifest spec) — a trigger's adds/
# removes naming anything else (e.g. human-reject/re-claim removing
# pre-approved, still a planner/tracker-only label out of this change's
# scope) is filtered out here, never landing in the manifest's flags field.
_PROJECTED_FLAG_LABELS='["needs-info","needs-adr","rejected","reviewed"]'
NEW_STAGE="${NEW_STATE_NAME:-$CURRENT_STAGE}"
NEW_FLAGS_JSON=$(jq -cn \
  --argjson cur "$CURRENT_FLAGS_JSON" \
  --argjson adds "$(echo "$def" | jq -c '.adds // []')" \
  --argjson removes "$(echo "$def" | jq -c '.removes // []')" \
  --argjson allowed "$_PROJECTED_FLAG_LABELS" \
  '(($cur - $removes) + $adds | unique) as $u
   | [$u[] | select(. as $x | $allowed | index($x) != null)] | sort')

# ── Build this transition's event name/payload from the trigger's emits ────
_EVENT_NAME=$(echo "$def" | jq -r '.emits.event // empty')
_EVENT_DATA="{}"
if [ -n "$_EVENT_NAME" ]; then
  _EVENT_DATA_RAW=$(echo "$def" | jq -c '.emits.data // {}')
  _EVENT_DATA=$(printf '%s' "$_EVENT_DATA_RAW" | jq -c \
    --arg complexity "${DATA[complexity]:-simple}" \
    --arg outcome "${DATA[outcome]:-Smooth}" \
    'with_entries(.value |= (
       if type == "string"
       then gsub("\\{complexity\\}"; $complexity) | gsub("\\{outcome\\}"; $outcome)
       else . end))')
fi

NEXT_REV=$((CURRENT_REV + 1))
IDEM_KEY="${TICKET_ID}:${NEXT_REV}"

# ── Dry-run output ──────────────────────────────────────────────────────────
if $DRY_RUN; then
  jq -n \
    --arg trigger "$TRIGGER" \
    --arg current_stage "${CURRENT_STAGE:-}" \
    --argjson current_flags "$CURRENT_FLAGS_JSON" \
    --arg new_stage "$NEW_STAGE" \
    --argjson new_flags "$NEW_FLAGS_JSON" \
    --arg event "$_EVENT_NAME" \
    --argjson event_data "$_EVENT_DATA" \
    --arg idem "$IDEM_KEY" \
    --argjson is_epic "$IS_EPIC" \
    '{
      trigger: $trigger,
      dry_run: true,
      is_epic: $is_epic,
      current: {stage: $current_stage, flags: $current_flags},
      computed: {stage: $new_stage, flags: $new_flags},
      event: {name: $event, data: $event_data, idem: $idem}
    }'
  exit 0
fi

# ── Write the transition and emit its event ─────────────────────────────────
# The manifest write always runs, bumping rev unconditionally — a trigger
# whose computed (stage, flags) happen to match the current manifest still
# gets its own distinct rev/idem, because "no manifest state change" (the
# ticket-local-manifest spec's language) describes the observable stage/
# flags VALUES being unchanged, not that no write occurs. Writing every time
# is what guarantees a structurally-nil trigger (implement-outcome,
# re-claim: always to=null, always no label delta) still gets a fresh,
# distinct idempotency key on every invocation — the exact defect D3
# documents the old idempotent-skip path caused.
_PENDING_EVENT_JSON=""
if [ -n "$_EVENT_NAME" ]; then
  _PENDING_EVENT_JSON=$(jq -nc --arg e "$_EVENT_NAME" --argjson d "$_EVENT_DATA" '{event: $e, data: $d}')
fi

_manifest_set_transition "$NEW_STAGE" "$NEW_FLAGS_JSON" "$_PENDING_EVENT_JSON"

if [ "$TRIGGER" = "implement-outcome" ] && [ -n "${DATA[outcome]:-}" ]; then
  _log "IMPLEMENT|implement-outcome|info|${DATA[outcome]}"
fi

_ensure_manifest
_write_approval_manifest

if [ -n "$_EVENT_NAME" ] && declare -f emit_event >/dev/null 2>&1; then
  emit_event --idem "$IDEM_KEY" "$TICKET_ID" "$_EVENT_NAME" "$_EVENT_DATA" 2>/dev/null || true
fi
_manifest_clear_pending 2>/dev/null || true

# ── Drain this ticket's outbox before exiting ───────────────────────────────
# Unconditional and best-effort (flow-local-transitions spec: "A drain
# failure SHALL NOT fail the transition" / "not gated on any inferred
# daemon-liveness signal"). Correctness rests on the cursor lock shared
# with fleetd's own pusher pass, not on avoiding concurrency.
bash "$SCRIPT_DIR/outbox-drain.sh" "$TICKET_ID" >/dev/null 2>&1 || true

jq -n \
  --arg trigger "$TRIGGER" \
  --arg stage "$NEW_STAGE" \
  --argjson flags "$NEW_FLAGS_JSON" \
  --argjson rev "$NEXT_REV" \
  '{trigger: $trigger, stage: $stage, flags: $flags, rev: $rev, success: true}'
