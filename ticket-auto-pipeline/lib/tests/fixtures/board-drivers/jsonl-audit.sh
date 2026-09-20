#!/usr/bin/env bash
# jsonl-audit.sh — TEST FIXTURE, NOT A SHIPPED PRODUCTION BOARD DRIVER.
#
# Deliberately kept out of lib/board-drivers/ (the production namespace).
# Exists only to make "a second driver configured alongside Linear receives
# every event independently" (the tracker-decoupling plan's own B2
# acceptance-gate wording) a real, running thing in the test suite, rather
# than a single-driver system with a no-op inference standing in for that
# gate (design.md Decision 3). Never reference this path from
# FLEET_BOARD_DRIVERS in production configuration.
#
# ── Driver CLI contract (see lib/board-drivers/linear.sh for the full text
# shared by every driver script) ────────────────────────────────────────
# Usage: jsonl-audit.sh apply <TID> <EVENT> <SEQ> <JSON_DATA>
# Exit 0 = handled. Nonzero = retryable failure. Resolves its own paths via
# BASH_SOURCE, never $PWD.
#
# Action: appends one JSON line per *newly-dispatched* SEQ to
# {FLEET_PIPELINE_LOG_DIR}/{TID}-board-dispatch-jsonl-audit.jsonl, first
# checking whether a line for that SEQ already exists and skipping the
# append if so. Plain unconditional append would satisfy "a truthful log of
# distinct events" but not "safe to invoke twice for the same SEQ" — the
# pusher's own crash-recovery path re-invokes a driver for an entry whose
# cursor write didn't complete, and this driver's second invocation for
# that SEQ must not append a second line. Seq-keyed dedup resolves both at
# once: a genuinely different SEQ still appends its own distinct line.
set -eo pipefail

_JA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_jsonl_audit_dir() {
  echo "${FLEET_PIPELINE_LOG_DIR:-./logs}"
}

_jsonl_audit_file() {
  echo "$(_jsonl_audit_dir)/${1}-board-dispatch-jsonl-audit.jsonl"
}

_jsonl_audit_apply() {
  local tid="$1" event="$2" seq="$3" data="${4:-}"
  # Not "${4:-{}}" — bash's default-value parsing does not brace-match
  # arbitrary content, so a literal "{}" inside the ${VAR:-word} form leaks
  # a stray trailing "}" onto every caller-supplied value, not just the
  # fallback case (same bug class events.sh's emit_event documents and
  # works around). Assign the default separately instead.
  [ -z "$data" ] && data="{}"

  if [ -z "$tid" ] || [ -z "$event" ] || [ -z "$seq" ]; then
    echo "jsonl-audit.sh apply: TID, EVENT and SEQ are required" >&2
    return 2
  fi

  local dir file
  dir=$(_jsonl_audit_dir)
  mkdir -p "$dir" 2>/dev/null || true
  file=$(_jsonl_audit_file "$tid")

  if [ -f "$file" ] && jq -e --argjson s "$seq" 'select(.seq == $s)' "$file" >/dev/null 2>&1; then
    echo "jsonl-audit.sh apply: seq ${seq} already recorded for ${tid} — skipping duplicate" >&2
    return 0
  fi

  local record
  record=$(jq -nc \
    --arg tid "$tid" \
    --arg event "$event" \
    --argjson seq "$seq" \
    --argjson data "$data" \
    --arg dispatched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{tid: $tid, event: $event, seq: $seq, data: $data, dispatched_at: $dispatched_at}') || {
    echo "jsonl-audit.sh apply: failed to build record for ${tid}/${event}" >&2
    return 1
  }

  printf '%s\n' "$record" >>"$file" || {
    echo "jsonl-audit.sh apply: write failed for ${file}" >&2
    return 1
  }
  return 0
}

# ── CLI entrypoint ───────────────────────────────────────────────────────
case "${1:-}" in
apply)
  shift
  _jsonl_audit_apply "$@"
  ;;
*)
  echo "Usage: jsonl-audit.sh apply <TID> <EVENT> <SEQ> <JSON_DATA>" >&2
  exit 1
  ;;
esac
