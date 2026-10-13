#!/usr/bin/env bash
# planner-context-extract.sh — the one Planner Context block extractor.
#
# Every consumer that reads a ticket's `## Planner Context` block (gate-check,
# planned-feedback-write, fleet-controller's fleet-feedback, and
# planned-ticket-check's own _extract_md_section) goes through this file, so the
# block-delimiter rules live in one place (GitHub #513). Before this, three
# consumers used an unanchored sed range from the heading text to the next
# `^## ` line, which also matched
# `### Planner Context`, a fenced copy, or the phrase in the middle of a
# sentence — and read whichever came first.
#
# Rules (md_section_extract):
#   - CR is stripped from every line first, so a CRLF body behaves like LF.
#   - A heading matches only as a whole line: `## <heading>` with optional
#     trailing whitespace. `### <heading>`, `## <heading> (copy)`, an indented
#     heading, or the text mid-line never match.
#   - Lines inside a fenced code block (``` or ~~~, up to 3 leading spaces,
#     closed by the same character at least as long, CommonMark rules) are
#     never headings — neither as the block's start nor as its end. An
#     unclosed fence runs to the end of the body, as in CommonMark. A
#     multi-line HTML comment (`<!--` ... `-->`) is treated the same way.
#   - The FIRST matching heading wins; a second real block is ignored.
#   - The block ends at the next real `##` heading (`## x` or a bare `##`),
#     or at end of input. The heading line itself is not printed.
#
# Field reads (planner_context_field) are line-anchored — `**Field:**` at the
# start of a line — take the first such line in the block, and skip lines
# inside a fence within the block.
#
# Sourceable library — no set -euo pipefail. Also a CLI:
#   planner-context-extract.sh block [body_file]          # print the block
#   planner-context-extract.sh field <name> [body_file]   # print one field

# Shared awk tracker for lines that can never be headings or fields.
# opaque_line(line) returns 1 when the line is a fence delimiter, inside a
# fence, or part of a multi-line HTML comment (`<!--` ... `-->`, which
# CommonMark renders as an HTML block, not a heading) — updating
# `infence`/`incomment` as it goes — and 0 for an ordinary line. Like an
# unclosed fence, an unclosed comment runs to the end of the body. Written
# without regex interval expressions so mawk handles it as well as gawk.
_PCX_AWK_FENCE='
function opaque_line(line,   m, ch, n, rest) {
  if (incomment) {
    if (index(line, "-->") > 0) incomment = 0
    return 1
  }
  if (match(line, /^ ? ? ?(```+|~~~+)/)) {
    m = substr(line, RSTART, RLENGTH)
    sub(/^ +/, "", m)
    ch = substr(m, 1, 1)
    n = length(m)
    rest = substr(line, RSTART + RLENGTH)
    if (!infence) {
      # A backtick fence info string may not itself contain a backtick.
      if (!(ch == "`" && index(rest, "`") > 0)) {
        infence = 1; fch = ch; flen = n
        return 1
      }
    } else if (ch == fch && n >= flen && rest ~ /^[ \t]*$/) {
      infence = 0
      return 1
    }
  }
  if (infence) return 1
  if (line ~ /^ ? ? ?<!--/) {
    rest = substr(line, index(line, "<!--") + 4)
    if (index(rest, "-->") == 0) incomment = 1
    return 1
  }
  return 0
}
'

# md_section_extract <heading> [file]
# Print the body of the first real `## <heading>` section in <file> (or stdin).
# Prints nothing when there is no such section. Always returns 0.
md_section_extract() {
  local heading="$1"
  shift
  PCX_HEADING="$heading" awk "$_PCX_AWK_FENCE"'
    BEGIN { want = "## " ENVIRON["PCX_HEADING"] }
    { sub(/\r$/, "") }
    opaque_line($0) { if (found) print; next }
    !found {
      line = $0
      sub(/[ \t]+$/, "", line)
      if (line == want) found = 1
      next
    }
    /^##([ \t]|$)/ { exit }
    { print }
  ' "$@"
}

# md_section_strip <heading> [file]
# Inverse of md_section_extract: print the input with every real
# `## <heading>` section (heading through the next real `##` heading) removed.
md_section_strip() {
  local heading="$1"
  shift
  PCX_HEADING="$heading" awk "$_PCX_AWK_FENCE"'
    BEGIN { want = "## " ENVIRON["PCX_HEADING"] }
    { sub(/\r$/, "") }
    opaque_line($0) { if (!skip) print; next }
    skip && /^##([ \t]|$)/ { skip = 0 }
    !skip {
      line = $0
      sub(/[ \t]+$/, "", line)
      if (line == want) { skip = 1; next }
    }
    !skip { print }
  ' "$@"
}

# planner_context_extract [body_file]
# Print the `## Planner Context` block body from <body_file> (or stdin).
planner_context_extract() {
  md_section_extract "Planner Context" "$@"
}

# planner_context_field <field> [block_file]
# Read a block (stdin, or <block_file>) and print the value of the first line
# starting `**<field>:**`, leading/trailing whitespace trimmed. Lines inside a
# fence or HTML comment are skipped. Prints nothing when the field is absent. Always returns 0.
planner_context_field() {
  local field="$1"
  shift
  PCX_FIELD="$field" awk "$_PCX_AWK_FENCE"'
    BEGIN { want = "**" ENVIRON["PCX_FIELD"] ":**" }
    { sub(/\r$/, "") }
    opaque_line($0) { next }
    index($0, want) == 1 {
      v = substr($0, length(want) + 1)
      sub(/^[ \t]+/, "", v)
      sub(/[ \t]+$/, "", v)
      print v
      exit
    }
  ' "$@"
}

# planner_context_body_field <field> [body_file]
# Convenience: extract the Planner Context block from a whole body and read
# one field from it.
planner_context_body_field() {
  local field="$1"
  shift
  planner_context_extract "$@" | planner_context_field "$field"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
  block)
    shift
    planner_context_extract "$@"
    ;;
  field)
    shift
    [ -n "${1:-}" ] || {
      echo "usage: $0 field <name> [body_file]" >&2
      exit 1
    }
    planner_context_body_field "$@"
    ;;
  *)
    echo "usage: $0 block [body_file] | field <name> [body_file]" >&2
    exit 1
    ;;
  esac
fi
