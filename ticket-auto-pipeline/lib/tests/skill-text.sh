#!/usr/bin/env bash
# skill-text.sh — shared helpers for tests that slice skill prose by heading
# (skill-progressive-disclosure, design D6). Source it; it defines functions
# only and sets no shell options.
#
#   _section <file> <start-re> [end-re]
#       Lines from the first line matching start-re up to (not including) the
#       next line matching end-re. With no end-re (or an empty one), to EOF.
#       Prints nothing when start-re never matches.
#
#   _section_ref <ref> <start-re> [end-re]
#       The same slice, taken from a skill's reference file. <ref> is
#       "<skill>/references/<file>.md" (or ".../templates/<file>.md"),
#       resolved against this checkout's ticket-auto-pipeline/skills/ — tests
#       run from the source tree, never the plugin cache, so they do not call
#       lib/skill-ref.sh. A ref that does not resolve to a file prints a
#       message on stderr and returns 1, so a test pointed at a renamed or
#       never-created reference fails instead of slicing nothing.
#
#   _skill_ref_path <ref>
#       The resolved path _section_ref reads (exit 1 when absent).

_SKILL_TEXT_SKILLS_DIR="${_SKILL_TEXT_SKILLS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../skills" && pwd)}"

_section() {
  awk -v s="$2" -v e="${3:-}" '
    !on && $0 ~ s { on = 1; print; next }
    on && e != "" && $0 ~ e { exit }
    on { print }
  ' "$1"
}

_skill_ref_path() {
  local ref="$1" path
  case "$ref" in
  */references/*.md | */templates/*.md) ;;
  *)
    echo "_skill_ref_path: not a <skill>/references/<file>.md path: $ref" >&2
    return 1
    ;;
  esac
  path="$_SKILL_TEXT_SKILLS_DIR/$ref"
  if [ ! -f "$path" ]; then
    echo "_skill_ref_path: no such reference: $path" >&2
    return 1
  fi
  printf '%s\n' "$path"
}

_section_ref() {
  local path
  path=$(_skill_ref_path "$1") || return 1
  _section "$path" "$2" "${3:-}"
}
