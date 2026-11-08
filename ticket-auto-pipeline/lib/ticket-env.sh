#!/usr/bin/env bash
# ticket-env.sh — source a ticket's env file from the private scratch dir.
#
# Usage (sourced, from skill prose and phase agents):
#   source ~/.claude/skills/lib/ticket-env.sh <TICKET_ID>
#
# Replaces the old `source /tmp/ticket-auto-<ID>-env.sh 2>/dev/null || true`
# (GitHub #619). The file is found through ticket-tmp.sh's one resolution rule
# and sourced only when ticket_tmp_trusted accepts it. A missing file is
# silent, exactly like the old `2>/dev/null || true`; an untrusted one is
# warned about on stderr and skipped. Always returns 0, so a `set -e` caller
# and a fence that ends on this line both survive it.

_ticket_env_tid="${1:-}"
if [ -n "$_ticket_env_tid" ]; then
  # Find ticket-tmp.sh beside this file. BASH_SOURCE is empty when an agent
  # sources this from zsh, so fall back to the synced lib dir (the same
  # CLAUDE_SKILLS_LIB convention the router prose uses).
  _ticket_env_lib=""
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _ticket_env_lib="${BASH_SOURCE[0]%/*}"
    [ "$_ticket_env_lib" != "${BASH_SOURCE[0]}" ] || _ticket_env_lib="."
  fi
  if [ -z "$_ticket_env_lib" ] || [ ! -f "$_ticket_env_lib/ticket-tmp.sh" ]; then
    _ticket_env_lib="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
  fi
  # shellcheck source=ticket-tmp.sh
  source "$_ticket_env_lib/ticket-tmp.sh" 2>/dev/null || true
  unset _ticket_env_lib
  if declare -f ticket_tmp_path >/dev/null 2>&1; then
    _ticket_env_file=$(ticket_tmp_path "$_ticket_env_tid" env.sh) || _ticket_env_file=""
    if [ -n "$_ticket_env_file" ] && { [ -e "$_ticket_env_file" ] || [ -L "$_ticket_env_file" ]; }; then
      if ticket_tmp_trusted "$_ticket_env_file"; then
        # shellcheck disable=SC1090
        source "$_ticket_env_file" || true
      else
        echo "ticket-env: refusing untrusted env file $_ticket_env_file" >&2
      fi
    fi
    unset _ticket_env_file
  fi
fi
unset _ticket_env_tid
return 0 2>/dev/null || exit 0
