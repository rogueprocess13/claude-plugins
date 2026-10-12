#!/usr/bin/env bash
# planner-crosscheck-testdata.sh — Test-data provenance + cited-artifact checks.
#
# Part of the Crosscheck check family (#178). Two related gaps, one file:
#
# 1. Test-data provenance (#503). Specify's `## Verification Notes` lines say
#    WHAT data a criterion needs (`Test data: 5 seeded invoices`) and, since
#    #503, WHERE it comes from (`Source: <kind>[:<value>]`). Every later
#    test-data check is per-ticket, so data that no spec actually produces
#    passes them all: the shared, unowned nature of the data is only visible
#    across specs, which is Crosscheck's job. planner_crosscheck_testdata
#    aggregates every need across the initiative and reports the unowned ones
#    as ONE blocking TEST_DATA_UNOWNED finding that names every affected spec
#    and proposes the remedy: a test-data-pack enabler spec the affected specs
#    point at with `Source: seeded-by:<pack-slug>`.
#
# 2. Cited external artifacts (#504). Discovery records every external
#    artifact the source material cites (a sample file, a template, an export)
#    under discovery.md `## Cited Artifacts`, FOUND or NOT FOUND. Anything NOT
#    FOUND must reach the operator as a Consensus open question, and the
#    operator's answer becomes the test-data Source (`external:<who>` or
#    `generate`). planner_crosscheck_cited_artifacts checks that Consensus
#    raised each one (CITED_ARTIFACT_UNRAISED) and that each has been answered
#    (CITED_ARTIFACT_UNRESOLVED). Both are blocking, so an unanswered question
#    halts the run at Crosscheck — the existing CROSSCHECK_BLOCKED stop, with
#    its existing --accept / --answers paths. No new gate.
#    planner_cited_artifacts_questions renders the canonical question lines
#    the Consensus agent copies into consensus.md, so the question text is
#    assembled by bash, not paraphrased by the agent.
#
# The grammars parsed here are the contract documented in
# docs/test-data-source.md. ticket-auto-pipeline's readiness check consumes
# the same Source grammar from ticket bodies — keep the two in step.
#
# Usage:
#   planner_crosscheck_testdata <initiative_id>
#   planner_crosscheck_cited_artifacts <initiative_id>
#   planner_cited_artifacts_missing <initiative_id>
#   planner_cited_artifacts_questions <initiative_id>
#   planner_testdata_no_tests_rule
#     Check functions return 0 if clean, 1 if any finding was reported.
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

# The closed Source enum. `none` is only valid when the test data itself is
# none; the other four are the provenance kinds #503 defines.
PLANNER_TESTDATA_SOURCE_KINDS="exists seeded-by external generate none"

# Phrases that mean "implementation does not write tests". Deliberately
# narrow: a negation directly followed by write/add/create … tests, so a
# CLAUDE.md that merely mentions tests does not switch the rule on.
PLANNER_TESTDATA_NO_TESTS_RE="(do(es)?[[:space:]]+not|don'?t|never|must[[:space:]]+not|should[[:space:]]+not|shall[[:space:]]+not)[[:space:]]+(write|add|create|author)[[:space:]]+(any[[:space:]]+)?((unit|automated|integration|e2e)[[:space:]]+)?(tests|test[[:space:]]+(code|files|fixtures))"

_planner_testdata_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Does the project carry a standing "implementation does not write tests"
# rule (#503 point 4)? When it does, no ticket's implementation will produce
# fixtures as a side effect, so a spec seeding its own test data does not
# count as an owner and the test-data-pack remedy becomes mandatory.
#
# PLANNER_NO_TESTS_RULE=true|false overrides detection outright. Otherwise
# greps ${REPOS_ROOT}/CLAUDE.md and every ${REPOS_ROOT}/*/CLAUDE.md.
# Usage: planner_testdata_no_tests_rule
# Output (stdout): where the rule was found ("env" or the CLAUDE.md path).
# Returns: 0 if the rule is active, 1 otherwise.
planner_testdata_no_tests_rule() {
  case "${PLANNER_NO_TESTS_RULE:-}" in
  true | 1 | yes)
    echo "env"
    return 0
    ;;
  false | 0 | no) return 1 ;;
  esac

  local repos_root="${REPOS_ROOT:-}"
  [ -n "$repos_root" ] || return 1
  local f
  for f in "${repos_root}/CLAUDE.md" "${repos_root}"/*/CLAUDE.md; do
    [ -f "$f" ] || continue
    if grep -qiE "$PLANNER_TESTDATA_NO_TESTS_RE" "$f" 2>/dev/null; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

# Print the body of the `## <heading>` section of <file> (up to the next
# `## ` heading), outside fenced code blocks.
# Usage: _planner_testdata_section <file> <heading>
_planner_testdata_section() {
  local file="$1" heading="$2"
  awk -v h="## ${heading}" '
    /^```/ { fence = !fence; if (on) next }
    fence { next }
    /^## / { if (on) exit; if (tolower($0) ~ "^" tolower(h) "[[:space:]]*$") { on = 1; next } }
    on { print }
  ' "$file" 2>/dev/null
}

# Resolve a seeded-by ref to a sibling slug: exact match, or the unambiguous
# `-`-bounded prefix of exactly one slug — the same rule DANGLING_BLOCKED_BY
# uses (planner-crosscheck-deps.sh), so the two refs mean the same thing.
# Usage: _planner_testdata_resolve_slug <ref> <slug>...
# Output: the resolved slug, or nothing.
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

# Parse one `Test data: … Source: …` segment (the text after a `Test data:`
# marker) into "<data>\x1f<kind>\x1f<value>". kind is empty when the segment
# carries no Source.
# Usage: _planner_testdata_parse_segment <segment>
_planner_testdata_parse_segment() {
  local seg="$1" data src kind value
  if [[ "$seg" == *"Source:"* ]]; then
    data="${seg%%Source:*}"
    src="${seg#*Source:}"
    src=$(_planner_testdata_trim "$src")
    src="${src%.}"
    src="${src//\`/}"
    src=$(_planner_testdata_trim "$src")
    if [[ "$src" == *:* ]]; then
      kind="${src%%:*}"
      value="${src#*:}"
    else
      kind="${src%%[[:space:]]*}"
      value=""
    fi
    kind=$(_planner_testdata_trim "$kind")
    value=$(_planner_testdata_trim "$value")
  else
    data="$seg"
    kind=""
    value=""
  fi
  data=$(_planner_testdata_trim "$data")
  data="${data%.}"
  printf '%s\037%s\037%s\n' "$data" "$kind" "$value"
}

# Is <data> the explicit "no test data" value?
_planner_testdata_is_none() {
  local d
  d=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$d" in
  none | none\ * | none\(* | n/a | n/a\ * | -) return 0 ;;
  esac
  return 1
}

# For an initiative's spec files, aggregate every Verification Notes test-data
# need and report the ones no spec owns (#503).
#
# A need is owned when its Source is:
#   exists:<where>        — non-empty <where>
#   external:<who>        — non-empty <who>
#   seeded-by:<slug>      — resolves to a sibling spec that has a non-empty
#                           `## Test Data Provided` section (or is an existing
#                           Linear identifier — a cross-initiative pack). A spec
#                           naming itself is self-seeded, and does not count
#                           when the project's no-tests rule is active.
# and unowned when the Source is missing, `generate`, `none` for real data,
# or a kind outside the closed enum.
#
# Usage: planner_crosscheck_testdata <initiative_id>
# Returns: 0 if clean, 1 if a finding was reported.
planner_crosscheck_testdata() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-}"
  [ -n "$repos_root" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  local specs_dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts/specs"
  [ -d "$specs_dir" ] || return 0

  local -a known_slugs
  mapfile -t known_slugs < <(_planner_crosscheck_known_slugs "$specs_dir")
  [ "${#known_slugs[@]}" -ge 1 ] || return 0

  local no_tests_src="" no_tests=false
  if no_tests_src=$(planner_testdata_no_tests_rule); then
    no_tests=true
  fi

  local -a items=()
  local -A affected=()
  local spec_file base line num rest seg parsed data kind value reason target provided

  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    base="$(basename "$spec_file" .md)"
    [ "$base" = "INDEX" ] && continue

    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*([0-9]+)[.\)][[:space:]] ]] || continue
      num="${BASH_REMATCH[1]}"
      # Normalize marker case so `Test Data:`/`source:` parse the same.
      line=$(printf '%s' "$line" | sed -E 's/[Tt]est [Dd]ata:/Test data:/g; s/[Ss]ource:/Source:/g')
      [[ "$line" == *"Test data:"* ]] || continue

      rest="$line"
      while [[ "$rest" == *"Test data:"* ]]; do
        rest="${rest#*Test data:}"
        seg="${rest%%Test data:*}"
        parsed=$(_planner_testdata_parse_segment "$seg")
        IFS=$'\037' read -r data kind value <<<"$parsed"
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
            generate) reason="generate" ;;
            exists | external) [ -n "$value" ] || reason="${kind} with no value" ;;
            seeded-by)
              value="${value%%[[:space:]]*}"
              value="${value%.}"
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
                  provided=$(_planner_testdata_section "${specs_dir}/${target}.md" "Test Data Provided" | grep -cE '[^[:space:]]')
                  [ "${provided:-0}" -gt 0 ] ||
                    reason="seeded-by:${value} resolves to ${target}.md, which has no ## Test Data Provided section"
                fi
              fi
              ;;
            esac
          fi
        fi

        if [ -n "$reason" ]; then
          items+=("${base}.md#${num} (${reason})")
          affected["$base"]=1
        fi
      done
    done < <(_planner_testdata_section "$spec_file" "Verification Notes")
  done

  [ "${#items[@]}" -eq 0 ] && return 0

  local joined_items joined_specs
  joined_items=$(printf '%s; ' "${items[@]}")
  joined_items="${joined_items%; }"
  joined_specs=$(printf '%s\n' "${!affected[@]}" | LC_ALL=C sort | tr '\n' ',' | sed 's/,$//; s/,/, /g')

  local remedy="remedy: add an enabler spec (e.g. specs/test-data-pack.md, Kind enabler) whose ## Test Data Provided section lists the generator + seed scripts it delivers, then set each need's Source to seeded-by:<that-slug> as its verification prerequisite"
  if [ "$no_tests" = true ]; then
    remedy="MANDATORY ${remedy} — the project forbids implementation writing tests (${no_tests_src}), so no ticket will produce this data as a side effect"
  fi

  echo "planner-crosscheck-testdata: TEST_DATA_UNOWNED ${#items[@]} test-data need(s) across ${#affected[@]} spec(s) [${joined_specs}] have no owning spec: ${joined_items} — ${remedy}"
  return 1
}

# Cited artifacts discovery.md lists as NOT FOUND (#504), one name per line.
# Grammar (docs/test-data-source.md):
#   ## Cited Artifacts
#   - `<name>` — FOUND: <location>
#   - `<name>` — NOT FOUND (searched: <locations>)
# Usage: planner_cited_artifacts_missing <initiative_id>
planner_cited_artifacts_missing() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-}"
  [ -n "$repos_root" ] || return 0
  local discovery="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts/discovery.md"
  [ -f "$discovery" ] || return 0

  local line name
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*[-*][[:space:]] ]] || continue
    [[ "$line" == *"NOT FOUND"* ]] || continue
    [[ "$line" =~ \`([^\`]+)\` ]] || continue
    name=$(_planner_testdata_trim "${BASH_REMATCH[1]}")
    [ -n "$name" ] && echo "$name"
  done < <(_planner_testdata_section "$discovery" "Cited Artifacts")
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

# Check that every NOT FOUND cited artifact was raised in consensus.md and
# has an answer (#504).
# An answer is resolved when it is external:<who>, generate, or exists:<where>
# (the operator supplied it). PENDING, empty, or anything else is unresolved.
# Usage: planner_crosscheck_cited_artifacts <initiative_id>
# Returns: 0 if clean, 1 if any finding was reported.
planner_crosscheck_cited_artifacts() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-}"
  [ -n "$repos_root" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  local artifacts="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts"
  local consensus="${artifacts}/consensus.md"

  local -a missing
  mapfile -t missing < <(planner_cited_artifacts_missing "$initiative_id")
  [ "${#missing[@]}" -ge 1 ] || return 0

  # name(lowercased) -> answer, from every CITED_ARTIFACT line in consensus.md.
  local -A answers=()
  local line qname answer
  if [ -f "$consensus" ]; then
    while IFS= read -r line; do
      [[ "$line" == *"CITED_ARTIFACT:"* ]] || continue
      line="${line#*CITED_ARTIFACT:}"
      [[ "$line" =~ \`([^\`]+)\` ]] || continue
      qname=$(_planner_testdata_trim "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
      answer=""
      [[ "$line" == *"Answer:"* ]] && answer="${line##*Answer:}"
      answer=$(_planner_testdata_trim "${answer//\`/}")
      answer="${answer%.}"
      answers["$qname"]="$answer"
    done <"$consensus"
  fi

  local -a out_lines=()
  local name key kind value
  for name in "${missing[@]}"; do
    key=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    if [ -z "${answers[$key]+set}" ]; then
      out_lines+=("planner-crosscheck-testdata: CITED_ARTIFACT_UNRAISED consensus.md has no open question for cited artifact \`${name}\`, which discovery.md lists as NOT FOUND")
      continue
    fi
    answer="${answers[$key]}"
    kind="${answer%%:*}"
    value=""
    [[ "$answer" == *:* ]] && value=$(_planner_testdata_trim "${answer#*:}")
    case "$kind" in
    generate) [ "$answer" = "generate" ] && continue ;;
    external | exists) [ -n "$value" ] && continue ;;
    esac
    out_lines+=("planner-crosscheck-testdata: CITED_ARTIFACT_UNRESOLVED consensus.md open question for cited artifact \`${name}\` is unanswered (Answer: ${answer:-<empty>}) — provide it (Answer: exists:<where>), name who supplies it (Answer: external:<who>), or confirm it should be synthesised (Answer: generate)")
  done

  [ "${#out_lines[@]}" -eq 0 ] && return 0
  printf '%s\n' "${out_lines[@]}"
  return 1
}
