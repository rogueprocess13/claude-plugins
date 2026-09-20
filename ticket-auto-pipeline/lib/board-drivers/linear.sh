#!/usr/bin/env bash
# linear.sh — the one production board driver (tracker-event-board-pusher,
# Phase B2 of the tracker-decoupling programme, Track B).
#
# ── Driver CLI contract (shared by every board driver script) ──────────────
# Usage: <driver>.sh apply <TID> <EVENT> <SEQ> <JSON_DATA>
#
# Exit codes:
#   0  handled — including an explicit no-op. A driver with no column or
#      mapping for the given event treats it as a no-op, not an error.
#   nonzero  retryable failure. The caller (pusher.py / outbox-drain.sh)
#      does NOT advance the cursor past this entry and retries it next
#      cycle.
#
# SEQ is passed as its own argument, not only embedded in JSON_DATA, so a
# driver that needs to dedup a replayed dispatch (idempotent-dispatch
# requirement — see tracker-board-driver-contract's spec) always has it
# available without parsing the event's own payload shape.
#
# Every driver resolves its own file paths via BASH_SOURCE, NEVER the
# invoker's $PWD: fleetd's `subprocess.run` inherits the daemon's own cwd,
# while outbox-drain.sh runs from the router's cwd — a driver that located
# workflow.json relative to $PWD would silently behave differently
# depending on which runner called it (design.md Decision 3).
#
# Every driver's `apply` must be safe to invoke twice for the same
# (TID, EVENT, SEQ, JSON_DATA) without a second distinct external effect —
# required because the cursor mechanism can re-dispatch an entry after a
# crash between dispatch and cursor persistence.
# ─────────────────────────────────────────────────────────────────────────
#
# This driver's mapping is sourced from workflow.json's board_drivers.linear
# object, not hardcoded here, so it is inspectable and versioned alongside
# the event vocabulary it maps (tracker-board-driver-contract spec). In this
# phase board_drivers.linear is populated as {} — driver registered, no
# active mappings — so every event this driver receives is an explicit,
# logged no-op (design.md Decision 1: the ten hold/lifecycle events this
# phase routes through the pusher for the first time have zero existing
# Linear projection to reproduce; real mappings are a follow-up phase's
# work, once the flow-driven-sites cutover question is resolved).
#
# -u intentionally omitted — see events.sh's identical note.
set -eo pipefail

_LD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Same monorepo -> installed skill -> plugin-cache fallback chain events.sh
# uses for workflow.json resolution — anchored at this script's own
# location via BASH_SOURCE, never $PWD.
_linear_driver_resolve_workflow_json() {
  local _cand
  for _cand in \
    "$_LD_LIB_DIR/../skills/ticket-flow/workflow.json" \
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

_linear_driver_apply() {
  local tid="$1" event="$2" seq="$3" data="${4:-}"
  # Not "${4:-{}}" — bash's default-value parsing does not brace-match
  # arbitrary content, so a literal "{}" inside the ${VAR:-word} form leaks
  # a stray trailing "}" onto every caller-supplied value, not just the
  # fallback case (same bug class events.sh's emit_event documents and
  # works around). Assign the default separately instead.
  [ -z "$data" ] && data="{}"

  if [ -z "$tid" ] || [ -z "$event" ] || [ -z "$seq" ]; then
    echo "linear.sh apply: TID, EVENT and SEQ are required" >&2
    return 2
  fi

  local wf
  wf=$(_linear_driver_resolve_workflow_json) || {
    echo "linear.sh apply: workflow.json not found" >&2
    return 1
  }

  local mapping
  mapping=$(jq -c --arg e "$event" '.board_drivers.linear[$e] // null' "$wf" 2>/dev/null) || mapping="null"

  if [ "$mapping" = "null" ]; then
    echo "linear.sh apply: no-op — event '${event}' (seq ${seq}, tid ${tid}) has no board_drivers.linear mapping" >&2
    return 0
  fi

  # No mapping is populated in this phase (design.md Decision 1), so this
  # branch is unreachable today — kept explicit so a future phase adding
  # real mappings has a place to implement the actual mutation, and so the
  # "unmapped is a no-op, mapped is a real action" split is visible in the
  # code, not just in prose.
  echo "linear.sh apply: mapped event '${event}' (seq ${seq}, tid ${tid}) — no mutation implemented yet: ${mapping}" >&2
  return 1
}

# ── CLI entrypoint ───────────────────────────────────────────────────────
case "${1:-}" in
apply)
  shift
  _linear_driver_apply "$@"
  ;;
*)
  echo "Usage: linear.sh apply <TID> <EVENT> <SEQ> <JSON_DATA>" >&2
  exit 1
  ;;
esac
