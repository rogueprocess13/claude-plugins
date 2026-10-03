#!/usr/bin/env bash
# test-planner-business-framing.sh — Tests for planner-business-framing.
#
# Covers:
#   1. Golden ticket bodies in the business-first layout (Summary → Outcome|
#      Enables → template why/outcome headings → Technical Context → contract
#      sections) pass every existing deterministic gate unchanged: DoR
#      check_ticket_ready, planner_validate_ticket (Planner Context +
#      check_planned_body) and vplan-parse. A negative control proves why the
#      template why/outcome headings must stay (design D1: INTENT_MISSING).
#   2. planner_context_generate's optional Kind/Serves/Enables fields.
#   3. Specify / EpicGen / TicketGen prompt text carries the business-framing
#      rules (prompt-grep, same approach as test-planner-body-template-
#      humanizer.sh — whether an agent follows the prompt is not testable).
#   4. Signals extraction + planner_confidence_derive tolerate the new keys.
#
# Usage: bash ticket-planner/lib/tests/test-planner-business-framing.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
TAP_LIB_DIR="$(cd "${LIB_DIR}/../../ticket-auto-pipeline/lib" && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures/business-framing"

source "${TAP_LIB_DIR}/notes-parse.sh"
source "${TAP_LIB_DIR}/dor-check.sh"
source "${TAP_LIB_DIR}/vplan-parse.sh"
source "${TAP_LIB_DIR}/planned-ticket-check.sh"
source "${LIB_DIR}/planner-ticket-validate.sh"
source "${LIB_DIR}/planner-context-gen.sh"
source "${LIB_DIR}/planner-phase-prompts.sh"

# Hermetic: a developer's untracked config/test-users.json would otherwise
# resolve here but not in CI.
resolve_test_user_catalog() { return 1; }

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

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

echo "=== planner business-framing tests ==="

# ── 1. Golden bodies pass the existing gates ────────────────────────────────

echo "--- golden bodies pass DoR, body-section and Verification Plan gates ---"
for entry in business-lock-period:feature business-classified-reports:feature enabler-bom-java17:chore; do
  name="${entry%%:*}"
  type="${entry##*:}"
  file="${FIXTURES_DIR}/${name}.md"
  body=$(cat "$file")

  rc=0
  check_ticket_ready "BF-${name}" --body "$file" --type "$type" --no-fetch || rc=$?
  if [ "$rc" = "0" ] && [ "$DOR_STATUS" = "ready" ] && [ "$DOR_MISSING" = "[]" ]; then
    pass "${name}: check_ticket_ready ready, no hard codes"
  else
    fail "${name}: check_ticket_ready" "rc=$rc status=$DOR_STATUS missing=$DOR_MISSING"
  fi

  rc=0
  planner_validate_ticket "$body" true "$type" 2>/dev/null || rc=$?
  if [ "$rc" = "0" ]; then
    pass "${name}: planner_validate_ticket (Planner Context + body sections)"
  else
    fail "${name}: planner_validate_ticket" "rc=$rc"
  fi

  if vplan_parse "$body" && [ "${VPLAN_ROWS:-0}" -gt 0 ] && [ "${VPLAN_VERIFIABLE:-0}" -gt 0 ]; then
    pass "${name}: Verification Plan parses (${VPLAN_ROWS} rows)"
  else
    fail "${name}: Verification Plan parses" "rows=${VPLAN_ROWS:-0} verifiable=${VPLAN_VERIFIABLE:-0}"
  fi
done

echo "--- golden bodies carry the new sections in order ---"
_heading_line() { grep -n -m1 "^## $2\s*$" "$1" | cut -d: -f1; }
for entry in business-lock-period:Outcome:Proposed\ Behaviour business-classified-reports:Outcome:Proposed\ Behaviour enabler-bom-java17:Enables:Proposed\ Changes; do
  IFS=: read -r name framing proposed <<<"$entry"
  file="${FIXTURES_DIR}/${name}.md"
  s=$(_heading_line "$file" "Summary")
  f=$(_heading_line "$file" "$framing")
  w=$(_heading_line "$file" "Background / Motivation")
  p=$(_heading_line "$file" "$proposed")
  t=$(_heading_line "$file" "Technical Context")
  a=$(_heading_line "$file" "Acceptance Criteria")
  if [ -n "$s" ] && [ -n "$f" ] && [ -n "$w" ] && [ -n "$p" ] && [ -n "$t" ] && [ -n "$a" ] &&
    [ "$s" -lt "$f" ] && [ "$f" -lt "$w" ] && [ "$w" -lt "$p" ] && [ "$p" -lt "$t" ] && [ "$t" -lt "$a" ]; then
    pass "${name}: Summary < ${framing} < Background < ${proposed} < Technical Context < AC"
  else
    fail "${name}: section order" "lines s=$s f=$f w=$w p=$p t=$t a=$a"
  fi
done

echo "--- enabler golden body has no fake user story ---"
if grep -qiE 'as a (developer|user|system)' "${FIXTURES_DIR}/enabler-bom-java17.md"; then
  fail "enabler has no 'As a …' narrative" "user-story phrasing found"
else
  pass "enabler has no 'As a …' narrative"
fi

echo "--- negative control: dropping the template why/outcome headings fails INTENT_MISSING (design D1) ---"
stripped="${TMP_ROOT}/stripped.md"
awk '
  /^## (Background \/ Motivation|Proposed Behaviour)[[:space:]]*$/ { skip=1; next }
  /^## / { skip=0 }
  !skip { print }
' "${FIXTURES_DIR}/business-lock-period.md" >"$stripped"
rc=0
check_ticket_ready "BF-STRIPPED" --body "$stripped" --type feature --no-fetch || rc=$?
if [ "$rc" = "1" ] && echo "$DOR_MISSING" | jq -e 'index("INTENT_MISSING") != null' >/dev/null; then
  pass "Summary/Outcome/Technical Context alone does not satisfy INTENT_MISSING"
else
  fail "negative control" "rc=$rc missing=$DOR_MISSING (expected INTENT_MISSING)"
fi

# ── 2. Planner Context optional Kind/Serves/Enables ─────────────────────────

echo "--- planner_context_generate optional business-framing fields ---"
_BASE_CTX='{"Schema-Version":1,"Initiative":"INIT-TEST","Epic":"EPIC-1","Confidence":0.9,"Strategy":"Balanced","Decision":"Do the thing","Affected Services":"web","Target Symbols":"Foo.bar:src/foo.ts:10","Pre-approved":true,"Generated":"2026-10-03T00:00:00Z","Regenerate":false}'

# The pre-change output, written out literally: absent fields must not move
# a single byte of it (spec: planner-context-block "Fields absent").
expected_base='## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-TEST
**Epic:** EPIC-1
**Confidence:** 0.9
**Strategy:** Balanced
**Decision:** Do the thing
**Affected Services:** web
**Target Symbols:** Foo.bar:src/foo.ts:10
**Pre-approved:** true
**Generated:** 2026-10-03T00:00:00Z
**Regenerate:** false'
out=$(planner_context_generate "$_BASE_CTX")
if [ "$out" = "$expected_base" ]; then
  pass "no Kind/Serves/Enables → output byte-identical to the 11-field block"
else
  fail "no Kind/Serves/Enables → unchanged output" "got: $out"
fi

out=$(planner_context_generate "$(jq -c '. + {"Kind":"business","Serves":["O1","O2"],"Enables":[]}' <<<"$_BASE_CTX")")
if grep -qxF '**Kind:** business' <<<"$out" && grep -qxF '**Serves:** O1,O2' <<<"$out" &&
  ! grep -qF '**Enables:**' <<<"$out"; then
  pass "business Kind + Serves array → lines emitted, empty Enables omitted"
else
  fail "business Kind/Serves lines" "got: $out"
fi

out=$(planner_context_generate "$(jq -c '. + {"Kind":"enabler","Serves":"","Enables":"O3"}' <<<"$_BASE_CTX")")
if grep -qxF '**Kind:** enabler' <<<"$out" && grep -qxF '**Enables:** O3' <<<"$out" &&
  ! grep -qF '**Serves:**' <<<"$out"; then
  pass "enabler Kind + Enables string → lines emitted, empty Serves omitted"
else
  fail "enabler Kind/Enables lines" "got: $out"
fi

rc=0
planner_context_generate "$(jq -c '. + {"Kind":"story"}' <<<"$_BASE_CTX")" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "1" ]; then
  pass "invalid Kind 'story' → rc 1"
else
  fail "invalid Kind rejected" "rc=$rc"
fi

block=$(planner_context_generate "$(jq -c '. + {"Kind":"business","Serves":"O1"}' <<<"$_BASE_CTX")")
rc=0
check_planned_ticket "BF-CTX" "$block" "true" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "0" ]; then
  pass "generated block with Kind/Serves passes check_planned_ticket"
else
  fail "check_planned_ticket on block with Kind/Serves" "rc=$rc result=${CHECK_RESULT:-}"
fi

# ── 3. Specify prompt ───────────────────────────────────────────────────────

SPECIFY_PROMPT=$(planner_prompt_specify "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")
CONSENSUS_PROMPT=$(planner_prompt_consensus "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")

# _prompt_has <label> <prompt-text> <fixed-string>...
_prompt_has() {
  local label="$1" text="$2"
  shift 2
  local needle
  for needle in "$@"; do
    if grep -qF -- "$needle" <<<"$text"; then
      pass "${label} mentions '${needle}'"
    else
      fail "${label} mentions '${needle}'" "not found in generated prompt"
    fi
  done
}

echo "--- Specify prompt carries business framing ---"
_prompt_has "Specify" "$SPECIFY_PROMPT" \
  '## Business Outcomes' \
  '/artifacts/intent.md' \
  '**Who:**' '**Need:**' '**Outcome:**' '**Measure:**' \
  'NEEDS_HUMAN_DECISION' \
  'No invented business value' \
  'Problem before solution' \
  '"Kind": "<business|enabler>"' '"Serves":' '"Enables":' \
  'Title rules — business:' 'Title rules — enabler:' \
  '## Technical Context' \
  'Never a' \
  'short initiative name'

echo "--- Specify source priority is intent → appraisal → NEEDS_HUMAN_DECISION ---"
i=$(grep -n -m1 '1. \*\*intent.md\*\*' <<<"$SPECIFY_PROMPT" | cut -d: -f1)
a=$(grep -n -m1 '2. \*\*appraisal.md\*\*' <<<"$SPECIFY_PROMPT" | cut -d: -f1)
n=$(grep -n -m1 'NEEDS_HUMAN_DECISION' <<<"$SPECIFY_PROMPT" | cut -d: -f1)
if [ -n "$i" ] && [ -n "$a" ] && [ -n "$n" ] && [ "$i" -lt "$a" ] && [ "$a" -lt "$n" ]; then
  pass "source priority order"
else
  fail "source priority order" "lines intent=$i appraisal=$a nhd=$n"
fi

echo "--- Specify description layout keeps the template why/outcome headings before Technical Context ---"
o=$(grep -n -m1 '2. `## Outcome`' <<<"$SPECIFY_PROMPT" | cut -d: -f1)
b=$(grep -n -m1 '## Background / Motivation' <<<"$SPECIFY_PROMPT" | cut -d: -f1)
t=$(grep -n -m1 '4. `## Technical Context`' <<<"$SPECIFY_PROMPT" | cut -d: -f1)
if [ -n "$o" ] && [ -n "$b" ] && [ -n "$t" ] && [ "$o" -lt "$b" ] && [ "$b" -lt "$t" ]; then
  pass "Outcome < template headings < Technical Context"
else
  fail "Specify layout order" "lines outcome=$o background=$b technical=$t"
fi

echo "--- the old user-story invitation is gone ---"
if grep -qF 'any user-story narrative if helpful' <<<"$SPECIFY_PROMPT"; then
  fail "user-story invitation removed" "still present"
else
  pass "user-story invitation removed"
fi

echo "--- Consensus preserves Business Outcomes ---"
_prompt_has "Consensus" "$CONSENSUS_PROMPT" 'Carry the `## Business Outcomes` section over intact'

# ── 3b. Signals extraction + confidence tolerate Kind/Serves/Enables ────────

echo "--- Signals with Kind/Serves/Enables keep the same confidence ---"
_signals_spec() {
  printf '## Signals\n\n```json\n%s\n```\n' "$1"
}
base_signals='{"services_identified":2,"symbols_resolved":5,"prior_art_found":true,"complexity":"moderate","exploration_depth":"standard","Strategy":"Balanced","Decision":"d","AffectedServices":"web","TargetSymbols":"a:b.ts:1"}'
ext_signals=$(jq -c '. + {"Kind":"business","Serves":["O1"],"Enables":[]}' <<<"$base_signals")
_signals_spec "$base_signals" >"${TMP_ROOT}/base-spec.md"
_signals_spec "$ext_signals" >"${TMP_ROOT}/ext-spec.md"
# Same extraction pipeline TicketGen's prompt uses.
base_extracted=$(sed -n '/```json/,/```/p' "${TMP_ROOT}/base-spec.md" | sed '1d;$d' | jq -c)
ext_extracted=$(sed -n '/```json/,/```/p' "${TMP_ROOT}/ext-spec.md" | sed '1d;$d' | jq -c)
c_base=$(planner_confidence_derive "$base_extracted")
c_ext=$(planner_confidence_derive "$ext_extracted")
if [ -n "$c_base" ] && [ "$c_base" = "$c_ext" ] && [ "$(jq -r .Kind <<<"$ext_extracted")" = "business" ]; then
  pass "confidence unchanged (${c_base}) and Kind survives extraction"
else
  fail "Signals extraction/confidence" "base=$c_base ext=$c_ext extracted=$ext_extracted"
fi

# ── 4. EpicGen prompt ───────────────────────────────────────────────────────

EPICGEN_PROMPT=$(planner_prompt_epicgen "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")

echo "--- EpicGen prompt carries the epic business representation ---"
_prompt_has "EpicGen" "$EPICGEN_PROMPT" \
  'Epic business representation' \
  '`## Business Outcomes` section is the authoritative business framing' \
  'internal phase identifiers' \
  'Accountants can rely on filed documents as an audit-grade record' \
  'do not invent outcomes'

echo "--- EpicGen body layout headings appear in order ---"
prev=0
ok=true
for h in '## Summary' '## Outcomes' '## Who benefits' '## Child tickets' '## Technical approach'; do
  ln=$(grep -n -m1 -x -F "$h" <<<"$EPICGEN_PROMPT" | cut -d: -f1)
  if [ -z "$ln" ] || [ "$ln" -le "$prev" ]; then
    ok=false
    fail "EpicGen layout order" "'$h' at line '${ln:-missing}' (previous heading at $prev)"
    break
  fi
  prev=$ln
done
[ "$ok" = true ] && pass "Summary < Outcomes < Who benefits < Child tickets < Technical approach"

echo "--- EpicGen humanizer pass covers the title, before creation ---"
h=$(grep -n -m1 'run them through the \*\*humanizer\*\*' <<<"$EPICGEN_PROMPT" | cut -d: -f1)
c=$(grep -n -m1 -F 'planner_linear_create_issue \' <<<"$EPICGEN_PROMPT" | cut -d: -f1)
if grep -qF 'Once $EPIC_TITLE and $EPIC_DESCRIPTION are fully written' <<<"$EPICGEN_PROMPT" &&
  [ -n "$h" ] && [ -n "$c" ] && [ "$h" -lt "$c" ]; then
  pass "humanizer covers \$EPIC_TITLE and precedes the create call"
else
  fail "EpicGen humanizer covers title" "humanizer line=$h create line=$c"
fi

# ── 5. TicketGen prompt ─────────────────────────────────────────────────────

TICKETGEN_PROMPT=$(planner_prompt_ticketgen "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")

echo "--- TicketGen prompt carries both representations ---"
_prompt_has "TicketGen" "$TICKETGEN_PROMPT" \
  'BUSINESS TICKET REPRESENTATION' \
  'ENABLER TICKET REPRESENTATION' \
  '**Serves:** O1' '**Enables:** O1' \
  'no "As a developer…" narrative' \
  'Acceptance Criteria remain the executable contract' \
  'labels and every outcome id'

echo "--- TicketGen layout: Summary < Outcome < template headings < Technical Context < AC ---"
s=$(grep -n -m1 '^1\. `## Summary`' <<<"$TICKETGEN_PROMPT" | cut -d: -f1)
o=$(grep -n -m1 '^2\. `## Outcome`' <<<"$TICKETGEN_PROMPT" | cut -d: -f1)
b=$(grep -n -m1 '^3\. The type template' <<<"$TICKETGEN_PROMPT" | cut -d: -f1)
t=$(grep -n -m1 '^4\. `## Technical Context`' <<<"$TICKETGEN_PROMPT" | cut -d: -f1)
a=$(grep -n -m1 '^5\. `## Acceptance Criteria`' <<<"$TICKETGEN_PROMPT" | cut -d: -f1)
if [ -n "$s" ] && [ -n "$o" ] && [ -n "$b" ] && [ -n "$t" ] && [ -n "$a" ] &&
  [ "$s" -lt "$o" ] && [ "$o" -lt "$b" ] && [ "$b" -lt "$t" ] && [ "$t" -lt "$a" ]; then
  pass "layout order in the contract text"
else
  fail "TicketGen layout order" "lines s=$s o=$o b=$b t=$t a=$a"
fi

echo "--- TicketGen still requires every existing contract heading ---"
_prompt_has "TicketGen" "$TICKETGEN_PROMPT" \
  '## Acceptance Criteria' '## Test User' '## Scope' '## Test Data Prerequisites' \
  '## Navigation Path' '## Steps to Reproduce' '## Verification Plan' '### Per-Criterion Verification' \
  '## Planner Context'

echo "--- TicketGen's rendered context_json passes Kind/Serves/Enables into the Planner Context ---"
# Run the prompt's own jq expression (as the agent would) against real Signals,
# then feed the result to planner_context_generate.
ctx_cmd=$(awk '/^context_json=\$\(jq -nc/{f=1} f{print} f&&/^  }'"'"'\)$/{exit}' <<<"$TICKETGEN_PROMPT")
if [ -z "$ctx_cmd" ]; then
  fail "extract context_json block from TicketGen prompt" "block not found"
else
  signals_json='{"Strategy":"Balanced","Decision":"d","AffectedServices":"web","TargetSymbols":"a:b.ts:1","Kind":"business","Serves":["O1","O2"],"Enables":[]}'
  confidence="0.9"
  pre_approved="true"
  EPIC_ID="EPIC-1"
  context_json=""
  eval "$ctx_cmd"
  block=$(planner_context_generate "$context_json")
  if grep -qxF '**Kind:** business' <<<"$block" && grep -qxF '**Serves:** O1,O2' <<<"$block" &&
    ! grep -qF '**Enables:**' <<<"$block"; then
    pass "business Signals → Kind/Serves lines in the generated block"
  else
    fail "context_json pass-through (business)" "context=$context_json block=$block"
  fi

  signals_json='{"Strategy":"Balanced","Decision":"d","AffectedServices":"web","TargetSymbols":"a:b.ts:1"}'
  eval "$ctx_cmd"
  block=$(planner_context_generate "$context_json")
  if [ "$(grep -c '^\*\*' <<<"$block")" = "11" ]; then
    pass "legacy Signals without Kind → classic 11-field block"
  else
    fail "context_json pass-through (legacy)" "block=$block"
  fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
