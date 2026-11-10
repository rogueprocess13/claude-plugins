#!/usr/bin/env bash
# pr-review-comment.sh — the ticket-pr-review findings comment, written by
# ticket-pr-review Step 6 and read back by ticket-pr-iterate Step 2c
# (skill-deterministic-extraction 2). One file owns both directions, so the
# format the reader expects is the format the writer produces.
#
# Usage:
#   pr-review-comment.sh render --ticket ID --url URL --rows FILE
#                               [--impact FILE] [--next-steps FILE]
#   pr-review-comment.sh parse [FILE]          (stdin without FILE)
#
# render inputs (tab-separated, one item per line, blank lines ignored):
#   --rows        N<TAB>requirement<TAB>status    status: ✅ | ⚠️ | ❌
#   --impact      flow<TAB>risk                   GitNexus detect_changes rows;
#                                                 omit (or empty) when none
#   --next-steps  one suggested next step per line (gaps only)
# The verdict is derived from the rows: every row ✅ → "✅ All requirements
# addressed", anything else → "⚠️ Gaps found". A `|` in a cell is written as
# `\|` so the table stays well-formed. Prints the comment body on stdout.
#
# parse reads one or more comment bodies and uses the LAST
# "## Ticket alignment review" comment (a re-reviewed PR carries several).
# Prints, one record per line:
#   TICKET=<id>
#   URL=<ticket url>
#   VERDICT=pass|gaps
#   ROW<TAB>N<TAB>status<TAB>requirement     status as ✅ | ⚠️ | ❌
#   IMPACT<TAB>flow<TAB>risk
#   NEXT_STEP<TAB>text
#   GAPS=<number of ⚠️/❌ rows>
# parse(render(x)) recovers every field render wrote.
#
# Exit codes: 0 ok; 1 parse found no review comment or no verdict line;
# 2 usage or bad input (render: unreadable file, bad status, no rows).
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_prc_usage() {
  echo "Usage: pr-review-comment.sh render --ticket ID --url URL --rows FILE [--impact FILE] [--next-steps FILE]" >&2
  echo "       pr-review-comment.sh parse [FILE]" >&2
  exit 2
}

# _prc_cell <text> — one table cell: newlines to spaces, `|` escaped.
_prc_cell() {
  local s="${1//$'\r'/}"
  s="${s//$'\n'/ }"
  printf '%s' "${s//|/\\|}"
}

_prc_status() {
  case "$1" in
  ✅) printf '✅' ;;
  ⚠️ | ⚠) printf '⚠️' ;;
  ❌) printf '❌' ;;
  *) return 1 ;;
  esac
}

prc_render() {
  local ticket="" url="" rows="" impact="" steps=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || _prc_usage
    case "$1" in
    --ticket) ticket="$2" ;;
    --url) url="$2" ;;
    --rows) rows="$2" ;;
    --impact) impact="$2" ;;
    --next-steps) steps="$2" ;;
    *) _prc_usage ;;
    esac
    shift 2
  done
  [ -n "$ticket" ] && [ -n "$url" ] && [ -n "$rows" ] || _prc_usage
  local f
  for f in "$rows" "$impact" "$steps"; do
    [ -z "$f" ] || [ -r "$f" ] || {
      echo "pr-review-comment: cannot read $f" >&2
      exit 2
    }
  done

  local table="" n req st all_ok=true count=0
  while IFS=$'\t' read -r n req st || [ -n "$n" ]; do
    [ -n "${n//[[:space:]]/}" ] || continue
    st=$(_prc_status "${st//[[:space:]]/}") || {
      echo "pr-review-comment: row $n has status '$st' (want ✅, ⚠️ or ❌)" >&2
      exit 2
    }
    [ "$st" = ✅ ] || all_ok=false
    table+="| $(_prc_cell "$n") | $(_prc_cell "$req") | $st |"$'\n'
    count=$((count + 1))
  done <"$rows"
  [ "$count" -gt 0 ] || {
    echo "pr-review-comment: no requirement rows in $rows" >&2
    exit 2
  }

  printf '## Ticket alignment review — %s\n\n**Ticket:** %s\n\n' "$ticket" "$url"
  printf '### Requirements coverage\n\n| # | Requirement | Status |\n|---|---|---|\n%s\n' "$table"

  if [ -n "$impact" ] && grep -q '[^[:space:]]' "$impact"; then
    local flow risk high=false itable=""
    while IFS=$'\t' read -r flow risk || [ -n "$flow" ]; do
      [ -n "${flow//[[:space:]]/}" ] || continue
      risk="${risk//[[:space:]]/}"
      case "${risk^^}" in HIGH | CRITICAL) high=true ;; esac
      itable+="| $(_prc_cell "$flow") | $(_prc_cell "$risk") |"$'\n'
    done <"$impact"
    printf '### Structural impact (GitNexus)\n\n| Affected Flow | Risk |\n|---------------|------|\n%s\n' "$itable"
    if [ "$high" = true ]; then
      printf '⚠️  High structural impact detected — review the affected execution flows above carefully.\n\n'
    fi
  fi

  if [ "$all_ok" = true ]; then
    printf '**Verdict:** ✅ All requirements addressed\n'
  else
    printf '**Verdict:** ⚠️ Gaps found — see partial/missing rows above\n'
    if [ -n "$steps" ] && grep -q '[^[:space:]]' "$steps"; then
      printf '\n### Suggested next steps\n'
      local line
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        line="${line#- }"
        [ -n "${line//[[:space:]]/}" ] || continue
        printf -- '- %s\n' "$line"
      done <"$steps"
    fi
  fi
}

prc_parse() {
  local src="${1:--}"
  if [ "$src" != "-" ] && [ ! -r "$src" ]; then
    echo "pr-review-comment: cannot read $src" >&2
    exit 2
  fi
  local out rc=0
  out=$(cat -- "$src" | tr -d '\r' | awk '
    # Keep only the last review comment.
    /^## Ticket alignment review — / { n = 0; seen = 1 }
    seen { buf[++n] = $0 }
    END {
      if (!seen) exit 1
      section = ""; gaps = 0; verdict = ""
      for (i = 1; i <= n; i++) {
        line = buf[i]
        if (i == 1) { t = line; sub(/^## Ticket alignment review — /, "", t); print "TICKET=" t; continue }
        if (line ~ /^\*\*Ticket:\*\* /) { u = line; sub(/^\*\*Ticket:\*\* /, "", u); print "URL=" u; continue }
        if (line ~ /^### Requirements coverage/) { section = "req"; continue }
        if (line ~ /^### Structural impact/) { section = "impact"; continue }
        if (line ~ /^### Suggested next steps/) { section = "steps"; continue }
        if (line ~ /^\*\*Verdict:\*\* ✅/) { verdict = "pass"; section = ""; continue }
        if (line ~ /^\*\*Verdict:\*\* ⚠/) { verdict = "gaps"; section = ""; continue }
        if (line ~ /^## /) break
        if (section == "steps" && line ~ /^- /) { s = line; sub(/^- /, "", s); print "NEXT_STEP\t" s; continue }
        if (line !~ /^\|/ || line ~ /^\|[-| ]*\|$/) continue
        if (line ~ /^\| # \|/ || line ~ /^\| Affected Flow \|/) continue
        # Split on unescaped pipes; \| inside a cell is restored.
        l = line; gsub(/\\\|/, "\001", l)
        k = split(l, c, "|")
        for (j = 1; j <= k; j++) { gsub(/^ +| +$/, "", c[j]); gsub("\001", "|", c[j]) }
        if (section == "req" && k >= 5) {
          st = c[k - 1]
          if (st ~ /^⚠/) st = "⚠️"
          if (st != "✅") gaps++
          req = c[3]; for (j = 4; j <= k - 2; j++) req = req "|" c[j]
          print "ROW\t" c[2] "\t" st "\t" req
        } else if (section == "impact" && k >= 4) {
          print "IMPACT\t" c[2] "\t" c[3]
        }
      }
      if (verdict == "") exit 1
      print "VERDICT=" verdict
      print "GAPS=" gaps
    }') || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    echo "pr-review-comment: no '## Ticket alignment review' comment with a Verdict line" >&2
    exit 1
  fi
}

case "${1:-}" in
render)
  shift
  prc_render "$@"
  ;;
parse)
  shift
  [ $# -le 1 ] || _prc_usage
  prc_parse "$@"
  ;;
*) _prc_usage ;;
esac
