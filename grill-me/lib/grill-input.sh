#!/usr/bin/env bash
# ── grill-input.sh ────────────────────────────────────────────────────────────
# Input sanitization for the grill-me readiness gate.
#
# Ported from ticket-planner/lib/planner-phase-prompts.sh (planner_sanitize_input).
# Deliberately duplicated rather than sourced, because grill-me must install
# standalone. Recorded as a known sharp edge (design D6 in grill-me/CLAUDE.md).
#
# Exports:
#   grill_sanitize_input  <raw-input>
#     Returns sanitized input on stdout, exits 0.
#     Returns 1 if input contains a blocked injection pattern.
#     Returns 2 if input is longer than GRILL_INPUT_MAX_LENGTH (default 16000).
#     Nothing is ever truncated (grill-me-verbatim-brief): a brief that does
#     not fit is refused, loudly, so the sealed intent cannot silently lose its
#     tail.
#
#   grill_brief_verbatim  <raw-input>
#     Returns the input with its line structure intact, for the sealed
#     `## Original Brief` section: CR, zero-width, bidi and other control
#     characters (except tab and newline) removed, trailing whitespace stripped
#     from each line, leading and trailing blank lines dropped. Run it only on
#     input grill_sanitize_input has accepted.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── grill_sanitize_input ──────────────────────────────────────────────────────
# Usage: grill_sanitize_input <raw_input>
# Returns: sanitized input on stdout (exit 0), or blocked message on stderr (exit 1).
# ──────────────────────────────────────────────────────────────────────────────
grill_sanitize_input() {
  local raw="$1"

  if [ -z "$raw" ]; then
    echo ""
    return 0
  fi

  # Check input length limit. Refuse rather than truncate: a truncated brief
  # loses its tail (test-data tables, acceptance sections) with nothing in the
  # sealed intent to say so.
  local max_length="${GRILL_INPUT_MAX_LENGTH:-16000}"
  if [ "${#raw}" -gt "$max_length" ]; then
    echo "grill-input: input length ${#raw} exceeds GRILL_INPUT_MAX_LENGTH=${max_length} — refusing (nothing is truncated). Shorten the brief or raise GRILL_INPUT_MAX_LENGTH." >&2
    return 2
  fi

  # Normalize whitespace — collapse multiple spaces, trim leading/trailing
  local normalized
  normalized=$(echo "$raw" | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # Strip zero-width characters (ZWSP, ZWNJ, ZWJ, BOM)
  normalized=$(echo "$normalized" | sed '
    s/\xE2\x80\x8B//g
    s/\xE2\x80\x8C//g
    s/\xE2\x80\x8D//g
    s/\xEF\xBB\xBF//g
  ')

  # Strip RTL override and other bidi control characters
  normalized=$(echo "$normalized" | sed '
    s/\xE2\x80\x8E//g
    s/\xE2\x80\x8F//g
    s/\xE2\x80\xAA//g
    s/\xE2\x80\xAB//g
    s/\xE2\x80\xAC//g
    s/\xE2\x80\xAD//g
    s/\xE2\x80\xAE//g
  ')

  # Defense-in-depth: reject known injection patterns
  local lower
  lower=$(echo "$normalized" | tr '[:upper:]' '[:lower:]')

  local blocked_patterns=(
    "ignore previous instructions"
    "ignore all previous"
    "you are now"
    "pretend you are"
    "new instructions"
    "override system prompt"
    "system prompt:"
    "<system>" # attempt to inject XML system tags
    "</system>"
    "disregard previous"
    "disregard all"
  )

  for pattern in "${blocked_patterns[@]}"; do
    if echo "$lower" | grep -qF "$pattern" 2>/dev/null; then
      echo "grill-input: blocked input containing injection pattern: '${pattern}'" >&2
      return 1
    fi
  done

  echo "$normalized"
  return 0
}

# ── grill_brief_verbatim ──────────────────────────────────────────────────────
# Usage: grill_brief_verbatim <raw_input>
# Returns: the brief with newlines preserved (see header), exit 0.
# ──────────────────────────────────────────────────────────────────────────────
grill_brief_verbatim() {
  local raw="$1"
  printf '%s\n' "$raw" |
    tr -d '\000-\010\013\014\015\016-\037\177' |
    sed '
      s/\xE2\x80\x8B//g
      s/\xE2\x80\x8C//g
      s/\xE2\x80\x8D//g
      s/\xEF\xBB\xBF//g
      s/\xE2\x80\x8E//g
      s/\xE2\x80\x8F//g
      s/\xE2\x80\xAA//g
      s/\xE2\x80\xAB//g
      s/\xE2\x80\xAC//g
      s/\xE2\x80\xAD//g
      s/\xE2\x80\xAE//g
      s/[[:space:]]*$//
    ' |
    awk '
      NF || started { started = 1; lines[++n] = $0; if (NF) last = n }
      END { for (i = 1; i <= last; i++) print lines[i] }
    '
}

# If executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 1 ]; then
    echo "Usage: grill-input.sh <raw-input>" >&2
    exit 1
  fi
  grill_sanitize_input "$1"
fi
