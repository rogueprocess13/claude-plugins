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
# log-dir.sh (state-root-anchor): the one per-ticket dir resolver. A stale
# lib copy without it falls back to the old ${FLEET_PIPELINE_LOG_DIR:-./logs}.
_source_if_missing ticket_log_dir_or_legacy_set "$_EV_LIB_DIR/log-dir.sh" 2>/dev/null || true

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
  declare -f tap_cache_find >/dev/null 2>&1 ||
    source "$_EV_LIB_DIR/plugin-cache.sh" 2>/dev/null || true
  _found=$(tap_cache_find ticket-auto-pipeline skills/ticket-flow/workflow.json 2>/dev/null || true)
  if [ -n "$_found" ] && [ -f "$_found" ]; then
    echo "$_found"
    return 0
  fi
  return 1
}

# ── outbox path resolution ───────────────────────────────────────────────────
# Every writer for a given ticket MUST resolve the same file, or per-ticket
# seq monotonicity (guarded by the matching lock file below) silently breaks.
# The directory comes from lib/log-dir.sh (state-root-anchor, review ARCH-5):
# an absolute FLEET_PIPELINE_LOG_DIR, else the $REPOS_ROOT/.ticket-auto/log-dir
# anchor, else (legacy, with a warning) ./logs, or rc 13 under
# STATE_ROOT_STRICT=true. It used to be ${FLEET_PIPELINE_LOG_DIR:-./logs},
# so an emit from a repo subdirectory wrote a stray outbox no pusher reads.
# emit_event resolves once and holds the answer in _EV_OUTBOX_DIR (dynamic
# scope), so the helpers below all name the same directory.
_events_resolve_dir() {
  _EV_RESOLVED_DIR=""
  if declare -f ticket_log_dir_or_legacy_set >/dev/null 2>&1; then
    ticket_log_dir_or_legacy_set || return $?
    _EV_RESOLVED_DIR="$TICKET_LOG_DIR_RESOLVED"
  else
    _EV_RESOLVED_DIR="${FLEET_PIPELINE_LOG_DIR:-./logs}"
  fi
}

_events_outbox_dir() {
  if [ -n "${_EV_OUTBOX_DIR:-}" ]; then
    printf '%s\n' "$_EV_OUTBOX_DIR"
    return 0
  fi
  _events_resolve_dir || return $?
  printf '%s\n' "$_EV_RESOLVED_DIR"
}

_events_outbox_file() {
  echo "$(_events_outbox_dir)/${1}-outbox.jsonl"
}

_events_lock_file() {
  echo "$(_events_outbox_dir)/.${1}-outbox.lock"
}

# ── origin sidecar (board-cursor-first-drain, review ARCH-9) ─────────────────
# .{TID}-outbox-origin.json records, once per outbox, the seq at or below
# which records count as already projected. Records written before
# projection existed (ticket-auto-pipeline < 0.55.0) were applied to Linear
# directly, so replaying them is pure damage. board_cursor_get uses the
# sidecar as the start point for a board that has no cursor yet:
#   new outbox (no records yet)   -> {"origin_seq": 0, "kind": "new"}
#   legacy outbox (records exist) -> {"origin_seq": <max seq>, "kind": "legacy"}
# A sidecar left behind by a deleted outbox is reset to new/0, or the
# outbox's fresh seq 1 would sit at or below a stale origin and never project.
_events_origin_file() {
  echo "$(_events_outbox_dir)/.${1}-outbox-origin.json"
}

# _events_write_origin <tid> <dir> <last_seq>
# Called by emit_event under FD 7, after _last_seq and before the append.
# Never fails emit_event: a write error is logged to stderr and the append
# still runs (a missing sidecar reads as "start at the tail", the no-replay
# direction).
_events_write_origin() {
  local tid="$1" dir="$2" last_seq="$3"
  local file
  file=$(_events_origin_file "$tid")
  if [ -f "$file" ]; then
    [ "$last_seq" -eq 0 ] || return 0
    local cur
    cur=$(jq -r '.origin_seq // 0' "$file" 2>/dev/null) || cur=""
    [ "$cur" = "0" ] && return 0
  fi
  local kind=new
  [ "$last_seq" -gt 0 ] && kind=legacy
  find "$dir" -maxdepth 1 -name ".${tid}-outbox-origin.json.tmp.*" -mmin +60 \
    -delete 2>/dev/null || true
  local tmp="${file}.tmp.$$"
  # A directory at the sidecar path would swallow the mv (tmp moves inside
  # it and mv reports success), so treat it as a write failure.
  if [ ! -d "$file" ] && jq -nc --arg tid "$tid" --argjson origin "$last_seq" --arg kind "$kind" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{tid: $tid, origin_seq: $origin, created_at: $created_at, kind: $kind}' \
    >"$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  echo "emit_event: failed to write origin sidecar ${file}" >&2
  return 0
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
#   13 per-ticket log dir unresolvable under STATE_ROOT_STRICT=true (no file written)
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
  # Resolved once, before anything is created: strict + unresolved is rc 13
  # with no file written.
  local _EV_OUTBOX_DIR _EV_RESOLVED_DIR _rd_rc=0
  _events_resolve_dir || _rd_rc=$?
  if [ "$_rd_rc" -ne 0 ]; then
    echo "emit_event: per-ticket log dir unresolvable for ${tid} — nothing written" >&2
    return 13
  fi
  _EV_OUTBOX_DIR="$_EV_RESOLVED_DIR"
  local _outbox_dir _outbox_file _lock_file
  _outbox_dir="$_EV_OUTBOX_DIR"
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

  # A stray ./logs/{tid}-outbox.jsonl outside the resolved dir is reported
  # once per (tid, path) in the resolved pipeline log (D4). Under FD 7, so two
  # concurrent emits cannot both note it.
  if declare -f ticket_log_dir_note_stray >/dev/null 2>&1; then
    ticket_log_dir_note_stray "$tid" "$_outbox_dir" || true
  fi

  # ── Torn-line tolerance (review ARCH-10) ────────────────────────────────
  # A partial last line (disk full, a kill mid-printf) must not poison the
  # file. Every read below parses line by line with `fromjson?`, so one bad
  # line is skipped instead of failing the whole read: the old whole-file
  # `jq -e` exited non-zero at the parse error and read as "idem not seen",
  # and `tail -n 1 | jq` read a torn tail as seq 0, restarting seq at 1 —
  # below every board cursor, so both drains skipped those events for good.
  # A file that does not end in a newline gets one first, so the new record
  # is never glued onto the torn fragment.
  if [ -s "$_outbox_file" ] && [ -n "$(tail -c 1 "$_outbox_file" 2>/dev/null)" ]; then
    printf '\n' >>"$_outbox_file" 2>/dev/null || true
  fi

  # ── Idempotency dedup (must run under the same lock as the append) ─────
  if [ -n "$_idem" ] && [ -f "$_outbox_file" ] &&
    jq -Rne --arg idem "$_idem" \
      'any(inputs | fromjson? | objects; .idem == $idem)' "$_outbox_file" \
      >/dev/null 2>&1; then
    exec 7>&-
    return 0
  fi

  # Next seq = max(seq) over every parseable line, + 1 — not the last line's.
  local _last_seq=0 _next_seq
  if [ -f "$_outbox_file" ]; then
    _last_seq=$(jq -Rn '[inputs | fromjson? | objects | .seq | numbers] | max // 0' \
      "$_outbox_file" 2>/dev/null) || _last_seq=0
  fi
  [[ "$_last_seq" =~ ^[0-9]+$ ]] || _last_seq=0
  _next_seq=$((_last_seq + 1))

  # Origin sidecar (board-cursor-first-drain): written before the append, so
  # a drain that sees this record also sees the sidecar.
  _events_write_origin "$tid" "$_outbox_dir" "$_last_seq"
  if [[ "${EVENTS_TEST_PAUSE_AFTER_ORIGIN:-}" =~ ^[0-9.]+$ ]]; then
    sleep "$EVENTS_TEST_PAUSE_AFTER_ORIGIN"
  fi

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
