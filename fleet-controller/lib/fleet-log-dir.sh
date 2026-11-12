#!/usr/bin/env bash
# fleet-log-dir.sh — fleet-controller's bridge to ticket-auto-pipeline's
# per-ticket log-dir resolver (state-root-anchor, review ARCH-5).
#
# The one resolver is ticket-auto-pipeline/lib/log-dir.sh (`ticket_log_dir`:
# absolute FLEET_PIPELINE_LOG_DIR, then the $REPOS_ROOT/.ticket-auto/log-dir
# anchor). It is sourced here from the plugin layout, else from
# ~/.claude/skills/lib (synced by ticket-auto-pipeline's SessionStart hook),
# never copied — the same bridge fleet-config.sh uses for manifest-read.sh.
#
# Sourced API:
#   fleet_log_dir_or FALLBACK   the resolved dir, else FALLBACK (default
#                               ./logs). Always rc 0, never warns, never
#                               refuses under STATE_ROOT_STRICT: these are
#                               readers, and a reader passes today's default
#                               (usually ${FLEET_PIPELINE_LOG_DIR:-./logs}) so a
#                               host with no anchor behaves exactly as before.
#                               With log-dir.sh missing, prints FALLBACK.
#
# Sourceable library — no set flags.

if ! declare -f ticket_log_dir >/dev/null 2>&1; then
  _FLD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for _fld_lib in "$_FLD_DIR/../../ticket-auto-pipeline/lib" "$HOME/.claude/skills/lib"; do
    if [ -f "$_fld_lib/log-dir.sh" ]; then
      # shellcheck source=/dev/null
      source "$_fld_lib/log-dir.sh"
      break
    fi
  done
  unset _fld_lib
fi

fleet_log_dir_or() {
  local fallback="${1:-./logs}"
  if declare -f ticket_log_dir >/dev/null 2>&1; then
    ticket_log_dir 2>/dev/null || printf '%s\n' "$fallback"
  else
    printf '%s\n' "$fallback"
  fi
}
