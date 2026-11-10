#!/usr/bin/env bash
# ai-context-find.sh — wiki-maintenance Step 2.5a: list the ai-context.md
# files written in the last N days (skill-deterministic-extraction 6a).
#
# Usage:
#   ai-context-find.sh [--root DIR] [--days N]
#
# Prints one `*/tickets/*/ai-context.md` path per line under DIR (default .),
# newer than N days (default 90). The cutoff is an absolute ISO-8601 date,
# never GNU find's relative "90 days ago" form: `find` is `bfs` on some hosts
# and bfs rejects relative timestamps outright, which once made this step
# silently return nothing on every run (2026-09-10 retro).
#
# Exit codes: 0 search ran (an empty list means no recent files), 1 the date
# or find itself failed (stderr says which — never read that as "none"),
# 2 usage.

_root="." _days=90
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || {
    sed -n '5,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
  }
  case "$1" in
  --root) _root="$2" ;;
  --days) _days="$2" ;;
  *)
    sed -n '5,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
  esac
  shift 2
done
[[ "$_days" =~ ^[0-9]+$ ]] || {
  echo "ai-context-find: --days must be a whole number" >&2
  exit 2
}

_cutoff=$(date -u -d "$_days days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"${_days}"d +%Y-%m-%d 2>/dev/null) || _cutoff=""
if [ -z "$_cutoff" ]; then
  echo "ai-context-find: could not compute the cutoff date" >&2
  exit 1
fi
_rc=0
find "$_root" -path "*/tickets/*/ai-context.md" -newermt "$_cutoff" || _rc=$?
if [ "$_rc" -ne 0 ]; then
  echo "ai-context-find: find failed (rc $_rc) — the list above is not complete" >&2
  exit 1
fi
exit 0
