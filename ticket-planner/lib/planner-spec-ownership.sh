#!/usr/bin/env bash
# planner-spec-ownership.sh — the `## Writes` / `## Reads` tables of a spec
# (planner-crosscheck-ownership, design D1–D5).
#
# Every non-synthesized spec of a contract initiative declares what data it
# writes and reads and which side effects it owns (`fire`) or causes
# (`trigger`), as one pipe table (or `None.`) under each heading:
#
#   ## Writes                      ## Reads
#   | Key | Op |                   | Key | Source |
#
# This file is the bash that reads them: which rows are valid, and what a
# read's source effectively is once its anchor is checked. The Crosscheck
# family that judges the rows against each other lives in
# planner-crosscheck-ownership.sh.
#
# Functions:
#   planner_ownership_contract_mark <INIT>        append META|contract|start|
#                                                 spec-ownership-v1 once
#   planner_ownership_contract_initiative <INIT>  rc 0 when that line is present
#   planner_ownership_spec_checked <spec>         rc 0 when the spec is checked:
#                                                 not INDEX.md, not synth-marked
#   planner_ownership_writes <spec>               one line per valid Writes row:
#                                                 <line>\t<key>\t<op>
#   planner_ownership_reads <spec>                one line per valid Reads row:
#                                                 <line>\t<key>\t<source>
#   planner_ownership_invalid <spec>              one line per problem:
#                                                 <line>\t<writes|reads>\t<reason>;
#                                                 reason is one of missing (line 0) |
#                                                 empty | no-table | duplicate-section |
#                                                 header | shape | key | duplicate-key |
#                                                 op | source | effect-key
#   planner_ownership_read_effective <INIT> <source> <key>
#                                                 `spec`, `code`, `framework` or
#                                                 `external`, then `\t<reason>` when
#                                                 an anchor failed (a failed `code:`
#                                                 prints `spec\t<reason>`, a failed
#                                                 `external:` `external\t<reason>`)
#   planner_ownership_edges_write <INIT>          Crosscheck's edges step: recompute
#                                                 artifacts/ownership-edges.json,
#                                                 freeze consumers with a ticket,
#                                                 print OWN_EDGES_DIVERGED lines;
#                                                 rc 1 on a read/write failure
#   planner_ownership_edges_count <INIT>          edges in that file (0 if none)
#
# A skipped spec (planner_ownership_spec_checked rc 1) prints nothing from the
# three parse functions. Cells are trimmed, `\|` is a literal pipe, CRLF is
# tolerated, fenced lines are ignored. An effect key in `## Reads` is one this
# spec's own `## Writes` fires or triggers (the parser is per spec; a read of a
# sibling's effect key finds no data writer in the family instead).
#
# Values reach awk only through ENVIRON. Every awk program runs under LC_ALL=C
# with no regex intervals, so mawk runs it. `PLANNER_OWNERSHIP_AWK` (default
# `awk`) names the interpreter, so the tests can run each program under mawk
# and gawk.
#
# Sourceable library. No set -euo pipefail at file scope (repo convention for
# this directory).

_PLANNER_SPEC_OWNERSHIP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f planner_state_log >/dev/null 2>&1 ||
  source "${_PLANNER_SPEC_OWNERSHIP_DIR}/planner-state.sh"
declare -f planner_crosscheck_repo_refs_resolved >/dev/null 2>&1 ||
  source "${_PLANNER_SPEC_OWNERSHIP_DIR}/planner-crosscheck-repo-ref.sh"

PLANNER_OWNERSHIP_CONTRACT="spec-ownership-v1"
PLANNER_OWNERSHIP_FRAMEWORK_SOURCES="auth_user session clock timestamps row_id tenant"
PLANNER_OWNERSHIP_CODE_MAX_FILES=200
PLANNER_OWNERSHIP_KEY_MAX=64
PLANNER_OWNERSHIP_EXTERNAL_MIN=3
PLANNER_OWNERSHIP_EXTERNAL_MAX=80
PLANNER_OWNERSHIP_EXTERNAL_ARTIFACTS="idea.txt intent.md discovery.md architecture.md"
# Same text as planner-crosscheck-testdata.sh's PLANNER_TESTDATA_SYNTH_MARKER
# (a test pins the two equal); kept here so this file does not source that one.
PLANNER_OWNERSHIP_SYNTH_MARKER='<!-- planner:testdata-synth v1 -->'

_PLANNER_OWN_SEG_RE='[a-z][a-z0-9_]*'

_planner_own_awk() {
  "${PLANNER_OWNERSHIP_AWK:-awk}" "$@"
}

# ── Contract marker ───────────────────────────────────────────────────────────

planner_ownership_contract_initiative() {
  local log
  log=$(planner_state_log "$1" 2>/dev/null) || return 1
  [ -f "$log" ] || return 1
  grep -q "^[^|]*|META|contract|start|${PLANNER_OWNERSHIP_CONTRACT}\$" "$log" 2>/dev/null
}

planner_ownership_contract_mark() {
  local init="$1"
  planner_ownership_contract_initiative "$init" && return 0
  planner_state_write "$init" META contract start "$PLANNER_OWNERSHIP_CONTRACT"
}

planner_ownership_spec_checked() {
  [ -f "$1" ] || return 1
  [ "$(basename "$1")" = "INDEX.md" ] && return 1
  ! grep -qF -- "$PLANNER_OWNERSHIP_SYNTH_MARKER" "$1" 2>/dev/null
}

# ── Table parse ───────────────────────────────────────────────────────────────

# _planner_own_table_awk <file> — one structural pass over both sections.
# Fields are separated by \037. Records (<sec> is writes or reads):
#   S <sec> <line>                 the first heading of that section
#   D <sec> <line>                 a later heading of that section
#   N <sec> <line>                 `None.`
#   X <sec> <line>                 other content where the table should start
#   H <sec> <line> ok|bad          the header row
#   R <sec> <line> <n> <c1>..<cn>  a data row, cells trimmed and unescaped
_planner_own_table_awk() {
  # shellcheck disable=SC2016  # awk program, not shell
  LC_ALL=C _planner_own_awk '
    function fence_char(s) {
      sub(/^(   |  | )?/, "", s)
      if (substr(s, 1, 3) == "```") return "`"
      if (substr(s, 1, 3) == "~~~") return "~"
      return ""
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
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
    BEGIN { US = "\037"; fence = ""; sec = ""; tstate = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      fc = fence_char(line)
      if (fence != "") { if (fc == fence) fence = ""; next }
      if (fc != "") { fence = fc; next }

      if (line ~ /^## (Writes|Reads)[ \t]*$/) {
        s = (line ~ /^## Writes/) ? "writes" : "reads"
        if (s in SEEN) { print "D" US s US NR; sec = ""; next }
        SEEN[s] = 1; sec = s; tstate = 0
        print "S" US s US NR
        next
      }
      if (line ~ /^#[ \t]/ || line ~ /^#$/ || line ~ /^##[ \t]/ || line ~ /^##$/) { sec = ""; next }
      if (sec == "" || tstate == 3) next

      t = trim(line)
      if (t == "") { if (tstate > 0) tstate = 3; next }
      if (tstate == 0) {
        if (substr(t, 1, 1) == "|") {
          n = cells(t); h = ""
          for (k = 1; k <= n; k++) h = h (k > 1 ? "|" : "") tolower(C[k])
          want = (sec == "writes") ? "key|op" : "key|source"
          print "H" US sec US NR US (h == want ? "ok" : "bad")
          tstate = 1
        } else if (t == "None." || t == "None") {
          print "N" US sec US NR; tstate = 3
        } else {
          print "X" US sec US NR; tstate = 3
        }
        next
      }
      if (substr(t, 1, 1) != "|") { tstate = 3; next }
      if (tstate == 1 && t ~ /^[|:\- \t]+$/ && index(t, "-")) { tstate = 2; next }
      tstate = 2
      n = cells(t)
      out = "R" US sec US NR US n
      for (k = 1; k <= n; k++) out = out US C[k]
      print out
    }
  ' <"$1"
}

_planner_own_in_list() {
  local w="$1" x
  for x in $2; do [ "$x" = "$w" ] && return 0; done
  return 1
}

# _planner_own_key_ok <key> — one or two lower-case segments, ≤ 64 chars.
_planner_own_key_ok() {
  [ "${#1}" -le "$PLANNER_OWNERSHIP_KEY_MAX" ] &&
    [[ "$1" =~ ^${_PLANNER_OWN_SEG_RE}(\.${_PLANNER_OWN_SEG_RE})?$ ]]
}

# _planner_own_op_ok <op> — the Writes op grammar (design D3).
_planner_own_op_ok() {
  local op="$1" rest from to
  case "$op" in
  create | update | delete | append | fire | trigger) return 0 ;;
  transition:*) ;;
  *) return 1 ;;
  esac
  rest="${op#transition:}"
  [[ "$rest" == *"->"* ]] || return 1
  from="${rest%%->*}"
  to="${rest#*->}"
  [[ "$to" =~ ^${_PLANNER_OWN_SEG_RE}$ ]] || return 1
  [ "$from" = "*" ] && return 0
  [[ "$from" =~ ^${_PLANNER_OWN_SEG_RE}(,${_PLANNER_OWN_SEG_RE})*$ ]]
}

# _planner_own_path_ok <path> — relative, no `..` component, not empty.
_planner_own_path_ok() {
  local p="$1"
  [ -n "$p" ] || return 1
  case "$p" in /* | ~*) return 1 ;; esac
  case "/${p}/" in */../*) return 1 ;; esac
  return 0
}

# _planner_own_source_ok <source> — the Reads source grammar (design D5).
_planner_own_source_ok() {
  local s="$1" n
  case "$s" in
  spec) return 0 ;;
  code:*) _planner_own_path_ok "${s#code:}" ;;
  framework:*) _planner_own_in_list "${s#framework:}" "$PLANNER_OWNERSHIP_FRAMEWORK_SOURCES" ;;
  external:*)
    n=${#s}
    n=$((n - 9))
    [ "$n" -ge "$PLANNER_OWNERSHIP_EXTERNAL_MIN" ] && [ "$n" -le "$PLANNER_OWNERSHIP_EXTERNAL_MAX" ]
    ;;
  *) return 1 ;;
  esac
}

# _planner_own_classify <spec> — rows and problems in one pass. Prints
# V<US><sec><US><line><US><key><US><op|source> and
# I<US><line><US><sec><US><reason>; Writes first, then Reads, each in line
# order. rc 1 when the file cannot be read.
_planner_own_classify() {
  local f="$1" raw sec rec ln n key val reason
  local -a F
  local US=$'\037'
  { [ -f "$f" ] && [ -r "$f" ]; } || return 1
  planner_ownership_spec_checked "$f" || return 0
  raw=$(_planner_own_table_awk "$f") || return 1
  local -A effects=()
  for sec in writes reads; do
    local head="" body=0 hdr="" bad_hdr=0
    local -A keys=()
    while IFS=$'\037' read -r -a F; do
      [ "${#F[@]}" -gt 1 ] || continue
      [ "${F[1]}" = "$sec" ] || continue
      rec="${F[0]}"
      ln="${F[2]}"
      reason=""
      case "$rec" in
      S) head="$ln" ;;
      D) reason=duplicate-section ;;
      N) body=1 ;;
      X)
        body=1
        reason=no-table
        ;;
      H)
        body=1
        hdr="$ln"
        if [ "${F[3]}" != ok ]; then
          bad_hdr=1
          reason=header
        fi
        ;;
      R)
        n="${F[3]}"
        key="${F[4]:-}"
        val="${F[5]:-}"
        if [ "$bad_hdr" -eq 1 ]; then
          reason=header
        elif [ "$n" != 2 ]; then
          reason=shape
        elif [[ "$key" != '`'*'`' ]]; then
          reason=key
        else
          key="${key#\`}"
          key="${key%\`}"
          if ! _planner_own_key_ok "$key"; then
            reason=key
          elif [ -n "${keys[$key]:-}" ]; then
            reason=duplicate-key
          elif [ "$sec" = writes ] && ! _planner_own_op_ok "$val"; then
            reason=op
          elif [ "$sec" = reads ] && [ -n "${effects[$key]:-}" ]; then
            reason=effect-key
          elif [ "$sec" = reads ] && ! _planner_own_source_ok "$val"; then
            reason=source
          fi
          [ -n "$reason" ] || keys[$key]="$ln"
        fi
        if [ -z "$reason" ]; then
          case "$val" in fire | trigger) [ "$sec" = writes ] && effects[$key]=1 ;; esac
          printf 'V%s%s%s%s%s%s%s%s\n' "$US" "$sec" "$US" "$ln" "$US" "$key" "$US" "$val"
        fi
        ;;
      esac
      [ -z "$reason" ] || printf 'I%s%s%s%s%s%s\n' "$US" "$ln" "$US" "$sec" "$US" "$reason"
    done <<<"$raw"
    if [ -z "$head" ]; then
      printf 'I%s0%s%s%smissing\n' "$US" "$US" "$sec" "$US"
    elif [ "$body" -eq 0 ] && [ -z "$hdr" ]; then
      printf 'I%s%s%s%s%sempty\n' "$US" "$head" "$US" "$sec" "$US"
    fi
    unset keys
  done
  return 0
}

_planner_own_rows() {
  local out
  out=$(_planner_own_classify "$1") || return 1
  printf '%s\n' "$out" | LC_ALL=C awk -F'\037' -v OFS='\t' -v s="$2" '$1 == "V" && $2 == s { print $3, $4, $5 }'
}

planner_ownership_writes() { _planner_own_rows "$1" writes; }
planner_ownership_reads() { _planner_own_rows "$1" reads; }

planner_ownership_invalid() {
  local out
  out=$(_planner_own_classify "$1") || return 1
  printf '%s\n' "$out" | LC_ALL=C awk -F'\037' -v OFS='\t' '$1 == "I" { print $2, $3, $4 }'
}

# ── Anchors ───────────────────────────────────────────────────────────────────

# _planner_own_words_in <seg...> -- <file...> — rc 0 when one file contains
# every segment as a word (design D5): both sides lower-cased with `_` removed;
# a match must start and end on a word boundary of the original text (a change
# between alphanumeric and anything else, an `_`, or a lower-to-upper change).
_planner_own_words_in() {
  local segs=""
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    segs="${segs}${segs:+ }${1//_/}"
    shift
  done
  shift
  [ "$#" -gt 0 ] || return 1
  # shellcheck disable=SC2016  # awk program, not shell
  _PSO_SEGS="$segs" LC_ALL=C _planner_own_awk '
    function isalnum(c) { return c != "" && index("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", c) > 0 }
    function islower(c) { return c != "" && index("abcdefghijklmnopqrstuvwxyz", c) > 0 }
    function isupper(c) { return c != "" && index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c) > 0 }
    # B[k] = 1 when a word boundary sits before normalised char k.
    function bounds(line,   i, n, c, k, a, pa, pc, us) {
      n = length(line); k = 0; us = 0; pa = 0; pc = ""
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == "_") { us = 1; continue }
        a = isalnum(c); k++
        if (k == 1 || us || a != pa || (islower(pc) && isupper(c))) B[k] = 1
        else B[k] = 0
        pa = a; pc = c; us = 0
      }
      B[k + 1] = 1
    }
    function has_word(norm, s,   start, p, q, L) {
      L = length(s); start = 1
      while ((p = index(substr(norm, start), s)) > 0) {
        q = start + p - 1
        if (B[q] && B[q + L]) return 1
        start = q + 1
      }
      return 0
    }
    BEGIN { ns = split(ENVIRON["_PSO_SEGS"], S, " "); cur = ""; done = 0 }
    {
      if (FILENAME != cur) { cur = FILENAME; split("", HIT); nh = 0 }
      norm = tolower($0); gsub(/_/, "", norm)
      scanned = 0
      for (j = 1; j <= ns; j++) {
        if (j in HIT) continue
        if (!index(norm, S[j])) continue
        if (!scanned) { bounds($0); scanned = 1 }
        if (has_word(norm, S[j])) { HIT[j] = 1; nh++ }
      }
      if (nh == ns) { done = 1; exit }
    }
    END { exit !done }
  ' "$@"
}

# _planner_own_code_tree <INIT> <repos_root> <path> — the repository tree a
# `code:` path reads, then <TAB> and the path inside it. The repository is the
# shortest leading part of <path> that is a git checkout under <repos_root>
# (a bare first component is also searched for, like Discovery's legacy
# names); when Discovery pinned a sha for it and the live checkout has moved,
# the pinned worktree is used (created if missing). rc 1 when no repository
# resolves.
_planner_own_code_tree() {
  local init="$1" root="$2" path="$3" prefix="" rest="$3" comp live="" tree dir repo ref sha wt
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    prefix="${prefix:+${prefix}/}${comp}"
    if [ -e "${root}/${prefix}/.git" ]; then
      live="${root}/${prefix}"
      break
    fi
    if [ "$prefix" = "$comp" ]; then
      live=$(planner_crosscheck_repo_dir "$root" "$comp")
      [ -n "$live" ] && break
    fi
  done
  [ -n "$live" ] || return 1
  tree="$live"
  while IFS=$'\037' read -r dir repo ref sha; do
    [ "$dir" = "$live" ] && [ -n "$sha" ] || continue
    [ "$(git -C "$live" rev-parse HEAD 2>/dev/null)" = "$sha" ] && break
    wt=$(planner_crosscheck_repo_ref_worktree_dir "$live" "$ref" "$sha")
    [ -d "$wt" ] || planner_crosscheck_repo_ref_ensure "$root" "$repo" "$ref" "$sha" "$live" >/dev/null
    [ -d "$wt" ] && tree="$wt"
    break
  done < <(planner_crosscheck_repo_refs_resolved "$init" "$root")
  printf '%s\t%s\n' "$tree" "$rest"
}

# _planner_own_code_anchor <INIT> <path> <key> — empty on success, else the
# reason the anchor failed.
_planner_own_code_anchor() {
  local init="$1" path="$2" key="$3" root out tree sub target max n
  local -a files=() segs
  _planner_own_path_ok "$path" || {
    printf 'invalid path'
    return
  }
  root=$(planner_repos_root 2>/dev/null) || {
    printf 'repository not found'
    return
  }
  root="${root%/}"
  out=$(_planner_own_code_tree "$init" "$root" "$path") || {
    printf 'repository not found'
    return
  }
  tree="${out%%$'\t'*}"
  sub="${out#*$'\t'}"
  target="${tree}${sub:+/${sub}}"
  IFS=. read -r -a segs <<<"$key"
  max="$PLANNER_OWNERSHIP_CODE_MAX_FILES"
  if [ -f "$target" ]; then
    _planner_own_words_in "${segs[@]}" -- "$target" && return 0
    printf 'key not named in file'
    return
  fi
  if [ ! -d "$target" ]; then
    printf 'path not found'
    return
  fi
  mapfile -t files < <(find "$target" -name .git -prune -o -type f -print 2>/dev/null | LC_ALL=C sort | head -n "$max")
  n=${#files[@]}
  if [ "$n" -gt 0 ] && _planner_own_words_in "${segs[@]}" -- "${files[@]}"; then
    return 0
  fi
  if [ "$n" -ge "$max" ]; then
    printf 'key not named in the first %s files under the path' "$max"
  else
    printf 'key not named in any file under the path'
  fi
}

# _planner_own_norm — lower-case, whitespace runs to one space, trimmed.
_planner_own_norm() {
  LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# _planner_own_external_anchor <INIT> <name> — rc 0 when the name appears in
# one of the initiative's idea/intent/discovery/architecture artifacts.
_planner_own_external_anchor() {
  local dir needle a f
  dir=$(planner_initiative_dir "$1" 2>/dev/null) || return 1
  needle=$(printf '%s' "$2" | _planner_own_norm)
  [ -n "$needle" ] || return 1
  for a in $PLANNER_OWNERSHIP_EXTERNAL_ARTIFACTS; do
    f="${dir}/artifacts/${a}"
    { [ -f "$f" ] && [ -r "$f" ]; } || continue
    # shellcheck disable=SC2016  # awk program, not shell
    _PSO_HAY="$(_planner_own_norm <"$f")" _PSO_NEEDLE="$needle" LC_ALL=C _planner_own_awk \
      'BEGIN { exit !(index(ENVIRON["_PSO_HAY"], ENVIRON["_PSO_NEEDLE"]) > 0) }' && return 0
  done
  return 1
}

planner_ownership_read_effective() {
  local init="$1" src="$2" key="$3" reason
  case "$src" in
  spec) printf 'spec\n' ;;
  framework:*) printf 'framework\n' ;;
  code:*)
    reason=$(_planner_own_code_anchor "$init" "${src#code:}" "$key")
    if [ -z "$reason" ]; then
      printf 'code\n'
    else
      printf 'spec\t%s\n' "$reason"
    fi
    ;;
  external:*)
    if _planner_own_external_anchor "$init" "${src#external:}"; then
      printf 'external\n'
    else
      printf 'external\tname not found in idea.txt, intent.md, discovery.md or architecture.md\n'
    fi
    ;;
  *)
    printf 'spec\tinvalid source\n'
    return 1
    ;;
  esac
  return 0
}

# ── Ownership edges (design D6, D7) ───────────────────────────────────────────

# _planner_own_key_matches <read-key> <write-key> — the entity rule (design
# D2): equal keys, the read's entity, or a field of the read entity.
_planner_own_key_matches() {
  local r="$1" w="$2"
  [ "$w" = "$r" ] && return 0
  [[ "$r" == *.* ]] && [ "$w" = "${r%%.*}" ] && return 0
  [[ "$w" == "${r}."* ]] && return 0
  return 1
}

# _planner_own_edges_compute <INIT> <specs_dir> — `<consumer>\t<blocked_by>\t<key>`
# per edge key, sorted and unique under LC_ALL=C, from valid rows of checked
# specs only:
#   - a read whose effective source is `spec` (written `spec`, or a failed
#     `code:` anchor) → every other spec with a matching data write;
#   - a `trigger` row → every other spec that fires the key.
# A verified `code:`, a `framework:` or an `external:` read gives none, nor
# does a read of an effect key or of a key the spec writes itself (the same
# filters as the family's read loop).
_planner_own_edges_compute() {
  local init="$1" specs_dir="$2"
  local -a slugs=()
  local -A W=() R=() FIRE=() EFFECT=() DW=()
  local f slug ln key val
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    planner_ownership_spec_checked "$f" || continue
    slug="$(basename "$f" .md)"
    slugs+=("$slug")
    W[$slug]=$(planner_ownership_writes "$f") || W[$slug]=""
    R[$slug]=$(planner_ownership_reads "$f") || R[$slug]=""
    while IFS=$'\t' read -r ln key val; do
      [ -n "$key" ] || continue
      case "$val" in
      fire)
        FIRE[$key]+="${slug}"$'\n'
        EFFECT[$key]=1
        ;;
      trigger) EFFECT[$key]=1 ;;
      *) DW[$key]+="${slug}"$'\n' ;;
      esac
    done <<<"${W[$slug]}"
  done < <(find "$specs_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)

  local src wk wop own eff ws
  for slug in "${slugs[@]}"; do
    while IFS=$'\t' read -r ln key src; do
      [ -n "$key" ] || continue
      [ -n "${EFFECT[$key]:-}" ] && continue
      own=0
      while IFS=$'\t' read -r _ wk wop; do
        [ -n "$wk" ] || continue
        case "$wop" in fire | trigger) continue ;; esac
        _planner_own_key_matches "$key" "$wk" && own=1 && break
      done <<<"${W[$slug]}"
      [ "$own" -eq 1 ] && continue
      eff=$(planner_ownership_read_effective "$init" "$src" "$key")
      [ "${eff%%$'\t'*}" = spec ] || continue
      for wk in "${!DW[@]}"; do
        _planner_own_key_matches "$key" "$wk" || continue
        while IFS= read -r ws; do
          [ -n "$ws" ] && [ "$ws" != "$slug" ] || continue
          printf '%s\t%s\t%s\n' "$slug" "$ws" "$key"
        done <<<"${DW[$wk]}"
      done
    done <<<"${R[$slug]}"
    while IFS=$'\t' read -r ln key val; do
      [ "$val" = trigger ] || continue
      while IFS= read -r ws; do
        [ -n "$ws" ] && [ "$ws" != "$slug" ] || continue
        printf '%s\t%s\t%s\n' "$slug" "$ws" "$key"
      done <<<"${FIRE[$key]:-}"
    done <<<"${W[$slug]}"
  done | LC_ALL=C sort -u
}

# planner_ownership_edges_write <INIT> — Crosscheck's edges step. A full
# recompute into artifacts/ownership-edges.json:
#   {"version": 1, "edges": [{"consumer", "blocked_by", "keys", "frozen"}]}
# (jq -S, edges sorted by consumer then blocked_by, keys sorted, LC_ALL=C).
# Written through tmp + mv only when the bytes change; removed when there are
# no edges. No spec file is edited.
#
# Freeze (D7): a consumer whose ticket exists (.intents/ticket-<slug>.json,
# the same test as planner_testdata_synth_has_ticket) keeps the edges the
# previous file recorded for it, marked frozen, keys included. When this
# run's recomputed blocked_by set for it differs, one warning line is printed:
#   planner-ownership-edges: OWN_EDGES_DIVERGED specs/<slug>.md … added <c>
#   blocked_by <b>, …; removed <c> blocked_by <b>, … — …
# Divergence compares blocked_by targets, not keys.
#
# Legacy initiative (no spec-ownership-v1 marker): does nothing, rc 0.
# rc 1 with a message on stderr when the file cannot be read back or written.
planner_ownership_edges_write() {
  local init="$1"
  [ -n "${REPOS_ROOT:-}" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  planner_ownership_contract_initiative "$init" || return 0
  local dir specs_dir sc
  dir=$(planner_initiative_dir "$init") || return 1
  specs_dir="${dir}/artifacts/specs"
  sc="${dir}/artifacts/ownership-edges.json"
  if [ -e "$sc" ] && [ ! -f "$sc" ]; then
    echo "planner-spec-ownership: could not write artifacts/ownership-edges.json — it is not a regular file" >&2
    return 1
  fi

  local computed prev=""
  computed=$(_planner_own_edges_compute "$init" "$specs_dir")
  if [ -f "$sc" ]; then
    prev=$(jq -r '.edges[] | .consumer as $c | .blocked_by as $b | .keys[] | [$c, $b, .] | join("\t")' "$sc" 2>/dev/null) || {
      echo "planner-spec-ownership: could not read artifacts/ownership-edges.json back — fix or delete it, then resume" >&2
      return 1
    }
  fi

  # Consumers with a ticket.
  local -A frozen=()
  local c b k
  while IFS=$'\t' read -r c _ _; do
    [ -n "$c" ] || continue
    [ -f "${dir}/.intents/ticket-${c}.json" ] && frozen[$c]=1
  done < <(printf '%s\n%s\n' "$computed" "$prev")

  local rows="" added removed old new
  for c in $(printf '%s\n' "${!frozen[@]}" | LC_ALL=C sort); do
    old=$(awk -F'\t' -v c="$c" '$1 == c { print $2 }' <<<"$prev" | LC_ALL=C sort -u)
    new=$(awk -F'\t' -v c="$c" '$1 == c { print $2 }' <<<"$computed" | LC_ALL=C sort -u)
    if [ "$old" != "$new" ]; then
      added=$(LC_ALL=C comm -13 <(printf '%s\n' "$old" | sed '/^$/d') <(printf '%s\n' "$new" | sed '/^$/d') |
        sed "s/^/${c} blocked_by /" | paste -sd',' - | sed 's/,/, /g')
      removed=$(LC_ALL=C comm -23 <(printf '%s\n' "$old" | sed '/^$/d') <(printf '%s\n' "$new" | sed '/^$/d') |
        sed "s/^/${c} blocked_by /" | paste -sd',' - | sed 's/,/, /g')
      printf 'planner-ownership-edges: OWN_EDGES_DIVERGED specs/%s.md has a ticket, so its edges stay as recorded%s%s — edit the ticket'"'"'s blocked-by by hand if the new order matters, or restore the ## Writes / ## Reads rows\n' \
        "$c" "${added:+; this run added ${added}}" "${removed:+; removed ${removed}}"
    fi
    rows+=$(awk -F'\t' -v c="$c" '$1 == c { print $0 "\ttrue" }' <<<"$prev")$'\n'
  done
  while IFS=$'\t' read -r c b k; do
    [ -n "$c" ] || continue
    [ -n "${frozen[$c]:-}" ] && continue
    rows+="${c}"$'\t'"${b}"$'\t'"${k}"$'\tfalse\n'
  done <<<"$computed"

  if [ -z "$(sed '/^$/d' <<<"$rows")" ]; then
    rm -f "$sc" 2>/dev/null || {
      echo "planner-spec-ownership: could not remove artifacts/ownership-edges.json" >&2
      return 1
    }
    return 0
  fi

  local tmp
  tmp=$(mktemp "${sc}.XXXXXX" 2>/dev/null) || {
    echo "planner-spec-ownership: could not write artifacts/ownership-edges.json" >&2
    return 1
  }
  # shellcheck disable=SC2016  # jq program, not shell
  if ! printf '%s' "$rows" | LC_ALL=C jq -R -s '
      split("\n") | map(select(length > 0) | split("\t"))
      | group_by([.[0], .[1]])
      | map({consumer: .[0][0], blocked_by: .[0][1],
             keys: (map(.[2]) | unique), frozen: (.[0][3] == "true")})
      | {version: 1, edges: .}' 2>/dev/null | LC_ALL=C jq -S . >"$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "planner-spec-ownership: could not render artifacts/ownership-edges.json" >&2
    return 1
  fi
  if [ -f "$sc" ] && cmp -s "$tmp" "$sc"; then
    rm -f "$tmp"
    return 0
  fi
  if [ -f "$sc" ]; then
    chmod --reference="$sc" "$tmp" 2>/dev/null
  else
    chmod "$(printf '%o' $((0666 & ~$(umask))))" "$tmp" 2>/dev/null
  fi
  mv -f "$tmp" "$sc" || {
    rm -f "$tmp"
    echo "planner-spec-ownership: could not write artifacts/ownership-edges.json" >&2
    return 1
  }
  return 0
}

# planner_ownership_edges_count <INIT> — edges in artifacts/ownership-edges.json
# (0 when there is none).
planner_ownership_edges_count() {
  local dir sc n
  dir=$(planner_initiative_dir "$1" 2>/dev/null) || {
    echo 0
    return 0
  }
  sc="${dir}/artifacts/ownership-edges.json"
  [ -f "$sc" ] || {
    echo 0
    return 0
  }
  n=$(jq -r '.edges | length' "$sc" 2>/dev/null) || n=0
  echo "${n:-0}"
}
