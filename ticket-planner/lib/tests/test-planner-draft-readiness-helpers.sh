#!/usr/bin/env bash
# test-planner-draft-readiness-helpers.sh — planner-draft-readiness slice S2a
# (design D2, D4, D13): pure draft helpers, no gate.
#
# Covers:
#   1. planner_ticketgen_context_block's optional timestamp: absent or empty
#      leaves TicketGen's output byte-identical; set, it changes only the
#      `Generated` line.
#   2. Draft dependency refs: sibling → DRAFT-<slug>, external verbatim,
#      dangling refused; no created ticket needed.
#   3. The draft body equals the TicketGen body after the id rewrite, and is
#      byte-stable across runs.
#   4. Cache and file layout: first refresh lists every spec stale, a second
#      lists none; an edited spec lists only itself and loses its result
#      files but keeps lineage and revision history; a removed spec loses its
#      directory; another evaluator re-arms; verdict status validated.
#   5. Token map and rewrite: order, whole-token matching both ways, Linear
#      link unwrapping.
#   6. Equivalence: a Linear-re-rendered body is equivalent to its draft; a
#      body with an edited criterion is not.
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-readiness-helpers.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Hermetic: never resolve an installed plugin cache or skills-lib copy.
export HOME="${TMP_ROOT}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${TMP_ROOT}/repos"

source "${LIB_DIR}/planner-draft-readiness.sh"
# The helpers source ticket-auto-pipeline's DoR libs lazily, inside command
# substitutions; load them here too for _dor_body_hash/DOR_SEMANTIC_EVALUATOR.
_planner_refinement_source_deps || exit 1

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

echo "=== planner draft readiness helpers (S2a) ==="

INIT="INIT-DR1"
IDIR="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
SPECS="${IDIR}/artifacts/specs"
LOG="${IDIR}/state.log"
mkdir -p "$SPECS"

# _spec <slug> <title> <labels-line> <ac-lines>
_spec() {
  local slug="$1" title="$2" labels="$3" acs="$4" ac crit rows=""
  while IFS= read -r ac; do
    crit="${ac#- \[ \] }"
    rows+="| ${crit} | finance user | none | | done | yes |"$'\n'
  done <<<"$acs"
  cat >"${SPECS}/${slug}.md" <<SPEC
# ${slug}

## Title

${title}

## Description

## Summary

${title}, in plain language.

## Outcome

**Serves:** O1

**Outcome:** Invoices can be exported.

## Proposed Behaviour

An Export action on the invoice list.

## Technical Context

- Route \`GET /api/invoices/export\`.

## Acceptance Criteria

${acs}

## Out of Scope

Scheduled exports.

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
  "Strategy": "Balanced",
  "Decision": "Add an export route",
  "AffectedServices": "web",
  "TargetSymbols": "exportInvoices:web/src/invoices.ts:10",
  "Kind": "business",
  "Serves": ["O1"],
  "Enables": []
}
\`\`\`

## Verification Notes

| Criterion | Role | Test data | Navigation path | Expected | Verifiable |
|---|---|---|---|---|---|
${rows}
SPEC
}

_spec "a-schema" "Persist invoice exports" "planned, feature" \
  "- [ ] The Export button appears on the invoice list"
_spec "b-api" "Finance can export invoices" "planned, feature, blocked-by:a" \
  "- [ ] Export responds with 200
- [ ] Export downloads a file named invoices.csv"
_spec "c-ui" "Finance sees export progress" "planned, feature, blocked-by:b-api, blocked-by:WIL-83" \
  "- [ ] Progress shows while exporting"

{
  echo "2026-10-01T00:00:00Z|META|schema|done|1"
  echo "2026-10-01T00:00:01Z|Crosscheck|check|done|clean"
  echo "2026-10-01T00:00:03Z|Crosscheck|check|done|clean again"
} >"$LOG"

# ── 1. optional timestamp leaves TicketGen unchanged ──────────────────────
echo "--- 1. planner_ticketgen_context_block optional timestamp ---"
echo "2026-10-01T00:00:05Z|EpicGen|create|done|EPIC_ID=CRE-10" >>"$LOG"
c3=$(planner_ticketgen_context_block "$INIT" "CRE-10" "${SPECS}/b-api.md")
c4=$(planner_ticketgen_context_block "$INIT" "CRE-10" "${SPECS}/b-api.md" "")
if [ -n "$c3" ] && [ "$c3" = "$c4" ] && printf '%s\n' "$c3" | grep -qxF '**Generated:** 2026-10-01T00:00:05Z'; then
  pass "absent/empty timestamp: byte-identical, Generated from the EpicGen line"
else
  fail "absent timestamp" "c3=$c3"
fi
c5=$(planner_ticketgen_context_block "$INIT" "CRE-10" "${SPECS}/b-api.md" "2026-09-09T09:09:09Z")
if [ "$(diff <(echo "$c3") <(echo "$c5") | grep -c '^[<>]')" = 2 ] &&
  printf '%s\n' "$c5" | grep -qxF '**Generated:** 2026-09-09T09:09:09Z'; then
  pass "explicit timestamp changes only the Generated line"
else
  fail "explicit timestamp" "$(diff <(echo "$c3") <(echo "$c5"))"
fi

# ── 2. draft dependency refs ──────────────────────────────────────────────
echo "--- 2. planner_draft_readiness_dep_refs ---"
refs=$(planner_draft_readiness_dep_refs "$INIT" "${SPECS}/c-ui.md")
expected=$(printf 'DRAFT-b-api\tFinance can export invoices\nWIL-83\t')
if [ "$refs" = "$expected" ]; then
  pass "sibling → DRAFT-<slug> with title, external id verbatim, no ticket needed"
else
  fail "dep refs" "$(printf '%q' "$refs")"
fi
refs=$(planner_draft_readiness_dep_refs "$INIT" "${SPECS}/b-api.md")
[ "$refs" = "$(printf 'DRAFT-a-schema\tPersist invoice exports')" ] &&
  pass "prefix ref resolves to the full slug" || fail "prefix ref" "$refs"
cp "${SPECS}/a-schema.md" "${TMP_ROOT}/dangling.md"
sed -i 's/^planned, feature$/planned, feature, blocked-by:nowhere/' "${TMP_ROOT}/dangling.md"
mkdir -p "${TMP_ROOT}/dspecs" && cp "${TMP_ROOT}/dangling.md" "${TMP_ROOT}/dspecs/x.md"
if ! planner_draft_readiness_dep_refs "$INIT" "${TMP_ROOT}/dspecs/x.md" >/dev/null 2>&1; then
  pass "dangling ref refused"
else
  fail "dangling ref" "accepted"
fi

# ── 3. draft body = TicketGen body after id rewrite ───────────────────────
echo "--- 3. draft body composition ---"
d1=$(planner_draft_readiness_compose "$INIT" "c-ui")
d2=$(planner_draft_readiness_compose "$INIT" "c-ui")
if [ -n "$d1" ] && [ "$d1" = "$d2" ] &&
  printf '%s\n' "$d1" | grep -qxF '**Generated:** 2026-10-01T00:00:03Z' &&
  printf '%s\n' "$d1" | grep -qxF '**Epic:** DRAFT' &&
  printf '%s\n' "$d1" | grep -qxF -- '- Blocked by DRAFT-b-api — Finance can export invoices'; then
  pass "byte-stable; epic DRAFT, latest Crosscheck ts, DRAFT-<slug> related"
else
  fail "draft compose" "$d1"
fi

_mark() {
  planner_record_intent "$INIT" "TicketGen" "ticket" "ticket-$1" >/dev/null
  planner_entity_mark_created "$INIT" "ticket-$1" "$2" >/dev/null
}
_mark a-schema CRE-11
_mark b-api CRE-12
_mark c-ui CRE-13

MAP="${TMP_ROOT}/token-map.tsv"
planner_draft_readiness_token_map "$INIT" >"$MAP"
all_equal=1
for s in a-schema b-api c-ui; do
  planner_ticketgen_body "$INIT" "CRE-10" "$s" >"${TMP_ROOT}/tg-${s}.md" 2>/dev/null || all_equal=0
  planner_draft_readiness_compose "$INIT" "$s" >"${TMP_ROOT}/dr-${s}.md" 2>/dev/null || all_equal=0
  a=$(planner_draft_readiness_equiv_text "$MAP" real <"${TMP_ROOT}/tg-${s}.md")
  b=$(planner_draft_readiness_equiv_text "$MAP" draft <"${TMP_ROOT}/dr-${s}.md")
  [ -n "$a" ] && [ "$a" = "$b" ] || {
    all_equal=0
    diff <(echo "$a") <(echo "$b") | head -10
  }
done
[ "$all_equal" = 1 ] && pass "draft equals TicketGen body after the id rewrite (3 specs)" ||
  fail "draft vs TicketGen" "differ"
# Direct form of the same claim: the TicketGen body, ids rewritten to draft
# tokens, differs from the draft only on the Generated line.
tg_rew=$(planner_draft_readiness_rewrite "$MAP" to-draft <"${TMP_ROOT}/tg-c-ui.md")
ndiff=$(diff <(echo "$tg_rew") "${TMP_ROOT}/dr-c-ui.md" | grep '^[<>]' | grep -vc 'Generated:')
[ "$ndiff" = 0 ] && pass "only the Generated line differs after rewrite" || fail "direct rewrite" "$ndiff lines"

# ── 4. cache and file layout ──────────────────────────────────────────────
echo "--- 4. refresh / cache / layout ---"
ROOT=$(planner_draft_readiness_root "$INIT")
[ "$ROOT" = "${IDIR}/artifacts/draft-readiness" ] && pass "root under artifacts/draft-readiness" || fail "root" "$ROOT"
out1=$(planner_draft_readiness_refresh "$INIT")
if [ "$(printf '%s\n' "$out1" | awk -F'\t' '$3 == "stale"' | wc -l)" = 3 ] &&
  [ -f "${ROOT}/a-schema/body.md" ] && [ -f "${ROOT}/c-ui/body.md" ]; then
  pass "first refresh: every spec stale, body.md written"
else
  fail "first refresh" "$out1"
fi
if [ "$(cat "${ROOT}/c-ui/body.md")" = "$(cat "${TMP_ROOT}/dr-c-ui.md")" ]; then
  pass "body.md holds the composed draft"
else
  fail "body.md" "differs"
fi
h_expected=$(_dor_body_hash "$(cat "${ROOT}/b-api/body.md")")
h_line=$(printf '%s\n' "$out1" | awk -F'\t' '$1 == "b-api" { print $2 }')
[ -n "$h_line" ] && [ "$h_line" = "$h_expected" ] && pass "hash is _dor_body_hash of body.md" ||
  fail "hash" "$h_line vs $h_expected"

if ! planner_draft_readiness_verdict_write "$INIT" a-schema "$h_line" "$DOR_SEMANTIC_EVALUATOR" maybe 2>/dev/null; then
  pass "verdict status outside ready|blocked|unavailable refused"
else
  fail "verdict status" "accepted"
fi

# Simulate an evaluation: result files, lineage, revision history, verdict last.
while IFS=$'\t' read -r s h _; do
  for f in dor-result.json scan-result.txt audit-result.txt semantic.json lineage.json revise.r1.status spec.r0.md; do
    echo x >"${ROOT}/${s}/${f}"
  done
  planner_draft_readiness_verdict_write "$INIT" "$s" "$h" "$DOR_SEMANTIC_EVALUATOR" ready
done <<<"$out1"
v=$(planner_draft_readiness_verdict_read "$INIT" b-api)
[ "$v" = "${h_line} ${DOR_SEMANTIC_EVALUATOR} ready" ] && pass "verdict = <hash> <evaluator> <status>" || fail "verdict" "$v"

out2=$(planner_draft_readiness_refresh "$INIT")
if [ "$(printf '%s\n' "$out2" | awk -F'\t' '$3 == "stale"' | wc -l)" = 0 ] &&
  [ "$(printf '%s\n' "$out2" | awk -F'\t' '$3 == "cached"' | wc -l)" = 3 ]; then
  pass "second refresh on unchanged specs: no spawn listed"
else
  fail "second refresh" "$out2"
fi
[ -f "${ROOT}/a-schema/scan-result.txt" ] && pass "cached spec keeps its result files" || fail "cached results" "deleted"

sed -i 's/^- \[ \] Export responds with 200$/- [ ] Export responds with 200 for a finance user/' "${SPECS}/b-api.md"
sed -i 's/^| Export responds with 200 |/| Export responds with 200 for a finance user |/' "${SPECS}/b-api.md"
out3=$(planner_draft_readiness_refresh "$INIT")
stale=$(printf '%s\n' "$out3" | awk -F'\t' '$3 == "stale" { print $1 }')
[ "$stale" = "b-api" ] && pass "one edited spec lists only itself" || fail "edited spec" "$out3"
gone=1
for f in verdict dor-result.json scan-result.txt audit-result.txt semantic.json; do
  [ -e "${ROOT}/b-api/${f}" ] && gone=0
done
[ "$gone" = 1 ] && pass "hash change deletes the result files" || fail "result files" "$(ls "${ROOT}/b-api")"
[ -f "${ROOT}/b-api/lineage.json" ] && [ -f "${ROOT}/b-api/revise.r1.status" ] && [ -f "${ROOT}/b-api/spec.r0.md" ] &&
  pass "lineage and revision history survive a hash change" || fail "history" "$(ls "${ROOT}/b-api")"
[ -f "${ROOT}/a-schema/verdict" ] && pass "unedited specs keep their verdict" || fail "unedited verdict" "gone"

out4=$(DOR_SEMANTIC_EVALUATOR="dor-semantic-vNEXT" planner_draft_readiness_refresh "$INIT")
[ "$(printf '%s\n' "$out4" | awk -F'\t' '$3 == "stale"' | wc -l)" = 3 ] &&
  pass "another evaluator re-arms every spec" || fail "evaluator change" "$out4"

rm -f "${SPECS}/c-ui.md"
planner_draft_readiness_refresh "$INIT" >/dev/null
[ ! -e "${ROOT}/c-ui" ] && pass "removed spec drops its directory" || fail "removed spec" "still there"

sed -i 's/^## Acceptance Criteria$/## Acceptance criteria (draft)/' "${SPECS}/a-schema.md"
out5=$(planner_draft_readiness_refresh "$INIT" 2>/dev/null)
if printf '%s\n' "$out5" | awk -F'\t' '$1 == "a-schema" && $2 == "" && $3 == "error" { f = 1 } END { exit !f }'; then
  pass "spec the composer refuses is reported as error"
else
  fail "compose error" "$out5"
fi
[ ! -e "${ROOT}/a-schema/verdict" ] && pass "refused spec keeps no verdict" || fail "refused verdict" "kept"

INIT2="INIT-DR2"
mkdir -p "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT2}/artifacts/specs"
_spec_dir_save="$SPECS"
SPECS="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT2}/artifacts/specs"
_spec "solo" "Solo" "planned, feature" "- [ ] It works"
SPECS="$_spec_dir_save"
echo "2026-10-01T00:00:00Z|META|schema|done|1" >"${REPOS_ROOT}/.ticket-auto/initiatives/${INIT2}/state.log"
if ! planner_draft_readiness_compose "$INIT2" solo >/dev/null 2>&1; then
  pass "no Crosscheck|check|done line: compose refuses (never reads the clock)"
else
  fail "no crosscheck" "composed"
fi

# ── 5. token map and rewrite ──────────────────────────────────────────────
echo "--- 5. token map and rewrite ---"
expected=$(printf 'DRAFT-a-schema\tCRE-11\nDRAFT-b-api\tCRE-12\nDRAFT-c-ui\tCRE-13\nDRAFT\tCRE-10')
[ "$(cat "$MAP")" = "$expected" ] && pass "map: draft→real, longest draft token first" ||
  fail "map" "$(cat "$MAP")"
q=$(printf 'Blocked by DRAFT-a-schema under epic DRAFT; see DRAFT-b-api.\n' | planner_draft_readiness_rewrite "$MAP" to-real)
[ "$q" = "Blocked by CRE-11 under epic CRE-10; see CRE-12." ] && pass "to-real rewrites whole tokens" || fail "to-real" "$q"
q=$(printf 'DRAFTING DRAFT-zzz CRE-100 xCRE-11 CRE-11.\n' | planner_draft_readiness_rewrite "$MAP" to-draft)
[ "$q" = "DRAFTING DRAFT-zzz CRE-100 xCRE-11 DRAFT-a-schema." ] && pass "no partial-token matches" || fail "partial" "$q"
q=$(printf 'Blocked by [CRE-12](https://linear.app/acme/issue/CRE-12/finance-can-export) and https://linear.app/acme/issue/CRE-11/persist and https://linear.app/acme/issue/CRE-10\n' |
  planner_draft_readiness_rewrite "$MAP" to-draft)
[ "$q" = "Blocked by DRAFT-b-api and DRAFT-a-schema and DRAFT" ] && pass "to-draft unwraps Linear links" || fail "links" "$q"
if ! planner_draft_readiness_rewrite "$MAP" sideways </dev/null 2>/dev/null; then
  pass "unknown direction refused"
else
  fail "direction" "accepted"
fi
INIT3="INIT-DR3"
mkdir -p "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT3}/artifacts/specs"
echo "2026-10-01T00:00:00Z|META|schema|done|1" >"${REPOS_ROOT}/.ticket-auto/initiatives/${INIT3}/state.log"
m=$(planner_draft_readiness_token_map "$INIT3")
rc=$?
[ "$rc" = 0 ] && [ -z "$m" ] && pass "map before EpicGen is empty" || fail "early map" "rc=$rc $m"

# ── 6. equivalence on a Linear re-rendering ───────────────────────────────
echo "--- 6. equivalence ---"
# Linear's rendering: CRLF, trailing spaces, sibling ids as links, trailing
# blank lines.
sed -e 's/CRE-12 —/[CRE-12](https:\/\/linear.app\/acme\/issue\/CRE-12\/finance-can-export-invoices) —/' \
  -e 's/$/  \r/' "${TMP_ROOT}/tg-c-ui.md" >"${TMP_ROOT}/linear-c-ui.md"
printf '\r\n\r\n' >>"${TMP_ROOT}/linear-c-ui.md"
grep -qF '[CRE-12](https://linear.app' "${TMP_ROOT}/linear-c-ui.md" || fail "fixture" "link not injected"
if [ "$(cat "${TMP_ROOT}/linear-c-ui.md")" != "$(cat "${TMP_ROOT}/tg-c-ui.md")" ] &&
  planner_draft_readiness_equivalent "$MAP" "${TMP_ROOT}/linear-c-ui.md" "${TMP_ROOT}/dr-c-ui.md"; then
  pass "Linear-re-rendered body is equivalent to its draft"
else
  fail "re-rendered equivalence" "not equivalent"
fi
sed 's/^- \[ \] Progress shows while exporting/- [ ] Progress shows while exporting a large file/' \
  "${TMP_ROOT}/linear-c-ui.md" >"${TMP_ROOT}/edited-c-ui.md"
planner_draft_readiness_equivalent "$MAP" "${TMP_ROOT}/edited-c-ui.md" "${TMP_ROOT}/dr-c-ui.md"
rc=$?
[ "$rc" = 1 ] && pass "body with an edited criterion is not equivalent" || fail "edited criterion" "rc=$rc"
planner_draft_readiness_equivalent "$MAP" "${TMP_ROOT}/missing.md" "${TMP_ROOT}/dr-c-ui.md"
rc=$?
[ "$rc" = 2 ] && pass "missing body: cannot tell (rc 2)" || fail "missing body" "rc=$rc"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
