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
)
declare -A FIXTURE_STATUS=(
  ["01-excellent.md"]=ready ["02-minimal.md"]=ready ["03-missing-intent.md"]=not-ready
  ["04-useless-scope.md"]=ready ["05-vague-ac.md"]=not-ready ["06-backend-no-verification.md"]=ready
  ["07-fe-no-test-user.md"]=not-ready ["08-fe-no-nav-path.md"]=not-ready ["09-backend-no-ui.md"]=ready
  ["10-bug-no-expected-actual.md"]=not-ready ["11-contradictory-acs.md"]=ready ["12-unseeded-test-infra.md"]=ready
  ["13-impl-only-acs.md"]=ready ["14-typo-fix.md"]=ready ["15-impl-guide-no-behavior.md"]=ready
  ["16-edge-cases-missing-core.md"]=ready ["17-self-verifying-no-vplan.md"]=ready
  ["18-backend-twin.md"]=ready ["19-padding.md"]=ready
)
declare -A FIXTURE_HARD=(
  ["03-missing-intent.md"]=INTENT_MISSING ["05-vague-ac.md"]=AC_VAGUE ["07-fe-no-test-user.md"]=TEST_USER_MISSING
  ["08-fe-no-nav-path.md"]=NAV_PATH_MISSING ["10-bug-no-expected-actual.md"]=REPRO_NO_EXPECTED_ACTUAL
)
declare -A FIXTURE_ADVISORY=(
  ["02-minimal.md"]=TEST_DATA_MISSING ["06-backend-no-verification.md"]=VERIFICATION_REQUIRED_NOT_SELF_VERIFYING
  ["12-unseeded-test-infra.md"]=TEST_USER_UNRESOLVED ["13-impl-only-acs.md"]=AC_IMPLEMENTATION_ONLY
  ["15-impl-guide-no-behavior.md"]=AC_IMPLEMENTATION_ONLY
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

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
