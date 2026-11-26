#!/usr/bin/env bash
# notes-field.sh — read one field of ticket-implement's pre-implementation
# checkpoint line in a ticket's notes.md (GitHub #822).
#
# The checkpoint is one line of pipe-separated fields:
#   - Repos: {list} | Branch: {branch} | Worktree: {path} | Mode: {mode}
# A reader that takes everything after "Worktree: " keeps " | Mode: ..." and
# gets a path that does not exist. This is the one reader: the value stops at
# the next "|", trailing whitespace and surrounding backticks are removed, and
# the last checkpoint line wins (a re-implementation writes a new one).
#
# Usage: notes-field.sh worktree|branch|repos|mode <ticket-dir | notes.md>
# Output: the value on stdout. Exit 0 found, 1 no such field, 2 usage.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.

# notes_field <Field> <notes.md> — print the last value of "<Field>: ..."
notes_field() {
  local field="$1" notes="$2" val
  [ -n "$field" ] && [ -f "$notes" ] || return 1
  val=$(grep -E "(^|[[:space:]|])${field}: " "$notes" 2>/dev/null | tail -1 |
    sed -n "s/.*${field}: \([^|]*\).*/\1/p" |
    sed 's/[[:space:]]*$//; s/^`//; s/`$//')
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
  worktree) _nf_field=Worktree ;;
  branch) _nf_field=Branch ;;
  repos) _nf_field=Repos ;;
  mode) _nf_field=Mode ;;
  *)
    echo "usage: notes-field.sh worktree|branch|repos|mode <ticket-dir|notes.md>" >&2
    exit 2
    ;;
  esac
  [ -n "${2:-}" ] || {
    echo "usage: notes-field.sh $1 <ticket-dir|notes.md>" >&2
    exit 2
  }
  _nf_notes="$2"
  [ -d "$_nf_notes" ] && _nf_notes="$_nf_notes/notes.md"
  notes_field "$_nf_field" "$_nf_notes"
  exit $?
fi
