#!/usr/bin/env bash
# planner-crosscheck-ownership.sh — the Crosscheck ownership family
# (planner-crosscheck-ownership, design D2–D5, D8–D10).
#
# Every non-synthesized spec of a contract initiative declares in `## Writes`
# and `## Reads` what data it writes and reads and which side effects it owns
# (`fire`) or causes (`trigger`). planner-spec-ownership.sh parses the tables
# and checks read anchors; this family judges the rows against each other.
#
# Blocking codes:
#   OWN_TABLE_INVALID    a checked spec lacks a section, has a bad header or an
#                        invalid row; one finding per spec. A `## Reads` row whose
#                        key is another spec's `fire`/`trigger` key is invalid
#                        here too (design D2: an effect key never appears in
#                        `## Reads`; the per-spec parser only sees its own).
#   OWN_MULTI_WRITER     two specs write one exact data key in conflicting ways
#                        (cross-file, one per key). No conflict when either row
#                        is `append`, or both are transitions with disjoint
#                        from-sets; `create`/`update`/`delete` count as `*`.
#   OWN_NO_WRITER        a read whose effective source is `spec` (written `spec`,
#                        or a `code:` anchor that failed — its reason is quoted)
#                        that no other spec's data write matches: equal key, the
#                        read's entity, or a field of the read entity. One per
#                        spec and key.
#   OWN_MULTI_FIRE       two or more `fire` rows for one effect key (cross-file).
#   OWN_TRIGGER_UNOWNED  a `trigger` row whose key no spec fires; per spec and key.
# Warnings (PLANNER_CROSSCHECK_WARN_CODES):
#   OWN_NEAR_MATCH       beside an OWN_NO_WRITER: another spec writes a key equal
#                        to the read key once one trailing `s` is stripped from
#                        each segment of both.
#   OWN_UNDECLARED_REF   backticked `entity.field` tokens in `## Technical Context`
#                        (fences ignored; second segment not a file extension in
#                        PLANNER_OWNERSHIP_FILE_EXTS) that neither table holds;
#                        one per spec, tokens listed up to 300 characters.
#   OWN_EXTERNAL_UNANCHORED  an `external:` name found in no listed artifact.
#
# A read of a key the same spec writes is ignored. Valid rows of an invalid
# table still take part. Synth-marked specs and INDEX.md are skipped. Every
# finding is free of `|`, CR and LF, and each instance-code finding ends with
# its own accept command:
#   OWN_MULTI_WRITER@<key>, OWN_MULTI_FIRE@<key>,
#   OWN_NO_WRITER@<slug>/<key>, OWN_TRIGGER_UNOWNED@<slug>/<key>
# (planner_crosscheck_ownership_instance reads the token back;
# planner_crosscheck_ownership_accept_parse parses `--accept`).
#
# Legacy initiatives (no META|contract|start|spec-ownership-v1) produce
# nothing. Pure over files apart from reading the pinned repository tree for
# `code:` anchors.
#
# Usage:
#   planner_crosscheck_ownership <initiative_id>
#     stdout: `planner-crosscheck-ownership: <CODE> <message>` per finding.
#     Returns 0 clean, warn-only or legacy; 1 any blocking finding or an error.
#   planner_crosscheck_ownership_instance <message>
#   planner_crosscheck_ownership_accept_parse <arg>
#     stdout `<CODE>@<instance>\t<reason>`; rc 1 with the reason on stderr.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_OWNERSHIP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f planner_ownership_writes >/dev/null 2>&1 ||
  source "${_PLANNER_CROSSCHECK_OWNERSHIP_DIR}/planner-spec-ownership.sh"

PLANNER_OWNERSHIP_FILE_EXTS="md yaml yml json xml java kt ts tsx js jsx py sh sql html css scss properties txt csv go rb rs php cs vue"
PLANNER_OWNERSHIP_UNDECLARED_MAX=300

_PLANNER_XCO_PREFIX="planner-crosscheck-ownership:"

# _planner_xco_out <CODE> <message> — one finding line, `|` → `/`, CR/LF → space.
_planner_xco_out() {
  local msg="$2"
  msg="${msg//|//}"
  msg="${msg//$'\r'/ }"
  msg="${msg//$'\n'/ }"
  printf '%s %s %s\n' "$_PLANNER_XCO_PREFIX" "$1" "$msg"
}

_planner_xco_reason() {
  case "$1" in
  missing) echo "is missing" ;;
  empty) echo "is empty — write the table, or None." ;;
  no-table) echo "holds text where the table (or None.) should start" ;;
  duplicate-section) echo "appears twice — keep one" ;;
  header) echo "has a bad header — Writes takes the columns Key and Op, Reads Key and Source" ;;
  shape) echo "has a row without exactly two cells" ;;
  key) echo "has a key that is not a backticked lower-case <entity> or <entity>.<field> (at most 64 characters)" ;;
  duplicate-key) echo "repeats a key" ;;
  op) echo "has an Op that is not create, update, delete, append, transition:<from>-><to>, fire or trigger" ;;
  source) echo "has a Source that is not spec, code:<relative path>, framework:<name> (${PLANNER_OWNERSHIP_FRAMEWORK_SOURCES// /, }) or external:<name of 3 to 80 characters>" ;;
  effect-key) echo "reads an effect key — an effect is caused with a trigger row in ## Writes, never read" ;;
  *) echo "is invalid (${1})" ;;
  esac
}

# _planner_xco_from <op> — the from-set of a data write for the conflict rule:
# `*` for create/update/delete, the transition's from list, empty for append.
_planner_xco_from() {
  case "$1" in
  append) printf '' ;;
  transition:*)
    local r="${1#transition:}"
    printf '%s' "${r%%->*}"
    ;;
  *) printf '*' ;;
  esac
}

# _planner_xco_conflict <op-a> <op-b> — rc 0 when the two writes conflict.
_planner_xco_conflict() {
  local a b x
  a=$(_planner_xco_from "$1")
  b=$(_planner_xco_from "$2")
  { [ -n "$a" ] && [ -n "$b" ]; } || return 1
  { [ "$a" = "*" ] || [ "$b" = "*" ]; } && return 0
  for x in ${a//,/ }; do
    case ",${b}," in *",${x},"*) return 0 ;; esac
  done
  return 1
}

# _planner_xco_matches <read-key> <write-key> — the entity rule (design D2).
_planner_xco_matches() {
  local r="$1" w="$2"
  [ "$w" = "$r" ] && return 0
  [[ "$r" == *.* ]] && [ "$w" = "${r%%.*}" ] && return 0
  [[ "$w" == "${r}."* ]] && return 0
  return 1
}

# _planner_xco_strip <key> — one trailing `s` removed from each segment.
_planner_xco_strip() {
  local e="${1%%.*}" f=""
  [[ "$1" == *.* ]] && f="${1#*.}"
  e="${e%s}"
  if [ -n "$f" ]; then printf '%s.%s' "$e" "${f%s}"; else printf '%s' "$e"; fi
}

# _planner_xco_techctx_tokens <spec> — `<heading-line>\t<span>` per backticked
# span under `## Technical Context`, fenced lines ignored.
_planner_xco_techctx_tokens() {
  # shellcheck disable=SC2016  # awk program, not shell
  LC_ALL=C _planner_own_awk '
    function fence_char(s) {
      sub(/^(   |  | )?/, "", s)
      if (substr(s, 1, 3) == "```") return "`"
      if (substr(s, 1, 3) == "~~~") return "~"
      return ""
    }
    BEGIN { fence = ""; inctx = 0; head = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      fc = fence_char(line)
      if (fence != "") { if (fc == fence) fence = ""; next }
      if (fc != "") { fence = fc; next }
      if (line ~ /^##?[ \t]/) {
        h = line; sub(/^##?[ \t]+/, "", h); sub(/[ \t]+$/, "", h)
        inctx = (h == "Technical Context") ? 1 : 0
        if (inctx) head = NR
        next
      }
      if (!inctx) next
      rest = line
      while ((i = index(rest, "`")) > 0) {
        rest = substr(rest, i + 1)
        j = index(rest, "`")
        if (j == 0) break
        print head "\t" substr(rest, 1, j - 1)
        rest = substr(rest, j + 1)
      }
    }
  ' <"$1"
}

planner_crosscheck_ownership() {
  local init="$1"
  [ -n "${REPOS_ROOT:-}" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  planner_ownership_contract_initiative "$init" || return 0

  local dir specs_dir
  dir=$(planner_initiative_dir "$init") || return 1
  specs_dir="${dir}/artifacts/specs"
  [ -d "$specs_dir" ] || return 0

  local -a slugs=()
  local -A W=() R=() INV=() FIRE=() EFFECT=() DW=()
  local f base slug out line ln key val
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    planner_ownership_spec_checked "$f" || continue
    base="$(basename "$f")"
    slug="${base%.md}"
    slugs+=("$slug")
    W[$slug]=$(planner_ownership_writes "$f") || W[$slug]=""
    R[$slug]=$(planner_ownership_reads "$f") || R[$slug]=""
    INV[$slug]=$(planner_ownership_invalid "$f") || INV[$slug]=$'0\twrites\tmissing'
    while IFS=$'\t' read -r ln key val; do
      [ -n "$key" ] || continue
      case "$val" in
      fire)
        FIRE[$key]="${FIRE[$key]:-}${FIRE[$key]:+, }${slug}"
        EFFECT[$key]=1
        ;;
      trigger) EFFECT[$key]=1 ;;
      *) DW[$key]="${DW[$key]:-}${slug}"$'\t'"${val}"$'\n' ;;
      esac
    done <<<"${W[$slug]}"
  done < <(find "$specs_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)

  local blocking=0 s src eff reason first msg items wk ws wop found near
  local spec_ref
  for slug in "${slugs[@]}"; do
    spec_ref="specs/${slug}.md"

    # OWN_TABLE_INVALID: the parser's problems, plus reads of a sibling's
    # effect key.
    items="" first=""
    while IFS=$'\t' read -r ln s reason; do
      [ -n "$s" ] || continue
      if [ "$s" = writes ]; then s="## Writes"; else s="## Reads"; fi
      if [ "$ln" = 0 ]; then
        items+="${items:+; }${s} $(_planner_xco_reason "$reason")"
      else
        [ -n "$first" ] || first="$ln"
        items+="${items:+; }line ${ln} in ${s} $(_planner_xco_reason "$reason")"
      fi
    done <<<"${INV[$slug]}"
    while IFS=$'\t' read -r ln key src; do
      [ -n "$key" ] || continue
      [ -n "${EFFECT[$key]:-}" ] || continue
      [ -n "$first" ] || first="$ln"
      items+="${items:+; }line ${ln} in ## Reads reads the effect key \`${key}\` — an effect is caused with a trigger row in ## Writes, never read"
    done <<<"${R[$slug]}"
    if [ -n "$items" ]; then
      _planner_xco_out OWN_TABLE_INVALID "${spec_ref}${first:+:${first}} ${items}"
      blocking=1
    fi

    # Reads.
    while IFS=$'\t' read -r ln key src; do
      [ -n "$key" ] || continue
      [ -n "${EFFECT[$key]:-}" ] && continue
      # A read of a key this spec writes itself is ignored.
      found=0
      while IFS=$'\t' read -r _ wk wop; do
        [ -n "$wk" ] || continue
        case "$wop" in fire | trigger) continue ;; esac
        _planner_xco_matches "$key" "$wk" && found=1 && break
      done <<<"${W[$slug]}"
      [ "$found" -eq 1 ] && continue
      out=$(planner_ownership_read_effective "$init" "$src" "$key")
      eff="${out%%$'\t'*}"
      reason=""
      [[ "$out" == *$'\t'* ]] && reason="${out#*$'\t'}"
      case "$eff" in
      code | framework) continue ;;
      external)
        [ -n "$reason" ] &&
          _planner_xco_out OWN_EXTERNAL_UNANCHORED "${spec_ref}:${ln} read \`${key}\` from ${src} — ${reason}; name the system as the idea or architecture does, or use another source"
        continue
        ;;
      esac
      found=0
      for wk in "${!DW[@]}"; do
        _planner_xco_matches "$key" "$wk" || continue
        while IFS=$'\t' read -r ws _; do
          [ -n "$ws" ] && [ "$ws" != "$slug" ] && found=1 && break
        done <<<"${DW[$wk]}"
        [ "$found" -eq 1 ] && break
      done
      [ "$found" -eq 1 ] && continue
      msg="${spec_ref}:${ln} reads \`${key}\` (source ${src}) but no other spec writes it"
      [ -n "$reason" ] && msg+=" (${src} did not anchor: ${reason})"
      _planner_xco_out OWN_NO_WRITER "${msg} — add the write to the spec that owns it, or anchor the read with code:, framework: or external: — resume ${init} --accept OWN_NO_WRITER@${slug}/${key}:\"<reason>\""
      blocking=1
      near=$(_planner_xco_strip "$key")
      while IFS= read -r wk; do
        [ -n "$wk" ] || continue
        [ "$(_planner_xco_strip "$wk")" = "$near" ] || continue
        while IFS=$'\t' read -r ws _; do
          [ -n "$ws" ] && [ "$ws" != "$slug" ] || continue
          _planner_xco_out OWN_NEAR_MATCH "${spec_ref}:${ln} read \`${key}\` of ${slug} is close to \`${wk}\` written by ${ws} — rename one so the keys match exactly"
        done <<<"${DW[$wk]}"
      done < <(printf '%s\n' "${!DW[@]}" | LC_ALL=C sort)
    done <<<"${R[$slug]}"

    # OWN_TRIGGER_UNOWNED.
    while IFS=$'\t' read -r ln key val; do
      [ "$val" = trigger ] || continue
      [ -n "${FIRE[$key]:-}" ] && continue
      _planner_xco_out OWN_TRIGGER_UNOWNED "${spec_ref}:${ln} triggers \`${key}\` but no spec fires it — add a fire row to the spec that owns the effect, or remove the trigger — resume ${init} --accept OWN_TRIGGER_UNOWNED@${slug}/${key}:\"<reason>\""
      blocking=1
    done <<<"${W[$slug]}"

    # OWN_UNDECLARED_REF.
    local declared tok head="" list="" more=0 seen=" " ext
    declared=" $(printf '%s\n%s\n' "${W[$slug]}" "${R[$slug]}" | cut -f2 | tr '\n' ' ') "
    while IFS=$'\t' read -r ln tok; do
      [ -n "$tok" ] || continue
      [ "${#tok}" -le "$PLANNER_OWNERSHIP_KEY_MAX" ] || continue
      [[ "$tok" =~ ^${_PLANNER_OWN_SEG_RE}\.${_PLANNER_OWN_SEG_RE}$ ]] || continue
      ext="${tok#*.}"
      _planner_own_in_list "$ext" "$PLANNER_OWNERSHIP_FILE_EXTS" && continue
      case "$declared" in *" ${tok} "*) continue ;; esac
      case "$seen" in *" ${tok} "*) continue ;; esac
      seen+="${tok} "
      head="$ln"
      if [ $((${#list} + ${#tok} + 2)) -le "$PLANNER_OWNERSHIP_UNDECLARED_MAX" ]; then
        list+="${list:+, }${tok}"
      else
        more=$((more + 1))
      fi
    done < <(_planner_xco_techctx_tokens "${specs_dir}/${slug}.md")
    if [ -n "$list" ]; then
      [ "$more" -eq 0 ] || list+=" and ${more} more"
      _planner_xco_out OWN_UNDECLARED_REF "${spec_ref}:${head} ## Technical Context names keys neither ## Writes nor ## Reads declares: ${list} — declare each in the table it belongs to"
    fi
  done

  # OWN_MULTI_WRITER, one per key.
  local -a ops wsl
  local i j conflict names
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    ops=() wsl=()
    while IFS=$'\t' read -r ws wop; do
      [ -n "$ws" ] || continue
      wsl+=("$ws")
      ops+=("$wop")
    done <<<"${DW[$key]}"
    [ "${#wsl[@]}" -ge 2 ] || continue
    conflict=0
    for ((i = 0; i < ${#wsl[@]} && conflict == 0; i++)); do
      for ((j = i + 1; j < ${#wsl[@]}; j++)); do
        [ "${wsl[$i]}" != "${wsl[$j]}" ] || continue
        if _planner_xco_conflict "${ops[$i]}" "${ops[$j]}"; then
          conflict=1
          break
        fi
      done
    done
    [ "$conflict" -eq 1 ] || continue
    names=""
    for ((i = 0; i < ${#wsl[@]}; i++)); do
      names+="${names:+, }${wsl[$i]} (${ops[$i]})"
    done
    _planner_xco_out OWN_MULTI_WRITER "\`${key}\` has conflicting writers: ${names} — give the key one owner and have the others read it, or make each transition leave different states — resume ${init} --accept OWN_MULTI_WRITER@${key}:\"<reason>\""
    blocking=1
  done < <(printf '%s\n' "${!DW[@]}" | LC_ALL=C sort)

  # OWN_MULTI_FIRE, one per key.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    [[ "${FIRE[$key]}" == *", "* ]] || continue
    _planner_xco_out OWN_MULTI_FIRE "\`${key}\` is fired by ${FIRE[$key]} — keep one fire owner and make the others trigger it — resume ${init} --accept OWN_MULTI_FIRE@${key}:\"<reason>\""
    blocking=1
  done < <(printf '%s\n' "${!FIRE[@]}" | LC_ALL=C sort)

  [ "$blocking" -eq 0 ]
}

planner_crosscheck_ownership_instance() {
  [[ "$1" =~ --accept\ (OWN_(MULTI_WRITER|MULTI_FIRE|NO_WRITER|TRIGGER_UNOWNED)@[A-Za-z0-9_./-]+):\" ]] || return 0
  printf '%s\n' "${BASH_REMATCH[1]}"
}

planner_crosscheck_ownership_accept_parse() {
  local arg="$1" code inst reason form slug key
  code="${arg%%[@:]*}"
  case "$code" in
  OWN_MULTI_WRITER | OWN_MULTI_FIRE) form="${code}@<key>" ;;
  OWN_NO_WRITER | OWN_TRIGGER_UNOWNED) form="${code}@<slug>/<key>" ;;
  *)
    echo "ERROR: --accept ${code}: not an ownership code" >&2
    return 1
    ;;
  esac
  case "$arg" in
  "${code}@"*:*) ;;
  *)
    echo "ERROR: --accept ${code} is per instance: --accept ${form}:\"<reason>\", or --accept ${code}@*:\"<reason>\" for every instance the latest Crosscheck attempt found (got '${arg}')" >&2
    return 1
    ;;
  esac
  inst="${arg#"${code}@"}"
  reason="${inst#*:}"
  inst="${inst%%:*}"
  if [ "${#reason}" -ge 2 ] && [ "${reason:0:1}" = '"' ] && [ "${reason: -1}" = '"' ]; then
    reason="${reason:1:${#reason}-2}"
  fi
  reason="${reason#"${reason%%[![:space:]]*}"}"
  reason="${reason%"${reason##*[![:space:]]}"}"
  if [ -z "$reason" ]; then
    echo "ERROR: --accept ${code}@${inst}: requires a non-empty reason: ${form}:\"<reason>\"" >&2
    return 1
  fi
  case "$code" in
  OWN_MULTI_WRITER | OWN_MULTI_FIRE) key="$inst" ;;
  *)
    if [[ "$inst" != */* ]]; then
      echo "ERROR: --accept ${code}: '${inst}' is not <slug>/<key>" >&2
      return 1
    fi
    slug="${inst%%/*}"
    key="${inst#*/}"
    if [[ ! "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
      echo "ERROR: --accept ${code}: '${slug}' is not a spec slug (letters, digits, - and _)" >&2
      return 1
    fi
    ;;
  esac
  if ! _planner_own_key_ok "$key"; then
    echo "ERROR: --accept ${code}: '${key}' is not a key (lower-case <entity> or <entity>.<field>)" >&2
    return 1
  fi
  printf '%s@%s\t%s\n' "$code" "$inst" "$reason"
}
