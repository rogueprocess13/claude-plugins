#!/usr/bin/env bash
# planner-crosscheck-ac-precondition.sh — the Crosscheck AC precondition
# family (planner-ac-code-precondition, design D5, D8–D10).
#
# Every non-synthesized spec of a contract initiative (marker
# ac-precondition-v1) declares in `## Preconditions` the stored starting state
# each acceptance criterion needs. planner-ac-precondition.sh parses the table,
# reads strong schema facts from the pinned code and decides each row; this
# family turns the decisions into findings.
#
# Blocking codes:
#   AC_PRECONDITION_TABLE_INVALID  the section is missing or malformed, a row is
#                                  invalid, a criterion is not found, or a
#                                  `spec:` Basis breaks the Basis rules; one
#                                  finding per spec, every problem listed with
#                                  its line. Accepted code-wide.
#   AC_PRECONDITION_UNREACHABLE    a `state` row with a `code:` Basis whose
#                                  starting state the code forbids, when no
#                                  other spec writes the key; one per row,
#                                  instance token <slug>/<key>/<requires> with
#                                  the `:` of Requires written `=`.
# Warnings (PLANNER_CROSSCHECK_WARN_CODES):
#   AC_PRECONDITION_PLANNED        instead of UNREACHABLE when another
#                                  non-synthesized spec's `## Writes` holds the
#                                  key or its entity (any op); one per row.
#   AC_PRECONDITION_NO_SOURCE      once per initiative, when every checked row
#                                  that was scanned found no @Entity class and
#                                  no Liquibase changelog (an unsupported stack).
#
# `input` rows are counted, never flagged. A valid `spec:` row is counted as
# planned and never checked against code. Unchecked rows are not findings:
# the family writes one `META|ac-precondition|done|<c> checked, <u> unchecked,
# <p> planned, <i> input: <details>` line per run, <details> being up to
# PLANNER_ACPRE_INFO_MAX characters of `<slug>/<key> (<reason>)`.
#
# Every finding is free of `|`, CR and LF. Spec-derived text has `"` → `'`
# and every `--` → `-`, so the only `"` and the only `--` of an UNREACHABLE
# finding are those of its trailing accept command:
#   Accept: --accept AC_PRECONDITION_UNREACHABLE@<token>:"<reason>"
# planner_crosscheck_acpre_instance reads the token back from there only.
#
# Legacy initiatives (no META|contract|start|ac-precondition-v1) produce
# nothing: no finding, no META line.
#
# Usage:
#   planner_crosscheck_ac_precondition <initiative_id>
#     stdout: `planner-crosscheck-ac-precondition: <CODE> <message>` per finding.
#     Returns 0 clean, warn-only or legacy; 1 any blocking finding or an error.
#   planner_crosscheck_acpre_instance <message>
#   planner_crosscheck_acpre_accept_parse <arg>
#     stdout `AC_PRECONDITION_UNREACHABLE@<token>\t<reason>`; rc 1 with the
#     reason on stderr (the code-wide form included).
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_ACPRE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f planner_acpre_check_row >/dev/null 2>&1 ||
  source "${_PLANNER_CROSSCHECK_ACPRE_DIR}/planner-ac-precondition.sh"

PLANNER_ACPRE_EXCERPT_MAX=120
PLANNER_ACPRE_INFO_MAX=300

_PLANNER_XCA_PREFIX="planner-crosscheck-ac-precondition:"
_PLANNER_XCA_CODE="AC_PRECONDITION_UNREACHABLE"

# The info line is one `done` per run, never a progress marker.
_planner_xca_repeatable() {
  case " ${PLANNER_REPEATABLE_META_STEPS:-} " in
  *" ac-precondition "*) ;;
  *) PLANNER_REPEATABLE_META_STEPS="${PLANNER_REPEATABLE_META_STEPS:-} ac-precondition" ;;
  esac
}
_planner_xca_repeatable

# _planner_xca_safe <text> — spec-derived text made inert: `"` → `'`, every
# `--` → `-` until none is left, `|`, CR and LF removed, tabs → space.
_planner_xca_safe() {
  local s="$1"
  s="${s//\"/\'}"
  while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
  s="${s//|/}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}

# _planner_xca_out <CODE> <message> [<token>] — one finding line. With a
# token in the safe charset, the accept command is appended; an unsafe token
# gets none (the finding blocks).
_planner_xca_out() {
  local msg
  msg=$(_planner_xca_safe "$2")
  if [ -n "${3:-}" ] && [[ "$3" =~ ^[a-z0-9_.=/-]+$ ]]; then
    msg+=" Accept: --accept ${1}@${3}:\"<reason>\""
  fi
  printf '%s %s %s\n' "$_PLANNER_XCA_PREFIX" "$1" "$msg"
}

_planner_xca_reason() {
  case "$1" in
  missing) echo "## Preconditions is missing — write the table, or None." ;;
  empty) echo "empty — write the table, or None." ;;
  no-table) echo "no-table — text where the table (or None.) should start" ;;
  duplicate-section) echo "duplicate-section — a second ## Preconditions heading, keep one" ;;
  second-table) echo "second-table — keep one table" ;;
  header) echo "header — the columns are Criterion, Key, Mode, Requires, Basis" ;;
  shape) echo "shape — a row needs exactly five cells" ;;
  "criterion not found") echo "criterion not found — the Criterion cell must repeat one ## Acceptance Criteria line" ;;
  key) echo "key — a backticked lower-case <entity>.<field>" ;;
  mode) echo "mode — state or input" ;;
  requires) echo "requires — null, value:<v> or number:<n>" ;;
  basis) echo "basis — code:<relative path> or spec:<slug> for state, — for input" ;;
  duplicate) echo "duplicate — the (Criterion, Key, Mode, Requires) row repeats" ;;
  basis-spec-unknown) echo "basis-spec-unknown — the spec: Basis names no spec of this initiative" ;;
  basis-spec-no-write) echo "basis-spec-no-write — the Basis spec's ## Writes has no row for the key or its entity" ;;
  basis-not-a-dependency) echo "basis-not-a-dependency — add blocked-by:${2:-<slug>} to ## Labels" ;;
  *) echo "$1" ;;
  esac
}

# _planner_xca_fact <kind> <value> — what the code says, for a message.
_planner_xca_fact() {
  case "$1" in
  nullable) printf 'declares it NOT NULL' ;;
  enum) printf 'allows only %s' "$2" ;;
  min) printf 'is an integer column with min %s' "$2" ;;
  max) printf 'is an integer column with max %s' "$2" ;;
  *) printf 'forbids it (%s %s)' "$1" "$2" ;;
  esac
}

# _planner_xca_excerpt <criterion> — at most PLANNER_ACPRE_EXCERPT_MAX characters.
_planner_xca_excerpt() {
  if [ "${#1}" -gt "$PLANNER_ACPRE_EXCERPT_MAX" ]; then
    printf '%s...' "${1:0:PLANNER_ACPRE_EXCERPT_MAX}"
  else
    printf '%s' "$1"
  fi
}

planner_crosscheck_ac_precondition() {
  local init="$1"
  [ -n "${REPOS_ROOT:-}" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  planner_acpre_contract_initiative "$init" || return 0
  _planner_xca_repeatable

  local dir specs_dir
  dir=$(planner_initiative_dir "$init") || return 1
  specs_dir="${dir}/artifacts/specs"

  local -a slugs=()
  local f slug
  if [ -d "$specs_dir" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      planner_ownership_spec_checked "$f" || continue
      slug="$(basename "$f")"
      slugs+=("${slug%.md}")
    done < <(find "$specs_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
  fi

  local cache
  cache=$(mktemp -d 2>/dev/null) || cache=""
  local PLANNER_ACPRE_CACHE_DIR="$cache"

  local blocking=0 nc=0 nu=0 np=0 ni=0 scanned=0 found_src=0
  local details="" dmore=0 nosrc="" nsmore=0
  local inv rows ln reason items first crit key mode req basis out pin src d
  local kind val loc rest token excerpt where facttext s writers
  local -A bad=() basis_of=()
  for slug in "${slugs[@]}"; do
    f="${specs_dir}/${slug}.md"
    inv=$(planner_acpre_invalid "$init" "$f" 2>/dev/null) || inv=$'0\tmissing'
    rows=$(planner_acpre_rows "$f" 2>/dev/null) || rows=""
    bad=() basis_of=()
    while IFS=$'\t' read -r ln crit key mode req basis; do
      [ -n "$ln" ] || continue
      basis_of[$ln]="$basis"
    done <<<"$rows"

    # AC_PRECONDITION_TABLE_INVALID: every problem of the spec, one finding.
    items="" first=""
    while IFS=$'\t' read -r ln reason; do
      [ -n "$reason" ] || continue
      bad[$ln]=1
      if [ "$ln" = 0 ]; then
        items+="${items:+; }$(_planner_xca_reason "$reason")"
      else
        [ -n "$first" ] || first="$ln"
        s="${basis_of[$ln]:-}"
        items+="${items:+; }line ${ln} $(_planner_xca_reason "$reason" "${s#spec:}")"
      fi
    done <<<"$inv"
    if [ -n "$items" ]; then
      _planner_xca_out AC_PRECONDITION_TABLE_INVALID "specs/${slug}.md${first:+:${first}} ${items}"
      blocking=1
    fi

    while IFS=$'\t' read -r ln crit key mode req basis; do
      [ -n "$ln" ] || continue
      [ -z "${bad[$ln]:-}" ] || continue
      if [ "$mode" = input ]; then
        ni=$((ni + 1))
        continue
      fi
      case "$basis" in
      spec:*)
        np=$((np + 1))
        continue
        ;;
      code:*) ;;
      *) continue ;;
      esac
      out=$(planner_acpre_check_row "$init" "${basis#code:}" "$key" "$req")
      pin="${out%%$'\t'*}"
      rest="${out#*$'\t'}"
      src="${rest%%$'\t'*}"
      d="${rest#*$'\t'}"
      if [ "$src" != "-" ]; then
        scanned=1
        [ "$src" = none ] || found_src=1
      fi
      case "$d" in
      reachable)
        nc=$((nc + 1))
        ;;
      unreachable$'\t'*)
        rest="${d#unreachable$'\t'}"
        kind="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        val="${rest%%$'\t'*}"
        loc="${rest#*$'\t'}"
        facttext=$(_planner_xca_fact "$kind" "$val")
        where="(unpinned)"
        [ "$pin" = pinned ] && where="(pinned)"
        excerpt=$(_planner_xca_excerpt "$crit")
        writers=""
        for s in "${slugs[@]}"; do
          [ "$s" != "$slug" ] || continue
          _planner_acpre_spec_writes_key "${specs_dir}/${s}.md" "$key" &&
            writers+="${writers:+, }${s}"
        done
        if [ -n "$writers" ]; then
          np=$((np + 1))
          _planner_xca_out AC_PRECONDITION_PLANNED "specs/${slug}.md:${ln} '${excerpt}' needs ${key} ${req}, which ${loc} ${facttext} ${where}, but ${writers} write ${key} — set Basis spec:${writers%%,*} if that spec changes the schema"
        else
          nc=$((nc + 1))
          token="${slug}/${key}/${req/:/=}"
          _planner_xca_out "$_PLANNER_XCA_CODE" "specs/${slug}.md:${ln} '${excerpt}' needs ${key} ${req}, but ${loc} ${facttext} ${where}. Fix: change the criterion, mark it Mode input if the test submits the value, or set Basis spec:<slug> for a spec that changes the schema." "$token"
          blocking=1
        fi
        ;;
      *)
        nu=$((nu + 1))
        reason="${d#unchecked$'\t'}"
        reason="${reason//$'\t'/ }"
        s="${slug}/${key} (${reason})"
        if [ $((${#details} + ${#s} + 2)) -le "$PLANNER_ACPRE_INFO_MAX" ]; then
          details+="${details:+; }${s}"
        else
          dmore=$((dmore + 1))
        fi
        if [ "$src" = none ]; then
          s="${slug}/${key}"
          if [ $((${#nosrc} + ${#s} + 2)) -le "$PLANNER_ACPRE_INFO_MAX" ]; then
            nosrc+="${nosrc:+, }${s}"
          else
            nsmore=$((nsmore + 1))
          fi
        fi
        ;;
      esac
    done <<<"$rows"
  done
  [ -z "$cache" ] || rm -rf "$cache"

  if [ "$scanned" -eq 1 ] && [ "$found_src" -eq 0 ]; then
    [ "$nsmore" -eq 0 ] || nosrc+=" and ${nsmore} more"
    _planner_xca_out AC_PRECONDITION_NO_SOURCE "no code: row found an @Entity class or a Liquibase changelog (databaseChangeLog), under its path or in the whole repository — only JPA and Liquibase XML are read, so these rows stay unchecked: ${nosrc}"
  fi

  [ "$dmore" -eq 0 ] || details+=" and ${dmore} more"
  planner_state_write "$init" META ac-precondition done \
    "${nc} checked, ${nu} unchecked, ${np} planned, ${ni} input${details:+: ${details}}" >/dev/null 2>&1

  [ "$blocking" -eq 0 ]
}

planner_crosscheck_acpre_instance() {
  # Anchored to the end: only the trailing command names the instance.
  [[ "$1" =~ \ --accept\ (AC_PRECONDITION_UNREACHABLE@[a-z0-9_.=/-]+):\"\<reason\>\"$ ]] || return 0
  printf '%s\n' "${BASH_REMATCH[1]}"
}

planner_crosscheck_acpre_accept_parse() {
  local arg="$1" code inst reason slug key req rest
  local form="AC_PRECONDITION_UNREACHABLE@<slug>/<key>/<requires>"
  code="${arg%%[@:]*}"
  if [ "$code" != "$_PLANNER_XCA_CODE" ]; then
    echo "ERROR: --accept ${code}: not an AC precondition instance code" >&2
    return 1
  fi
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
  if [[ ! "$inst" =~ ^[a-z0-9_.=/-]+$ ]]; then
    echo "ERROR: --accept ${code}: '${inst}' has characters outside [a-z0-9_.=/-] — copy the token the finding prints" >&2
    return 1
  fi
  if [[ ! "$inst" =~ ^[^/]+/[^/]+/[^/]+$ ]]; then
    echo "ERROR: --accept ${code}: '${inst}' is not <slug>/<key>/<requires>" >&2
    return 1
  fi
  slug="${inst%%/*}"
  rest="${inst#*/}"
  key="${rest%%/*}"
  req="${rest#*/}"
  if [[ ! "$slug" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    echo "ERROR: --accept ${code}: '${slug}' is not a spec slug" >&2
    return 1
  fi
  if ! _planner_acpre_key_ok "$key"; then
    echo "ERROR: --accept ${code}: '${key}' is not a key (lower-case <entity>.<field>)" >&2
    return 1
  fi
  case "$req" in
  null) ;;
  value=* | number=*) req="${req/=/:}" ;;
  *) req="bad" ;;
  esac
  if ! _planner_acpre_requires_ok "$req"; then
    echo "ERROR: --accept ${code}: '${inst##*/}' is not a requirement (null, value=<v> or number=<n>)" >&2
    return 1
  fi
  printf '%s@%s\t%s\n' "$code" "$inst" "$reason"
}
