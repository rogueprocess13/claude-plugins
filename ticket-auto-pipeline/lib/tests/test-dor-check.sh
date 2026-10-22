#!/usr/bin/env bash
# test-dor-check.sh — unit tests for lib/dor-check.sh (dor-readiness-gate-
# foundation, tasks 4.11/4.14; extended by dor-quality-score, tasks 8.1-8.5).
# Usage: bash test-dor-check.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/dor"

# notes-parse.sh is sourced here (not by dor-check.sh itself — see its
# sourcing block for why) so get_test_users_by_role is available for the
# strict-catalog fixtures below, mirroring how gate-check.sh already
# sources it under its own errexit before dor-check.sh runs.
source "$LIB_DIR/notes-parse.sh"
source "$LIB_DIR/dor-check.sh"

# Hermetic: a developer's untracked config/test-users.json would otherwise
# resolve here but not in CI. Tests that need a catalog pass --catalog.
resolve_test_user_catalog() { return 1; }

PASS=0
FAIL=0
_pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_fail() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

_write_body() {
  local file="$1" content="$2"
  printf '%s' "$content" >"$file"
}

# ── Fixture bodies ───────────────────────────────────────────────────────

full_body='## Summary
Save handovers reliably from the settings page.

## Background / Motivation
Attorneys report the Save button silently failing on the handovers settings page, with no error shown and no data saved.

## Proposed Behaviour
Saving on the handovers settings page always either succeeds with a confirmation toast or fails with a visible error toast — never silently.

## Acceptance Criteria
- [ ] Save button works
- [ ] Error toast appears

## Test User
`admin` — password `admin`

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |

## Navigation Path
`Settings > Handovers > Save`
'

missing_sections_body='## Summary
Fix the broken feature.

## Background / Motivation
The feature is broken for some users and this is disruptive.

## Proposed Behaviour
The feature works for all users.

## Acceptance Criteria
- [ ] Feature works

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |
'

backend_only_body='## Summary
API returns the wrong status code.

## Background / Motivation
The API returns 500 instead of 200 for a valid request, breaking downstream integrations.

## Proposed Behaviour
The API returns 200 for a valid request.

## Acceptance Criteria
- [ ] API returns 200

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | gateway | api  |
'

no_scope_body='## Summary
Fix the broken feature.

## Background / Motivation
The feature is broken for some users.

## Proposed Behaviour
The feature works for all users.

## Acceptance Criteria
- [ ] Feature works
'

# ── Scenario: ready ticket ──────────────────────────────────────────────

body_file="$TMP_ROOT/full-body.md"
_write_body "$body_file" "$full_body"

rc=0
check_ticket_ready "TEST-READY" --body "$body_file" --type feature --no-fetch || rc=$?
[ "$rc" = "0" ] && [ "$DOR_STATUS" = "ready" ] && [ "$DOR_MISSING" = "[]" ] &&
  _pass "ready ticket: exit 0, status ready, empty missing" ||
  _fail "ready ticket should pass (got rc=$rc status=$DOR_STATUS missing=$DOR_MISSING)"

echo "$DOR_DIMENSIONS" | jq -e 'has("acceptance_criteria") and has("verification") and has("scope") and has("intent") and has("test_uat") and has("context") and has("completion") and has("dependencies") and has("constraints") and has("edge_cases") and has("requirement_completeness")' >/dev/null &&
  _pass "DOR_DIMENSIONS carries every dimension key" ||
  _fail "DOR_DIMENSIONS missing a key (got $DOR_DIMENSIONS)"

[ -n "$DOR_SCORE" ] && [ "$DOR_SCORE" -ge 0 ] 2>/dev/null && [ "$DOR_SCORE" -le 100 ] 2>/dev/null &&
  _pass "DOR_SCORE is an integer in [0,100] (got $DOR_SCORE)" ||
  _fail "DOR_SCORE should be an integer 0-100 (got $DOR_SCORE)"

# ── Scenario: missing structural sections ────────────────────────────────

body_file="$TMP_ROOT/missing-body.md"
_write_body "$body_file" "$missing_sections_body"

rc=0
check_ticket_ready "TEST-MISSING" --body "$body_file" --type feature --no-fetch || rc=$?
[ "$rc" = "1" ] && [ "$DOR_STATUS" = "not-ready" ] &&
  echo "$DOR_MISSING" | jq -e 'index("NAV_PATH_MISSING") != null' >/dev/null &&
  echo "$DOR_MISSING" | jq -e 'index("TEST_USER_MISSING") != null' >/dev/null &&
  _pass "missing sections: NAV_PATH_MISSING + TEST_USER_MISSING, not-ready, exit 1" ||
  _fail "missing sections should report both codes (got rc=$rc missing=$DOR_MISSING)"

# ── Scenario: check cannot run ───────────────────────────────────────────

rc=0
check_ticket_ready "TEST-NOBODY" --no-fetch || rc=$?
[ "$rc" = "2" ] && [ "$DOR_STATUS" = "unavailable" ] &&
  _pass "no body resolvable: exit 2, status unavailable" ||
  _fail "no body resolvable should be exit 2 (got rc=$rc status=$DOR_STATUS)"

# ── Scenario: advisory failure alone leaves the ticket ready ─────────────
# A Test User section naming an unresolvable role, with no catalog seeded —
# CATALOG_ABSENT path: TEST_USER_UNRESOLVED is unevaluated, not advisory,
# and never blocks. See the strict-catalog fixture below for the advisory
# (catalog present, role unresolved) path.

body_file="$TMP_ROOT/full-body-2.md"
_write_body "$body_file" "$full_body"
rc=0
check_ticket_ready "TEST-CATALOG-ABSENT" --body "$body_file" --type feature --no-fetch --catalog "$TMP_ROOT/no-such-catalog.json" || rc=$?
[ "$rc" = "0" ] && [ "$DOR_STATUS" = "ready" ] &&
  echo "$DOR_CHECKS" | jq -e '.CATALOG_ABSENT.pass == true' >/dev/null &&
  _pass "CATALOG_ABSENT reported, ticket still ready" ||
  _fail "CATALOG_ABSENT should be reported without blocking (got rc=$rc status=$DOR_STATUS checks=$DOR_CHECKS)"

# ── Scenario: advisory failures are still recorded ───────────────────────

echo "$DOR_ADVISORY" | jq -e 'index("VPLAN_MISSING") != null' >/dev/null &&
  _pass "advisory VPLAN_MISSING recorded on a body with no Verification Plan" ||
  _fail "VPLAN_MISSING should be recorded as advisory (got $DOR_ADVISORY)"

# ── Scenario: backend-only ticket needs no navigation path ───────────────

body_file="$TMP_ROOT/backend-body.md"
_write_body "$body_file" "$backend_only_body"
rc=0
check_ticket_ready "TEST-BACKEND" --body "$body_file" --type feature --no-fetch || rc=$?
echo "$DOR_MISSING" | jq -e 'index("NAV_PATH_MISSING") == null' >/dev/null &&
  echo "$DOR_MISSING" | jq -e 'index("TEST_USER_MISSING") == null' >/dev/null &&
  _pass "backend-only scope: NAV_PATH_MISSING/TEST_USER_MISSING never fire" ||
  _fail "backend-only scope should skip nav/test-user codes (got $DOR_MISSING)"

echo "$DOR_DIMENSIONS" | jq -e '.test_uat == null' >/dev/null &&
  _pass "backend-only scope: test_uat dimension is null" ||
  _fail "backend-only scope should report test_uat as null (got $DOR_DIMENSIONS)"

# ── Scenario: non-bug ticket needs no reproduction steps ─────────────────

rc=0
check_ticket_ready "TEST-FEATURE-NO-REPRO" --body "$body_file" --type feature --no-fetch || rc=$?
echo "$DOR_MISSING" | jq -e 'index("REPRO_MISSING") == null' >/dev/null &&
  _pass "feature ticket: REPRO_MISSING never fires" ||
  _fail "feature ticket should skip REPRO_MISSING (got $DOR_MISSING)"

rc=0
check_ticket_ready "TEST-BUG-NO-REPRO" --body "$body_file" --type bug --no-fetch || rc=$?
echo "$DOR_MISSING" | jq -e 'index("REPRO_MISSING") != null' >/dev/null &&
  _pass "bug ticket with no repro steps: REPRO_MISSING fires" ||
  _fail "bug ticket should report REPRO_MISSING (got $DOR_MISSING)"

# ── Scenario: ambiguous scope keeps the full requirement set ─────────────

body_file="$TMP_ROOT/no-scope-body.md"
_write_body "$body_file" "$no_scope_body"
rc=0
check_ticket_ready "TEST-NO-SCOPE" --body "$body_file" --type feature --no-fetch || rc=$?
echo "$DOR_MISSING" | jq -e 'index("SCOPE_MISSING") != null' >/dev/null &&
  echo "$DOR_MISSING" | jq -e 'index("NAV_PATH_MISSING") != null' >/dev/null &&
  echo "$DOR_MISSING" | jq -e 'index("TEST_USER_MISSING") != null' >/dev/null &&
  _pass "no Scope table: SCOPE_MISSING plus full frontend-scoped set evaluated" ||
  _fail "ambiguous scope should keep the full requirement set (got $DOR_MISSING)"

# ── Strict-catalog promotion ──────────────────────────────────────────────

catalog_file="$TMP_ROOT/test-users.json"
echo '[{"id":"u1","roles":["admin"],"environments":["staging"]}]' >"$catalog_file"

unresolved_body='## Summary
Add a new feature to the page.

## Background / Motivation
Users have asked for this feature for a long time and it unblocks a common workflow.

## Proposed Behaviour
The feature is added to the page and works as described.

## Acceptance Criteria
- [ ] Feature works

## Test User
`some-unknown-role`

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |

## Navigation Path
`Settings > Page`
'
body_file="$TMP_ROOT/unresolved-body.md"
_write_body "$body_file" "$unresolved_body"

rc=0
DOR_STRICT_CATALOG=false check_ticket_ready "TEST-STRICT-OFF" --body "$body_file" --type feature --no-fetch --catalog "$catalog_file" || rc=$?
[ "$rc" = "0" ] && [ "$DOR_STATUS" = "ready" ] &&
  echo "$DOR_ADVISORY" | jq -e 'index("TEST_USER_UNRESOLVED") != null' >/dev/null &&
  _pass "defaults preserve current behaviour: unresolved test user is advisory only" ||
  _fail "unresolved test user should be advisory-only by default (got rc=$rc status=$DOR_STATUS advisory=$DOR_ADVISORY)"

rc=0
DOR_STRICT_CATALOG=true check_ticket_ready "TEST-STRICT-ON" --body "$body_file" --type feature --no-fetch --catalog "$catalog_file" || rc=$?
[ "$rc" = "1" ] && [ "$DOR_STATUS" = "not-ready" ] &&
  echo "$DOR_MISSING" | jq -e 'index("TEST_USER_UNRESOLVED") != null' >/dev/null &&
  _pass "DOR_STRICT_CATALOG=true promotes TEST_USER_UNRESOLVED to hard" ||
  _fail "strict catalog should promote TEST_USER_UNRESOLVED (got rc=$rc status=$DOR_STATUS missing=$DOR_MISSING)"

rc=0
DOR_STRICT_CATALOG=true check_ticket_ready "TEST-STRICT-NO-CATALOG" --body "$body_file" --type feature --no-fetch --catalog "$TMP_ROOT/absent.json" || rc=$?
echo "$DOR_MISSING" | jq -e 'index("TEST_USER_UNRESOLVED") == null' >/dev/null &&
  _pass "strict catalog with no catalog resolved never blocks on TEST_USER_UNRESOLVED" ||
  _fail "CATALOG_ABSENT should never contribute to not-ready, even under strict (got $DOR_MISSING)"

# ── Sourcing does not leak errexit/pipefail into the caller ─────────────

(
  set +e
  source "$LIB_DIR/dor-check.sh"
  check_ticket_ready "TEST-LEAK-CHECK" --no-fetch >/dev/null 2>&1
  if [[ $- == *e* ]]; then
    echo "LEAK-FAIL"
  else
    echo "LEAK-OK"
  fi
) | grep -q "LEAK-OK" &&
  _pass "sourcing dor-check.sh + calling check_ticket_ready leaves errexit unset" ||
  _fail "check_ticket_ready must not leak errexit into the caller's shell"

# ── ensure_ticket_readiness: self-healing cache ──────────────────────────

write_ticket_manifest "CACHE-1" "INIT-1" "feature" '[]'
body_file="$TMP_ROOT/cache-body-1.md"
_write_body "$body_file" "$missing_sections_body"

rc=0
ensure_ticket_readiness "CACHE-1" --body "$body_file" || rc=$?
[ "$rc" = "1" ] && [ "$DOR_STATUS" = "not-ready" ] &&
  _pass "ensure_ticket_readiness: never-scanned ticket computes live" ||
  _fail "ensure_ticket_readiness should compute live for a never-scanned ticket (got rc=$rc status=$DOR_STATUS)"

cached_ready_json=$(get_ticket_manifest_field "CACHE-1" ready 2>/dev/null)
[ -n "$cached_ready_json" ] &&
  [ "$(echo "$cached_ready_json" | jq -r '.status')" = "not-ready" ] &&
  [ "$(echo "$cached_ready_json" | jq -r '.body_hash // empty')" != "" ] &&
  _pass "ensure_ticket_readiness: live verdict (with score/body_hash) is cached on the manifest" ||
  _fail "ensure_ticket_readiness should cache the computed verdict incl. body_hash (got $cached_ready_json)"

# ── --waive CLI ────────────────────────────────────────────────────────

write_ticket_manifest "WAIVE-1" "INIT-1" "feature" '[]'
set_ticket_readiness "WAIVE-1" "not-ready" '["AC_VAGUE"]' '[]'

waive_out=$(bash "$LIB_DIR/dor-check.sh" --waive "WAIVE-1" "AC_VAGUE" "reviewed, wording is fine" --by tester)
echo "$waive_out" | grep -q "status now ready" &&
  _pass "--waive CLI: last hard code waived flips status to ready" ||
  _fail "--waive CLI should report status now ready (got: $waive_out)"

waived_json=$(get_ticket_manifest_field "WAIVE-1" ready 2>/dev/null | jq -c '.waived.AC_VAGUE')
echo "$waived_json" | jq -e '.by == "tester" and .reason == "reviewed, wording is fine"' >/dev/null &&
  _pass "--waive CLI: waiver records by/reason" ||
  _fail "--waive CLI should record by/reason (got $waived_json)"

# --waive on an already-ready ticket is a no-op that still succeeds
write_ticket_manifest "WAIVE-2" "INIT-1" "feature" '[]'
set_ticket_readiness "WAIVE-2" "ready" '[]' '[]'
waive_out2=$(bash "$LIB_DIR/dor-check.sh" --waive "WAIVE-2" "AC_VAGUE" "n/a" 2>&1)
rc2=$?
[ "$rc2" = "0" ] && echo "$waive_out2" | grep -q "status now ready" &&
  _pass "--waive CLI: no-op on an already-ready ticket still succeeds" ||
  _fail "--waive CLI should succeed as a no-op on a ready ticket (rc=$rc2 out=$waive_out2)"

# ══════════════════════════════════════════════════════════════════════════
# dor-quality-score: fixture-driven assertions (task 8.1)
# ══════════════════════════════════════════════════════════════════════════

declare -A FIXTURE_TYPE=(
  ["01-excellent.md"]=feature ["02-minimal.md"]=feature ["03-missing-intent.md"]=feature
  ["04-useless-scope.md"]=feature ["05-vague-ac.md"]=feature ["06-backend-no-verification.md"]=chore
  ["07-fe-no-test-user.md"]=feature ["08-fe-no-nav-path.md"]=feature ["09-backend-no-ui.md"]=chore
  ["10-bug-no-expected-actual.md"]=bug ["11-contradictory-acs.md"]=feature ["12-unseeded-test-infra.md"]=feature
  ["13-impl-only-acs.md"]=chore ["14-typo-fix.md"]=feature ["15-impl-guide-no-behavior.md"]=chore
  ["16-edge-cases-missing-core.md"]=feature ["17-self-verifying-no-vplan.md"]=chore
  ["18-backend-twin.md"]=chore ["19-padding.md"]=feature
  ["20-unsourced-legacy.md"]=feature ["21-unsourced-contract.md"]=feature ["22-sourced-contract.md"]=feature
  ["23-planned-contract-unsourced.md"]=feature
  ["24-contract-no-test-data.md"]=feature ["25-td-chore.md"]=chore
  ["26-contract-implied-miss.md"]=feature ["27-planned-all-none-miss.md"]=feature
  ["28-threshold-only-none.md"]=feature
)
declare -A FIXTURE_STATUS=(
  ["01-excellent.md"]=ready ["02-minimal.md"]=ready ["03-missing-intent.md"]=not-ready
  ["04-useless-scope.md"]=ready ["05-vague-ac.md"]=not-ready ["06-backend-no-verification.md"]=ready
  ["07-fe-no-test-user.md"]=not-ready ["08-fe-no-nav-path.md"]=not-ready ["09-backend-no-ui.md"]=ready
  ["10-bug-no-expected-actual.md"]=not-ready ["11-contradictory-acs.md"]=ready ["12-unseeded-test-infra.md"]=ready
  ["13-impl-only-acs.md"]=ready ["14-typo-fix.md"]=ready ["15-impl-guide-no-behavior.md"]=ready
  ["16-edge-cases-missing-core.md"]=ready ["17-self-verifying-no-vplan.md"]=ready
  ["18-backend-twin.md"]=ready ["19-padding.md"]=ready
  ["20-unsourced-legacy.md"]=ready ["21-unsourced-contract.md"]=not-ready ["22-sourced-contract.md"]=ready
  ["23-planned-contract-unsourced.md"]=not-ready
  ["24-contract-no-test-data.md"]=not-ready ["25-td-chore.md"]=ready
  ["26-contract-implied-miss.md"]=ready ["27-planned-all-none-miss.md"]=ready
  ["28-threshold-only-none.md"]=ready
)
declare -A FIXTURE_HARD=(
  ["03-missing-intent.md"]=INTENT_MISSING ["05-vague-ac.md"]=AC_VAGUE ["07-fe-no-test-user.md"]=TEST_USER_MISSING
  ["08-fe-no-nav-path.md"]=NAV_PATH_MISSING ["10-bug-no-expected-actual.md"]=REPRO_NO_EXPECTED_ACTUAL
  ["21-unsourced-contract.md"]=TEST_DATA_UNSOURCED ["23-planned-contract-unsourced.md"]=TEST_DATA_UNSOURCED
  ["24-contract-no-test-data.md"]=TEST_DATA_MISSING
)
declare -A FIXTURE_ADVISORY=(
  ["02-minimal.md"]=TEST_DATA_MISSING ["06-backend-no-verification.md"]=VERIFICATION_REQUIRED_NOT_SELF_VERIFYING
  ["12-unseeded-test-infra.md"]=TEST_USER_UNRESOLVED ["13-impl-only-acs.md"]=AC_IMPLEMENTATION_ONLY
  ["15-impl-guide-no-behavior.md"]=AC_IMPLEMENTATION_ONLY ["20-unsourced-legacy.md"]=TEST_DATA_UNSOURCED
)
declare -A FIXTURE_GAPS=(
  ["04-useless-scope.md"]=deep_scope_ambiguity ["11-contradictory-acs.md"]=contradictory_requirements
  ["16-edge-cases-missing-core.md"]=edge_case_sufficiency
)

for fixture in "${!FIXTURE_TYPE[@]}"; do
  fpath="$FIXTURES_DIR/$fixture"
  [ -f "$fpath" ] || {
    _fail "fixture $fixture not found under $FIXTURES_DIR"
    continue
  }
  frc=0
  check_ticket_ready "FIX-${fixture}" --body "$fpath" --type "${FIXTURE_TYPE[$fixture]}" --no-fetch --catalog "$catalog_file" || frc=$?
  expected_status="${FIXTURE_STATUS[$fixture]}"

  if [ "$DOR_STATUS" = "$expected_status" ]; then
    _pass "fixture $fixture: status=$expected_status"
  else
    _fail "fixture $fixture: expected status=$expected_status, got $DOR_STATUS (missing=$DOR_MISSING)"
  fi

  if [ -n "${FIXTURE_HARD[$fixture]:-}" ]; then
    if echo "$DOR_MISSING" | jq -e --arg c "${FIXTURE_HARD[$fixture]}" 'index($c) != null' >/dev/null; then
      _pass "fixture $fixture: DOR_MISSING contains ${FIXTURE_HARD[$fixture]}"
    else
      _fail "fixture $fixture: expected DOR_MISSING to contain ${FIXTURE_HARD[$fixture]} (got $DOR_MISSING)"
    fi
  fi

  if [ -n "${FIXTURE_ADVISORY[$fixture]:-}" ]; then
    if echo "$DOR_ADVISORY" | jq -e --arg c "${FIXTURE_ADVISORY[$fixture]}" 'index($c) != null' >/dev/null; then
      _pass "fixture $fixture: DOR_ADVISORY contains ${FIXTURE_ADVISORY[$fixture]}"
    else
      _fail "fixture $fixture: expected DOR_ADVISORY to contain ${FIXTURE_ADVISORY[$fixture]} (got $DOR_ADVISORY)"
    fi
  fi

  if [ -n "${FIXTURE_GAPS[$fixture]:-}" ]; then
    if echo "$DOR_GAPS" | jq -e --arg g "${FIXTURE_GAPS[$fixture]}" 'index($g) != null' >/dev/null; then
      _pass "fixture $fixture: DOR_GAPS contains ${FIXTURE_GAPS[$fixture]}"
    else
      _fail "fixture $fixture: expected DOR_GAPS to contain ${FIXTURE_GAPS[$fixture]} (got $DOR_GAPS)"
    fi
  fi
done

# fixture 10: REPRO_MISSING must NEVER fire (repro steps ARE present) even
# though REPRO_NO_EXPECTED_ACTUAL does.
check_ticket_ready "FIX-10-repro" --body "$FIXTURES_DIR/10-bug-no-expected-actual.md" --type bug --no-fetch || true
echo "$DOR_MISSING" | jq -e 'index("REPRO_MISSING") == null' >/dev/null &&
  _pass "fixture 10: REPRO_MISSING does not fire alongside REPRO_NO_EXPECTED_ACTUAL" ||
  _fail "fixture 10 should never report REPRO_MISSING (got $DOR_MISSING)"

# fixture 17: VPLAN_MISSING must be satisfied-by-AC, never in DOR_ADVISORY.
check_ticket_ready "FIX-17-vplan" --body "$FIXTURES_DIR/17-self-verifying-no-vplan.md" --type chore --no-fetch || true
echo "$DOR_ADVISORY" | jq -e 'index("VPLAN_MISSING") == null' >/dev/null &&
  echo "$DOR_CHECKS" | jq -e '.VPLAN_MISSING.class == "satisfied-by-ac"' >/dev/null &&
  _pass "fixture 17: VPLAN_MISSING satisfied by self-verifying AC, not advisory" ||
  _fail "fixture 17: VPLAN_MISSING should be satisfied-by-ac (got advisory=$DOR_ADVISORY checks=$(echo "$DOR_CHECKS" | jq -c .VPLAN_MISSING))"

# ══════════════════════════════════════════════════════════════════════════
# Score relation tests (task 8.2)
# ══════════════════════════════════════════════════════════════════════════

check_ticket_ready "SCORE-01" --body "$FIXTURES_DIR/01-excellent.md" --type feature --no-fetch || true
score_01=$DOR_SCORE
[ "$score_01" -ge 90 ] 2>/dev/null &&
  _pass "fixture 01: score >= 90 (got $score_01)" ||
  _fail "fixture 01 should score >= 90 (got $score_01)"

check_ticket_ready "SCORE-02" --body "$FIXTURES_DIR/02-minimal.md" --type feature --no-fetch || true
score_02=$DOR_SCORE
[ "$score_01" -gt "$score_02" ] 2>/dev/null && [ "$score_02" -gt 0 ] 2>/dev/null &&
  _pass "01 > 02 > 0 (got $score_01 > $score_02 > 0)" ||
  _fail "expected 01 > 02 > 0 (got $score_01, $score_02)"

check_ticket_ready "SCORE-19" --body "$FIXTURES_DIR/19-padding.md" --type feature --no-fetch || true
score_19=$DOR_SCORE
[ "$score_19" = "$score_02" ] &&
  _pass "padding fixture (19) score == fixture 02 score ($score_19 == $score_02)" ||
  _fail "padding should not change the score (got 19=$score_19, 02=$score_02)"

check_ticket_ready "SCORE-14" --body "$FIXTURES_DIR/14-typo-fix.md" --type feature --no-fetch || true
score_14=$DOR_SCORE
status_14=$DOR_STATUS
[ "$status_14" = "ready" ] && [ "$score_14" -lt "$score_02" ] 2>/dev/null &&
  _pass "fixture 14: ready with score < fixture 02 (got $score_14 < $score_02)" ||
  _fail "fixture 14 should be ready with a lower score than fixture 02 (got status=$status_14 score=$score_14 vs $score_02)"

check_ticket_ready "SCORE-18" --body "$FIXTURES_DIR/18-backend-twin.md" --type chore --no-fetch || true
score_18=$DOR_SCORE
test_uat_18=$(echo "$DOR_DIMENSIONS" | jq -c '.test_uat')
fe_twin_body=$(cat "$FIXTURES_DIR/18-backend-twin.md")
fe_twin_body="${fe_twin_body}

## Test User

\`user@example.com\` — password \`admin\`

## Navigation Path

\`Quotes > Rate limit banner\`
"
fe_twin_body="${fe_twin_body/| BE    | quote-svc | rate-limit |/| FE    | gateway   | quote-page |
| BE    | quote-svc | rate-limit |}"
fe_twin_file="$TMP_ROOT/18-fe-twin.md"
_write_body "$fe_twin_file" "$fe_twin_body"
check_ticket_ready "SCORE-18-FE" --body "$fe_twin_file" --type chore --no-fetch || true
score_18_fe=$DOR_SCORE

[ "$test_uat_18" = "null" ] &&
  _pass "fixture 18: test_uat dimension is null for the backend-only ticket" ||
  _fail "fixture 18 should report test_uat as null (got $test_uat_18)"
[ "$score_18" -ge "$score_18_fe" ] 2>/dev/null &&
  _pass "fixture 18: backend score ($score_18) not below its frontend twin's score ($score_18_fe)" ||
  _fail "fixture 18's backend score should not be lower than its frontend twin (got $score_18 vs $score_18_fe)"

check_ticket_ready "SCORE-15" --body "$FIXTURES_DIR/15-impl-guide-no-behavior.md" --type chore --no-fetch || true
echo "$DOR_DIMENSIONS" | jq -e '.acceptance_criteria == 0' >/dev/null &&
  _pass "fixture 15: acceptance_criteria dimension == 0" ||
  _fail "fixture 15's acceptance_criteria dimension should be 0 (got $(echo "$DOR_DIMENSIONS" | jq .acceptance_criteria))"

# ══════════════════════════════════════════════════════════════════════════
# Strict-flag tests (task 8.3)
# ══════════════════════════════════════════════════════════════════════════

rc13=0
DOR_STRICT_AC_IMPL=true check_ticket_ready "STRICT-13" --body "$FIXTURES_DIR/13-impl-only-acs.md" --type chore --no-fetch || rc13=$?
[ "$rc13" = "1" ] && [ "$DOR_STATUS" = "not-ready" ] &&
  echo "$DOR_MISSING" | jq -e 'index("AC_IMPLEMENTATION_ONLY") != null' >/dev/null &&
  _pass "fixture 13 not-ready under DOR_STRICT_AC_IMPL=true" ||
  _fail "fixture 13 should be not-ready under DOR_STRICT_AC_IMPL=true (rc=$rc13 status=$DOR_STATUS missing=$DOR_MISSING)"

check_ticket_ready "STRICT-13-OFF" --body "$FIXTURES_DIR/13-impl-only-acs.md" --type chore --no-fetch || true
[ "$DOR_STATUS" = "ready" ] &&
  _pass "fixture 13 ready by default (DOR_STRICT_AC_IMPL unset)" ||
  _fail "fixture 13 should be ready by default (got $DOR_STATUS)"

rc06=0
DOR_STRICT_VERIFICATION=true check_ticket_ready "STRICT-06" --body "$FIXTURES_DIR/06-backend-no-verification.md" --type chore --no-fetch || rc06=$?
[ "$rc06" = "1" ] && [ "$DOR_STATUS" = "not-ready" ] &&
  echo "$DOR_MISSING" | jq -e 'index("VERIFICATION_REQUIRED_NOT_SELF_VERIFYING") != null' >/dev/null &&
  _pass "fixture 06 not-ready under DOR_STRICT_VERIFICATION=true" ||
  _fail "fixture 06 should be not-ready under DOR_STRICT_VERIFICATION=true (rc=$rc06 status=$DOR_STATUS missing=$DOR_MISSING)"

check_ticket_ready "STRICT-06-OFF" --body "$FIXTURES_DIR/06-backend-no-verification.md" --type chore --no-fetch || true
[ "$DOR_STATUS" = "ready" ] &&
  _pass "fixture 06 ready by default (DOR_STRICT_VERIFICATION unset)" ||
  _fail "fixture 06 should be ready by default (got $DOR_STATUS)"

# ══════════════════════════════════════════════════════════════════════════
# DOR_STRICT_VPLAN tests (planner-ready-by-construction)
# ══════════════════════════════════════════════════════════════════════════
#
# Two non-self-verifying AC lines (neither matches _DOR_SELFVERIFY_RE — no
# 3-digit status codes, "within Nms/s", equals/is-set/user-can wording,
# error message, N%/ms/kb, or quoted strings) so satisfied_by_ac never
# applies here: selfverify_count*2 (0) >= ac_count (2) is false.

vplan_base_body='## Summary
Improve the export workflow.

## Background / Motivation
Finance needs a faster way to reconcile invoices.

## Proposed Behaviour
An export action produces a downloadable file.

## Acceptance Criteria
- [ ] The export button appears on the invoice list
- [ ] The exported file reflects the current filter

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | api     | export |

## Test User
qa@example.com / password123
'

no_vplan_file="$TMP_ROOT/vplan-missing.md"
_write_body "$no_vplan_file" "$vplan_base_body"

rc=0
DOR_STRICT_VPLAN=true check_ticket_ready "STRICT-VPLAN-MISSING" --body "$no_vplan_file" --type chore --no-fetch || rc=$?
[ "$rc" = "1" ] && [ "$DOR_STATUS" = "not-ready" ] &&
  echo "$DOR_MISSING" | jq -e 'index("VPLAN_MISSING") != null' >/dev/null &&
  _pass "no table, no self-verifying AC: not-ready under DOR_STRICT_VPLAN=true" ||
  _fail "should be not-ready under DOR_STRICT_VPLAN=true (rc=$rc status=$DOR_STATUS missing=$DOR_MISSING)"

check_ticket_ready "STRICT-VPLAN-MISSING-OFF" --body "$no_vplan_file" --type chore --no-fetch || true
[ "$DOR_STATUS" = "ready" ] &&
  echo "$DOR_ADVISORY" | jq -e 'index("VPLAN_MISSING") != null' >/dev/null &&
  _pass "no table, no self-verifying AC: ready but VPLAN_MISSING advisory by default" ||
  _fail "should be ready with VPLAN_MISSING advisory by default (status=$DOR_STATUS advisory=$DOR_ADVISORY)"

row_gap_body="${vplan_base_body}
## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|-----------|-----------|------------------|-------------------|--------------------|------------|
| 1 | Export button appears | finance | Billing > Invoices | none | button is present | Y |
"
row_gap_file="$TMP_ROOT/vplan-row-gap.md"
_write_body "$row_gap_file" "$row_gap_body"

rc=0
DOR_STRICT_VPLAN=true check_ticket_ready "STRICT-VPLAN-ROWGAP" --body "$row_gap_file" --type chore --no-fetch || rc=$?
[ "$rc" = "1" ] && [ "$DOR_STATUS" = "not-ready" ] &&
  echo "$DOR_MISSING" | jq -e 'index("VPLAN_ROW_GAP") != null' >/dev/null &&
  _pass "1 row vs 2 AC lines: not-ready under DOR_STRICT_VPLAN=true" ||
  _fail "should be not-ready under DOR_STRICT_VPLAN=true (rc=$rc status=$DOR_STATUS missing=$DOR_MISSING)"

check_ticket_ready "STRICT-VPLAN-ROWGAP-OFF" --body "$row_gap_file" --type chore --no-fetch || true
[ "$DOR_STATUS" = "ready" ] &&
  echo "$DOR_ADVISORY" | jq -e 'index("VPLAN_ROW_GAP") != null' >/dev/null &&
  _pass "1 row vs 2 AC lines: ready but VPLAN_ROW_GAP advisory by default" ||
  _fail "should be ready with VPLAN_ROW_GAP advisory by default (status=$DOR_STATUS advisory=$DOR_ADVISORY)"

unverifiable_body="${vplan_base_body}
## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|-----------|-----------|------------------|-------------------|--------------------|------------|
| 1 | Export button appears | finance | Billing > Invoices | none | looks correct |   |
| 2 | Export reflects filter | finance | Billing > Invoices | filtered invoices | behaves as expected |   |
"
unverifiable_file="$TMP_ROOT/vplan-unverifiable.md"
_write_body "$unverifiable_file" "$unverifiable_body"

rc=0
DOR_STRICT_VPLAN=true check_ticket_ready "STRICT-VPLAN-UNVERIFIABLE" --body "$unverifiable_file" --type chore --no-fetch || rc=$?
[ "$rc" = "1" ] && [ "$DOR_STATUS" = "not-ready" ] &&
  echo "$DOR_MISSING" | jq -e 'index("VPLAN_UNVERIFIABLE") != null' >/dev/null &&
  _pass "zero rows marked: not-ready under DOR_STRICT_VPLAN=true" ||
  _fail "should be not-ready under DOR_STRICT_VPLAN=true (rc=$rc status=$DOR_STATUS missing=$DOR_MISSING)"

check_ticket_ready "STRICT-VPLAN-UNVERIFIABLE-OFF" --body "$unverifiable_file" --type chore --no-fetch || true
[ "$DOR_STATUS" = "ready" ] &&
  echo "$DOR_ADVISORY" | jq -e 'index("VPLAN_UNVERIFIABLE") != null' >/dev/null &&
  _pass "zero rows marked: ready but VPLAN_UNVERIFIABLE advisory by default" ||
  _fail "should be ready with VPLAN_UNVERIFIABLE advisory by default (status=$DOR_STATUS advisory=$DOR_ADVISORY)"

# #514: y/Y in other cells ("Agency", "yearly", "Yes") must not count as a
# Verifiable mark — the old whole-row grep made this table look verifiable.
y_words_body="${vplan_base_body}
## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|-----------|-----------|------------------|-------------------|--------------------|------------|
| 1 | Agency sees yearly export | collection agency | Billing > Yearly | any invoice | Yes button shows |   |
| 2 | Export reflects filter | any user | Billing > Invoices | yearly invoices | behaves as expected | ✗ |
"
y_words_file="$TMP_ROOT/vplan-y-words.md"
_write_body "$y_words_file" "$y_words_body"

rc=0
DOR_STRICT_VPLAN=true check_ticket_ready "STRICT-VPLAN-YWORDS" --body "$y_words_file" --type chore --no-fetch || rc=$?
[ "$rc" = "1" ] && echo "$DOR_MISSING" | jq -e 'index("VPLAN_UNVERIFIABLE") != null' >/dev/null &&
  _pass "#514: y/Y words outside the Verifiable column still fire VPLAN_UNVERIFIABLE" ||
  _fail "#514: y-words table should fire VPLAN_UNVERIFIABLE (rc=$rc missing=$DOR_MISSING)"

# The self-verifying-AC escape hatch is unaffected by DOR_STRICT_VPLAN in
# either state — no Verification Plan table, but a single AC line that
# matches _DOR_SELFVERIFY_RE ("returns 200").
selfverify_body='## Summary
Fix the status code returned by the health endpoint.

## Background / Motivation
The health endpoint returns the wrong status code.

## Proposed Behaviour
The endpoint returns 200 on success.

## Acceptance Criteria
- [ ] The health endpoint returns 200

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | api     | health |

## Test User
qa@example.com / password123
'
selfverify_file="$TMP_ROOT/vplan-selfverify.md"
_write_body "$selfverify_file" "$selfverify_body"

DOR_STRICT_VPLAN=true check_ticket_ready "STRICT-VPLAN-SELFVERIFY" --body "$selfverify_file" --type chore --no-fetch || true
echo "$DOR_CHECKS" | jq -e '.VPLAN_MISSING.class == "satisfied-by-ac"' >/dev/null &&
  _pass "self-verifying AC still satisfies VPLAN_MISSING under DOR_STRICT_VPLAN=true" ||
  _fail "VPLAN_MISSING should stay satisfied-by-ac under strict mode (checks=$(echo "$DOR_CHECKS" | jq -c .VPLAN_MISSING))"

! echo "$DOR_MISSING" | jq -e 'index("VPLAN_MISSING") != null' >/dev/null &&
  _pass "VPLAN_MISSING does not block a self-verifying-AC ticket under DOR_STRICT_VPLAN=true" ||
  _fail "VPLAN_MISSING must not block a self-verifying-AC ticket under DOR_STRICT_VPLAN=true (missing=$DOR_MISSING)"

# ══════════════════════════════════════════════════════════════════════════
# Widened AC_VAGUE tests (task 8.4)
# ══════════════════════════════════════════════════════════════════════════

widened_fails_body='## Summary
Improve checkout error handling.

## Background / Motivation
Customers see no feedback when checkout fails, which increases abandonment.

## Proposed Behaviour
Checkout failures are surfaced clearly to the customer.

## Acceptance Criteria
- [ ] Errors are handled gracefully

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | gateway | checkout |
'
body_file="$TMP_ROOT/widened-fails.md"
_write_body "$body_file" "$widened_fails_body"
check_ticket_ready "WIDENED-FAILS" --body "$body_file" --type feature --no-fetch || true
echo "$DOR_MISSING" | jq -e 'index("AC_VAGUE") != null' >/dev/null &&
  _pass "widened vague term 'handled gracefully' fails AC_VAGUE" ||
  _fail "'handled gracefully' should fail AC_VAGUE (got $DOR_MISSING)"

widened_passes_body='## Summary
Improve checkout error handling.

## Background / Motivation
Customers see no feedback when checkout fails, which increases abandonment.

## Proposed Behaviour
Checkout failures are surfaced clearly to the customer.

## Acceptance Criteria
- [ ] A duplicate submission is handled: the API returns 409 with message "already submitted"

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | gateway | checkout |
'
body_file="$TMP_ROOT/widened-passes.md"
_write_body "$body_file" "$widened_passes_body"
check_ticket_ready "WIDENED-PASSES" --body "$body_file" --type feature --no-fetch || true
echo "$DOR_MISSING" | jq -e 'index("AC_VAGUE") == null' >/dev/null &&
  _pass "'handled: returns 409 ...' with a concrete result passes AC_VAGUE" ||
  _fail "a widened term with a concrete result should pass AC_VAGUE (got $DOR_MISSING)"

# audit_ac_testability's own output on the same vague text is unchanged —
# the shared library is never modified by this change.
audit_ac_testability "Errors are handled gracefully" >/dev/null 2>&1 || true
vague_count_alone="${VAGUE_AC_COUNT:-0}"
[ "$vague_count_alone" = "0" ] &&
  _pass "audit_ac_testability alone does not flag 'handled gracefully' (widened terms are DoR-only)" ||
  _fail "audit_ac_testability's own vague detection should be unaffected by this change (got VAGUE_AC_COUNT=$vague_count_alone)"

# ══════════════════════════════════════════════════════════════════════════
# Cache tests (task 8.5)
# ══════════════════════════════════════════════════════════════════════════

# body edit -> recompute + new hash
write_ticket_manifest "HASH-1" "INIT-1" "feature" '[]'
planner_dir="$TMP_ROOT/.ticket-auto/initiatives/INIT-1/tickets/HASH-1/planner"
mkdir -p "$planner_dir"
_write_body "$planner_dir/body.md" "$missing_sections_body"

# resolve_planner_dir must resolve HASH-1 -> $planner_dir. Stub it for this
# section: the real implementation depends on live Planner Context blocks
# this test has no ticket for.
resolve_planner_dir() { echo "$planner_dir"; }

ensure_ticket_readiness "HASH-1" || true
first_status=$DOR_STATUS
first_hash=$(get_ticket_manifest_field "HASH-1" ready 2>/dev/null | jq -r '.body_hash')

_write_body "$planner_dir/body.md" "$full_body"
ensure_ticket_readiness "HASH-1" || true
second_status=$DOR_STATUS
second_hash=$(get_ticket_manifest_field "HASH-1" ready 2>/dev/null | jq -r '.body_hash')

[ "$first_status" = "not-ready" ] && [ "$second_status" = "ready" ] && [ "$first_hash" != "$second_hash" ] &&
  _pass "ensure_ticket_readiness: edited body recomputes and gets a new body_hash" ||
  _fail "expected recompute on body edit (got first=$first_status/$first_hash second=$second_status/$second_hash)"

# unchanged body -> no recompute (stub check_ticket_ready with a counter)
_DOR_CHECK_CALL_COUNT=0
eval "_dor_original_check_ticket_ready() $(declare -f check_ticket_ready | tail -n +2)"
check_ticket_ready() {
  _DOR_CHECK_CALL_COUNT=$((_DOR_CHECK_CALL_COUNT + 1))
  _dor_original_check_ticket_ready "$@"
}
ensure_ticket_readiness "HASH-1" || true
[ "$_DOR_CHECK_CALL_COUNT" = "0" ] &&
  _pass "ensure_ticket_readiness: unchanged body does not recompute" ||
  _fail "ensure_ticket_readiness should not recompute when the body is unchanged (check_ticket_ready called $_DOR_CHECK_CALL_COUNT times)"
check_ticket_ready() { _dor_original_check_ticket_ready "$@"; }

# legacy cache without a body hash is trusted, even once the body would now
# fail a newer hard code.
write_ticket_manifest "LEGACY-1" "INIT-1" "feature" '[]'
set_ticket_readiness "LEGACY-1" "ready" '[]' '[]'
legacy_planner_dir="$TMP_ROOT/.ticket-auto/initiatives/INIT-1/tickets/LEGACY-1/planner"
mkdir -p "$legacy_planner_dir"
_write_body "$legacy_planner_dir/body.md" "$no_scope_body"
resolve_planner_dir() {
  case "$1" in
  LEGACY-1) echo "$legacy_planner_dir" ;;
  HASH-1) echo "$planner_dir" ;;
  esac
}
ensure_ticket_readiness "LEGACY-1" || true
[ "$DOR_STATUS" = "ready" ] &&
  _pass "ensure_ticket_readiness: legacy cache without body_hash is trusted, not recomputed" ||
  _fail "legacy cache without body_hash should be trusted as-is (got $DOR_STATUS)"

# no local body source -> no get_issue call
write_ticket_manifest "NOFETCH-1" "INIT-1" "feature" '[]'
set_ticket_readiness "NOFETCH-1" "ready" '[]' '[]' '{"score": 50, "dimensions": {}, "gaps": [], "body_hash": "sha256:deadbeef"}'
_GET_ISSUE_CALLED=false
get_issue() {
  _GET_ISSUE_CALLED=true
  echo '{}'
}
resolve_planner_dir() { return 1; }
ensure_ticket_readiness "NOFETCH-1" || true
[ "$_GET_ISSUE_CALLED" = "false" ] && [ "$DOR_STATUS" = "ready" ] &&
  _pass "ensure_ticket_readiness: a cache hit with no local body never calls get_issue" ||
  _fail "ensure_ticket_readiness should never call get_issue on a cache hit (called=$_GET_ISSUE_CALLED status=$DOR_STATUS)"
unset -f get_issue

# waiver survives hash-driven recompute
write_ticket_manifest "WAIVE-HASH-1" "INIT-1" "feature" '[]'
waive_planner_dir="$TMP_ROOT/.ticket-auto/initiatives/INIT-1/tickets/WAIVE-HASH-1/planner"
mkdir -p "$waive_planner_dir"
vague_body='## Summary
Ship the widget.

## Background / Motivation
The widget needs shipping because customers are waiting on it.

## Proposed Behaviour
The widget ships and works properly.

## Acceptance Criteria
- [ ] Errors are handled gracefully

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | gateway | widget |
'
_write_body "$waive_planner_dir/body.md" "$vague_body"
resolve_planner_dir() {
  case "$1" in
  WAIVE-HASH-1) echo "$waive_planner_dir" ;;
  LEGACY-1) echo "$legacy_planner_dir" ;;
  HASH-1) echo "$planner_dir" ;;
  esac
}
ensure_ticket_readiness "WAIVE-HASH-1" || true
[ "$DOR_STATUS" = "not-ready" ] || _fail "setup: WAIVE-HASH-1 should be not-ready before waiving (got $DOR_STATUS)"
waive_ticket_readiness_code "WAIVE-HASH-1" "AC_VAGUE" "tester" "wording accepted"

# Edit the body's Scope service name only (still vague AC, hash still
# changes) and recompute.
_write_body "$waive_planner_dir/body.md" "${vague_body/gateway/gateway-v2}"
ensure_ticket_readiness "WAIVE-HASH-1" || true
waived_after=$(get_ticket_manifest_field "WAIVE-HASH-1" ready 2>/dev/null | jq -c '.waived.AC_VAGUE // empty')
[ "$DOR_STATUS" = "ready" ] && [ -n "$waived_after" ] &&
  _pass "ensure_ticket_readiness: waiver survives a hash-driven recompute" ||
  _fail "waiver should survive recomputation (got status=$DOR_STATUS waived=$waived_after)"

unset -f resolve_planner_dir

# ── ensure_ticket_readiness exports DOR_SEMANTIC (dor-semantic-evaluator, task 7.1) ──

# Cache hit: a manifest whose cached `ready.semantic` matches the resolved
# body's hash exports it verbatim, with no recompute.
write_ticket_manifest "SEM-CACHE-1" "INIT-1" "feature" '[]'
sem_planner_dir="$TMP_ROOT/.ticket-auto/initiatives/INIT-1/tickets/SEM-CACHE-1/planner"
mkdir -p "$sem_planner_dir"
sem_body='## Summary
Ship the widget.

## Background / Motivation
The widget needs shipping because customers are waiting on it.

## Proposed Behaviour
The widget ships.

## Acceptance Criteria
- [ ] The widget ships correctly

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | gateway | widget |
'
_write_body "$sem_planner_dir/body.md" "$sem_body"
sem_hash=$(_dor_body_hash "$sem_body")
set_ticket_readiness "SEM-CACHE-1" "ready" '[]' '[]' "{\"body_hash\": \"${sem_hash}\"}"
sem_obj=$(jq -nc --arg h "$sem_hash" '{evaluator:"dor-semantic-v1", checked_at:"2026-09-30T00:00:00Z", body_hash:$h, findings:[], gaps:{}, audit:[], missed:[], score_plausible:true, score_reason:"ok"}')
set_ticket_semantic "SEM-CACHE-1" "$sem_obj"

DOR_SEMANTIC=""
resolve_planner_dir() { echo "$sem_planner_dir"; }
ensure_ticket_readiness "SEM-CACHE-1" || true
[ -n "$DOR_SEMANTIC" ] && [ "$(echo "$DOR_SEMANTIC" | jq -r '.evaluator')" = "dor-semantic-v1" ] &&
  _pass "ensure_ticket_readiness: cache hit exports DOR_SEMANTIC" ||
  _fail "ensure_ticket_readiness: cache hit should export DOR_SEMANTIC (got '$DOR_SEMANTIC')"
unset -f resolve_planner_dir

# Fresh compute (no manifest yet, live body): DOR_SEMANTIC is empty — a
# brand-new verdict has never been evaluated by the semantic pass.
DOR_SEMANTIC="sentinel-should-be-cleared"
ensure_ticket_readiness "SEM-FRESH-1" --body "$sem_planner_dir/body.md" --type feature || true
[ -z "$DOR_SEMANTIC" ] &&
  _pass "ensure_ticket_readiness: fresh compute with no prior semantic leaves DOR_SEMANTIC empty" ||
  _fail "ensure_ticket_readiness: fresh compute should leave DOR_SEMANTIC empty (got '$DOR_SEMANTIC')"

# Unavailable: no body resolvable at all — DOR_SEMANTIC stays empty, same as
# every other DOR_* global on this path.
DOR_SEMANTIC="sentinel-should-be-cleared"
ensure_ticket_readiness "SEM-NEVER-SEEN-1" || true
[ "$DOR_STATUS" = "unavailable" ] && [ -z "$DOR_SEMANTIC" ] &&
  _pass "ensure_ticket_readiness: unavailable path leaves DOR_SEMANTIC empty" ||
  _fail "ensure_ticket_readiness: unavailable path should leave DOR_SEMANTIC empty (status=$DOR_STATUS semantic='$DOR_SEMANTIC')"

# ══════════════════════════════════════════════════════════════════════════
# TEST_DATA_UNSOURCED (issue #505) — the Source grammar from
# ticket-planner/docs/test-data-source.md, read from ticket bodies
# ══════════════════════════════════════════════════════════════════════════

# _td_verdict <normalised-or-raw item text> [legacy] — the classifier's verdict word.
_td_verdict() {
  _dor_td_classify "$(_dor_td_norm "$1")" "${2:-false}" | cut -d$'\037' -f1
}
_td_case() {
  local desc="$1" want="$2" text="$3" legacy="${4:-false}" got
  got=$(_td_verdict "$text" "$legacy")
  [ "$got" = "$want" ] && _pass "classify: $desc -> $want" ||
    _fail "classify: $desc should be $want (got '$got' for '$text')"
}

_td_case "exists with value" sourced "Five invoices. Source: exists:staging seed set"
_td_case "external with value" sourced "Price list. Source: external:pricing team"
_td_case "seeded-by slug" sourced "Five invoices. Source: seeded-by:inv-0-test-data-pack"
_td_case "seeded-by tracker id" sourced "Five invoices. Source: seeded-by:ABC-123"
_td_case "bold marker + backticks + trailing dot" sourced 'Client record. **Source:** `exists:clients.sql`.'
_td_case "underscore-wrapped marker" sourced "Template. _Source:_ external:onboarding team"
_td_case "lowercase marker" sourced "Template. source: external:ops"
_td_case "Verification Plan cell form" sourced "a 1,000-row file (Source: seeded-by:upload-pack)"
_td_case "cell form, exists value with parens" sourced "a client (Source: exists:seed set (clients.sql))"
_td_case "last Source wins (sourced)" sourced "File. Source: generate. Source: exists:/data/file.csv"
_td_case "last Source wins (unsourced)" unsourced "File. Source: exists:/data/file.csv Source: generate"
_td_case "generate" unsourced "A 1,000-row file. Source: generate"
_td_case "exists with empty value" unsourced "A file. Source: exists:"
_td_case "external with empty value" unsourced "A file. Source: external:  ."
_td_case "seeded-by with no slug" unsourced "A file. Source: seeded-by:"
_td_case "seeded-by with a non-slug token" unsourced "A file. Source: seeded-by:pack/spec"
_td_case "unknown kind" unsourced "A file. Source: somewhere:else"
_td_case "Source none on real data" unsourced "Five invoices. Source: none"
_td_case "empty Source" unsourced "Five invoices. Source:"
_td_case "no Source (contract)" unsourced "A client with no configuration"
_td_case "Resource: is not a Source marker" unsourced "API key. Resource: exists:vault"
_td_case "none data" na "none"
_td_case "none data with Source none" na "Test data: none. Source: none"
_td_case "no test data phrasing" na "No special test data needed."
_td_case "n/a cell" na "n/a"
_td_case "legacy: seeded by named script" sourced "Five invoices, seeded by scripts/seed-invoices.sh" true
_td_case "legacy: provided by named party" sourced "The regional price list, provided by the pricing team" true
_td_case "legacy: path" sourced "The sample file at fixtures/clients/sample.csv" true
_td_case "legacy: tracker id" sourced "The dataset produced by CRE-101" true
_td_case "legacy: bare description" unsourced "A 1,000-row valid upload file" true
_td_case "legacy: UTF-8 is not a tracker id" unsourced "A UTF-8 encoded upload file" true
_td_case "legacy: adjective 'seeded' alone is not a source" unsourced "At least 5 seeded invoices" true
_td_case "contract: legacy markers do not count" unsourced "Five invoices, seeded by scripts/seed.sh" false

# Item extraction: list items, prose fallback, Verification Plan cells,
# fenced code ignored, a Source column in a Test Data table.
td_items_body='## Test Data Prerequisites

```
- not an item. Source: generate
```

- First item. Source: generate
1. Second item. Source: exists:here

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Test data needed | Verifiable |
|---|-----------|------------------|------------|
| 1 | One | five invoices (Source: external:finance) | ✓ |
| 2 | Two |  | ✓ |
'
td_items=$(_dor_td_items "$td_items_body")
td_count=$(printf '%s\n' "$td_items" | grep -c . || true)
[ "$td_count" = "3" ] && printf '%s' "$td_items" | grep -q $'^vplan#1\037five invoices (Source: external:finance)$' &&
  ! printf '%s' "$td_items" | grep -q "not an item" &&
  _pass "_dor_td_items: list items + Verification Plan cell, fenced code and blank cells skipped" ||
  _fail "_dor_td_items should yield 3 items (got: $(printf '%s' "$td_items" | tr '\037' '='))"

td_table_body='## Test Data Prerequisites

| Item | Source |
|------|--------|
| Five invoices | seeded-by:inv-pack |
| A client | generate |
'
td_items=$(_dor_td_items "$td_table_body")
printf '%s' "$td_items" | grep -q $'^tdp#1\037Five invoices Source: seeded-by:inv-pack$' &&
  printf '%s' "$td_items" | grep -q $'^tdp#2\037A client Source: generate$' &&
  _pass "_dor_td_items: a Test Data table with a Source column reads that column as the Source" ||
  _fail "_dor_td_items table form (got: $(printf '%s' "$td_items" | tr '\037' '='))"

td_prose_body='## Test Data Prerequisites

At least 5 seeded invoices across two customers.
'
td_items=$(_dor_td_items "$td_prose_body")
[ "$(printf '%s\n' "$td_items" | grep -c .)" = "1" ] &&
  _pass "_dor_td_items: a list-free legacy section reads each prose line as an item" ||
  _fail "_dor_td_items prose fallback (got: $(printf '%s' "$td_items" | tr '\037' '='))"

# Fixture-level severity.
rc=0
check_ticket_ready "TD-20" --body "$FIXTURES_DIR/20-unsourced-legacy.md" --type feature --no-fetch || rc=$?
[ "$rc" = "0" ] && echo "$DOR_ADVISORY" | jq -e 'index("TEST_DATA_UNSOURCED") != null' >/dev/null &&
  [ "$(echo "$DOR_CHECKS" | jq -r '.TEST_DATA_UNSOURCED.class')" = "advisory" ] &&
  [ "$(echo "$DOR_CHECKS" | jq -r '.TEST_DATA_MISSING.pass')" = "false" ] &&
  [ "$(echo "$DOR_CHECKS" | jq -r '.TEST_DATA_UNSEEDED.pass')" = "false" ] &&
  _pass "fixture 20 (issue #505 repro, legacy): TEST_DATA_UNSOURCED advisory, MISSING/UNSEEDED pass" ||
  _fail "fixture 20 should be ready with TEST_DATA_UNSOURCED advisory (rc=$rc adv=$DOR_ADVISORY checks=$(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

rc=0
DOR_STRICT_TEST_DATA=true check_ticket_ready "TD-20-STRICT" --body "$FIXTURES_DIR/20-unsourced-legacy.md" --type feature --no-fetch || rc=$?
[ "$rc" = "1" ] && echo "$DOR_MISSING" | jq -e 'index("TEST_DATA_UNSOURCED") != null' >/dev/null &&
  _pass "fixture 20: DOR_STRICT_TEST_DATA=true promotes legacy TEST_DATA_UNSOURCED to hard" ||
  _fail "fixture 20 under DOR_STRICT_TEST_DATA should be not-ready (rc=$rc missing=$DOR_MISSING)"

rc=0
check_ticket_ready "TD-21" --body "$FIXTURES_DIR/21-unsourced-contract.md" --type feature --no-fetch || rc=$?
td21_detail=$(echo "$DOR_CHECKS" | jq -r '.TEST_DATA_UNSOURCED.detail')
[ "$rc" = "1" ] && echo "$DOR_MISSING" | jq -e 'index("TEST_DATA_UNSOURCED") != null' >/dev/null &&
  [[ "$td21_detail" == *"3 of 5"* ]] && [[ "$td21_detail" == *"tdp#3 (no Source)"* ]] &&
  [[ "$td21_detail" == *"vplan#1 (generate)"* ]] &&
  _pass "fixture 21 (contract): unsourced items are hard by default, detail names each" ||
  _fail "fixture 21 should be not-ready on TEST_DATA_UNSOURCED (rc=$rc missing=$DOR_MISSING detail=$td21_detail)"

rc=0
DOR_STRICT_TEST_DATA_SOURCE=false check_ticket_ready "TD-21-DEMOTE" --body "$FIXTURES_DIR/21-unsourced-contract.md" --type feature --no-fetch || rc=$?
[ "$rc" = "0" ] && echo "$DOR_ADVISORY" | jq -e 'index("TEST_DATA_UNSOURCED") != null' >/dev/null &&
  _pass "fixture 21: DOR_STRICT_TEST_DATA_SOURCE=false demotes the contract case to advisory" ||
  _fail "fixture 21 with DOR_STRICT_TEST_DATA_SOURCE=false should be ready+advisory (rc=$rc adv=$DOR_ADVISORY missing=$DOR_MISSING)"

rc=0
DOR_STRICT_TEST_DATA=true check_ticket_ready "TD-22" --body "$FIXTURES_DIR/22-sourced-contract.md" --type feature --no-fetch || rc=$?
[ "$rc" = "0" ] && [ "$(echo "$DOR_CHECKS" | jq -r '.TEST_DATA_UNSOURCED.pass')" = "false" ] &&
  _pass "fixture 22: every item sourced passes, even under DOR_STRICT_TEST_DATA" ||
  _fail "fixture 22 should be ready with TEST_DATA_UNSOURCED pass=false (rc=$rc checks=$(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"
td22_tu=$(echo "$DOR_DIMENSIONS" | jq -r '.test_uat')
check_ticket_ready "TD-21-SCORE" --body "$FIXTURES_DIR/21-unsourced-contract.md" --type feature --no-fetch || true
td21_tu=$(echo "$DOR_DIMENSIONS" | jq -r '.test_uat')
awk -v a="$td21_tu" -v b="$td22_tu" 'BEGIN { exit !(a < b) }' &&
  _pass "test_uat dimension gives unsourced test data less credit ($td21_tu < $td22_tu)" ||
  _fail "test_uat should be lower for unsourced data (got 21=$td21_tu 22=$td22_tu)"

# Inapplicable when MISSING/UNSEEDED already fired.
check_ticket_ready "TD-12" --body "$FIXTURES_DIR/12-unseeded-test-infra.md" --type feature --no-fetch || true
[ "$(echo "$DOR_CHECKS" | jq -r '.TEST_DATA_UNSOURCED.class')" = "inapplicable" ] &&
  _pass "TEST_DATA_UNSOURCED is inapplicable when TEST_DATA_UNSEEDED fired" ||
  _fail "TEST_DATA_UNSOURCED should be inapplicable on fixture 12 (got $(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

# All-none items: nothing to source.
td_none_file="$TMP_ROOT/td-none.md"
_write_body "$td_none_file" "$(cat "$FIXTURES_DIR/22-sourced-contract.md" | sed '/^## Test Data Prerequisites/,$d')
## Test Data Prerequisites

- Test data: none. Source: none
"
check_ticket_ready "TD-NONE" --body "$td_none_file" --type feature --no-fetch || true
[ "$(echo "$DOR_CHECKS" | jq -r '.TEST_DATA_UNSOURCED.pass')" = "false" ] &&
  _pass "a body whose only test data is none does not fire TEST_DATA_UNSOURCED" ||
  _fail "none-only test data should pass (got $(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

# Log safety: a hostile kind carrying `|`/CR is sanitised in the detail.
td_pipe_file="$TMP_ROOT/td-pipe.md"
_write_body "$td_pipe_file" "$(cat "$FIXTURES_DIR/22-sourced-contract.md" | sed '/^## Test Data Prerequisites/,$d')
## Test Data Prerequisites

- A file. Source: we|ird$(printf '\r'):x
"
check_ticket_ready "TD-PIPE" --body "$td_pipe_file" --type feature --no-fetch || true
td_pipe_detail=$(echo "$DOR_CHECKS" | jq -r '.TEST_DATA_UNSOURCED.detail')
[[ "$td_pipe_detail" != *"|"* ]] && [[ "$td_pipe_detail" != *$'\r'* ]] && [[ "$td_pipe_detail" != *$'\n'* ]] &&
  [[ "$td_pipe_detail" == *"unknown kind"* ]] &&
  _pass "TEST_DATA_UNSOURCED detail is free of | CR LF" ||
  _fail "TEST_DATA_UNSOURCED detail must be log-safe (got '$td_pipe_detail')"

# Detail is capped.
td_many_file="$TMP_ROOT/td-many.md"
{
  sed '/^## Test Data Prerequisites/,$d' "$FIXTURES_DIR/22-sourced-contract.md"
  printf '## Test Data Prerequisites\n\n'
  for i in $(seq 1 14); do printf -- '- Item %s. Source: generate\n' "$i"; done
} >"$td_many_file"
check_ticket_ready "TD-MANY" --body "$td_many_file" --type feature --no-fetch || true
td_many_detail=$(echo "$DOR_CHECKS" | jq -r '.TEST_DATA_UNSOURCED.detail')
[[ "$td_many_detail" == *"and 4 more"* ]] && [[ "$td_many_detail" != *"tdp#11 "* ]] &&
  _pass "TEST_DATA_UNSOURCED detail lists at most 10 items" ||
  _fail "TEST_DATA_UNSOURCED detail should cap at 10 (got '$td_many_detail')"

# ── Review fixes (#505 re-review) ──────────────────────────────────────────

# _td_body <name> <test-data-section> [vplan-section] — fixture 22's
# structural sections with the given Test Data (and optionally Verification
# Plan) sections substituted; echoes the file path.
_td_body() {
  local name="$1" tdp="$2" vplan="${3:-}" f="$TMP_ROOT/td-$1.md"
  {
    sed '/^## Verification Plan/,$d' "$FIXTURES_DIR/22-sourced-contract.md"
    [ -n "$vplan" ] && printf '%s\n\n' "$vplan"
    printf '## Test Data Prerequisites\n\n%s\n' "$tdp"
  } >"$f"
  echo "$f"
}
_td_check() {
  check_ticket_ready "$1" --body "$2" --type feature --no-fetch >/dev/null 2>&1 || true
}
_td_field() { echo "$DOR_CHECKS" | jq -r ".TEST_DATA_UNSOURCED.$1"; }

# 1. List continuation lines and nested sub-bullets belong to their parent.
f=$(_td_body nested '- Five invoices. Source: seeded-by:inv-pack
  - rows include 3 duplicate ids
  - one row has a negative amount
- A client. Source: exists:staging seed set')
_td_check TD-NESTED "$f"
[ "$(_td_field pass)" = "false" ] && [[ "$(_td_field detail)" == *"all 2 "* ]] &&
  _pass "nested sub-bullets under a sourced bullet are part of that item (2 items, all sourced)" ||
  _fail "nested sub-bullets must not become items (got $(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

f=$(_td_body wrapped '- A client with no configuration, used for the
  empty-state check. Source: exists:staging seed set
- Five invoices. Source: seeded-by:inv-pack')
_td_check TD-WRAPPED "$f"
[ "$(_td_field pass)" = "false" ] && [[ "$(_td_field detail)" == *"all 2 "* ]] &&
  _pass "a wrapped bullet whose Source sits on the continuation line is sourced" ||
  _fail "wrapped bullet continuation must join its item (got $(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

f=$(_td_body lazy '- A client with no configuration,
used for the empty-state check. Source: exists:staging seed set')
_td_check TD-LAZY "$f"
[ "$(_td_field pass)" = "false" ] &&
  _pass "an unindented line directly under a bullet continues it" ||
  _fail "lazy continuation must join its item (got $(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

td_items=$(_dor_td_items '## Test Data Prerequisites

- First. Source: generate

Trailing prose after a blank line.
- Second. Source: exists:x')
[ "$(printf '%s\n' "$td_items" | grep -c .)" = "2" ] && ! printf '%s' "$td_items" | grep -q "Trailing prose" &&
  _pass "_dor_td_items: prose after a blank line ends the item and is not an item itself" ||
  _fail "_dor_td_items blank-line boundary (got: $(printf '%s' "$td_items" | tr '\037' '='))"

# 2. Escaped `\|` inside a cell does not shift the Verification Plan columns.
td_items=$(_dor_td_items '## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Test data needed | Verifiable |
|---|-----------|------------|------------------|------------|
| 1 | Role \| gating | ops \| admin | five invoices (Source: seeded-by:inv-pack) | ✓ |
')
[ "$td_items" = $'vplan#1\037five invoices (Source: seeded-by:inv-pack)' ] &&
  _pass "_dor_td_items: an escaped \\| in a cell keeps the Test data needed column aligned" ||
  _fail "_dor_td_items escaped pipe shifted columns (got: $(printf '%s' "$td_items" | tr '\037' '='))"

# 3. seeded-by value cut at whitespace; punctuation after the closing paren.
_td_case "seeded-by value cut at first whitespace" sourced "A file. Source: seeded-by:upload-pack (owns fixtures)"
_td_case "seeded-by slug then prose" sourced "A file. Source: seeded-by:the pack spec"
_td_case "cell form with punctuation after the paren" sourced "a file (Source: seeded-by:pack)."
_td_case "cell form exists, punctuation after the paren" sourced "a client (Source: exists:seed set (clients.sql));"

# 4. Contract detection: only a Source of a known kind.
f=$(_td_body informal '- Five invoices from the nightly billing export. Data source: billing team
- A client with no configuration')
rc=0
check_ticket_ready TD-INFORMAL --body "$f" --type feature --no-fetch >/dev/null 2>&1 || rc=$?
[ "$rc" = "0" ] && [ "$(_td_field class)" = "advisory" ] && [[ "$(_td_field detail)" == *"(legacy)"* ]] &&
  [[ "$(_td_field detail)" == *"1 of 2"* ]] &&
  _pass "informal 'Data source: billing team' does not make a contract body (advisory, ready)" ||
  _fail "informal Source must stay legacy (rc=$rc checks=$(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

f=$(_td_body informal2 '- Five invoices. Source: the staging DB')
rc=0
check_ticket_ready TD-INFORMAL2 --body "$f" --type feature --no-fetch >/dev/null 2>&1 || rc=$?
[ "$rc" = "0" ] && [ "$(_td_field pass)" = "false" ] &&
  _pass "legacy 'Source: the staging DB' counts as an informal source" ||
  _fail "legacy informal Source should pass (rc=$rc checks=$(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

# A Planner Context block alone does NOT make a contract body: a planned
# ticket from before ticket-planner 0.17.0 (no Source fields) stays legacy.
f=$(_td_body planner '- A 1,000-row valid upload file')
printf '\n## Planner Context\n\n**Initiative:** INIT-1\n' >>"$f"
rc=0
check_ticket_ready TD-PLANNER --body "$f" --type feature --no-fetch >/dev/null 2>&1 || rc=$?
[ "$rc" = "0" ] && [ "$(_td_field class)" = "advisory" ] && [[ "$(_td_field detail)" == *"(legacy)"* ]] &&
  _pass "a pre-0.17.0 planned body (Planner Context, no Source) stays legacy and ready" ||
  _fail "Planner Context alone must not make a contract body (rc=$rc checks=$(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

# A 0.17.0-shape planned body (Planner Context + Source fields) is a
# contract body and blocks on its one unsourced item (fixture 23).
rc=0
check_ticket_ready TD-23 --body "$FIXTURES_DIR/23-planned-contract-unsourced.md" --type feature --no-fetch >/dev/null 2>&1 || rc=$?
td23_detail=$(_td_field detail)
[ "$rc" = "1" ] && [ "$(_td_field class)" = "hard" ] && [[ "$td23_detail" == *"(contract)"* ]] &&
  [[ "$td23_detail" == *"vplan#2 (generate)"* ]] && [[ "$td23_detail" == *"tdp#2 (generate)"* ]] &&
  [[ "$td23_detail" != *"#1 "* ]] &&
  _pass "fixture 23: a 0.17.0-shape planned body is a contract body and blocks on its unsourced item" ||
  _fail "fixture 23 should block on TEST_DATA_UNSOURCED (rc=$rc detail=$td23_detail)"

# 5. "not recorded in spec" reason; a Source column in the Verification Plan.
_td_case "#499 placeholder cell" unsourced "not recorded in spec"
[ "$(_dor_td_classify "not recorded in spec" false | cut -d$'\037' -f2)" = "verification note not recorded" ] &&
  _pass "classify: '$_DOR_TD_NOT_RECORDED' reports 'verification note not recorded'" ||
  _fail "classify: not-recorded reason (got '$(_dor_td_classify "not recorded in spec" false | tr '\037' '=')')"

td_items=$(_dor_td_items '## Verification Plan

### Per-Criterion Verification

| # | Criterion | Test data needed | Source | Verifiable |
|---|-----------|------------------|--------|------------|
| 1 | One | five invoices | seeded-by:inv-pack | ✓ |
| 2 | Two | a client | | ✓ |
')
printf '%s' "$td_items" | grep -q $'^vplan#1\037five invoices Source: seeded-by:inv-pack$' &&
  printf '%s' "$td_items" | grep -q $'^vplan#2\037a client$' &&
  _pass "_dor_td_items: a Verification Plan Source column is read as the Source" ||
  _fail "_dor_td_items VP Source column (got: $(printf '%s' "$td_items" | tr '\037' '='))"

f=$(_td_body notrec '- Five invoices. Source: seeded-by:inv-pack' '## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|-----------|------------|-----------------|------------------|-------------------|------------|
| 1 | One | ops | Clients | five invoices (Source: seeded-by:inv-pack) | shown | ✓ |
| 2 | Two | not recorded in spec | Clients | not recorded in spec | not recorded in spec |  |')
_td_check TD-NOTREC "$f"
[[ "$(_td_field detail)" == *"vplan#2 (verification note not recorded)"* ]] &&
  _pass "a #499 'not recorded in spec' row reports its own reason in the detail" ||
  _fail "not-recorded row detail (got $(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

# 6. Dash none-phrasings and the tightened legacy heuristics.
_td_case "em dash cell is none" na "—"
_td_case "en dash cell is none" na "–"
_td_case "legacy: provided by the business" unsourced "Price list, provided by the business" true
_td_case "legacy: seeded by someone" unsourced "Five invoices, seeded by someone" true
_td_case "legacy: supplied by TBD" unsourced "Upload file, supplied by TBD" true
_td_case "legacy: COVID-19 is not a tracker id" unsourced "Patients with a COVID-19 flag" true
_td_case "legacy: SKU-123 is not a tracker id" unsourced "A product with SKU-123" true
_td_case "legacy: long id prefix is not a tracker id" unsourced "Record TRANSACTION-42 exists" true
_td_case "legacy: and/or is not a path" unsourced "One invoice and/or one credit note" true
_td_case "legacy: relative path with ./" sourced "Run ./seed-invoices first" true
_td_case "legacy: absolute path" sourced "The dump at /srv/fixtures/clients" true

# ── Nested sourced children (#505 re-review 2) ───────────────────────────────
# A sub-bullet carrying its own Source is its own item, so a sibling's Source
# can never hide a `generate`; only Source-less children are joined.

# S1: a lead-in parent ending in `:` with one generate and one sourced child.
f=$(_td_body s1 '- Upload files:
  - a valid file. Source: generate
  - an invalid file. Source: exists:/fixtures/bad.csv')
_td_check TD-S1 "$f"
[ "$(_td_field pass)" = "true" ] && [[ "$(_td_field detail)" == *"tdp#1 (generate)"* ]] &&
  [[ "$(_td_field detail)" == *"1 of 2 "* ]] &&
  _pass "S1: a generate child under a lead-in parent is reported (parent dropped, 2 items)" ||
  _fail "S1: sibling Source must not hide generate (got $(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

# S2: an unsourced parent (not a lead-in) with a sourced child stays unsourced.
f=$(_td_body s2 '- A client with no config
  - A 1,000-row file. Source: exists:/x.csv')
_td_check TD-S2 "$f"
[ "$(_td_field pass)" = "true" ] && [[ "$(_td_field detail)" == *"tdp#1 (no Source)"* ]] &&
  [[ "$(_td_field detail)" == *"1 of 2 "* ]] &&
  _pass "S2: an unsourced parent with a sourced child is still unsourced" ||
  _fail "S2: unsourced parent hidden by child (got $(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

# Numbered nesting: a sourced parent with a generate child, and a lead-in
# numbered parent whose children are all sourced.
f=$(_td_body s5 '1. Invoices. Source: seeded-by:inv-pack
   1. five overdue invoices. Source: generate
2. Clients:
   1. one client. Source: exists:staging seed set
   2. one archived client. Source: external:ops team')
_td_check TD-S5 "$f"
[ "$(_td_field pass)" = "true" ] && [[ "$(_td_field detail)" == *"1 of 4 "* ]] &&
  [[ "$(_td_field detail)" == *"tdp#2 (generate)"* ]] &&
  _pass "numbered nesting: a generate child is its own item; a lead-in numbered parent is dropped" ||
  _fail "numbered nesting (got $(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

# Regression: a Source-less sub-bullet is detail of its parent, not an item.
f=$(_td_body nested2 '- Five invoices. Source: seeded-by:inv-pack
  - rows include 3 duplicate ids')
_td_check TD-NESTED2 "$f"
[ "$(_td_field pass)" = "false" ] && [[ "$(_td_field detail)" == *"all 1 "* ]] &&
  _pass "a Source-less sub-bullet (rows include 3 duplicate ids) stays part of its sourced parent" ||
  _fail "Source-less sub-bullet regression (got $(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

# A Source-less grandchild under a sourced child joins that child.
td_items=$(_dor_td_items '## Test Data Prerequisites

- Upload files:
  - a valid file. Source: seeded-by:pack
    - 1,000 rows
  - an invalid file. Source: generate')
[ "$(printf '%s\n' "$td_items" | grep -c .)" = "2" ] &&
  printf '%s' "$td_items" | grep -q $'^tdp#1\037a valid file. Source: seeded-by:pack 1,000 rows$' &&
  _pass "_dor_td_items: a Source-less grandchild joins the sourced child above it" ||
  _fail "_dor_td_items grandchild (got: $(printf '%s' "$td_items" | tr '\037' '='))"

# Unindented lazy line: a new sentence with its own Source is an item; a
# mid-sentence wrap joins.
f=$(_td_body s4 '- A client with no config
The upload file. Source: exists:/x.csv')
_td_check TD-S4 "$f"
[ "$(_td_field pass)" = "true" ] && [[ "$(_td_field detail)" == *"tdp#1 (no Source)"* ]] &&
  _pass "an unindented sentence with its own Source does not hide an unsourced item above it" ||
  _fail "lazy sourced sentence (got $(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

# Optional heuristics: whole-party stopword, 2-10 letter tracker ids, URIs
# and trailing-slash directories.
_td_case "legacy: 'by the business team' is a real party" sourced "Price list, provided by the business team" true
_td_case "legacy: 'by the business.' is a placeholder" unsourced "Price list, provided by the business." true
_td_case "legacy: 6-letter tracker prefix" sourced "The dataset produced by BILLING-123" true
_td_case "legacy: s3 URI is a path" sourced "Dump at s3://bucket/clients" true
_td_case "legacy: https URI is a path" sourced "Template at https://example.com/t.xlsx" true
_td_case "legacy: trailing-slash directory is a path" sourced "Files under fixtures/clients/" true

# ══════════════════════════════════════════════════════════════════════════
# planner-test-data-derivation (task 6.3): TEST_DATA_MISSING/UNSEEDED are
# hard by default on a contract body (except chore/security); an explicit
# DOR_STRICT_TEST_DATA=false demotes; legacy bodies stay advisory.
# Re-baseline note: no existing fixture needed re-baselining — the only
# contract-shaped fixtures (21, 22, 23) all carry a concrete Test Data
# section, so neither code fires on them.
# ══════════════════════════════════════════════════════════════════════════

rc=0
check_ticket_ready "TDD-24" --body "$FIXTURES_DIR/24-contract-no-test-data.md" --type feature --no-fetch || rc=$?
[ "$rc" = "1" ] && echo "$DOR_MISSING" | jq -e 'index("TEST_DATA_MISSING") != null' >/dev/null &&
  [ "$(echo "$DOR_CHECKS" | jq -r '.TEST_DATA_MISSING.class')" = "hard" ] &&
  _pass "contract feature without Test Data (contract only in the Verification Plan) → TEST_DATA_MISSING hard" ||
  _fail "fixture 24 should be not-ready on hard TEST_DATA_MISSING (rc=$rc missing=$DOR_MISSING)"

rc=0
DOR_STRICT_TEST_DATA=false check_ticket_ready "TDD-24-OFF" --body "$FIXTURES_DIR/24-contract-no-test-data.md" --type feature --no-fetch || rc=$?
[ "$rc" = "0" ] && echo "$DOR_ADVISORY" | jq -e 'index("TEST_DATA_MISSING") != null' >/dev/null &&
  _pass "explicit DOR_STRICT_TEST_DATA=false demotes the contract TEST_DATA_MISSING to advisory" ||
  _fail "fixture 24 with DOR_STRICT_TEST_DATA=false should be ready+advisory (rc=$rc adv=$DOR_ADVISORY missing=$DOR_MISSING)"

rc=0
DOR_STRICT_TEST_DATA=true check_ticket_ready "TDD-24-ON" --body "$FIXTURES_DIR/24-contract-no-test-data.md" --type feature --no-fetch || rc=$?
[ "$rc" = "1" ] && echo "$DOR_MISSING" | jq -e 'index("TEST_DATA_MISSING") != null' >/dev/null &&
  _pass "DOR_STRICT_TEST_DATA=true keeps the contract TEST_DATA_MISSING hard" ||
  _fail "fixture 24 with DOR_STRICT_TEST_DATA=true should be not-ready (rc=$rc missing=$DOR_MISSING)"

for td_type in chore security; do
  rc=0
  check_ticket_ready "TDD-24-$td_type" --body "$FIXTURES_DIR/24-contract-no-test-data.md" --type "$td_type" --no-fetch || rc=$?
  echo "$DOR_ADVISORY" | jq -e 'index("TEST_DATA_MISSING") != null' >/dev/null &&
    ! echo "$DOR_MISSING" | jq -e 'index("TEST_DATA_MISSING") != null' >/dev/null &&
    _pass "contract $td_type without Test Data → TEST_DATA_MISSING stays advisory" ||
    _fail "contract $td_type should keep TEST_DATA_MISSING advisory (missing=$DOR_MISSING adv=$DOR_ADVISORY)"
done

rc=0
check_ticket_ready "TDD-02" --body "$FIXTURES_DIR/02-minimal.md" --type feature --no-fetch || rc=$?
[ "$rc" = "0" ] && echo "$DOR_ADVISORY" | jq -e 'index("TEST_DATA_MISSING") != null' >/dev/null &&
  [ "$(echo "$DOR_CHECKS" | jq -r '.TEST_DATA_MISSING.class')" = "advisory" ] &&
  _pass "legacy feature without Test Data stays advisory by default" ||
  _fail "legacy fixture 02 should keep TEST_DATA_MISSING advisory (rc=$rc adv=$DOR_ADVISORY missing=$DOR_MISSING)"

tdd_unseeded_file="$TMP_ROOT/tdd-contract-unseeded.md"
_write_body "$tdd_unseeded_file" "$(cat "$FIXTURES_DIR/24-contract-no-test-data.md")
## Test Data Prerequisites

TBD
"
rc=0
check_ticket_ready "TDD-UNSEEDED" --body "$tdd_unseeded_file" --type feature --no-fetch || rc=$?
[ "$rc" = "1" ] && echo "$DOR_MISSING" | jq -e 'index("TEST_DATA_UNSEEDED") != null' >/dev/null &&
  _pass "contract feature with a placeholder-only Test Data section → TEST_DATA_UNSEEDED hard" ||
  _fail "contract unseeded body should be not-ready on TEST_DATA_UNSEEDED (rc=$rc missing=$DOR_MISSING)"

rc=0
check_ticket_ready "TDD-25" --body "$FIXTURES_DIR/25-td-chore.md" --type chore --no-fetch || rc=$?
[ "$rc" = "0" ] && [ "$DOR_MISSING" = "[]" ] &&
  [ "$(echo "$DOR_CHECKS" | jq -r '.TEST_DATA_UNSOURCED.pass')" = "false" ] &&
  _pass "synthesized test-data chore passes; its Test Data Provided items are not read as needs" ||
  _fail "fixture 25 should be ready with no hard codes (rc=$rc missing=$DOR_MISSING checks=$(echo "$DOR_CHECKS" | jq -c .TEST_DATA_UNSOURCED))"

tdd_chore_notdp="$TMP_ROOT/tdd-chore-no-tdp.md"
_write_body "$tdd_chore_notdp" "$(sed '/^## Test Data Prerequisites/,$d' "$FIXTURES_DIR/25-td-chore.md")"
rc=0
check_ticket_ready "TDD-25-NOTDP" --body "$tdd_chore_notdp" --type chore --no-fetch || rc=$?
[ "$rc" = "0" ] && ! echo "$DOR_MISSING" | jq -e 'index("TEST_DATA_MISSING") != null' >/dev/null &&
  _pass "test-data chore with no Test Data Prerequisites section is still ready" ||
  _fail "test-data chore without the section should be ready (rc=$rc missing=$DOR_MISSING)"

# ── Scenario: the heuristic-miss fixtures the deterministic check cannot see
# (dor-semantic-test-data-gap). Each is ready even under the strict flags
# Refinement passes, which is why the semantic TEST_DATA_GAP backstop exists.
# Fixture 26 carries a Source (a contract body); fixture 27, the composer's
# all-none shape, carries none and is therefore a legacy body.
for td_fx in 26-contract-implied-miss 27-planned-all-none-miss 28-threshold-only-none; do
  rc=0
  DOR_STRICT_TEST_DATA=true DOR_STRICT_VPLAN=true \
    check_ticket_ready "TDG-$td_fx" --body "$FIXTURES_DIR/$td_fx.md" --type feature --no-fetch || rc=$?
  [ "$rc" = "0" ] && [ "$DOR_MISSING" = "[]" ] &&
    _pass "fixture $td_fx: ready under DOR_STRICT_TEST_DATA/DOR_STRICT_VPLAN" ||
    _fail "fixture $td_fx should be ready under the strict flags (rc=$rc missing=$DOR_MISSING)"
done

td_src_contract="" td_src_total=0 td_src_unsourced=0 td_src_detail=""
_dor_test_data_source_state "$(cat "$FIXTURES_DIR/27-planned-all-none-miss.md")" || true
[ "$td_src_contract" = "false" ] &&
  _pass "fixture 27: the all-none planner body is a legacy body (no Source contract)" ||
  _fail "fixture 27 should be legacy (td_src_contract=$td_src_contract)"
check_ticket_ready "TDG-27-codes" --body "$FIXTURES_DIR/27-planned-all-none-miss.md" --type feature --no-fetch || true
if echo "$DOR_MISSING" | jq -e 'index("TEST_DATA_UNSOURCED") == null' >/dev/null &&
  echo "$DOR_ADVISORY" | jq -e 'index("TEST_DATA_UNSOURCED") == null' >/dev/null; then
  _pass "fixture 27: no TEST_DATA_UNSOURCED, hard or advisory"
else
  _fail "fixture 27 should carry no TEST_DATA_UNSOURCED (missing=$DOR_MISSING advisory=$DOR_ADVISORY)"
fi

td_src_contract="" td_src_total=0 td_src_unsourced=0 td_src_detail=""
_dor_test_data_source_state "$(cat "$FIXTURES_DIR/26-contract-implied-miss.md")" || true
[ "$td_src_contract" = "true" ] &&
  _pass "fixture 26: one sourced item makes it a contract body" ||
  _fail "fixture 26 should be a contract body (td_src_contract=$td_src_contract)"

# ── Scenario: every shipped template satisfies INTENT (dor-template-intent-
# and-nav-path) ───────────────────────────────────────────────────────────
# A template used verbatim fails INTENT by design ({...} tokens are
# placeholders), so each token is replaced with distinct filler — one shared
# string would trip the Summary-Jaccard restatement rule. Only INTENT is
# asserted: other codes (e.g. NAV_PATH_MISSING on bug/security, whose
# backticked path is replaced by filler) fail on filler text by design.
TEMPLATES_DIR="$LIB_DIR/../templates"
_render_template() {
  awk 'f { while (match($0, /\{[^}]*\}/)) { n++; $0 = substr($0, 1, RSTART - 1) "filler" n " alpha" n " beta" n " gamma" n substr($0, RSTART + RLENGTH) } print } /^---$/ { f = 1 }' "$1"
}
_intent_ok() {
  local id="$1" file="$2" type="$3"
  check_ticket_ready "$id" --body "$file" --type "$type" --no-fetch >/dev/null 2>&1 || true
  ! echo "$DOR_MISSING" | jq -e 'index("INTENT_MISSING") != null' >/dev/null
}
for tpl_type in feature improvement chore security bug; do
  tpl_file="$TMP_ROOT/tpl-$tpl_type.md"
  _render_template "$TEMPLATES_DIR/$tpl_type.md" >"$tpl_file"
  _intent_ok "TPL-$tpl_type" "$tpl_file" "$tpl_type" &&
    _pass "template $tpl_type filled under its own headings passes INTENT" ||
    _fail "template $tpl_type should pass INTENT (missing=$DOR_MISSING)"
done

# US spelling of the improvement outcome heading is accepted too.
tpl_us="$TMP_ROOT/tpl-improvement-us.md"
_render_template "$TEMPLATES_DIR/improvement.md" | sed 's/^## Desired Behaviour$/## Desired Behavior/' >"$tpl_us"
grep -q '^## Desired Behavior$' "$tpl_us" && _intent_ok "TPL-improvement-us" "$tpl_us" improvement &&
  _pass "improvement with US-spelled '## Desired Behavior' passes INTENT" ||
  _fail "US-spelled Desired Behavior should pass INTENT (missing=$DOR_MISSING)"

# A non-bug body with only a Summary still fails INTENT.
tpl_summary_only="$TMP_ROOT/tpl-summary-only.md"
_write_body "$tpl_summary_only" '## Summary
Implement password reset.
'
! _intent_ok "TPL-SUMMARY-ONLY" "$tpl_summary_only" feature &&
  _pass "summary-only body still fails INTENT" ||
  _fail "summary-only body should fail INTENT (missing=$DOR_MISSING)"

# ── Scenario: Verification Plan column header is not a navigation path ──

nav_base='## Summary
Lock a completed period so its documents cannot change.

## Background / Motivation
Firm admins edit periods after sign-off, which breaks the audit trail they hand to regulators.

## Proposed Behaviour
An admin can lock a completed period; while locked, its documents are read-only for every role.

## Acceptance Criteria
- [ ] Locking a completed period shows the period as Locked

## Test User
`admin` — password `admin`

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | period-detail |
'
nav_vplan_empty='
## Verification Plan
| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|---|---|---|---|---|---|
| 1 | Lock a completed period | firm admin |  | 1 completed period | period shows Locked | ✓ |
'
nav_vplan_filled='
## Verification Plan
| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|---|---|---|---|---|---|
| 1 | Lock a completed period | firm admin | Clients > Matters > Period detail | 1 completed period | period shows Locked | ✓ |
'
nav_file="$TMP_ROOT/nav-header-only.md"
_write_body "$nav_file" "$nav_base$nav_vplan_empty"
check_ticket_ready "NAV-HDR" --body "$nav_file" --type feature --no-fetch >/dev/null 2>&1 || true
echo "$DOR_MISSING" | jq -e 'index("NAV_PATH_MISSING") != null' >/dev/null &&
  _pass "FE body whose only nav evidence is the Verification Plan column header → NAV_PATH_MISSING" ||
  _fail "column header alone should fire NAV_PATH_MISSING (got $DOR_MISSING)"

_write_body "$nav_file" "$nav_base
## Navigation Path
Clients > Matters > Period detail
$nav_vplan_empty"
check_ticket_ready "NAV-HEAD" --body "$nav_file" --type feature --no-fetch >/dev/null 2>&1 || true
echo "$DOR_MISSING" | jq -e 'index("NAV_PATH_MISSING") == null' >/dev/null &&
  _pass "FE body with a real ## Navigation Path section passes NAV_PATH_MISSING" ||
  _fail "a real Navigation Path section should pass (got $DOR_MISSING)"

_write_body "$nav_file" "$nav_base$nav_vplan_filled"
check_ticket_ready "NAV-CELL" --body "$nav_file" --type feature --no-fetch >/dev/null 2>&1 || true
echo "$DOR_MISSING" | jq -e 'index("NAV_PATH_MISSING") == null' >/dev/null &&
  _pass "FE body with the path only in a Verification Plan cell passes NAV_PATH_MISSING" ||
  _fail "a filled Verification Plan cell should pass (got $DOR_MISSING)"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
