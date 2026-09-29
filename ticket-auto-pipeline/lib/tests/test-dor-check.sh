#!/usr/bin/env bash
# test-dor-check.sh — unit tests for lib/dor-check.sh (dor-readiness-gate-
# foundation, tasks 4.11/4.14).
# Usage: bash test-dor-check.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# notes-parse.sh is sourced here (not by dor-check.sh itself — see its
# sourcing block for why) so get_test_users_by_role is available for the
# strict-catalog fixtures below, mirroring how gate-check.sh already
# sources it under its own errexit before dor-check.sh runs.
source "$LIB_DIR/notes-parse.sh"
source "$LIB_DIR/dor-check.sh"

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

full_body='## Acceptance Criteria
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

missing_sections_body='## Acceptance Criteria
- [ ] Feature works

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |
'

backend_only_body='## Acceptance Criteria
- [ ] API returns 200

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | gateway | api  |
'

no_scope_body='## Acceptance Criteria
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

unresolved_body='## Acceptance Criteria
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
  _pass "ensure_ticket_readiness: live verdict is cached on the manifest" ||
  _fail "ensure_ticket_readiness should cache the computed verdict (got $cached_ready_json)"

# Overwrite the body file with a ready body — the SECOND call must still
# return the cached not-ready verdict (no recomputation) rather than the
# fresh (now-ready) verdict the new body would produce.
_write_body "$body_file" "$full_body"
rc=0
ensure_ticket_readiness "CACHE-1" --body "$body_file" || rc=$?
[ "$rc" = "1" ] && [ "$DOR_STATUS" = "not-ready" ] &&
  _pass "ensure_ticket_readiness: cached verdict reused without recomputation" ||
  _fail "ensure_ticket_readiness should reuse the cached verdict (got rc=$rc status=$DOR_STATUS)"

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

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
