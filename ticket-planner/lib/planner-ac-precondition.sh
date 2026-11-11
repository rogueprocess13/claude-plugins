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
# This file is the bash that reads the table (which rows are valid, and the
# Basis rules against the initiative's other specs), reads strong schema
# facts from JPA classes and Liquibase XML changelogs, and decides each
# `state` row with a `code:` Basis (design D6–D8). The Crosscheck family that
# turns decisions into findings is lib/planner-crosscheck-ac-precondition.sh
# (task 3).
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
#   planner_acpre_facts <tree> <sub> <key> [<label>]
#                                             schema facts for <entity>.<field>:
#                                             <kind>\t<value>\t<label>/<path>:<line>,
#                                             plus found/source/name markers and
#                                             `unchecked <reason> -` (see below)
#   planner_acpre_decide <requires> <facts> [<key>]
#                                             reachable | unreachable\t<fact> |
#                                             unchecked\t<reason>
#   planner_acpre_check_row <INIT> <code-path> <key> <requires>
#                                             the two above behind the code-target
#                                             resolver: <pin>\t<sources>\t<decision>
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

# ── Schema facts (design D4, D6, D7) ──────────────────────────────────────────
#
# A raw record, as the extractors print it and the cache stores it, is
# <fk>\t<kind>\t<value>\t<loc>: <fk> the normalised field it belongs to (`*`
# for the whole entity), <loc> `<label/><path>:<line>` or `-`. planner_acpre_facts
# drops <fk> after filtering on the key's field.

PLANNER_ACPRE_EXTRACTORS="_planner_acpre_facts_liquibase_xml _planner_acpre_facts_jpa"
PLANNER_ACPRE_ENTITY_MAX_FILES=2000
# The candidate list of the current entity scan (relative paths), shared by
# the extractors.
_PLANNER_ACPRE_CAND=()

# _planner_acpre_norm <name> — lower case, `_` removed (design D6).
_planner_acpre_norm() {
  local s="${1,,}"
  printf '%s' "${s//_/}"
}

# _planner_acpre_list <tree> <rel> — `.java`/`.xml` files under <tree>/<rel>
# (the whole tree for an empty <rel>), relative to <tree>, with build and VCS
# directories pruned, sorted.
_planner_acpre_list() {
  local tree="$1" rel="${2:-.}"
  (cd "$tree" 2>/dev/null && find "$rel" -mindepth 1 \
    \( -type d \( -name .git -o -name target -o -name build -o -name node_modules \
    -o -name out -o -name .gradle -o -name .idea \) -prune \) \
    -o -type f \( -name '*.java' -o -name '*.xml' \) -print 2>/dev/null) |
    sed 's#^\./##' | LC_ALL=C sort
}

# _planner_acpre_containing <tree> <text> — the relative paths on stdin whose
# file holds <text>, in input order.
_planner_acpre_containing() {
  local tree="$1" text="$2" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF -- "$text" "${tree}/${f}" 2>/dev/null && printf '%s\n' "$f"
  done
}

# _planner_acpre_run_awk <tree> <label> <entity> <program> <file...> — runs one
# extractor program from <tree> so FILENAME is relative.
_planner_acpre_run_awk() {
  local tree="$1" label="$2" ent="$3" prog="$4"
  shift 4
  [ "$#" -gt 0 ] || return 0
  (cd "$tree" && _ACP_E="$ent" _ACP_LABEL="${label:+${label}/}" LC_ALL=C _planner_acpre_awk "$prog" "$@")
}

# The Java comment/string scanner both Java programs share: strip(line) returns
# the line with comments blanked (`//` to the end, `/* */` across lines; state
# in `incom`). String and char literals are kept, and a `//` or `/*` inside
# one is not a comment.
# shellcheck disable=SC2016  # awk program, not shell
_PLANNER_ACPRE_AWK_JSTRIP='
function strip(line,   i, L, c, out, q) {
  out = ""; i = 1; L = length(line); q = ""
  while (i <= L) {
    c = substr(line, i, 1)
    if (incom) {
      if (c == "*" && substr(line, i + 1, 1) == "/") { incom = 0; i += 2; out = out "  "; continue }
      out = out " "; i++; continue
    }
    if (q != "") {
      out = out c
      if (c == "\\") { out = out substr(line, i + 1, 1); i += 2; continue }
      if (c == q) q = ""
      i++; continue
    }
    if (c == "/" && substr(line, i + 1, 1) == "/") break
    if (c == "/" && substr(line, i + 1, 1) == "*") { incom = 1; i += 2; out = out "  "; continue }
    if (c == "\"" || c == "\047") q = c
    out = out c; i++
  }
  return out
}
'

# The JPA program. ENVIRON: _ACP_E (normalised entity), _ACP_LABEL. Records:
#   * source jpa            a file with an @Entity class
#   * entity-name <n>       every @Entity class name and literal @Table name
#   * found entity          the class matching _ACP_E
#   * field-name <n>        each persistent field of it (and its column literal)
#   <fk> found field
#   <fk> transient -        @Transient, @Formula, `transient`
#   <fk> nullable no        @Id
#   <fk> primitive <type>
#   <fk> jtype <Type>       a non-primitive type (resolved to enum facts in bash)
#   <fk> jenum STRING|ORDINAL|none|unknown
#   <fk> jconvert -         @Convert
# An annotation argument that is not a plain literal gives no name.
# shellcheck disable=SC2016  # awk program, not shell
_PLANNER_ACPRE_AWK_JPA="${_PLANNER_ACPRE_AWK_JSTRIP}"'
function norm(s) { s = tolower(s); gsub(/_/, "", s); return s }
function trim(s) { sub(/^[ \t\n]+/, "", s); sub(/[ \t\n]+$/, "", s); return s }
function emit(fk, kind, val, ln) { print fk "\t" kind "\t" val "\t" LABEL FILENAME ":" ln }
# parse_annots(s) — fills AN[1..na] (simple names) and AA[1..na] (argument
# text, "\001" when there are no parentheses); returns s without them.
function parse_annots(s,   i, j, k, m, L, c, c2, out, nm, d, q) {
  na = 0; out = ""; L = length(s); i = 1
  while (i <= L) {
    c = substr(s, i, 1)
    if (c == "\"" || c == "\047") {
      j = i + 1
      while (j <= L && substr(s, j, 1) != c) { if (substr(s, j, 1) == "\\") j++; j++ }
      out = out substr(s, i, j - i + 1); i = j + 1; continue
    }
    if (c != "@") { out = out c; i++; continue }
    j = i + 1
    while (j <= L && substr(s, j, 1) ~ /[A-Za-z0-9_$.]/) j++
    nm = substr(s, i + 1, j - i - 1)
    k = j
    while (k <= L && substr(s, k, 1) ~ /[ \t\n]/) k++
    na++; AA[na] = "\001"
    if (substr(s, k, 1) == "(") {
      d = 0; q = ""; m = k
      while (m <= L) {
        c2 = substr(s, m, 1)
        if (q != "") { if (c2 == "\\") { m += 2; continue } if (c2 == q) q = ""; m++; continue }
        if (c2 == "\"" || c2 == "\047") { q = c2; m++; continue }
        if (c2 == "(") d++
        else if (c2 == ")") { d--; if (d == 0) break }
        m++
      }
      AA[na] = substr(s, k + 1, m - k - 1); j = m + 1
    }
    sub(/^.*\./, "", nm); AN[na] = nm
    out = out " "; i = j
  }
  return out
}
# rawattr(args, key) — the trimmed raw value of key= in an argument list
# ("value" also takes a lone positional argument); "\002" when absent.
function rawattr(args, key,   i, L, c, d, q, part, n, P, k, v) {
  if (args == "\001") return "\002"
  n = 0; part = ""; d = 0; q = ""; L = length(args)
  for (i = 1; i <= L; i++) {
    c = substr(args, i, 1)
    if (q != "") { part = part c; if (c == "\\") { i++; part = part substr(args, i, 1); continue } if (c == q) q = ""; continue }
    if (c == "\"" || c == "\047") { q = c; part = part c; continue }
    if (c == "(" || c == "{") d++
    if (c == ")" || c == "}") d--
    if (c == "," && d == 0) { P[++n] = part; part = ""; continue }
    part = part c
  }
  P[++n] = part
  for (i = 1; i <= n; i++) {
    v = trim(P[i])
    if (v == "") continue
    if (match(v, /^[A-Za-z_][A-Za-z0-9_]*[ \t\n]*=/)) {
      k = substr(v, 1, RLENGTH - 1); k = trim(k); v = trim(substr(v, RLENGTH + 1))
    } else k = "value"
    if (k == key) return v
  }
  return "\002"
}
# litattr(args, key) — the string literal value of key, "" when absent or not
# a plain literal (a constant, a concatenation, a ${…} placeholder).
function litattr(args, key,   v) {
  v = rawattr(args, key)
  if (v == "\002") return ""
  if (v !~ /^"[^"\\]*"$/) return ""
  v = substr(v, 2, length(v) - 2)
  if (index(v, "${")) return ""
  return v
}
function enumval(args,   v) {
  if (args == "\001") return "ORDINAL"
  v = rawattr(args, "value")
  if (v == "\002") return "ORDINAL"
  gsub(/[ \t\n]/, "", v)
  if (v == "STRING" || v ~ /(^|\.)EnumType\.STRING$/) return "STRING"
  if (v == "ORDINAL" || v ~ /(^|\.)EnumType\.ORDINAL$/) return "ORDINAL"
  return "unknown"
}
function open_block(s,   rest, m, cls, tbl, isent, k) {
  rest = parse_annots(s)
  if (!match(" " rest " ", /[^A-Za-z0-9_$](class|record)[ \t\n]+[A-Za-z_$][A-Za-z0-9_$]*/)) return
  m = substr(" " rest " ", RSTART, RLENGTH)
  sub(/^[^A-Za-z0-9_$]*(class|record)[ \t\n]+/, "", m)
  cls = m; isent = 0; tbl = ""
  for (k = 1; k <= na; k++) {
    if (AN[k] == "Entity") isent = 1
    if (AN[k] == "Table") tbl = litattr(AA[k], "name")
  }
  if (!isent) return
  if (!srcdone) { emit("*", "source", "jpa", FNR); srcdone = 1 }
  emit("*", "entity-name", cls, FNR)
  if (tbl != "") emit("*", "entity-name", tbl, FNR)
  if (!inent && (norm(cls) == E || (tbl != "" && norm(tbl) == E))) {
    inent = 1; entdepth = depth + 1
    emit("*", "found", "entity", FNR)
  }
}
function field(s, ln,   rest, k, n, T, name, type, isstatic, trans, id, en, conv, col, fk1, fk2, x, fk, prim) {
  rest = parse_annots(s)
  k = index(rest, "="); if (k) rest = substr(rest, 1, k - 1)
  while (match(rest, /<[^<>]*>/)) rest = substr(rest, 1, RSTART - 1) " " substr(rest, RSTART + RLENGTH)
  gsub(/\[[ \t\n]*\]/, " ", rest)
  if (index(rest, ",") || index(rest, "(") || index(rest, ")")) return
  n = split(trim(rest), T, /[ \t\n]+/)
  if (n < 2) return
  name = T[n]; type = T[n - 1]
  if (name !~ /^[A-Za-z_$][A-Za-z0-9_$]*$/ || type !~ /^[A-Za-z_$][A-Za-z0-9_$.]*$/) return
  isstatic = 0; trans = 0
  for (k = 1; k < n - 1; k++) { if (T[k] == "static") isstatic = 1; if (T[k] == "transient") trans = 1 }
  if (isstatic) return
  id = 0; en = "none"; conv = 0; col = ""
  for (k = 1; k <= na; k++) {
    if (AN[k] == "Id") id = 1
    else if (AN[k] == "Transient" || AN[k] == "Formula") trans = 1
    else if (AN[k] == "Enumerated") en = enumval(AA[k])
    else if (AN[k] == "Convert") conv = 1
    else if (AN[k] == "Column" || AN[k] == "JoinColumn") { x = litattr(AA[k], "name"); if (x != "") col = x }
  }
  emit("*", "field-name", name, ln)
  if (col != "") emit("*", "field-name", col, ln)
  fk1 = norm(name); fk2 = (col != "" ? norm(col) : fk1)
  prim = (type ~ /^(int|long|short|byte|double|float|boolean|char)$/)
  for (x = 1; x <= 2; x++) {
    fk = (x == 1 ? fk1 : fk2)
    if (x == 2 && fk2 == fk1) break
    emit(fk, "found", "field", ln)
    if (trans) emit(fk, "transient", "-", ln)
    if (id) emit(fk, "nullable", "no", ln)
    if (prim) emit(fk, "primitive", type, ln)
    else {
      emit(fk, "jtype", type, ln)
      emit(fk, "jenum", en, ln)
      if (conv) emit(fk, "jconvert", "-", ln)
    }
  }
}
BEGIN { E = ENVIRON["_ACP_E"]; LABEL = ENVIRON["_ACP_LABEL"] }
FNR == 1 { incom = 0; depth = 0; pd = 0; buf = ""; inent = 0; srcdone = 0 }
{
  line = $0; sub(/\r$/, "", line)
  line = strip(line)
  L = length(line); i = 1; q = ""
  while (i <= L) {
    c = substr(line, i, 1)
    if (q != "") {
      buf = buf c
      if (c == "\\") { buf = buf substr(line, i + 1, 1); i += 2; continue }
      if (c == q) q = ""
      i++; continue
    }
    if (c == "\"" || c == "\047") { q = c; buf = buf c; i++; continue }
    if (c == "(") { pd++; buf = buf c; i++; continue }
    if (c == ")") { if (pd > 0) pd--; buf = buf c; i++; continue }
    if (pd == 0 && c == "{") { open_block(buf); depth++; buf = ""; i++; continue }
    if (pd == 0 && c == "}") { depth--; if (inent && depth < entdepth) inent = 0; buf = ""; i++; continue }
    if (pd == 0 && c == ";") { if (inent && depth == entdepth) field(buf, FNR); buf = ""; i++; continue }
    buf = buf c; i++
  }
  buf = buf "\n"
}
'

# The enum program, one file at a time. ENVIRON: _ACP_T (a Java identifier).
# One line per `enum <T>` declaration: <line>\t<ok|args>\t<CONST,CONST,…>;
# `args` when a constant has constructor arguments or a body.
# shellcheck disable=SC2016  # awk program, not shell
_PLANNER_ACPRE_AWK_ENUM="${_PLANNER_ACPRE_AWK_JSTRIP}"'
function trim(s) { sub(/^[ \t\n]+/, "", s); sub(/[ \t\n]+$/, "", s); return s }
BEGIN { T = ENVIRON["_ACP_T"]; S = "\n" }
{ line = $0; sub(/\r$/, "", line); S = S strip(line) "\n" }
END {
  S = S "\n"
  re = "[^A-Za-z0-9_$.]enum[ \t\n]+" T "[^A-Za-z0-9_$]"
  off = 0; rest = S
  while (match(rest, re)) {
    pos = off + RSTART + RLENGTH - 1
    pre = substr(S, 2, off + RSTART - 1); ln = 1 + gsub(/\n/, "", pre)
    k = index(substr(S, pos), "{")
    off = pos; rest = substr(S, pos + 1)
    if (!k) continue
    i = pos + k; L = length(S); d = 1; pd = 0; q = ""; args = 0; cb = ""
    while (i <= L) {
      c = substr(S, i, 1)
      if (q != "") { if (c == "\\") { i += 2; continue } if (c == q) q = ""; i++; continue }
      if (c == "\"" || c == "\047") { q = c; i++; continue }
      if (c == "(") { pd++; if (d == 1 && pd == 1) args = 1; i++; continue }
      if (c == ")") { pd--; i++; continue }
      if (pd == 0 && c == "{") { d++; args = 1; i++; continue }
      if (pd == 0 && c == "}") { d--; if (d == 0) break; i++; continue }
      if (d == 1 && pd == 0 && c == ";") break
      if (d == 1 && pd == 0) cb = cb c
      i++
    }
    n = split(cb, P, ","); out = ""
    for (j = 1; j <= n; j++) {
      v = trim(P[j]); gsub(/@[A-Za-z0-9_$.]+/, "", v); v = trim(v)
      if (v ~ /^[A-Za-z_$][A-Za-z0-9_$]*$/) out = out (out == "" ? "" : ",") v
    }
    print ln "\t" (args ? "args" : "ok") "\t" out
  }
}
'

# The Liquibase XML program. ENVIRON: _ACP_E (normalised table), _ACP_LABEL.
# Comments, CDATA and every <rollback> block are skipped before any element
# is read; attributes are collected across lines with the line each starts
# on. A small state machine follows the current modelled change and column.
# Records:
#   * source liquibase       a file with a databaseChangeLog element
#   * unparsed <element>     <sql>, <sqlFile>, <customChange>, <modifySql>
#                            anywhere, or any other element naming the table
#   * entity-name <table>    every createTable
#   * found entity           an element naming the table
#   * field-name <column>
#   <fk> found field
#   <fk> nullable no|yes     constraints nullable/primaryKey,
#                            add/dropNotNullConstraint, addPrimaryKey
#   <fk> min|max <n>         smallint, int/integer, bigint; printed at the end,
#                            and only when every type the column is given is
#                            one of those (a column also typed varchar or
#                            ${…} gets none)
# shellcheck disable=SC2016  # awk program, not shell
_PLANNER_ACPRE_AWK_LIQUIBASE='
function norm(s) { s = tolower(s); gsub(/_/, "", s); return s }
function trim(s) { sub(/^[ \t\n]+/, "", s); sub(/[ \t\n]+$/, "", s); return s }
function emit(fk, kind, val, ln) { print fk "\t" kind "\t" val "\t" LABEL FILENAME ":" ln }
# parse(t, ln) — the element name; fills AV (values) and AL (lines).
function parse(t, ln,   i, L, c, nm, an, q, v, cur) {
  split("", AV); split("", AL)
  if (!match(t, /^[A-Za-z_][A-Za-z0-9_:.-]*/)) return ""
  nm = substr(t, 1, RLENGTH); sub(/^.*:/, "", nm)
  i = RLENGTH + 1; L = length(t); cur = ln
  while (i <= L) {
    c = substr(t, i, 1)
    if (c == "\n") { cur++; i++; continue }
    if (c ~ /[ \t\r]/) { i++; continue }
    if (c !~ /[A-Za-z_:]/) { i++; continue }
    an = ""
    while (i <= L && substr(t, i, 1) ~ /[A-Za-z0-9_:.-]/) { an = an substr(t, i, 1); i++ }
    while (i <= L && substr(t, i, 1) ~ /[ \t\r\n]/) { if (substr(t, i, 1) == "\n") cur++; i++ }
    if (substr(t, i, 1) != "=") continue
    i++
    while (i <= L && substr(t, i, 1) ~ /[ \t\r\n]/) { if (substr(t, i, 1) == "\n") cur++; i++ }
    q = substr(t, i, 1)
    if (q != "\"" && q != "\047") continue
    i++; v = ""
    while (i <= L && substr(t, i, 1) != q) { if (substr(t, i, 1) == "\n") cur++; v = v substr(t, i, 1); i++ }
    i++
    sub(/^.*:/, "", an)
    if (!(an in AV)) { AV[an] = v; AL[an] = cur }
  }
  return nm
}
function attr(a) { return (a in AV) ? AV[a] : "" }
function intclass(t) {
  t = tolower(trim(t)); sub(/[ \t]*\(.*$/, "", t)
  if (t == "smallint") return "s"
  if (t == "int" || t == "integer") return "i"
  if (t == "bigint") return "b"
  return ""
}
function addtype(fk, t, loc) {
  if (!(fk in TN)) { TN[fk] = 0; COLS[++nc] = fk }
  TN[fk]++; TV[fk, TN[fk]] = t; TLOC[fk, TN[fk]] = loc
}
function column_found(col, ln) {
  emit(norm(col), "found", "field", ln); emit("*", "field-name", col, ln)
}
function tag(t, ln,   closing, self, t2, nm, tn, hit, col, n, P, k, v) {
  c = substr(t, 1, 1)
  if (c == "?" || c == "!") return
  closing = 0
  if (c == "/") { closing = 1; t = substr(t, 2) }
  t2 = t; sub(/[ \t\r\n]+$/, "", t2); self = 0
  if (substr(t2, length(t2), 1) == "/") { self = 1; t2 = substr(t2, 1, length(t2) - 1) }
  nm = parse(t2, ln)
  if (nm == "") return
  if (nm == "rollback") { if (closing) { if (rb > 0) rb-- } else if (!self) rb++; return }
  if (rb > 0) return
  if (closing) {
    if (nm == "column") incol = 0
    else if (inchg && nm == chg) { inchg = 0; incol = 0 }
    return
  }
  if (nm == "databaseChangeLog") { if (!srcdone) { emit("*", "source", "liquibase", ln); srcdone = 1 } return }
  if (nm == "sql" || nm == "sqlFile" || nm == "customChange" || nm == "modifySql") { emit("*", "unparsed", nm, ln); return }
  if (inchg) {
    if (nm == "column") {
      col = attr("name"); incol = 0
      if (col == "") return
      column_found(col, ln); curcol = norm(col)
      if (attr("type") != "") addtype(curcol, attr("type"), LABEL FILENAME ":" ln)
      if (!self) incol = 1
    } else if (nm == "constraints" && incol) {
      v = attr("nullable")
      if (v == "false") emit(curcol, "nullable", "no", AL["nullable"])
      else if (v == "true") emit(curcol, "nullable", "yes", AL["nullable"])
      if (attr("primaryKey") == "true") emit(curcol, "nullable", "no", AL["primaryKey"])
    }
    return
  }
  tn = attr("tableName")
  if (nm == "createTable" && tn != "") emit("*", "entity-name", tn, ln)
  if (nm == "renameTable") hit = (norm(attr("oldTableName")) == E || norm(attr("newTableName")) == E)
  else hit = (tn != "" && norm(tn) == E)
  if (!hit) return
  emit("*", "found", "entity", ln)
  if (nm == "createTable" || nm == "addColumn") {
    if (!self) { inchg = 1; chg = nm; incol = 0 }
    return
  }
  if (nm == "addNotNullConstraint" || nm == "dropNotNullConstraint") {
    col = attr("columnName"); if (col == "") return
    column_found(col, ln)
    emit(norm(col), "nullable", (nm == "addNotNullConstraint" ? "no" : "yes"), ln)
    return
  }
  if (nm == "modifyDataType") {
    col = attr("columnName"); if (col == "") return
    column_found(col, ln)
    if (attr("newDataType") != "") addtype(norm(col), attr("newDataType"), LABEL FILENAME ":" AL["newDataType"])
    return
  }
  if (nm == "addPrimaryKey") {
    n = split(attr("columnNames"), P, ",")
    for (k = 1; k <= n; k++) {
      col = trim(P[k]); if (col == "") continue
      column_found(col, ln); emit(norm(col), "nullable", "no", AL["columnNames"])
    }
    return
  }
  if (nm in BENIGN) return
  emit("*", "unparsed", nm, ln)
}
BEGIN {
  E = ENVIRON["_ACP_E"]; LABEL = ENVIRON["_ACP_LABEL"]; nc = 0
  n = split("createIndex dropIndex addUniqueConstraint dropUniqueConstraint tableExists columnExists indexExists foreignKeyConstraintExists primaryKeyExists viewExists rowCount tableIsEmpty", B, " ")
  for (k = 1; k <= n; k++) BENIGN[B[k]] = 1
}
FNR == 1 { incom = 0; incdata = 0; intag = 0; q = ""; rb = 0; inchg = 0; incol = 0; srcdone = 0 }
{
  line = $0; sub(/\r$/, "", line); L = length(line); i = 1
  while (i <= L) {
    if (incom) { k = index(substr(line, i), "-->"); if (!k) { i = L + 1; continue } incom = 0; i += k + 2; continue }
    if (incdata) { k = index(substr(line, i), "]]>"); if (!k) { i = L + 1; continue } incdata = 0; i += k + 2; continue }
    c = substr(line, i, 1)
    if (intag) {
      if (q != "") { if (c == q) q = ""; tb = tb c; i++; continue }
      if (c == "\"" || c == "\047") { q = c; tb = tb c; i++; continue }
      if (c == ">") { intag = 0; tag(tb, tl); i++; continue }
      tb = tb c; i++; continue
    }
    if (c == "<") {
      if (substr(line, i, 4) == "<!--") { incom = 1; i += 4; continue }
      if (substr(line, i, 9) == "<![CDATA[") { incdata = 1; i += 9; continue }
      intag = 1; tb = ""; tl = FNR; i++; continue
    }
    i++
  }
  if (intag) tb = tb "\n"
}
END {
  for (k = 1; k <= nc; k++) {
    fk = COLS[k]; ok = 1
    for (j = 1; j <= TN[fk]; j++) if (intclass(TV[fk, j]) == "") ok = 0
    if (!ok) continue
    for (j = 1; j <= TN[fk]; j++) {
      cl = intclass(TV[fk, j])
      if (cl == "s") { mn = "-32768"; mx = "32767" }
      else if (cl == "i") { mn = "-2147483648"; mx = "2147483647" }
      else { mn = "-9223372036854775808"; mx = "9223372036854775807" }
      print fk "\tmin\t" mn "\t" TLOC[fk, j]
      print fk "\tmax\t" mx "\t" TLOC[fk, j]
    }
  }
}
'

# _planner_acpre_has_found <records> — rc 0 when a `found entity` record is there.
_planner_acpre_has_found() {
  grep -q "^\*"$'\t'"found"$'\t'"entity"$'\t' <<<"$1"
}

# _planner_acpre_facts_liquibase_xml <tree> <sub> <entity> <label> — raw
# records from the changelogs (files holding `databaseChangeLog`) among the
# candidates; when none names the table, from every changelog in the tree
# (capped at PLANNER_ACPRE_ENTITY_MAX_FILES).
_planner_acpre_facts_liquibase_xml() {
  local tree="$1" sub="$2" ent="$3" label="$4" out=""
  local -a files=()
  mapfile -t files < <(printf '%s\n' "${_PLANNER_ACPRE_CAND[@]}" | grep '\.xml$' | _planner_acpre_containing "$tree" databaseChangeLog)
  [ "${#files[@]}" -eq 0 ] || out=$(_planner_acpre_run_awk "$tree" "$label" "$ent" "$_PLANNER_ACPRE_AWK_LIQUIBASE" "${files[@]}")
  if ! _planner_acpre_has_found "$out" && [ -n "$sub" ]; then
    mapfile -t files < <(_planner_acpre_list "$tree" "" | grep '\.xml$' | _planner_acpre_containing "$tree" databaseChangeLog)
    if [ "${#files[@]}" -gt "$PLANNER_ACPRE_ENTITY_MAX_FILES" ]; then
      printf '*\tunchecked\tmore than %s changelog files in the repository\t-\n' "$PLANNER_ACPRE_ENTITY_MAX_FILES"
      return 0
    fi
    out=""
    [ "${#files[@]}" -eq 0 ] || out=$(_planner_acpre_run_awk "$tree" "$label" "$ent" "$_PLANNER_ACPRE_AWK_LIQUIBASE" "${files[@]}")
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

# _planner_acpre_facts_jpa <tree> <sub> <entity> <label> — raw records from the
# `@Entity` classes among the candidates; when none matches, from every
# `@Entity` file in the tree (capped at PLANNER_ACPRE_ENTITY_MAX_FILES).
_planner_acpre_facts_jpa() {
  local tree="$1" sub="$2" ent="$3" label="$4" out=""
  local -a files=()
  mapfile -t files < <(printf '%s\n' "${_PLANNER_ACPRE_CAND[@]}" | grep '\.java$' | _planner_acpre_containing "$tree" '@Entity')
  [ "${#files[@]}" -eq 0 ] || out=$(_planner_acpre_run_awk "$tree" "$label" "$ent" "$_PLANNER_ACPRE_AWK_JPA" "${files[@]}")
  if ! _planner_acpre_has_found "$out" && [ -n "$sub" ]; then
    mapfile -t files < <(_planner_acpre_list "$tree" "" | grep '\.java$' | _planner_acpre_containing "$tree" '@Entity')
    if [ "${#files[@]}" -gt "$PLANNER_ACPRE_ENTITY_MAX_FILES" ]; then
      printf '*\tunchecked\tmore than %s entity files in the repository\t-\n' "$PLANNER_ACPRE_ENTITY_MAX_FILES"
      return 0
    fi
    out=""
    [ "${#files[@]}" -eq 0 ] || out=$(_planner_acpre_run_awk "$tree" "$label" "$ent" "$_PLANNER_ACPRE_AWK_JPA" "${files[@]}")
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

# _planner_acpre_cache_key <text> — a file name for the cache.
_planner_acpre_cache_key() {
  printf '%s' "$1" | cksum | tr ' ' '-'
}

# _planner_acpre_entity_scan <tree> <sub> <entity> <label> — every raw record
# for one entity: the candidate list and its cap, then each extractor. Cached
# in PLANNER_ACPRE_CACHE_DIR when that directory exists, so one run computes
# one (tree, path, entity) once.
_planner_acpre_entity_scan() {
  local tree="$1" sub="$2" ent="$3" label="$4" cf="" target where fn n
  if [ -n "${PLANNER_ACPRE_CACHE_DIR:-}" ] && [ -d "$PLANNER_ACPRE_CACHE_DIR" ]; then
    cf="${PLANNER_ACPRE_CACHE_DIR}/scan-$(_planner_acpre_cache_key "${tree}|${sub}|${ent}|${label}")"
    if [ -f "$cf" ]; then
      cat "$cf"
      return 0
    fi
  fi
  {
    target="${tree}${sub:+/${sub}}"
    where="${label}${sub:+${label:+/}${sub}}"
    _PLANNER_ACPRE_CAND=()
    if [ -f "$target" ]; then
      case "$sub" in *.java | *.xml) _PLANNER_ACPRE_CAND=("$sub") ;; esac
    elif [ -d "$target" ]; then
      mapfile -t _PLANNER_ACPRE_CAND < <(_planner_acpre_list "$tree" "$sub")
    fi
    n="${#_PLANNER_ACPRE_CAND[@]}"
    if [ ! -e "$target" ]; then
      printf '*\tunchecked\tpath not found: %s\t-\n' "$where"
    elif [ "$n" -gt "$PLANNER_OWNERSHIP_CODE_MAX_FILES" ]; then
      printf '*\tunchecked\tmore than %s candidate files under %s\t-\n' "$PLANNER_OWNERSHIP_CODE_MAX_FILES" "$where"
    else
      for fn in $PLANNER_ACPRE_EXTRACTORS; do
        "$fn" "$tree" "$sub" "$ent" "$label"
      done
    fi
  } | LC_ALL=C awk '!seen[$0]++' >"${cf:-/dev/stdout}"
  [ -z "$cf" ] || cat "$cf"
}

# _planner_acpre_enum_decls <tree> <Type> — one line per `enum <Type>`
# declaration in the tree: <file>:<line>\t<ok|args>\t<constants>. Cached like
# the entity scan.
_planner_acpre_enum_decls() {
  local tree="$1" type="$2" cf="" f
  [[ "$type" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
  if [ -n "${PLANNER_ACPRE_CACHE_DIR:-}" ] && [ -d "$PLANNER_ACPRE_CACHE_DIR" ]; then
    cf="${PLANNER_ACPRE_CACHE_DIR}/enum-$(_planner_acpre_cache_key "${tree}|${type}")"
    if [ -f "$cf" ]; then
      cat "$cf"
      return 0
    fi
  fi
  {
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      # shellcheck disable=SC2016  # awk program, not shell
      (cd "$tree" && _ACP_T="$type" LC_ALL=C _planner_acpre_awk "$_PLANNER_ACPRE_AWK_ENUM" "$f") |
        while IFS= read -r l; do printf '%s:%s\n' "$f" "$l"; done
    done < <(_planner_acpre_list "$tree" "" | grep '\.java$' | _planner_acpre_containing "$tree" "enum")
  } >"${cf:-/dev/stdout}"
  [ -z "$cf" ] || cat "$cf"
}

# planner_acpre_facts <tree> <sub> <key> [<label>] — one line per fact for
# <entity>.<field>: <kind>\t<value>\t<loc>, <loc> `<label>/<path>:<line>`.
# Fact kinds (design D6): nullable no|yes, primitive <type>, enum <C1,C2,…>,
# enum-unchecked <reason>, min|max <n>, transient -, unparsed <element>.
# Markers, which are not facts: `found entity|field <loc>`, `source
# jpa|liquibase <loc>`, `entity-name|field-name <name> <loc>` (for nearest
# names), and `unchecked <reason> -` (cap hit, path not found).
planner_acpre_facts() {
  local tree="$1" sub="$2" key="$3" label="${4:-}" ent fld raw fk kind val loc
  local jtype="" jenum="" jconv=0 jloc="" decls n c2 c3
  ent=$(_planner_acpre_norm "${key%%.*}")
  fld=$(_planner_acpre_norm "${key#*.}")
  raw=$(_planner_acpre_entity_scan "$tree" "$sub" "$ent" "$label")
  [ -n "$raw" ] || return 0
  while IFS=$'\t' read -r fk kind val loc; do
    [ "$fk" = "*" ] || [ "$fk" = "$fld" ] || continue
    case "$kind" in
    jtype)
      jtype="${val##*.}"
      jloc="$loc"
      ;;
    jenum) jenum="$val" ;;
    jconvert) jconv=1 ;;
    *) printf '%s\t%s\t%s\n' "$kind" "$val" "$loc" ;;
    esac
  done <<<"$raw"
  [ -n "$jtype" ] || return 0
  decls=$(_planner_acpre_enum_decls "$tree" "$jtype")
  [ -n "$decls" ] || return 0
  n=$(grep -c . <<<"$decls")
  if [ "$jconv" -eq 1 ]; then
    printf 'enum-unchecked\t@Convert\t%s\n' "$jloc"
  elif [ "$n" -gt 1 ]; then
    printf 'enum-unchecked\tambiguous enum %s (%s declarations)\t%s\n' "$jtype" "$n" "$jloc"
  else
    IFS=$'\t' read -r _ c2 c3 <<<"$decls"
    if [ "$c2" = args ]; then
      printf 'enum-unchecked\tenum %s has constructor arguments\t%s\n' "$jtype" "$jloc"
    else
      case "$jenum" in
      STRING) printf 'enum\t%s\t%s\n' "${c3:--}" "$jloc" ;;
      ORDINAL) printf 'enum-unchecked\tordinal enum\t%s\n' "$jloc" ;;
      none) printf 'enum-unchecked\tno @Enumerated (ordinal by default)\t%s\n' "$jloc" ;;
      *) printf 'enum-unchecked\tunreadable @Enumerated argument\t%s\n' "$jloc" ;;
      esac
    fi
  fi
}

# ── Decision (design D8) ──────────────────────────────────────────────────────

# _planner_acpre_num_cmp <a> <b> — -1, 0 or 1, comparing two decimal strings
# (optional sign, digits, optional fraction) exactly, never as floating
# point; runs under mawk.
_planner_acpre_num_cmp() {
  # shellcheck disable=SC2016  # awk program, not shell
  _ACP_A="$1" _ACP_B="$2" LC_ALL=C _planner_acpre_awk '
    function canon(s,   k) {
      s = "" s; CN = 0
      if (substr(s, 1, 1) == "-") { CN = 1; s = substr(s, 2) } else if (substr(s, 1, 1) == "+") s = substr(s, 2)
      k = index(s, ".")
      if (k) { CI = substr(s, 1, k - 1); CF = substr(s, k + 1) } else { CI = s; CF = "" }
      sub(/^0+/, "", CI); sub(/0+$/, "", CF)
      if (CI == "" && CF == "") CN = 0
    }
    function mag(i1, f1, i2, f2) {
      if (length(i1) != length(i2)) return (length(i1) < length(i2)) ? -1 : 1
      if (i1 != i2) return (("x" i1) < ("x" i2)) ? -1 : 1
      while (length(f1) < length(f2)) f1 = f1 "0"
      while (length(f2) < length(f1)) f2 = f2 "0"
      if (f1 == f2) return 0
      return (("x" f1) < ("x" f2)) ? -1 : 1
    }
    BEGIN {
      canon(ENVIRON["_ACP_A"]); an = CN; ai = CI; af = CF
      canon(ENVIRON["_ACP_B"]); bn = CN; bi = CI; bf = CF
      if (an != bn) { print (an ? -1 : 1); exit }
      r = mag(ai, af, bi, bf)
      print (an ? -r : r)
    }'
}

# _planner_acpre_nearest <name> — up to three names from stdin close to
# <name>, comma-separated: first those equal after stripping one trailing `s`
# from each (item 6's OWN_NEAR_MATCH rule), then those sharing a normalised
# prefix of at least four characters, longest first. Names compare
# normalised (lower case, `_` removed); the first spelling seen is printed.
_planner_acpre_nearest() {
  # shellcheck disable=SC2016  # awk program, not shell
  _ACP_T="$1" LC_ALL=C _planner_acpre_awk '
    function norm(s) { s = tolower(s); gsub(/_/, "", s); return s }
    function strip1(s) { return (substr(s, length(s), 1) == "s") ? substr(s, 1, length(s) - 1) : s }
    function lcp(a, b,   i, L) {
      L = length(a); if (length(b) < L) L = length(b)
      for (i = 1; i <= L; i++) if (substr(a, i, 1) != substr(b, i, 1)) break
      return i - 1
    }
    BEGIN { t = norm(ENVIRON["_ACP_T"]); ts = strip1(t); r1 = 0; np = 0 }
    {
      n = norm($0)
      if (n == "" || (n in seen)) next
      seen[n] = 1
      if (n == t) next
      if (strip1(n) == ts) { R1[++r1] = $0; next }
      l = lcp(n, t)
      if (l >= 4) { np++; P[np] = $0; PL[np] = l }
    }
    END {
      for (i = 2; i <= np; i++) {
        v = P[i]; vl = PL[i]; j = i - 1
        while (j >= 1 && PL[j] < vl) { P[j + 1] = P[j]; PL[j + 1] = PL[j]; j-- }
        P[j + 1] = v; PL[j + 1] = vl
      }
      out = ""; c = 0
      for (i = 1; i <= r1 && c < 3; i++) { out = out (c ? ", " : "") R1[i]; c++ }
      for (i = 1; i <= np && c < 3; i++) { out = out (c ? ", " : "") P[i]; c++ }
      printf "%s", out
    }'
}

# planner_acpre_decide <requires> <facts> [<key>] — the decision for one
# `state` row with a `code:` Basis (design D8): `reachable`,
# `unreachable\t<kind>\t<value>\t<loc>` (the fact that forbids it) or
# `unchecked\t<reason>`. With <key>, a not-found reason lists up to three
# nearest names from the facts' name markers. A row is never unreachable
# without a positive Liquibase, @Id or enum fact.
planner_acpre_decide() {
  local req="$1" facts="$2" key="${3:-}" kind val loc near
  local unchecked="" ent=0 fld=0 trans="" unparsed="" nn="" ny="" prim="" primloc=""
  local enumu="" enumv="" enumloc="" nenum=0 v c r
  local -a mins=() maxs=() minloc=() maxloc=() enames=() fnames=()
  while IFS=$'\t' read -r kind val loc; do
    case "$kind" in
    unchecked) [ -n "$unchecked" ] || unchecked="$val" ;;
    found) if [ "$val" = entity ]; then ent=1; else fld=1; fi ;;
    entity-name) enames+=("$val") ;;
    field-name) fnames+=("$val") ;;
    transient) [ -n "$trans" ] || trans="$loc" ;;
    unparsed) [ -n "$unparsed" ] || unparsed="${val}"$'\t'"${loc}" ;;
    nullable) if [ "$val" = no ]; then [ -n "$nn" ] || nn="$loc"; else [ -n "$ny" ] || ny="$loc"; fi ;;
    primitive)
      prim="$val"
      primloc="$loc"
      ;;
    enum)
      nenum=$((nenum + 1))
      enumv="$val"
      enumloc="$loc"
      ;;
    enum-unchecked) [ -n "$enumu" ] || enumu="${val} at ${loc}" ;;
    min)
      mins+=("$val")
      minloc+=("$loc")
      ;;
    max)
      maxs+=("$val")
      maxloc+=("$loc")
      ;;
    esac
  done <<<"$facts"
  if [ -n "$unchecked" ]; then
    printf 'unchecked\t%s\n' "$unchecked"
    return 0
  fi
  if [ "$ent" -eq 0 ]; then
    near=""
    [ -z "$key" ] || [ "${#enames[@]}" -eq 0 ] || near=$(printf '%s\n' "${enames[@]}" | _planner_acpre_nearest "${key%%.*}")
    printf 'unchecked\tentity not found%s\n' "${near:+; nearest: ${near}}"
    return 0
  fi
  case "$req" in
  value:*) ;;
  *)
    if [ -n "$unparsed" ]; then
      printf 'unchecked\tchangelog has an unparsed change (%s) at %s\n' "${unparsed%%$'\t'*}" "${unparsed#*$'\t'}"
      return 0
    fi
    ;;
  esac
  if [ "$fld" -eq 0 ]; then
    near=""
    [ -z "$key" ] || [ "${#fnames[@]}" -eq 0 ] || near=$(printf '%s\n' "${fnames[@]}" | _planner_acpre_nearest "${key#*.}")
    printf 'unchecked\tfield not found%s\n' "${near:+; nearest: ${near}}"
    return 0
  fi
  if [ -n "$trans" ]; then
    printf 'unchecked\ttransient or computed field at %s\n' "$trans"
    return 0
  fi
  case "$req" in
  null)
    if [ -n "$nn" ] && [ -n "$ny" ]; then
      printf 'unchecked\tnullable facts disagree (%s, %s)\n' "$nn" "$ny"
    elif [ -n "$nn" ]; then
      printf 'unreachable\tnullable\tno\t%s\n' "$nn"
    elif [ -n "$prim" ] && [ -n "$ny" ]; then
      printf 'unchecked\tprimitive %s on a nullable column at %s\n' "$prim" "$primloc"
    elif [ -n "$prim" ]; then
      printf 'unchecked\tonly a primitive type (%s) at %s\n' "$prim" "$primloc"
    else
      printf 'reachable\n'
    fi
    ;;
  value:*)
    if [ -n "$enumu" ]; then
      printf 'unchecked\t%s\n' "$enumu"
    elif [ "$nenum" -eq 0 ]; then
      printf 'unchecked\tnot an enum\n'
    elif [ "$nenum" -gt 1 ]; then
      printf 'unchecked\tenum facts disagree\n'
    else
      v=$(_planner_acpre_norm "${req#value:}")
      r=unreachable
      IFS=, read -r -a cs <<<"$enumv"
      for c in "${cs[@]}"; do
        [ "$(_planner_acpre_norm "$c")" = "$v" ] && r=reachable
      done
      if [ "$r" = reachable ]; then
        printf 'reachable\n'
      else
        printf 'unreachable\tenum\t%s\t%s\n' "$enumv" "$enumloc"
      fi
    fi
    ;;
  number:*)
    v="${req#number:}"
    if [ "${#mins[@]}" -eq 0 ] || [ "${#maxs[@]}" -eq 0 ]; then
      printf 'unchecked\tno integer column type\n'
    elif [ "$(printf '%s\n' "${mins[@]}" | LC_ALL=C sort -u | grep -c .)" -gt 1 ] ||
      [ "$(printf '%s\n' "${maxs[@]}" | LC_ALL=C sort -u | grep -c .)" -gt 1 ]; then
      printf 'unchecked\tinteger types disagree\n'
    elif [ "$(_planner_acpre_num_cmp "$v" "${mins[0]}")" = -1 ]; then
      printf 'unreachable\tmin\t%s\t%s\n' "${mins[0]}" "${minloc[0]}"
    elif [ "$(_planner_acpre_num_cmp "$v" "${maxs[0]}")" = 1 ]; then
      printf 'unreachable\tmax\t%s\t%s\n' "${maxs[0]}" "${maxloc[0]}"
    else
      printf 'reachable\n'
    fi
    ;;
  *) printf 'unchecked\tunknown requirement\n' ;;
  esac
}

# planner_acpre_check_row <INIT> <code-path> <key> <requires> — one `state`
# row with Basis `code:<code-path>`, end to end: resolve the tree
# (planner_ownership_code_target), read the facts, decide. Prints
# <pin>\t<sources>\t<decision>, where <pin> is pinned|live|pin-failed (`-`
# when the path did not resolve), <sources> the comma-joined source markers
# seen (`jpa`, `liquibase`; `none` when the scan found neither, `-` when no
# scan ran), and <decision> planner_acpre_decide's line. A pin-failed tree
# is unchecked (design D4).
planner_acpre_check_row() {
  local init="$1" path="$2" key="$3" req="$4" out err tree rest sub pin label facts src d
  if ! out=$(planner_ownership_code_target "$init" "$path" 2>/dev/null); then
    err=$(planner_ownership_code_target "$init" "$path" 2>&1 >/dev/null | head -1)
    printf -- '-\t-\tunchecked\t%s\n' "${err:-repository not found}"
    return 0
  fi
  tree="${out%%$'\t'*}"
  rest="${out#*$'\t'}"
  sub="${rest%$'\t'*}"
  pin="${rest##*$'\t'}"
  if [ "$pin" = pin-failed ]; then
    printf 'pin-failed\t-\tunchecked\tthe pinned worktree could not be created\n'
    return 0
  fi
  sub="${sub%/}"
  path="${path%/}"
  label="$path"
  [ -z "$sub" ] || label="${path%/"$sub"}"
  facts=$(planner_acpre_facts "$tree" "$sub" "$key" "$label")
  if grep -q "^unchecked"$'\t' <<<"$facts"; then
    src=-
  else
    src=$(grep "^source"$'\t' <<<"$facts" | cut -f2 | LC_ALL=C sort -u | paste -sd, -)
    src="${src:-none}"
  fi
  d=$(planner_acpre_decide "$req" "$facts" "$key")
  printf '%s\t%s\t%s\n' "$pin" "$src" "$d"
}
