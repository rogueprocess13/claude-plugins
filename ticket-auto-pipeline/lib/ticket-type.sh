#!/usr/bin/env bash
# ticket-type.sh — the one ticket-type derivation (#677): the local manifest
# `type`, else a whole `bug` tracker label, else nothing.
#
# Planned and /ticket-create tickets carry no type label: their type lives in
# the ticket manifest. A hand-filed ticket has no manifest, so its `bug`
# label is the fallback. No text heuristic lives here.
#
#   ticket_type_from_manifest <TID>     manifest type when it is a known
#                                       type, else nothing (needs REPOS_ROOT)
#   ticket_type_from_labels <CSV>       `bug` when the comma list holds a
#                                       whole `bug` label (case-insensitive)
#   ticket_type_context_labels <FILE>   the first `**Labels:**` line of a
#                                       context.md, as a comma list
#   ticket_type_resolve <TID> [<CSV>]   manifest, else labels, else nothing
#
# Every function prints one line or nothing and returns 0. Sourceable (no
# errexit leak) and a CLI:
#   ticket-type.sh <TID> [--labels CSV | --context FILE]
# prints the resolved type, `feature` when there is none. Exit 0, 2 usage.

# Keep in step with template-select.sh's KNOWN_TYPES (refactor is an alias).
_TICKET_TYPE_KNOWN=" bug feature improvement security chore refactor "
_TICKET_TYPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ticket_type_from_manifest() {
  local tid="${1:-}" t=""
  [ -n "$tid" ] && [ -n "${REPOS_ROOT:-}" ] || return 0
  if ! declare -f get_ticket_manifest_field >/dev/null 2>&1; then
    [ -f "$_TICKET_TYPE_DIR/manifest-read.sh" ] || return 0
    # shellcheck source=manifest-read.sh
    source "$_TICKET_TYPE_DIR/manifest-read.sh"
  fi
  # `|| true`: a missing index/manifest returns 1/3, fatal under set -e.
  t=$(get_ticket_manifest_field "$tid" type 2>/dev/null || true)
  # Unknown, empty or JSON null: dropped, not an error.
  case "$_TICKET_TYPE_KNOWN" in
  *" ${t} "*) echo "$t" ;;
  esac
  return 0
}

ticket_type_from_labels() {
  if tr ',' '\n' <<<"${1:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qix bug; then
    echo bug
  fi
  return 0
}

ticket_type_context_labels() {
  [ -f "${1:-}" ] || return 0
  grep -m1 '^\*\*Labels:\*\*' "$1" 2>/dev/null | sed 's/^\*\*Labels:\*\*//'
  return 0
}

ticket_type_resolve() {
  local t
  t=$(ticket_type_from_manifest "${1:-}")
  [ -n "$t" ] || t=$(ticket_type_from_labels "${2:-}")
  [ -z "$t" ] || echo "$t"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _tt_tid="${1:-}" _tt_labels=""
  [ -n "$_tt_tid" ] && [ "${_tt_tid#-}" = "$_tt_tid" ] || {
    echo "usage: ticket-type.sh <TID> [--labels CSV | --context FILE]" >&2
    exit 2
  }
  case "${2:-}" in
  "") ;;
  --labels) _tt_labels="${3:-}" ;;
  --context) _tt_labels=$(ticket_type_context_labels "${3:-}") ;;
  *)
    echo "usage: ticket-type.sh <TID> [--labels CSV | --context FILE]" >&2
    exit 2
    ;;
  esac
  _tt=$(ticket_type_resolve "$_tt_tid" "$_tt_labels")
  echo "${_tt:-feature}"
fi
