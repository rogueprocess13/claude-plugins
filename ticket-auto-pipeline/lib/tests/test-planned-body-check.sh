#!/usr/bin/env bash
# test-planned-body-check.sh — unit tests for lib/planned-ticket-body-check.sh
# Usage: bash test-planned-body-check.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ───────────────────────────────────────────────────
if ! declare -f get_issue >/dev/null 2>&1; then
  get_issue() {
    echo "get_issue: CI stub" >&2
    echo '{"description":"","labels":{"nodes":[]}}'
  }
fi
if ! declare -f _plog >/dev/null 2>&1; then
  _plog() { :; }
fi
if ! declare -f hb_gate >/dev/null 2>&1; then
  hb_gate() { :; }
fi

export REPOS_ROOT="${REPOS_ROOT:-/tmp/test-repos-root}"

source "$LIB_DIR/planned-ticket-check.sh"
source "$LIB_DIR/planner-artifacts.sh"
source "$LIB_DIR/planned-ticket-body-check.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_run_check() {
  local name="$1"
  local expected_exit="$2"
  local expected_missing="$3"
  shift 3
  check_planned_body "$@" 2>/dev/null || true
  if [ "$BODY_CHECK_EXIT_CODE" = "$expected_exit" ]; then
    if [ -n "$expected_missing" ]; then
      if echo "$BODY_CHECK_MISSING" | grep -q "$expected_missing"; then
        echo "PASS: $name (exit=$BODY_CHECK_EXIT_CODE missing='$BODY_CHECK_MISSING')"
        ((PASS++)) || true
      else
        echo "FAIL: $name (expected missing='$expected_missing', got '$BODY_CHECK_MISSING')"
        ((FAIL++)) || true
      fi
    else
      echo "PASS: $name (exit=$BODY_CHECK_EXIT_CODE)"
      ((PASS++)) || true
    fi
  else
    echo "FAIL: $name (expected exit $expected_exit, got $BODY_CHECK_EXIT_CODE, missing='$BODY_CHECK_MISSING')"
    ((FAIL++)) || true
  fi
}

# ── Test bodies ───────────────────────────────────────────────────────────────

COMPLETE_BUG_BODY='## Acceptance Criteria
- [ ] Save button works after form is filled
- [ ] Error toast appears on validation failure
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | handover-form |
## Steps to Reproduce
1. Log in as admin@example.com (password: admin)
2. Navigate via `Handover > Pending`
3. Click on handover #123
4. Observe that save button is disabled
## Test Data Prerequisites
At least one handover in status Pending assigned to test user.'

COMPLETE_FEATURE_BODY='## Acceptance Criteria
- [ ] New "Export CSV" button appears on handover list
- [ ] Clicking button downloads CSV with correct columns
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | handover-list |
| BE    | handover | export-service |
## Navigation Path
`Handover > List > Export CSV`
## Test Data Prerequisites
None — no acceptance criterion needs test data.'

FEATURE_MISSING_NAV='## Acceptance Criteria
- [ ] Feature works as expected
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |'

BUG_MISSING_REPRO='## Acceptance Criteria
- [ ] Bug is fixed
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |'

# ── Tests ─────────────────────────────────────────────────────────────────────

# 1. Complete bug body → exit 0
_run_check "complete bug body passes" 0 "" \
  "TEST-1" "bug" "$COMPLETE_BUG_BODY" "true"

# 2. Complete feature body → exit 0
_run_check "complete feature body passes" 0 "" \
  "TEST-2" "feature" "$COMPLETE_FEATURE_BODY" "true"

# 3. Feature missing Navigation Path → exit 1
_run_check "feature missing Nav Path fails" 1 "Navigation Path" \
  "TEST-3" "feature" "$FEATURE_MISSING_NAV" "true"

# 4. Bug missing Steps to Reproduce → exit 1
_run_check "bug missing repro steps fails" 1 "Steps to Reproduce" \
  "TEST-4" "bug" "$BUG_MISSING_REPRO" "true"

# 5. Empty body → exit 2 (body_source_unavailable)
_run_check "empty body → exit 2" 2 "body_source_unavailable" \
  "TEST-5" "bug" "" "true"

# 6. Plane body.md preferred over description (when plane exists)
# tracker-planner-and-fallback-cutover (3.3): resolve_planner_dir resolves
# {INIT} from the local initiative index alone now — no description
# parsing — so the index entry must exist for TEST-6 or resolution fails
# and body.md is never found.
TEST_DIR="$REPOS_ROOT/.ticket-auto/initiatives/INIT-42/tickets/TEST-6/planner"
mkdir -p "$TEST_DIR" "$REPOS_ROOT/.ticket-auto/initiatives/_index"
echo "INIT-42" >"$REPOS_ROOT/.ticket-auto/initiatives/_index/TEST-6.initiative"
echo "$COMPLETE_BUG_BODY" >"$TEST_DIR/body.md"
# Provide a desc with Planner Context (so plane resolves) but thin body content that
# would fail if used — the plane body.md should be preferred instead.
PLANE_DESC_WITH_THIN_BODY='## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-42
**Epic:** EPIC-1
**Confidence:** 0.92
**Strategy:** Conservative
**Decision:** Fix bug
**Affected Services:** collector
**Target Symbols:** DebtCollector.collect:src/collector.ts:42
**Pre-approved:** true
**Generated:** 2026-07-01T12:00:00Z
**Regenerate:** false

thin description body — this should NOT be used because plane body.md exists'
_run_check "plane body preferred — complete bug passes even with thin desc" 0 "" \
  "TEST-6" "bug" "$PLANE_DESC_WITH_THIN_BODY" "true"

# 7. chore type — universal sections only (no Nav Path required)
CHORE_BODY='## Acceptance Criteria
- [ ] Dependencies updated
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| Infra | ci      | pipeline |'
_run_check "chore body with universal sections passes" 0 "" \
  "TEST-7" "chore" "$CHORE_BODY" "true"

# 8. Security type — universal sections only
_run_check "security body with universal sections passes" 0 "" \
  "TEST-8" "security" "$CHORE_BODY" "true"

# 9. Complete improvement body (requires Nav Path) — passes
IMPROVEMENT_BODY='## Acceptance Criteria
- [ ] Filter persists across page navigation
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | handover-list |
## Navigation Path
`Handover > List > Apply Filter`
## Test Data Prerequisites
None — no acceptance criterion needs test data.'
_run_check "complete improvement body passes" 0 "" \
  "TEST-9" "improvement" "$IMPROVEMENT_BODY" "true"

# 10. Improvement missing Nav Path → exit 1
IMPROVEMENT_MISSING_NAV='## Acceptance Criteria
- [ ] Pagination controls added
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | user-list |'
_run_check "improvement missing Nav Path fails" 1 "Navigation Path" \
  "TEST-10" "improvement" "$IMPROVEMENT_MISSING_NAV" "true"

# 11. Backend-only feature body (Scope has BE, no FE) — no Test User/Nav Path
# required, passes without them (WIL-78 regression case).
BACKEND_ONLY_FEATURE_BODY='## Acceptance Criteria
- [ ] preparation_status transitions to needs_review on low-confidence split
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | ledgerly-worker | pdfsplit |
## Test Data Prerequisites
None — no acceptance criterion needs test data.'
_run_check "backend-only feature body skips Test User/Nav Path" 0 "" \
  "TEST-11" "feature" "$BACKEND_ONLY_FEATURE_BODY" "true"

# 12. Feature body with no Scope table at all — ambiguous, NOT assumed
# backend-only, so Test User/Nav Path/Scope are all still required.
NO_SCOPE_FEATURE_BODY='## Acceptance Criteria
- [ ] Feature works as expected'
_run_check "feature with no Scope table stays ambiguous, requires Test User" 1 "Test User" \
  "TEST-12" "feature" "$NO_SCOPE_FEATURE_BODY" "true"
_run_check "feature with no Scope table stays ambiguous, requires Nav Path" 1 "Navigation Path" \
  "TEST-12b" "feature" "$NO_SCOPE_FEATURE_BODY" "true"

# 13. Backend-only bug body — Test User skipped, but Steps to Reproduce
# (type-specific, not layer-gated) is still required.
BACKEND_ONLY_BUG_BODY='## Acceptance Criteria
- [ ] Dedup no longer double-counts hash collisions
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | ledgerly-worker | dedup |
## Test Data Prerequisites
Two fixtures with identical content hash.'
_run_check "backend-only bug skips Test User but still needs repro steps" 1 "Steps to Reproduce" \
  "TEST-13" "bug" "$BACKEND_ONLY_BUG_BODY" "true"

# 14. tracker-local-facts-read-migration (task 5.4): manifest presence alone
# (no live "planned" label) must still let plane resolution attempt fire on
# the live-fetch path (no inline description/has_planned_label args).
source "$LIB_DIR/manifest-write.sh"
TEST14_DIR="$REPOS_ROOT/.ticket-auto/initiatives/INIT-77/tickets/TEST-14/planner"
mkdir -p "$TEST14_DIR"
echo "$COMPLETE_BUG_BODY" >"$TEST14_DIR/body.md"
write_ticket_manifest "TEST-14" "INIT-77" "bug" '[]' >/dev/null

test_manifest_only_plane_resolution() {
  local orig_get_issue
  orig_get_issue=$(declare -f get_issue 2>/dev/null || true)
  get_issue() {
    echo '{"description":"thin description — should not be used","labels":{"nodes":[{"name":"bug"}]}}'
  }
  check_planned_body "TEST-14" "bug" 2>/dev/null || true
  local rc="$BODY_CHECK_EXIT_CODE"
  if [ -n "$orig_get_issue" ]; then
    eval "$orig_get_issue"
  fi
  [ "$rc" = "0" ]
}
_run "manifest only — plane body resolves with no live planned label" test_manifest_only_plane_resolution

# 15. planner-test-data-derivation (task 6.4): Test Data Prerequisites is
# required on every type except chore and security. A feature/improvement
# needs a real `## Test Data…` heading — the Verification Plan's own
# `Test data needed` column header must not satisfy it.
FEATURE_NO_TDP='## Acceptance Criteria
- [ ] Clicking Export downloads a CSV with 5 rows
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | handover-list |
## Navigation Path
`Handover > List > Export CSV`
## Verification Plan
### Per-Criterion Verification
| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|---|---|---|---|---|---|
| 1 | Export | admin | Handover > List | five handovers (Source: seeded-by:handover-test-data) | CSV has 5 rows | ✓ |'
_run_check "feature without Test Data Prerequisites fails" 1 "Test Data Prerequisites" \
  "TEST-15" "feature" "$FEATURE_NO_TDP" "true"
_run_check "improvement without Test Data Prerequisites fails" 1 "Test Data Prerequisites" \
  "TEST-15b" "improvement" "$FEATURE_NO_TDP" "true"
_run_check "chore without Test Data Prerequisites passes" 0 "" \
  "TEST-15c" "chore" "$FEATURE_NO_TDP" "true"
_run_check "security without Test Data Prerequisites passes" 0 "" \
  "TEST-15d" "security" "$FEATURE_NO_TDP" "true"

# 16. An empty Test Data heading does not count; neither does one inside a
# fenced code block.
FEATURE_EMPTY_TDP="$FEATURE_NO_TDP
## Test Data Prerequisites

## Notes
nothing"
_run_check "feature with an empty Test Data heading fails" 1 "Test Data Prerequisites" \
  "TEST-16" "feature" "$FEATURE_EMPTY_TDP" "true"
FEATURE_FENCED_TDP="$FEATURE_NO_TDP
\`\`\`
## Test Data Prerequisites
- example only
\`\`\`"
_run_check "feature with a fenced Test Data heading fails" 1 "Test Data Prerequisites" \
  "TEST-16b" "feature" "$FEATURE_FENCED_TDP" "true"
FEATURE_NONE_TDP="$FEATURE_NO_TDP
## Test Data Prerequisites
None — no acceptance criterion needs test data."
_run_check "feature with the composer's None line passes" 0 "" \
  "TEST-16c" "feature" "$FEATURE_NONE_TDP" "true"

# 17. Navigation path evidence must be an actual click path
# (dor-template-intent-and-nav-path). The bare phrase — including the
# Verification Plan's "Navigation path" column header — never counts.
_nav_yes() { _has_section_nav_path "$1"; }
_nav_no() { ! _has_section_nav_path "$1"; }
NAV_VPLAN_EMPTY='## Verification Plan
| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|---|---|---|---|---|---|
| 1 | Export | admin |  | none | CSV has 5 rows | ✓ |'
NAV_VPLAN_NA='## Verification Plan
| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|---|---|---|---|---|---|
| 1 | Export | admin | n/a | none | CSV has 5 rows | ✓ |

## Other table
| a | b | c | d |
|---|---|---|---|
| 1 | 2 | 3 | x > y |'
_run "nav: column header only is not a path" _nav_no "$NAV_VPLAN_EMPTY"
_run "nav: prose mention is not a path" _nav_no 'The navigation path is TBD for now.'
_run "nav: heading with only TBD is not a path" _nav_no $'## Navigation Path\n\nTBD\n\n## Notes\nnone'
_run "nav: heading with only - is not a path" _nav_no $'## Navigation Path\n-\n## Notes\nx'
_run "nav: heading with only --- is not a path" _nav_no $'## Navigation Path\n---\n## Notes\nx'
_run "nav: heading with only '- TBD' is not a path" _nav_no $'## Navigation Path\n- TBD\n## Notes\nx'
_run "nav: n/a cells plus another table's same column is not a path" _nav_no "$NAV_VPLAN_NA"
_run "nav: real heading content is a path" _nav_yes $'## Navigation Path\nClients > Matters > Period detail'
_run "nav: ### heading with content is a path" _nav_yes $'### Navigation Path\nClients > Matters'
_run "nav: ## heading with trailing colon is a path" _nav_yes $'## Navigation Path:\nClients > Matters'
_run "nav: bold label with text is a path" _nav_yes '**Navigation Path:** Clients > Matters'
_run "nav: backticked click path is a path" _nav_yes 'Navigate via `Clients > Matters`'
_run "nav: filled Verification Plan cell is a path" _nav_yes "${NAV_VPLAN_EMPTY/|  |/| Clients > Matters > Period detail |}"

FEATURE_HEADER_ONLY_NAV='## Acceptance Criteria
- [ ] Clicking Export downloads a CSV with 5 rows
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | handover-list |
## Test Data Prerequisites
- five handovers (Source: seeded-by:handover-test-data)
'"$NAV_VPLAN_EMPTY"
_run_check "feature with only the Navigation path column header fails" 1 "Navigation Path" \
  "TEST-17" "feature" "$FEATURE_HEADER_ONLY_NAV" "true"

# ── Large bodies under pipefail (issue #580) ─────────────────────────────────
# `echo "$body" | grep -q` on a body larger than the pipe buffer lets grep
# exit on an early match, kills echo with SIGPIPE, and pipefail (set at the
# top of this file, as in gate-check.sh) turns a found section into "missing".
# Each detector is run several times because the failure is scheduling-bound.
BIG_PAD=$(printf 'x%.0s' $(seq 1 2000))
BIG_PAD=$(for _i in $(seq 1 100); do printf '%s\n' "$BIG_PAD"; done)
BIG_BODY='## Acceptance Criteria
- [ ] Export works
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |
## Navigation Path
Clients > Matters
Navigate via `Clients > Matters`
| Step | Navigation path |
| ---- | --------------- |
| 1    | Clients > Matters |
## Test Data Prerequisites
- five handovers
## Steps to Reproduce
1. Log in as admin
## Notes
'"$BIG_PAD"
_big_repeat() {
  local i
  for i in 1 2 3 4 5 6 7 8; do "$@" "$BIG_BODY" || return 1; done
}
_big_nav_rule4() {
  # Rule 4 only: strip every other nav evidence, keep the table + padding.
  local b=$'| Step | Navigation path |\n| ---- | --------------- |\n| 1    | Clients > Matters |\n'"$BIG_PAD"
  _has_section_nav_path "$b"
}
_big_layers() { [ "$(_scope_layers "$1")" = "FE " ]; }
_run "big body (>64KB): body is actually larger than a pipe buffer" test "${#BIG_BODY}" -gt 131072
_run "big body: AC detected under pipefail" _big_repeat _has_section_ac
_run "big body: Test User detected under pipefail" _big_repeat _has_section_test_user
_run "big body: Scope detected under pipefail" _big_repeat _has_section_scope
_run "big body: Scope layers extracted under pipefail" _big_repeat _big_layers
_run "big body: Navigation Path detected under pipefail" _big_repeat _has_section_nav_path
_run "big body: nav table column (rule 4) detected under pipefail" _big_nav_rule4
_run "big body: Test Data heading detected under pipefail" _big_repeat _has_heading_test_data
_run "big body: Test Data detected under pipefail" _big_repeat _has_section_test_data
_run "big body: repro steps detected under pipefail" _big_repeat _has_section_repro_steps
_big_full_check() {
  local i
  for i in 1 2 3 4 5; do
    check_planned_body "TEST-BIG" "feature" "$BIG_BODY" "true" 2>/dev/null || true
    [ "$BODY_CHECK_EXIT_CODE" = "0" ] || return 1
  done
}
_run "big feature body passes check_planned_body under pipefail" _big_full_check

# Cleanup
rm -rf "$REPOS_ROOT/.ticket-auto"

# ── Summary ───────────────────────────────────────────────────────────────────

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
