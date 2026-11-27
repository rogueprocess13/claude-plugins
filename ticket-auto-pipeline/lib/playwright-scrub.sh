#!/usr/bin/env bash
# playwright-scrub.sh — redact typed passwords from Playwright MCP snapshots
# (GitHub #819).
#
# Playwright MCP writes every browser_snapshot, and the snapshot after each
# action, as a YAML accessibility tree under `.playwright-mcp/` in the
# session's working directory (the tickets root). A filled password input is
# recorded with its value in clear text:
#     - textbox "Password" [ref=f6e26]: <the typed password>
# ticket-verify signs in through forms many times per ticket, so these files
# pile up. This script rewrites them in place:
#   1. the value of any `textbox "<name>"` whose name contains "password" or
#      "passcode" (any case) becomes `[REDACTED]`;
#   2. every literal occurrence of the configured UAT test password
#      (UAT_TEST_PASSWORD env, else the UAT_TEST_PASSWORD field of
#      ./CLAUDE.md), anywhere in any file, becomes `[REDACTED]`. Values
#      shorter than 4 characters are not matched literally (too many false
#      hits); rule 1 still covers them in a password field.
#
# Usage:
#   playwright-scrub.sh [DIR...]
# DIR defaults to ./.playwright-mcp, plus $REPOS_ROOT/.playwright-mcp when
# REPOS_ROOT is set and differs. A missing DIR is skipped. Prints one line:
#   PLAYWRIGHT_SCRUB files=<scanned> redacted=<files rewritten>
# Never prints a secret. Best-effort: exit 0 unless the usage is wrong (2).

set -u

_ps_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
-h | --help)
  sed -n '2,26p' "$0"
  exit 0
  ;;
-*)
  echo "usage: playwright-scrub.sh [DIR...]" >&2
  exit 2
  ;;
esac

_ps_dirs=()
if [ $# -gt 0 ]; then
  _ps_dirs=("$@")
else
  _ps_dirs=("./.playwright-mcp")
  if [ -n "${REPOS_ROOT:-}" ] && [ -d "$REPOS_ROOT/.playwright-mcp" ]; then
    _a=$(cd "$REPOS_ROOT/.playwright-mcp" && pwd -P)
    _b=$(cd ./.playwright-mcp 2>/dev/null && pwd -P || true)
    [ "$_a" = "$_b" ] || _ps_dirs+=("$REPOS_ROOT/.playwright-mcp")
  fi
fi

_ps_secret="${UAT_TEST_PASSWORD:-}"
if [ -z "$_ps_secret" ] && [ -f ./CLAUDE.md ] && [ -f "$_ps_lib/claude-md-field.sh" ]; then
  # shellcheck source=/dev/null
  source "$_ps_lib/claude-md-field.sh" 2>/dev/null || true
  if declare -f claude_md_field >/dev/null 2>&1; then
    _ps_secret=$(claude_md_field ./CLAUDE.md UAT_TEST_PASSWORD 2>/dev/null || true)
  fi
fi
[ "${#_ps_secret}" -ge 4 ] || _ps_secret=""

# The secret reaches awk through the environment, never argv.
_ps_awk='
BEGIN { sec = ENVIRON["_PS_SECRET"]; red = "[REDACTED]" }
{
  line = $0
  if (sec != "") {
    out = ""
    while ((i = index(line, sec)) > 0) {
      out = out substr(line, 1, i - 1) red
      line = substr(line, i + length(sec))
    }
    line = out line
  }
  low = tolower(line)
  if (match(low, /textbox "[^"]*pass(word|code)[^"]*"[^:]*: /)) {
    keep = substr(line, 1, RSTART + RLENGTH - 1)
    rest = substr(line, RSTART + RLENGTH)
    if (rest != "" && rest != red) line = keep red
  }
  print line
}'

_ps_files=0
_ps_redacted=0
for _d in "${_ps_dirs[@]}"; do
  # A snapshot dir that is a symlink is refused: it could point anywhere.
  _d="${_d%/}"
  [ -n "$_d" ] && [ -d "$_d" ] && [ ! -L "$_d" ] || continue
  while IFS= read -r -d '' _f; do
    # Only a regular file this user owns, never through a symlink, is
    # rewritten (a planted link must not get its target overwritten).
    [ -f "$_f" ] && [ ! -L "$_f" ] && [ -O "$_f" ] || continue
    _ps_files=$((_ps_files + 1))
    # Unpredictable temp name in the file's own dir: same filesystem, so the
    # mv below is an atomic rename.
    _tmp=$(mktemp "$(dirname "$_f")/.scrub.XXXXXX" 2>/dev/null) || continue
    if ! _PS_SECRET="$_ps_secret" awk "$_ps_awk" "$_f" >"$_tmp" 2>/dev/null; then
      rm -f "$_tmp"
      continue
    fi
    if cmp -s "$_f" "$_tmp"; then
      rm -f "$_tmp"
      continue
    fi
    chmod --reference="$_f" "$_tmp" 2>/dev/null || chmod 600 "$_tmp" 2>/dev/null || true
    if mv -f "$_tmp" "$_f"; then
      _ps_redacted=$((_ps_redacted + 1))
    else
      rm -f "$_tmp"
    fi
  done < <(find "$_d" -type f ! -name '*.scrub.*' ! -name '.scrub.*' -print0 2>/dev/null)
done

echo "PLAYWRIGHT_SCRUB files=$_ps_files redacted=$_ps_redacted"
exit 0
