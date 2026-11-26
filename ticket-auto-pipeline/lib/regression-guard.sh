#!/usr/bin/env bash
# regression-guard.sh — the deterministic half of ticket-appraise-exec
# Step 3.5, the Regression Guard (GitHub #823).
#
# The agent still judges each overlap (CONFLICT, ADJACENT or SUPERSEDES).
# This script decides two things the agent used to decide from prose:
#
#   1. Which files overlap. A prior ticket's changed files are read from its
#      ai-context.md `## What changed` list (written by ticket-document from
#      the real diff), never from tokens in a Prior Art "Key finding" line.
#   2. Which verdicts need a person. Only these hold implementation:
#        CONFLICT                                   always
#        SUPERSEDES of a prior ticket that is not a dependency
#        any verdict that is not one of the three   (read as CONFLICT)
#      ADJACENT never holds, and SUPERSEDES of a dependency never holds.
#      Those rows go to a `## Regression Notes` section for the reviewer.
#      A dependency is a prior ticket in the same epic (resolve_ticket_epic
#      gives both the same epic) or one named in this ticket's blocked_by.
#      When the relation cannot be read (no REPOS_ROOT, no manifest) the
#      prior ticket is not a dependency, so the row stays gated.
#
# CLI:
#   regression-guard.sh changed-files <PRIOR_TICKET_DIR>
#     The prior ticket's changed files, one per line. Exit 1 when it has no
#     ai-context.md with a `## What changed` list (the caller falls back to
#     reading the prior ticket's notes).
#   regression-guard.sh overlap <PLAN_FILES_FILE> <PRIOR_TICKET_DIR>
#     The plan files (one per line in PLAN_FILES_FILE) that the prior ticket
#     changed. Paths match when equal or when one ends with "/" + the other
#     (repo-relative against repo-prefixed). Exit 1 as for changed-files.
#   regression-guard.sh relation <TID> <PRIOR_TID>
#     Prints `dependency same-epic:<EPIC>`, `dependency blocked-by` or
#     `unrelated`. Exit 0.
#   regression-guard.sh write <TID> <notes.md> <rows.tsv>
#     rows.tsv: one row per overlap, tab-separated:
#       plan_file  prior_tid  source_tag  verdict  detail
#     Replaces any `## ⚠️ Regression Risk` / `## Regression Notes` section in
#     notes.md with the gated and the noted rows, then records the gated
#     section with regression-risk.sh record. Prints
#       REGRESSION_GUARD_GATED=<n>  REGRESSION_GUARD_NOTED=<n>
#       REGRESSION_GUARD_WORST=CONFLICT|SUPERSEDES|ADJACENT|clear
#       REGRESSION_RISK_RECORDED=<12 hex>|none
#     Exit 0; 1 the record failed (stop); 2 bad arguments or unreadable input.
#
# -u (nounset) intentionally omitted: repo convention (see regression-risk.sh).

_RG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _rg_norm <path> — strip backticks, surrounding space and a leading "./".
_rg_norm() {
  local p="$1"
  p="${p//\`/}"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  p="${p#./}"
  printf '%s' "$p"
}

regression_guard_changed_files() {
  local ctx="$1/ai-context.md"
  [ -f "$ctx" ] && [ -r "$ctx" ] || return 1
  local out
  out=$(awk '
    { gsub(/\r/, "") }
    /^##[ \t]/ { insec = (tolower($0) ~ /^##[ \t]+what changed[ \t]*$/); if (insec) found = 1; next }
    !insec { next }
    /^[ \t]*[-*][ \t]+/ {
      line = $0
      sub(/^[ \t]*[-*][ \t]+/, "", line)
      gsub(/\*\*/, "", line)
      if (substr(line, 1, 1) == "`") {
        line = substr(line, 2); i = index(line, "`")
        if (i > 0) line = substr(line, 1, i - 1)
      } else {
        i = index(line, ": "); if (i > 0) line = substr(line, 1, i - 1)
        sub(/:$/, "", line); sub(/[ \t].*$/, "", line)
      }
      sub(/^\.\//, "", line)
      if (line != "") print line
    }
    END { exit(found ? 0 : 1) }
  ' "$ctx") || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | awk '!seen[$0]++'
}

regression_guard_overlap() {
  local plan_file="$1" prior_dir="$2" changed p c np nc
  [ -f "$plan_file" ] || return 2
  changed=$(regression_guard_changed_files "$prior_dir") || return 1
  while IFS= read -r p || [ -n "$p" ]; do
    np=$(_rg_norm "$p")
    [ -n "$np" ] || continue
    while IFS= read -r c; do
      nc=$(_rg_norm "$c")
      [ -n "$nc" ] || continue
      if [ "$np" = "$nc" ] || [[ "$np" == */"$nc" ]] || [[ "$nc" == */"$np" ]]; then
        printf '%s\n' "$np"
        break
      fi
    done <<<"$changed"
  done <"$plan_file" | awk '!seen[$0]++'
  return 0
}

regression_guard_relation() {
  local tid="$1" prior="$2" e1="" e2=""
  if [ -z "${REPOS_ROOT:-}" ] || [ -z "$prior" ] || [ "$tid" = "$prior" ]; then
    echo "unrelated"
    return 0
  fi
  declare -f resolve_ticket_epic >/dev/null 2>&1 ||
    source "$_RG_LIB_DIR/manifest-read.sh" 2>/dev/null || {
    echo "unrelated"
    return 0
  }
  e1=$(resolve_ticket_epic "$tid" 2>/dev/null) || e1=""
  e2=$(resolve_ticket_epic "$prior" 2>/dev/null) || e2=""
  if [ -n "$e1" ] && [ "$e1" = "$e2" ]; then
    echo "dependency same-epic:$e1"
    return 0
  fi
  local bb
  bb=$(get_ticket_manifest_field "$tid" blocked_by 2>/dev/null) || bb=""
  if [ -n "$bb" ] && jq -e --arg p "$prior" 'type == "array" and index($p) != null' <<<"$bb" >/dev/null 2>&1; then
    echo "dependency blocked-by"
    return 0
  fi
  echo "unrelated"
}

# _rg_cell <text> — a markdown table cell: pipes escaped.
_rg_cell() { printf '%s' "${1//|/\\|}"; }

regression_guard_write() {
  local tid="$1" notes="$2" rows="$3"
  [[ "$tid" =~ ^[A-Z]+-[0-9]+$ ]] || {
    echo "regression-guard: invalid ticket id '$tid'" >&2
    return 2
  }
  [ -f "$notes" ] && [ -r "$notes" ] && [ -w "$notes" ] || {
    echo "regression-guard: notes.md '$notes' is not a readable, writable file" >&2
    return 2
  }
  [ -f "$rows" ] && [ -r "$rows" ] || {
    echo "regression-guard: rows file '$rows' is not readable" >&2
    return 2
  }

  local gated="" noted="" n_gated=0 n_noted=0 worst="clear"
  local file prior tag verdict detail rel row
  while IFS=$'\t' read -r file prior tag verdict detail || [ -n "$file" ]; do
    file=$(_rg_norm "$file")
    [ -n "$file" ] || continue
    verdict=$(printf '%s' "$verdict" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')
    case "$verdict" in CONFLICT | ADJACENT | SUPERSEDES) ;; *) verdict="CONFLICT" ;; esac
    rel=$(regression_guard_relation "$tid" "$prior")
    row="| \`$(_rg_cell "$file")\` | $(_rg_cell "$prior") $(_rg_cell "$tag") | $verdict | $(_rg_cell "$detail") |"
    if [ "$verdict" = "CONFLICT" ] || { [ "$verdict" = "SUPERSEDES" ] && [ "${rel%% *}" != "dependency" ]; }; then
      gated+="$row"$'\n'
      n_gated=$((n_gated + 1))
    else
      [ "${rel%% *}" = "dependency" ] && row="${row% |} (${rel#dependency }) |"
      noted+="$row"$'\n'
      n_noted=$((n_noted + 1))
    fi
    case "$worst:$verdict" in
    *:CONFLICT) worst="CONFLICT" ;;
    clear:SUPERSEDES | ADJACENT:SUPERSEDES) worst="SUPERSEDES" ;;
    clear:ADJACENT) worst="ADJACENT" ;;
    esac
  done <"$rows"

  local tmp
  tmp=$(mktemp "${notes}.XXXXXX") || return 2
  # Drop the sections this script owns, wherever they stand, then append the
  # new ones at the end.
  awk '
    function hlevel(s,   n) { sub(/^ +/, "", s); n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    {
      line = $0; sub(/\r$/, "", line)
      if (line ~ /^ ? ? ?##+[ \t]/) {
        lv = hlevel(line)
        if (tolower(line) ~ /regression (risk|notes)/) { skip = 1; skiplv = lv; next }
        if (skip && lv <= skiplv) skip = 0
      }
      if (!skip) print $0
    }
  ' "$notes" | awk '{ a[NR] = $0 } END { n = NR; while (n > 0 && a[n] == "") n--; for (i = 1; i <= n; i++) print a[i] }' >"$tmp" || {
    rm -f "$tmp"
    return 2
  }
  {
    if [ "$n_gated" -gt 0 ]; then
      printf '\n## ⚠️ Regression Risk\n\n'
      printf '| Plan file | Prior art | Verdict | Detail |\n|-----------|-----------|---------|--------|\n'
      printf '%s' "$gated"
      printf '\n→ A person acknowledges this from a terminal: `bash ~/.claude/skills/lib/regression-ack.sh %s`. An edit here does not.\n' "$tid"
    fi
    if [ "$n_noted" -gt 0 ]; then
      printf '\n## Regression Notes\n\n'
      printf 'Overlaps that need no acknowledgement (ADJACENT, or a dependency this ticket builds on). For the PR reviewer.\n\n'
      printf '| Plan file | Prior art | Verdict | Detail |\n|-----------|-----------|---------|--------|\n'
      printf '%s' "$noted"
    fi
  } >>"$tmp"
  mv "$tmp" "$notes" || {
    rm -f "$tmp"
    return 2
  }

  echo "REGRESSION_GUARD_GATED=$n_gated"
  echo "REGRESSION_GUARD_NOTED=$n_noted"
  echo "REGRESSION_GUARD_WORST=$worst"
  if [ "$n_gated" -eq 0 ]; then
    echo "REGRESSION_RISK_RECORDED=none"
    return 0
  fi
  bash "$_RG_LIB_DIR/regression-risk.sh" record "$tid" "$notes" || return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
  changed-files)
    [ -n "${2:-}" ] || {
      echo "usage: regression-guard.sh changed-files <PRIOR_TICKET_DIR>" >&2
      exit 2
    }
    regression_guard_changed_files "$2"
    exit $?
    ;;
  overlap)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || {
      echo "usage: regression-guard.sh overlap <PLAN_FILES_FILE> <PRIOR_TICKET_DIR>" >&2
      exit 2
    }
    regression_guard_overlap "$2" "$3"
    exit $?
    ;;
  relation)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || {
      echo "usage: regression-guard.sh relation <TID> <PRIOR_TID>" >&2
      exit 2
    }
    regression_guard_relation "$2" "$3"
    exit $?
    ;;
  write)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || {
      echo "usage: regression-guard.sh write <TID> <notes.md> <rows.tsv>" >&2
      exit 2
    }
    regression_guard_write "$2" "$3" "$4"
    exit $?
    ;;
  *)
    echo "usage: regression-guard.sh changed-files|overlap|relation|write ..." >&2
    exit 2
    ;;
  esac
fi
