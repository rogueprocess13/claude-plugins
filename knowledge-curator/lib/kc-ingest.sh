#!/usr/bin/env bash
# kc-ingest.sh — deterministic helpers for the kc-import / kc-sweep ingesters.
#
#   kc-ingest.sh title <file> [fallback]
#       Prints the document title: the first `# ` (H1) heading outside a
#       ``` / ~~~ fence; else the first `## ` heading; else <fallback>
#       (default: the file's basename without .md). kc-import used
#       `head -5 | grep "^## "`, which took an H2 — or nothing, when the H1 was
#       followed by more than four lines before the first H2 — instead of the
#       document's own title.
#
#   kc-ingest.sh new-plans [--plans-dir D] [--knowledge-dir K] [--marker F]
#                          [--since-hours N]
#       Prints the plan files (one path per line, sorted) that a sweep should
#       consider: modified after the marker file, or — when there is no marker
#       (the first sweep) — within the last N hours (default 24). Plans already
#       imported (an item in K carrying `source: plan:<slug>`) are left out.
#       kc-sweep used `find -newer <marker> 2>/dev/null`, which errors (and,
#       with the error suppressed, prints nothing) when the marker is missing,
#       so the first sweep never picked up any plan.
#       Defaults: D=~/.claude/plans, K=knowledge, F=K/.kc-sweep-marker.
#
# Exit: 0 ok, 2 usage. Read-only.
set -euo pipefail

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

cmd_title() {
  local file="${1:-}" fallback="${2:-}"
  [ -n "$file" ] || usage
  [ -n "$fallback" ] || fallback=$(basename "$file" .md)
  local t=""
  if [ -r "$file" ]; then
    t=$(awk '
      { sub(/\r$/, "") }
      /^[ \t]*(```|~~~)/ { fence = !fence; next }
      fence { next }
      /^# +[^ ]/ && h1 == "" { h1 = $0; sub(/^# +/, "", h1) }
      /^## +[^ ]/ && h2 == "" { h2 = $0; sub(/^## +/, "", h2) }
      END {
        t = (h1 != "") ? h1 : h2
        sub(/[ \t#]+$/, "", t)
        print t
      }
    ' "$file")
  fi
  printf '%s\n' "${t:-$fallback}"
}

cmd_new_plans() {
  local plans_dir="${HOME}/.claude/plans" kdir="knowledge" marker="" hours=24
  while [ $# -gt 0 ]; do
    case "$1" in
    --plans-dir) plans_dir="${2:-}" ;;
    --knowledge-dir) kdir="${2:-}" ;;
    --marker) marker="${2:-}" ;;
    --since-hours) hours="${2:-}" ;;
    *) usage ;;
    esac
    shift 2 || usage
  done
  [ -n "$marker" ] || marker="${kdir}/.kc-sweep-marker"
  [[ "$hours" =~ ^[0-9]+$ ]] || usage
  [ -d "$plans_dir" ] || return 0

  local -a age
  if [ -f "$marker" ]; then
    age=(-newer "$marker")
  else
    age=(-mmin "-$((hours * 60))")
  fi

  local f slug
  while IFS= read -r -d '' f; do
    slug=$(basename "$f" .md)
    if compgen -G "${kdir}/KC-*.md" >/dev/null &&
      grep -qxF -- "source: plan:${slug}" "${kdir}"/KC-*.md 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$f"
  done < <(find "$plans_dir" -maxdepth 1 -type f -name '*.md' "${age[@]}" -print0 | LC_ALL=C sort -z)
}

case "${1:-}" in
title)
  shift
  cmd_title "$@"
  ;;
new-plans)
  shift
  cmd_new_plans "$@"
  ;;
*) usage ;;
esac
