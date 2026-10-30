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
#      CITED_ARTIFACT_UNREFERENCED       no spec need cites it by backticked
#                                        name, contract initiatives (blocking)
#      CITED_ARTIFACTS_SECTION_MISSING   discovery.md has no section, contract
#                                        initiatives only (warn)
#    The stop is the existing CROSSCHECK_BLOCKED one — no new gate.
#
# 3. Test-data tripwires (planner-test-data-derivation) — see the section
#    "Check 3" below: TEST_DATA_INVENTORY_MISSING (warn),
#    VERIFICATION_NOTES_MISSING (blocking), TEST_DATA_IMPLIED (blocking) /
#    TEST_DATA_IMPLIED_WEAK (warn), and the TESTDATA_CONFIRM answer line.
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
PLANNER_TESTDATA_NO_TESTS_RE="(do(es)?[[:space:]]+not|don'?t|never|must[[:space:]]+not|should[[:space:]]+not|shall[[:space:]]+not)[[:space:]]+(write|add|create|author)([[:space:]]+or[[:space:]]+(write|add|create|modify))?[[:space:]]+(any[[:space:]]+)?((unit|automated|integration|e2e)[[:space:]]+)?(tests|test[[:space:]]+(code|files|fixtures))[[:space:]]*([.;:,!]|$|when[[:space:]]+(implementing|implementation))"

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
# (case-insensitive prefix, `*`/`_` ignored, so `## Verification Notes (per
# AC)` counts), up to the next heading of any level, fenced lines (``` or ~~~)
# skipped, CR stripped. The ONE reader of `## Verification Notes`: Crosscheck
# and the TicketGen composer (planner-ticket-body.sh) both read it here.
# Usage: _planner_testdata_section <file> <heading>
_planner_testdata_section() {
  local file="$1" heading="$2"
  [ -f "$file" ] || return 0
  tr -d '\r' <"$file" | awk -v h="$(_planner_testdata_lower "$heading")" '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
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
# the two markers. A marker must not follow a letter (`Resource:` and
# `Latest data:` are prose, not markers). Usage: _planner_testdata_norm_line <line>
_planner_testdata_norm_line() {
  printf '%s' "$1" | tr -d '\r*' |
    sed -E 's/(^|[[:space:]])_+([A-Za-z])/\1\2/g; s/([A-Za-z.:])_+([[:space:]]|$)/\1\2/g' |
    sed -E 's/(^|[^A-Za-z])[Tt][Ee][Ss][Tt][ -]?[Dd][Aa][Tt][Aa][[:space:]]*:/\1Test data:/g; s/(^|[^A-Za-z])[Ss][Oo][Uu][Rr][Cc][Ee][[:space:]]*:/\1Source:/g'
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

# ── Verification Notes: one reading shared with the TicketGen composer ─────
#
# planner-ticket-body.sh composes the ticket's Verification Plan and Test Data
# Prerequisites from the same `## Verification Notes` section this file checks
# for ownership. Both sides MUST read it identically, or a need Crosscheck
# never saw (or saw differently) reaches the ticket with a Source nobody
# checked. So both go through the functions below — the section extractor,
# the table parser and the per-cell need parser — and both refuse the spec
# shapes on which two Markdown readers could still disagree
# (_planner_testdata_notes_problems).

# Unicode whitespace look-alikes folded before a heading is compared:
# NBSP, U+2000-U+200A, U+202F, U+3000 become a space; ZWSP/ZWNJ/ZWJ, U+2060
# and the BOM are removed. Used only to DETECT a heading variant — the exact
# spelling is still required.
_planner_testdata_fold_ws() {
  LC_ALL=C sed -E 's/\xc2\xa0|\xe2\x80[\x80-\x8a]|\xe2\x80\xaf|\xe3\x80\x80/ /g; s/\xe2\x80[\x8b-\x8d]|\xe2\x81\xa0|\xef\xbb\xbf//g'
}

# Lines (after CR strip and whitespace folding, `*`/`_` removed, lowercased)
# that look like a heading for <name>: any number of `#`, optional space,
# then <name>. Output: "<fenced 0|1>\x1f<raw, unfolded line>" per match, fences being
# ``` or ~~~ with optional indentation.
# Usage: _planner_testdata_heading_lookalikes <file> <name-lowercase>
_planner_testdata_heading_lookalikes() {
  tr -d '\r' <"$1" | LC_ALL=C awk -v want="$2" '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    {
      l = $0
      gsub(/\302\240|\342\200[\200-\212]|\342\200\257|\343\200\200/, " ", l)
      gsub(/\342\200[\213-\215]|\342\201\240|\357\273\277/, "", l)
      l = tolower(l); gsub(/[*_]/, "", l); gsub(/[[:space:]]+/, " ", l)
      if (l ~ /^ ?#+ ?/) {
        sub(/^ ?#+ ?/, "", l)
        if (index(l, want) == 1) printf "%d\037%s\n", fence, $0
      }
    }'
}

# The Verification Notes table as parsed rows: the first output line is the
# header (cells lowercased, `*`/`_`/backticks stripped, trimmed), each further
# line one data row (cells trimmed, `\|` restored to a literal `|`), all
# \x1f-separated. Only the first contiguous `|` block counts (the structure
# check refuses a second one). Separator rows are skipped.
# Usage: _planner_testdata_notes_table <<<"<section>"
_planner_testdata_notes_table() {
  awk '
    /^[[:space:]]*\|/ {
      if (done) next
      intable = 1
      line = $0
      gsub(/\\\|/, "\036", line)
      sub(/^[[:space:]]*\|/, "", line); sub(/\|[[:space:]]*$/, "", line)
      n = split(line, c, "|")
      sep = 1
      for (i = 1; i <= n; i++) { t = c[i]; gsub(/[-: ]/, "", t); if (t != "") { sep = 0; break } }
      if (sep) next
      out = ""
      for (i = 1; i <= n; i++) {
        t = c[i]; gsub(/\036/, "|", t); gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
        if (!hdr) { t = tolower(t); gsub(/[*_`]/, "", t); gsub(/^[[:space:]]+|[[:space:]]+$/, "", t) }
        out = out (i > 1 ? "\037" : "") t
      }
      hdr = 1
      print out
      next
    }
    { if (intable) done = 1 }
  '
}

# Column index (1-based) of the first header cell starting with <prefix>, or
# empty. Usage: _planner_testdata_col <header-line> <prefix>
_planner_testdata_col() {
  printf '%s\n' "$1" | awk -F'\037' -v p="$2" '{ for (i = 1; i <= NF; i++) if (index($i, p) == 1) { print i; exit } }'
}

# One table row's need, parsed exactly like a numbered line's single
# `Test data: … Source: …` pair: "<data>\x1f<kind>\x1f<value>". A non-empty
# Source cell is appended last, so it wins over an inline `Source:` in the
# Test data cell. A `-`/`—`/`–`/`n/a` Source cell is an empty cell. The Test
# data cell is ONE need — a `Test data:` marker inside it does not split it.
# Usage: _planner_testdata_cell_need <test-data-cell> <source-cell>
_planner_testdata_cell_need() {
  local data="$1" src="$2" line
  # The cell is the Source: drop backticks/emphasis and a leading marker, so
  # `Source: x` in the cell reads as x, not as a second pair.
  src=$(printf '%s' "${src//\`/}" | tr -d '*' | sed -E 's/^[[:space:]_]*[Ss][Oo][Uu][Rr][Cc][Ee][[:space:]_]*:[[:space:]]*//')
  case "$(_planner_testdata_lower "$(_planner_testdata_trim "$src")")" in
  - | — | – | n/a) src="" ;;
  esac
  line="${data}"
  [ -n "$(_planner_testdata_trim "$src")" ] && line="${line} Source: ${src}"
  line=$(_planner_testdata_norm_line "$line")
  _planner_testdata_parse_segment "$line"
}

# Verification Notes table rows as needs: "<k>\x1f<data>\x1f<kind>\x1f<value>",
# k the 1-based data-row number. Needs a Test data column; Source is optional.
# Usage: _planner_testdata_table_needs <<<"<section>"
_planner_testdata_table_needs() {
  local rows header di si k=0 row
  rows=$(_planner_testdata_notes_table)
  [ -n "$rows" ] || return 0
  header=$(head -1 <<<"$rows")
  di=$(_planner_testdata_col "$header" "test data")
  si=$(_planner_testdata_col "$header" "source")
  [ -n "$di" ] || return 0
  while IFS= read -r row; do
    k=$((k + 1))
    local -a cells=()
    IFS=$'\037' read -r -a cells <<<"$row"
    printf '%s\037%s\n' "$k" "$(_planner_testdata_cell_need "${cells[di - 1]:-}" "${si:+${cells[si - 1]:-}}")"
  done < <(tail -n +2 <<<"$rows")
}

# Structural problems with a spec's Verification Notes on which two Markdown
# readers could disagree, or on which the ticket would carry a need nobody
# checked. Every one is refused by both Crosscheck (blocking) and the TicketGen
# composer. One reason per line; nothing when the spec is fine (including a
# spec with no Verification Notes at all).
#   - more than one heading that reads as Verification Notes at any level,
#     fenced or not, after folding Unicode whitespace look-alikes;
#   - such a heading that the reader would not see (fenced, `#`/`####`, no
#     space after the hashes, NBSP/zero-width inside);
#   - a sub-heading or a code fence inside the section (up to the next
#     heading of the same or a higher level);
#   - more than one table, or a table split by a blank/other line;
#   - a table without both a Criterion and a Test data column, or a row whose
#     cell count differs from the header's;
#   - a table plus numbered/bullet Test data lines;
#   - with a table: a `## Test Data Prerequisites` item no table row records
#     (the composer replaces that section from the table, so the item would
#     otherwise vanish unchecked).
# Usage: _planner_testdata_notes_problems <spec_file>
_planner_testdata_notes_problems() {
  local f="$1" looks n raw fenced lexical rows header ncols bad item key
  [ -f "$f" ] || return 0
  looks=$(_planner_testdata_heading_lookalikes "$f" "verification notes")
  [ -n "$looks" ] || return 0
  n=$(grep -c . <<<"$looks")
  [ "$n" -gt 1 ] && echo "${n} Verification Notes headings — keep exactly one"
  while IFS=$'\037' read -r fenced raw; do
    if [ "$fenced" = 1 ]; then
      echo "Verification Notes heading inside a code fence"
    elif ! LC_ALL=C grep -qE '^###? +[A-Za-z*_]' <<<"$raw" ||
      [[ "$(_planner_testdata_lower "$raw" | sed -E 's/^#+[[:space:]]+//; s/[*_]//g')" != "verification notes"* ]]; then
      echo "Verification Notes heading must be a '## Verification Notes' or '### Verification Notes' heading in plain ASCII (found '$(_planner_testdata_safe "$raw")')"
    fi
  done <<<"$looks"
  [ "$n" -gt 1 ] && return 0

  # The lexical section: from the heading to the next heading of the same or
  # a higher level, fences included — what an author sees as "the notes".
  lexical=$(tr -d '\r' <"$f" | awk '
    !on && !fence && /^###?[[:space:]]/ {
      l = tolower($0); sub(/^#+[[:space:]]+/, "", l); gsub(/[*_]/, "", l)
      if (index(l, "verification notes") == 1) { on = 1; match($0, /^#+/); lvl = RLENGTH; next }
    }
    /^[[:space:]]*(```|~~~)/ { fence = !fence; if (on) print; next }
    on && !fence && /^#+[[:space:]]/ { match($0, /^#+/); if (RLENGTH <= lvl) exit }
    on { print }')
  grep -qE '^[[:space:]]*(```|~~~)' <<<"$lexical" && echo "code fence inside Verification Notes"
  grep -qE '^[[:space:]]*#' <<<"$lexical" && echo "sub-heading inside Verification Notes"
  grep -qE '^[[:space:]]*\|' <<<"$lexical" || return 0

  awk '/^[[:space:]]*\|/ { if (gap) { bad = 1; exit } in_t = 1; next } in_t { gap = 1 } END { exit !bad }' <<<"$lexical" &&
    echo "Verification Notes table is split or repeated — one contiguous table only"
  rows=$(_planner_testdata_notes_table <<<"$lexical")
  header=$(head -1 <<<"$rows")
  { [ -n "$(_planner_testdata_col "$header" "criterion")" ] && [ -n "$(_planner_testdata_col "$header" "test data")" ]; } ||
    echo "Verification Notes table needs a Criterion and a Test data column"
  ncols=$(awk -F'\037' '{ print NF; exit }' <<<"$header")
  bad=$(tail -n +2 <<<"$rows" | awk -F'\037' -v n="$ncols" 'NF != n { b++ } END { print b + 0 }')
  [ "$bad" -gt 0 ] && echo "${bad} Verification Notes table row(s) do not have the header's ${ncols} cells — a missing or extra cell shifts the Source column"
  _planner_testdata_norm_line "$lexical" | grep -E '^[[:space:]]*([0-9]+[.)]|[-*+])[[:space:]]' | grep -q 'Test data:' &&
    echo "Verification Notes mixes a table with numbered/bullet Test data lines — use the table only"

  # Hand-written Test Data Prerequisites items must all be table needs.
  local keys
  keys=$(_planner_testdata_table_needs <<<"$lexical" | cut -d$'\037' -f2 | while IFS= read -r item; do
    _planner_testdata_need_key "$item"
    echo
  done)
  while IFS= read -r item; do
    item=$(sed -E 's/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+//' <<<"$item")
    [ -n "$(_planner_testdata_trim "$item")" ] || continue
    item=$(_planner_testdata_norm_line "$item")
    item=$(_planner_testdata_parse_segment "$item" | cut -d$'\037' -f1)
    _planner_testdata_is_none "$item" && continue
    key=$(_planner_testdata_need_key "$item")
    grep -qxF -- "$key" <<<"$keys" ||
      echo "Test Data Prerequisites names '$(_planner_testdata_safe "$item")', which no Verification Notes row records — add it to the table (with its Source) or remove it"
  done < <(_planner_testdata_exact_section "$f" "## Test Data Prerequisites")
  return 0
}

# Comparison key for a need's data text: lowercased, backticks removed,
# whitespace collapsed, trailing .,;: stripped.
_planner_testdata_need_key() {
  local k
  k=$(printf '%s' "$1" | tr -d '`' | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+/ /g')
  k=$(_planner_testdata_trim "$k")
  while [[ "$k" =~ [.,\;:]$ ]]; do k="${k%?}"; done
  printf '%s' "$(_planner_testdata_trim "$k")"
}

# Body of the exact, unfenced heading line <heading> up to the next heading,
# fenced lines skipped. Usage: _planner_testdata_exact_section <file> <heading>
_planner_testdata_exact_section() {
  tr -d '\r' <"$1" | awk -v h="$2" '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^#+[[:space:]]/ { if (on) exit; t = $0; sub(/[[:space:]]+$/, "", t); if (t == h) on = 1; next }
    on { print }'
}

# Every test-data need in one spec, one record per line:
#   <label>\x1f<data>\x1f<kind>\x1f<value>
# label is the item's number (numbered lists), b<k> (k-th bullet), or the
# 1-based data-row number of a Verification Notes table (#499).
_planner_testdata_spec_needs() {
  local spec_file="$1" line label bullets=0 rest seg parsed section
  section=$(_planner_testdata_section "$spec_file" "Verification Notes")
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
  done <<<"$section"
  _planner_testdata_table_needs <<<"$section"
}

# Does the spec carry at least one Source field (marks it as written to this
# contract, even in a legacy initiative)? A `Source:` marker on a non-table
# line of the notes, or a need parsed from the table with a Source.
_planner_testdata_spec_has_source() {
  local body
  body=$(_planner_testdata_section "$1" "Verification Notes")
  local prose
  prose=$(grep -vE '^[[:space:]]*\|' <<<"$body")
  [[ "$(_planner_testdata_norm_line "$prose")" == *"Source:"* ]] && return 0
  _planner_testdata_table_needs <<<"$body" | awk -F'\037' '$3 != "" { found = 1 } END { exit !found }'
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
    # "None — no external artifacts cited.", "No artifacts are cited": a
    # statement that there is nothing to list, not an entry.
    if [[ "$up" != *'`'* ]] && [[ "$up" =~ ^(none[^a-z]|no[[:space:]]).*(artifact|external|files) ]] &&
      ! [[ "$up" =~ (—|–|[[:space:]]-[[:space:]]).*found ]]; then
      continue
    fi
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

# Parse one consensus.md line as a CITED_ARTIFACT open question. Prints
#   <name>\x1f<kind>\x1f<value>\x1f<raw answer>
# and returns 0, or returns 1 when the line is not such a question. kind ∈
# exists | external | generate when the answer is well formed, else
# "unresolved". The ONE reader of the line shape: the Crosscheck answers map,
# the per-artifact headless questions and the answer writer (#515) all go
# through it, so they cannot disagree about which line is question <n>.
_planner_cited_answer_parse() {
  local line name answer kind value
  line=$(printf '%s' "$1" | tr -d '\r*')
  [[ "$line" == *"CITED_ARTIFACT:"* ]] || return 1
  line="${line#*CITED_ARTIFACT:}"
  [[ "$line" =~ \`([^\`]+)\` ]] || return 1
  name="${BASH_REMATCH[1]}"
  answer=""
  [[ "$line" == *"Answer:"* ]] && answer="${line##*Answer:}"
  answer=$(_planner_testdata_trim "${answer//\`/}")
  answer="${answer#_}"
  answer="${answer%_}"
  # `_Answer:_ x` leaves "_ x": trim again after the emphasis goes.
  answer=$(_planner_testdata_trim "$answer")
  while [[ "$answer" =~ [.,\;:!]$ ]]; do answer="${answer%?}"; done
  kind=$(_planner_testdata_lower "${answer%%:*}")
  value=""
  [[ "$answer" == *:* ]] && value=$(_planner_testdata_trim "${answer#*:}")
  case "$kind" in
  generate) [ "$answer" = "${answer%%:*}" ] || kind="unresolved" ;;
  external | exists) [ -n "$value" ] || kind="unresolved" ;;
  *) kind="unresolved" ;;
  esac
  printf '%s\037%s\037%s\037%s\n' "$name" "$kind" "$value" "$(_planner_testdata_safe "$answer")"
}

# Every CITED_ARTIFACT open question in consensus.md, in file order:
#   <n>\x1f<name key>\x1f<name>\x1f<kind>\x1f<value>\x1f<raw answer>
# n is the 1-based position the `consensus-answer:cited:<n>` binding names.
# Usage: planner_cited_answer_lines <consensus.md>
planner_cited_answer_lines() {
  local consensus="$1" line parsed n=0 name kind value raw
  [ -f "$consensus" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    parsed=$(_planner_cited_answer_parse "$line") || continue
    n=$((n + 1))
    IFS=$'\037' read -r name kind value raw <<<"$parsed"
    printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$n" "$(_planner_testdata_name_key "$name")" \
      "$(_planner_testdata_safe "$name")" "$kind" "$value" "$raw"
  done <"$consensus"
}

# Answers recorded in consensus.md, one per line:
#   <lowercased name>\x1f<kind>\x1f<value>\x1f<raw answer>
# Last line for a name wins.
_planner_cited_answers() {
  local n key name kind value raw
  while IFS=$'\037' read -r n key name kind value raw; do
    printf '%s\037%s\037%s\037%s\n' "$key" "$kind" "$value" "$raw"
  done < <(planner_cited_answer_lines "$1")
}

# Validate and normalise a headless answer to a cited-artifact question
# (#515). The closed set is exists:<where> | external:<who> | generate — the
# same kinds _planner_cited_answer_parse accepts — and the value must survive
# that parser unchanged, so anything it would strip or misread is refused
# rather than silently altered: `|` (the state log and Source grammar
# separator), CR/LF/tab and every other control character, backticks and `*`
# (stripped by the parser), a second "Answer:" (the parser reads the last
# one), and trailing punctuation or `_`. Prints the normalised value (kind
# lowercased, whitespace trimmed); on rejection prints the reason on stderr
# and returns 1.
# Usage: planner_cited_answer_normalize <value>
PLANNER_CITED_ANSWER_VALUE_MAX=256
planner_cited_answer_normalize() {
  local v="$1" lower kind val
  local LC_ALL=C
  if [[ "$v" == *"|"* ]]; then
    echo "a cited-artifact answer must not contain '|'" >&2
    return 1
  fi
  if [[ "$v" =~ [[:cntrl:]] ]]; then
    echo "a cited-artifact answer is one line: no CR, LF, tab or other control character" >&2
    return 1
  fi
  if [[ "$v" == *'`'* ]] || [[ "$v" == *'*'* ]]; then
    echo "a cited-artifact answer must not contain backticks or '*'" >&2
    return 1
  fi
  v=$(_planner_testdata_trim "$v")
  lower=$(_planner_testdata_lower "$v")
  case "$lower" in
  generate)
    printf 'generate'
    return 0
    ;;
  exists:* | external:*)
    kind="${lower%%:*}"
    val=$(_planner_testdata_trim "${v#*:}")
    ;;
  *)
    echo "a cited-artifact answer must be exists:<where>, external:<who> or generate" >&2
    return 1
    ;;
  esac
  if [ -z "$val" ]; then
    echo "${kind}: needs a value (${kind}:<$([ "$kind" = exists ] && echo where || echo who)>)" >&2
    return 1
  fi
  if [[ "$(_planner_testdata_lower "$val")" == *"answer:"* ]]; then
    echo "a cited-artifact answer must not contain 'Answer:'" >&2
    return 1
  fi
  if [[ "$val" =~ [.,\;:!_]$ ]]; then
    echo "a cited-artifact answer must not end with punctuation or '_'" >&2
    return 1
  fi
  if [ "${#val}" -gt "$PLANNER_CITED_ANSWER_VALUE_MAX" ]; then
    echo "a cited-artifact answer value is at most ${PLANNER_CITED_ANSWER_VALUE_MAX} bytes" >&2
    return 1
  fi
  printf '%s:%s' "$kind" "$val"
}

# Rewrite the Answer: field of consensus.md's <n>th CITED_ARTIFACT question
# (#515). The rest of the line, every other line and CRLF endings are kept;
# a line with no Answer: field gets one appended. The rewritten line is
# re-parsed before anything is written and must yield exactly the normalised
# answer, so a value the reader would see differently never lands. Written
# tmp + mv. Idempotent: the same value again rewrites the line to itself.
# Exit: 0 written, 1 file missing or write failed, 2 invalid value or index,
# 3 no question <n>, 4 round-trip mismatch.
# Usage: planner_cited_answer_set <consensus.md> <n> <value>
planner_cited_answer_set() {
  local consensus="$1" want="$2" value
  if ! [[ "$want" =~ ^[1-9][0-9]*$ ]]; then
    echo "planner_cited_answer_set: index '${want}' is not a positive integer" >&2
    return 2
  fi
  value=$(planner_cited_answer_normalize "$3") || return 2
  [ -f "$consensus" ] || {
    echo "planner_cited_answer_set: ${consensus} not found" >&2
    return 1
  }

  local -a lines=()
  mapfile -t lines <"$consensus"
  local i n=0 hit=-1
  for i in "${!lines[@]}"; do
    _planner_cited_answer_parse "${lines[$i]}" >/dev/null || continue
    n=$((n + 1))
    if [ "$n" -eq "$want" ]; then
      hit=$i
      break
    fi
  done
  if [ "$hit" -lt 0 ]; then
    echo "planner_cited_answer_set: consensus.md has no cited-artifact question ${want} (it has ${n})" >&2
    return 3
  fi

  local raw cr="" prefix tail emph new
  raw="${lines[$hit]}"
  if [[ "$raw" == *$'\r' ]]; then
    cr=$'\r'
    raw="${raw%$'\r'}"
  fi
  if [[ "$raw" == *"Answer:"* ]]; then
    prefix="${raw%Answer:*}"
    tail="${raw##*Answer:}"
    # Keep a closing emphasis run (`**Answer:** PENDING`).
    emph="${tail%%[!*_]*}"
    new="${prefix}Answer:${emph} ${value}"
  else
    new="${raw%"${raw##*[![:space:]]}"} Answer: ${value}"
  fi

  local got gname gkind gvalue graw want_kind want_value=""
  want_kind="${value%%:*}"
  [[ "$value" == *:* ]] && want_value="${value#*:}"
  got=$(_planner_cited_answer_parse "$new") || got=""
  IFS=$'\037' read -r gname gkind gvalue graw <<<"$got"
  if [ "$gkind" != "$want_kind" ] || [ "$gvalue" != "$want_value" ]; then
    echo "planner_cited_answer_set: rewritten line would read back as '${gkind}:${gvalue}', not '${value}'" >&2
    return 4
  fi

  lines[hit]="${new}${cr}"
  # cp -p first so the tmp file, and therefore consensus.md after the mv,
  # keeps the original mode; the redirect then truncates it in place.
  local tmp="${consensus}.tmp.$$"
  cp -p "$consensus" "$tmp" && printf '%s\n' "${lines[@]}" >"$tmp" && mv -f "$tmp" "$consensus" || {
    rm -f "$tmp"
    echo "planner_cited_answer_set: could not write ${consensus}" >&2
    return 1
  }
  return 0
}

# Comparison key for a cited-artifact name: lowercased, en/em dashes as "-",
# whitespace runs collapsed, trimmed, trailing .,;:! stripped. Used on both
# sides of every name comparison (discovery.md, consensus.md, spec needs).
_planner_testdata_name_key() {
  local k
  k=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/—|–/-/g; s/[[:space:]]+/ /g')
  k=$(_planner_testdata_trim "$k")
  while [[ "$k" =~ [.,\;:!]$ ]]; do k="${k%?}"; done
  printf '%s' "$(_planner_testdata_trim "$k")"
}

# Does <data> cite the artifact <name>? Only an exact, case-insensitive
# backticked span counts. Prose is never matched: substring and even
# word-boundary matching turn "a seeded email template record" into a citation
# of an artifact called `template`, and a short name into a match inside a
# longer one (`sample` in `sample file v2`). CITED_ARTIFACT_UNREFERENCED makes
# the backticked reference mandatory, so nothing that matters is lost.
_planner_testdata_names_artifact() {
  local rest="$1" span name_l
  name_l=$(_planner_testdata_name_key "$2")
  [ -n "$name_l" ] || return 1
  while [[ "$rest" =~ \`([^\`]+)\` ]]; do
    span=$(_planner_testdata_name_key "${BASH_REMATCH[1]}")
    [ "$span" = "$name_l" ] && return 0
    rest="${rest#*\`"${BASH_REMATCH[1]}"\`}"
  done
  return 1
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
    case "${answer_kind[$(_planner_testdata_name_key "$name")]:-unresolved}" in
    unresolved) pending+=("$name") ;;
    esac
  done < <(planner_cited_artifacts_missing "$initiative_id")

  local -a items=() legacy_items=()
  local -A affected=() legacy_affected=()
  local spec_file base strict label data kind value reason target provided p skip
  # An applying exists:/external: TESTDATA_CONFIRM answer is the spec's
  # effective Source (in memory — planner_testdata_spec_effective_needs).
  local td_ents
  td_ents=$(_planner_testdata_entity_names "$initiative_id")

  # Needs Crosscheck's test-data synthesis took (sidecar overrides,
  # planner-test-data-derivation): a `generate` row with an override is
  # owned by its TD spec (Source seeded-by:<td> in effect), so only needs
  # synthesis could not own reach TEST_DATA_UNOWNED. Keyed consumer +
  # criterion + data; the criterion comes from _planner_testdata_rows,
  # matched to spec_needs' records by label + data (same parsers).
  local -A synth_owned=()
  local o_c o_crit o_data o_src o_rec
  if declare -f planner_testdata_synth_overrides >/dev/null 2>&1; then
    while IFS=$'\037' read -r o_c o_crit o_data o_src o_rec; do
      [ -n "$o_c" ] && synth_owned["${o_c}"$'\037'"${o_crit}"$'\037'"${o_data}"]=1
    done < <(planner_testdata_synth_overrides "$initiative_id")
  fi
  local -A row_crit=()
  local r_label r_crit r_data r_kind r_value okey

  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    base="$(basename "$spec_file" .md)"
    [ "$base" = "INDEX" ] && continue
    strict=$strict_init
    [ "$strict" = true ] || ! _planner_testdata_spec_has_source "$spec_file" || strict=true
    row_crit=()
    if [ "${#synth_owned[@]}" -gt 0 ]; then
      while IFS=$'\037' read -r r_label r_crit r_data r_kind r_value; do
        [ "$r_kind" = "generate" ] || continue
        row_crit["${r_label}"$'\037'"${r_data//$'\037'/ }"]="${r_crit//$'\037'/ }"
      done < <(_planner_testdata_rows "$spec_file")
    fi

    # A Verification Notes shape the composer could read differently blocks
    # in every initiative: TicketGen refuses it too (_planner_tb_guard).
    while IFS= read -r reason; do
      [ -n "$reason" ] || continue
      items+=("${base}.md#notes (${reason})")
      affected["$base"]=1
    done < <(_planner_testdata_notes_problems "$spec_file")

    while IFS=$'\037' read -r label data kind value; do
      reason=""
      if [[ "$value" == *"|"* ]]; then
        reason="Source value contains '|'"
      elif [ -z "$kind" ]; then
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
            if [ "$skip" = false ] && [ "${#synth_owned[@]}" -gt 0 ]; then
              okey="${label}"$'\037'"${data}"
              [ -n "${row_crit[$okey]+set}" ] &&
                [ -n "${synth_owned["${base}"$'\037'"${row_crit[$okey]}"$'\037'"${data}"]:-}" ] && skip=true
            fi
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
    done < <(planner_testdata_spec_effective_needs "$initiative_id" "$spec_file" "$td_ents")
  done

  local specs
  if [ "${#legacy_items[@]}" -gt 0 ]; then
    specs=$(printf '%s\n' "${!legacy_affected[@]}" | LC_ALL=C sort | paste -sd, - | sed 's/,/, /g')
    _planner_testdata_emit "planner-crosscheck-testdata: TEST_DATA_UNSOURCED_LEGACY ${#legacy_items[@]} test-data need(s) across ${#legacy_affected[@]} legacy spec(s) [${specs}] predate the Source field: $(_planner_testdata_join_items "${legacy_items[@]}") — add Source: to these lines (docs/test-data-source.md); not blocking because the initiative predates the contract"
  fi

  [ "${#items[@]}" -eq 0 ] && return 0

  specs=$(printf '%s\n' "${!affected[@]}" | LC_ALL=C sort | paste -sd, - | sed 's/,/, /g')
  local remedy="remedy: give each need a valid Source — generate (Crosscheck's test-data synthesis then writes the TD spec that owns it; do not hand-write a test-data pack), exists:<where>, external:<who>, or seeded-by:<slug> naming a spec whose ## Test Data Provided lists it"
  if [ "$no_tests" = true ]; then
    remedy="MANDATORY ${remedy} — the project forbids implementation writing tests (${no_tests_src}), so no ticket will produce this data as a side effect"
  fi
  _planner_testdata_emit "planner-crosscheck-testdata: TEST_DATA_UNOWNED ${#items[@]} test-data need(s) across ${#affected[@]} spec(s) [${specs}] have no owning spec and synthesis could not take them: $(_planner_testdata_join_items "${items[@]}") — ${remedy}"
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
      key=$(_planner_testdata_name_key "$name")
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

  # Every spec need that cites a NOT FOUND artifact (backticked name) must
  # carry the Source the recorded answer implies; before an answer it stays
  # `generate`. And, on contract initiatives, every NOT FOUND artifact must be
  # cited by at least one need — a paraphrase would dodge the check above.
  if [ "${#missing[@]}" -gt 0 ] && [ -d "$specs_dir" ]; then
    local spec_file base label data kind value want ok nspecs=0
    local -A referenced=()
    for spec_file in "$specs_dir"/*.md; do
      [ -f "$spec_file" ] || continue
      base="$(basename "$spec_file" .md)"
      [ "$base" = "INDEX" ] && continue
      nspecs=$((nspecs + 1))
      while IFS=$'\037' read -r label data kind value; do
        for name in "${missing[@]}"; do
          _planner_testdata_names_artifact "$data" "$name" || continue
          key=$(_planner_testdata_name_key "$name")
          # Only a real need counts: a Source, and test data that is not none.
          [ -n "$kind" ] || continue
          _planner_testdata_is_none "$data" && continue
          referenced["$key"]=1
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

    if [ "$nspecs" -gt 0 ] && planner_testdata_contract_initiative "$initiative_id"; then
      for name in "${missing[@]}"; do
        key=$(_planner_testdata_name_key "$name")
        [ -n "${referenced[$key]:-}" ] && continue
        _planner_testdata_emit "planner-crosscheck-testdata: CITED_ARTIFACT_UNREFERENCED no spec Verification Notes need cites \`${name}\` (NOT FOUND in discovery.md) by its backticked name — quote it exactly in the Test data of every need that uses it, or --accept the code if no spec needs it"
        blocking=1
      done
    fi
  fi

  [ "$blocking" -eq 0 ]
}

# ── Check 3: test-data tripwires (planner-test-data-derivation) ─────────────
#
# Three gaps the Source contract above cannot see, because it only reads the
# needs a spec wrote down:
#
#   TEST_DATA_INVENTORY_MISSING   discovery.md has no `## Test Data Inventory`
#                                 (warn, contract initiatives only)
#   VERIFICATION_NOTES_MISSING    a spec with acceptance criteria has no
#                                 Verification Notes rows at all (blocking;
#                                 legacy initiatives: the warn-level
#                                 VERIFICATION_NOTES_MISSING_LEGACY)
#   TEST_DATA_IMPLIED             every row says `none`, yet a criterion
#                                 strongly implies data (blocking; answerable
#                                 with a TESTDATA_CONFIRM line in consensus.md)
#   TEST_DATA_IMPLIED_WEAK        the same on a weak-tier match only, or a
#                                 strong match in a legacy initiative (warn)
#
# Enabler specs are exempt from VERIFICATION_NOTES_MISSING; specs carrying
# PLANNER_TESTDATA_SYNTH_MARKER (written by Crosscheck's own test-data
# synthesis) are exempt from every tripwire.

# Marker the test-data synthesis step stamps on every spec it writes. A
# synthesized spec is self-verifying and never re-checked here.
PLANNER_TESTDATA_SYNTH_MARKER='<!-- planner:testdata-synth v1 -->'

# A count followed by one of these is a threshold, not data. The design's
# list (minutes, seconds, ms, s, attempts, requests, retries, times, bytes,
# MB, %) plus their singulars and the obvious sibling units of the same class
# (other time units, size units, characters, pixels).
PLANNER_TESTDATA_UNIT_DENYLIST="minute minutes min mins second seconds sec secs s ms millisecond milliseconds hour hours h hr hrs day days week weeks month months year years attempt attempts request requests retry retries try tries time times byte bytes b kb mb gb tb character characters char chars px pixel pixels percent"

# Record states that, without a named entity, only weakly imply data.
PLANNER_TESTDATA_STATE_WORDS="overdue archived expired pending paid unpaid draft deleted disabled locked suspended inactive cancelled canceled closed approved rejected published verified unverified"

# Words that end a noun phrase (never part of the matched phrase).
_PLANNER_TESTDATA_STOPWORDS=" a an the is are was were be been with without of or and to in on at for by from as that which who when where then than per more less after before within into is are has have shows show see sees appear appears can cannot must should will "

# Is spec <file> one the synthesis step wrote?
_planner_testdata_spec_is_synth() {
  [ -f "$1" ] && grep -qF -- "$PLANNER_TESTDATA_SYNTH_MARKER" "$1" 2>/dev/null
}

# The spec's Signals `Kind` (business|enabler), lowercased; empty when the
# Signals block is missing or unparseable.
_planner_testdata_spec_kind() {
  tr -d '\r' <"$1" 2>/dev/null | awk '
    /^## / { h = tolower($0); sub(/^## +/, "", h); sub(/[[:space:]]+$/, "", h); on = (h == "signals"); next }
    on && /^[[:space:]]*(```|~~~)/ { if (in_f) exit; in_f = 1; next }
    on && in_f { print }' | jq -r 'if type == "object" then (.Kind // "") else "" end' 2>/dev/null |
    tr '[:upper:]' '[:lower:]'
}

# Acceptance Criteria items, one per line, markers stripped — the same reader
# as planner-ticket-body.sh's _planner_tb_ac_items (that file sources this
# one, so it cannot be called from here).
_planner_testdata_ac_items() {
  tr -d '\r' <"$1" 2>/dev/null | awk '
    /^(```|~~~)/ { fence = !fence }
    !fence && /^## / { h = tolower($0); sub(/^## +/, "", h); sub(/[[:space:]]+$/, "", h); on = (h == "acceptance criteria"); next }
    on { print }' |
    { grep -E '^[[:space:]]*(-[[:space:]]*\[[ xX]\]|-|\*|[0-9]+[.)])[[:space:]]+[^[:space:]]' || true; } |
    sed -E 's/^[[:space:]]*(-[[:space:]]*\[[ xX]\]|-|\*|[0-9]+[.)])[[:space:]]*//; s/[[:space:]]+$//' |
    awk '!seen[$0]++'
}

# Entity name normalised: lowercase, backticks/`*` removed, whitespace
# collapsed, trimmed, characters outside [a-z0-9 _-] dropped.
_planner_testdata_entity_norm() {
  local k
  k=$(printf '%s' "$1" | tr -d '`*' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 _-]+/ /g; s/[[:space:]]+/ /g')
  _planner_testdata_trim "$k"
}

# Rows of discovery.md `## Test Data Inventory`, one per line:
#   <entity>\x1f<load via>
# entity normalised (_planner_testdata_entity_norm), load via lowercased.
# Nothing when the section or its table is missing.
# Usage: planner_testdata_inventory_entities <initiative_id>
planner_testdata_inventory_entities() {
  [ -n "${REPOS_ROOT:-}" ] || return 0
  local discovery rows header ei li row ent lv
  discovery="$(_planner_testdata_state_dir "$1")/artifacts/discovery.md"
  [ -f "$discovery" ] || return 0
  rows=$(_planner_testdata_section "$discovery" "Test Data Inventory" | _planner_testdata_notes_table)
  [ -n "$rows" ] || return 0
  header=$(head -1 <<<"$rows")
  ei=$(_planner_testdata_col "$header" "entity")
  li=$(_planner_testdata_col "$header" "load via")
  [ -n "$ei" ] || return 0
  while IFS= read -r row; do
    local -a cells=()
    IFS=$'\037' read -r -a cells <<<"$row"
    ent=$(_planner_testdata_entity_norm "${cells[ei - 1]:-}")
    [ -n "$ent" ] || continue
    lv=""
    [ -n "$li" ] && lv=$(_planner_testdata_lower "$(_planner_testdata_trim "${cells[li - 1]:-}")")
    printf '%s\037%s\n' "$ent" "$lv"
  done < <(tail -n +2 <<<"$rows")
}

# How many words starting at position <j> of the word array name entity <e>
# (singular, +s, +es, y→ies on the last word)? 0 when none.
# Usage: _planner_testdata_entity_len_at <e> <j> <words...>
_planner_testdata_entity_len_at() {
  local e="$1" j="$2"
  shift 2
  local -a w=("$@") ew=()
  read -r -a ew <<<"$e"
  local n=${#ew[@]} k last got
  [ "$n" -gt 0 ] || {
    echo 0
    return
  }
  [ $((j + n)) -le ${#w[@]} ] || {
    echo 0
    return
  }
  for ((k = 0; k < n - 1; k++)); do
    [ "${w[j + k]}" = "${ew[k]}" ] || {
      echo 0
      return
    }
  done
  last="${ew[n - 1]}"
  got="${w[j + n - 1]}"
  if [ "$got" = "$last" ] || [ "$got" = "${last}s" ] || [ "$got" = "${last}es" ] ||
    { [[ "$last" == *y ]] && [ "$got" = "${last%y}ies" ]; }; then
    echo "$n"
    return
  fi
  echo 0
}

_planner_testdata_in_list() {
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

# Up to <max> words from position <j> that form a noun phrase (stops at a
# stopword or a number). Usage: _planner_testdata_np <j> <max> <words...>
_planner_testdata_np() {
  local j="$1" max="$2" out="" k
  shift 2
  local -a w=("$@")
  for ((k = j; k < ${#w[@]} && k < j + max; k++)); do
    _planner_testdata_in_list "${w[k]}" "$_PLANNER_TESTDATA_STOPWORDS" && break
    [[ "${w[k]}" =~ ^[0-9] ]] && break
    out="${out}${out:+ }${w[k]}"
  done
  printf '%s' "$out"
}

# First tokens that make a multi-word backticked span a command line, not a
# name: package managers and runtimes, build tools, VCS/HTTP clients and
# container/infra CLIs. A span is a command when it starts with one of these
# and has a second word (`npm run build`, `git status`, `make seed`).
PLANNER_TESTDATA_COMMAND_WORDS="npm npx node yarn pnpm bun deno corepack git gh curl wget http make cmake just python python3 pip pip3 pipx poetry uv pytest ruby gem bundle rake rails go cargo rustc java javac mvn mvnw gradle gradlew dotnet php composer docker docker-compose podman kubectl helm terraform ansible bash sh zsh source cd ls cat grep sed awk jq echo export env sudo psql mysql sqlite3 redis-cli mongosh vite tsc eslint prettier jest vitest playwright"

# Is a backticked span (raw text) a command invocation rather than a name?
# True for a multi-word span whose first word is in
# PLANNER_TESTDATA_COMMAND_WORDS, and for any span carrying a flag word
# (`-x`, `--flag`), a shell operator or a `$VAR`. A `/` alone never makes a
# command: `GET /api/profiles/jake` and URL paths name resources.
_planner_testdata_span_is_command() {
  local span="$1" first rest
  [[ "$span" =~ (^|[[:space:]])--?[A-Za-z] ]] && return 0
  [[ "$span" == *'|'* || "$span" == *'&&'* || "$span" == *'$'* ]] && return 0
  read -r first rest <<<"$span"
  [ -n "$rest" ] || return 1
  first=$(_planner_testdata_lower "$first")
  _planner_testdata_in_list "$first" "$PLANNER_TESTDATA_COMMAND_WORDS"
}

# The arguments of a command span: the span minus its leading command word
# and every flag word. Paths and arguments stay in the scanned text so a
# resource they name (`curl /api/profiles/jake`) still reaches the rules.
_planner_testdata_span_args() {
  local -a t=()
  local out="" k
  read -r -a t <<<"$1"
  for ((k = 0; k < ${#t[@]}; k++)); do
    [ "$k" -eq 0 ] && _planner_testdata_in_list "$(_planner_testdata_lower "${t[k]}")" "$PLANNER_TESTDATA_COMMAND_WORDS" && continue
    [[ "${t[k]}" =~ ^--?[A-Za-z] ]] && continue
    out="${out}${out:+ }${t[k]}"
  done
  printf '%s' "$out"
}

# Is the criterion only about what a document or file says? True when it
# names a document (README, CHANGELOG, docs, documentation, runbook) or a
# docs/config file (*.md, *.json, *.yml, *.toml, *.env, ...), a content verb
# follows that name (states, mentions, documents, describes, says,
# explains, labelled, reads, names, warns, tells, defines, declares), and no
# app-behaviour clause is present (shows, returns, renders, displays,
# appears, loads, responds, redirects, log/sign in). Its quoted spans
# are then quoted content, not data.
_planner_testdata_crit_is_doc_text() {
  local lower after
  lower=$(_planner_testdata_lower "$1")
  [[ "$lower" =~ (^|[^a-z0-9_])(readme|changelog|docs|documentation|runbook|[a-z0-9_.-]*\.(md|json|ya?ml|toml|ini|cfg|conf|env|txt|xml|properties|lock))([^a-z0-9_]|$) ]] || return 1
  after="${lower#*"${BASH_REMATCH[0]}"}"
  [[ " $after" =~ [^a-z](states?|stated|mentions?|mentioned|documents?|documented|describes?|described|says|said|explains?|explained|labell?ed|labels?|reads|names|named|warns?|warned|tells?|instructs?|defines?|defined|declares?|declared)([^a-z]|$) ]] || return 1
  [[ " $lower" =~ [^a-z](shows?|showing|returns?|renders?|rendered|displays?|appears?|loads?|responds?|redirects?|logs?[[:space:]]+in|logging[[:space:]]+in|signs?[[:space:]]+in|signing[[:space:]]+in)([^a-z]|$) ]] && return 1
  return 0
}

# Does a double-quoted span read as UI copy (a label, button text, title)
# rather than a value? True when the span is a short Title Case phrase
# ("New Article", "Sign in") or a UI noun (button, link, tab, label,
# heading, menu, title, placeholder, banner, text, message) is within two
# words of it. Quoted emails and usernames ("alice@example.com", "alice")
# are not UI copy and stay in the scanned text.
# Usage: _planner_testdata_quote_is_ui <span> <text before> <text after>
_planner_testdata_quote_is_ui() {
  local span="$1" ctx ui="button buttons link links tab tabs label labels labelled labeled heading headings menu title titled placeholder banner text message"
  [[ "$span" == *@* ]] && return 1
  if [[ "$span" =~ ^[A-Z][A-Za-z0-9]*([[:space:]]+([A-Z][A-Za-z0-9]*|a|an|the|of|to|in|on|for|and|or)){0,4}[.!?]?$ ]]; then
    return 0
  fi
  ctx="$(_planner_testdata_lower "$2" | tr -c 'a-z\n' ' ' | tr '\n' ' ' | awk '{ for (i = NF - 1; i <= NF; i++) if (i > 0) printf "%s ", $i }') $(_planner_testdata_lower "$3" | tr -c 'a-z\n' ' ' | tr '\n' ' ' | awk '{ for (i = 1; i <= 2 && i <= NF; i++) printf "%s ", $i }')"
  local wd
  for wd in $ctx; do
    _planner_testdata_in_list "$wd" "$ui" && return 0
  done
  return 1
}

# Remove UI-copy double-quoted spans (_planner_testdata_quote_is_ui) from
# text; with <all>=true remove every double-quoted span.
# Usage: _planner_testdata_strip_quotes <text> <all>
_planner_testdata_strip_quotes() {
  local rest="$1" out="" q pre
  while [[ "$rest" =~ \"([^\"]*)\" ]]; do
    q="${BASH_REMATCH[1]}"
    pre="${rest%%\""${q}"\"*}"
    rest="${rest#*\""${q}"\"}"
    out="${out}${pre}"
    if [ "$2" = true ] || _planner_testdata_quote_is_ui "$q" "$pre" "$rest"; then
      out="${out} "
    else
      out="${out} ${q} "
    fi
  done
  printf '%s' "${out}${rest}"
}

# Words that, right before or after a backticked span, make it the name of a
# key, field, setting or script — an identifier in code, not a record
# (`jwt` value, the `following` field, the scripts `dev`).
PLANNER_TESTDATA_IDENT_NOUNS="value values key keys helper helpers module modules component components hook hooks field fields header headers property properties prop props param params parameter parameters argument arguments arg args variable variables column columns flag flags attribute attributes cookie cookies script scripts command commands option options setting settings function functions method methods"

# Classify one acceptance criterion for implied test data (design Decision 3).
# Pure: no I/O beyond stdout. Prints "<tier>\x1f<reason>\x1f<matched phrase>",
# tier strong|weak|none (reason and phrase empty for none).
# Quoted content is not data (rehearsal F28). Before any rule runs: a
# double-quoted span that reads as UI copy (_planner_testdata_quote_is_ui) is
# dropped; a backticked command (_planner_testdata_span_is_command) keeps
# only its arguments (_planner_testdata_span_args) and is never an entity; a
# backticked identifier next to a PLANNER_TESTDATA_IDENT_NOUNS word (or
# continuing a list of them) is dropped; and in a criterion only about what
# a document or file says (_planner_testdata_crit_is_doc_text) every quoted
# span is dropped.
#   strong: an inventory entity or a backticked lowercase entity in the
#           criterion (count+entity preferred for the phrase); existing /
#           seeded / pre-existing / already-existing state; "given a|an|the …
#           with"; "when there are"; list/filter/search/export of a plural
#           noun after a Given/When.
#   weak:   a count followed by a noun that is not a unit (denylist) or an
#           HTTP status code; a record-state word with no entity.
# Usage: _planner_testdata_implied_match <criterion> <entities-newline-list>
_planner_testdata_implied_match() {
  local crit="$1" ents_in="$2" lower span e doc=false scan=""
  local -a ents=()
  while IFS= read -r e; do
    e=$(_planner_testdata_entity_norm "$e")
    [ -n "$e" ] && ents+=("$e")
  done <<<"$ents_in"
  _planner_testdata_crit_is_doc_text "$crit" && doc=true
  # A backticked span that reads as a plain lowercase noun is an entity too
  # (`invoice`, `line item`); code-like spans (`GET`, `foo()`, `a/b`,
  # `snake_case_fn`) are not. Quoted content (see above) is removed from the
  # scanned text instead.
  local rest="$crit" pre prev_w next_w ident=false
  while [[ "$rest" =~ \`([^\`]+)\` ]]; do
    span="${BASH_REMATCH[1]}"
    pre="${rest%%\`"${span}"\`*}"
    rest="${rest#*\`"${span}"\`}"
    scan="${scan}${pre} "
    # A list continuation (", " / " and " / " or ") inherits the previous
    # span's identifier status; otherwise look at the adjacent words.
    if [ "$ident" = true ] && [[ "$pre" =~ ^[[:space:],]*((and|or)[[:space:]]+)?$ ]]; then
      :
    else
      prev_w=$(_planner_testdata_lower "$pre" | tr -c 'a-z' ' ' | awk '{ print $NF }')
      next_w=$(_planner_testdata_lower "$rest" | tr -c 'a-z' ' ' | awk '{ print $1 }')
      ident=false
      if _planner_testdata_in_list "${prev_w:-.}" "$PLANNER_TESTDATA_IDENT_NOUNS" ||
        _planner_testdata_in_list "${next_w:-.}" "$PLANNER_TESTDATA_IDENT_NOUNS"; then
        ident=true
      fi
    fi
    [ "$doc" = true ] && continue
    [ "$ident" = true ] && continue
    if _planner_testdata_span_is_command "$span"; then
      scan="${scan}$(_planner_testdata_span_args "$span") "
      continue
    fi
    scan="${scan}\`${span}\`"
    [[ "$span" =~ ^[a-z][a-z0-9\ -]{0,40}$ ]] && ents+=("$(_planner_testdata_entity_norm "$span")")
  done
  scan="${scan}${rest}"
  scan=$(_planner_testdata_strip_quotes "$scan" "$doc")
  lower=$(_planner_testdata_lower "$scan")

  local -a w=()
  local tok
  for tok in $(printf '%s' "$lower" | tr -c 'a-z0-9.%_\n-' ' '); do
    while [[ "$tok" =~ [.%_-]$ ]] && [[ ! "$tok" =~ ^[0-9.]+%$ ]]; do tok="${tok%?}"; done
    tok="${tok#[._-]}"
    [ -n "$tok" ] && w+=("$tok")
  done
  local n=${#w[@]} i j k len phrase

  # Strong 1: a count followed (within 3 words) by an entity. A number named
  # by the word before it (port, localhost, version) is not a count.
  for ((i = 0; i < n; i++)); do
    [[ "${w[i]}" =~ ^[0-9]+$ ]] || continue
    [ "$i" -gt 0 ] && _planner_testdata_in_list "${w[i - 1]}" "port version v localhost" && continue
    for ((j = i + 1; j < n && j <= i + 3; j++)); do
      for e in "${ents[@]}"; do
        len=$(_planner_testdata_entity_len_at "$e" "$j" "${w[@]}")
        [ "$len" -gt 0 ] || continue
        phrase="${w[*]:i:j-i+len}"
        k=$((j + len))
        [ "$k" -lt "$n" ] && _planner_testdata_in_list "${w[k]}" "record records row rows entry entries item items" &&
          phrase="${phrase} ${w[k]}"
        printf 'strong\037count+entity\037%s\n' "$phrase"
        return 0
      done
    done
  done
  # Strong 2: an entity anywhere.
  for ((j = 0; j < n; j++)); do
    for e in "${ents[@]}"; do
      len=$(_planner_testdata_entity_len_at "$e" "$j" "${w[@]}")
      [ "$len" -gt 0 ] || continue
      printf 'strong\037entity\037%s\n' "${w[*]:j:len}"
      return 0
    done
  done
  # Strong 3: existing / seeded / pre-existing state ("existing behaviour"
  # and friends are about code, not data).
  for ((i = 0; i < n; i++)); do
    case "${w[i]}" in
    existing | pre-existing | preexisting | seeded)
      phrase=$(_planner_testdata_np $((i + 1)) 3 "${w[@]}")
      case "${phrase%% *}" in
      behaviour | behavior | functionality | code | test | tests | logic | flow | flows | api | apis | endpoint | endpoints | contract | ui | layout | style | styles | "") continue ;;
      esac
      printf 'strong\037existing-state\037%s\n' "${w[i]} ${phrase}"
      return 0
      ;;
    already)
      if [ $((i + 1)) -lt "$n" ] && _planner_testdata_in_list "${w[i + 1]}" "exists exist existing"; then
        phrase=$(_planner_testdata_np $((i > 2 ? i - 2 : 0)) 2 "${w[@]}")
        printf 'strong\037existing-state\037%s\n' "${phrase:-already ${w[i + 1]}}"
        return 0
      fi
      ;;
    esac
  done
  # Strong 4: "given a|an|the … with".
  for ((i = 0; i + 1 < n; i++)); do
    [ "${w[i]}" = "given" ] || continue
    _planner_testdata_in_list "${w[i + 1]}" "a an the" || continue
    for ((j = i + 2; j < n && j <= i + 7; j++)); do
      if [ "${w[j]}" = "with" ] && [ "$j" -gt $((i + 2)) ]; then
        printf 'strong\037given-with\037%s\n' "${w[*]:i+2:j-i-2}"
        return 0
      fi
    done
  done
  # Strong 5: "when there are …".
  for ((i = 0; i + 2 < n; i++)); do
    if [ "${w[i]}" = "when" ] && [ "${w[i + 1]}" = "there" ] && [ "${w[i + 2]}" = "are" ]; then
      phrase=$(_planner_testdata_np $((i + 3)) 4 "${w[@]}")
      [ -n "$phrase" ] || phrase="${w[*]:i+3:4}"
      printf 'strong\037when-there-are\037%s\n' "${phrase:-records}"
      return 0
    fi
  done
  # Strong 6: list/filter/search/export of a plural noun, after Given/When.
  local gw=-1
  for ((i = 0; i < n; i++)); do
    if [ "${w[i]}" = "given" ] || [ "${w[i]}" = "when" ]; then
      gw=$i
      break
    fi
  done
  if [ "$gw" -ge 0 ]; then
    for ((i = gw + 1; i < n; i++)); do
      case "${w[i]}" in
      list | lists | listing | listed | filter | filters | filtering | filtered | search | searches | searching | searched | export | exports | exporting | exported) ;;
      *) continue ;;
      esac
      for ((j = i + 1; j < n && j <= i + 3; j++)); do
        if [[ "${w[j]}" =~ ^[a-z]{3,}s$ ]] && [[ ! "${w[j]}" =~ (ss|us|is)$ ]] &&
          ! _planner_testdata_in_list "${w[j]}" "$PLANNER_TESTDATA_UNIT_DENYLIST results this its was has does always" &&
          ! _planner_testdata_in_list "${w[j]}" "$_PLANNER_TESTDATA_STOPWORDS"; then
          printf 'strong\037list-over-entity\037%s\n' "${w[j]}"
          return 0
        fi
      done
    done
  fi
  # Weak 1: a count followed by a noun that is not a unit or a status code.
  # A number named by the word before it (port 5173, localhost:5173,
  # version 2) is an identifier, not a count.
  local num nx pv
  for ((i = 0; i + 1 < n; i++)); do
    num="${w[i]}"
    [[ "$num" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
    [ "$i" -gt 0 ] && _planner_testdata_in_list "${w[i - 1]}" "port version v localhost" && continue
    nx="${w[i + 1]}"
    [[ "$nx" =~ ^[a-z][a-z-]*$ ]] || continue
    _planner_testdata_in_list "$nx" "$PLANNER_TESTDATA_UNIT_DENYLIST" && continue
    _planner_testdata_in_list "$nx" "$_PLANNER_TESTDATA_STOPWORDS x" && continue
    if [[ "$num" =~ ^[1-5][0-9][0-9]$ ]]; then
      pv=""
      [ "$i" -gt 0 ] && pv="${w[i - 1]}"
      _planner_testdata_in_list "$pv" "http status code returns return returned responds respond responded with" && continue
      _planner_testdata_in_list "$nx" "ok created accepted error status response body page message not bad unauthorized forbidden conflict found redirect" && continue
    fi
    printf 'weak\037count+noun\037%s\n' "${num} ${nx}"
    return 0
  done
  # Weak 2: a record-state word with no entity.
  for ((i = 0; i < n; i++)); do
    _planner_testdata_in_list "${w[i]}" "$PLANNER_TESTDATA_STATE_WORDS" || continue
    phrase="${w[i]}"
    if [ $((i + 1)) -lt "$n" ] && [[ "${w[i + 1]}" =~ ^[a-z]+$ ]] &&
      ! _planner_testdata_in_list "${w[i + 1]}" "$_PLANNER_TESTDATA_STOPWORDS"; then
      phrase="${phrase} ${w[i + 1]}"
    fi
    printf 'weak\037state-word\037%s\n' "$phrase"
    return 0
  done
  printf 'none\037\037\n'
}

# strong|weak|none for one criterion — see _planner_testdata_implied_match.
# Usage: _planner_testdata_implies_data <criterion> <entities-newline-list>
_planner_testdata_implies_data() {
  _planner_testdata_implied_match "$1" "$2" | cut -d$'\037' -f1
}

_planner_testdata_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# First 8 hex digits of sha256("<slug>\n<criterion, CR stripped and
# trimmed>"). The key of a TESTDATA_CONFIRM answer: rewriting the criterion
# voids the answer. Usage: planner_testdata_confirm_hash <slug> <criterion>
planner_testdata_confirm_hash() {
  local crit
  crit=$(_planner_testdata_trim "$(printf '%s' "$2" | tr -d '\r')")
  printf '%s\n%s' "$1" "$crit" | _planner_testdata_sha256 | cut -c1-8
}

# Validate and normalise a TESTDATA_CONFIRM answer value. Free text has `|`,
# CR, LF and backticks stripped (tabs become spaces). Accepted, case-
# insensitive kind: none | generate: <desc> | exists:<where> | external:<who>.
# Prints the canonical value (`none`, `generate: <desc>`, `exists:<where>`,
# `external:<who>`); on rejection prints the reason on stderr and returns 1.
# Usage: planner_testdata_answer_normalize <value>
PLANNER_TESTDATA_ANSWER_VALUE_MAX=256
planner_testdata_answer_normalize() {
  local v="$1" lower kind val
  v=$(printf '%s' "$v" | tr -d '|\r\n`' | tr '\t' ' ' | LC_ALL=C tr -d '\000-\010\013-\037\177')
  v=$(_planner_testdata_trim "$v")
  lower=$(_planner_testdata_lower "$v")
  case "$lower" in
  none)
    printf 'none'
    return 0
    ;;
  generate:* | exists:* | external:*)
    kind="${lower%%:*}"
    val=$(_planner_testdata_trim "${v#*:}")
    ;;
  generate)
    echo "generate: needs a description of the data (generate: <description>)" >&2
    return 1
    ;;
  "")
    echo "a test-data answer must not be empty" >&2
    return 1
    ;;
  *)
    echo "a test-data answer must be none, generate: <description>, exists:<where> or external:<who>" >&2
    return 1
    ;;
  esac
  if [ -z "$val" ]; then
    case "$kind" in
    generate) echo "generate: needs a description of the data (generate: <description>)" >&2 ;;
    exists) echo "exists: needs a value (exists:<where>)" >&2 ;;
    external) echo "external: needs a value (external:<who>)" >&2 ;;
    esac
    return 1
  fi
  if [ "${#val}" -gt "$PLANNER_TESTDATA_ANSWER_VALUE_MAX" ]; then
    echo "a test-data answer value is at most ${PLANNER_TESTDATA_ANSWER_VALUE_MAX} characters" >&2
    return 1
  fi
  if [ "$kind" = "generate" ]; then
    printf 'generate: %s' "$val"
  else
    printf '%s:%s' "$kind" "$val"
  fi
}

# Parse one consensus.md line as a TESTDATA_CONFIRM answer:
#   TESTDATA_CONFIRM: `<slug>` [<hash8>] — Answer: <value>
# (anywhere on the line, so a `- ` bullet prefix is fine; the separator may
# be —, – or -). The value is everything after the FIRST "Answer:" following
# the hash. Prints "<slug>\x1f<hash8>\x1f<kind>\x1f<value>\x1f<raw answer>"
# and returns 0, or returns 1 when the line is not such an answer. kind is
# none | generate | exists | external, or "invalid" when the value does not
# normalise; value is the description/where/who (empty for none/invalid).
_planner_testdata_confirm_parse() {
  local line slug hash raw norm kind value
  line=$(printf '%s' "$1" | tr -d '\r*')
  [[ "$line" == *"TESTDATA_CONFIRM:"* ]] || return 1
  line="${line#*TESTDATA_CONFIRM:}"
  local re='^[[:space:]]*`([A-Za-z0-9_-]+)`[[:space:]]*\[([0-9a-fA-F]{8})\][^A]*Answer:(.*)$'
  [[ "$line" =~ $re ]] || return 1
  slug="${BASH_REMATCH[1]}"
  hash=$(_planner_testdata_lower "${BASH_REMATCH[2]}")
  raw=$(_planner_testdata_trim "${BASH_REMATCH[3]}")
  if norm=$(planner_testdata_answer_normalize "$raw" 2>/dev/null); then
    kind="${norm%%:*}"
    value=""
    [[ "$norm" == *:* ]] && value=$(_planner_testdata_trim "${norm#*:}")
  else
    kind="invalid"
    value=""
  fi
  printf '%s\037%s\037%s\037%s\037%s\n' "$slug" "$hash" "$kind" "$value" "$(_planner_testdata_safe "$raw")"
}

# Every TESTDATA_CONFIRM line in consensus.md, in file order:
#   <n>\x1f<slug>\x1f<hash8>\x1f<kind>\x1f<value>\x1f<raw answer>
# n is the 1-based position among such lines. Readers take the LAST line per
# slug (planner_testdata_answer_set keeps exactly one).
# Usage: planner_testdata_confirm_lines <consensus.md>
planner_testdata_confirm_lines() {
  local consensus="$1" line parsed n=0
  [ -f "$consensus" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    parsed=$(_planner_testdata_confirm_parse "$line") || continue
    n=$((n + 1))
    printf '%s\037%s\n' "$n" "$parsed"
  done <"$consensus"
}

# Write <slug>'s TESTDATA_CONFIRM line into consensus.md: replace it where it
# already is (any hash; earlier duplicates for the slug are dropped), else
# insert it after the last TESTDATA_CONFIRM line, else append it under a new
# `## Test Data Confirmations` heading. The new line is re-parsed before
# anything is written and must read back as exactly <slug>, <hash8> and the
# normalised value. Written tmp + mv (mode kept). Idempotent.
# Exit: 0 written, 1 file missing or write failed, 2 invalid slug/hash/value,
# 4 round-trip mismatch.
# Usage: planner_testdata_answer_set <consensus.md> <slug> <hash8> <value>
planner_testdata_answer_set() {
  local consensus="$1" slug="$2" hash="$3" value
  if ! [[ "$slug" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "planner_testdata_answer_set: slug '${slug}' is not a spec slug" >&2
    return 2
  fi
  if ! [[ "$hash" =~ ^[0-9a-f]{8}$ ]]; then
    echo "planner_testdata_answer_set: hash '${hash}' is not 8 lowercase hex digits" >&2
    return 2
  fi
  value=$(planner_testdata_answer_normalize "$4") || return 2
  [ -f "$consensus" ] || {
    echo "planner_testdata_answer_set: ${consensus} not found" >&2
    return 1
  }

  local new got gslug ghash gkind gvalue graw want_kind want_value=""
  new="- TESTDATA_CONFIRM: \`${slug}\` [${hash}] — Answer: ${value}"
  want_kind="${value%%:*}"
  [[ "$value" == *:* ]] && want_value=$(_planner_testdata_trim "${value#*:}")
  got=$(_planner_testdata_confirm_parse "$new") || got=""
  IFS=$'\037' read -r gslug ghash gkind gvalue graw <<<"$got"
  if [ "$gslug" != "$slug" ] || [ "$ghash" != "$hash" ] || [ "$gkind" != "$want_kind" ] || [ "$gvalue" != "$want_value" ]; then
    echo "planner_testdata_answer_set: line would read back as '${gslug}' [${ghash}] ${gkind}:${gvalue}, not '${slug}' [${hash}] ${value}" >&2
    return 4
  fi

  local -a lines=() out=()
  mapfile -t lines <"$consensus"
  local i last_mine=-1 last_any=-1 p cr=""
  [[ "${lines[0]:-}" == *$'\r' ]] && cr=$'\r'
  for i in "${!lines[@]}"; do
    p=$(_planner_testdata_confirm_parse "${lines[$i]}") || continue
    last_any=$i
    [ "${p%%$'\037'*}" = "$slug" ] && last_mine=$i
  done
  for i in "${!lines[@]}"; do
    if [ "$last_mine" -ge 0 ]; then
      if [ "$i" -eq "$last_mine" ]; then
        out+=("${new}${cr}")
        continue
      fi
      p=$(_planner_testdata_confirm_parse "${lines[$i]}") && [ "${p%%$'\037'*}" = "$slug" ] && continue
    fi
    out+=("${lines[$i]}")
    [ "$last_mine" -lt 0 ] && [ "$i" -eq "$last_any" ] && out+=("${new}${cr}")
  done
  if [ "$last_mine" -lt 0 ] && [ "$last_any" -lt 0 ]; then
    [ "${#out[@]}" -gt 0 ] && [ -n "$(_planner_testdata_trim "${out[${#out[@]} - 1]%$'\r'}")" ] && out+=("$cr")
    out+=("## Test Data Confirmations${cr}" "$cr" "${new}${cr}")
  fi

  local tmp="${consensus}.tmp.$$"
  cp -p "$consensus" "$tmp" && printf '%s\n' "${out[@]}" >"$tmp" && mv -f "$tmp" "$consensus" || {
    rm -f "$tmp"
    echo "planner_testdata_answer_set: could not write ${consensus}" >&2
    return 1
  }
  return 0
}

# The criterion that makes a spec's all-`none` Verification Notes suspect:
# the first strong-tier match in Acceptance Criteria order, else the first
# weak one. Prints
#   <tier>\x1f<reason>\x1f<phrase>\x1f<hash8>\x1f<criterion>
# and nothing when the spec is synth-marked, has no Verification Notes needs,
# has a need that is not `none`, or no criterion implies data.
# Usage: _planner_testdata_spec_trigger <spec_file> <entities-newline-list>
_planner_testdata_spec_trigger() {
  local spec_file="$1" ents="$2" slug label data kind value nneeds=0 crit m tier weak=""
  _planner_testdata_spec_is_synth "$spec_file" && return 0
  slug=$(basename "$spec_file" .md)
  while IFS=$'\037' read -r label data kind value; do
    [ -n "$label" ] || continue
    nneeds=$((nneeds + 1))
    _planner_testdata_is_none "$data" || return 0
  done < <(_planner_testdata_spec_needs "$spec_file")
  [ "$nneeds" -gt 0 ] || return 0
  while IFS= read -r crit; do
    [ -n "$crit" ] || continue
    m=$(_planner_testdata_implied_match "$crit" "$ents")
    tier="${m%%$'\037'*}"
    case "$tier" in
    strong)
      printf '%s\037%s\037%s\n' "$m" "$(planner_testdata_confirm_hash "$slug" "$crit")" "$crit"
      return 0
      ;;
    weak) [ -n "$weak" ] || weak=$(printf '%s\037%s\037%s' "$m" "$(planner_testdata_confirm_hash "$slug" "$crit")" "$crit") ;;
    esac
  done < <(_planner_testdata_ac_items "$spec_file")
  [ -n "$weak" ] && printf '%s\n' "$weak"
  return 0
}

# Inventory entity names, one per line (the heuristic's vocabulary).
_planner_testdata_entity_names() {
  planner_testdata_inventory_entities "$1" | cut -d$'\037' -f1
}

# TESTDATA_CONFIRM answers that still apply: the spec's current trigger
# criterion hashes to the line's hash and the value is well formed. One line
# per spec, specs in slug order:
#   <slug>\x1f<hash8>\x1f<kind>\x1f<value>\x1f<criterion>\x1f<matched phrase>
# kind none | generate | exists | external. A stale line (criterion rewritten)
# or an invalid value is not listed — the question is asked again.
# Usage: planner_testdata_confirm_resolved <initiative_id> [entities]
planner_testdata_confirm_resolved() {
  [ -n "${REPOS_ROOT:-}" ] || return 0
  local init="$1" ents state_dir specs_dir consensus
  state_dir=$(_planner_testdata_state_dir "$init")
  specs_dir="${state_dir}/artifacts/specs"
  consensus="${state_dir}/artifacts/consensus.md"
  [ -d "$specs_dir" ] && [ -f "$consensus" ] || return 0
  if [ "$#" -ge 2 ]; then ents="$2"; else ents=$(_planner_testdata_entity_names "$init"); fi

  local -A a_hash=() a_kind=() a_value=()
  local n slug hash kind value raw
  while IFS=$'\037' read -r n slug hash kind value raw; do
    a_hash["$slug"]="$hash"
    a_kind["$slug"]="$kind"
    a_value["$slug"]="$value"
  done < <(planner_testdata_confirm_lines "$consensus")
  [ "${#a_hash[@]}" -gt 0 ] || return 0

  local spec_file trig tier reason phrase thash crit
  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    slug=$(basename "$spec_file" .md)
    [ "$slug" = "INDEX" ] && continue
    [ -n "${a_hash[$slug]+set}" ] || continue
    [ "${a_kind[$slug]}" = "invalid" ] && continue
    trig=$(_planner_testdata_spec_trigger "$spec_file" "$ents")
    [ -n "$trig" ] || continue
    IFS=$'\037' read -r tier reason phrase thash crit <<<"$trig"
    [ "$thash" = "${a_hash[$slug]}" ] || continue
    printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$slug" "$thash" "${a_kind[$slug]}" "${a_value[$slug]}" "$crit" "$phrase"
  done
}

# `generate:` answers as unowned needs, for the test-data synthesis step:
#   <slug>\x1f<hash8>\x1f<description>
# Usage: planner_testdata_confirm_generate_needs <initiative_id>
planner_testdata_confirm_generate_needs() {
  local slug hash kind value crit phrase
  while IFS=$'\037' read -r slug hash kind value crit phrase; do
    [ "$kind" = "generate" ] && printf '%s\037%s\037%s\n' "$slug" "$hash" "$value"
  done < <(planner_testdata_confirm_resolved "$@")
  return 0
}

# A spec's needs, as _planner_testdata_spec_needs prints them
# (<label>\x1f<data>\x1f<kind>\x1f<value>), with an applying `exists:` or
# `external:` TESTDATA_CONFIRM answer folded in as the effective Source — in
# memory only, the spec is never edited. The table row whose Criterion is the
# trigger criterion takes the answer (data = the matched phrase); with no
# such row a `confirm` record is appended. `none` and `generate:` answers
# change nothing here (generate needs go to synthesis instead).
# Usage: planner_testdata_spec_effective_needs <initiative_id> <spec_file> [entities]
planner_testdata_spec_effective_needs() {
  local init="$1" spec_file="$2" slug ans="" r_slug r_hash r_kind r_value r_crit r_phrase
  slug=$(basename "$spec_file" .md)
  if [ "$#" -ge 3 ]; then
    ans=$(planner_testdata_confirm_resolved "$init" "$3" | awk -F'\037' -v s="$slug" '$1 == s')
  else
    ans=$(planner_testdata_confirm_resolved "$init" | awk -F'\037' -v s="$slug" '$1 == s')
  fi
  IFS=$'\037' read -r r_slug r_hash r_kind r_value r_crit r_phrase <<<"$ans"
  case "$r_kind" in
  exists | external) ;;
  *)
    _planner_testdata_spec_needs "$spec_file"
    return 0
    ;;
  esac
  # Which table data row (1-based) repeats the trigger criterion?
  local rows header ci k=0 row hit="" want
  want=$(_planner_testdata_need_key "$r_crit")
  rows=$(_planner_testdata_section "$spec_file" "Verification Notes" | _planner_testdata_notes_table)
  header=$(head -1 <<<"$rows")
  ci=$(_planner_testdata_col "$header" "criterion")
  if [ -n "$ci" ]; then
    while IFS= read -r row; do
      k=$((k + 1))
      local -a cells=()
      IFS=$'\037' read -r -a cells <<<"$row"
      if [ -z "$hit" ] && [ "$(_planner_testdata_need_key "${cells[ci - 1]:-}")" = "$want" ]; then hit=$k; fi
    done < <(tail -n +2 <<<"$rows")
  fi
  local label data kind value
  while IFS=$'\037' read -r label data kind value; do
    if [ -n "$hit" ] && [ "$label" = "$hit" ]; then
      printf '%s\037%s\037%s\037%s\n' "$label" "$r_phrase" "$r_kind" "$r_value"
    else
      printf '%s\037%s\037%s\037%s\n' "$label" "$data" "$kind" "$value"
    fi
  done < <(_planner_testdata_spec_needs "$spec_file")
  [ -n "$hit" ] || printf 'confirm\037%s\037%s\037%s\n' "$r_phrase" "$r_kind" "$r_value"
  return 0
}

# Usage: planner_crosscheck_testdata_tripwires <initiative_id>
# Returns: 0 if clean (or warn-only), 1 if a blocking finding was reported.
planner_crosscheck_testdata_tripwires() {
  local initiative_id="$1"
  [ -n "${REPOS_ROOT:-}" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  local state_dir specs_dir discovery strict=false blocking=0
  state_dir=$(_planner_testdata_state_dir "$initiative_id")
  specs_dir="${state_dir}/artifacts/specs"
  discovery="${state_dir}/artifacts/discovery.md"
  planner_testdata_contract_initiative "$initiative_id" && strict=true

  if [ "$strict" = true ] && [ -f "$discovery" ] &&
    ! _planner_testdata_has_section "$discovery" "Test Data Inventory"; then
    _planner_testdata_emit "planner-crosscheck-testdata: TEST_DATA_INVENTORY_MISSING discovery.md has no ## Test Data Inventory section — re-run Discovery or add the table (Entity / States/variants / Roles / Volume / Source / Load via / Privacy, or None.) so criteria can be matched against named entities"
  fi
  [ -d "$specs_dir" ] || return 0

  local ents
  ents=$(_planner_testdata_entity_names "$initiative_id")
  local -A resolved=()
  local r_slug r_hash r_kind r_value r_crit r_phrase
  while IFS=$'\037' read -r r_slug r_hash r_kind r_value r_crit r_phrase; do
    [ -n "$r_slug" ] && resolved["$r_slug"]="$r_hash"
  done < <(planner_testdata_confirm_resolved "$initiative_id" "$ents")

  local spec_file slug nac nneeds trig tier reason phrase hash crit code
  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    slug=$(basename "$spec_file" .md)
    [ "$slug" = "INDEX" ] && continue
    _planner_testdata_spec_is_synth "$spec_file" && continue

    nac=$(_planner_testdata_ac_items "$spec_file" | grep -c . || true)
    nneeds=$(_planner_testdata_spec_needs "$spec_file" | grep -c . || true)
    if [ "${nac:-0}" -gt 0 ] && [ "${nneeds:-0}" -eq 0 ] &&
      [ "$(_planner_testdata_spec_kind "$spec_file")" != "enabler" ]; then
      if [ "$strict" = true ]; then
        _planner_testdata_emit "planner-crosscheck-testdata: VERIFICATION_NOTES_MISSING ${slug}.md has ${nac} acceptance criteria and no ## Verification Notes table rows — add the table, one row per criterion (Test data derived from its Given/When, none only when nothing must exist first)"
        blocking=1
      else
        _planner_testdata_emit "planner-crosscheck-testdata: VERIFICATION_NOTES_MISSING_LEGACY ${slug}.md has ${nac} acceptance criteria and no ## Verification Notes table rows — not blocking because the initiative predates the test-data contract"
      fi
      continue
    fi

    trig=$(_planner_testdata_spec_trigger "$spec_file" "$ents")
    [ -n "$trig" ] || continue
    IFS=$'\037' read -r tier reason phrase hash crit <<<"$trig"
    [ "${resolved[$slug]:-}" = "$hash" ] && continue
    phrase="${phrase//\"/}"
    if [ "$tier" = "strong" ] && [ "$strict" = true ]; then
      code="TEST_DATA_IMPLIED"
      blocking=1
    else
      code="TEST_DATA_IMPLIED_WEAK"
      [ "$tier" = "strong" ] && reason="${reason}; strong, warn-only because the initiative predates the test-data contract"
    fi
    _planner_testdata_emit "planner-crosscheck-testdata: ${code} ${slug}.md [${hash}] match=\"${phrase}\" (${tier}: ${reason}) — every Verification Notes row says Test data none, but this criterion implies data must exist first: \"${crit}\" — derive the need from its Given/When with a Source, or answer TESTDATA_CONFIRM: \`${slug}\` [${hash}] in consensus.md (none, generate: <what>, exists:<where>, external:<who>)"
  done

  [ "$blocking" -eq 0 ]
}

# Crosscheck's test-data synthesis reads this file's parsers, and this file's
# row walker reads synthesis' sidecar (planner_testdata_synth_overrides) —
# source it last, so its own guard finds every function above defined.
if ! declare -f planner_testdata_synth_overrides >/dev/null 2>&1; then
  # shellcheck source=planner-testdata-synth.sh
  [ -f "$(dirname "${BASH_SOURCE[0]}")/planner-testdata-synth.sh" ] &&
    source "$(dirname "${BASH_SOURCE[0]}")/planner-testdata-synth.sh"
fi
