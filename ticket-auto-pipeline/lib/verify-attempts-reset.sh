#!/usr/bin/env bash
# verify-attempts-reset.sh — the one supported way to reset a ticket's VERIFY
# attempt count (#573), after an operator fixes the cause of earlier failures
# (a broken test environment, missing seed data, ...).
#
# Usage: verify-attempts-reset.sh [--log-file F] <TICKET_ID> <reason...>
#
# Writes `reset|<log line count>|<iso>|<reason>` to `<LOG>.verify-ctl`: only
# attempts after that log line count toward the cap (lib/verify-checkpoint.sh).
# Also appends `META|verify-attempts-reset|info|<reason>` to the pipeline log as
# an audit record; counters ignore that line, because phase agents can write
# the log directly and must never be able to reset their own cap.
#
# Refuses agent context (exit 4): CLAUDE_CODE_SESSION_ID or FLEET_WORKER_PID
# set — run it from a plain terminal, the same rule adr-store.sh's adr_accept
# uses. Refuses once VERIFY_RESET_MAX (default 2) resets are on record
# (exit 5): counters honour no more than that, so an extra one would be a no-op
# that looks like it worked. This raises the bar; it is not a sandbox — an
# agent that writes the control file itself is deliberately forging operator
# state.
#
# Exit: 0 reset recorded, 2 usage, 3 log not found, 4 agent context, 5 cap.
set -eo pipefail

usage() {
  echo "Usage: verify-attempts-reset.sh [--log-file F] <TICKET_ID> <reason...>" >&2
  exit 2
}

log_file=""
if [ "${1:-}" = "--log-file" ]; then
  [ $# -ge 2 ] || usage
  log_file="$2"
  shift 2
fi
[ $# -ge 2 ] || usage
tid="$1"
shift
reason="$*"
case "$tid" in '' | *[!A-Za-z0-9_-]*) usage ;; esac
reason=$(printf '%s' "$reason" | tr -d '\n\r|')
[ -n "$reason" ] || usage

if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -n "${FLEET_WORKER_PID:-}" ]; then
  echo "verify-attempts-reset: refusing to run in an agent context (CLAUDE_CODE_SESSION_ID/FLEET_WORKER_PID set); run it from a terminal" >&2
  exit 4
fi

[ -n "$log_file" ] || log_file="${FLEET_PIPELINE_LOG_DIR:-./logs}/${tid}-pipeline.log"
if [ ! -f "$log_file" ]; then
  echo "verify-attempts-reset: pipeline log not found: $log_file" >&2
  exit 3
fi

ctl="$log_file.verify-ctl"
max="${VERIFY_RESET_MAX:-2}"
case "$max" in '' | *[!0-9]*) max=2 ;; esac
have=0
if [ -f "$ctl" ]; then
  have=$(grep -c '^reset|' "$ctl" 2>/dev/null || true)
  have=${have:-0}
fi
if [ "$have" -ge "$max" ]; then
  echo "verify-attempts-reset: $have reset(s) already recorded for $tid; VERIFY_RESET_MAX=$max — not recording another" >&2
  exit 5
fi

iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
lines=$(wc -l <"$log_file" | tr -d ' ')
printf 'reset|%s|%s|%s\n' "$lines" "$iso" "$reason" >>"$ctl"
printf '%s|META|verify-attempts-reset|info|%s\n' "$iso" "$reason" >>"$log_file"
echo "verify-attempts-reset: recorded for $tid at log line $lines ($((have + 1))/$max)"
