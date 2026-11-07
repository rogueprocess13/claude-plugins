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
  echo "  --generation N   Caller's generation token (default: \$FLEET_GENERATION, which fleetd sets for every worker)" >&2
  echo "  --state-dir DIR   Fleet state directory for fence marker lookup" >&2
  echo "  --override REASON   Force a verdict-gated trigger past a trailing FAIL/BLOCK verifier-result" >&2
  echo "  --provenance human|policy   Who approved (human-approve/pr-iterate only; default human)" >&2
  echo "" >&2
  echo "Exit codes: 0 ok, 1 usage, 3 unknown trigger, 8 precondition, 9/10 generation fence," >&2
  echo "  11 verdict gate, 12 an earlier pending event could not be emitted, 42 ticket in flight" >&2
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
# A flag that takes a value must have one. Without this check `--data` as the
# last argument crashed on an empty array subscript, and the other value
# flags tripped set -e on the final shift (review QA-5).
_need_value() {
  if [ "$2" -lt 2 ]; then
    echo "flow.sh: $1 requires a value" >&2
    usage
  fi
}
while [ $# -gt 0 ]; do
  case "$1" in
  --dry-run) DRY_RUN=true ;;
  --generation)
    _need_value "$1" $#
    CALLER_GENERATION="$2"
    shift
    ;;
  --state-dir)
    _need_value "$1" $#
    FLEET_STATE_DIR="$2"
    shift
    ;;
  --override)
    _need_value "$1" $#
    OVERRIDE_REASON="$2"
    shift
    ;;
  --provenance)
    _need_value "$1" $#
    PROVENANCE="$2"
    shift
    ;;
  --data)
    _need_value "$1" $#
    key="${2%%=*}"
    val="${2#*=}"
    if [ -z "$key" ] || [ "$key" = "$2" ]; then
      echo "flow.sh: --data expects key=value, got '$2'" >&2
      usage
    fi
    DATA["$key"]="$val"
    shift
    ;;
  *)
    # Unknown arguments used to be ignored, so a typo such as `--dryrun`
    # silently ran a real transition (review QA-5).
    echo "flow.sh: unknown argument: $1" >&2
    usage
    ;;
  esac
  shift
done

# ── Generation token: one source for both fence checks ──────────────────────
# fleetd exports FLEET_GENERATION into every worker it spawns
# (fleetd/supervisor.py spawn_worker), and no caller passes --generation. So
# the flag defaults to the environment; without this every transition after a
# fleet kill exited 9, because the fence marker is never cleared (review
# ARCH-1). The resolved value is exported back as FLEET_GENERATION so
# emit_event (lib/events.sh), which runs its own fence check from that
# variable, judges the same token flow.sh did. Before, `--generation` alone
# passed flow.sh's fence while emit_event refused and the event was lost.
CALLER_GENERATION="${CALLER_GENERATION:-${FLEET_GENERATION:-}}"
if [ -n "$CALLER_GENERATION" ]; then
  if ! [[ "$CALLER_GENERATION" =~ ^[0-9]+$ ]]; then
    echo "flow.sh: invalid generation token '${CALLER_GENERATION}' — must be a non-negative integer" >&2
    exit 1
  fi
  export FLEET_GENERATION="$CALLER_GENERATION"
fi

# ── Pipeline log helper ─────────────────────────────────────────────────────

# The pipeline log path arrives as LOG_FILE (flow-run.sh, older callers) or
# as TAP_LOG, the name phase agents export since GitHub #575 — a bare
# LOG_FILE in an agent's environment is read by Spring Boot as its own log
# file, so the exported name is namespaced. Shell-local from here on.
LOG_FILE="${LOG_FILE:-${TAP_LOG:-}}"

# --dry-run is side-effect free (review QA-4): no log lines, no heartbeat,
# no manifest bootstrap, no pending-event replay. Every writer below checks
# DRY_RUN itself, so a refusal path (exit 8/9/10/11) still reports on
# stderr in a dry run but leaves nothing on disk.
_log() {
  ! $DRY_RUN || return 0
  [ -n "${LOG_FILE:-}" ] || return 0
  IFS='|' read -r _ph _st _status _msg <<<"$1"
  _plog "$LOG_FILE" "$_ph" "$_st" "$_status" "$_msg"
}

# ── Heartbeat helpers (GitHub #530) ─────────────────────────────────────────
# hb_write rejects a malformed or nested DETAIL with rc 1. Every heartbeat in
# this script is advisory, so a rejected entry must never change flow.sh's
# outcome: under `set -e` a bare hb_gate failure would abort the transition
# (the warn-only ILLEGAL_TRANSITION case) or turn a deliberate exit 8/9/10/11
# into exit 1. _hb_gate swallows the failure; hb_write already reported it
# on stderr.
_hb_gate() {
  ! $DRY_RUN || return 0
  hb_gate "$@" || true
}

# _hb_detail key value [key value ...] -> compact flat JSON object with string
# values, built by jq so quotes, newlines and control characters in a value
# can never produce invalid JSON.
_hb_detail() {
  jq -nc '$ARGS.positional as $a
    | reduce range(0; $a | length; 2) as $i ({}; . + {($a[$i]): ($a[$i + 1] // "")})' \
    --args "$@" 2>/dev/null || echo '{}'
}

_emit_schema_header() {
  ! $DRY_RUN || return 0
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
  ! $DRY_RUN || return 0
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
_hb_gate "trigger-dispatch" "fired" "trigger ${TRIGGER} dispatched" "$(_hb_detail trigger "$TRIGGER")"

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
    # .from may be an array, which `jq -r` pretty-prints over several lines —
    # flatten it to "A,B" for both the log line and the flat heartbeat DETAIL.
    _expected_from_flat=$(echo "$def" | jq -r '.from | if type == "array" then join(",") else tostring end')
    _log "META|flow-warn|info|ILLEGAL_TRANSITION — ${TICKET_ID} attempted ${TRIGGER} from ${CURRENT_STAGE:-<none>}, expected from ${_expected_from_flat}"
    _hb_gate "flow-warn" "warn" "ILLEGAL_TRANSITION" \
      "$(_hb_detail ticket "$TICKET_ID" trigger "$TRIGGER" actual "$CURRENT_STAGE" expected_from "$_expected_from_flat")"
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
    _hb_gate "precondition" "fail" "${_subject} precondition rejected" "$(_hb_detail ticket "$TICKET_ID" subject "$_subject")"
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
  _hb_gate "fence-guard" "fail" "missing generation token" "$(_hb_detail ticket "$TICKET_ID" fenced_gen "$FENCE_CHECK_FENCED_GEN")"
  exit 9
  ;;
10)
  echo "flow.sh: fence guard — generation ${CALLER_GENERATION} is superseded by fenced generation ${FENCE_CHECK_FENCED_GEN} for ${TICKET_ID}" >&2
  _log "META|fence-guard|fail|generation ${CALLER_GENERATION} <= fenced ${FENCE_CHECK_FENCED_GEN}"
  _hb_gate "fence-guard" "fail" "superseded generation" \
    "$(_hb_detail ticket "$TICKET_ID" caller_gen "$CALLER_GENERATION" fenced_gen "$FENCE_CHECK_FENCED_GEN")"
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
      _hb_gate "verdict-override" "ok" "verdict gate overridden" "$(_hb_detail ticket "$TICKET_ID" trigger "$TRIGGER")"
    else
      echo "flow.sh: refusing '${TRIGGER}' for ${TICKET_ID} — trailing FAIL/BLOCK verifier-result(s): ${_failing_summary}. Pass --override <reason> to force past this." >&2
      _log "META|verdict-gate|fail|trigger=${TRIGGER} blocked by ${_failing_summary}"
      _hb_gate "verdict-gate" "fail" "trailing FAIL/BLOCK verifier-result blocks trigger" "$(_hb_detail ticket "$TICKET_ID" trigger "$TRIGGER")"
      exit 11
    fi
  fi
fi

# ── Manifest bootstrap ───────────────────────────────────────────────────────
_ensure_manifest

# ── Emit-and-clear any pending_event found on entry ─────────────────────────
# A pending_event present at this point means a prior invocation either
# crashed between writing the transition and the emission returning (or
# between the emission returning and clearing the marker — the idem key
# makes that re-emission a no-op), or ran emit_event and it failed (see
# "Write the transition" below). Its idem key is derived from CURRENT_REV,
# the exact revision it was written alongside.
#
# The marker is cleared only once the event is in the outbox. If the replay
# fails, flow.sh refuses this invocation with exit 12 and changes nothing:
# applying the new transition would overwrite pending_event with this
# trigger's event and lose the old one for good (review ARCH-2). The one
# exception is exit 3 (event not in workflow.json's vocabulary any more),
# which no retry can fix — that is logged as EMIT_DROPPED and cleared, so a
# vocabulary edit cannot wedge a ticket.
_PENDING_JSON=$(_manifest_get pending_event) || true
if ! $DRY_RUN && [ -n "$_PENDING_JSON" ] && [ "$_PENDING_JSON" != "null" ]; then
  _pending_event=$(echo "$_PENDING_JSON" | jq -r '.event // empty' 2>/dev/null)
  _pending_data=$(echo "$_PENDING_JSON" | jq -c '.data // {}' 2>/dev/null)
  _replay_rc=0
  if [ -n "$_pending_event" ]; then
    if declare -f emit_event >/dev/null 2>&1; then
      emit_event --idem "${TICKET_ID}:${CURRENT_REV}" "$TICKET_ID" "$_pending_event" "$_pending_data" || _replay_rc=$?
    else
      _replay_rc=127
    fi
  fi
  case "$_replay_rc" in
  0) ;;
  3)
    _log "META|flow-warn|warn|EMIT_DROPPED event=${_pending_event} rev=${CURRENT_REV} rc=3 (not in vocabulary)"
    _hb_gate "flow-warn" "warn" "EMIT_DROPPED" "$(_hb_detail ticket "$TICKET_ID" event "$_pending_event" rc 3)"
    ;;
  *)
    echo "flow.sh: pending event '${_pending_event}' (rev ${CURRENT_REV}) for ${TICKET_ID} could not be emitted (rc ${_replay_rc}); refusing '${TRIGGER}' so it is not overwritten — retry" >&2
    _log "META|flow-warn|warn|EMIT_FAILED replay event=${_pending_event} rev=${CURRENT_REV} rc=${_replay_rc}; ${TRIGGER} refused"
    _hb_gate "flow-warn" "warn" "EMIT_FAILED" \
      "$(_hb_detail ticket "$TICKET_ID" event "$_pending_event" rc "$_replay_rc" refused "$TRIGGER")"
    exit 12
    ;;
  esac
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

# pending_event is cleared only when emit_event succeeded (review ARCH-2).
# On failure the transition itself stands — the manifest write above is
# done, and exiting non-zero would make callers that retry on failure apply
# the trigger a second time — so flow.sh still exits 0, but it reports
# event_emitted:false, logs EMIT_FAILED, and leaves pending_event in place.
# The next flow.sh invocation for this ticket replays it under the same
# idem key ({tid}:{rev}) before doing anything else (see above).
_EMIT_RC=0
if [ -n "$_EVENT_NAME" ]; then
  if declare -f emit_event >/dev/null 2>&1; then
    emit_event --idem "$IDEM_KEY" "$TICKET_ID" "$_EVENT_NAME" "$_EVENT_DATA" || _EMIT_RC=$?
  else
    _EMIT_RC=127
  fi
fi
if [ "$_EMIT_RC" -eq 0 ]; then
  _manifest_clear_pending 2>/dev/null || true
else
  echo "flow.sh: event '${_EVENT_NAME}' for ${TICKET_ID} rev ${NEXT_REV} was not emitted (rc ${_EMIT_RC}); kept as pending_event for replay" >&2
  _log "META|flow-warn|warn|EMIT_FAILED event=${_EVENT_NAME} rev=${NEXT_REV} rc=${_EMIT_RC}; kept as pending_event"
  _hb_gate "flow-warn" "warn" "EMIT_FAILED" \
    "$(_hb_detail ticket "$TICKET_ID" event "$_EVENT_NAME" rev "$NEXT_REV" rc "$_EMIT_RC")"
fi

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
  --argjson emitted "$([ "$_EMIT_RC" -eq 0 ] && echo true || echo false)" \
  '{trigger: $trigger, stage: $stage, flags: $flags, rev: $rev, success: true, event_emitted: $emitted}'
