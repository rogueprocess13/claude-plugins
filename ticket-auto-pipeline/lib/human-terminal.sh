#!/usr/bin/env bash
# human-terminal.sh — "is a person driving this?" for the actuators that
# record a person's decision: ticket-approve/approve.sh,
# ticket-reject/reject.sh, and flow.sh for the triggers those two fire
# (human-approve / pr-iterate with provenance human, human-reject).
# lib/regression-ack.sh applies the same two checks inline.
#
# Sourced:
#   human_terminal_agent_context     0 when CLAUDE_CODE_SESSION_ID,
#                                    FLEET_WORKER_PID or FLEET_GENERATION is
#                                    set (an agent session or a fleetd worker)
#   human_terminal_present           0 when /dev/tty opens for reading and
#                                    writing and is a terminal
#   human_terminal_require <who> <what>
#                                    both checks; on a miss prints why on
#                                    stderr and returns 4
#   human_terminal_confirm <expected> <prompt...>
#                                    writes the prompt lines and
#                                    "Type <expected> to <last word> ..." to
#                                    the controlling terminal, reads one line
#                                    from it (never stdin), and returns 0 only
#                                    when the answer equals <expected>; 4 with
#                                    no terminal, 6 on any other answer
#
# There is no flag and no variable that skips a check. A Claude Code Bash
# call and a fleetd worker have no controlling terminal, so an unattended
# agent is refused even when it unsets the variables.
#
# What this does not stop: a process that allocates its own pseudo-terminal
# and types the answer, and anything that writes the manifest file directly.
# The check raises the bar and makes a bypass a deliberate act; it is not a
# sandbox.
#
# No `set -e` here: this file is sourced by scripts with their own options.

human_terminal_agent_context() {
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -n "${FLEET_WORKER_PID:-}" ] || [ -n "${FLEET_GENERATION:-}" ]
}

human_terminal_present() {
  # A subshell, so no file descriptor of the caller is touched (flow.sh
  # holds its lock on FD 9).
  (exec 7<>/dev/tty && [ -t 7 ]) 2>/dev/null
}

human_terminal_require() {
  local who="$1" what="$2"
  if human_terminal_agent_context; then
    echo "$who: refusing to $what in an agent or fleetd-worker context (CLAUDE_CODE_SESSION_ID/FLEET_WORKER_PID/FLEET_GENERATION set). This is a person's decision; run it in your own terminal." >&2
    return 4
  fi
  if ! human_terminal_present; then
    echo "$who: no terminal. A person must $what from an interactive terminal." >&2
    return 4
  fi
  return 0
}

human_terminal_confirm() {
  local expected="$1" answer="" line
  shift
  human_terminal_present || return 4
  {
    echo >&7
    for line in "$@"; do
      printf '%s\n' "$line" >&7
    done
    printf 'Type %s to confirm (anything else aborts): ' "$expected" >&7
    IFS= read -r answer <&7 || answer=""
  } 7<>/dev/tty || return 4
  answer=$(printf '%s' "$answer" | tr -d '[:space:]') || answer=""
  [ -n "$expected" ] && [ "$answer" = "$expected" ] || return 6
  return 0
}
