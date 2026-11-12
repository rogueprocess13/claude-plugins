#!/usr/bin/env bash
# adversarial-override.sh — the one supported way for a human to accept a
# plan that ticket-appraise-exec's adversarial review BLOCKED, without
# another review round (GitHub #610).
#
# Usage: adversarial-override.sh [--log-file F] <TICKET_ID> --reason "<why>"
#
# Appends, in order:
#   META|adversarial-override|info|reason=<why>      the operator marker
#   EXEC|adversarial-review|done|WARNINGS — HUMAN OVERRIDE: <why>
#   META|verifier-result|info|{adversarial_review, WARN, phase EXEC}
#
# The marker and the WARN result supersede the live BLOCK in flow.sh's
# verdict gate (lib/verifier-result.sh verifier_latest_verdict), so
# pr-review-pass-* is no longer refused hours later. The done line is what
# detect-resume.sh and adversarial-rounds.sh read, so the pipeline resumes
# and the round count resets. A fresh BLOCKED round after this re-arms the
# gate. A plain done line written without this script does not clear the
# verdict gate.
#
# Refuses agent and fleetd-worker context (exit 4): CLAUDE_CODE_SESSION_ID,
# FLEET_WORKER_PID or FLEET_GENERATION set — run it from a plain terminal.
# This raises the bar; it is not a sandbox (same stance as
# verify-attempts-reset.sh).
#
# Exit: 0 recorded, 2 usage (incl. empty reason), 3 log not found,
#       4 agent context, 5 no live adversarial BLOCK to override.
set -eo pipefail

_AO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: adversarial-override.sh [--log-file F] <TICKET_ID> --reason \"<why>\"" >&2
  exit 2
}

log_file="" tid="" reason=""
while [ $# -gt 0 ]; do
  case "$1" in
  --log-file)
    [ $# -ge 2 ] || usage
    log_file="$2"
    shift 2
    ;;
  --reason)
    [ $# -ge 2 ] || usage
    reason="$2"
    shift 2
    ;;
  -*) usage ;;
  *)
    [ -z "$tid" ] || usage
    tid="$1"
    shift
    ;;
  esac
done
case "$tid" in '' | *[!A-Za-z0-9_-]*) usage ;; esac
reason=$(printf '%s' "$reason" | tr -d '\n\r|' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
if [ -z "$reason" ]; then
  echo "adversarial-override: --reason is required and must not be empty" >&2
  usage
fi

if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -n "${FLEET_WORKER_PID:-}" ] || [ -n "${FLEET_GENERATION:-}" ]; then
  echo "adversarial-override: refusing to run in an agent or fleetd-worker context (CLAUDE_CODE_SESSION_ID/FLEET_WORKER_PID/FLEET_GENERATION set); run it from a terminal" >&2
  exit 4
fi

if [ -z "$log_file" ]; then
  # The anchored per-ticket state dir (lib/log-dir.sh, state-root-anchor),
  # else (legacy, with a warning) ${FLEET_PIPELINE_LOG_DIR:-./logs};
  # STATE_ROOT_STRICT=true and unresolved exits 13.
  _ld_dir="${FLEET_PIPELINE_LOG_DIR:-./logs}"
  if [ -f "$_AO_DIR/log-dir.sh" ]; then
    # shellcheck source=log-dir.sh
    source "$_AO_DIR/log-dir.sh"
    _ld_rc=0
    ticket_log_dir_or_legacy_set || _ld_rc=$?
    if [ "$_ld_rc" -ne 0 ]; then
      exit "$_ld_rc"
    fi
    _ld_dir="$TICKET_LOG_DIR_RESOLVED"
  fi
  log_file="${_ld_dir}/${tid}-pipeline.log"
fi
if [ ! -f "$log_file" ]; then
  echo "adversarial-override: pipeline log not found: $log_file" >&2
  exit 3
fi

if [ -f "$_AO_DIR/verifier-result.sh" ]; then
  # shellcheck source=/dev/null
  source "$_AO_DIR/verifier-result.sh"
else
  # shellcheck source=/dev/null
  source "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/verifier-result.sh"
fi

_live=$(verifier_latest_verdict "$log_file")
if [[ $'\n'"$_live" != *$'\n'"adversarial_review|EXEC|BLOCK"* ]]; then
  echo "adversarial-override: no live adversarial_review BLOCK in $log_file — nothing to override" >&2
  exit 5
fi

# Carry the last BLOCK's criteria; the override is the next attempt.
_last=$(awk -F'|' '$2=="META" && $3=="verifier-result" {
  s=$5; for (i=6;i<=NF;i++) s=s"|"$i; print s }' "$log_file" |
  jq -c 'select(.verifier=="adversarial_review" and .phase=="EXEC")' 2>/dev/null | tail -1)
[ -n "$_last" ] || _last='{}'
_met=$(jq -r '.criteria_met // 0' <<<"$_last" 2>/dev/null || echo 0)
_total=$(jq -r '.criteria_total // 0' <<<"$_last" 2>/dev/null || echo 0)
_attempt=$(jq -r '(.attempt // 0) + 1' <<<"$_last" 2>/dev/null || echo 1)

iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s|META|adversarial-override|info|reason=%s\n' "$iso" "$reason" >>"$log_file"
printf '%s|EXEC|adversarial-review|done|WARNINGS — HUMAN OVERRIDE: %s\n' "$iso" "$reason" >>"$log_file"
LOG_FILE="$log_file" write_verifier_result verifier=adversarial_review verdict=WARN \
  criteria_met="$_met" criteria_total="$_total" attempt="$_attempt" phase=EXEC

echo "adversarial-override: recorded for $tid (attempt $_attempt) — re-run /ticket-auto $tid to resume"
