#!/usr/bin/env bash
# events.sh — append-only per-ticket event outbox (tracker-event-vocabulary-and-emitter,
# Phase B1 of the tracker-decoupling programme, Track B).
#
# emit_event <TID> <EVENT> <JSON_DATA>
#
# The single entry point for writing a fact to a ticket's outbox
# ({TID}-outbox.jsonl). Every event-producing site in the pipeline — whether
# or not it calls flow.sh — calls this function rather than writing an outbox
# record by any other means (specs/tracker-event-outbox/spec.md).
#
# Deliberately independent of flow.sh: gate holds and human holds write
# directly to the pipeline log and never call flow.sh, and flow.sh's own
# idempotency rule ("no mutation needed, exit 0") would silently swallow an
# emission for a hold, which changes no Linear label or state, if emission
# lived inside flow.sh. See design.md "The outbox is a new library, not a
# flow.sh extension".
#
# Record shape: {seq, tid, ts, gen, event, data, from_hint} — exactly these
# seven keys, JSON Lines, one object per line. No `position`/column/
# destination field exists anywhere in this shape by design — see design.md
# "Record format carries the event and its data, never a resolved position
# or column".
#
# Dual-write only in this phase: nothing consumes the outbox yet (that is
# B2). This library is purely additive.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention.
#
# set -eo pipefail only when executed directly, never when sourced — this is
# a sourceable library (epic-branch.sh, fleet-intervene.sh, flow.sh all
# source it unconditionally at file scope), and every risky command in
# emit_event already has explicit `||` error handling, so -e buys nothing
# here while leaking into every caller's shell flags. Same convention
# fleet-dispatch.sh documents (and works around) for linear-api.sh — this
# library gets it right instead of needing a snapshot/restore workaround.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -eo pipefail
fi

_EV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_source_if_missing() { declare -f "$1" >/dev/null 2>&1 || source "$2"; }
_source_if_missing check_generation_fence "$_EV_LIB_DIR/fence-check.sh" 2>/dev/null || true

# ── workflow.json resolution ─────────────────────────────────────────────────
# Same monorepo → installed skill → plugin-cache fallback chain
# ticket-preamble.sh already uses for state-machine.json — workflow.json is
# its replacement (Section 4 of this change).
_events_resolve_workflow_json() {
  local _cand
  for _cand in \
    "$_EV_LIB_DIR/../skills/ticket-flow/workflow.json" \
    "$HOME/.claude/skills/ticket-flow/workflow.json"; do
    [ -f "$_cand" ] && {
      echo "$_cand"
      return 0
    }
  done
  local _found
  _found=$(find "$HOME/.claude/plugins/cache" -name workflow.json \
    -path "*/ticket-flow/*" 2>/dev/null | sort | tail -1)
  if [ -n "$_found" ] && [ -f "$_found" ]; then
    echo "$_found"
    return 0
  fi
  return 1
}

# ── outbox path resolution ───────────────────────────────────────────────────
# Every writer for a given ticket MUST resolve the same file, or per-ticket
# seq monotonicity (guarded by the matching lock file below) silently breaks.
# FLEET_PIPELINE_LOG_DIR is the existing convention for this ticket's whole
# log-family ({tid}-pipeline.log, {tid}-heartbeat.log, {tid}-activity.log,
# {tid}-tool-errors.log) — fleet_kill_pipeline (fleet-intervene.sh) uses the
# identical "${FLEET_PIPELINE_LOG_DIR:-./logs}" fallback, so a fleet-initiated
# kill and an in-pipeline emission for the same ticket always land in the same
# directory.
_events_outbox_dir() {
  echo "${FLEET_PIPELINE_LOG_DIR:-./logs}"
}

_events_outbox_file() {
  echo "$(_events_outbox_dir)/${1}-outbox.jsonl"
}

_events_lock_file() {
  echo "$(_events_outbox_dir)/.${1}-outbox.lock"
}

# emit_event [--idem KEY] <TID> <EVENT> <JSON_DATA>
#
# JSON_DATA defaults to "{}". Must be a valid, flat-or-nested JSON value (an
# object in every declared vocabulary entry so far, but emit_event itself
# does not require object-shape — the vocabulary check below is what actually
# constrains callers).
#
# --idem KEY: an optional idempotency key (tracker-flow-projection-cutover).
# When supplied, a record already carrying this key in the ticket's outbox
# suppresses the append (exit 0, no write, sequence counter unchanged) —
# the check and the append happen under the same lock acquisition so two
# concurrent callers with the same key cannot both append. Parsed before the
# positional arguments so the pre-existing three-argument call shape is
# unchanged for every caller that does not pass it.
#
# Exit codes:
#   0  written (or suppressed as a duplicate of an existing idem key)
#   2  usage error (missing args, invalid JSON, workflow.json unreadable)
#   3  undeclared event name
#   9  fence guard — missing generation token on a fenced ticket
#   10 fence guard — superseded generation
#   1  lock/write failure
emit_event() {
  local _idem=""
  while [ "${1:-}" = "--idem" ]; do
    _idem="$2"
    shift 2
  done

  local tid="$1" event="$2" data="${3:-}"
  # Not "${3:-{}}" — bash's default-value parsing does not brace-match
  # arbitrary content, so a literal "{}" inside the ${VAR:-word} form leaks a
  # stray trailing "}" onto every caller-supplied value, not just the
  # fallback case. Assign the default separately instead.
  [ -z "$data" ] && data="{}"

  if [ -z "$tid" ] || [ -z "$event" ]; then
    echo "emit_event: TID and EVENT are required" >&2
    return 2
  fi

  if ! printf '%s' "$data" | jq -e . >/dev/null 2>&1; then
    echo "emit_event: DATA is not valid JSON: $data" >&2
    return 2
  fi

  local _wf
  _wf=$(_events_resolve_workflow_json) || {
    echo "emit_event: workflow.json not found" >&2
    return 2
  }

  # ── Closed vocabulary ────────────────────────────────────────────────────
  # An event name not declared in workflow.json's vocabulary SHALL NOT be
  # emitted (specs/pipeline-event-vocabulary/spec.md).
  if ! jq -e --arg e "$event" '.vocabulary[$e] != null' "$_wf" >/dev/null 2>&1; then
    echo "emit_event: undeclared event '$event' — not present in ${_wf}'s vocabulary" >&2
    return 3
  fi

  # ── Generation fence (shared with flow.sh, lib/fence-check.sh) ──────────
  # FLEET_GENERATION is exported into every fleetd-spawned phase's
  # environment (fleetd/supervisor.py worker_env) — the same generation
  # token flow.sh receives via --generation from the router/spawn-helper.
  # A caller with a different authoritative generation (e.g.
  # fleet-intervene.sh, which is the fence writer, not a fenced participant)
  # overrides it per-call: FLEET_GENERATION=<gen> emit_event ...
  local _gen="${FLEET_GENERATION:-}"
  local _fence_rc=0
  if declare -f check_generation_fence >/dev/null 2>&1; then
    check_generation_fence "$tid" "$_gen" "${FLEET_STATE_DIR:-}" || _fence_rc=$?
    case "$_fence_rc" in
    0) ;;
    9)
      echo "emit_event: fence guard — missing generation token for fenced ticket ${tid} (fenced at generation ${FENCE_CHECK_FENCED_GEN:-0})" >&2
      return 9
      ;;
    10)
      echo "emit_event: fence guard — generation ${_gen} is superseded by fenced generation ${FENCE_CHECK_FENCED_GEN:-0} for ${tid}" >&2
      return 10
      ;;
    *)
      echo "emit_event: fence check returned unexpected code ${_fence_rc} for ${tid}" >&2
      return 1
      ;;
    esac
  fi

  # ── flock-guarded seq assignment + JSON Lines append ────────────────────
  local _outbox_dir _outbox_file _lock_file
  _outbox_dir=$(_events_outbox_dir)
  mkdir -p "$_outbox_dir" 2>/dev/null || true
  _outbox_file=$(_events_outbox_file "$tid")
  _lock_file=$(_events_lock_file "$tid")

  exec 7>"$_lock_file" || {
    echo "emit_event: failed to open lock file ${_lock_file}" >&2
    return 1
  }
  if ! flock -w "${EVENTS_LOCK_TIMEOUT_SECS:-30}" 7; then
    echo "emit_event: lock timeout acquiring outbox lock for ${tid}" >&2
    exec 7>&-
    return 1
  fi

  # ── Idempotency dedup (must run under the same lock as the append) ─────
  if [ -n "$_idem" ] && [ -f "$_outbox_file" ] &&
    jq -e --arg idem "$_idem" 'select(.idem == $idem) | true' "$_outbox_file" \
      >/dev/null 2>&1; then
    exec 7>&-
    return 0
  fi

  local _last_seq _next_seq
  _last_seq=$(tail -n 1 "$_outbox_file" 2>/dev/null | jq -r '.seq // 0' 2>/dev/null) || _last_seq=0
  [[ "$_last_seq" =~ ^[0-9]+$ ]] || _last_seq=0
  _next_seq=$((_last_seq + 1))

  local _record
  _record=$(jq -nc \
    --argjson seq "$_next_seq" \
    --arg tid "$tid" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson gen "${_gen:-0}" \
    --arg event "$event" \
    --argjson data "$data" \
    --arg from_hint "${EMIT_EVENT_FROM_HINT:-}" \
    --arg idem "$_idem" \
    '{seq: $seq, tid: $tid, ts: $ts, gen: $gen, event: $event, data: $data,
      from_hint: (if $from_hint == "" then null else $from_hint end),
      idem: (if $idem == "" then null else $idem end)}' 2>/dev/null) || {
    echo "emit_event: failed to build JSON record for ${tid}/${event}" >&2
    exec 7>&-
    return 1
  }

  if ! printf '%s\n' "$_record" >>"$_outbox_file"; then
    echo "emit_event: write failed for ${_outbox_file}" >&2
    exec 7>&-
    return 1
  fi

  exec 7>&-
  return 0
}

# ── CLI entrypoint ────────────────────────────────────────────────────────────
# Lets non-bash callers (fleetd's Python phase-dispatch, fleet-intervene.sh's
# own separate process) shell out rather than re-implementing emission.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
  emit)
    shift
    emit_event "$@"
    ;;
  *)
    echo "Usage: events.sh emit <TID> <EVENT> <JSON_DATA>" >&2
    exit 1
    ;;
  esac
fi
