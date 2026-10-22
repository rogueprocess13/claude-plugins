#!/usr/bin/env bash
# planner-specify-decisions.sh — Specify's open business decisions
# (planner-specify-waiting-on-human).
#
# When no source gives an outcome an actor and a need, the Specify prompt has
# the agent write, under `## Business Outcomes` → `### O<n>`:
#
#   **Outcome:** NEEDS_HUMAN_DECISION — <question>
#
# and then finish the phase as usual. This file is the bash that notices. It
# scans proposal.md for those markers, gates the dispatch of Review on them,
# and renders the line that replaces a marker once a person answers or defers
# it. "Open" is a property of proposal.md, never of the state log: an answer
# removes its marker, so the next scan simply does not find it. Nothing here
# changes the state machine.
#
# Functions:
#   planner_specify_decisions_scan <INIT>    one line per decision, in file
#                                            order: O<n>\t<hash8>\t<line_no>\t<question>
#                                            rc 0 (also: no proposal), 1 cannot read
#   planner_specify_decisions_open <INIT>    same output and rc (every decision
#                                            the scan takes is open)
#   planner_specify_decisions_stray <INIT>   tripwire: <line_no>\t<reason> for every
#                                            non-fenced NEEDS_HUMAN_DECISION line the
#                                            scan did not take; reason is one of
#                                            outside|heading|duplicate|variant|prose
#                                            rc 0, 1 cannot read
#   planner_specify_gate <INIT>              rc 0 clear, 3 at least one open decision,
#                                            1 cannot scan. Writes no phase line; its
#                                            only write is one deduplicated
#                                            META|specify-gate|warn line per proposal sha8
#   planner_specify_halt_report <INIT> <STATE_DIR>
#                                            the halt prose (stdout); rc 0, 1 cannot scan
#   planner_specify_render_answer <value> <round> <role>
#                                            the answered Outcome line; rc 1 bad round/role
#   planner_specify_render_defer <question>  the deferred Outcome line
#   planner_specify_substitute <proposal> <out> <line_no> <rendered>
#                                            writes <proposal> with line <line_no>
#                                            replaced by <rendered> to <out>; rc 0 ok,
#                                            1 I/O or usage, 2 target line is not a marker
#
# Scan rules (design D2): a line opening a ``` or ~~~ fence toggles fence state
# and fenced lines are never looked at. The section runs from
# `## Business Outcomes` to the next `#`/`##` heading. A subsection opens at
# `### O<n>` with <n> 1–999 and no leading zero — the same pattern as the
# `specify-answer:O<n>` binding in ticket-auto-pipeline's human-hold-parse.sh,
# so the scan can never emit a binding the parser rejects. A marker is
# anchored at the line start; only the first one in a subsection is taken.
# hash8 = first 8 hex of sha256("<oid>\n<question>").
#
# Values reach awk only through ENVIRON, never as program text or -v (which
# would interpret backslash escapes). Written without regex intervals, so
# mawk runs it, and under LC_ALL=C so `—`/`–` compare as bytes everywhere.
#
# Sourceable library. No set -euo pipefail at file scope (repo convention for
# this directory).

_PLANNER_SPECIFY_DECISIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f planner_state_log >/dev/null 2>&1 ||
  source "${_PLANNER_SPECIFY_DECISIONS_DIR}/planner-state.sh"

PLANNER_SPECIFY_MARKER="NEEDS_HUMAN_DECISION"

_planner_specify_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# _planner_specify_proposal <INIT> — print the proposal path. rc 0 exists and
# is readable, 2 does not exist, 1 cannot resolve or cannot read.
_planner_specify_proposal() {
  local dir p
  dir=$(planner_initiative_dir "$1") || return 1
  p="${dir}/artifacts/proposal.md"
  printf '%s\n' "$p"
  [ -e "$p" ] || return 2
  { [ -f "$p" ] && [ -r "$p" ]; } || return 1
  return 0
}

# _planner_specify_awk <file> — the one scan pass. Prints
#   T<TAB>O<n><TAB><line_no><TAB><question>   for a taken decision
#   S<TAB><line_no><TAB><reason>               for a tripwire line
_planner_specify_awk() {
  # shellcheck disable=SC2016  # awk program, not shell
  LC_ALL=C _PSD_TOKEN="$PLANNER_SPECIFY_MARKER" awk '
    function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
    function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
    # The fence character this line opens or closes with, or "".
    function fence_char(s) {
      sub(/^(   |  | )?/, "", s)
      if (substr(s, 1, 3) == "```") return "`"
      if (substr(s, 1, 3) == "~~~") return "~"
      return ""
    }
    # Is s (already left-stripped of decoration) an outcome marker in one of
    # the forms the scan refuses? Used to tell "variant" from "prose".
    function variant_head(s) {
      if (index(s, "**Outcome:**") == 1) s = substr(s, 13)
      else if (index(s, "**Outcome**:") == 1) s = substr(s, 13)
      else return 0
      s = ltrim(s)
      return index(s, tok) == 1
    }
    BEGIN { tok = ENVIRON["_PSD_TOKEN"]; fence = ""; in_sec = 0; sub_state = "none" }
    {
      line = $0
      sub(/\r$/, "", line)
      fc = fence_char(line)
      if (fence != "") {
        if (fc == fence) fence = ""
        next
      }
      if (fc != "") { fence = fc; next }

      if (line ~ /^## Business Outcomes[ \t]*$/) {
        in_sec = 1; sub_state = "none"; next
      }
      if (line ~ /^#[ \t]/ || line ~ /^#$/ || line ~ /^##[ \t]/ || line ~ /^##$/) {
        in_sec = 0; sub_state = "none"
      } else if (in_sec && (line ~ /^###[ \t]/ || line ~ /^###$/)) {
        s = line
        sub(/^###[ \t]*/, "", s)
        id = s
        if (match(s, /[ \t]/)) id = substr(s, 1, RSTART - 1)
        if (id ~ /^O[1-9][0-9]?[0-9]?$/) {
          if (id in seen) sub_state = "dup"
          else { seen[id] = 1; sub_state = "ok"; cur = id; taken = 0 }
        } else {
          sub_state = "bad"
        }
        # A heading line is never a marker; a token in it is prose.
        if (index(line, tok)) print "S\t" NR "\tprose"
        next
      }

      if (!index(line, tok)) next

      if (!in_sec) { print "S\t" NR "\toutside"; next }

      # Exact marker: **Outcome:** <ws> TOKEN, then nothing or <sep> question.
      is_marker = 0; q = ""
      if (index(line, "**Outcome:**") == 1) {
        r = ltrim(substr(line, 13))
        if (index(r, tok) == 1) {
          r = substr(r, length(tok) + 1)
          if (r ~ /^[ \t]*$/) { is_marker = 1 }
          else {
            r = ltrim(r)
            n = split("\342\200\224 \342\200\223 -- - :", seps, " ")
            for (i = 1; i <= n; i++) {
              if (index(r, seps[i]) == 1) {
                is_marker = 1; q = substr(r, length(seps[i]) + 1); break
              }
            }
          }
        }
      }

      if (is_marker) {
        if (sub_state == "ok" && !taken) {
          taken = 1
          gsub(/[|`\r]/, "", q)
          gsub(/[ \t]+/, " ", q)
          q = rtrim(ltrim(q))
          print "T\t" cur "\t" NR "\t" q
        } else if (sub_state == "ok" || sub_state == "dup") {
          print "S\t" NR "\tduplicate"
        } else {
          print "S\t" NR "\theading"
        }
        next
      }

      # Not exact: decorated (blockquote, list item, code span) or the
      # **Outcome**: spelling is a variant; anything else is prose.
      d = line
      while (1) {
        o = d
        sub(/^[ \t]+/, "", d)
        sub(/^>/, "", d)
        sub(/^[-*+][ \t]+/, "", d)
        sub(/^[0-9]+[.)][ \t]+/, "", d)
        sub(/^`+/, "", d)
        if (d == o) break
      }
      if (variant_head(d)) print "S\t" NR "\tvariant"
      else print "S\t" NR "\tprose"
    }
  ' <"$1"
}

planner_specify_decisions_scan() {
  local init="$1" p rc=0 raw kind oid lno q h
  p=$(_planner_specify_proposal "$init") || rc=$?
  [ "$rc" -eq 2 ] && return 0
  [ "$rc" -eq 0 ] || return 1
  raw=$(_planner_specify_awk "$p") || return 1
  while IFS=$'\t' read -r kind oid lno q; do
    [ "$kind" = "T" ] || continue
    [ -n "$q" ] || q="(no question was written — state the business outcome for ${oid})"
    h=$(printf '%s\n%s' "$oid" "$q" | _planner_specify_sha256 | cut -c1-8)
    printf '%s\t%s\t%s\t%s\n' "$oid" "$h" "$lno" "$q"
  done <<<"$raw"
  return 0
}

planner_specify_decisions_open() {
  planner_specify_decisions_scan "$@"
}

planner_specify_decisions_stray() {
  local init="$1" p rc=0 raw
  p=$(_planner_specify_proposal "$init") || rc=$?
  [ "$rc" -eq 2 ] && return 0
  [ "$rc" -eq 0 ] || return 1
  raw=$(_planner_specify_awk "$p") || return 1
  printf '%s\n' "$raw" | awk -F'\t' '$1 == "S" { print $2 "\t" $3 }'
  return 0
}

# _planner_specify_tripwire <INIT> <proposal> — write the warn line once per
# proposal sha8. Never fails the gate.
_planner_specify_tripwire() {
  local init="$1" p="$2" st sha8 log n list
  st=$(planner_specify_decisions_stray "$init") || return 0
  [ -n "$st" ] || return 0
  sha8=$(_planner_specify_sha256 <"$p" | cut -c1-8)
  log=$(planner_state_log "$init") || return 0
  if [ -f "$log" ] && grep -q "^[^|]*|META|specify-gate|warn|.*\[proposal ${sha8}\]\$" "$log" 2>/dev/null; then
    return 0
  fi
  n=$(printf '%s\n' "$st" | grep -c .)
  list=$(printf '%s\n' "$st" | awk -F'\t' '{ printf "%sL%s %s", (NR > 1 ? ", " : ""), $1, $2 }')
  planner_state_write "$init" META specify-gate warn \
    "${n} ${PLANNER_SPECIFY_MARKER} line(s) not asked: ${list} [proposal ${sha8}]" || true
  return 0
}

planner_specify_gate() {
  local init="$1" p rc=0 open
  p=$(_planner_specify_proposal "$init") || rc=$?
  [ "$rc" -eq 2 ] && return 0
  [ "$rc" -eq 0 ] || return 1
  open=$(planner_specify_decisions_scan "$init") || return 1
  _planner_specify_tripwire "$init" "$p"
  [ -n "$open" ] && return 3
  return 0
}

planner_specify_halt_report() {
  local init="$1" state_dir="$2" open n oid h lno q
  open=$(planner_specify_decisions_scan "$init") || return 1
  n=0
  [ -n "$open" ] && n=$(printf '%s\n' "$open" | grep -c .)
  echo "Specify is waiting on ${n} business decision(s) — the proposal could not source them."
  echo ""
  if [ -n "$open" ]; then
    while IFS=$'\t' read -r oid h lno q; do
      printf '  %s  %s\n' "$oid" "$q"
    done <<<"$open"
  fi
  echo ""
  echo "Answer:     bash lib/planner-stop-describe.sh ${init}, then /ticket-planner resume ${init} --answers <file>"
  echo "            (or edit the Outcome line in proposal.md by hand, then /ticket-planner resume ${init})"
  echo "Proposal:   ${state_dir}/artifacts/proposal.md"
  return 0
}

# _planner_specify_neutralise <text> — one line with fences, HTML comments and
# the marker token made inert. Pure parameter expansion: nothing is evaluated.
_planner_specify_neutralise() {
  local v="$1" prev pre rest
  v="${v//$'\r'/ }"
  v="${v//$'\n'/ }"
  # Paired comments first, shortest match each time.
  while [[ "$v" == *'<!--'*'-->'* ]]; do
    pre="${v%%<!--*}"
    rest="${v#*<!--}"
    [[ "$rest" == *'-->'* ]] || break
    v="${pre}${rest#*-->}"
  done
  # Then any unpaired opener or closer and fence runs, until nothing changes
  # (a removal can join two halves into a new one).
  prev=""
  while [ "$v" != "$prev" ]; do
    prev="$v"
    v="${v//<!--/}"
    v="${v//-->/}"
    v="${v//~~~/}"
    v="${v//\`\`\`/}"
  done
  # Last, so no earlier removal can rebuild the token.
  v="${v//${PLANNER_SPECIFY_MARKER}/NEEDS-HUMAN-DECISION}"
  # Collapse whitespace runs and trim.
  v=$(printf '%s' "$v" | tr -s ' \t' '  ')
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

planner_specify_render_answer() {
  local value="$1" round="$2" role="$3" v
  [[ "$round" =~ ^[1-9][0-9]*$ ]] || {
    echo "planner_specify_render_answer: bad round '${round}'" >&2
    return 1
  }
  case "$role" in
  client | operator) ;;
  *)
    echo "planner_specify_render_answer: bad role '${role}'" >&2
    return 1
    ;;
  esac
  v=$(_planner_specify_neutralise "$value")
  v="${v//\"/\'}"
  printf '**Outcome:** Human decision (verbatim, round %s, %s): "%s"\n' "$round" "$role" "$v"
}

planner_specify_render_defer() {
  local q
  q=$(_planner_specify_neutralise "$1")
  printf '**Outcome:** Deferred decision: %s\n' "$q"
}

planner_specify_substitute() {
  local proposal="$1" out="$2" lno="$3" rendered="$4" target
  if [ "$#" -ne 4 ] || [ ! -f "$proposal" ] || [ ! -r "$proposal" ] || [ -z "$out" ]; then
    echo "planner_specify_substitute: usage <proposal> <out> <line_no> <rendered>" >&2
    return 1
  fi
  [[ "$lno" =~ ^[1-9][0-9]*$ ]] || {
    echo "planner_specify_substitute: bad line number '${lno}'" >&2
    return 2
  }
  target=$(sed -n "${lno}p" "$proposal" | tr -d '\r')
  case "$target" in
  "**Outcome:**"*"${PLANNER_SPECIFY_MARKER}"*) ;;
  *)
    echo "planner_specify_substitute: line ${lno} is not a ${PLANNER_SPECIFY_MARKER} marker" >&2
    return 2
    ;;
  esac
  # shellcheck disable=SC2016  # awk program, not shell
  _PSD_LNO="$lno" _PSD_RENDERED="$rendered" awk '
    NR == ENVIRON["_PSD_LNO"] + 0 { print ENVIRON["_PSD_RENDERED"]; next }
    { print }
  ' "$proposal" >"$out" || return 1
  return 0
}
