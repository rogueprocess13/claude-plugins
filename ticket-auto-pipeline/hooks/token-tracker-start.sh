#!/bin/bash
# SubagentStart hook — writes nanosecond timestamp for phase duration tracking.
#
# Identity resolution mirrors token-tracker.sh (the SubagentStop counterpart):
# both hooks derive TICKET_ID/PHASE from the spawn-meta file
# ($(ticket_tmp_dir)/ticket-auto-{ID}-spawn-meta.txt) whose SESSION_ID matches the hook
# payload's session_id — the single shared source of truth, so start and stop
# can no longer disagree about which spawn they belong to. No ctx-file
# fallback, no ls -t across unrelated sessions.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

# Private per-user scratch dir (GitHub #619). Hooks never create it: no dir
# means no pipeline spawn on this host, so there is nothing to resolve.
_TT_LIB="${BASH_SOURCE[0]%/*}/../lib/ticket-tmp.sh"
# shellcheck source=../lib/ticket-tmp.sh
{ [ -f "$_TT_LIB" ] && source "$_TT_LIB" && ticket_tmp_peek; } || exit 0
SCRATCH="$TICKET_TMP_RESOLVED"

read -r hook_json
SESSION_ID=$(echo "$hook_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")

# No session identity on the payload — nothing to safely attribute to.
[ -z "$SESSION_ID" ] && exit 0

PHASE=""
TICKET_ID=""
for f in $(ls -t "$SCRATCH"/ticket-auto-*-spawn-meta.txt 2>/dev/null || true); do
  [ -f "$f" ] || continue
  _phase="" _sid=""
  while IFS='=' read -r key val; do
    case "$key" in
    PHASE) _phase="$val" ;;
    SESSION_ID) _sid="$val" ;;
    esac
  done <"$f"
  if [ "$_sid" = "$SESSION_ID" ]; then
    PHASE="$_phase"
    TICKET_ID=$(basename "$f" | sed 's/ticket-auto-\(.*\)-spawn-meta\.txt/\1/')
    break
  fi
done

# No matching live pipeline spawn for this session — nothing to track.
[ -z "$PHASE" ] && exit 0
[ -z "$TICKET_ID" ] && exit 0

# Unique suffix prevents sub-sub-agent spawns from overwriting the parent agent's
# start timestamp. A second SubagentStart within the same phase writes a distinct
# file so both elapsed_ms values survive to SubagentStop.
ticket_tmp_valid_id "$TICKET_ID" || exit 0
date +%s%N >"$SCRATCH/ticket-auto-${TICKET_ID}-start-${PHASE}-$(date +%s%N).ts"

# Best-effort telemetry — never block the agent that triggered this hook.
exit 0
