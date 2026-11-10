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
#   kc-ingest.sh audit [--changes-dir C] [--knowledge-dir K]
#       Prints one tab-separated line per openspec change in C (archive/
#       skipped), in glob order:  name status done total existing title
#       done/total count `- [x]` / `- [` lines in tasks.md; status is `done`
#       when total > 0 and every task is checked, else `active`; existing is
#       the first item file in K whose source line is `openspec:<name>`
#       (whole value, quotes allowed; empty: create one); title is `title <C>/<name>/proposal.md <name>`.
#       Defaults: C=openspec/changes, K=knowledge. (kc-import Step 2)
#
# Exit: 0 ok, 2 usage. Read-only.
set -euo pipefail

usage() {
  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//' >&2
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

cmd_audit() {
  local cdir="openspec/changes" kdir="knowledge"
  while [ $# -gt 0 ]; do
    case "$1" in
    --changes-dir) cdir="${2:-}" ;;
    --knowledge-dir) kdir="${2:-}" ;;
    *) usage ;;
    esac
    shift 2 || usage
  done
  local d name total done status existing title
  for d in "$cdir"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    [ "$name" = "archive" ] && continue
    # grep -c prints 0 itself on no match; `|| true` keeps set -e quiet.
    total=$(grep -c '^\- \[' "${d}tasks.md" 2>/dev/null || true)
    done=$(grep -c '^\- \[x\]' "${d}tasks.md" 2>/dev/null || true)
    total=${total:-0} done=${done:-0}
    if [ "$done" -eq "$total" ] && [ "$total" -gt 0 ]; then status=done; else status=active; fi
    existing=""
    if compgen -G "${kdir}/KC-*.md" >/dev/null; then
      existing=$(grep -lE -- "^source:[[:space:]]*\"?openspec:$(sed 's/[][\.*^$+?(){}|/]/\\&/g' <<<"$name")\"?[[:space:]]*$" \
        "${kdir}"/KC-*.md 2>/dev/null | head -1) || true
    fi
    title=$(cmd_title "${d}proposal.md" "$name")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$status" "$done" "$total" "$existing" "$title"
  done
}

case "${1:-}" in
audit)
  shift
  cmd_audit "$@"
  ;;
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
