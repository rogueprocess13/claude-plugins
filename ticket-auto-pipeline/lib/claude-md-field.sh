#!/usr/bin/env bash
# claude-md-field.sh — the one CLAUDE.md field reader.
#
# Every place that reads a project-context field (REPOS_ROOT, LOCAL_URL,
# UAT_URL, ...) out of a project CLAUDE.md goes through claude_md_field, so
# /ticket-env-check (both its report and validate modes), resolve_uat_url and
# the runtime preamble cannot disagree about what a project declares. They
# used to carry their own copies of the regex, and the copies drifted: validate
# mode anchored on a bare `^REPOS_ROOT`, so a backticked declaration — the
# form these CLAUDE.md files document their fields in — read as missing there
# while every other reader found it.
#
# Grammar (one declaration per line, anchored at line start):
#   KEY = value        KEY: value
#   `KEY` = value      `KEY`: `value`
# The key and the value may each be wrapped in backticks. The value runs to the
# next backtick or end of line, trailing whitespace trimmed — values may
# contain spaces (BE_TEST_CMD is a command line). The first match wins.
#
# Function definitions only — safe to source.

# claude_md_field <CLAUDE_MD_PATH> <KEY>
# Echoes the value and returns 0; returns 1 (no output) when the file is
# missing or declares no non-empty value for KEY.
claude_md_field() {
  local claude_md="$1" key="$2" val=""
  [ -n "$key" ] && [ -f "$claude_md" ] || return 1
  val=$(grep -oP '^`?'"$key"'`?\s*[=:]\s*`?\K[^`]+' "$claude_md" 2>/dev/null |
    head -1 | sed 's/[[:space:]]*$//' || true)
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
}
