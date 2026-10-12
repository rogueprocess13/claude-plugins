#!/usr/bin/env bash
# planner-crosscheck-testdata.sh — Test-data provenance + cited-artifact checks.
#
# Part of the Crosscheck check family (#178). Two related gaps, one file:
#
# 1. Test-data provenance (#503). Specify's `## Verification Notes` lines say
#    WHAT data a criterion needs (`Test data: 5 seeded invoices`) and, since
#    #503, WHERE it comes from (`Source: <kind>[:<value>]`). Every later
#    test-data check is per-ticket, so data no spec produces passes them all;
#    the shared, unowned nature of the data only shows across specs.
#    planner_crosscheck_testdata aggregates every need across the initiative
#    and reports the unowned ones as ONE blocking TEST_DATA_UNOWNED finding
#    naming every affected spec and proposing a test-data-pack enabler spec.
#
#    In-flight initiatives are grandfathered. An initiative created by this
#    contract carries `META|contract|start|test-data-source-v1` (written by
#    planner_state_init). Without that marker, a spec whose Verification Notes
#    carry no Source field at all is a legacy spec: its needs are reported as
#    the warn-level TEST_DATA_UNSOURCED_LEGACY instead of blocking.
#
# 2. Cited external artifacts (#504). Discovery records every external
#    artifact the source material cites under discovery.md `## Cited
#    Artifacts`, FOUND or NOT FOUND. Each NOT FOUND one must reach the operator
#    as a Consensus open question; the answer is the test-data Source for the
#    specs that use the artifact. planner_crosscheck_cited_artifacts reports:
#      CITED_ARTIFACT_MALFORMED          a list item it cannot parse (blocking)
#      CITED_ARTIFACT_UNRAISED           no question in consensus.md (blocking)
#      CITED_ARTIFACT_UNRESOLVED         answer still PENDING/malformed (blocking)
#      CITED_ARTIFACT_SOURCE_MISMATCH    a spec's Source disagrees with the
#                                        recorded answer (blocking)
#      CITED_ARTIFACTS_SECTION_MISSING   discovery.md has no section, contract
#                                        initiatives only (warn)
#    The stop is the existing CROSSCHECK_BLOCKED one — no new gate.
#
# Every finding is one line with `|`, CR and LF removed: findings go into the
# pipe-delimited state log.
#
# The grammars parsed here are the contract in docs/test-data-source.md.
# ticket-auto-pipeline's readiness check reads the same Source grammar from
# ticket bodies — keep them in step.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_TESTDATA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f _planner_crosscheck_known_slugs >/dev/null 2>&1; then
  # shellcheck source=planner-crosscheck-propagation.sh
  [ -f "${_PLANNER_CROSSCHECK_TESTDATA_LIB_DIR}/planner-crosscheck-propagation.sh" ] &&
    source "${_PLANNER_CROSSCHECK_TESTDATA_LIB_DIR}/planner-crosscheck-propagation.sh"
fi
if ! declare -f planner_deps_is_external_ref >/dev/null 2>&1; then
  # shellcheck source=planner-deps-check.sh
  [ -f "${_PLANNER_CROSSCHECK_TESTDATA_LIB_DIR}/planner-deps-check.sh" ] &&
    source "${_PLANNER_CROSSCHECK_TESTDATA_LIB_DIR}/planner-deps-check.sh"
fi
if ! declare -f planner_config_get >/dev/null 2>&1; then
  # shellcheck source=planner-state.sh
  [ -f "${_PLANNER_CROSSCHECK_TESTDATA_LIB_DIR}/planner-state.sh" ] &&
    source "${_PLANNER_CROSSCHECK_TESTDATA_LIB_DIR}/planner-state.sh"
fi

# The contract version planner_state_init records for new initiatives.
PLANNER_TESTDATA_CONTRACT="test-data-source-v1"

# The closed Source enum. `none` is only valid when the test data is none.
PLANNER_TESTDATA_SOURCE_KINDS="exists seeded-by external generate none"

# How many unowned needs a finding lists before summarising the rest.
PLANNER_TESTDATA_MAX_ITEMS=25

# An unscoped "implementation does not write tests" rule: a negation, a verb,
# optional qualifiers, then "tests" ending the clause. A rule scoped by what
# follows ("for generated code", "that hit the network") does not match.
PLANNER_TESTDATA_NO_TESTS_RE="(do(es)?[[:space:]]+not|don'?t|never|must[[:space:]]+not|should[[:space:]]+not|shall[[:space:]]+not)[[:space:]]+(write|add|create|author)[[:space:]]+(any[[:space:]]+)?((unit|automated|integration|e2e)[[:space:]]+)?(tests|test[[:space:]]+(code|files|fixtures))[[:space:]]*([.;!]|$)"

_planner_testdata_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# One state-log-safe line: `|` → `/`, CR/LF → space.
_planner_testdata_safe() {
  printf '%s' "$1" | tr '|\r\n' '/  '
}

_planner_testdata_emit() {
  printf '%s\n' "$(_planner_testdata_safe "$1")"
}

_planner_testdata_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Join items with "; ", listing at most PLANNER_TESTDATA_MAX_ITEMS.
_planner_testdata_join_items() {
  local max="$PLANNER_TESTDATA_MAX_ITEMS" n=0 out="" it
  for it in "$@"; do
    n=$((n + 1))
    [ "$n" -le "$max" ] && out="${out}${out:+; }${it}"
  done
  [ "$n" -gt "$max" ] && out="${out}; … and $((n - max)) more"
  printf '%s' "$out"
}

# Print the body of the first `##`/`###` heading starting with <heading>
# (case-insensitive prefix, so `## Verification Notes (per AC)` counts), up to
# the next heading, outside fenced code blocks, CR stripped.
# Usage: _planner_testdata_section <file> <heading>
_planner_testdata_section() {
  local file="$1" heading="$2"
  [ -f "$file" ] || return 0
  tr -d '\r' <"$file" | awk -v h="$(_planner_testdata_lower "$heading")" '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    /^#+[[:space:]]/ {
      if (on) exit
      line = tolower($0); sub(/^#+[[:space:]]+/, "", line); gsub(/[*_]/, "", line)
      if ((/^##[[:space:]]/ || /^###[[:space:]]/) && index(line, h) == 1) { on = 1; next }
    }
    on { print }
  '
}

# Does <file> have such a section at all (even an empty one)?
_planner_testdata_has_section() {
  local file="$1" heading="$2"
  [ -f "$file" ] || return 1
  tr -d '\r' <"$file" | awk -v h="$(_planner_testdata_lower "$heading")" '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    /^##+[[:space:]]/ { line = tolower($0); sub(/^#+[[:space:]]+/, "", line); gsub(/[*_]/, "", line)
      if (index(line, h) == 1) { found = 1; exit } }
    END { exit !found }
  '
}

_planner_testdata_state_dir() {
  printf '%s' "${REPOS_ROOT}/.ticket-auto/initiatives/$1"
}

# Was <initiative_id> created under this contract (planner_state_init marker)?
planner_testdata_contract_initiative() {
  local log
  log="$(_planner_testdata_state_dir "$1")/state.log"
  [ -f "$log" ] && grep -q "^[^|]*|META|contract|start|.*${PLANNER_TESTDATA_CONTRACT}" "$log" 2>/dev/null
}

# ── No-tests rule (#503 point 4) ────────────────────────────────────────────

# Is the no-tests rule active for <initiative_id>? Reads the persisted config
# only (`no-tests-rule`, written at argument parsing) — never the environment.
# Output: where the rule came from (the recorded source, or "config").
# Returns: 0 if active, 1 otherwise.
planner_testdata_no_tests_rule() {
  local init="$1" value log src
  value=$(planner_config_get "$init" "no-tests-rule" 2>/dev/null)
  [ "$value" = "true" ] || return 1
  log="$(_planner_testdata_state_dir "$init")/state.log"
  src=$(grep '^[^|]*|META|no-tests-rule-source|' "$log" 2>/dev/null | tail -1 | cut -d'|' -f5-)
  printf '%s' "${src:-config}"
  return 0
}

# Look for an unscoped no-tests rule in ${REPOS_ROOT}/CLAUDE.md and
# ${REPOS_ROOT}/*/CLAUDE.md. Output: "<file>:<line>: <text>" of the first hit.
# Returns: 0 on a hit, 1 otherwise. Writes nothing.
planner_testdata_no_tests_rule_scan() {
  local repos_root="${REPOS_ROOT:-}" f hit
  [ -n "$repos_root" ] || return 1
  for f in "${repos_root}/CLAUDE.md" "${repos_root}"/*/CLAUDE.md; do
    [ -f "$f" ] || continue
    hit=$(tr -d '\r' <"$f" | grep -niE "$PLANNER_TESTDATA_NO_TESTS_RE" 2>/dev/null | head -1) || true
    if [ -n "$hit" ]; then
      printf '%s:%s' "$f" "$(_planner_testdata_safe "$hit")"
      return 0
    fi
  done
  return 1
}

# Persist the no-tests rule for <initiative_id>, once, at argument parsing.
#   <flag> true|false — the operator decided (--no-tests-rule[=…]); always written.
#   <flag> empty      — detect from CLAUDE.md, but only if nothing is persisted
#                       yet; the result (and where it came from) is written,
#                       so a later CLAUDE.md edit cannot flip a running plan.
# Usage: planner_testdata_no_tests_rule_persist <initiative_id> [true|false]
planner_testdata_no_tests_rule_persist() {
  local init="$1" flag="${2:-}" hit
  case "$flag" in
  true | false)
    planner_state_write "$init" "META" "no-tests-rule-source" "info" "operator flag --no-tests-rule=${flag}"
    planner_config_set "$init" "no-tests-rule" "$flag"
    return 0
    ;;
  esac
  planner_config_is_set "$init" "no-tests-rule" && return 0
  if hit=$(planner_testdata_no_tests_rule_scan); then
    planner_state_write "$init" "META" "no-tests-rule-source" "info" "detected ${hit}"
    planner_config_set "$init" "no-tests-rule" "true"
  else
    planner_config_set "$init" "no-tests-rule" "false"
  fi
}

# ── Source parsing ──────────────────────────────────────────────────────────

# Is <data> an explicit "no test data" value?
_planner_testdata_is_none() {
  local d
  d=$(_planner_testdata_lower "$(_planner_testdata_trim "$1")")
  d="${d%%[.;,]*}"
  d=$(_planner_testdata_trim "$d")
  case "$d" in
  "" | none | none\ * | none\(* | n/a | n/a\ * | na | - | nothing | nothing\ * | \
    not\ applicable* | no\ special\ data* | no\ special\ test\ data* | no\ test\ data* | \
    no\ data\ required* | no\ data\ needed* | no\ setup* | no\ special\ setup*) return 0 ;;
  esac
  return 1
}

# Normalize one Verification Notes line: drop markdown emphasis, canonicalize
# the two markers. Usage: _planner_testdata_norm_line <line>
_planner_testdata_norm_line() {
  printf '%s' "$1" | tr -d '\r*' |
    sed -E 's/(^|[[:space:]])_+([A-Za-z])/\1\2/g; s/([A-Za-z.:])_+([[:space:]]|$)/\1\2/g' |
    sed -E 's/[Tt][Ee][Ss][Tt][ -]?[Dd][Aa][Tt][Aa][[:space:]]*:/Test data:/g; s/[Ss][Oo][Uu][Rr][Cc][Ee][[:space:]]*:/Source:/g'
}

# Parse one segment (text after a `Test data:` marker) into
# "<data>\x1f<kind>\x1f<value>". The LAST `Source:` wins. kind is lowercased,
# empty when the segment carries no Source.
_planner_testdata_parse_segment() {
  local seg="$1" data src kind value
  if [[ "$seg" == *"Source:"* ]]; then
    data="${seg%Source:*}"
    src="${seg##*Source:}"
    src="${src//\`/}"
    src=$(_planner_testdata_trim "$src")
    while [[ "$src" =~ [.,\;:!]$ ]]; do src="${src%?}"; done
    if [[ "$src" == *:* ]]; then
      kind="${src%%:*}"
      value="${src#*:}"
    else
      kind="${src%%[[:space:]]*}"
      value=""
    fi
    kind=$(_planner_testdata_lower "$(_planner_testdata_trim "$kind")")
    value=$(_planner_testdata_trim "$value")
  else
    data="$seg"
    kind=""
    value=""
  fi
  data=$(_planner_testdata_trim "$data")
  while [[ "$data" =~ [.,\;]$ ]]; do data="${data%?}"; done
  printf '%s\037%s\037%s\n' "$data" "$kind" "$value"
}

# Every test-data need in one spec, one record per line:
#   <label>\x1f<data>\x1f<kind>\x1f<value>
# label is the item's number (numbered lists) or b<k> (k-th bullet).
_planner_testdata_spec_needs() {
  local spec_file="$1" line label bullets=0 rest seg parsed
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[.\)][[:space:]] ]]; then
      label="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*[-*+][[:space:]] ]]; then
      bullets=$((bullets + 1))
      label="b${bullets}"
    else
      continue
    fi
    line=$(_planner_testdata_norm_line "$line")
    [[ "$line" == *"Test data:"* ]] || continue
    rest="$line"
    while [[ "$rest" == *"Test data:"* ]]; do
      rest="${rest#*Test data:}"
      seg="${rest%%Test data:*}"
      parsed=$(_planner_testdata_parse_segment "$seg")
      printf '%s\037%s\n' "$label" "$parsed"
    done
  done < <(_planner_testdata_section "$spec_file" "Verification Notes")
}

# Does the spec carry at least one Source field (marks it as written to this
# contract, even in a legacy initiative)?
_planner_testdata_spec_has_source() {
  local body
  body=$(_planner_testdata_section "$1" "Verification Notes")
  body=$(_planner_testdata_norm_line "$body")
  [[ "$body" == *"Source:"* ]]
}

# Resolve a seeded-by ref to a sibling slug: exact, or the unambiguous
# `-`-bounded prefix of exactly one — the DANGLING_BLOCKED_BY rule.
_planner_testdata_resolve_slug() {
  local ref="$1" s
  shift
  local -a matches=()
  for s in "$@"; do
    [ "$s" = "$ref" ] && {
      echo "$s"
      return 0
    }
  done
  for s in "$@"; do
    case "$s" in "${ref}-"*) matches+=("$s") ;; esac
  done
  [ "${#matches[@]}" -eq 1 ] && echo "${matches[0]}"
  return 0
}

# ── Cited artifacts (#504) parsing ──────────────────────────────────────────

# Every list item under discovery.md `## Cited Artifacts`:
#   <STATUS>\x1f<name>\x1f<raw>     STATUS = FOUND | NOT_FOUND | MALFORMED
# Shape: `- <name> — FOUND: <loc>` / `- <name> — NOT FOUND (searched: …)`.
# Bullets or numbered items; name backticked or bare; separator —, – or -.
# The status is the first token after the separator, case-insensitive.
_planner_cited_entries() {
  local discovery="$1" line item name rest status up
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([-*+]|[0-9]+[.\)])[[:space:]]+(.*)$ ]]; then
      item="${BASH_REMATCH[2]}"
    else
      continue
    fi
    item=$(_planner_testdata_trim "$item")
    up=$(_planner_testdata_lower "$(printf '%s' "$item" | tr -d '*_')")
    case "$up" in none | none.) continue ;; esac
    name=""
    rest=""
    if [[ "$item" =~ ^[*_]*\`([^\`]+)\`[*_]*(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
    elif [[ "$item" == *" — "* ]]; then
      name="${item%% — *}"
      rest=" — ${item#* — }"
    elif [[ "$item" == *" – "* ]]; then
      name="${item%% – *}"
      rest=" – ${item#* – }"
    elif [[ "$item" == *" - "* ]]; then
      name="${item%% - *}"
      rest=" - ${item#* - }"
    fi
    name=$(_planner_testdata_trim "$(printf '%s' "$name" | tr -d '*')")
    rest=$(_planner_testdata_trim "$rest")
    # Strip the separator, then emphasis, then read the status token.
    rest="${rest#—}"
    rest="${rest#–}"
    rest="${rest#-}"
    rest="${rest#:}"
    rest=$(_planner_testdata_trim "$(printf '%s' "$rest" | tr -d '*_')")
    up=$(printf '%s' "$rest" | tr '[:lower:]' '[:upper:]')
    status="MALFORMED"
    if [ -n "$name" ]; then
      if [[ "$up" =~ ^NOT[[:space:]]+FOUND([^A-Z]|$) ]]; then
        status="NOT_FOUND"
      elif [[ "$up" =~ ^FOUND([^A-Z]|$) ]]; then
        status="FOUND"
      fi
    fi
    printf '%s\037%s\037%s\n' "$status" "$name" "$(_planner_testdata_safe "$item")"
  done < <(_planner_testdata_section "$discovery" "Cited Artifacts")
}

# Cited artifacts discovery.md lists as NOT FOUND, one name per line.
# Usage: planner_cited_artifacts_missing <initiative_id>
planner_cited_artifacts_missing() {
  [ -n "${REPOS_ROOT:-}" ] || return 0
  local discovery status name raw
  discovery="$(_planner_testdata_state_dir "$1")/artifacts/discovery.md"
  while IFS=$'\037' read -r status name raw; do
    [ "$status" = "NOT_FOUND" ] && printf '%s\n' "$name"
  done < <(_planner_cited_entries "$discovery")
  return 0
}

# Canonical open-question lines for every NOT FOUND cited artifact — the
# Consensus agent copies these verbatim into consensus.md `## Open Questions`.
# Usage: planner_cited_artifacts_questions <initiative_id>
planner_cited_artifacts_questions() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf -- '- CITED_ARTIFACT: `%s` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: PENDING\n' "$name"
  done < <(planner_cited_artifacts_missing "$1")
}

# Answers recorded in consensus.md, one per line:
#   <lowercased name>\x1f<kind>\x1f<value>\x1f<raw answer>
# kind ∈ exists | external | generate when the answer is well formed, else
# "unresolved". Last line for a name wins.
_planner_cited_answers() {
  local consensus="$1" line qname answer kind value
  [ -f "$consensus" ] || return 0
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr -d '\r*')
    [[ "$line" == *"CITED_ARTIFACT:"* ]] || continue
    line="${line#*CITED_ARTIFACT:}"
    [[ "$line" =~ \`([^\`]+)\` ]] || continue
    qname=$(_planner_testdata_lower "$(_planner_testdata_trim "${BASH_REMATCH[1]}")")
    answer=""
    [[ "$line" == *"Answer:"* ]] && answer="${line##*Answer:}"
    answer=$(_planner_testdata_trim "${answer//\`/}")
    answer="${answer#_}"
    answer="${answer%_}"
    while [[ "$answer" =~ [.,\;:!]$ ]]; do answer="${answer%?}"; done
    kind=$(_planner_testdata_lower "${answer%%:*}")
    value=""
    [[ "$answer" == *:* ]] && value=$(_planner_testdata_trim "${answer#*:}")
    case "$kind" in
    generate) [ "$answer" = "${answer%%:*}" ] || kind="unresolved" ;;
    external | exists) [ -n "$value" ] || kind="unresolved" ;;
    *) kind="unresolved" ;;
    esac
    printf '%s\037%s\037%s\037%s\n' "$qname" "$kind" "$value" "$(_planner_testdata_safe "$answer")"
  done <"$consensus"
}

# Does <data> name the cited artifact <name>? A backticked mention equal to
# the name, or the whole name as a case-insensitive substring.
_planner_testdata_names_artifact() {
  local data_l name_l
  data_l=$(_planner_testdata_lower "$1")
  name_l=$(_planner_testdata_lower "$2")
  [ -n "$name_l" ] && [[ "$data_l" == *"$name_l"* ]]
}

# ── Check 1: unowned test data (#503) ───────────────────────────────────────

# Usage: planner_crosscheck_testdata <initiative_id>
# Returns: 0 if clean (or warn-only), 1 if a blocking finding was reported.
planner_crosscheck_testdata() {
  local initiative_id="$1"
  [ -n "${REPOS_ROOT:-}" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  local state_dir specs_dir
  state_dir=$(_planner_testdata_state_dir "$initiative_id")
  specs_dir="${state_dir}/artifacts/specs"
  [ -d "$specs_dir" ] || return 0

  local -a known_slugs
  mapfile -t known_slugs < <(_planner_crosscheck_known_slugs "$specs_dir")
  [ "${#known_slugs[@]}" -ge 1 ] || return 0

  local strict_init=false no_tests=false no_tests_src=""
  planner_testdata_contract_initiative "$initiative_id" && strict_init=true
  no_tests_src=$(planner_testdata_no_tests_rule "$initiative_id") && no_tests=true

  # Cited artifacts still awaiting an answer: a `generate` need that names one
  # is CITED_ARTIFACT_UNRESOLVED's business, not this check's.
  local -a pending=()
  local discovery="${state_dir}/artifacts/discovery.md" name
  local -A answer_kind=()
  local qn qk qv qr
  while IFS=$'\037' read -r qn qk qv qr; do answer_kind["$qn"]="$qk"; done \
    < <(_planner_cited_answers "${state_dir}/artifacts/consensus.md")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "${answer_kind[$(_planner_testdata_lower "$name")]:-unresolved}" in
    unresolved) pending+=("$name") ;;
    esac
  done < <(planner_cited_artifacts_missing "$initiative_id")

  local -a items=() legacy_items=()
  local -A affected=() legacy_affected=()
  local spec_file base strict label data kind value reason target provided p skip

  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    base="$(basename "$spec_file" .md)"
    [ "$base" = "INDEX" ] && continue
    strict=$strict_init
    [ "$strict" = true ] || ! _planner_testdata_spec_has_source "$spec_file" || strict=true

    while IFS=$'\037' read -r label data kind value; do
      reason=""
      if [ -z "$kind" ]; then
        _planner_testdata_is_none "$data" || reason="missing Source"
      else
        case " ${PLANNER_TESTDATA_SOURCE_KINDS} " in
        *" ${kind} "*) ;;
        *) reason="unknown Source kind '${kind}'" ;;
        esac
        if [ -z "$reason" ]; then
          case "$kind" in
          none) _planner_testdata_is_none "$data" || reason="Source: none for real test data" ;;
          generate)
            skip=false
            for p in "${pending[@]}"; do
              _planner_testdata_names_artifact "$data" "$p" && skip=true
            done
            [ "$skip" = true ] || reason="generate"
            ;;
          exists | external) [ -n "$value" ] || reason="${kind} with no value" ;;
          seeded-by)
            value="${value%%[[:space:]]*}"
            if [ -z "$value" ]; then
              reason="seeded-by with no slug"
            else
              target=$(_planner_testdata_resolve_slug "$value" "${known_slugs[@]}")
              if [ -z "$target" ]; then
                planner_deps_is_external_ref "$value" ||
                  reason="seeded-by:${value} names no sibling spec"
              elif [ "$target" = "$base" ] && [ "$no_tests" = true ]; then
                reason="self-seeded, but the project forbids implementation writing tests"
              else
                provided=$(_planner_testdata_section "${specs_dir}/${target}.md" "Test Data Provided" | grep -cE '[^[:space:]]' || true)
                [ "${provided:-0}" -gt 0 ] ||
                  reason="seeded-by:${value} resolves to ${target}.md, which has no ## Test Data Provided section"
              fi
            fi
            ;;
          esac
        fi
      fi

      [ -n "$reason" ] || continue
      if [ "$strict" = true ]; then
        items+=("${base}.md#${label} (${reason})")
        affected["$base"]=1
      else
        legacy_items+=("${base}.md#${label} (${reason})")
        legacy_affected["$base"]=1
      fi
    done < <(_planner_testdata_spec_needs "$spec_file")
  done

  local specs
  if [ "${#legacy_items[@]}" -gt 0 ]; then
    specs=$(printf '%s\n' "${!legacy_affected[@]}" | LC_ALL=C sort | paste -sd, - | sed 's/,/, /g')
    _planner_testdata_emit "planner-crosscheck-testdata: TEST_DATA_UNSOURCED_LEGACY ${#legacy_items[@]} test-data need(s) across ${#legacy_affected[@]} legacy spec(s) [${specs}] predate the Source field: $(_planner_testdata_join_items "${legacy_items[@]}") — add Source: to these lines (docs/test-data-source.md); not blocking because the initiative predates the contract"
  fi

  [ "${#items[@]}" -eq 0 ] && return 0

  specs=$(printf '%s\n' "${!affected[@]}" | LC_ALL=C sort | paste -sd, - | sed 's/,/, /g')
  local remedy="remedy: add an enabler spec (e.g. specs/test-data-pack.md, Kind enabler) whose ## Test Data Provided section lists the generator + seed scripts it delivers, then set each need's Source to seeded-by:<that-slug> as its verification prerequisite"
  if [ "$no_tests" = true ]; then
    remedy="MANDATORY ${remedy} — the project forbids implementation writing tests (${no_tests_src}), so no ticket will produce this data as a side effect"
  fi
  _planner_testdata_emit "planner-crosscheck-testdata: TEST_DATA_UNOWNED ${#items[@]} test-data need(s) across ${#affected[@]} spec(s) [${specs}] have no owning spec: $(_planner_testdata_join_items "${items[@]}") — ${remedy}"
  return 1
}

# ── Check 2: cited artifacts (#504) ─────────────────────────────────────────

# Usage: planner_crosscheck_cited_artifacts <initiative_id>
# Returns: 0 if clean (or warn-only), 1 if a blocking finding was reported.
planner_crosscheck_cited_artifacts() {
  local initiative_id="$1"
  [ -n "${REPOS_ROOT:-}" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  local state_dir discovery consensus specs_dir
  state_dir=$(_planner_testdata_state_dir "$initiative_id")
  discovery="${state_dir}/artifacts/discovery.md"
  consensus="${state_dir}/artifacts/consensus.md"
  specs_dir="${state_dir}/artifacts/specs"
  [ -f "$discovery" ] || return 0

  if ! _planner_testdata_has_section "$discovery" "Cited Artifacts"; then
    planner_testdata_contract_initiative "$initiative_id" &&
      _planner_testdata_emit "planner-crosscheck-testdata: CITED_ARTIFACTS_SECTION_MISSING discovery.md has no ## Cited Artifacts section — re-run Discovery or add the section (FOUND / NOT FOUND per cited artifact, or None.)"
    return 0
  fi

  local -A answer_kind=() answer_value=() answer_raw=()
  local qn qk qv qr
  while IFS=$'\037' read -r qn qk qv qr; do
    answer_kind["$qn"]="$qk"
    answer_value["$qn"]="$qv"
    answer_raw["$qn"]="$qr"
  done < <(_planner_cited_answers "$consensus")

  local blocking=0 status name raw key
  local -a missing=()
  while IFS=$'\037' read -r status name raw; do
    case "$status" in
    MALFORMED)
      _planner_testdata_emit "planner-crosscheck-testdata: CITED_ARTIFACT_MALFORMED discovery.md ## Cited Artifacts item cannot be parsed: \"${raw}\" — write it as \`<name>\` — FOUND: <location> or \`<name>\` — NOT FOUND (searched: …)"
      blocking=1
      ;;
    NOT_FOUND)
      missing+=("$name")
      key=$(_planner_testdata_lower "$name")
      if [ -z "${answer_kind[$key]+set}" ]; then
        _planner_testdata_emit "planner-crosscheck-testdata: CITED_ARTIFACT_UNRAISED consensus.md has no open question for cited artifact \`${name}\`, which discovery.md lists as NOT FOUND"
        blocking=1
      elif [ "${answer_kind[$key]}" = "unresolved" ]; then
        _planner_testdata_emit "planner-crosscheck-testdata: CITED_ARTIFACT_UNRESOLVED consensus.md open question for cited artifact \`${name}\` is unanswered (Answer: ${answer_raw[$key]:-<empty>}) — provide it (Answer: exists:<where>), name who supplies it (Answer: external:<who>), or confirm it should be synthesised (Answer: generate)"
        blocking=1
      fi
      ;;
    esac
  done < <(_planner_cited_entries "$discovery")

  # Every spec need that names a NOT FOUND artifact must carry the Source the
  # recorded answer implies. Before an answer it stays `generate`.
  if [ "${#missing[@]}" -gt 0 ] && [ -d "$specs_dir" ]; then
    local spec_file base label data kind value want ok
    for spec_file in "$specs_dir"/*.md; do
      [ -f "$spec_file" ] || continue
      base="$(basename "$spec_file" .md)"
      [ "$base" = "INDEX" ] && continue
      while IFS=$'\037' read -r label data kind value; do
        [ -n "$kind" ] || continue
        for name in "${missing[@]}"; do
          _planner_testdata_names_artifact "$data" "$name" || continue
          key=$(_planner_testdata_lower "$name")
          ok=true
          case "${answer_kind[$key]:-unresolved}" in
          unresolved)
            want="generate (unanswered)"
            [ "$kind" = "generate" ] || ok=false
            ;;
          generate)
            want="generate or seeded-by:<pack>"
            case "$kind" in generate | seeded-by) ;; *) ok=false ;; esac
            ;;
          external | exists)
            want="${answer_kind[$key]}:${answer_value[$key]}"
            if [ "$kind" != "${answer_kind[$key]}" ] ||
              [ "$(_planner_testdata_lower "$value")" != "$(_planner_testdata_lower "${answer_value[$key]}")" ]; then
              ok=false
            fi
            ;;
          esac
          if [ "$ok" = false ]; then
            _planner_testdata_emit "planner-crosscheck-testdata: CITED_ARTIFACT_SOURCE_MISMATCH ${base}.md#${label} uses cited artifact \`${name}\` with Source: ${kind}${value:+:${value}}, but consensus.md records ${want} — make the spec's Source match the operator's answer"
            blocking=1
          fi
        done
      done < <(_planner_testdata_spec_needs "$spec_file")
    done
  fi

  [ "$blocking" -eq 0 ]
}
