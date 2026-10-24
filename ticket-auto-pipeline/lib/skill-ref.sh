#!/usr/bin/env bash
# skill-ref.sh — print the installed path of a file inside a ticket-auto-pipeline
# skill directory (typically `references/<name>.md`).
#
# Usage:
#   bash ~/.claude/skills/lib/skill-ref.sh <skill> <file>
#   e.g. skill-ref.sh ticket-verify references/build-only.md
#
# Resolves `skills/<skill>/<file>` through `tap_cache_find` (plugin-cache.sh):
# the installPath recorded in installed_plugins.json first, else the newest
# cached version by numeric order. Deliberately never CLAUDE_PLUGIN_ROOT (unset
# in Bash-tool context) and never a hard-coded ~/.claude/skills/<skill>/ path
# (the SessionStart sync copies only selected skill files there).
#
# Exit codes:
#   0  path printed on stdout
#   1  no cached copy of the file (message on stderr, stdout empty)
#   2  usage: fewer than two arguments, an empty one, or an absolute path or
#      `..` component in either (a caller cannot escape the skill directory)

set -eo pipefail

_SR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_sr_usage() {
  echo "usage: skill-ref.sh <skill> <file>${1:+ — $1}" >&2
  exit 2
}

# Refuse an absolute path or any `..` path component.
_sr_check_component() {
  local what="$1" value="$2"
  case "$value" in
  "") _sr_usage "empty ${what}" ;;
  /*) _sr_usage "${what} must be relative: ${value}" ;;
  esac
  case "/${value}/" in
  */../*) _sr_usage "${what} must not contain '..': ${value}" ;;
  esac
  return 0
}

[ "$#" -ge 2 ] || _sr_usage
_sr_check_component skill "$1"
_sr_check_component file "$2"

if ! declare -f tap_cache_find >/dev/null 2>&1; then
  if [ ! -f "$_SR_LIB_DIR/plugin-cache.sh" ]; then
    echo "skill-ref.sh: plugin-cache.sh not found in $_SR_LIB_DIR" >&2
    exit 1
  fi
  # shellcheck source=plugin-cache.sh
  source "$_SR_LIB_DIR/plugin-cache.sh"
fi

path=$(tap_cache_find ticket-auto-pipeline "skills/${1}/${2}")
if [ -z "$path" ]; then
  echo "skill-ref.sh: no installed copy of skills/${1}/${2} (ticket-auto-pipeline)" >&2
  exit 1
fi
echo "$path"
