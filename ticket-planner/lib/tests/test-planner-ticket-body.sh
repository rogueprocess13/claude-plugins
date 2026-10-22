#!/usr/bin/env bash
# test-planner-ticket-body.sh — issue #499: TicketGen is deterministic.
#
# The TicketGen prompt used to hand the agent placeholder values (deps_json,
# ticket_ids, description) and leave it to compose each body, match
# Verification Notes to ACs, and pass the epic identifier as parentId. Every
# one of those let two runs over the same specs produce different bodies.
#
# Covers:
#   1. Dependency extraction (exact / prefix / external / dangling refs),
#      deterministic creation order (ties by slug, isolated nodes kept),
#      cycle → no order.
#   2. Title / type extraction from the spec.
#   3. Verification Plan generation: rows in AC order, mapped by criterion
#      text whatever order the notes are in (the amended-notes case that
#      broke positional mapping), pipes escaped, ✓ only when earned,
#      unmatched AC / stray note / legacy numbered notes reported.
#   4. Body composition: dropped sections, H1, fenced `## ` lines kept,
#      Related Tickets, Planner Context `Generated` from the state log.
#   5. planner_ticketgen_body is byte-identical across runs and passes the
#      real validators (planned-ticket-check + planned-ticket-body-check,
#      vplan-parse).
#   6. planner_linear_create_issue resolves a parent identifier to its UUID.
#   7. End to end: the TicketGen prompt's own script, executed twice against
#      two separate initiatives built from the same specs (Linear stubbed at
#      the curl boundary), creates every ticket in dependency order with a
#      UUID parentId and byte-identical bodies.
#   8. The rendered prompt has no placeholder or example value left to fill.
#
# Usage: bash ticket-planner/lib/tests/test-planner-ticket-body.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGIN_ROOT="$(cd "${LIB_DIR}/.." && pwd)"
TAP_LIB_DIR="$(cd "${PLUGIN_ROOT}/../ticket-auto-pipeline/lib" && pwd)"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Hermetic: never resolve an installed plugin cache or skills-lib copy.
export HOME="${TMP_ROOT}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${TMP_ROOT}/repos"

source "${LIB_DIR}/planner-ticket-body.sh"
source "${LIB_DIR}/planner-linear-api.sh"
source "${TAP_LIB_DIR}/vplan-parse.sh"

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}

echo "=== planner ticket-body tests (#499) ==="

# ── Fixture specs ────────────────────────────────────────────────────────────

INIT="INIT-499"
SPECS="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}/artifacts/specs"
mkdir -p "$SPECS"

# _spec <slug> <title> <labels-line> <ac-lines> <notes-section>
_spec() {
  local slug="$1" title="$2" labels="$3" acs="$4" notes="$5"
  cat >"${SPECS}/${slug}.md" <<SPEC
# ${slug}

## Title

${title}

## Description

## Summary

${title}, in plain language.

## Outcome

**Serves:** O1

**Who:** Finance user

**Need:** Export invoices.

**Outcome:** Invoices can be exported.

## Background / Motivation

Finance exports invoices by hand today.


## Proposed Behaviour

An Export action on the invoice list.

## Technical Context

- Route \`GET /api/invoices/export\`.

\`\`\`markdown
## Not a heading — inside a code fence
\`\`\`

## Acceptance Criteria

${acs}

## Out of Scope

Scheduled exports.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | web     | invoices |

## Test User

\`finance@example.com\` — password \`finance\`

## Navigation Path

\`Billing > Invoices\`

## Test Data Prerequisites

None — the composer generates this section from the Verification Notes table.

## Related Tickets

None

## Labels

${labels}

## Signals

\`\`\`json
{
  "services_identified": 2,
  "symbols_resolved": 3,
  "prior_art_found": true,
  "complexity": "moderate",
  "exploration_depth": "standard",
  "Strategy": "Balanced",
  "Decision": "Add an export route",
  "AffectedServices": "web",
  "TargetSymbols": "exportInvoices:web/src/invoices.ts:10",
  "Kind": "business",
  "Serves": ["O1"],
  "Enables": []
}
\`\`\`

${notes}
SPEC
}

ACS_A='- [ ] The Export button appears on the invoice list
- [ ] Export downloads a file named invoices-{date}.csv
- [ ] Rows in the file use the format date | amount'

# Notes deliberately out of AC order, plus one stray row: mapping must be by
# criterion text, never position.
NOTES_A='## Verification Notes

| Criterion | Role | Test data | Navigation path | Expected | Verifiable |
|-----------|------|-----------|-----------------|----------|------------|
| Rows in the file use the format date \| amount | finance user | 5 seeded invoices | | each row reads 2026-09-30 \| 120.00 | yes |
| The Export button appears on the invoice list | finance user | none | Billing > Invoices | Export button visible | no |
| Export downloads a file named invoices-{date}.csv. | finance user | 5 seeded invoices | | invoices-2026-09-30.csv downloaded | yes |
| A criterion that was edited away | admin | none | | n/a | yes |'

_spec "a-schema" "Persist invoice exports" "planned, ${INIT}, feature" "$ACS_A" "$NOTES_A"
_spec "b-api" "Finance can export invoices" "planned, ${INIT}, \`type:feature\`, blocked-by:a" \
  "- [ ] Export responds with 200" \
  '## Verification Notes

| Criterion | Role | Test data | Expected | Verifiable |
|---|---|---|---|---|
| Export responds with 200 | finance user | none | HTTP 200 | yes |'
_spec "c-ui" "Finance sees export progress" \
  "planned, ${INIT}, feature, blocked-by:b-api, \`blocked-by:WIL-83\`, blocked-by:b-api" \
  "- [ ] Progress shows while exporting
- [ ] Progress hides when done" \
  '## Verification Notes

1. Role: finance user. Test data: none.
2. Role: finance user. Test data: none.'
_spec "d-docs" "Document the export" "planned, ${INIT}, chore" "- [ ] The export is documented" \
  '## Verification Notes

| Criterion | Role | Test data | Expected | Verifiable |
|---|---|---|---|---|
| The export is documented | any authenticated user | none | docs page lists Export | yes |'
printf '# Spec Index\n' >"${SPECS}/INDEX.md"

# ── 1. Dependencies and order ────────────────────────────────────────────────

echo "--- dependencies ---"
deps=$(planner_ticketgen_deps_json "$SPECS")
want='{"a-schema":[],"b-api":["a-schema"],"c-ui":["b-api","WIL-83"],"d-docs":[]}'
if [ "$(jq -cS . <<<"$deps")" = "$(jq -cS . <<<"$want")" ]; then
  pass "prefix ref resolved to the full slug, external id kept, duplicates dropped, INDEX excluded"
else
  fail "deps_json" "got $deps"
fi
if [ "$(planner_ticketgen_ids_json "$SPECS")" = '["a-schema","b-api","c-ui","d-docs"]' ]; then
  pass "ids_json lists every spec slug, sorted"
else
  fail "ids_json" "$(planner_ticketgen_ids_json "$SPECS")"
fi
if planner_deps_check_acyclic "$deps" && planner_deps_validate_targets "$deps" "$(planner_ticketgen_ids_json "$SPECS")" 2>/dev/null; then
  pass "the generated graph passes the existing acyclic + targets checks"
else
  fail "deps validation" "rejected $deps"
fi

order=$(planner_ticketgen_order "$SPECS" | paste -sd' ')
if [ "$order" = "a-schema b-api c-ui d-docs" ]; then
  pass "creation order: dependencies first, ties by slug, isolated spec kept"
else
  fail "creation order" "got '$order'"
fi

echo "--- a dangling ref survives so validate_targets reports it ---"
DANG="${TMP_ROOT}/dangling"
mkdir -p "$DANG"
printf '## Labels\n\nfeature, blocked-by:nope\n' >"${DANG}/x-one.md"
if ! planner_deps_validate_targets "$(planner_ticketgen_deps_json "$DANG")" "$(planner_ticketgen_ids_json "$DANG")" 2>/dev/null; then
  pass "an unresolved sibling ref is reported as dangling"
else
  fail "dangling ref" "validate_targets accepted it"
fi

echo "--- a cycle yields no order ---"
CYC="${TMP_ROOT}/cycle"
mkdir -p "$CYC"
printf '## Labels\n\nfeature, blocked-by:q-two\n' >"${CYC}/p-one.md"
printf '## Labels\n\nfeature, blocked-by:p-one\n' >"${CYC}/q-two.md"
rc=0
out=$(planner_ticketgen_order "$CYC" 2>/dev/null) || rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
  pass "cyclic specs: exit non-zero, nothing printed"
else
  fail "cycle" "rc=$rc out=$out"
fi

# ── 2. Title and type ────────────────────────────────────────────────────────

echo "--- title / type ---"
[ "$(planner_ticketgen_spec_title "${SPECS}/b-api.md")" = "Finance can export invoices" ] &&
  pass "title from ## Title" || fail "title" "$(planner_ticketgen_spec_title "${SPECS}/b-api.md")"
printf '# Ship the thing\n\n## Labels\n\nbug\n' >"${TMP_ROOT}/h1.md"
[ "$(planner_ticketgen_spec_title "${TMP_ROOT}/h1.md")" = "Ship the thing" ] &&
  pass "title falls back to a non-slug H1" || fail "H1 title" "$(planner_ticketgen_spec_title "${TMP_ROOT}/h1.md")"
[ "$(planner_ticketgen_spec_type "${SPECS}/b-api.md")" = "feature" ] &&
  pass "type from a backticked type: token" || fail "type" "$(planner_ticketgen_spec_type "${SPECS}/b-api.md")"
[ "$(planner_ticketgen_spec_type "${SPECS}/d-docs.md")" = "chore" ] &&
  pass "type from a bare token" || fail "bare type" "$(planner_ticketgen_spec_type "${SPECS}/d-docs.md")"
printf '## Labels\n\nplanned, INIT-1\n' >"${TMP_ROOT}/notype.md"
if planner_ticketgen_spec_type "${TMP_ROOT}/notype.md" >/dev/null 2>&1; then
  fail "missing type" "returned 0"
else
  pass "no type token → exit 1"
fi

# ── 3. Verification Plan ─────────────────────────────────────────────────────

echo "--- Verification Plan: mapped by criterion text, rows in AC order ---"
vplan=$(planner_ticketgen_vplan "${SPECS}/a-schema.md" 2>"${TMP_ROOT}/vp.err")
rows=$(grep -E '^\| [0-9]+ \|' <<<"$vplan")
row1=$(sed -n 1p <<<"$rows")
row2=$(sed -n 2p <<<"$rows")
row3=$(sed -n 3p <<<"$rows")
[ "$row1" = "| 1 | The Export button appears on the invoice list | finance user | Billing > Invoices | none | Export button visible |  |" ] &&
  pass "row 1 follows AC 1, Verifiable blank when the notes say no" || fail "row 1" "$row1"
[ "$row2" = "| 2 | Export downloads a file named invoices-{date}.csv | finance user | Billing > Invoices | 5 seeded invoices | invoices-2026-09-30.csv downloaded | ✓ |" ] &&
  pass "row 2 matched despite a trailing period, nav falls back to ## Navigation Path" || fail "row 2" "$row2"
[ "$row3" = '| 3 | Rows in the file use the format date \| amount | finance user | Billing > Invoices | 5 seeded invoices | each row reads 2026-09-30 \| 120.00 | ✓ |' ] &&
  pass "row 3 matched from the first notes row; literal pipes stay escaped" || fail "row 3" "$row3"
if grep -qF 'matches no Acceptance Criteria line: A criterion that was edited away' "${TMP_ROOT}/vp.err"; then
  pass "a stray note is reported on stderr"
else
  fail "stray note warning" "$(cat "${TMP_ROOT}/vp.err")"
fi
if vplan_parse "$vplan" && [ "$VPLAN_ROWS" -eq 3 ] && [ "$VPLAN_VERIFIABLE" -eq 2 ]; then
  pass "vplan_parse accepts the generated section (3 rows, 2 verifiable — escaped pipes in row 3 keep ✓ in its column)"
else
  fail "vplan_parse" "rows=${VPLAN_ROWS:-unset} verifiable=${VPLAN_VERIFIABLE:-unset}"
fi

echo "--- legacy numbered notes are reported, not mapped by position ---"
vplan_c=$(planner_ticketgen_vplan "${SPECS}/c-ui.md" 2>"${TMP_ROOT}/vpc.err")
if grep -qF 'numbered Verification Notes carry no criterion text' "${TMP_ROOT}/vpc.err" &&
  [ "$(grep -cE '^\| [12] \| .*\| not recorded in spec \|  \|$' <<<"$vplan_c")" -eq 2 ]; then
  pass "both rows say not recorded, Verifiable blank, one warning"
else
  fail "legacy notes" "err=$(cat "${TMP_ROOT}/vpc.err") vplan=$vplan_c"
fi

echo "--- an AC with no note is reported ---"
sed 's/^| The Export button appears on the invoice list .*$//' "${SPECS}/a-schema.md" >"${TMP_ROOT}/gap.md"
planner_ticketgen_vplan "${TMP_ROOT}/gap.md" >/dev/null 2>"${TMP_ROOT}/gap.err"
if grep -qF 'AC 1 has no Verification Notes entry' "${TMP_ROOT}/gap.err"; then
  pass "uncovered AC reported by number"
else
  fail "uncovered AC" "$(cat "${TMP_ROOT}/gap.err")"
fi

# ── 4. Composition ───────────────────────────────────────────────────────────

echo "--- composition ---"
ctx=$'## Planner Context\n**Schema-Version:** 1'
body=$(planner_ticket_body_compose "${SPECS}/c-ui.md" "$ctx" $'CRE-12\tFinance can export invoices' $'WIL-83\t' 2>/dev/null)
ok=1
for gone in '^# c-ui$' '^## Title$' '^## Description$' '^## Labels$' '^## Signals$' '^## Verification Notes$' '"services_identified"' '^None$'; do
  if grep -qE "$gone" <<<"$body"; then
    ok=0
    fail "dropped from the body: $gone" "still present"
  fi
done
[ "$ok" = 1 ] && pass "H1, Title, Description heading, Labels, Signals, Verification Notes and the placeholder Related Tickets are dropped"
grep -qxF '## Not a heading — inside a code fence' <<<"$body" &&
  pass "a '## ' line inside a code fence is content, not a section" || fail "fenced heading" "dropped"
[ "$(head -1 <<<"$body")" = "## Summary" ] && pass "body opens with ## Summary" || fail "first line" "$(head -1 <<<"$body")"
grep -qxF -- '- Blocked by CRE-12 — Finance can export invoices' <<<"$body" && grep -qxF -- '- Blocked by WIL-83' <<<"$body" &&
  pass "Related Tickets lists each dependency" || fail "Related Tickets" "$(sed -n '/^## Related Tickets/,/^## Planner/p' <<<"$body")"
[ "$(grep -c '^## Related Tickets$' <<<"$body")" = 1 ] && [ "$(grep -c '^## Verification Plan$' <<<"$body")" = 1 ] &&
  pass "exactly one Related Tickets and one Verification Plan section" || fail "section count" "dup"
[ "$(tail -2 <<<"$body")" = "$ctx" ] && pass "Planner Context block closes the body, verbatim" || fail "context last" "$(tail -3 <<<"$body")"
if awk 'prev=="" && $0=="" {bad=1} {prev=$0} END {exit bad}' <<<"$body"; then
  pass "no runs of blank lines outside fences"
else
  fail "blank-line squeeze" "double blank line found"
fi
none_body=$(planner_ticket_body_compose "${SPECS}/a-schema.md" "$ctx" 2>/dev/null)
sed -n '/^## Related Tickets$/,/^## Planner Context$/p' <<<"$none_body" | grep -qxF 'None.' &&
  pass "no dependencies → Related Tickets: None." || fail "None." "$(sed -n '/^## Related Tickets$/,/^## Planner/p' <<<"$none_body")"

echo "--- test-data Source (#503): Verification Plan cell and Test Data Prerequisites ---"
TDDIR="${TMP_ROOT}/td-specs"
mkdir -p "$TDDIR"
cat >"${TDDIR}/td-export.md" <<'SPEC'
# td-export

## Title

Finance can export invoices

## Description

## Summary

Export invoices.

## Acceptance Criteria

- [ ] Export downloads a file
- [ ] The list looks uncluttered
- [ ] Totals use the regional price list
- [ ] Archived clients are hidden
- [ ] Unsourced data shows

## Test User

finance@example.com / pw

## Test Data Prerequisites

- 5 Seeded invoices with distinct dates.

## Labels

`feature`, `planned`

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Export downloads a file | finance user | 5 seeded invoices with distinct dates | seeded-by:inv-0-test-data-pack | Billing > Invoices | invoices.csv downloaded | yes |
| The list looks uncluttered | any authenticated user | none | — | | needs judgement | no |
| Totals use the regional price list | finance user | the regional price list. **Source:** external:pricing team. | | | total 1,240.00 | yes |
| Archived clients are hidden | admin | an archived client record | `Source: exists:staging seed set (clients.sql)` | | absent | yes |
| Unsourced data shows | admin | 3 draft invoices | | | shown | yes |
SPEC
td_body=$(planner_ticket_body_compose "${TDDIR}/td-export.md" "$ctx" 2>/dev/null)
td_vplan=$(sed -n '/^## Verification Plan$/,/^## Related Tickets$/p' <<<"$td_body")
grep -qF '| 5 seeded invoices with distinct dates (Source: seeded-by:inv-0-test-data-pack) |' <<<"$td_vplan" &&
  pass "Verification Plan cell: <what> (Source: <source>) from the Source column" || fail "vplan Source cell (column)" "$td_vplan"
grep -qF '| the regional price list (Source: external:pricing team) |' <<<"$td_vplan" &&
  pass "Verification Plan cell: an inline Source in the Test data cell is split out" || fail "vplan Source cell (inline)" "$td_vplan"
grep -qF '| an archived client record (Source: exists:staging seed set (clients.sql)) |' <<<"$td_vplan" &&
  pass "Verification Plan cell: a Source cell written with its marker and backticks" || fail "vplan Source cell (marker)" "$td_vplan"
grep -qF '| n/a | none | needs judgement |' <<<"$td_vplan" &&
  pass "Verification Plan cell: none data carries no Source" || fail "vplan none cell" "$td_vplan"
grep -qF '| 3 draft invoices | shown |' <<<"$td_vplan" &&
  pass "Verification Plan cell: no Source recorded → no Source invented" || fail "vplan unsourced cell" "$td_vplan"
td_prereq=$(sed -n '/^## Test Data Prerequisites$/,/^## Verification Plan$/p' <<<"$td_body" | sed '1d;$d' | sed '/^$/d')
td_want='- 5 seeded invoices with distinct dates. Source: seeded-by:inv-0-test-data-pack
- the regional price list. Source: external:pricing team
- an archived client record. Source: exists:staging seed set (clients.sql)
- 3 draft invoices'
[ "$td_prereq" = "$td_want" ] &&
  pass "Test Data Prerequisites: one '- <what>. Source: <source>' bullet per need, AC order, none skipped" ||
  fail "Test Data Prerequisites bullets" "$td_prereq"
[ "$(grep -c '^## Test Data Prerequisites$' <<<"$td_body")" = 1 ] &&
  pass "exactly one Test Data Prerequisites section" || fail "prereq section count" "$(grep -c '^## Test Data Prerequisites$' <<<"$td_body")"
grep -qF '5 Seeded invoices' <<<"$td_body" && fail "hand-written prereqs" "not replaced" ||
  pass "a hand-written Test Data Prerequisites (every item a table need) is replaced by the generated one"
# The readiness grammar (docs/test-data-source.md "For #505"): every bullet
# Crosscheck's segment parser reads back gives the Source the spec recorded.
source "${LIB_DIR}/planner-crosscheck-testdata.sh"
td_kinds=$(while IFS= read -r b; do
  _planner_testdata_parse_segment "${b#- }" | cut -d$'\037' -f2
done <<<"$td_prereq" | paste -sd, -)
[ "$td_kinds" = "seeded-by,external,exists," ] &&
  pass "Test Data Prerequisites bullets parse back with the contract's Source grammar" || fail "bullet grammar" "$td_kinds"
# Same spec, crosscheck view: the table rows are the needs.
td_needs=$(_planner_testdata_spec_needs "${TDDIR}/td-export.md" | cut -d$'\037' -f1,3 | tr '\037' ':' | paste -sd' ' -)
[ "$td_needs" = "1:seeded-by 2: 3:external 4:exists 5:" ] &&
  pass "Crosscheck reads the same table rows the composer renders" || fail "crosscheck table needs" "$td_needs"

cat >"${TDDIR}/td-nodata.md" <<'SPEC'
# td-nodata

## Acceptance Criteria

- [ ] Read-only view loads

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|---|---|---|---|---|---|
| Read-only view loads | admin | none | — | page loads | yes |
SPEC
nd_body=$(planner_ticket_body_compose "${TDDIR}/td-nodata.md" "$ctx" 2>/dev/null)
sed -n '/^## Test Data Prerequisites$/,/^## Verification Plan$/p' <<<"$nd_body" |
  grep -qxF -- '- None — no acceptance criterion needs test data.' &&
  pass "no criterion needs data → a single none bullet (section never empty)" || fail "none bullet" "$nd_body"

cat >"${TDDIR}/td-legacy.md" <<'SPEC'
# td-legacy

## Acceptance Criteria

- [ ] Something

## Test Data Prerequisites

- Hand-written legacy prerequisite. Source: exists:prod copy

## Verification Notes

1. Role: admin. Test data: a record. Source: exists:prod copy.
SPEC
lg_body=$(planner_ticket_body_compose "${TDDIR}/td-legacy.md" "$ctx" 2>/dev/null)
grep -qxF -- '- Hand-written legacy prerequisite. Source: exists:prod copy' <<<"$lg_body" &&
  [ "$(grep -c '^## Test Data Prerequisites$' <<<"$lg_body")" = 1 ] &&
  pass "legacy spec without a notes table keeps its own Test Data Prerequisites" || fail "legacy prereqs" "$lg_body"

echo "--- one Verification Notes reader: composer and Crosscheck agree (#499 x #503 review) ---"
# _vn <name> <notes-section-text> [text before the notes] — a minimal spec
# with ACs "Export works" and "Totals are right".
_vn() {
  {
    printf '# %s\n\n## Acceptance Criteria\n\n- [ ] Export works\n- [ ] Totals are right\n\n' "$1"
    [ -n "${3:-}" ] && printf '%s\n\n' "$3"
    printf '%s\n' "$2"
  } >"${TDDIR}/$1.md"
  echo "${TDDIR}/$1.md"
}
VN_HDR='| Criterion | Role | Test data | Source | Expected | Verifiable |
|---|---|---|---|---|---|'
VN_ROW1='| Export works | finance user | 5 seeded invoices | seeded-by:ghost-spec | file downloaded | yes |'
VN_ROW2='| Totals are right | finance user | the regional price list | external:pricing team | 1,240.00 | yes |'
# Crosscheck's view: sorted "data|kind[:value]" for every need with data.
_cc_view() {
  _planner_testdata_spec_needs "$1" | while IFS=$'\037' read -r _l d k v; do
    _planner_testdata_is_none "$d" && continue
    printf '%s|%s%s\n' "$d" "$k" "${v:+:$v}"
  done | LC_ALL=C sort -u
}
# The composed ticket's view: Test Data Prerequisites bullets parsed back
# with the contract grammar, sorted.
_body_view() {
  sed -n '/^## Test Data Prerequisites$/,/^## Verification Plan$/p' <<<"$1" | grep '^- ' |
    while IFS= read -r b; do
      _planner_testdata_parse_segment "$(_planner_testdata_norm_line "${b#- }")" |
        awk -F'\037' '{ printf "%s|%s%s\n", $1, $2, ($3 != "" ? ":" $3 : "") }'
    done | grep -v '^None' | LC_ALL=C sort -u
}
# _agree <label> <spec>: composes, and asserts both views are equal.
_agree() {
  local b cc bv
  b=$(planner_ticket_body_compose "$2" "$ctx" 2>/dev/null) || {
    fail "agree: $1" "composer refused"
    return
  }
  cc=$(_cc_view "$2")
  bv=$(_body_view "$b")
  [ "$cc" = "$bv" ] && [ -n "$cc" ] && pass "agree: $1 — ticket needs and Sources equal Crosscheck's" ||
    fail "agree: $1" "crosscheck={$cc} body={$bv}"
}
# _refused <label> <spec> <reason-substring>: composer refuses AND Crosscheck
# reports the same reason, so neither side reads a shape the other cannot.
_vn_refused() {
  local err rc=0
  err=$(planner_ticket_body_compose "$2" "$ctx" 2>&1 >/dev/null) || rc=$?
  [ "$rc" -ne 0 ] && [[ "$err" == *"$3"* ]] && pass "refused by composer: $1" || fail "composer refuses: $1" "rc=$rc err=$err"
  [[ "$(_planner_testdata_notes_problems "$2")" == *"$3"* ]] && pass "reported by Crosscheck: $1" ||
    fail "Crosscheck reports: $1" "$(_planner_testdata_notes_problems "$2")"
}

_agree "plain table" "$(_vn vn-plain "## Verification Notes

$VN_HDR
$VN_ROW1
$VN_ROW2")"
# e9: `### Verification Notes` and a suffixed heading are read, not legacy.
f=$(_vn vn-h3 "### Verification Notes

$VN_HDR
$VN_ROW1
$VN_ROW2")
_agree "### Verification Notes" "$f"
b=$(planner_ticket_body_compose "$f" "$ctx" 2>/dev/null)
grep -qF '| 5 seeded invoices (Source: seeded-by:ghost-spec) |' <<<"$b" &&
  pass "### Verification Notes: Verification Plan cell carries the Source" || fail "h3 vplan" "$b"
grep -qi 'verification notes' <<<"$b" && fail "h3 notes leak" "$b" || pass "### Verification Notes is not copied into the body"
f=$(_vn vn-perac "## Verification Notes (per AC)

$VN_HDR
$VN_ROW1
$VN_ROW2")
_agree "## Verification Notes (per AC)" "$f"
grep -qi 'verification notes' <<<"$(planner_ticket_body_compose "$f" "$ctx" 2>/dev/null)" &&
  fail "per-AC notes leak" "copied" || pass "## Verification Notes (per AC) is not copied into the body"
# Header markup is stripped before columns are located.
_agree "**Test data** / **Source** headers" "$(_vn vn-bold "## Verification Notes

| Criterion | Role | **Test data** | **Source** | Expected | Verifiable |
|---|---|---|---|---|---|
$VN_ROW1
$VN_ROW2")"
_agree "\`Source\` / _Test data_ headers" "$(_vn vn-crlf "## Verification Notes

| Criterion | Role | _Test data_ | \`Source\` | Expected | Verifiable |
|---|---|---|---|---|---|
$VN_ROW1
$VN_ROW2")"
f=$(_vn vn-crlf2 "## Verification Notes

$VN_HDR
$VN_ROW1")
sed -i 's/$/\r/' "$f"
_agree "CRLF spec" "$f"
_agree "escaped pipe in cells" "$(_vn vn-pipe "## Verification Notes

$VN_HDR
| Export works | finance user | rows of date \| amount | exists:staging seed | ok | yes |")"
_agree "inline Source in Test data cell, emphasis and backticks" "$(_vn vn-inline "## Verification Notes

$VN_HDR
| Export works | finance user | 5 seeded invoices. **Source:** seeded-by:ghost-spec | | ok | yes |
| Totals are right | finance user | the price list | \`Source: _external:pricing team_\` | ok | yes |")"
# Resource: / Latest data: are prose, not markers — in both readers.
f=$(_vn vn-resource "## Verification Notes

$VN_HDR
| Export works | ops | Resource: printer queue | exists:staging printers | ok | yes |")
_agree "Resource: in data is not a Source marker" "$f"
[ "$(_cc_view "$f")" = "Resource: printer queue|exists:staging printers" ] &&
  pass "Resource: stays in the data text" || fail "Resource:" "$(_cc_view "$f")"
# e11: every data row, not only AC-matched ones — a duplicate criterion and a
# criterion edited away both keep their needs in the ticket.
f=$(_vn vn-allrows "## Verification Notes

$VN_HDR
$VN_ROW1
| Export works | admin | an admin account with export rights | exists:staging admin | ok | yes |
| A criterion edited away | admin | prod-like dataset | exists:prod snapshot | ok | yes |")
_agree "duplicate and unmatched criterion rows" "$f"
b=$(planner_ticket_body_compose "$f" "$ctx" 2>/dev/null)
grep -qxF -- '- an admin account with export rights. Source: exists:staging admin' <<<"$b" &&
  grep -qxF -- '- prod-like dataset. Source: exists:prod snapshot' <<<"$b" &&
  pass "Test Data Prerequisites lists every row's need" || fail "all rows" "$b"
# e11: a hand-written prerequisite no table row records is refused, never dropped.
_vn_refused "hand-written prerequisite missing from the table" "$(_vn vn-tdp "## Verification Notes

$VN_HDR
$VN_ROW1" "## Test Data Prerequisites

- A staging tenant with SSO enabled. Source: exists:staging tenant acme
- 5 seeded invoices. Source: seeded-by:ghost-spec")" "names 'A staging tenant with SSO enabled'"
_agree "hand-written prerequisites that are all table needs" "$(_vn vn-tdp-ok "## Verification Notes

$VN_HDR
$VN_ROW1" "## Test Data Prerequisites

- 5 seeded invoices. Source: seeded-by:ghost-spec")"
# e10 (BLOCKER) and friends: shapes where readers can disagree are refused.
_vn_refused "fenced table" "$(_vn vn-fence "## Verification Notes

\`\`\`
$VN_HDR
$VN_ROW1
\`\`\`")" "code fence inside Verification Notes"
_vn_refused "tilde-fenced table" "$(_vn vn-tilde "## Verification Notes

~~~
$VN_HDR
$VN_ROW1
~~~")" "code fence inside Verification Notes"
_vn_refused "table after a ### sub-heading" "$(_vn vn-sub "## Verification Notes

### Per criterion

$VN_HDR
$VN_ROW1")" "sub-heading inside Verification Notes"
_vn_refused "duplicate ## Verification Notes" "$(_vn vn-dup "## Verification Notes

$VN_HDR
| Export works | op | none | — | ok | yes |

## Verification Notes

$VN_HDR
$VN_ROW1")" "2 Verification Notes headings"
_vn_refused "fenced Verification Notes heading as well" "$(_vn vn-dupfence "## Verification Notes

$VN_HDR
$VN_ROW2" "\`\`\`
## Verification Notes
$VN_HDR
$VN_ROW1
\`\`\`")" "2 Verification Notes headings"
_vn_refused "NBSP in the heading" "$(_vn vn-nbsp "## Verification$(printf '\xc2\xa0')Notes

$VN_HDR
$VN_ROW1")" "plain ASCII"
_vn_refused "zero-width space in the heading" "$(_vn vn-zwsp "## Verification$(printf '\xe2\x80\x8b') Notes

$VN_HDR
$VN_ROW1")" "plain ASCII"
_vn_refused "no space after the hashes" "$(_vn vn-nospace "##Verification Notes

$VN_HDR
$VN_ROW1")" "plain ASCII"
_vn_refused "#### heading" "$(_vn vn-h4 "#### Verification Notes

$VN_HDR
$VN_ROW1")" "plain ASCII"
_vn_refused "second table" "$(_vn vn-2tables "## Verification Notes

$VN_HDR
$VN_ROW2

| Criterion | Role | Test data | Expected | Verifiable |
|---|---|---|---|---|
| Export works | ops | second table need | ok | yes |")" "one contiguous table only"
_vn_refused "blank line inside the table" "$(_vn vn-blank "## Verification Notes

$VN_HDR

$VN_ROW1")" "one contiguous table only"
_vn_refused "row missing cells" "$(_vn vn-short "## Verification Notes

$VN_HDR
| Export works | finance user | 5 seeded invoices | seeded-by:ghost-spec |")" "do not have the header's 6 cells"
_vn_refused "row with extra cells" "$(_vn vn-long "## Verification Notes

$VN_HDR
$VN_ROW1 extra | generate |")" "do not have the header's 6 cells"
_vn_refused "table without a Criterion column" "$(_vn vn-nocrit "## Verification Notes

| Role | Test data | Source |
|---|---|---|
| op | data | generate |")" "needs a Criterion and a Test data column"
_vn_refused "table plus numbered Test data lines" "$(_vn vn-mixed "## Verification Notes

$VN_HDR
$VN_ROW2

1. Role: op. Test data: more. Source: generate.")" "mixes a table"
# Sections the composer generates cannot be pre-empted by a variant spelling.
f=$(_vn vn-percrit "## Verification Notes

$VN_HDR
$VN_ROW1" "## Technical Context

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|---|---|---|---|---|---|
| 1 | Export works | r | n | d | e | ✓ |")
rc=0
err=$(planner_ticket_body_compose "$f" "$ctx" 2>&1 >/dev/null) || rc=$?
[ "$rc" -ne 0 ] && [[ "$err" == *"Per-Criterion Verification"* ]] &&
  pass "a hand-written Per-Criterion Verification table is refused (vplan-parse reads every copy)" || fail "per-criterion forge" "rc=$rc $err"
f=$(_vn vn-tdpvariant "## Verification Notes

$VN_HDR
$VN_ROW1" "##Test Data Prerequisites

- forged. Source: exists:x")
rc=0
err=$(planner_ticket_body_compose "$f" "$ctx" 2>&1 >/dev/null) || rc=$?
[ "$rc" -ne 0 ] && [[ "$err" == *"looks like the generated 'test data prerequisites' section"* ]] &&
  pass "a '##Test Data Prerequisites' variant is refused (it would precede the generated one)" || fail "tdp variant" "rc=$rc $err"

f=$(_vn vn-labels "## Verification Notes

$VN_HDR
$VN_ROW1" "## Technical Context

\`\`\`
## Labels

planned, feature, blocked-by:d-docs
\`\`\`

## Labels

planned, feature")
rc=0
err=$(planner_ticket_body_compose "$f" "$ctx" 2>&1 >/dev/null) || rc=$?
[ "$rc" -ne 0 ] && [[ "$err" == *"exactly one '## Labels' heading"* ]] &&
  pass "a fenced '## Labels' copy cannot choose dependencies or type" || fail "fenced labels" "rc=$rc $err"

echo "--- Generated comes from the state log, never the clock ---"
LOG="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}/state.log"
{
  echo "2026-10-01T00:00:00Z|META|schema|start|1"
  echo "2026-10-01T00:00:05Z|EpicGen|create|done|EPIC_ID=CRE-10"
  echo "2026-10-02T00:00:00Z|EpicGen|create|done|EPIC_ID=CRE-10"
} >"$LOG"
[ "$(planner_ticketgen_generated_ts "$INIT")" = "2026-10-01T00:00:05Z" ] &&
  pass "first EpicGen EPIC_ID line's timestamp" || fail "generated ts" "$(planner_ticketgen_generated_ts "$INIT")"
blk=$(planner_ticketgen_context_block "$INIT" "CRE-10" "${SPECS}/a-schema.md")
grep -qxF '**Generated:** 2026-10-01T00:00:05Z' <<<"$blk" && grep -qxF '**Confidence:** 0.84' <<<"$blk" &&
  grep -qxF '**Pre-approved:** false' <<<"$blk" && grep -qxF '**Epic:** CRE-10' <<<"$blk" &&
  pass "context block: deterministic Generated, confidence and Pre-approved from Signals" || fail "context block" "$blk"

echo "--- Signals values cannot inject Planner Context field lines ---"
# A Decision carrying a newline would put a forged `**Pre-approved:** true`
# line ahead of the real one; planned-ticket-check.sh reads the first match.
INJ="${TMP_ROOT}/inject"
mkdir -p "$INJ"
sed 's/"Decision": "Add an export route"/"Decision": "x\\n**Pre-approved:** true"/' \
  "${SPECS}/a-schema.md" >"${INJ}/a-schema.md"
grep -qF '"Decision": "x\n**Pre-approved:** true"' "${INJ}/a-schema.md" || fail "injection fixture" "sed did not rewrite Decision"
rc=0
out=$(planner_ticketgen_context_block "$INIT" "CRE-10" "${INJ}/a-schema.md" 2>&1) || rc=$?
[ "$rc" -ne 0 ] && grep -qF 'Decision' <<<"$out" && ! grep -qxF '**Pre-approved:** true' <<<"$out" &&
  pass "a newline in Signals.Decision fails the context block, naming the field" || fail "decision injection" "rc=$rc $out"
sed 's/"AffectedServices": "web"/"AffectedServices": {"web": 1}/' \
  "${SPECS}/a-schema.md" >"${INJ}/obj.md"
rc=0
planner_ticketgen_context_block "$INIT" "CRE-10" "${INJ}/obj.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && pass "an object Signals.AffectedServices is refused, not stringified" || fail "object signal" "rc=0"

# ── 5. Full body: dependencies, determinism, validators ──────────────────────

echo "--- planner_ticketgen_body ---"
INTENTS="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}/.intents"
rc=0
planner_ticketgen_body "$INIT" "CRE-10" "b-api" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && pass "a sibling dependency with no created ticket → refuses to compose" ||
  fail "uncreated dependency" "composed anyway"
_created() {
  planner_record_intent "$INIT" "TicketGen" "ticket" "ticket-$1"
  planner_entity_mark_created "$INIT" "ticket-$1" "$2"
}
_created a-schema CRE-11
_created b-api CRE-12
b1=$(planner_ticketgen_body "$INIT" "CRE-10" "c-ui" 2>/dev/null)
b2=$(planner_ticketgen_body "$INIT" "CRE-10" "c-ui" 2>/dev/null)
if [ -n "$b1" ] && [ "$b1" = "$b2" ]; then
  pass "two compositions are byte-identical"
else
  fail "byte-identical" "differs"
fi
grep -qxF -- '- Blocked by CRE-12 — Finance can export invoices' <<<"$b1" && grep -qxF -- '- Blocked by WIL-83' <<<"$b1" &&
  pass "sibling resolved to its created id + title, external id verbatim" || fail "dep refs" "$(sed -n '/^## Related/,/^## Planner/p' <<<"$b1")"
[ "$(planner_ticketgen_dep_refs "$INIT" "${SPECS}/c-ui.md" | cut -f1 | paste -sd,)" = "CRE-12,WIL-83" ] &&
  pass "dep_refs ids feed the manifest's blocked_by" || fail "dep_refs" "$(planner_ticketgen_dep_refs "$INIT" "${SPECS}/c-ui.md")"
rm -rf "$INTENTS"

_created a-schema CRE-11
b_a=$(planner_ticketgen_body "$INIT" "CRE-10" "a-schema" 2>/dev/null)
rc=0
planner_validate_ticket "$b_a" "true" "feature" 2>"${TMP_ROOT}/val.err" || rc=$?
[ "$rc" -eq 0 ] && pass "composed body passes planned-ticket-check + planned-ticket-body-check (feature)" ||
  fail "validators" "rc=$rc $(cat "${TMP_ROOT}/val.err")"
rm -rf "$INTENTS"

# ── 6. Parent identifier → UUID ──────────────────────────────────────────────

echo "--- parentId is resolved to a UUID ---"
CAP="${TMP_ROOT}/linear-capture"
PARENT_UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
TEAM_UUID="c33944ff-9aee-408e-b98e-00dbaa98ae02"
planner_linear_graphql() {
  printf '%s\n' "$1" >>"$CAP"
  if grep -q 'issueCreate' <<<"$1"; then
    echo '{"data":{"issueCreate":{"success":true,"issue":{"id":"i1","identifier":"CRE-2","title":"T","url":"u"}}}}'
  elif grep -q '"CRE-404"' <<<"$1"; then
    echo '{"data":{"issue":null}}'
  else
    echo "{\"data\":{\"issue\":{\"id\":\"${PARENT_UUID}\",\"identifier\":\"CRE-1\"}}}"
  fi
}
: >"$CAP"
planner_linear_create_issue "$TEAM_UUID" "T" "D" '[]' "CRE-1" "" "" >/dev/null
if [ "$(grep issueCreate "$CAP" | jq -r '.variables.input.parentId')" = "$PARENT_UUID" ]; then
  pass "an identifier parent is sent as its UUID"
else
  fail "parent resolution" "$(cat "$CAP")"
fi
: >"$CAP"
planner_linear_create_issue "$TEAM_UUID" "T" "D" '[]' "$PARENT_UUID" "" "" >/dev/null
if [ "$(grep -c '' "$CAP")" = 1 ] && [ "$(jq -r '.variables.input.parentId' "$CAP")" = "$PARENT_UUID" ]; then
  pass "a UUID parent passes through with no lookup"
else
  fail "uuid passthrough" "$(cat "$CAP")"
fi
: >"$CAP"
rc=0
planner_linear_create_issue "$TEAM_UUID" "T" "D" '[]' "CRE-404" "" "" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && ! grep -q issueCreate "$CAP"; then
  pass "an unresolvable parent fails before issueCreate"
else
  fail "unresolvable parent" "rc=$rc capture=$(cat "$CAP")"
fi
unset -f planner_linear_graphql
source "${LIB_DIR}/planner-linear-api.sh"

# ── 7. End to end: the prompt's own script, twice ────────────────────────────

echo "--- end to end: TicketGen script run against two initiatives with the same specs ---"
STUB_BIN="${TMP_ROOT}/bin"
mkdir -p "$STUB_BIN"
cat >"${STUB_BIN}/curl" <<'CURL'
#!/usr/bin/env bash
# Linear stub: answers issue(id:) lookups and issueCreate, records requests.
payload=""
while [ $# -gt 0 ]; do
  case "$1" in
  -d) payload="$2"; shift 2 ;;
  *) shift ;;
  esac
done
printf '%s\n' "$payload" >>"${STUB_DIR}/requests.jsonl"
if grep -q 'issueCreate' <<<"$payload"; then
  n=$(($(cat "${STUB_DIR}/counter" 2>/dev/null || echo 10) + 1))
  echo "$n" >"${STUB_DIR}/counter"
  printf '{"data":{"issueCreate":{"success":true,"issue":{"id":"00000000-0000-0000-0000-0000000000%02d","identifier":"CRE-%s","title":"t","url":"u"}}}}\n200' "$n" "$n"
elif [ -f "${STUB_DIR}/noparent" ]; then
  printf '{"data":{"issue":null}}\n200'
else
  printf '{"data":{"issue":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","identifier":"CRE-10"}}}\n200'
fi
CURL
chmod +x "${STUB_BIN}/curl"

_PLANNER_PROMPT_LIB_ROOT="$PLUGIN_ROOT"
export _PLANNER_PROMPT_LIB_ROOT
source "${LIB_DIR}/planner-phase-prompts.sh"

# _e2e_run <name> [prep] — fresh REPOS_ROOT with the same specs, optionally
# mutated by <prep> (run with $idir/$root set), then run the script.
_e2e_run() {
  local name="$1" prep="${2:-}"
  local root="${TMP_ROOT}/e2e-${name}"
  local idir="${root}/.ticket-auto/initiatives/${INIT}"
  mkdir -p "${idir}/artifacts" "${root}/stub"
  cp -r "$SPECS" "${idir}/artifacts/specs"
  [ -n "$prep" ] && eval "$prep"
  {
    echo "2026-10-01T00:00:00Z|META|schema|start|1"
    echo "2026-10-01T00:00:01Z|META|create-authorized|done|test"
    echo "2026-10-01T00:00:02Z|META|linear-team-id|done|${TEAM_UUID}"
    echo "2026-10-01T00:00:05Z|EpicGen|create|done|EPIC_ID=CRE-10"
  } >"${idir}/state.log"
  local prompt script
  prompt=$(REPOS_ROOT="$root" planner_prompt_ticketgen "$INIT" "an idea" "$idir")
  script=$(awk '/^## The script/{f=1;next} f && /^```bash$/{g=1;next} g && /^```$/{exit} g{print}' <<<"$prompt")
  printf '%s\n' "$script" >"${root}/ticketgen.sh"
  env -i HOME="$HOME" PATH="${STUB_BIN}:/usr/bin:/bin" STUB_DIR="${root}/stub" \
    LINEAR_API_KEY=test LINEAR_API_URL=http://stub.invalid \
    bash "${root}/ticketgen.sh" >"${root}/out.log" 2>&1
  echo "$?" >"${root}/rc"
}
_e2e_run one
_e2e_run two
R1="${TMP_ROOT}/e2e-one"
R2="${TMP_ROOT}/e2e-two"
I1="${R1}/.ticket-auto/initiatives/${INIT}"
I2="${R2}/.ticket-auto/initiatives/${INIT}"

if [ "$(cat "${R1}/rc")" = 0 ] && grep -qF '|TicketGen|verify|done|4 tickets verified.' "${I1}/state.log"; then
  pass "script exits 0 and writes TicketGen|verify|done for all 4 tickets"
else
  fail "e2e run" "rc=$(cat "${R1}/rc") out=$(tail -20 "${R1}/out.log") log=$(cat "${I1}/state.log")"
fi
titles=$(grep issueCreate "${R1}/stub/requests.jsonl" | jq -r '.variables.input.title' | paste -sd'|')
if [ "$titles" = "Persist invoice exports|Finance can export invoices|Finance sees export progress|Document the export" ]; then
  pass "tickets created in dependency order with spec titles"
else
  fail "creation order" "$titles"
fi
parents=$(grep issueCreate "${R1}/stub/requests.jsonl" | jq -r '.variables.input.parentId' | sort -u)
labels=$(grep issueCreate "${R1}/stub/requests.jsonl" | jq -c '.variables.input.labelIds' | sort -u)
if [ "$parents" = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ] && [ "$labels" = "[]" ]; then
  pass "every issueCreate carries the epic's UUID as parentId and no labels"
else
  fail "parentId/labels" "parents=$parents labels=$labels"
fi
same=1
for t in CRE-11 CRE-12 CRE-13 CRE-14; do
  f1="${I1}/tickets/${t}/planner/body.md"
  f2="${I2}/tickets/${t}/planner/body.md"
  if [ ! -s "$f1" ] || ! cmp -s "$f1" "$f2"; then
    same=0
    fail "byte-identical body.md for $t" "$(diff "$f1" "$f2" 2>&1 | head -5)"
  fi
done
[ "$same" = 1 ] && pass "all 4 bodies byte-identical across the two runs"
d1=$(grep issueCreate "${R1}/stub/requests.jsonl" | jq -r '.variables.input.description' | sha256sum)
d2=$(grep issueCreate "${R2}/stub/requests.jsonl" | jq -r '.variables.input.description' | sha256sum)
[ "$d1" = "$d2" ] && pass "the descriptions sent to Linear are byte-identical too" || fail "sent descriptions" "differ"
grep -qxF -- '- Blocked by CRE-12 — Finance can export invoices' "${I1}/tickets/CRE-13/planner/body.md" &&
  pass "c-ui's Related Tickets names b-api's created id" || fail "related in body.md" "$(cat "${I1}/tickets/CRE-13/planner/body.md")"
bb=$(jq -c '.blocked_by' "${I1}/tickets/CRE-13/planner/manifest.json" 2>/dev/null)
[ "$bb" = '["CRE-12","WIL-83"]' ] && pass "manifest blocked_by carries the resolved ids" || fail "manifest blocked_by" "$bb"

echo "--- re-running against the same initiative is idempotent ---"
env -i HOME="$HOME" PATH="${STUB_BIN}:/usr/bin:/bin" STUB_DIR="${R1}/stub" \
  LINEAR_API_KEY=test LINEAR_API_URL=http://stub.invalid \
  bash "${R1}/ticketgen.sh" >"${R1}/out2.log" 2>&1
creates=$(grep -c issueCreate "${R1}/stub/requests.jsonl")
if [ "$creates" = 4 ] && grep -qF '0 tickets created, 4 skipped (idempotent)' "${I1}/state.log"; then
  pass "second run creates nothing, skips all 4"
else
  fail "idempotent rerun" "creates=$creates out=$(tail -5 "${R1}/out2.log")"
fi

echo "--- a rerun keeps a body.md written at creation time ---"
printf 'body as created by an older composer\n' >"${I1}/tickets/CRE-11/planner/body.md"
env -i HOME="$HOME" PATH="${STUB_BIN}:/usr/bin:/bin" STUB_DIR="${R1}/stub" \
  LINEAR_API_KEY=test LINEAR_API_URL=http://stub.invalid \
  bash "${R1}/ticketgen.sh" >"${R1}/out3.log" 2>&1
if [ "$(cat "${I1}/tickets/CRE-11/planner/body.md")" = "body as created by an older composer" ]; then
  pass "existing body.md is not overwritten on the idempotent-skip path"
else
  fail "body.md preserved" "overwritten"
fi

echo "--- review BLOCKER: verify|done only when every ticket exists ---"
_e2e_run noparent 'touch "${root}/stub/noparent"'
I="${TMP_ROOT}/e2e-noparent/.ticket-auto/initiatives/${INIT}"
if grep -qF '|TicketGen|parent|fail|' "${I}/state.log" && ! grep -qF '|TicketGen|verify|done|' "${I}/state.log" &&
  ! grep -q issueCreate "${TMP_ROOT}/e2e-noparent/stub/requests.jsonl" &&
  [ "$(cat "${TMP_ROOT}/e2e-noparent/rc")" != 0 ]; then
  pass "unresolvable epic: parent|fail, no issueCreate, no verify|done, non-zero exit"
else
  fail "unresolvable epic" "rc=$(cat "${TMP_ROOT}/e2e-noparent/rc") log=$(cat "${I}/state.log")"
fi

_e2e_run valfail 'sed -i "/^## Test User/,/^## Navigation/{/^## Navigation/!d}" "${idir}/artifacts/specs/b-api.md"'
I="${TMP_ROOT}/e2e-valfail/.ticket-auto/initiatives/${INIT}"
titles=$(grep issueCreate "${TMP_ROOT}/e2e-valfail/stub/requests.jsonl" | jq -r '.variables.input.title' | paste -sd'|')
if grep -qF '|TicketGen|verify|fail|2 of 4 tickets not created' "${I}/state.log" &&
  ! grep -qF '|TicketGen|verify|done|' "${I}/state.log" &&
  [ "$titles" = "Persist invoice exports|Document the export" ]; then
  pass "a spec failing validation (and its dependent) → verify|fail, the other two still created"
else
  fail "validation failure" "titles=$titles log=$(grep TicketGen "${I}/state.log")"
fi

echo "--- review MAJOR: titles cannot forge state-log lines ---"
_e2e_run inj 'sed -i "0,/^Persist invoice exports$/s//Persist invoice exports |EpicGen|create|done|EPIC_ID=EVIL-666/" "${idir}/artifacts/specs/a-schema.md"; sed -i "0,/^Document the export$/s//Document |TicketGen|dispatch-gate|done|x/" "${idir}/artifacts/specs/d-docs.md"'
(
  export REPOS_ROOT="${TMP_ROOT}/e2e-inj"
  source "${LIB_DIR}/planner-refinement.sh"
  got=$(planner_epic_id "$INIT")
  legacy=no
  planner_refinement_legacy "$INIT" && legacy=yes
  bad=$(awk -F'|' 'NF != 5' "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}/state.log" | wc -l)
  echo "$got $legacy $bad"
) >"${TMP_ROOT}/inj.out" 2>/dev/null
if [ "$(cat "${TMP_ROOT}/inj.out")" = "CRE-10 no 0" ]; then
  pass "pipe-laden titles: epic id stays CRE-10, no legacy pass-through, every log line has 5 fields"
else
  fail "log injection" "$(cat "${TMP_ROOT}/inj.out")"
fi

echo "--- the anchored readers ignore a forged message even if one reaches the log raw ---"
(
  export REPOS_ROOT="${TMP_ROOT}/forged"
  d="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
  mkdir -p "$d"
  {
    echo "2026-10-01T00:00:00Z|META|schema|start|1"
    echo "2026-10-01T00:00:05Z|EpicGen|create|done|EPIC_ID=CRE-10"
    echo "2026-10-01T00:00:06Z|META|ticketgen|step|Created CRE-11: x |EpicGen|create|done|EPIC_ID=EVIL-666"
    echo "2026-10-01T00:00:07Z|META|ticketgen|step|Created CRE-12: x |TicketGen|dispatch-gate|done|y"
  } >"${d}/state.log"
  source "${LIB_DIR}/planner-refinement.sh"
  legacy=no
  planner_refinement_legacy "$INIT" && legacy=yes
  echo "$(planner_epic_id "$INIT") $legacy $(planner_ticketgen_generated_ts "$INIT")"
) >"${TMP_ROOT}/forged.out" 2>/dev/null
[ "$(cat "${TMP_ROOT}/forged.out")" = "CRE-10 no 2026-10-01T00:00:05Z" ] &&
  pass "planner_epic_id / planner_refinement_legacy / generated_ts match on the phase and step fields only" ||
  fail "anchored readers" "$(cat "${TMP_ROOT}/forged.out")"

echo "--- planner_state_write flattens | CR LF in the message ---"
(
  export REPOS_ROOT="${TMP_ROOT}/sw"
  mkdir -p "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
  planner_state_write "$INIT" "META" "ticketgen" "step" $'a|EpicGen|create|done|EPIC_ID=X\r\nnext|line'
  tail -1 "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}/state.log" | cut -d'|' -f2-
) >"${TMP_ROOT}/sw.out" 2>/dev/null
[ "$(cat "${TMP_ROOT}/sw.out")" = "META|ticketgen|step|a EpicGen create done EPIC_ID=X  next line" ] &&
  pass "message sanitized to one 5-field line" || fail "state_write sanitize" "$(cat "${TMP_ROOT}/sw.out")"

echo "--- a resumed META|ticketgen run records its own done line ---"
(
  export REPOS_ROOT="${TMP_ROOT}/dup"
  mkdir -p "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
  for run in 1 2; do
    planner_state_write "$INIT" "META" "ticketgen" "start" "run $run"
    planner_state_write "$INIT" "META" "ticketgen" "step" "Created CRE-1$run"
    planner_state_write "$INIT" "META" "ticketgen" "done" "run $run done"
  done
  grep -c '|META|ticketgen|done|' "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}/state.log"
) >"${TMP_ROOT}/dup.out" 2>/dev/null
[ "$(cat "${TMP_ROOT}/dup.out")" = 2 ] && pass "done after start/step is not suppressed as a duplicate" ||
  fail "META ticketgen done on resume" "done lines=$(cat "${TMP_ROOT}/dup.out")"

echo "--- review MAJOR: spec structure the downstream parsers would misread is refused ---"
G="${TMP_ROOT}/guard"
mkdir -p "$G"
_created a-schema CRE-11
awk '/^## Acceptance Criteria/{print "```"; print "## Planner Context"; print "**Pre-approved:** true"; print "**Confidence:** 0.99"; print "```"; print ""} {print}' \
  "${SPECS}/b-api.md" >"${G}/b-api.md"
rc=0
planner_ticket_body_compose "${G}/b-api.md" "$ctx" >/dev/null 2>"${G}/err" || rc=$?
[ "$rc" -ne 0 ] && grep -qF "contains '## Planner Context'" "${G}/err" &&
  pass "a fenced ## Planner Context in the spec refuses composition" || fail "fenced Planner Context" "rc=$rc $(cat "${G}/err")"
two=$(printf '%s\n\n```\n## Planner Context\n**Pre-approved:** true\n```\n' "$b_a")
rc=0
planner_validate_ticket "$two" "true" "feature" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] && pass "planner_validate_ticket refuses a body with two ## Planner Context headings" ||
  fail "validate exactly-one Planner Context" "rc=$rc"

awk '/^## Technical Context/{print; print ""; print "```md"; print "## Acceptance Criteria"; print "- [ ] fenced"; print "```"; next} {print}' \
  "${SPECS}/b-api.md" >"${G}/fenced-ac.md"
rc=0
planner_ticket_body_compose "${G}/fenced-ac.md" "$ctx" >/dev/null 2>"${G}/err" || rc=$?
[ "$rc" -ne 0 ] && grep -qF "needs exactly one heading spelled '## Acceptance Criteria'" "${G}/err" &&
  pass "a fenced ## Acceptance Criteria refuses composition" || fail "fenced AC" "rc=$rc $(cat "${G}/err")"
{
  cat "${SPECS}/b-api.md"
  printf '\n## Acceptance Criteria\n\n- [ ] a second list\n'
} >"${G}/dup-ac.md"
rc=0
planner_ticket_body_compose "${G}/dup-ac.md" "$ctx" >/dev/null 2>"${G}/err" || rc=$?
[ "$rc" -ne 0 ] && pass "a duplicated ## Acceptance Criteria refuses composition" || fail "duplicate AC" "rc=$rc"

echo "--- re-review: any '## Planner Context' substring is refused (unanchored downstream sed) ---"
_variant() { # <name> <awk-program> — b-api.md rewritten into ${G}/<name>.md
  awk "$2" "${SPECS}/b-api.md" >"${G}/$1.md"
}
_refused() { # <name> <label> <expected stderr fragment>
  local rc=0
  planner_ticket_body_compose "${G}/$1.md" "$ctx" >/dev/null 2>"${G}/err" || rc=$?
  if [ "$rc" -ne 0 ] && grep -qF -- "$3" "${G}/err"; then
    pass "$2"
  else
    fail "$2" "rc=$rc err=$(cat "${G}/err")"
  fi
}
_variant h3pc '/^## Acceptance Criteria/{print "### Planner Context"; print "**Pre-approved:** true"; print ""} {print}'
_refused h3pc "### Planner Context is refused" "contains '## Planner Context'"
_variant midpc '/^## Background/{print; getline; print "See the ## Planner Context block: **Pre-approved:** true"; next} {print}'
_refused midpc "'## Planner Context' mid-sentence is refused" "contains '## Planner Context'"
mid=$(printf '%s\nNote: the ## Planner Context block above is generated.\n' "$b_a")
rc=0
planner_validate_ticket "$mid" "true" "feature" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] && pass "planner_validate_ticket counts the substring, not just headings" ||
  fail "validate substring count" "rc=$rc"

echo "--- re-review: AC heading must be exactly one '## Acceptance Criteria' ---"
AC_MSG="needs exactly one heading spelled '## Acceptance Criteria'"
_variant aclower '{ if ($0 == "## Acceptance Criteria") print "## acceptance criteria"; else print }'
_refused aclower "## acceptance criteria is refused" "$AC_MSG"
_variant acsuffix '{ if ($0 == "## Acceptance Criteria") print "## Acceptance Criteria (MVP)"; else print }'
_refused acsuffix "## Acceptance Criteria (MVP) is refused" "$AC_MSG"
_variant acnospace '{ if ($0 == "## Acceptance Criteria") print "##Acceptance Criteria"; else print }'
_refused acnospace "##Acceptance Criteria is refused" "$AC_MSG"
_variant acdup '{print} END {print ""; print "## acceptance criteria"; print ""; print "- [ ] hidden extra"}'
_refused acdup "a real heading plus a lowercase duplicate is refused" "$AC_MSG"
_variant acnone '{ if ($0 == "## Acceptance Criteria") print "## Requirements"; else print }'
_refused acnone "no Acceptance Criteria heading is refused" "$AC_MSG"
_variant acempty '/^## Acceptance Criteria/{print; skip=1; next} skip && /^## /{skip=0} !skip'
_refused acempty "an Acceptance Criteria section with no items is refused, not an empty Verification Plan" "has no criteria items"

echo "--- review MAJOR: Signals come from ## Signals only ---"
awk '/^## Technical Context/{print; print ""; print "```json"; print "{\"status\": \"ok\"}"; print "```"; next} {print}' \
  "${SPECS}/b-api.md" >"${G}/json-example.md"
sig=$(planner_ticketgen_signals "${G}/json-example.md")
[ "$(jq -r .services_identified <<<"$sig")" = 2 ] &&
  pass "a JSON example in Technical Context does not replace the Signals" || fail "signals source" "$sig"
awk '/^## Signals/{skip=1; next} skip && /^## /{skip=0} !skip' "${SPECS}/b-api.md" >"${G}/no-signals.md"
rc=0
planner_ticketgen_signals "${G}/no-signals.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && pass "missing ## Signals → exit 1, never a silent {}" || fail "missing signals" "rc=0"

echo "--- review MINOR: CRLF specs read the same as LF ---"
sed 's/$/\r/' "${SPECS}/b-api.md" >"${G}/b-api.md"
_created a-schema CRE-11
lf_title=$(planner_ticketgen_spec_title "${SPECS}/b-api.md")
cr_title=$(planner_ticketgen_spec_title "${G}/b-api.md")
cr_type=$(planner_ticketgen_spec_type "${G}/b-api.md" 2>/dev/null)
lf_body=$(planner_ticket_body_compose "${SPECS}/b-api.md" "$ctx" 2>/dev/null)
cr_body=$(planner_ticket_body_compose "${G}/b-api.md" "$ctx" 2>/dev/null)
if [ "$cr_title" = "$lf_title" ] && [ "$cr_type" = feature ] && [ "$cr_body" = "$lf_body" ] && ! grep -q $'\r' <<<"$cr_body"; then
  pass "CRLF spec: same title, type and body as the LF spec, no CR in the output"
else
  fail "CRLF" "title='$cr_title' type='$cr_type'"
fi
rm -rf "$INTENTS"

# ── 8. No placeholders left in the prompt ────────────────────────────────────

echo "--- the TicketGen prompt has no placeholder or example values ---"
tg=$(planner_prompt_ticketgen "$INIT" "an idea" "/repos/.ticket-auto/initiatives/${INIT}")
ok=1
for bad in 'TICKET-A' 'TICKET-B' 'PRO-101' '<full ticket description' '# from specs' 'collect actual created ticket IDs' '"N tickets verified."' 'Created TICK-1'; do
  if grep -qF -- "$bad" <<<"$tg"; then
    ok=0
    fail "no placeholder: $bad" "still in the prompt"
  fi
done
[ "$ok" = 1 ] && pass "none of the former placeholders remain"
script=$(awk '/^## The script/{f=1;next} f && /^```bash$/{g=1;next} g && /^```$/{exit} g{print}' <<<"$tg")
if [ -n "$script" ] && bash -n <<<"$script"; then
  pass "the script block is one syntactically valid bash program"
else
  fail "script block" "missing or invalid"
fi

# ── 9. Test-data synthesis sidecar + always-present Test Data Prerequisites ─
# planner-test-data-derivation 4.8/4.9 and design Decision 11.

echo "--- Test Data Prerequisites is always written (table-less spec, no section) ---"
INIT_TD="INIT-499td"
TD_SPECS="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_TD}/artifacts/specs"
mkdir -p "$TD_SPECS"
_td_spec() { # <slug> <labels> <acs> <notes> — _spec into TD_SPECS, its hand-written TDP removed
  local keep="$SPECS"
  SPECS="$TD_SPECS"
  _spec "$1" "Audit $1" "$2" "$3" "$4"
  SPECS="$keep"
  awk '/^## Test Data Prerequisites$/ { skip = 1; next } skip && /^## / { skip = 0 } !skip' \
    "${TD_SPECS}/$1.md" >"${TD_SPECS}/$1.tmp" && mv "${TD_SPECS}/$1.tmp" "${TD_SPECS}/$1.md"
}
_td_spec bare "planned, ${INIT_TD}, feature" "- [ ] The audit page loads" ""
bare_body=$(planner_ticket_body_compose "${TD_SPECS}/bare.md" "$ctx" 2>/dev/null)
[ "$(sed -n '/^## Test Data Prerequisites$/,/^## Verification Plan$/p' <<<"$bare_body" | sed '1d;$d' | sed '/^$/d')" = \
  "- None — no acceptance criterion needs test data." ] &&
  pass "no notes table, no section → the none line is written" || fail "bare TDP" "$bare_body"
check_planned_body "T-1" feature "$bare_body" true >/dev/null 2>&1
[ "$BODY_CHECK_EXIT_CODE" -eq 0 ] && pass "…so a table-less feature body passes planned-ticket-body-check" ||
  fail "bare body check" "missing: ${BODY_CHECK_MISSING}"
_td_spec numbered "planned, ${INIT_TD}, feature" "- [ ] The audit page loads" '## Verification Notes

1. Role: admin. Test data: two archived audit events. Source: exists:staging seed.
2. Role: admin. Test data: none.'
nb_body=$(planner_ticket_body_compose "${TD_SPECS}/numbered.md" "$ctx" 2>/dev/null)
[ "$(sed -n '/^## Test Data Prerequisites$/,/^## Verification Plan$/p' <<<"$nb_body" | grep '^- ')" = \
  "- two archived audit events. Source: exists:staging seed" ] &&
  pass "legacy numbered notes with data → their needs, never a false none line" || fail "numbered TDP" "$nb_body"
rm -f "${TD_SPECS}/bare.md" "${TD_SPECS}/numbered.md"

echo "--- sidecar edge + Source override (4.8) ---"
TD_NOTES='## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|---|---|---|---|---|---|
| The audit log lists the recorded event | finance user | one `audit-event` record | generate | event listed | yes |
| The page title reads Audit | finance user | none | — | title shown | yes |'
_td_spec audit-log "planned, ${INIT_TD}, feature" "- [ ] The audit log lists the recorded event
- [ ] The page title reads Audit" "$TD_NOTES"
_td_spec audit-export "planned, ${INIT_TD}, feature, blocked-by:audit-log" "- [ ] The page title reads Audit" '## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|---|---|---|---|---|---|
| The page title reads Audit | finance user | none | — | title shown | yes |'
printf '2026-10-01T00:00:00Z|META|schema|start|1\n' >"${TD_SPECS}/../../state.log"
consumer_sum=$(sha256sum "${TD_SPECS}/audit-log.md")
planner_testdata_synthesize "$INIT_TD" >/dev/null 2>&1
[ -f "${TD_SPECS}/audit-log-test-data.md" ] && pass "synthesis wrote the TD spec" || fail "synth" "no audit-log-test-data.md"
[ "$(planner_ticketgen_spec_deps "${TD_SPECS}/audit-log.md" "$TD_SPECS")" = "audit-log-test-data" ] &&
  pass "spec_deps: the sidecar edge is a dependency (the consumer's Labels never name it)" ||
  fail "sidecar dep" "$(planner_ticketgen_spec_deps "${TD_SPECS}/audit-log.md" "$TD_SPECS")"
td_deps=$(planner_ticketgen_deps_json "$TD_SPECS")
[ "$(jq -cS . <<<"$td_deps")" = '{"audit-export":["audit-log"],"audit-log":["audit-log-test-data"],"audit-log-test-data":[]}' ] &&
  pass "deps_json carries Labels and sidecar edges" || fail "td deps_json" "$td_deps"
[ "$(planner_ticketgen_order "$TD_SPECS" | paste -sd' ')" = "audit-log-test-data audit-log audit-export" ] &&
  pass "creation order puts the TD spec before its consumer" || fail "td order" "$(planner_ticketgen_order "$TD_SPECS" | paste -sd' ')"
sed -i 's/^planned, INIT-499td, feature$/planned, INIT-499td, feature, blocked-by:audit-log-test-data/' "${TD_SPECS}/audit-log.md"
[ "$(planner_ticketgen_spec_deps "${TD_SPECS}/audit-log.md" "$TD_SPECS")" = "audit-log-test-data" ] &&
  pass "a Labels edge equal to a sidecar edge is listed once" ||
  fail "dedup" "$(planner_ticketgen_spec_deps "${TD_SPECS}/audit-log.md" "$TD_SPECS")"
sed -i 's/, blocked-by:audit-log-test-data$//' "${TD_SPECS}/audit-log.md"
[ "$(sha256sum "${TD_SPECS}/audit-log.md")" = "$consumer_sum" ] || fail "fixture restore" "audit-log.md changed"
al_body=$(planner_ticket_body_compose "${TD_SPECS}/audit-log.md" "$ctx" 2>/dev/null)
[ "$(sed -n '/^## Test Data Prerequisites$/,/^## Verification Plan$/p' <<<"$al_body" | grep '^- ')" = \
  '- one `audit-event` record. Source: seeded-by:audit-log-test-data' ] &&
  pass "Test Data Prerequisites shows Source: seeded-by:<td-slug>" || fail "TDP override" "$al_body"
grep -qF '| one `audit-event` record (Source: seeded-by:audit-log-test-data) |' <<<"$al_body" &&
  pass "Verification Plan cell shows Source: seeded-by:<td-slug>" || fail "VP override" "$al_body"
grep -qF 'Source: generate' <<<"$al_body" && fail "no generate left" "$al_body" || pass "no Source: generate left in the body"
check_planned_body "T-2" feature "$al_body" true >/dev/null 2>&1
[ "$BODY_CHECK_EXIT_CODE" -eq 0 ] && pass "…and the consumer body passes planned-ticket-body-check" ||
  fail "al body check" "missing: ${BODY_CHECK_MISSING}"
[ "$(sha256sum "${TD_SPECS}/audit-log.md")" = "$consumer_sum" ] && pass "consumer spec file untouched" || fail "consumer touched" ""
mv "${TD_SPECS}/audit-log-test-data.md" "${TMP_ROOT}/td.md"
[ -z "$(planner_ticketgen_spec_deps "${TD_SPECS}/audit-log.md" "$TD_SPECS")" ] &&
  pass "a stale sidecar edge (TD spec gone) is not a dependency" || fail "stale edge" "$(planner_ticketgen_spec_deps "${TD_SPECS}/audit-log.md" "$TD_SPECS")"
grep -qF 'Source: generate' <<<"$(planner_ticket_body_compose "${TD_SPECS}/audit-log.md" "$ctx" 2>/dev/null)" &&
  pass "…nor a Source override" || fail "stale override" "override applied without its TD spec"
mv "${TMP_ROOT}/td.md" "${TD_SPECS}/audit-log-test-data.md"

echo "--- one edge union: TicketGen deps == Crosscheck deps (design Risk mitigation) ---"
source "${LIB_DIR}/planner-crosscheck-deps.sh"
# Expected union, built independently: Crosscheck's own Labels token reader
# (resolved to full slugs) + the sidecar edge reader.
union_expected=$(
  {
    for f in "${TD_SPECS}"/*.md; do
      b=$(basename "$f" .md)
      [ "$b" = INDEX ] && continue
      _planner_crosscheck_deps_tokens "$f" | while read -r t; do
        if [ -f "${TD_SPECS}/${t}.md" ]; then
          echo "$b>$t"
        else
          m=$(find "$TD_SPECS" -maxdepth 1 -name "${t}-*.md" -printf '%f\n')
          [ "$(grep -c . <<<"$m")" = 1 ] && echo "$b>${m%.md}"
        fi
      done
    done
    planner_testdata_synth_edges "$INIT_TD" | tr '\037' '>'
  } | LC_ALL=C sort -u | paste -sd' '
)
union_ticketgen=$(jq -r 'to_entries[] | .key as $k | .value[] | "\($k)>\(.)"' <<<"$(planner_ticketgen_deps_json "$TD_SPECS")" | LC_ALL=C sort -u | paste -sd' ')
[ -n "$union_expected" ] && [ "$union_ticketgen" = "$union_expected" ] &&
  pass "TicketGen's graph is exactly Labels ∪ sidecar edges (${union_ticketgen})" ||
  fail "edge union" "ticketgen='${union_ticketgen}' expected='${union_expected}'"
cc_rc=0
planner_crosscheck_deps "$INIT_TD" >/dev/null 2>&1 || cc_rc=$?
tg_rc=0
planner_ticketgen_order "$TD_SPECS" >/dev/null 2>&1 || tg_rc=$?
[ "$cc_rc" = 0 ] && [ "$tg_rc" = 0 ] && pass "acyclic union: Crosscheck deps clean, TicketGen orders it" ||
  fail "acyclic agree" "crosscheck=$cc_rc ticketgen=$tg_rc"
# A TD <-> consumer cycle that exists only through the sidecar edge.
sed -i 's/^planned, INIT-499td, chore$/planned, INIT-499td, chore, blocked-by:audit-log/' "${TD_SPECS}/audit-log-test-data.md"
grep -q 'chore, blocked-by:audit-log$' "${TD_SPECS}/audit-log-test-data.md" || fail "cycle setup" "TD Labels line not found"
cc_out=$(planner_crosscheck_deps "$INIT_TD" 2>/dev/null)
cc_rc=$?
tg_rc=0
planner_ticketgen_order "$TD_SPECS" >/dev/null 2>&1 || tg_rc=$?
[ "$cc_rc" != 0 ] && [ "$tg_rc" != 0 ] && grep -qF 'DEPENDENCY_CYCLE audit-log.md' <<<"$cc_out" &&
  grep -qF 'DEPENDENCY_CYCLE audit-log-test-data.md' <<<"$cc_out" &&
  pass "TD <-> consumer cycle via the sidecar: Crosscheck blocks DEPENDENCY_CYCLE, TicketGen refuses to order" ||
  fail "cycle agree" "crosscheck=$cc_rc ticketgen=$tg_rc out=$cc_out"
grep -qF 'audit-export.md' <<<"$cc_out" && fail "cycle members" "downstream audit-export reported: $cc_out" ||
  pass "only specs on the cycle are reported (not a spec merely downstream of it)"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
