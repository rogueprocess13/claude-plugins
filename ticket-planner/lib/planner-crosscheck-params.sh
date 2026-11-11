#!/usr/bin/env bash
# planner-crosscheck-params.sh — the Crosscheck parameter family
# (planner-specify-parameters, design D7).
#
# Specify declares every value the plan depends on once, in proposal.md's
# `## Parameters` registry (planner-specify-params.sh). This family checks the
# specs against it: an acceptance criterion or a Verification Notes Expected
# cell must not carry a unit literal (`15 minutes`, `10s`, `30-day`, `2 GB`,
# `3 retries`, `2.5%`) that no decided registry row declares. Bash decides
# this deterministically, and a new literal always blocks.
#
# Codes, all blocking (review round 1, S1):
#   PARAM_TABLE_INVALID  no `## Parameters` section, a bad header, any invalid
#                        row (planner_params_invalid)
#   PARAM_UNDECIDED      any open row (planner_params_scan). Unreachable through
#                        the router — the Specify gate halts at Crosscheck first
#                        (D4) — and kept for direct callers such as
#                        scripts/e2e-preflight.sh
#   PARAM_LITERAL        a literal in a checked place that is not covered
#
# Checked places: every line under `## Acceptance Criteria`, and the
# `Expected` column of the `## Verification Notes` table. Legacy numbered
# notes lines are not checked. Fenced blocks are blanked first
# (_planner_crosscheck_contracts_defenced); the tokenizer itself skips code
# spans, link targets and URLs.
#
# Literals and their canonical forms come from planner_params_literals (the
# one tokenizer, shared with the anchors and answer intake; its unit list is
# PLANNER_PARAMS_UNITS). A literal is covered when its canonical form equals
# the canonical form of a literal in the Value of
#   - a closed row that is not `fixed` (initiative-wide), or
#   - a closed `fixed` row whose key the spec names in backticks.
# Open and invalid rows never cover; a Value with no literal covers nothing.
#
# Per-literal accept: `resume <INIT> --accept PARAM_LITERAL@<slug>:"<literal>"`
# is parsed by planner_crosscheck_params_accept_parse and recorded as
# `META|crosscheck|accepted|PARAM_LITERAL@<slug>=<canonical> <literal>`.
# _planner_crosscheck_emit_finding asks planner_crosscheck_params_instance for
# the finding's instance token and writes a matching finding as
# `accepted|PARAM_LITERAL@<slug>=<canonical> <message>` — the instance token
# first, never the bare code, so the stop describer (which treats an accepted
# line's first token as an accepted code) never reads it as a code-wide accept.
# A code-wide `PARAM_LITERAL` accept is refused at parsing and ignored here.
#
# Each PARAM_LITERAL message ends with its own accept command, which the stop
# describer reads back (`PARAM_LITERAL@<slug>:"<literal>"`); a literal never
# contains `"`.
#
# Legacy initiatives (no META|contract|start|specify-parameters-v1) produce
# nothing. Synth-marked TD specs and INDEX.md are skipped. Pure over files:
# no network, no clock, no git.
#
# Usage:
#   planner_crosscheck_params <initiative_id>
#     stdout: `planner-crosscheck-params: <CODE> <message>` per finding.
#     Returns 0 clean (or legacy), 1 any finding or an error.
#   planner_crosscheck_params_accept_parse <arg>
#     <arg> is `PARAM_LITERAL@<slug>:<literal>` (the literal optionally in
#     double quotes). stdout `PARAM_LITERAL@<slug>=<canonical>\t<literal>`;
#     rc 1 with the reason on stderr.
#   planner_crosscheck_params_instance <message>
#     The instance token of a PARAM_LITERAL finding message, or nothing.
#   planner_crosscheck_params_literal <message>
#     The literal a PARAM_LITERAL finding message quotes, or nothing: the text
#     a wildcard accept (`PARAM_LITERAL@*:"<reason>"`) records ahead of the
#     reason, `PARAM_LITERAL@<slug>=<canonical> <literal> — <reason>`.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_PARAMS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f _planner_crosscheck_contracts_defenced >/dev/null 2>&1 ||
  source "${_PLANNER_CROSSCHECK_PARAMS_LIB_DIR}/planner-crosscheck-contracts.sh"
declare -f planner_params_literals >/dev/null 2>&1 ||
  source "${_PLANNER_CROSSCHECK_PARAMS_LIB_DIR}/planner-specify-params.sh"

# _planner_crosscheck_params_places <ac|vn> — stdin (a defenced spec) to
# stdout with the same line count: only the checked text of one place kept,
# every other line blank. `vn` keeps the Expected cell of each table row.
_planner_crosscheck_params_places() {
  # shellcheck disable=SC2016  # awk program, not shell
  LC_ALL=C PCP_WANT="$1" _planner_params_awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN { want = ENVIRON["PCP_WANT"]; sect = ""; intable = 0; vcol = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^##?[ \t]/) {
        h = line; sub(/^##?[ \t]+/, "", h); h = trim(h)
        sect = (h == "Acceptance Criteria") ? "ac" : ((h == "Verification Notes") ? "vn" : "")
        intable = 0; vcol = 0
        print ""; next
      }
      if (sect == "ac" && want == "ac") { print line; next }
      if (sect == "vn" && want == "vn" && line ~ /^[ \t]*\|/) {
        row = line
        gsub(/\\\|/, "\001", row)
        sub(/^[ \t]*\|/, "", row)
        sub(/\|[ \t]*$/, "", row)
        n = split(row, C, "|")
        if (!intable) {
          intable = 1; vcol = 0
          for (k = 1; k <= n; k++) if (tolower(trim(C[k])) == "expected") { vcol = k; break }
          print ""; next
        }
        if (vcol == 0 || vcol > n || trim(C[vcol]) ~ /^:?-+:?$/) { print ""; next }
        cell = C[vcol]
        gsub(/\001/, "\\|", cell)
        print cell; next
      }
      if (line !~ /^[ \t]*\|/) { intable = 0; vcol = 0 }
      print ""
    }
  '
}

# The canonical forms of every literal in <text>, space-separated.
_planner_crosscheck_params_value_canons() {
  printf '%s\n' "$1" | planner_params_literals - | cut -f2 | tr '\n' ' '
}

_planner_crosscheck_params_reason() {
  case "$1" in
  missing) echo "proposal.md has no ## Parameters section — a contract initiative must declare its parameters (a table, or None.)" ;;
  empty) echo "## Parameters is empty — write the table, or None." ;;
  no-table) echo "## Parameters holds text where the table (or None.) should start" ;;
  duplicate-section) echo "a second ## Parameters section — keep one" ;;
  header) echo "the header is not Name | Key | Kind | Default | Value | Source" ;;
  shape) echo "the row does not have six cells" ;;
  name) echo "the Name cell is empty" ;;
  key) echo "the Key is not a backticked letter followed by letters, digits, _ . - (at most 64)" ;;
  duplicate-key) echo "the Key is already used by an earlier row" ;;
  kind) echo "the Kind is not one of ${PLANNER_PARAMS_KINDS}" ;;
  value) echo "the Value cell is empty" ;;
  source) echo "the Source is not default, — (open rows only), <artifact>:\"<quote>\", code:<path>:\"<quote>\" or human:r<N>:<client|operator>" ;;
  *) echo "invalid (${1})" ;;
  esac
}

planner_crosscheck_params() {
  local init="$1"
  local repos_root="${REPOS_ROOT:-}"
  [ -n "$repos_root" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  planner_params_contract_initiative "$init" || return 0

  local dir specs_dir found=0 out
  dir=$(planner_initiative_dir "$init") || return 1
  specs_dir="${dir}/artifacts/specs"

  # PARAM_TABLE_INVALID
  local ln reason
  out=$(planner_params_invalid "$init") || {
    echo "planner-crosscheck-params: PARAM_TABLE_INVALID proposal.md could not be read"
    return 1
  }
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    reason="${ln#*$'\t'}"
    ln="${ln%%$'\t'*}"
    if [ "$ln" = 0 ]; then
      echo "planner-crosscheck-params: PARAM_TABLE_INVALID $(_planner_crosscheck_params_reason "$reason")"
    else
      echo "planner-crosscheck-params: PARAM_TABLE_INVALID proposal.md:${ln} $(_planner_crosscheck_params_reason "$reason")"
    fi
    found=1
  done <<<"$out"

  # PARAM_UNDECIDED. Scan lines are <key>\t<line>\t<kind>\t<name>\t<suggestion>\t<question>;
  # read with cut (the suggestion may be empty).
  local scan line key open_keys=" "
  scan=$(planner_params_scan "$init") || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=$(cut -f1 <<<"$line")
    open_keys+="${key} "
    echo "planner-crosscheck-params: PARAM_UNDECIDED proposal.md:$(cut -f2 <<<"$line") \`${key}\` is still open — $(cut -f6- <<<"$line")"
    found=1
  done <<<"$scan"

  # Coverage from the closed valid rows.
  local rows kind val global=" " c
  declare -A fixed_canons=()
  rows=$(planner_params_rows "$init") || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=$(cut -f2 <<<"$line")
    case "$open_keys" in *" ${key} "*) continue ;; esac
    kind=$(cut -f3 <<<"$line")
    val=$(cut -f6 <<<"$line")
    c=$(_planner_crosscheck_params_value_canons "$val")
    [ -n "${c// /}" ] || continue
    if [ "$kind" = fixed ]; then
      fixed_canons["$key"]=" ${c}"
    else
      global+="${c}"
    fi
  done <<<"$rows"

  [ -d "$specs_dir" ] || {
    [ "$found" -eq 0 ]
    return
  }

  local spec_file base slug covered place where lnum canon lit
  local marker="${PLANNER_TESTDATA_SYNTH_MARKER:-<!-- planner:testdata-synth v1 -->}"
  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    base="$(basename "$spec_file")"
    [ "$base" = "INDEX.md" ] && continue
    grep -qF -- "$marker" "$spec_file" 2>/dev/null && continue
    slug="${base%.md}"
    covered="$global"
    for key in "${!fixed_canons[@]}"; do
      grep -qF -- "\`${key}\`" "$spec_file" && covered+="${fixed_canons[$key]}"
    done
    for place in ac vn; do
      if [ "$place" = ac ]; then where="Acceptance Criteria"; else where="the Verification Notes Expected column"; fi
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        lnum=$(cut -f1 <<<"$line")
        canon=$(cut -f2 <<<"$line")
        lit=$(cut -f3- <<<"$line" | tr -s ' \t' '  ')
        case "$covered" in *" ${canon} "*) continue ;; esac
        echo "planner-crosscheck-params: PARAM_LITERAL specs/${base}:${lnum} \"${lit}\" (${canon}) in ${where} is not declared in ## Parameters — resume ${init} --accept PARAM_LITERAL@${slug}:\"${lit}\""
        found=1
      done < <(_planner_crosscheck_contracts_defenced "$spec_file" | _planner_crosscheck_params_places "$place" | planner_params_literals -)
    done
  done
  [ "$found" -eq 0 ]
}

planner_crosscheck_params_accept_parse() {
  local arg="$1" rest slug lit canon
  case "$arg" in
  PARAM_LITERAL@*:*) ;;
  *)
    echo "ERROR: --accept PARAM_LITERAL is per literal: --accept PARAM_LITERAL@<slug>:\"<literal>\", or --accept PARAM_LITERAL@*:\"<reason>\" for every literal the latest Crosscheck attempt found (got '${arg}')" >&2
    return 1
    ;;
  esac
  rest="${arg#PARAM_LITERAL@}"
  slug="${rest%%:*}"
  lit="${rest#*:}"
  if [[ ! "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    echo "ERROR: --accept PARAM_LITERAL@<slug>: '${slug}' is not a spec slug (letters, digits, - and _)" >&2
    return 1
  fi
  if [ "${#lit}" -ge 2 ] && [ "${lit:0:1}" = '"' ] && [ "${lit: -1}" = '"' ]; then
    lit="${lit:1:${#lit}-2}"
  fi
  lit=$(printf '%s' "$lit" | tr -s ' \t' '  ')
  lit="${lit#"${lit%%[![:space:]]*}"}"
  lit="${lit%"${lit##*[![:space:]]}"}"
  case "$lit" in
  *'"'* | "")
    echo "ERROR: --accept PARAM_LITERAL@${slug}: give exactly one unit literal, e.g. PARAM_LITERAL@${slug}:\"15 minutes\"" >&2
    return 1
    ;;
  esac
  if ! canon=$(_planner_params_canon "$lit"); then
    echo "ERROR: --accept PARAM_LITERAL@${slug}: '${lit}' is not exactly one unit literal, e.g. PARAM_LITERAL@${slug}:\"15 minutes\"" >&2
    return 1
  fi
  printf 'PARAM_LITERAL@%s=%s\t%s\n' "$slug" "$canon" "$lit"
}

planner_crosscheck_params_literal() {
  [[ "$1" =~ ^[^\"]*\"([^\"]*)\" ]] || return 0
  printf '%s\n' "${BASH_REMATCH[1]}"
}

planner_crosscheck_params_instance() {
  local msg="$1" slug canon
  [[ "$msg" =~ --accept\ PARAM_LITERAL@([A-Za-z0-9_-]+): ]] || return 0
  slug="${BASH_REMATCH[1]}"
  [[ "$msg" =~ \ \(([a-z]+:[0-9]+)\)\ in\  ]] || return 0
  canon="${BASH_REMATCH[1]}"
  printf 'PARAM_LITERAL@%s=%s\n' "$slug" "$canon"
}
