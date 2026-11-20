#!/usr/bin/env bash
# test-planner-body-template.sh — GitHub #773: the ticket-body-v2 additions.
#
# Covers:
#   1. planner_body_verify_mode: the one form the planner writes, and what it
#      refuses.
#   2. The verify mode a spec declares survives planner_ticket_body_compose and
#      is what ticket-auto-pipeline's own classifier (verify_mode_shape,
#      lib/verify-mode.sh) returns for the composed body, for all five shapes.
#      Negative control: the same body without the section is classified from
#      its words.
#   3. The Crosscheck ticket-body family: silent without the ticket-body-v2
#      marker; with it, each code on the spec that breaks its rule and nothing
#      on a spec that follows them; blocking vs warn through
#      planner_crosscheck_run.
#   4. The contract marker is written on the first Specify dispatch.
#   5. The Specify, Consensus and Epic Gen prompts carry the rules, and the
#      Specify self-lint runs the family.
#   6. The new sections are additive for the body's downstream readers: the
#      golden bodies give the same Definition-of-Ready verdict with and
#      without them, and the body-section check still passes.
#   7. ticket-auto-pipeline's templates carry the sections; a template with
#      the field filled in classifies as that shape, and one left unfilled
#      classifies as it did before the field existed.
#
# Usage: bash ticket-planner/lib/tests/test-planner-body-template.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TAP_ROOT="$(cd "${LIB_DIR}/../../ticket-auto-pipeline" && pwd)"
TAP_LIB_DIR="${TAP_ROOT}/lib"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures/business-framing"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="${TMP_ROOT}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${TMP_ROOT}/repos"
mkdir -p "$REPOS_ROOT"

source "${TAP_LIB_DIR}/notes-parse.sh"
source "${TAP_LIB_DIR}/dor-check.sh"
source "${TAP_LIB_DIR}/planned-ticket-check.sh"
source "${TAP_LIB_DIR}/verify-mode.sh"
source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-ticket-validate.sh"
source "${LIB_DIR}/planner-ticket-body.sh"
source "${LIB_DIR}/planner-crosscheck.sh"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-phase-prompts.sh"
set +e

resolve_test_user_catalog() { return 1; }

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
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2', want '$3'"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "missing '$3' in: ${2:0:300}"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "unexpected '$3'"; fi
}

echo "=== planner body template tests (GitHub #773) ==="

# write_spec <file> <shape-line> [<variant>...] — a spec written to the
# ticket-body-v2 rules. Variants remove or break one rule each.
write_spec() {
  local file="$1" mode_line="$2"
  shift 2
  local variants=" $* "
  local type="feature" errors=1 tag_live="[live] " tag_unit="[unit] " scope_seed=1 scope_ro=" (read-only)" merged="returns 201 with the fields \`id\`, \`email\` and \`username\`"
  [[ "$variants" == *" chore "* ]] && type="chore"
  [[ "$variants" == *" no-errors "* ]] && errors=0
  [[ "$variants" == *" untagged "* ]] && tag_live="" && tag_unit=""
  [[ "$variants" == *" scope-missing "* ]] && scope_seed=0
  [[ "$variants" == *" scope-extra "* ]] && scope_ro=""
  [[ "$variants" == *" post-merge "* ]] && merged="is available on \`develop\` once merged"
  {
    cat <<'SPEC'
# users-api

## Title

Visitors can register an account

## Description

## Summary

A visitor can register an account over the users endpoint.

## Outcome

**Serves:** O1

**Who:** Visitor

**Need:** An account to publish under.

**Outcome:** A visitor registers once and can then sign in.

## Background / Motivation

Nobody can publish without an account, and there is no way to make one.

## Proposed Behaviour

`POST /api/users` creates an account from an email, a username and a password.

## Technical Context

- New handler in `backend/src/routes/users.js`, registered in `backend/src/app.js:14`.
- The seeded accounts in `backend/src/seed.js` stay as they are.
- Email comparison follows the `auth.email_normalisation` parameter; the `users.email` column stores the normalised value.
- Runs on Node.js with `express` 5.x.

SPEC
    if [ "$errors" = 1 ]; then
      cat <<'SPEC'
## Errors and Edge Cases

- **Failure:** a storage failure returns 500 with the body `{"errors":{"body":["unexpected error"]}}`.
- **Check order:** 422 for a malformed body before the duplicate check.
- **Empty or malformed input:** an empty body returns 422.
- **Late or concurrent responses:** two registrations with the same email at once: one returns 201, the other 422.
- **Unauthorised viewer:** Not applicable — registration needs no token.

SPEC
    fi
    printf '## Acceptance Criteria\n\n'
    printf -- '- [ ] %sPOST /api/users with a new email %s\n' "$tag_live" "$merged"
    printf -- '- [ ] %sPOST /api/users with an email that differs only in case from a stored one returns 422\n' "$tag_live"
    printf -- '- [ ] %sTwo registrations in the same millisecond get distinct ids\n' "$tag_unit"
    if [[ "$variants" == *" many-criteria "* ]]; then
      local i
      for i in $(seq 1 20); do
        printf -- '- [ ] [live] The response field number %s holds the value the request sent\n' "$i"
      done
    fi
    printf '\n## Scope\n\n| Layer | Service | Area |\n| ----- | ------- | ---- |\n'
    if [ "$scope_seed" = 1 ]; then
      printf '| BE    | api     | `backend/src/routes/users.js`, `backend/src/app.js`, `seed.js`%s |\n' "$scope_ro"
    else
      printf '| BE    | api     | `backend/src/routes/users.js`, `backend/src/app.js` |\n'
    fi
    [[ "$variants" == *" scope-extra "* ]] && printf '| BE    | api     | `backend/src/auth.js` |\n'
    printf '\n## Test User\n\nNone — registration needs no account.\n\n## Navigation Path\n\nn/a — no page.\n\n'
    [ -n "$mode_line" ] && printf '## Verify Mode\n\n%s\n\n' "$mode_line"
    printf '## Labels\n\nplanned, INIT-1, %s\n\n' "$type"
    cat <<'SPEC'
## Signals

```json
{"services_identified": 1, "symbols_resolved": 2, "prior_art_found": true, "Strategy": "Balanced", "Decision": "Add the users route", "AffectedServices": "api", "TargetSymbols": "users (new):backend/src/routes/users.js", "Kind": "business", "Serves": ["O1"]}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| none | any | none | — | | none | no |

## Writes

None.

## Reads

None.

## Preconditions

None.
SPEC
  } >"$file"
}

CTX=$(planner_context_generate '{"Schema-Version":1,"Initiative":"INIT-TEST","Epic":"EPIC-1","Confidence":0.9,"Strategy":"Balanced","Decision":"Add the users route","Affected Services":"api","Target Symbols":"users (new):backend/src/routes/users.js","Pre-approved":true,"Generated":"2026-10-03T00:00:00Z","Regenerate":false}')

# ── 1. planner_body_verify_mode ──────────────────────────────────────────────

echo "--- 1. the verify mode a spec declares ---"
ONE="${TMP_ROOT}/one.md"
vm() {
  write_spec "$ONE" "$1"
  local out rc=0
  out=$(planner_body_verify_mode "$ONE") || rc=$?
  printf '%s/%s' "$out" "$rc"
}
for shape in $PLANNER_VERIFY_MODE_SHAPES; do
  assert_eq "shape ${shape} is read" "$(vm "**Verify mode:** ${shape} — a reason")" "${shape}/0"
done
assert_eq "shape with no reason is read" "$(vm "**Verify mode:** api-only")" "api-only/0"
assert_eq "no section is rc 1" "$(vm "")" "/1"
assert_eq "an unknown shape is rc 2" "$(vm "**Verify mode:** manual — by hand")" "/2"
assert_eq "a prefix of a shape is rc 2" "$(vm "**Verify mode:** api — endpoints")" "/2"
assert_eq "a bare shape line is rc 2" "$(vm "api-only")" "/2"
assert_eq "a placeholder is rc 2" "$(vm "**Verify mode:** {shape} — {one-line reason}")" "/2"
assert_eq "the five shapes are the classifier's own" \
  "$(tr ' ' '\n' <<<"$PLANNER_VERIFY_MODE_SHAPES" | sort | tr '\n' ' ')" \
  "$(grep -oE '\(browser\|[a-z|-]+\)' "${TAP_LIB_DIR}/verify-mode.sh" | head -1 | tr -d '()' | tr '|' '\n' | sort | tr '\n' ' ')"

# ── 2. composed body through ticket-auto's classifier ────────────────────────

echo "--- 2. the composed body classifies as the declared shape ---"
for shape in $PLANNER_VERIFY_MODE_SHAPES; do
  write_spec "$ONE" "**Verify mode:** ${shape} — a reason"
  body=$(planner_ticket_body_compose "$ONE" "$CTX" 2>/dev/null)
  assert_contains "${shape}: the body carries the section" "$body" $'## Verify Mode\n\n**Verify mode:** '"${shape} — a reason"
  assert_eq "${shape}: verify_mode_shape returns it" "$(verify_mode_shape "$body")" "$shape"
done
write_spec "$ONE" "**Verify mode:** api-only — endpoints only"
body=$(planner_ticket_body_compose "$ONE" "$CTX" 2>/dev/null)
assert_contains "the body carries Errors and Edge Cases" "$body" $'## Errors and Edge Cases\n\n- **Failure:**'
assert_eq "api-only runs the live-backend verify path" "$(verify_mode_classify "$body")" "live-backend"
assert_eq "api-only maps to the api-only gate profile" "$(verify_mode_gate_profile "$body" 0 0)" "api-only"
# A body whose words say "page" and "click", declared diff-only: the field
# decides, the words do not.
write_spec "$ONE" "**Verify mode:** diff-only — documentation only"
printf '\n' >>"$ONE"
sed -i 's/^Nobody can publish without an account.*/Click the Register button on the sign-up page to open the form./' "$ONE"
body=$(planner_ticket_body_compose "$ONE" "$CTX" 2>/dev/null)
assert_eq "the declared shape wins over browser words" "$(verify_mode_shape "$body")" "diff-only"
without=$(awk '/^## Verify Mode[[:space:]]*$/ { skip = 1; next } /^## / { skip = 0 } !skip { print }' <<<"$body")
assert_eq "negative control: without the section the words decide" "$(verify_mode_shape "$without")" "browser"

# ── 3. Crosscheck ticket-body family ─────────────────────────────────────────

echo "--- 3. Crosscheck ticket-body family ---"
new_init() {
  INIT="$1"
  planner_state_init "$INIT" "an idea" >/dev/null
  ART="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}/artifacts"
  SPECS="${ART}/specs"
  mkdir -p "$SPECS"
  LOG=$(planner_state_log "$INIT")
}
codes() { grep -oE 'planner-crosscheck-body: [A-Z_]+' <<<"$1" | awk '{print $2}' | sort | tr '\n' ' ' | sed 's/ $//'; }

new_init "INIT-BODY-1"
write_spec "${SPECS}/users-api.md" "" no-errors untagged scope-missing
assert_eq "no marker: silent on a spec that breaks every rule" "$(planner_crosscheck_body "$INIT")" ""
planner_body_contract_mark "$INIT"
planner_body_contract_mark "$INIT"
assert_eq "the marker is written once" "$(grep -c '|META|contract|start|ticket-body-v2$' "$LOG")" "1"

write_spec "${SPECS}/users-api.md" "**Verify mode:** api-only — endpoints only"
out=$(planner_crosscheck_body "$INIT")
rc=$?
assert_eq "a spec that follows the rules is clean" "${out}/${rc}" "/0"

run_variant() { # <mode-line> <variants...> → sorted codes
  local mode="$1"
  shift
  write_spec "${SPECS}/users-api.md" "$mode" "$@"
  codes "$(planner_crosscheck_body "$INIT")"
}
OK_MODE="**Verify mode:** api-only — endpoints only"
assert_eq "no Verify Mode section" "$(run_variant "")" "VERIFY_MODE_INVALID"
assert_eq "a Verify Mode that names no shape" "$(run_variant "**Verify mode:** manual")" "VERIFY_MODE_INVALID"
assert_eq "feature spec without Errors and Edge Cases" "$(run_variant "$OK_MODE" no-errors)" "EDGE_CASES_MISSING"
assert_eq "api-only chore without Errors and Edge Cases" "$(run_variant "$OK_MODE" chore no-errors)" "EDGE_CASES_MISSING"
assert_eq "build-only chore needs no Errors and Edge Cases" "$(run_variant "**Verify mode:** build-only — the build is the check" chore no-errors)" ""
assert_eq "untagged criteria" "$(run_variant "$OK_MODE" untagged)" "AC_UNTAGGED"
assert_eq "more criteria than the soft cap" "$(run_variant "$OK_MODE" many-criteria)" "AC_COUNT_HIGH"
assert_eq "a criterion about the state after merge" "$(run_variant "$OK_MODE" post-merge)" "AC_POST_MERGE_STATE"
assert_eq "a Technical Context file missing from Scope" "$(run_variant "$OK_MODE" scope-missing)" "SCOPE_TC_MISMATCH"
assert_eq "a Scope file Technical Context never names" "$(run_variant "$OK_MODE" scope-extra)" "SCOPE_TC_MISMATCH"

write_spec "${SPECS}/users-api.md" "$OK_MODE" scope-missing
out=$(planner_crosscheck_body "$INIT")
assert_contains "the finding names the missing file" "$out" 'SCOPE_TC_MISMATCH users-api.md named in Technical Context but not in the Scope table: `backend/src/seed.js`'
assert_not_contains "a column, a parameter key and a runtime name are not files" "$out" 'users.email'
assert_not_contains "Node.js is not a file" "$out" 'Node.js'
write_spec "${SPECS}/users-api.md" "$OK_MODE" scope-extra
out=$(planner_crosscheck_body "$INIT")
assert_contains "the finding names the unexplained Scope files" "$out" 'in the Scope table but neither named in Technical Context nor marked (read-only): `backend/src/auth.js`'
assert_not_contains "a path tail matches its full path" "$out" '`seed.js`'
write_spec "${SPECS}/users-api.md" "$OK_MODE" untagged
assert_contains "untagged count" "$(planner_crosscheck_body "$INIT")" "AC_UNTAGGED users-api.md 3 of 3 acceptance criteria"

# Skipped files: INDEX.md and a synth-marked test-data spec.
write_spec "${SPECS}/users-api.md" "$OK_MODE"
printf '# index\n' >"${SPECS}/INDEX.md"
printf '<!-- planner:testdata-synth v1 -->\n# td\n\n## Acceptance Criteria\n\n- [ ] seeded\n' >"${SPECS}/users-api-test-data.md"
assert_eq "INDEX.md and a synth test-data spec are skipped" "$(planner_crosscheck_body "$INIT")" ""
rm -f "${SPECS}/INDEX.md" "${SPECS}/users-api-test-data.md"

# proposal.md: security and identity decisions.
printf '# Proposal\n\n## Business Outcomes\n\nA visitor registers with an email and a password.\n\n## Parameters\n\nNone.\n' >"${ART}/proposal.md"
assert_eq "auth in the proposal with no decisions section" "$(codes "$(planner_crosscheck_body "$INIT")")" "SECURITY_DECISIONS_MISSING"
printf '\n## Security & Identity Decisions\n\n- **Identifier normalisation** — `auth.email_normalisation`.\n' >>"${ART}/proposal.md"
assert_eq "the decisions section clears it" "$(planner_crosscheck_body "$INIT")" ""
printf '# Proposal\n\n## Business Outcomes\n\nReports list classified documents.\n' >"${ART}/proposal.md"
assert_eq "a proposal with no auth wording needs no section" "$(planner_crosscheck_body "$INIT")" ""
rm -f "${ART}/proposal.md"

echo "--- 3b. blocking and warn levels through planner_crosscheck_run ---"
new_init "INIT-BODY-2"
planner_body_contract_mark "$INIT"
write_spec "${SPECS}/users-api.md" "" no-errors untagged
planner_crosscheck_run "$INIT" >/dev/null 2>&1
rc=$?
log=$(cat "$LOG")
assert_eq "a missing verify mode blocks Crosscheck" "$([ "$rc" -ne 0 ] && echo blocked)" "blocked"
assert_contains "VERIFY_MODE_INVALID is a fail line" "$log" "|META|crosscheck|fail|VERIFY_MODE_INVALID users-api.md"
assert_contains "EDGE_CASES_MISSING is a fail line" "$log" "|META|crosscheck|fail|EDGE_CASES_MISSING users-api.md"
assert_contains "AC_UNTAGGED is a warn line" "$log" "|META|crosscheck|warn|info AC_UNTAGGED users-api.md"
for code in SCOPE_TC_MISMATCH AC_COUNT_HIGH AC_UNTAGGED AC_POST_MERGE_STATE SECURITY_DECISIONS_MISSING; do
  assert_eq "${code} is warn-level" "$(_planner_crosscheck_is_warn_code "$code" && echo yes)" "yes"
done
for code in VERIFY_MODE_INVALID EDGE_CASES_MISSING; do
  assert_eq "${code} is blocking" "$(_planner_crosscheck_is_warn_code "$code" && echo yes || echo no)" "no"
done
for code in VERIFY_MODE_INVALID EDGE_CASES_MISSING SCOPE_TC_MISMATCH AC_COUNT_HIGH AC_UNTAGGED AC_POST_MERGE_STATE SECURITY_DECISIONS_MISSING; do
  assert_not_contains "${code} has a fix hint" "$(planner_crosscheck_fix_hint "$code")" "no canned hint"
done

new_init "INIT-BODY-3"
write_spec "${SPECS}/users-api.md" "" no-errors untagged
planner_crosscheck_run "$INIT" >/dev/null 2>&1
if grep -qE 'VERIFY_MODE_INVALID|EDGE_CASES_MISSING|AC_UNTAGGED' "$LOG"; then
  fail "a legacy initiative gets no ticket-body finding" "$(grep -E 'VERIFY_MODE|EDGE_CASES|AC_UNTAGGED' "$LOG" | head -2)"
else
  pass "a legacy initiative gets no ticket-body finding"
fi

# ── 4. contract marker on the first Specify dispatch ─────────────────────────

echo "--- 4. the first Specify dispatch writes ticket-body-v2 ---"
new_init "INIT-BODY-4"
rmdir "$SPECS" 2>/dev/null
_planner_dispatch_contract_mark "$INIT" Review
before=$(grep -c '|META|contract|start|ticket-body-v2$' "$LOG")
_planner_dispatch_contract_mark "$INIT" Specify
_planner_dispatch_contract_mark "$INIT" Specify
assert_eq "written once, by Specify only" "${before}/$(grep -c '|META|contract|start|ticket-body-v2$' "$LOG")" "0/1"
assert_eq "it is the last of the first-dispatch markers" "$(grep '|META|contract|start|' "$LOG" | tail -1 | cut -d'|' -f5)" "ticket-body-v2"

# ── 5. prompts ───────────────────────────────────────────────────────────────

echo "--- 5. prompts carry the rules ---"
SPEC_PROMPT=$(planner_prompt_specify "INIT-TEST" "an idea" "${REPOS_ROOT}/.ticket-auto/initiatives/INIT-TEST")
for frag in '## Verify Mode' '**Verify mode:** <shape>' '`browser`' '`api-only`' '`live-backend`' '`build-only`' '`diff-only`' \
  '## Errors and Edge Cases' '**Check order**' '**Late or concurrent responses**' '**Unauthorised viewer**' \
  '**Scope names files**' '(read-only)' '**Technical Context states constraints, not calls**' \
  "**Decision is this ticket's slice**" '**Pin what a scaffold installs**' '**Order by state**' \
  '**Group field checks.**' '| Field | Expected |' "About ${PLANNER_AC_SOFT_CAP} criteria at most" '`[unit]`' '`[live]`' \
  '**True on the PR branch.**' '## Security & Identity Decisions' '**Identifier normalisation**' '**Token handling**' \
  'one criterion for the group, not one per field' \
  'planner_crosscheck_body "INIT-TEST"' 'A `planner-crosscheck-body:` line names a spec'; do
  assert_contains "Specify: ${frag}" "$SPEC_PROMPT" "$frag"
done
assert_not_contains "Specify no longer asks for one criterion per field" "$SPEC_PROMPT" "each field or element a list, page or response is said to show"
CONS_PROMPT=$(planner_prompt_consensus "INIT-TEST" "an idea" "${REPOS_ROOT}/.ticket-auto/initiatives/INIT-TEST")
assert_contains "Consensus keeps the body rules" "$CONS_PROMPT" "$(planner_body_template_consensus_rule)"
EPIC_PROMPT=$(planner_prompt_epicgen "INIT-TEST" "an idea" "${REPOS_ROOT}/.ticket-auto/initiatives/INIT-TEST" 2>/dev/null)
assert_contains "Epic Gen carries the security decisions" "$EPIC_PROMPT" "$(planner_security_decisions_epic_rule)"

# ── 6. additive for downstream readers ───────────────────────────────────────

echo "--- 6. the new sections change no downstream verdict ---"
strip_new() {
  awk '/^## (Verify Mode|Errors and Edge Cases)[[:space:]]*$/ { skip = 1; next } /^## / { skip = 0 } !skip { print }' "$1" |
    sed -E 's/^- \[ \] \[(unit|live)\] /- [ ] /'
}
for entry in business-lock-period:feature business-classified-reports:feature enabler-bom-java17:chore; do
  name="${entry%%:*}"
  type="${entry##*:}"
  file="${FIXTURES_DIR}/${name}.md"
  old="${TMP_ROOT}/${name}.old.md"
  strip_new "$file" >"$old"
  if grep -q '^## Verify Mode' "$file" && ! grep -q '^## Verify Mode' "$old"; then
    pass "${name}: the golden body carries Verify Mode"
  else
    fail "${name}: the golden body carries Verify Mode" "section missing or not stripped"
  fi
  check_ticket_ready "BT-${name}" --body "$file" --type "$type" --no-fetch
  new_verdict="${DOR_STATUS} ${DOR_MISSING} ${DOR_ADVISORY}"
  check_ticket_ready "BT-${name}-old" --body "$old" --type "$type" --no-fetch
  assert_eq "${name}: same readiness verdict with and without the sections" "$new_verdict" "${DOR_STATUS} ${DOR_MISSING} ${DOR_ADVISORY}"
  assert_eq "${name}: ready" "${new_verdict%% *}" "ready"
  rc=0
  planner_validate_ticket "$(cat "$file")" true "$type" 2>/dev/null || rc=$?
  assert_eq "${name}: body-section check passes" "$rc" "0"
  declared=$(sed -n 's/^\*\*Verify mode:\*\* \([a-z-]*\).*/\1/p' "$file")
  assert_eq "${name}: classifies as declared (${declared})" "$(verify_mode_shape "$(cat "$file")")" "$declared"
done

# ── 7. ticket-auto-pipeline templates ────────────────────────────────────────

echo "--- 7. templates ---"
tpl_body() { sed '1,/^---$/d' "${TAP_ROOT}/templates/$1.md"; }
for t in feature improvement bug chore security; do
  b=$(tpl_body "$t")
  assert_contains "${t}.md has the Verify Mode field" "$b" $'## Verify Mode\n\n**Verify mode:** {shape}'
  filled="${b//\{shape\}/build-only}"
  assert_eq "${t}.md filled in classifies as the shape" "$(verify_mode_shape "$filled")" "build-only"
  before=$(awk '/^## Verify Mode[[:space:]]*$/ { skip = 1; next } /^## / { skip = 0 } !skip { print }' <<<"$b")
  assert_eq "${t}.md left unfilled classifies as before the field existed" "$(verify_mode_shape "$b")" "$(verify_mode_shape "$before")"
done
for t in feature improvement; do
  assert_contains "${t}.md has Errors and Edge Cases" "$(tpl_body "$t")" $'## Errors and Edge Cases\n\n- **Failure:**'
done

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
