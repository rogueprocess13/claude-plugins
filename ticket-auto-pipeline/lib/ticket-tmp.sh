#!/usr/bin/env bash
# ticket-tmp.sh — the pipeline's private per-user scratch directory (GitHub #619).
#
# Every per-ticket scratch file (env.sh, spawn-meta, ctx, start stamps, agent
# progress, the bash fallback for stop files and the background-PID ledger)
# lives here instead of under a predictable name in shared /tmp, where another
# local user could pre-create the file or a symlink and steer our writes.
#
# Resolution (one rule, mirrored by fleetd's phase_dispatch.ticket_tmp_dir):
#   $TICKET_TMP_DIR                 when set and non-empty (tests, operators)
#   /tmp/ticket-auto-$EUID          otherwise
#
# The default deliberately depends on nothing but the effective uid (fleetd:
# os.geteuid()). XDG_RUNTIME_DIR and TMPDIR differ between a terminal, cron, nohup, a container and a Claude Code
# sandbox, and the router, its phase agents, the hooks and fleetd must all
# land on the same directory without being told.
#
# The directory is created 0700 if missing and REFUSED (non-zero return, a
# stderr warning, nothing printed) when it exists as a symlink, is not a
# directory, is owned by someone else, or has any group/other permission bit.
# Refusing fails closed: a planted directory costs a run, never a redirected
# write.
#
# Sourced:  ticket_tmp_dir            print the directory
#           ticket_tmp_peek           no-fork, no-create lookup for hot-path
#                                     hooks: sets TICKET_TMP_RESOLVED when the
#                                     dir exists, is not a symlink and is ours
#                                     (no mode check - that needs stat)
#           ticket_tmp_path TID NAME  print <dir>/ticket-auto-<TID>-<NAME>,
#                                     refusing a TID outside ^[A-Za-z0-9_-]+$
#           ticket_tmp_valid_id TID   0 when TID is safe in a path
#           ticket_tmp_trusted FILE   0 when FILE is a regular file, not a
#                                     symlink, ours, not group/other writable
# Executed: bash ticket-tmp.sh               print the directory
#           bash ticket-tmp.sh TID NAME      print the file path
#
# Exit/return: 0 ok, 1 refused or invalid.

ticket_tmp_valid_id() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]]
}

_ticket_tmp_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

ticket_tmp_peek() {
  local d="${TICKET_TMP_DIR:-/tmp/ticket-auto-${EUID}}"
  TICKET_TMP_RESOLVED=""
  [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || return 1
  TICKET_TMP_RESOLVED="$d"
}

ticket_tmp_dir() {
  local d m uid="$EUID"
  d="${TICKET_TMP_DIR:-/tmp/ticket-auto-${uid}}"
  if [ ! -e "$d" ] && [ ! -L "$d" ]; then
    # mkdir -m sets the mode exactly, whatever the umask. Losing a race to a
    # concurrent mkdir is fine: the checks below judge whoever won.
    mkdir -m 700 -- "$d" 2>/dev/null || true
  fi
  if [ -L "$d" ] || [ ! -d "$d" ] || [ ! -O "$d" ]; then
    echo "ticket-tmp: refusing scratch dir $d (symlink, not a directory, or not owned by uid $uid)" >&2
    return 1
  fi
  m=$(_ticket_tmp_mode "$d")
  case "$m" in
  '' | *[!0-7]*)
    echo "ticket-tmp: refusing scratch dir $d (cannot read its mode)" >&2
    return 1
    ;;
  esac
  if (((8#$m & 8#077) != 0)); then
    echo "ticket-tmp: refusing scratch dir $d (mode $m, must be 700)" >&2
    return 1
  fi
  printf '%s\n' "$d"
}

ticket_tmp_path() {
  local tid="${1:-}" name="${2:-}" d
  if ! ticket_tmp_valid_id "$tid"; then
    echo "ticket-tmp: invalid ticket id '$tid'" >&2
    return 1
  fi
  d=$(ticket_tmp_dir) || return 1
  printf '%s/ticket-auto-%s-%s\n' "$d" "$tid" "$name"
}

ticket_tmp_trusted() {
  local f="${1:-}" m
  [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] || return 1
  m=$(_ticket_tmp_mode "$f")
  case "$m" in '' | *[!0-7]*) return 1 ;; esac
  (((8#$m & 8#022) == 0))
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -ge 2 ]; then
    ticket_tmp_path "$1" "$2"
  else
    ticket_tmp_dir
  fi
  exit $?
fi
