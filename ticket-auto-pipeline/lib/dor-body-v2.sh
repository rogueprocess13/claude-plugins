#!/usr/bin/env bash
# dor-body-v2.sh — the ticket-body-v2 readers of the Definition-of-Ready check
# (GitHub #773). Sourced by dor-check.sh; check_ticket_ready calls
# _dor_body_v2_checks.
#
# The planner's Crosscheck enforces these rules on a spec before a ticket
# exists (ticket-planner/lib/planner-crosscheck-body.sh). This file applies
# the same rules to a ticket body, so a ticket written or edited by hand is
# judged too. The rules and code names are the same on purpose; the readers
# are a port, because this plugin does not depend on ticket-planner.
#
# A body carries the contract when it has a `## Verify Mode` heading, a
# `## Errors and Edge Cases` heading, or at least one acceptance criterion
# that starts with `[unit]` or `[live]`. The planner's `ticket-body-v2`
# marker is a line of the initiative's state log, not of the body, and the
# readiness check reads the body alone, so the body's own content decides
# (the same way the test-data Source contract is detected). A body with none
# of the three is a legacy body: every code below is `inapplicable` on it.
#
# Codes, all advisory unless their switch is `true`:
#
#   VERIFY_MODE_INVALID   DOR_STRICT_VERIFY_MODE   no `## Verify Mode` section,
#                                                  or its first line is not
#                                                  `**Verify mode:** <shape>`
#   EDGE_CASES_MISSING    DOR_STRICT_EDGE_CASES    a feature or improvement, or
#                                                  an api-only / live-backend
#                                                  ticket, has no non-empty
#                                                  `## Errors and Edge Cases`
#   AC_UNTAGGED           DOR_STRICT_AC_SHAPE      a criterion has no leading
#                                                  [unit] / [live] tag
#   AC_COUNT_HIGH         DOR_STRICT_AC_SHAPE      more than DOR_V2_AC_SOFT_CAP
#                                                  criteria
#   AC_POST_MERGE_STATE   DOR_STRICT_AC_SHAPE      a criterion refers to a state
#                                                  after merge or a base branch
#   SCOPE_TC_MISMATCH     DOR_STRICT_SCOPE_FILES   `## Scope` and
#                                                  `## Technical Context` name
#                                                  different files
#
# Sourceable library — no set -euo pipefail. awk is used without regex
# intervals (mawk).

DOR_V2_VERIFY_MODE_SHAPES="browser api-only diff-only build-only live-backend"
DOR_V2_AC_SOFT_CAP=20
DOR_V2_FILE_EXTS="js jsx mjs cjs ts tsx json css scss less html htm md yml yaml java kt kts py rb go rs sh bash sql xml toml ini properties gradle vue svelte php cs c h cpp hpp txt env lock conf cfg tf proto graphql"
DOR_V2_NOT_FILES="node.js next.js vue.js nuxt.js express.js react.js three.js d3.js"
_DOR_V2_POST_MERGE_RE='(after|once|when)( it| this| the (pr|pull request|branch|change|ticket))?( is| has been| gets)? merged|post-merge|after (the )?merge\b|\b(on|in|into|to|against) (the )?(`(develop|main|master)`|(develop|main|master) branch)'

# _dor_v2_section <body> <heading-lower-case> — one `## ` section up to the
# next `## ` heading. A heading inside a fenced block is not a boundary.
_dor_v2_section() {
  printf '%s\n' "$1" | tr -d '\r' | DOR_V2_WANT="$2" awk '
    /^(```|~~~)/ { fence = !fence }
    !fence && /^## / {
      h = tolower($0); sub(/^## +/, "", h); sub(/[[:space:]]+$/, "", h)
      on = (h == ENVIRON["DOR_V2_WANT"]); next
    }
    on { print }
  '
}

# The same section with fenced blocks blanked.
_dor_v2_section_prose() {
  _dor_v2_section "$1" "$2" | awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; print ""; next }
    fence { print ""; next }
    { print }
  '
}

# _dor_v2_has_heading <body> <heading-lower-case> — rc 0 when the body has
# that `## ` heading outside a fence.
_dor_v2_has_heading() {
  printf '%s\n' "$1" | tr -d '\r' | DOR_V2_WANT="$2" awk '
    /^(```|~~~)/ { fence = !fence }
    !fence && /^## / {
      h = tolower($0); sub(/^## +/, "", h); sub(/[[:space:]]+$/, "", h)
      if (h == ENVIRON["DOR_V2_WANT"]) { found = 1; exit }
    }
    END { exit !found }
  '
}

# _dor_v2_ac_items <body> — criteria, markers stripped, letter case kept.
_dor_v2_ac_items() {
  _dor_v2_section_prose "$1" "acceptance criteria" |
    { grep -E '^[[:space:]]*(-[[:space:]]*\[[ xX]\]|-|\*|[0-9]+[.)])[[:space:]]+[^[:space:]]' || true; } |
    sed -E 's/^[[:space:]]*(-[[:space:]]*\[[ xX]\]|-|\*|[0-9]+[.)])[[:space:]]*//; s/[[:space:]]+$//' |
    awk '!seen[$0]++'
}

# _dor_v2_verify_mode <body> — prints the shape. rc 1 no `## Verify Mode`
# section, rc 2 its first line is not `**Verify mode:** <shape>`.
_dor_v2_verify_mode() {
  local body="$1" line shape s
  _dor_v2_has_heading "$body" "verify mode" || return 1
  line=$(_dor_v2_section_prose "$body" "verify mode" | awk 'NF { print; exit }')
  case "$line" in
  '**Verify mode:** '*) shape="${line#'**Verify mode:** '}" ;;
  *) return 2 ;;
  esac
  shape="${shape%%[[:space:]]*}"
  for s in $DOR_V2_VERIFY_MODE_SHAPES; do
    if [ "$shape" = "$s" ]; then
      echo "$s"
      return 0
    fi
  done
  return 2
}

# _dor_v2_carries <body> — rc 0 when the body carries the contract.
_dor_v2_carries() {
  local body="$1"
  _dor_v2_has_heading "$body" "verify mode" && return 0
  _dor_v2_has_heading "$body" "errors and edge cases" && return 0
  _dor_v2_ac_items "$body" | grep -qE '^\[(unit|live)\] '
}

# _dor_v2_files <body> <heading-lower-case> — "<file>\t<ro|rw>" per backticked
# file name in that section, first mention first, each file once. `ro` when
# "(read-only)" follows the name.
_dor_v2_files() {
  _dor_v2_section_prose "$1" "$2" |
    DOR_V2_EXTS="$DOR_V2_FILE_EXTS" DOR_V2_NOT="$DOR_V2_NOT_FILES" awk '
    BEGIN {
      n = split(ENVIRON["DOR_V2_EXTS"], e, " "); for (i = 1; i <= n; i++) ext[e[i]] = 1
      n = split(ENVIRON["DOR_V2_NOT"], d, " "); for (i = 1; i <= n; i++) notfile[d[i]] = 1
    }
    function is_file(t,   base, x, k, parts) {
      if (t == "" || t ~ /[ *{<>]/ || index(t, "://")) return 0
      k = split(t, parts, "/"); base = parts[k]
      if (base == "") return 0
      if (tolower(base) in notfile) return 0
      if (base == "Makefile" || base == "Dockerfile") return 1
      if (base !~ /[A-Za-z0-9_-]\.[A-Za-z0-9]+$/) return 0
      x = base; sub(/^.*\./, "", x); x = tolower(x)
      if (x in ext) return 1
      return (k > 1 && x ~ /[a-z]/)
    }
    {
      s = $0
      while ((i = index(s, "`")) > 0) {
        s = substr(s, i + 1)
        j = index(s, "`")
        if (j == 0) break
        t = substr(s, 1, j - 1)
        s = substr(s, j + 1)
        sub(/:[0-9]+-[0-9]+$/, "", t); sub(/:[0-9]+$/, "", t)
        sub(/^\.\//, "", t)
        if (!is_file(t)) continue
        ro = (tolower(s) ~ /^[[:space:]]*\(read-only\)/) ? "ro" : "rw"
        if (!(t in seen)) { seen[t] = 1; order[++m] = t; mode[t] = ro }
        else if (ro == "ro") mode[t] = "ro"
      }
    }
    END { for (i = 1; i <= m; i++) printf "%s\t%s\n", order[i], mode[order[i]] }
  '
}

# Two names are one file when they are equal or one is the other's path tail.
_dor_v2_file_match() {
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 0
  case "$a" in */"$b") return 0 ;; esac
  case "$b" in */"$a") return 0 ;; esac
  return 1
}

# "a, b" from newline-separated names, at most 6 then "and N more".
_dor_v2_list() {
  awk 'NF { n++; if (n <= 6) out = out (n > 1 ? ", " : "") $0 }
       END { if (n > 6) out = out " and " (n - 6) " more"; print out }'
}

# _dor_v2_scope_detail <body> — the Scope <-> Technical Context difference,
# or nothing when the two sections agree.
_dor_v2_scope_detail() {
  local body="$1" f mode g hit i missing="" extra="" out=""
  local -a tc=() sc=() sc_mode=()
  while IFS=$'\t' read -r f mode; do
    [ -n "$f" ] && tc+=("$f")
  done < <(_dor_v2_files "$body" "technical context")
  while IFS=$'\t' read -r f mode; do
    [ -n "$f" ] || continue
    sc+=("$f")
    sc_mode+=("$mode")
  done < <(_dor_v2_files "$body" "scope")

  for f in "${tc[@]}"; do
    hit=0
    for g in "${sc[@]}"; do
      if _dor_v2_file_match "$f" "$g"; then
        hit=1
        break
      fi
    done
    [ "$hit" -eq 1 ] || missing+="${f}"$'\n'
  done
  for i in "${!sc[@]}"; do
    [ "${sc_mode[$i]}" = "ro" ] && continue
    hit=0
    for g in "${tc[@]}"; do
      if _dor_v2_file_match "${sc[$i]}" "$g"; then
        hit=1
        break
      fi
    done
    [ "$hit" -eq 1 ] || extra+="${sc[$i]}"$'\n'
  done

  [ -n "$missing" ] && out="named in Technical Context but not in the Scope table: $(_dor_v2_list <<<"$missing")"
  if [ -n "$extra" ]; then
    [ -n "$out" ] && out+="; "
    out+="in the Scope table but neither named in Technical Context nor marked (read-only): $(_dor_v2_list <<<"$extra")"
  fi
  printf '%s' "$out"
}

# _dor_v2_fire <code> <class> <detail> — records a failing code and files it
# under the caller's `missing` (hard) or `advisory` array.
_dor_v2_fire() {
  _dor_record "$1" "true" "$2" "$3"
  if [ "$2" = "hard" ]; then
    missing+=("$1")
  else
    advisory+=("$1")
  fi
}

# _dor_body_v2_checks <body> <type> — called by check_ticket_ready, whose
# `missing` and `advisory` arrays it appends to (bash dynamic scope).
_dor_body_v2_checks() {
  local body="$1" type="$2" code
  if ! _dor_v2_carries "$body"; then
    for code in VERIFY_MODE_INVALID EDGE_CASES_MISSING AC_UNTAGGED AC_COUNT_HIGH AC_POST_MERGE_STATE SCOPE_TC_MISMATCH; do
      _dor_record "$code" "null" "inapplicable" "body does not carry ticket-body-v2"
    done
    return 0
  fi

  local c_mode="advisory" c_edge="advisory" c_ac="advisory" c_scope="advisory"
  [ "${DOR_STRICT_VERIFY_MODE:-false}" = "true" ] && c_mode="hard"
  [ "${DOR_STRICT_EDGE_CASES:-false}" = "true" ] && c_edge="hard"
  [ "${DOR_STRICT_AC_SHAPE:-false}" = "true" ] && c_ac="hard"
  [ "${DOR_STRICT_SCOPE_FILES:-false}" = "true" ] && c_scope="hard"

  local shape rc=0
  shape=$(_dor_v2_verify_mode "$body") || rc=$?
  case "$rc" in
  0) _dor_record "VERIFY_MODE_INVALID" "false" "$c_mode" "Verify mode: $shape" ;;
  1) _dor_v2_fire "VERIFY_MODE_INVALID" "$c_mode" "no Verify Mode section" ;;
  *) _dor_v2_fire "VERIFY_MODE_INVALID" "$c_mode" "Verify Mode does not start with **Verify mode:** <shape> (one of: ${DOR_V2_VERIFY_MODE_SHAPES// /, })" ;;
  esac

  local need=""
  case "$type" in feature | improvement) need="type=$type" ;; esac
  case "$shape" in api-only | live-backend) need="${need:-verify mode $shape}" ;; esac
  if [ -z "$need" ]; then
    _dor_record "EDGE_CASES_MISSING" "null" "inapplicable" "type=${type:-unknown}, verify mode ${shape:-unknown}"
  elif _dor_v2_section "$body" "errors and edge cases" | grep -q '[^[:space:]]'; then
    _dor_record "EDGE_CASES_MISSING" "false" "$c_edge" "Errors and Edge Cases present"
  else
    _dor_v2_fire "EDGE_CASES_MISSING" "$c_edge" "no Errors and Edge Cases section ($need)"
  fi

  local items total untagged hit
  items=$(_dor_v2_ac_items "$body")
  total=$(grep -c . <<<"$items" || true)
  untagged=$(grep -cvE '^\[(unit|live)\] ' <<<"$items" || true)
  [ -n "$items" ] || untagged=0
  if [ "${untagged:-0}" -gt 0 ]; then
    _dor_v2_fire "AC_UNTAGGED" "$c_ac" "${untagged} of ${total} acceptance criteria have no [unit] or [live] tag"
  else
    _dor_record "AC_UNTAGGED" "false" "$c_ac" "every acceptance criterion is tagged"
  fi
  if [ "${total:-0}" -gt "$DOR_V2_AC_SOFT_CAP" ]; then
    _dor_v2_fire "AC_COUNT_HIGH" "$c_ac" "${total} acceptance criteria (soft cap ${DOR_V2_AC_SOFT_CAP})"
  else
    _dor_record "AC_COUNT_HIGH" "false" "$c_ac" "${total} acceptance criteria (soft cap ${DOR_V2_AC_SOFT_CAP})"
  fi
  hit=$(grep -iE -m1 -- "$_DOR_V2_POST_MERGE_RE" <<<"$items" || true)
  if [ -n "$hit" ]; then
    _dor_v2_fire "AC_POST_MERGE_STATE" "$c_ac" "a criterion refers to a state after merge or to a base branch: ${hit:0:160}"
  else
    _dor_record "AC_POST_MERGE_STATE" "false" "$c_ac" "no criterion refers to a state after merge"
  fi

  local detail
  if ! _dor_v2_has_heading "$body" "technical context"; then
    _dor_record "SCOPE_TC_MISMATCH" "null" "inapplicable" "no Technical Context section"
  else
    detail=$(_dor_v2_scope_detail "$body")
    if [ -n "$detail" ]; then
      _dor_v2_fire "SCOPE_TC_MISMATCH" "$c_scope" "$detail"
    else
      _dor_record "SCOPE_TC_MISMATCH" "false" "$c_scope" "Scope and Technical Context name the same files"
    fi
  fi
  return 0
}
