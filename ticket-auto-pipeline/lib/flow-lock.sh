#!/usr/bin/env bash
# flow-lock.sh — the one resolver for flow.sh's per-ticket mutex (review ARCH-3).
#
# flow.sh serialises transitions on a ticket with `flock` on
# `.ticket-flow-<TID>.lock`. That lock only works if every flow.sh copy (the
# plugin cache, the SessionStart sync under ~/.claude/skills, a repo checkout)
# and every reader (fleet-intervene.sh's _flow_mutex_held) open the SAME file.
# The old default, `<dir of the running flow.sh>/locks`, gave each copy its own
# lock, so two copies never excluded each other.
#
# Resolution (one rule; no Python mirror exists — fleetd only ever runs flow.sh,
# it never opens the lock itself):
#   $TICKET_FLOW_LOCK_DIR             when set and non-empty (tests, operators)
#   $REPOS_ROOT/.ticket-auto/locks    otherwise
#
# The lock is anchored to the state it protects: the ticket manifest lives
# under $REPOS_ROOT/.ticket-auto, and flow.sh already refuses to run without
# REPOS_ROOT (exit 13). Two hosts or two REPOS_ROOTs have separate manifests,
# so they need separate locks; two flow.sh copies on one REPOS_ROOT share both.
#
# Sourced:  flow_lock_dir         print the directory; return 1 when neither
#                                 TICKET_FLOW_LOCK_DIR nor REPOS_ROOT is set
#           flow_lock_path TID    print <dir>/.ticket-flow-<TID>.lock; return 1
#                                 when the dir is unresolvable or TID is not
#                                 ^[A-Za-z0-9_-]+$
# Nothing is created; the caller makes the directory if it needs to.

flow_lock_dir() {
  if [ -n "${TICKET_FLOW_LOCK_DIR:-}" ]; then
    printf '%s\n' "$TICKET_FLOW_LOCK_DIR"
    return 0
  fi
  [ -n "${REPOS_ROOT:-}" ] || return 1
  printf '%s\n' "${REPOS_ROOT%/}/.ticket-auto/locks"
}

flow_lock_path() {
  local tid="${1:-}" dir
  [[ "$tid" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  dir=$(flow_lock_dir) || return 1
  printf '%s/.ticket-flow-%s.lock\n' "$dir" "$tid"
}
