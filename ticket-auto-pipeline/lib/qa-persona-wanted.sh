#!/usr/bin/env bash
# qa-persona-wanted.sh — does ticket-verify load the QA persona for this
# ticket? (openspec change verify-qa-persona, task group 5)
#
#   qa-persona-wanted.sh <TID> [<context.md>]
#
# Prints `true` or `false` on stdout, exit 0 (2 on usage). The decision is
# deterministic and never the agent's:
#
#   VERIFY_QA_PERSONA   persona
#   true                on for every ticket
#   false               off
#   bug (default)       on when the ticket's type is exactly `bug`, as
#                       ticket-type.sh derives it: the local manifest `type`
#                       (needs REPOS_ROOT), else a whole `bug` label on the
#                       context.md `**Labels:**` line. No type means off.
#   anything else       counts as `bug`, with one META|qa-persona|warn line
#
# Sourceable: sets no shell options.

_QPW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f ticket_type_resolve >/dev/null 2>&1 ||
  source "$_QPW_DIR/ticket-type.sh"

# qa_persona_wanted <TID> [<context.md>]
qa_persona_wanted() {
  local tid="${1:-}" ctx="${2:-}" mode="${VERIFY_QA_PERSONA:-bug}" labels="" t
  case "$mode" in
  true | false | bug) ;;
  *)
    bash "$_QPW_DIR/plog.sh" META qa-persona warn \
      "VERIFY_QA_PERSONA=$mode is not bug, true or false; using bug" >/dev/null 2>&1 || true
    echo "qa-persona-wanted: VERIFY_QA_PERSONA=$mode is not bug, true or false; using bug" >&2
    mode=bug
    ;;
  esac
  if [ "$mode" != "bug" ]; then
    echo "$mode"
    return 0
  fi
  [ -n "$ctx" ] && labels=$(ticket_type_context_labels "$ctx")
  t=$(ticket_type_resolve "$tid" "$labels")
  if [ "$t" = "bug" ]; then echo true; else echo false; fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ] || [ $# -gt 2 ]; then
    echo "usage: qa-persona-wanted.sh <TID> [<context.md>]" >&2
    exit 2
  fi
  qa_persona_wanted "$@"
fi
