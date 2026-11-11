#!/usr/bin/env bash
# planner-specify-params.sh — the parameter registry in proposal.md
# (planner-specify-parameters).
#
# Specify declares every value the plan depends on, that someone could choose
# differently, once per initiative, as one pipe table under `## Parameters` in
# artifacts/proposal.md:
#
#   | Name | Key | Kind | Default | Value | Source |
#
# This file is the bash that reads it: which rows are valid, which sources
# verify, which rows are open (and so asked through the SPECIFY_DECISION
# round), the unit-literal tokenizer the anchors, intake and Crosscheck share,
# and the row rendering and substitution answer intake uses.
#
# Functions:
#   planner_params_contract_mark <INIT>        append META|contract|start|
#                                              specify-parameters-v1 once
#   planner_params_contract_initiative <INIT>  rc 0 when that line is present
#   planner_params_rows <INIT> [file]          one line per valid row:
#                                              <line>\t<key>\t<kind>\t<name>\t<default>\t<value>\t<source>
#                                              (cells unescaped; default may be empty)
#   planner_params_invalid <INIT> [file]       one line per problem: <line>\t<reason>;
#                                              reason is one of missing (line 0) |
#                                              empty | no-table | duplicate-section |
#                                              header | shape | name | key |
#                                              duplicate-key | kind | value | source
#   planner_params_anchor_ok <INIT> <key> <value> <source>
#                                              rc 0 the source verifies, 1 it does not
#   planner_params_keyword_kind <name> <key>   the must-ask kind the keyword table
#                                              implies, or nothing
#   planner_params_scan <INIT> [file]          one line per open row, table order:
#                                              <key>\t<line>\t<kind>\t<name>\t<suggestion>\t<question>
#                                              Prints nothing for a legacy (non-contract)
#                                              initiative. rc 0 (also: no proposal),
#                                              1 cannot read
#   planner_params_literals <file|->           one line per unit literal:
#                                              <line>\t<canonical>\t<literal text>
#   _planner_params_canon <text>               the canonical form of <text> when it
#                                              tokenises to exactly one literal; rc 1 else
#   planner_params_render_row <name> <key> <kind> <default> <value> <round> <role>
#                                              the answered row line; rc 1 bad round/role
#   planner_params_substitute <INIT> <src> <out> <line_no> <key> <rendered>
#                                              write <src> with line <line_no> replaced
#                                              to <out>; rc 0 ok, 1 I/O or usage, 2 the
#                                              line is no longer the open row for <key>
#
# Parsing <TAB> output: the default and suggestion columns may be empty. Bash
# `read` with IFS=$'\t' collapses empty fields (tab is IFS whitespace), so read
# these lines with `awk -F'\t'` or `cut -f`, never with `IFS=$'\t' read`.
#
# Values reach awk only through ENVIRON. Every awk program here runs under
# LC_ALL=C with no regex intervals, so mawk runs it; lengths are checked in
# bash. `PLANNER_PARAMS_AWK` (default `awk`) names the interpreter, so the
# tests can run each program under mawk and gawk.
#
# Sourceable library. No set -euo pipefail at file scope (repo convention for
# this directory).

_PLANNER_SPECIFY_PARAMS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f planner_state_log >/dev/null 2>&1 ||
  source "${_PLANNER_SPECIFY_PARAMS_DIR}/planner-state.sh"
declare -f _planner_specify_neutralise >/dev/null 2>&1 ||
  source "${_PLANNER_SPECIFY_PARAMS_DIR}/planner-specify-decisions.sh"

PLANNER_PARAMS_CONTRACT="specify-parameters-v1"
PLANNER_PARAMS_KINDS="policy rounding transaction failure fixed duration limit size"
PLANNER_PARAMS_MUST_ASK_KINDS="policy rounding transaction failure fixed"
PLANNER_PARAMS_ARTIFACTS="idea intent appraisal discovery architecture"
PLANNER_PARAMS_KEY_MAX=64
PLANNER_PARAMS_QUOTE_MIN=8
PLANNER_PARAMS_QUOTE_MAX=300

# The unit list (design D7), one `<word>:<class>:<multiplier>` entry each. It
# is added by this change on purpose, not derived from
# PLANNER_TESTDATA_UNIT_DENYLIST, which answers a different question (review
# round 1, C4). The tokenizer matches each word case-insensitively, singular
# or with an `s`; `retries` is spelled out. `businessday` and `dp` stand for
# the two-word units `business day` and `decimal place`, and `pct` for `%`:
# none of the three is reachable as a single word. Count words (`thread`,
# `connection`, `worker`, `request`, `time`, `try`, `px`) are left out, so a
# count assertion never blocks (review round 1, F3). Canonical classes: time
# in ms, month (year = 12), size in bytes (1024-based), pct in hundredths of
# a percent, attempt, char and dp as counts.
PLANNER_PARAMS_UNITS="ms:time:1 millisecond:time:1 s:time:1000 sec:time:1000 second:time:1000 min:time:60000 minute:time:60000 h:time:3600000 hr:time:3600000 hour:time:3600000 d:time:86400000 day:time:86400000 businessday:time:86400000 week:time:604800000 month:month:1 year:month:12 byte:size:1 kb:size:1024 mb:size:1048576 gb:size:1073741824 tb:size:1099511627776 percent:pct:100 pct:pct:100 attempt:attempt:1 retry:attempt:1 character:char:1 char:char:1 dp:dp:1"

# Keyword cross-check (design D2): one line per implied must-ask kind, then
# its token prefixes. Matched by prefix against the row's Name words and its
# Key split on `._-`, lowercased. `timeout` and `pool` are left out on
# purpose: they imply tuning kinds, which never open a row.
PLANNER_PARAMS_KIND_KEYWORDS="rounding round decimal precision
failure retry retries attempt backoff fallback deadletter dead-letter fail
transaction rollback transaction atomic commit idempot
policy refund fee price pricing trial retention grace quota penalty interest discount tax"

_planner_params_awk() {
  "${PLANNER_PARAMS_AWK:-awk}" "$@"
}

# ── Contract marker ───────────────────────────────────────────────────────────

planner_params_contract_initiative() {
  local log
  log=$(planner_state_log "$1" 2>/dev/null) || return 1
  [ -f "$log" ] || return 1
  grep -q "^[^|]*|META|contract|start|${PLANNER_PARAMS_CONTRACT}\$" "$log" 2>/dev/null
}

planner_params_contract_mark() {
  local init="$1"
  planner_params_contract_initiative "$init" && return 0
  planner_state_write "$init" META contract start "$PLANNER_PARAMS_CONTRACT"
}

# ── Table parse ───────────────────────────────────────────────────────────────

# _planner_params_table_awk <file> — the one structural pass. Fields are
# separated by \037 (not a tab: bash `read` keeps empty fields only with a
# non-whitespace IFS). Records:
#   S <line>                  the first `## Parameters` heading
#   D <line>                  a later `## Parameters` heading
#   N <line>                  `None.`
#   X <line>                  other content where the table should start
#   H <line> ok|bad           the header row
#   R <line> <n> <c1>..<cn>   a data row, cells trimmed and unescaped
_planner_params_table_awk() {
  # shellcheck disable=SC2016  # awk program, not shell
  LC_ALL=C _planner_params_awk '
    function fence_char(s) {
      sub(/^(   |  | )?/, "", s)
      if (substr(s, 1, 3) == "```") return "`"
      if (substr(s, 1, 3) == "~~~") return "~"
      return ""
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # Split a trimmed row (it starts with "|") into C[1..n]; returns n.
    # A backslash before a pipe makes the pipe part of the cell.
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
    BEGIN { US = "\037"; fence = ""; in_sec = 0; seen = 0; tstate = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      fc = fence_char(line)
      if (fence != "") { if (fc == fence) fence = ""; next }
      if (fc != "") { fence = fc; next }

      if (line ~ /^## Parameters[ \t]*$/) {
        if (seen) { print "D" US NR; in_sec = 0; next }
        seen = 1; in_sec = 1; tstate = 0
        print "S" US NR
        next
      }
      if (line ~ /^#[ \t]/ || line ~ /^#$/ || line ~ /^##[ \t]/ || line ~ /^##$/) { in_sec = 0; next }
      if (!in_sec || tstate == 3) next

      t = trim(line)
      if (t == "") { if (tstate > 0) tstate = 3; next }
      if (tstate == 0) {
        if (substr(t, 1, 1) == "|") {
          n = cells(t); h = ""
          for (k = 1; k <= n; k++) h = h (k > 1 ? "|" : "") tolower(C[k])
          print "H" US NR US (h == "name|key|kind|default|value|source" ? "ok" : "bad")
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
      for (k = 1; k <= n; k++) out = out US C[k]
      print out
    }
  ' <"$1"
}

# _planner_params_file <INIT> [file] — the file to read: the given one, else
# the initiative's proposal. rc as _planner_specify_proposal (0 ok, 2 absent,
# 1 cannot resolve or read).
_planner_params_file() {
  if [ -n "${2:-}" ]; then
    printf '%s\n' "$2"
    [ -e "$2" ] || return 2
    { [ -f "$2" ] && [ -r "$2" ]; } || return 1
    return 0
  fi
  _planner_specify_proposal "$1"
}

_planner_params_in_list() {
  local w="$1" x
  for x in $2; do [ "$x" = "$w" ] && return 0; done
  return 1
}

_planner_params_is_marker() {
  [[ "$1" == "${PLANNER_SPECIFY_MARKER}"* ]]
}

# _planner_params_source_ok <source> <value> — the Source grammar (design D2).
_planner_params_source_ok() {
  local s="$1" v="$2" art rest path n
  case "$s" in
  default) return 0 ;;
  "—" | "–" | "-")
    _planner_params_is_marker "$v"
    return
    ;;
  human:*)
    [[ "$s" =~ ^human:r[1-9][0-9]*:(client|operator)$ ]]
    return
    ;;
  code:*)
    rest="${s#code:}"
    [[ "$rest" == *':"'*'"' ]] || return 1
    path="${rest%%:\"*}"
    [ -n "$path" ] || return 1
    case "$path" in /* | ~*) return 1 ;; esac
    case "/${path}/" in */../*) return 1 ;; esac
    return 0
    ;;
  esac
  art="${s%%:*}"
  [ "$art" != "$s" ] || return 1
  _planner_params_in_list "$art" "$PLANNER_PARAMS_ARTIFACTS" || return 1
  rest="${s#*:}"
  n=${#rest}
  [ "$n" -ge 2 ] || return 1
  [[ "$rest" == '"'*'"' ]]
}

# _planner_params_classify <INIT> [file] — rows and problems in one pass.
# Prints V<US><line><US><key><US><kind><US><name><US><default><US><value><US><source>
# and I<US><line><US><reason>. rc 0, 2 no proposal, 1 cannot read.
_planner_params_classify() {
  local init="$1" f rc=0 raw rec ln n kind name key def val src
  local -a F
  local -A keys=()
  local US=$'\037' sec="" hdr="" body=0 bad_hdr=0
  f=$(_planner_params_file "$init" "${2:-}") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  raw=$(_planner_params_table_awk "$f") || return 1
  while IFS=$'\037' read -r -a F; do
    [ "${#F[@]}" -gt 0 ] || continue
    rec="${F[0]}"
    ln="${F[1]}"
    case "$rec" in
    S) sec="$ln" ;;
    D) printf 'I%s%s%sduplicate-section\n' "$US" "$ln" "$US" ;;
    N) body=1 ;;
    X)
      body=1
      printf 'I%s%s%sno-table\n' "$US" "$ln" "$US"
      ;;
    H)
      body=1
      hdr="$ln"
      if [ "${F[2]}" != "ok" ]; then
        bad_hdr=1
        printf 'I%s%s%sheader\n' "$US" "$ln" "$US"
      fi
      ;;
    R)
      if [ "$bad_hdr" -eq 1 ]; then
        printf 'I%s%s%sheader\n' "$US" "$ln" "$US"
        continue
      fi
      n="${F[2]}"
      if [ "$n" != 6 ]; then
        printf 'I%s%s%sshape\n' "$US" "$ln" "$US"
        continue
      fi
      name="${F[3]:-}" key="${F[4]:-}" kind="${F[5]:-}" def="${F[6]:-}" val="${F[7]:-}" src="${F[8]:-}"
      kind=$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')
      if [ -z "$name" ]; then
        printf 'I%s%s%sname\n' "$US" "$ln" "$US"
        continue
      fi
      if [[ "$key" != '`'*'`' ]]; then
        printf 'I%s%s%skey\n' "$US" "$ln" "$US"
        continue
      fi
      key="${key#\`}"
      key="${key%\`}"
      if [ "${#key}" -gt "$PLANNER_PARAMS_KEY_MAX" ] || ! [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_.-]*$ ]]; then
        printf 'I%s%s%skey\n' "$US" "$ln" "$US"
        continue
      fi
      if [ -n "${keys[$key]:-}" ]; then
        printf 'I%s%s%sduplicate-key\n' "$US" "$ln" "$US"
        continue
      fi
      keys[$key]="$ln"
      if ! _planner_params_in_list "$kind" "$PLANNER_PARAMS_KINDS"; then
        printf 'I%s%s%skind\n' "$US" "$ln" "$US"
        continue
      fi
      case "$val" in
      "" | "—" | "–" | "-")
        printf 'I%s%s%svalue\n' "$US" "$ln" "$US"
        continue
        ;;
      esac
      if ! _planner_params_source_ok "$src" "$val"; then
        printf 'I%s%s%ssource\n' "$US" "$ln" "$US"
        continue
      fi
      printf 'V%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$US" "$ln" "$US" "$key" "$US" "$kind" "$US" "$name" \
        "$US" "$def" "$US" "$val" "$US" "$src"
      ;;
    esac
  done <<<"$raw"
  if [ -z "$sec" ]; then
    printf 'I%s0%smissing\n' "$US" "$US"
  elif [ "$body" -eq 0 ] && [ -z "$hdr" ]; then
    printf 'I%s%s%sempty\n' "$US" "$sec" "$US"
  fi
  return 0
}

planner_params_rows() {
  local out rc=0
  out=$(_planner_params_classify "$1" "${2:-}") || rc=$?
  [ "$rc" -eq 2 ] && return 0
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$out" | awk -F'\037' -v OFS='\t' '$1 == "V" { print $2, $3, $4, $5, $6, $7, $8 }'
  return 0
}

planner_params_invalid() {
  local out rc=0
  out=$(_planner_params_classify "$1" "${2:-}") || rc=$?
  if [ "$rc" -eq 2 ]; then
    printf '0\tmissing\n'
    return 0
  fi
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$out" | awk -F'\037' -v OFS='\t' '$1 == "I" { print $2, $3 }'
  return 0
}

# ── Literals ──────────────────────────────────────────────────────────────────

# planner_params_literals <file|-> — unit literals (design D7). A decimal
# number (30, 1.5, 2,000) followed by optional whitespace and a unit word, a
# hyphen and a unit word, a glued unit, or `%`. Never a literal: the value 0,
# 100%, a four-digit decade (1990s), anything in a fence, an inline code span,
# a link target or a URL, and a leading criterion label (`- [ ] 10h.`).
#
# Canonical form <class>:<integer>: time in ms (d and business day = 1 day),
# month (year = 12), size in bytes (1024-based), pct in hundredths of a
# percent, attempt, char and dp (decimal places) as counts.
planner_params_literals() {
  local f="${1:--}"
  # shellcheck disable=SC2016  # awk program, not shell
  LC_ALL=C PLANNER_PARAMS_UNITS="$PLANNER_PARAMS_UNITS" _planner_params_awk '
    function fence_char(s) {
      sub(/^(   |  | )?/, "", s)
      if (substr(s, 1, 3) == "```") return "`"
      if (substr(s, 1, 3) == "~~~") return "~"
      return ""
    }
    function isdigit(c) { return c != "" && index("0123456789", c) > 0 }
    function isalpha(c) { return c != "" && index("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", c) > 0 }
    function isword(c) { return isdigit(c) || isalpha(c) || c == "_" }
    function blank(n,   s) { s = ""; while (n-- > 0) s = s " "; return s }
    # The unit a word names, or "".
    function unit_of(w,   b) {
      w = tolower(w)
      if (w in CLS) return w
      if (w == "retries") return "retry"
      b = substr(w, 1, length(w) - 1)
      if (length(w) > 1 && substr(w, length(w)) == "s" && (b in CLS)) return b
      return ""
    }
    # Read a run of letters starting at p; sets WEND (index after it).
    function word_at(s, p,   q) {
      q = p
      while (isalpha(substr(s, q, 1))) q++
      WEND = q
      return substr(s, p, q - p)
    }
    function skip_ws(s, p) {
      while (substr(s, p, 1) == " " || substr(s, p, 1) == "\t") p++
      return p
    }
    BEGIN {
      fence = ""
      n = split(ENVIRON["PLANNER_PARAMS_UNITS"], U, " ")
      for (k = 1; k <= n; k++) {
        split(U[k], P, ":")
        CLS[P[1]] = P[2]; MUL[P[1]] = P[3]
      }
      # Two-word units and the % sign are not reachable as a single word.
      delete CLS["businessday"]; delete CLS["dp"]; delete CLS["pct"]
      XCLS["businessday"] = "time"; XMUL["businessday"] = 86400000
      XCLS["dp"] = "dp"; XMUL["dp"] = 1
      XCLS["pct"] = "pct"; XMUL["pct"] = 100
      for (u in CLS) { XCLS[u] = CLS[u]; XMUL[u] = MUL[u] }
    }
    {
      line = $0
      sub(/\r$/, "", line)
      fc = fence_char(line)
      if (fence != "") { if (fc == fence) fence = ""; next }
      if (fc != "") { fence = fc; next }

      # Inline code spans, link targets and URLs are never prose.
      while (match(line, /`[^`]*`/)) line = substr(line, 1, RSTART - 1) blank(RLENGTH) substr(line, RSTART + RLENGTH)
      while (match(line, /\]\([^)]*\)/)) line = substr(line, 1, RSTART) blank(RLENGTH - 1) substr(line, RSTART + RLENGTH)
      while (match(line, /[A-Za-z][A-Za-z0-9+.-]*:\/\/[^ \t]*/)) line = substr(line, 1, RSTART - 1) blank(RLENGTH) substr(line, RSTART + RLENGTH)
      while (match(line, /www\.[^ \t]*/)) line = substr(line, 1, RSTART - 1) blank(RLENGTH) substr(line, RSTART + RLENGTH)

      # A leading criterion label: digits, at most one letter, then . ) or :
      # and whitespace or the end of the line.
      if (match(line, /^[ \t]*[-*+][ \t]+\[[ xX]\][ \t]+/)) {
        p = RSTART + RLENGTH; q = p
        while (isdigit(substr(line, q, 1))) q++
        if (q > p) {
          if (isalpha(substr(line, q, 1))) q++
          c = substr(line, q, 1)
          if ((c == "." || c == ")" || c == ":") && (substr(line, q + 1, 1) == "" || substr(line, q + 1, 1) == " " || substr(line, q + 1, 1) == "\t"))
            line = substr(line, 1, p - 1) blank(q - p + 1) substr(line, q + 1)
        }
      }

      L = length(line); i = 1
      while (i <= L) {
        c = substr(line, i, 1)
        pc = (i > 1) ? substr(line, i - 1, 1) : ""
        # Not the start of a number: inside a word, after a decimal point, or
        # the tail of a comma decimal (1,5 hours).
        if (!isdigit(c) || isword(pc) || pc == "." || (pc == "," && isdigit(substr(line, i - 2, 1)))) { i++; continue }
        j = i
        while (isdigit(substr(line, j, 1))) j++
        intpart = substr(line, i, j - i)
        while (substr(line, j, 1) == "," && isdigit(substr(line, j + 1, 1)) && isdigit(substr(line, j + 2, 1)) && isdigit(substr(line, j + 3, 1)) && !isdigit(substr(line, j + 4, 1))) j += 4
        if (substr(line, j, 1) == "." && isdigit(substr(line, j + 1, 1))) { j++; while (isdigit(substr(line, j, 1))) j++ }
        numtext = substr(line, i, j - i)
        num = numtext; gsub(/,/, "", num); num = num + 0

        u = ""; e = j; glued = 0
        c = substr(line, j, 1)
        if (c == "%") { u = "pct"; e = j + 1 }
        else if (c == "-" && isalpha(substr(line, j + 1, 1))) {
          w = word_at(line, j + 1); u = unit_of(w); e = WEND
        } else if (isalpha(c)) {
          w = word_at(line, j); u = unit_of(w); e = WEND; glued = 1
        } else if (c == " " || c == "\t") {
          k = skip_ws(line, j)
          if (isalpha(substr(line, k, 1))) {
            w = tolower(word_at(line, k)); e = WEND
            if (w == "business" || w == "decimal") {
              k2 = skip_ws(line, e)
              w2 = tolower(word_at(line, k2))
              if (w == "business" && (w2 == "day" || w2 == "days") && k2 > e) { u = "businessday"; e = WEND }
              else if (w == "decimal" && (w2 == "place" || w2 == "places") && k2 > e) { u = "dp"; e = WEND }
            } else u = unit_of(w)
          }
        }
        if (u != "" && (isdigit(substr(line, e, 1)) || substr(line, e, 1) == "_")) u = ""
        if (u != "" && glued && u == "s" && numtext ~ /^[0-9][0-9][0-9]0$/) u = ""
        if (u != "" && num == 0) u = ""
        if (u != "" && XCLS[u] == "pct" && num == 100) u = ""
        if (u == "") { i = j; continue }
        v = int(num * XMUL[u] + 0.5)
        printf "%d\t%s:%.0f\t%s\n", NR, XCLS[u], v, substr(line, i, e - i)
        i = e
      }
    }
  ' "$f"
}

_planner_params_canon() {
  local out n
  out=$(printf '%s\n' "$1" | planner_params_literals -) || return 1
  [ -n "$out" ] || return 1
  n=$(printf '%s\n' "$out" | grep -c .)
  [ "$n" -eq 1 ] || return 1
  printf '%s\n' "$out" | cut -f2
}

# ── Anchors ───────────────────────────────────────────────────────────────────

# _planner_params_norm — whitespace runs (newlines included) to one space,
# trimmed. stdin → stdout, no trailing newline.
_planner_params_norm() {
  tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

planner_params_anchor_ok() {
  local init="$1" key="$2" value="$3" src="$4" dir art rest quote file path n
  local vlits qlits c rf role
  dir=$(planner_initiative_dir "$init" 2>/dev/null) || return 1
  case "$src" in
  human:*)
    [[ "$src" =~ ^human:r([1-9][0-9]*):(client|operator)$ ]] || return 1
    n="${BASH_REMATCH[1]}"
    role="${BASH_REMATCH[2]}"
    rf="${dir}/artifacts/answers/round-${n}.json"
    [ -f "$rf" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local v
    while IFS= read -r -d '' v; do
      [ "$(_planner_specify_neutralise "$v")" = "$value" ] && return 0
    done < <(jq -j --arg b "specify-param:${key}" --arg role "$role" \
      '(.answers // [])[] | select(.binding == $b and .role == $role) | (.value // "" | tostring), "\u0000"' \
      "$rf" 2>/dev/null)
    return 1
    ;;
  code:*)
    rest="${src#code:}"
    path="${rest%%:\"*}"
    quote="${rest#*:\"}"
    quote="${quote%\"}"
    case "$path" in /* | ~* | "") return 1 ;; esac
    case "/${path}/" in */../*) return 1 ;; esac
    file="$(planner_repos_root 2>/dev/null)/${path}" || return 1
    ;;
  *:*)
    art="${src%%:*}"
    _planner_params_in_list "$art" "$PLANNER_PARAMS_ARTIFACTS" || return 1
    quote="${src#*:}"
    [[ "$quote" == '"'*'"' ]] || return 1
    quote="${quote#\"}"
    quote="${quote%\"}"
    if [ "$art" = idea ]; then file="${dir}/artifacts/idea.txt"; else file="${dir}/artifacts/${art}.md"; fi
    ;;
  *) return 1 ;;
  esac
  quote=$(printf '%s' "$quote" | _planner_params_norm)
  n=${#quote}
  { [ "$n" -ge "$PLANNER_PARAMS_QUOTE_MIN" ] && [ "$n" -le "$PLANNER_PARAMS_QUOTE_MAX" ]; } || return 1
  { [ -f "$file" ] && [ -r "$file" ]; } || return 1
  # shellcheck disable=SC2016  # awk program, not shell
  _PSP_HAY="$(_planner_params_norm <"$file")" _PSP_NEEDLE="$quote" LC_ALL=C _planner_params_awk \
    'BEGIN { exit !(index(ENVIRON["_PSP_HAY"], ENVIRON["_PSP_NEEDLE"]) > 0) }' || return 1
  # A numeric Value must be stated by the quote itself.
  vlits=$(printf '%s\n' "$value" | planner_params_literals - | cut -f2)
  [ -n "$vlits" ] || return 0
  qlits=$(printf '%s\n' "$quote" | planner_params_literals - | cut -f2)
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    grep -qxF -- "$c" <<<"$qlits" || return 1
  done <<<"$vlits"
  return 0
}

# ── Open rows ─────────────────────────────────────────────────────────────────

planner_params_keyword_kind() {
  local name="$1" key="$2" toks tok line kind p
  toks="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]') $(printf '%s' "$key" | tr '[:upper:]' '[:lower:]' | tr '._-' '   ')"
  while IFS= read -r line; do
    kind="${line%% *}"
    for tok in $toks; do
      for p in ${line#* }; do
        if [[ "$tok" == "$p"* ]]; then
          printf '%s\n' "$kind"
          return 0
        fi
      done
    done
  done <<<"$PLANNER_PARAMS_KIND_KEYWORDS"
  return 0
}

# _planner_params_marker_question <value> <name>
_planner_params_marker_question() {
  local r="${1#"$PLANNER_SPECIFY_MARKER"}" name="$2" sep
  r="${r#"${r%%[![:space:]]*}"}"
  for sep in "—" "–" "--" "-" ":"; do
    if [[ "$r" == "$sep"* ]]; then
      r="${r#"$sep"}"
      break
    fi
  done
  r="${r//\`/}"
  r=$(printf '%s' "$r" | tr -s ' \t' '  ')
  r="${r#"${r%%[![:space:]]*}"}"
  r="${r%"${r##*[![:space:]]}"}"
  [ -n "$r" ] || r="(no question was written — what should ${name} be?)"
  printf '%s' "$r"
}

planner_params_scan() {
  local init="$1" rows line ln key kind name def val src implied sugg q
  planner_params_contract_initiative "$init" || return 0
  rows=$(planner_params_rows "$init" "${2:-}") || return 1
  [ -n "$rows" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ln=$(cut -f1 <<<"$line")
    key=$(cut -f2 <<<"$line")
    kind=$(cut -f3 <<<"$line")
    name=$(cut -f4 <<<"$line")
    def=$(cut -f5 <<<"$line")
    val=$(cut -f6 <<<"$line")
    src=$(cut -f7- <<<"$line")
    sugg=""
    case "$def" in "" | "—" | "–" | "-") ;; *) sugg="$def" ;; esac
    if _planner_params_is_marker "$val"; then
      q=$(_planner_params_marker_question "$val" "$name")
    else
      [ -n "$sugg" ] || sugg="$val"
      implied=$(planner_params_keyword_kind "$name" "$key")
      if ! _planner_params_in_list "$kind" "$PLANNER_PARAMS_MUST_ASK_KINDS" && [ -z "$implied" ]; then
        continue
      fi
      if [ "$src" != default ] && planner_params_anchor_ok "$init" "$key" "$val" "$src"; then
        continue
      fi
      q="Specify assumed \"${val}\" — is that right?"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$ln" "$kind" "$name" "$sugg" "$q"
  done <<<"$rows"
  return 0
}

# ── Rendering and substitution ────────────────────────────────────────────────

# _planner_params_cell <text> — one table cell: neutralised, pipes escaped.
_planner_params_cell() {
  local v
  v=$(_planner_specify_neutralise "$1")
  printf '%s' "${v//|/\\|}"
}

planner_params_render_row() {
  local name="$1" key="$2" kind="$3" def="$4" value="$5" round="$6" role="$7"
  [[ "$round" =~ ^[1-9][0-9]*$ ]] || {
    echo "planner_params_render_row: bad round '${round}'" >&2
    return 1
  }
  case "$role" in
  client | operator) ;;
  *)
    echo "planner_params_render_row: bad role '${role}'" >&2
    return 1
    ;;
  esac
  { [ "${#key}" -le "$PLANNER_PARAMS_KEY_MAX" ] && [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_.-]*$ ]]; } || {
    echo "planner_params_render_row: bad key '${key}'" >&2
    return 1
  }
  # shellcheck disable=SC2016  # literal backticks around the key
  printf '| %s | `%s` | %s | %s | %s | human:r%s:%s |\n' \
    "$(_planner_params_cell "$name")" "$key" "$(_planner_params_cell "$kind")" \
    "$(_planner_params_cell "$def")" "$(_planner_params_cell "$value")" "$round" "$role"
}

planner_params_substitute() {
  local init="$1" src="$2" out="$3" lno="$4" key="$5" rendered="$6" open
  if [ "$#" -ne 6 ] || [ ! -f "$src" ] || [ ! -r "$src" ] || [ -z "$out" ]; then
    echo "planner_params_substitute: usage <INIT> <src> <out> <line_no> <key> <rendered>" >&2
    return 1
  fi
  [[ "$lno" =~ ^[1-9][0-9]*$ ]] || {
    echo "planner_params_substitute: bad line number '${lno}'" >&2
    return 2
  }
  open=$(planner_params_scan "$init" "$src") || return 1
  # shellcheck disable=SC2016  # awk program, not shell
  if ! printf '%s\n' "$open" | _PSP_KEY="$key" _PSP_LNO="$lno" awk -F'\t' '
    BEGIN { r = 1 }
    $1 == ENVIRON["_PSP_KEY"] && $2 == ENVIRON["_PSP_LNO"] { r = 0 }
    END { exit r }'; then
    echo "planner_params_substitute: line ${lno} is not the open row for '${key}'" >&2
    return 2
  fi
  # shellcheck disable=SC2016  # awk program, not shell
  _PSP_LNO="$lno" _PSP_RENDERED="$rendered" _planner_params_awk '
    NR == ENVIRON["_PSP_LNO"] + 0 { print ENVIRON["_PSP_RENDERED"]; next }
    { print }
  ' "$src" >"$out" || return 1
  return 0
}
