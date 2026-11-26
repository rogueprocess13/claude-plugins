#!/usr/bin/env bash
# operator-root.sh — REPOS_ROOT for an operator script a person runs in their
# own shell (skills/ticket-approve/approve.sh, lib/regression-ack.sh).
#
# A person's shell can still hold an exported REPOS_ROOT from work on another
# project. Taken on trust, it records the approval or the acknowledgement in
# that other project's manifest while the ticket's own stays held (GitHub
# #818). So the root is resolved, then checked:
#
#   1. Resolution: the environment, else the ticket's env file, else the
#      project CLAUDE.md in the current directory (./CLAUDE.md).
#   2. Agreement: when ./CLAUDE.md declares a REPOS_ROOT and the root came
#      from somewhere else, the two must name the same directory. A mismatch
#      is a refusal that prints both values.
#   3. Existence: the ticket's manifest must already exist under the root.
#      A ticket held at a gate always has one (flow.sh wrote it when the
#      ticket got there), so a missing manifest means the wrong root; it is
#      never created here.
#
# Function definitions only — safe to source. Needs manifest-read.sh (or
# manifest-write.sh, which sources it) loaded for step 3.

_OPERATOR_ROOT_LIB="${BASH_SOURCE[0]%/*}"

# _operator_root_norm <path> — the physical path of an existing directory,
# else the path with trailing slashes removed.
_operator_root_norm() {
  local p="$1"
  if [ -d "$p" ]; then
    (cd "$p" 2>/dev/null && pwd -P) && return 0
  fi
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s\n' "$p"
}

# operator_resolve_repos_root <who> <TICKET-ID>
# Sets and exports REPOS_ROOT, and sets OPERATOR_ROOT_SOURCE (environment,
# ticket env file, ./CLAUDE.md). Returns 0, or 3 with a message naming
# <who> on stderr: no root at all, or a root that disagrees with ./CLAUDE.md.
operator_resolve_repos_root() {
  local who="$1" tid="$2" lib md_root=""
  lib="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
  OPERATOR_ROOT_SOURCE=""
  if [ -n "${REPOS_ROOT:-}" ]; then
    OPERATOR_ROOT_SOURCE="environment"
  else
    local _f
    for _f in "$lib/ticket-env.sh" "$_OPERATOR_ROOT_LIB/ticket-env.sh"; do
      if [ -f "$_f" ]; then
        # shellcheck source=/dev/null
        source "$_f" "$tid" 2>/dev/null || true
        break
      fi
    done
    [ -z "${REPOS_ROOT:-}" ] || OPERATOR_ROOT_SOURCE="ticket env file"
  fi

  if [ -f ./CLAUDE.md ]; then
    declare -f claude_md_field >/dev/null 2>&1 ||
      source "$lib/claude-md-field.sh" 2>/dev/null ||
      source "$_OPERATOR_ROOT_LIB/claude-md-field.sh" 2>/dev/null || true
    if declare -f claude_md_field >/dev/null 2>&1; then
      md_root=$(claude_md_field ./CLAUDE.md REPOS_ROOT 2>/dev/null) || md_root=""
    fi
  fi

  if [ -z "${REPOS_ROOT:-}" ]; then
    if [ -z "$md_root" ]; then
      echo "$who: REPOS_ROOT is not set and ./CLAUDE.md declares none. Run this from the project's tickets root, or export REPOS_ROOT. Nothing was recorded." >&2
      return 3
    fi
    REPOS_ROOT="$md_root"
    OPERATOR_ROOT_SOURCE="./CLAUDE.md"
  elif [ -n "$md_root" ] &&
    [ "$(_operator_root_norm "$REPOS_ROOT")" != "$(_operator_root_norm "$md_root")" ]; then
    {
      echo "$who: REPOS_ROOT disagrees with this project's CLAUDE.md. Nothing was recorded."
      echo "  REPOS_ROOT from the $OPERATOR_ROOT_SOURCE: $REPOS_ROOT"
      echo "  REPOS_ROOT in $PWD/CLAUDE.md: $md_root"
      echo "Your shell may still hold a REPOS_ROOT from another project. Unset it (or set it to this project's root), then run this again."
    } >&2
    return 3
  fi
  export REPOS_ROOT
}

# operator_require_manifest <who> <TICKET-ID>
# Prints the ticket's manifest path under REPOS_ROOT and returns 0 when the
# manifest exists; else returns 3 with a message on stderr. Never creates
# one.
operator_require_manifest() {
  local who="$1" tid="$2" path=""
  path=$(get_ticket_manifest_path "$tid" 2>/dev/null) || path=""
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    {
      echo "$who: $tid has no manifest under REPOS_ROOT=$REPOS_ROOT (from the ${OPERATOR_ROOT_SOURCE:-environment}). Nothing was recorded."
      echo "A ticket held at a gate always has one, so this is most likely the wrong project root. Check REPOS_ROOT, then run this again."
    } >&2
    return 3
  fi
  printf '%s\n' "$path"
}
