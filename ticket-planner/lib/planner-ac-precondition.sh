#!/usr/bin/env bash
# planner-ac-precondition.sh — the `## Preconditions` table of a spec
# (planner-ac-code-precondition, design D1, D4, D5).
#
# Every non-synthesized spec of a contract initiative declares, per
# acceptance criterion, the stored starting state that criterion needs, as one
# pipe table (or `None.`) under one heading:
#
#   ## Preconditions
#
#   | Criterion | Key | Mode | Requires | Basis |
#   |-----------|-----|------|----------|-------|
#   | <an AC line> | `invoice.due_date` | state | null | code:billing/src/main/resources/db/changelog |
#   | <an AC line> | `invoice.customer_id` | input | null | — |
#
# This file is the bash that reads the table: which rows are valid, and the
# Basis rules against the initiative's other specs. Schema facts, the
# decision and the Crosscheck family come later (tasks 2–3).
#
# Functions:
#   planner_acpre_contract_mark <INIT>        append META|contract|start|
#                                             ac-precondition-v1 once (not wired:
#                                             the router call is task 5.3)
#   planner_acpre_contract_initiative <INIT>  rc 0 when that line is present
#   planner_acpre_rows <spec>                 one line per grammar-valid row:
#                                             <line>\t<criterion>\t<key>\t<mode>\t
#                                             <requires>\t<basis>; criterion with
#                                             whitespace collapsed, key without
#                                             backticks. A `spec:` row is printed
#                                             even when its Basis fails the
#                                             semantic rules below; callers drop
#                                             every row whose line
#                                             planner_acpre_invalid names.
#   planner_acpre_invalid <INIT> <spec>       one line per problem, sorted by line:
#                                             <line>\t<reason>. Reasons: missing
#                                             (line 0) | empty | no-table |
#                                             duplicate-section | second-table |
#                                             header | shape | criterion not found |
#                                             key | mode | requires | basis |
#                                             duplicate | basis-spec-unknown |
#                                             basis-spec-no-write |
#                                             basis-not-a-dependency
#
# Row rules (design D1):
#   Criterion  equals one `## Acceptance Criteria` item (`- [ ]`, `- [x]`,
#              `* [ ]`) after trimming and collapsing whitespace runs
#   Key        backticked, item 6's key grammar with exactly two segments
#   Mode       state | input
#   Requires   null | value:<[a-z][a-z0-9_]*> | number:<-?digits[.digits]>,
#              the number at most PLANNER_ACPRE_NUMBER_MAX characters
#   Basis      state: code:<path> (item 6 path grammar) or spec:<slug>;
#              input: `—` (an ASCII `-` is accepted too)
#   A (Criterion, Key, Mode, Requires) tuple appears once; a later copy is
#   `duplicate`. Each row gets its first failing reason only.
# Basis rules (design D5), checked by planner_acpre_invalid against the
# specs next to <spec>: `spec:<slug>` names an existing spec that is not
# INDEX.md or synth-marked (else basis-spec-unknown) whose `## Writes` holds
# the row's key or its entity (else basis-spec-no-write); a slug other than
# the spec's own must be in planner_ticketgen_spec_deps (else
# basis-not-a-dependency). Both of the last two can be reported for one row.
#
# A skipped spec (planner_ownership_spec_checked rc 1: INDEX.md or
# synth-marked) prints nothing from either parse function. Cells are trimmed,
# `\|` is a literal pipe, CRLF is tolerated, fenced lines are ignored.
#
# Values reach awk only through ENVIRON. Every awk program runs under LC_ALL=C
# with no regex intervals, so mawk runs it. `PLANNER_ACPRE_AWK` (default
# `awk`) names the interpreter, so the tests can run each program under mawk
# and gawk.
#
# Sourceable library. No set -euo pipefail at file scope (repo convention for
# this directory).

_PLANNER_AC_PRECONDITION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f planner_state_log >/dev/null 2>&1 ||
  source "${_PLANNER_AC_PRECONDITION_DIR}/planner-state.sh"
declare -f planner_ownership_writes >/dev/null 2>&1 ||
  source "${_PLANNER_AC_PRECONDITION_DIR}/planner-spec-ownership.sh"

PLANNER_ACPRE_CONTRACT="ac-precondition-v1"
PLANNER_ACPRE_NUMBER_MAX=30

_planner_acpre_awk() {
  "${PLANNER_ACPRE_AWK:-awk}" "$@"
}

# ── Contract marker ───────────────────────────────────────────────────────────

planner_acpre_contract_initiative() {
  local log
  log=$(planner_state_log "$1" 2>/dev/null) || return 1
  [ -f "$log" ] || return 1
  grep -q "^[^|]*|META|contract|start|${PLANNER_ACPRE_CONTRACT}\$" "$log" 2>/dev/null
}

planner_acpre_contract_mark() {
  local init="$1"
  planner_acpre_contract_initiative "$init" && return 0
  planner_state_write "$init" META contract start "$PLANNER_ACPRE_CONTRACT"
}

# ── Table parse ───────────────────────────────────────────────────────────────

# _planner_acpre_table_awk <file> — one structural pass. Fields are separated
# by \037. Records:
#   A <criterion>                  an Acceptance Criteria item, whitespace
#                                  collapsed and trimmed
#   S <line>                       the first `## Preconditions` heading
#   D <line>                       a later one
#   N <line>                       `None.`
#   X <line>                       other content where the table should start
#   H <line> ok|bad                the header row
#   R <line> <n> <c1>..<cn>        a data row, cells trimmed and unescaped
#   T <line>                       the first row of a second table
_planner_acpre_table_awk() {
  # shellcheck disable=SC2016  # awk program, not shell
  LC_ALL=C _planner_acpre_awk '
    function fence_char(s) {
      sub(/^(   |  | )?/, "", s)
      if (substr(s, 1, 3) == "```") return "`"
      if (substr(s, 1, 3) == "~~~") return "~"
      return ""
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function squeeze(s) { gsub(/[ \t]+/, " ", s); return trim(s) }
    function cells(s,   n, i, L, c, cur, lastsep) {
      s = substr(s, 2); L = length(s); n = 0; cur = ""; lastsep = 1; i = 1
      while (i <= L) {
        c = substr(s, i, 1)
        if (c == "\\" && substr(s, i + 1, 1) == "|") { cur = cur "|"; i += 2; lastsep = 0; continue }
        if (c == "|") { C[++n] = trim(cur); cur = ""; i++; lastsep = 1; continue }
        if (c == "\t") c = " "
        cur = cur c; i++; lastsep = 0
      }
      if (!lastsep) C[++n] = trim(cur)
      return n
    }
    BEGIN { US = "\037"; fence = ""; sec = ""; seen = 0; tstate = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      fc = fence_char(line)
      if (fence != "") { if (fc == fence) fence = ""; next }
      if (fc != "") { fence = fc; next }

      if (line ~ /^#[ \t]/ || line ~ /^#$/ || line ~ /^##[ \t]/ || line ~ /^##$/) {
        h = trim(line)
        sec = ""
        if (h == "## Acceptance Criteria") { sec = "ac"; next }
        if (h == "## Preconditions") {
          if (seen) { print "D" US NR; next }
          seen = 1; sec = "pre"; tstate = 0
          print "S" US NR
        }
        next
      }
      if (sec == "ac") {
        if (line ~ /^[ \t]*[-*][ \t]+\[[ xX]\]/) {
          t = line
          sub(/^[ \t]*[-*][ \t]+\[[ xX]\]/, "", t)
          print "A" US squeeze(t)
        }
        next
      }
      if (sec != "pre") next

      t = trim(line)
      # 3: the table (or None.) ended; 4: inside a second table.
      if (tstate >= 3) {
        if (t == "") { tstate = 3; next }
        if (substr(t, 1, 1) == "|" && tstate == 3) { print "T" US NR; tstate = 4 }
        next
      }
      if (t == "") { if (tstate > 0) tstate = 3; next }
      if (tstate == 0) {
        if (substr(t, 1, 1) == "|") {
          n = cells(t); hd = ""
          for (k = 1; k <= n; k++) hd = hd (k > 1 ? "|" : "") tolower(C[k])
          print "H" US NR US (hd == "criterion|key|mode|requires|basis" ? "ok" : "bad")
          tstate = 1
        } else if (t == "None." || t == "None") {
          print "N" US NR; tstate = 3
        } else {
          print "X" US NR; tstate = 3
        }
        next
      }
      if (substr(t, 1, 1) != "|") { tstate = 3; next }
      if (tstate == 1 && t ~ /^[|:\- \t]+$/ && index(t, "-")) { tstate = 2; next }
      tstate = 2
      n = cells(t)
      out = "R" US NR US n
      for (k = 1; k <= n; k++) out = out US squeeze(C[k])
      print out
    }
  ' <"$1"
}

# _planner_acpre_key_ok <key> — item 6's key grammar, exactly two segments.
_planner_acpre_key_ok() {
  [[ "$1" == *.* ]] && _planner_own_key_ok "$1"
}

# _planner_acpre_requires_ok <requires> — null | value:<v> | number:<n>.
_planner_acpre_requires_ok() {
  local r="$1" n
  case "$r" in
  null) return 0 ;;
  value:*) [[ "${r#value:}" =~ ^[a-z][a-z0-9_]*$ ]] ;;
  number:*)
    n="${r#number:}"
    [ "${#n}" -le "$PLANNER_ACPRE_NUMBER_MAX" ] && [[ "$n" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
    ;;
  *) return 1 ;;
  esac
}

# _planner_acpre_basis_ok <mode> <basis> — the Basis grammar for that Mode.
_planner_acpre_basis_ok() {
  local mode="$1" b="$2"
  if [ "$mode" = input ]; then
    [ "$b" = "—" ] || [ "$b" = "-" ]
    return
  fi
  case "$b" in
  code:*) _planner_own_path_ok "${b#code:}" ;;
  spec:*) [[ "${b#spec:}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] ;;
  *) return 1 ;;
  esac
}

# _planner_acpre_classify <spec> — rows and problems in one pass. Prints
# V<US><line><US><criterion><US><key><US><mode><US><requires><US><basis> and
# I<US><line><US><reason>, in line order. rc 1 when the file cannot be read.
_planner_acpre_classify() {
  local f="$1" raw rec ln n crit key mode req basis reason head="" body=0 bad_hdr=0 tuple
  local -a F
  local US=$'\037'
  { [ -f "$f" ] && [ -r "$f" ]; } || return 1
  planner_ownership_spec_checked "$f" || return 0
  raw=$(_planner_acpre_table_awk "$f") || return 1
  local -A acs=() tuples=()
  while IFS=$'\037' read -r -a F; do
    [ "${F[0]:-}" = A ] && acs["${F[1]:-}"]=1
  done <<<"$raw"
  while IFS=$'\037' read -r -a F; do
    [ "${#F[@]}" -gt 1 ] || continue
    rec="${F[0]}"
    ln="${F[1]}"
    reason=""
    case "$rec" in
    A) continue ;;
    S) head="$ln" ;;
    D) reason=duplicate-section ;;
    N) body=1 ;;
    X)
      body=1
      reason=no-table
      ;;
    T) reason=second-table ;;
    H)
      body=1
      if [ "${F[2]}" != ok ]; then
        bad_hdr=1
        reason=header
      fi
      ;;
    R)
      n="${F[2]}"
      crit="${F[3]:-}"
      key="${F[4]:-}"
      mode="${F[5]:-}"
      req="${F[6]:-}"
      basis="${F[7]:-}"
      if [ "$bad_hdr" -eq 1 ]; then
        reason=header
      elif [ "$n" != 5 ]; then
        reason=shape
      elif [ -z "${acs[$crit]:-}" ]; then
        reason="criterion not found"
      elif [[ "$key" != '`'*'`' ]] || ! _planner_acpre_key_ok "${key:1:${#key}-2}"; then
        reason=key
      elif [ "$mode" != state ] && [ "$mode" != input ]; then
        reason=mode
      elif ! _planner_acpre_requires_ok "$req"; then
        reason=requires
      elif ! _planner_acpre_basis_ok "$mode" "$basis"; then
        reason=basis
      else
        key="${key:1:${#key}-2}"
        tuple="${crit}${US}${key}${US}${mode}${US}${req}"
        if [ -n "${tuples[$tuple]:-}" ]; then
          reason=duplicate
        else
          tuples[$tuple]="$ln"
          printf 'V%s%s%s%s%s%s%s%s%s%s%s%s\n' "$US" "$ln" "$US" "$crit" "$US" "$key" "$US" "$mode" "$US" "$req" "$US" "$basis"
        fi
      fi
      ;;
    esac
    [ -z "$reason" ] || printf 'I%s%s%s%s\n' "$US" "$ln" "$US" "$reason"
  done <<<"$raw"
  if [ -z "$head" ]; then
    printf 'I%s0%smissing\n' "$US" "$US"
  elif [ "$body" -eq 0 ]; then
    printf 'I%s%s%sempty\n' "$US" "$head" "$US"
  fi
  return 0
}

planner_acpre_rows() {
  local out
  out=$(_planner_acpre_classify "$1") || return 1
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | LC_ALL=C awk -F'\037' -v OFS='\t' '$1 == "V" { print $2, $3, $4, $5, $6, $7 }'
}

# _planner_acpre_spec_writes_key <spec> <key> — rc 0 when the spec's valid
# `## Writes` rows hold <key> or its entity.
_planner_acpre_spec_writes_key() {
  local w
  while IFS= read -r w; do
    [ "$w" = "$2" ] || [ "$w" = "${2%%.*}" ] && return 0
  done < <(planner_ownership_writes "$1" 2>/dev/null | cut -f2)
  return 1
}

planner_acpre_invalid() {
  local spec="$2" out specs_dir self ln key basis slug target deps=""
  local deps_done=0
  out=$(_planner_acpre_classify "$spec") || return 1
  specs_dir=$(dirname "$spec")
  self=$(basename "$spec" .md)
  {
    [ -z "$out" ] || printf '%s\n' "$out" | LC_ALL=C awk -F'\037' -v OFS='\t' '$1 == "I" { print $2, $3 }'
    while IFS=$'\037' read -r _ ln _ key _ _ basis; do
      case "$basis" in spec:*) ;; *) continue ;; esac
      slug="${basis#spec:}"
      target="${specs_dir}/${slug}.md"
      if ! planner_ownership_spec_checked "$target"; then
        printf '%s\tbasis-spec-unknown\n' "$ln"
        continue
      fi
      _planner_acpre_spec_writes_key "$target" "$key" ||
        printf '%s\tbasis-spec-no-write\n' "$ln"
      [ "$slug" = "$self" ] && continue
      if [ "$deps_done" -eq 0 ]; then
        declare -f planner_ticketgen_spec_deps >/dev/null 2>&1 ||
          source "${_PLANNER_AC_PRECONDITION_DIR}/planner-ticket-body.sh"
        deps=$(planner_ticketgen_spec_deps "$spec" "$specs_dir" 2>/dev/null) || deps=""
        deps_done=1
      fi
      grep -qxF -- "$slug" <<<"$deps" || printf '%s\tbasis-not-a-dependency\n' "$ln"
    done < <(printf '%s\n' "$out" | grep "^V" || true)
  } | LC_ALL=C sort -s -t$'\t' -k1,1n
}
