#!/usr/bin/env bash
# prescan-system-index.sh — rebuild REPOS_ROOT/.ticket-auto/system.md
# (ticket-prescan Step 5.5) without losing curated rows.
#
# The previous inline heredoc rewrote the whole file from a template on every
# scan, wiping the FE → BE Contract Map and Shared Types rows the prescan agent
# had added, although the skill promised "existing rows are preserved"
# (DET-SU-15).
#
# This script regenerates only the `Generated:` line and the `## Indexed Repos`
# table (from every <slug>/docs/INDEX.md under .ticket-auto/). The bodies of
# `## FE → BE Contract Map` and `## Shared Types` are carried over verbatim
# from the existing file when present, else taken from the empty template.
# Any other `##` section in an existing file is carried over too, after them.
# The write is atomic (tmp + mv).
#
# Usage: prescan-system-index.sh --repos-root <path>
# Output: SYSTEM_INDEX_REPOS=<n> on stdout.
# Exit: 0 written, 2 usage / missing .ticket-auto dir.
set -euo pipefail

REPOS_ROOT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
  --repos-root)
    REPOS_ROOT_ARG="${2:-}"
    shift 2 || true
    ;;
  *)
    echo "prescan-system-index: unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

if [ -z "$REPOS_ROOT_ARG" ]; then
  echo "Usage: prescan-system-index.sh --repos-root <path>" >&2
  exit 2
fi
TA_DIR="$REPOS_ROOT_ARG/.ticket-auto"
if [ ! -d "$TA_DIR" ]; then
  echo "prescan-system-index: no .ticket-auto dir under $REPOS_ROOT_ARG" >&2
  exit 2
fi

SYSTEM_MD="$TA_DIR/system.md"
CONTRACT_HEADING="## FE → BE Contract Map"
TYPES_HEADING="## Shared Types"

DEFAULT_CONTRACT='<!-- Populated by automated contract detection during multi-repo scans.
     Maps frontend API calls to backend endpoint handlers across repos. -->

| Frontend (Repo) | API Call | Backend Endpoint (Repo) | Handler |
|-----------------|----------|------------------------|---------|'

DEFAULT_TYPES='<!-- Cross-repo type definitions and DTOs. -->

| Type | Defined In (Repo) | Consumed By (Repos) |
|------|-------------------|---------------------|'

# _section_body <file> <heading> — lines after the exact heading line up to
# (not including) the next `## ` heading, with trailing blank lines dropped.
# Prints nothing and returns 1 when the heading is absent.
_section_body() {
  local file="$1" heading="$2"
  [ -f "$file" ] || return 1
  grep -qxF -- "$heading" "$file" || return 1
  awk -v h="$heading" '
    { sub(/\r$/, "") }
    $0 == h { inside = 1; next }
    inside && /^## / { exit }
    inside { buf[++n] = $0 }
    END {
      while (n > 0 && buf[n] ~ /^[[:space:]]*$/) n--
      s = 1
      while (s <= n && buf[s] ~ /^[[:space:]]*$/) s++
      for (i = s; i <= n; i++) print buf[i]
    }
  ' "$file"
}

# _other_sections <file> — every `## ` section other than the three this
# script owns, verbatim, so a hand-added section is never dropped.
_other_sections() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk -v c="$CONTRACT_HEADING" -v t="$TYPES_HEADING" '
    { sub(/\r$/, "") }
    /^## / { keep = ($0 != "## Indexed Repos" && $0 != c && $0 != t) }
    keep { print }
  ' "$file"
}

contract_body=$(_section_body "$SYSTEM_MD" "$CONTRACT_HEADING") || true
[ -n "$contract_body" ] || contract_body="$DEFAULT_CONTRACT"
types_body=$(_section_body "$SYSTEM_MD" "$TYPES_HEADING") || true
[ -n "$types_body" ] || types_body="$DEFAULT_TYPES"
others=$(_other_sections "$SYSTEM_MD")

repo_rows=""
repo_count=0
while IFS= read -r idx; do
  [ -n "$idx" ] || continue
  slug=$(basename "$(dirname "$(dirname "$idx")")")
  repo_rows+="| $slug | $idx |"$'\n'
  repo_count=$((repo_count + 1))
done < <(find "$TA_DIR" -mindepth 3 -maxdepth 3 -path '*/docs/INDEX.md' -type f 2>/dev/null | LC_ALL=C sort)

tmp=$(mktemp "$TA_DIR/.system.md.XXXXXX")
{
  echo "# Cross-Repo System Map"
  echo ""
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "## Indexed Repos"
  echo ""
  echo "| Repo | INDEX |"
  echo "|------|-------|"
  printf '%s' "$repo_rows"
  echo ""
  echo "$CONTRACT_HEADING"
  echo ""
  printf '%s\n' "$contract_body"
  echo ""
  echo "$TYPES_HEADING"
  echo ""
  printf '%s\n' "$types_body"
  if [ -n "$others" ]; then
    echo ""
    printf '%s\n' "$others"
  fi
} >"$tmp"
mv "$tmp" "$SYSTEM_MD"

echo "SYSTEM_INDEX_REPOS=$repo_count"
