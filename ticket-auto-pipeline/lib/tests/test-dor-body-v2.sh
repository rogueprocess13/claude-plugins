#!/usr/bin/env bash
# test-dor-body-v2.sh — the ticket-body-v2 readiness codes (GitHub #773,
# lib/dor-body-v2.sh). For every code: an absent or broken section warns by
# default, blocks under its DOR_STRICT_* switch, a body that does not carry
# the contract is not judged, and a complete body is clean.
# Usage: bash test-dor-body-v2.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LIB_DIR/dor-check.sh"

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
assert_eq() {
  if [ "$2" = "$3" ]; then
    _pass "$1"
  else
    _fail "$1 (got '$2', want '$3')"
  fi
}

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

unset DOR_STRICT_VERIFY_MODE DOR_STRICT_EDGE_CASES DOR_STRICT_AC_SHAPE DOR_STRICT_SCOPE_FILES
unset DOR_STRICT_TEST_DATA DOR_STRICT_VPLAN DOR_STRICT_CATALOG DOR_STRICT_AC_IMPL DOR_STRICT_VERIFICATION

V2_CODES="VERIFY_MODE_INVALID EDGE_CASES_MISSING AC_UNTAGGED AC_COUNT_HIGH AC_POST_MERGE_STATE SCOPE_TC_MISMATCH"

# ── Bodies ───────────────────────────────────────────────────────────────

# A complete body: every ticket-body-v2 rule holds.
read -r -d '' COMPLETE <<'BODY' || true
## Summary
Show a clear error when sign-in fails.

## Background / Motivation
People who mistype a password see a blank page and cannot tell what went wrong, so they contact support.

## Proposed Behaviour
The sign-in page shows the message "Invalid email or password" and keeps the email field filled in.

## Verify Mode

**Verify mode:** browser — a person signs in on a page.

## Technical Context
The form lives in `frontend/src/login.js`. The message text comes from `frontend/src/messages.json`, which this ticket only reads.

## Errors and Edge Cases
- **Failure** — a 5xx response shows "Sign-in is unavailable, try again".
- **Check order** — Not applicable — one status only.
- **Empty or malformed input** — an empty password shows "Password is required".
- **Late or concurrent responses** — a second click while the request runs is ignored.
- **Unauthorised viewer** — Not applicable — the page is public.

## Acceptance Criteria
- [ ] [live] Signing in with a wrong password shows "Invalid email or password"
- [ ] [live] An empty password shows "Password is required"
- [ ] [unit] A 503 response shows "Sign-in is unavailable, try again"

## Test User
`admin` — password `admin`

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | `frontend/src/login.js`, `frontend/src/messages.json` (read-only) |

## Navigation Path
`Home > Sign in`
BODY

# The same ticket written before the contract: none of the three markers.
read -r -d '' LEGACY <<'BODY' || true
## Summary
Show a clear error when sign-in fails.

## Background / Motivation
People who mistype a password see a blank page and cannot tell what went wrong, so they contact support.

## Proposed Behaviour
The sign-in page shows the message "Invalid email or password" and keeps the email field filled in.

## Technical Context
The form lives in `frontend/src/login.js` and reads `frontend/src/other.js`.

## Acceptance Criteria
- [ ] Signing in with a wrong password shows "Invalid email or password" once merged
- [ ] An empty password shows "Password is required"

## Test User
`admin` — password `admin`

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |

## Navigation Path
`Home > Sign in`
BODY

_n=0
# _check <body> [type] — runs the check with the current environment.
_check() {
  _n=$((_n + 1))
  local f="$TMP_ROOT/body-${_n}.md"
  printf '%s\n' "$1" >"$f"
  RC=0
  check_ticket_ready "V2-${_n}" --body "$f" --type "${2:-feature}" --no-fetch || RC=$?
}
_in() { jq -e --arg c "$2" 'index($c) != null' <<<"$1" >/dev/null 2>&1; }
_class() { jq -r --arg c "$1" '.[$c].class // "absent"' <<<"$DOR_CHECKS"; }
_pass_of() { jq -r --arg c "$1" '.[$c].pass | tostring' <<<"$DOR_CHECKS"; }

# _drop_section <body> <heading> — the body without that `## ` section.
_drop_section() {
  awk -v h="## $2" '$0 == h { skip = 1; next } skip && /^## / { skip = 0 } !skip { print }' <<<"$1"
}

# _expect_code <label> <code> <switch> <body> [type] — the three-way contract
# of one code: advisory by default, hard under its own switch only.
_expect_code() {
  local label="$1" code="$2" sw="$3" body="$4" type="${5:-feature}" other
  _check "$body" "$type"
  if [ "$RC" -eq 0 ] && [ "$DOR_STATUS" = "ready" ] && _in "$DOR_ADVISORY" "$code" && ! _in "$DOR_MISSING" "$code"; then
    _pass "$label: $code warns by default, ticket stays ready"
  else
    _fail "$label: $code should be advisory (rc=$RC status=$DOR_STATUS missing=$DOR_MISSING advisory=$DOR_ADVISORY)"
  fi
  assert_eq "$label: $code is recorded advisory" "$(_class "$code")" "advisory"

  export "$sw=true"
  _check "$body" "$type"
  unset "$sw"
  if [ "$RC" -eq 1 ] && [ "$DOR_STATUS" = "not-ready" ] && _in "$DOR_MISSING" "$code" && ! _in "$DOR_ADVISORY" "$code"; then
    _pass "$label: $code blocks under $sw=true"
  else
    _fail "$label: $code should block under $sw (rc=$RC status=$DOR_STATUS missing=$DOR_MISSING advisory=$DOR_ADVISORY)"
  fi

  export "$sw=false"
  _check "$body" "$type"
  unset "$sw"
  if [ "$RC" -eq 0 ] && _in "$DOR_ADVISORY" "$code"; then
    _pass "$label: $sw=false is the default"
  else
    _fail "$label: $sw=false should stay advisory (rc=$RC missing=$DOR_MISSING)"
  fi

  # Every other switch leaves this code advisory.
  for other in DOR_STRICT_VERIFY_MODE DOR_STRICT_EDGE_CASES DOR_STRICT_AC_SHAPE DOR_STRICT_SCOPE_FILES; do
    [ "$other" = "$sw" ] && continue
    export "$other=true"
    _check "$body" "$type"
    unset "$other"
    if _in "$DOR_MISSING" "$code"; then
      _fail "$label: $other must not promote $code"
    fi
  done
  _pass "$label: only $sw promotes $code"
}

echo "--- 1. a complete ticket-body-v2 body is clean ---"
_check "$COMPLETE"
assert_eq "complete body is ready" "$RC $DOR_STATUS $DOR_MISSING" "0 ready []"
for code in $V2_CODES; do
  if _in "$DOR_ADVISORY" "$code" || _in "$DOR_MISSING" "$code"; then
    _fail "complete body: $code fired ($(jq -r --arg c "$code" '.[$c].detail' <<<"$DOR_CHECKS"))"
  else
    _pass "complete body: $code does not fire"
  fi
  assert_eq "complete body: $code passes" "$(_pass_of "$code")" "false"
done
DOR_STRICT_VERIFY_MODE=true DOR_STRICT_EDGE_CASES=true DOR_STRICT_AC_SHAPE=true DOR_STRICT_SCOPE_FILES=true \
  _check "$COMPLETE"
assert_eq "complete body is ready with every switch on" "$RC $DOR_STATUS $DOR_MISSING" "0 ready []"

echo "--- 2. a body that does not carry the contract is not judged ---"
_check "$LEGACY"
legacy_default="$RC $DOR_STATUS $DOR_MISSING $DOR_ADVISORY"
for code in $V2_CODES; do
  assert_eq "legacy body: $code is inapplicable" "$(_class "$code") $(_pass_of "$code")" "inapplicable null"
done
DOR_STRICT_VERIFY_MODE=true DOR_STRICT_EDGE_CASES=true DOR_STRICT_AC_SHAPE=true DOR_STRICT_SCOPE_FILES=true \
  _check "$LEGACY"
assert_eq "legacy body: same verdict with every switch on" "$RC $DOR_STATUS $DOR_MISSING $DOR_ADVISORY" "$legacy_default"
for code in $V2_CODES; do
  if _in "$DOR_ADVISORY" "$code" || _in "$DOR_MISSING" "$code"; then
    _fail "legacy body: $code fired under strict"
  else
    _pass "legacy body: $code silent under strict"
  fi
done
# A fenced heading or a tag in prose does not make a body carry the contract.
fenced_legacy="${LEGACY}"$'\n\n## Notes\n```\n## Verify Mode\n## Errors and Edge Cases\n```\nThe [unit] tag is described here.\n'
_check "$fenced_legacy"
assert_eq "fenced headings do not mark the contract" "$(_class VERIFY_MODE_INVALID)" "inapplicable"

echo "--- 3. VERIFY_MODE_INVALID / DOR_STRICT_VERIFY_MODE ---"
_expect_code "no section" VERIFY_MODE_INVALID DOR_STRICT_VERIFY_MODE "$(_drop_section "$COMPLETE" "Verify Mode")"
_expect_code "unknown shape" VERIFY_MODE_INVALID DOR_STRICT_VERIFY_MODE "${COMPLETE/'**Verify mode:** browser'/'**Verify mode:** manual'}"
_expect_code "unfilled template" VERIFY_MODE_INVALID DOR_STRICT_VERIFY_MODE "${COMPLETE/'**Verify mode:** browser'/'**Verify mode:** {shape}'}"
_expect_code "empty section" VERIFY_MODE_INVALID DOR_STRICT_VERIFY_MODE "${COMPLETE/'**Verify mode:** browser — a person signs in on a page.'/}"
for shape in browser api-only diff-only build-only live-backend; do
  _check "${COMPLETE/'**Verify mode:** browser'/"**Verify mode:** ${shape}"}"
  assert_eq "shape ${shape} is accepted" "$(_pass_of VERIFY_MODE_INVALID)" "false"
done

echo "--- 4. EDGE_CASES_MISSING / DOR_STRICT_EDGE_CASES ---"
no_edge=$(_drop_section "$COMPLETE" "Errors and Edge Cases")
_expect_code "feature, no section" EDGE_CASES_MISSING DOR_STRICT_EDGE_CASES "$no_edge" feature
_expect_code "improvement, no section" EDGE_CASES_MISSING DOR_STRICT_EDGE_CASES "$no_edge" improvement
empty_edge=$(awk '$0 == "## Errors and Edge Cases" { print; skip = 1; next } skip && /^## / { skip = 0; print ""; } !skip { print }' <<<"$COMPLETE")
_expect_code "feature, empty section" EDGE_CASES_MISSING DOR_STRICT_EDGE_CASES "$empty_edge" feature
# A chore needs the section only when it is API or live-backend work.
chore_body=$(_drop_section "$no_edge" "Navigation Path")
DOR_STRICT_EDGE_CASES=true _check "$chore_body" chore
assert_eq "browser chore without the section: inapplicable" "$(_class EDGE_CASES_MISSING)" "inapplicable"
_expect_code "api-only chore, no section" EDGE_CASES_MISSING DOR_STRICT_EDGE_CASES \
  "${chore_body/'**Verify mode:** browser'/'**Verify mode:** api-only'}" chore
_expect_code "live-backend chore, no section" EDGE_CASES_MISSING DOR_STRICT_EDGE_CASES \
  "${chore_body/'**Verify mode:** browser'/'**Verify mode:** live-backend'}" chore

echo "--- 5. AC_UNTAGGED / AC_COUNT_HIGH / AC_POST_MERGE_STATE / DOR_STRICT_AC_SHAPE ---"
untagged="${COMPLETE/'- [ ] [live] An empty password'/'- [ ] An empty password'}"
_expect_code "one untagged criterion" AC_UNTAGGED DOR_STRICT_AC_SHAPE "$untagged"
_check "$untagged"
assert_eq "untagged detail counts the criteria" "$(jq -r '.AC_UNTAGGED.detail' <<<"$DOR_CHECKS")" \
  "1 of 3 acceptance criteria have no [unit] or [live] tag"

many=""
for i in $(seq 1 21); do many+="- [ ] [live] Field ${i} shows \"value ${i}\""$'\n'; done
high=$(awk -v add="$many" '{ print } $0 == "## Acceptance Criteria" { printf "%s", add }' <<<"$COMPLETE")
_expect_code "24 criteria" AC_COUNT_HIGH DOR_STRICT_AC_SHAPE "$high"
at_cap=$(awk -v add="$(head -17 <<<"$many")" '{ print } $0 == "## Acceptance Criteria" { print add }' <<<"$COMPLETE")
_check "$at_cap"
assert_eq "20 criteria is at the cap, not over it" "$(_pass_of AC_COUNT_HIGH)" "false"

post="${COMPLETE/'shows "Password is required"'$'\n''- [ ] [unit]'/'shows "Password is required" once merged'$'\n''- [ ] [unit]'}"
_expect_code "once merged" AC_POST_MERGE_STATE DOR_STRICT_AC_SHAPE "$post"
post2="${COMPLETE/'- [ ] [unit] A 503 response'/'- [ ] [unit] On the develop branch a 503 response'}"
_expect_code "base branch" AC_POST_MERGE_STATE DOR_STRICT_AC_SHAPE "$post2"

# The three share one switch and are still reported one by one.
DOR_STRICT_AC_SHAPE=true _check "${post/'- [ ] [live] Signing in'/'- [ ] Signing in'}"
assert_eq "two AC shape codes block together" "$DOR_MISSING" '["AC_UNTAGGED","AC_POST_MERGE_STATE"]'

echo "--- 6. SCOPE_TC_MISMATCH / DOR_STRICT_SCOPE_FILES ---"
tc_extra="${COMPLETE/'The form lives in'/'The route is in `backend/routes/auth.js`. The form lives in'}"
_expect_code "Technical Context file not in Scope" SCOPE_TC_MISMATCH DOR_STRICT_SCOPE_FILES "$tc_extra"
_check "$tc_extra"
assert_eq "detail names the file" "$(jq -r '.SCOPE_TC_MISMATCH.detail' <<<"$DOR_CHECKS")" \
  "named in Technical Context but not in the Scope table: backend/routes/auth.js"
scope_extra="${COMPLETE/'`frontend/src/login.js`, '/'`frontend/src/login.js`, `frontend/src/style.css`, '}"
_expect_code "Scope file not in Technical Context" SCOPE_TC_MISMATCH DOR_STRICT_SCOPE_FILES "$scope_extra"
_check "${scope_extra/'`frontend/src/style.css`,'/'`frontend/src/style.css` (read-only),'}"
assert_eq "a read-only Scope file needs no Technical Context mention" "$(_pass_of SCOPE_TC_MISMATCH)" "false"
_check "${COMPLETE/'`frontend/src/login.js`, `frontend/src/messages.json` (read-only)'/'`login.js`, `messages.json` (read-only)'}"
assert_eq "a path tail names the same file" "$(_pass_of SCOPE_TC_MISMATCH)" "false"
# A hand-written body with no Technical Context section is not compared.
DOR_STRICT_SCOPE_FILES=true _check "$(_drop_section "$COMPLETE" "Technical Context")"
assert_eq "no Technical Context section: inapplicable" "$(_class SCOPE_TC_MISMATCH) $RC" "inapplicable 0"

echo "--- 7. each marker alone makes the body carry the contract ---"
only_tags=$(_drop_section "$(_drop_section "$COMPLETE" "Verify Mode")" "Errors and Edge Cases")
_check "$only_tags"
if _in "$DOR_ADVISORY" VERIFY_MODE_INVALID && _in "$DOR_ADVISORY" EDGE_CASES_MISSING; then
  _pass "tagged criteria alone: both missing sections warn"
else
  _fail "tagged criteria alone should warn for both sections (advisory=$DOR_ADVISORY)"
fi
only_edge=$(_drop_section "$COMPLETE" "Verify Mode")
only_edge="${only_edge//'[live] '/}"
only_edge="${only_edge//'[unit] '/}"
_check "$only_edge"
if _in "$DOR_ADVISORY" VERIFY_MODE_INVALID && _in "$DOR_ADVISORY" AC_UNTAGGED; then
  _pass "Errors and Edge Cases alone: missing verify mode and tags warn"
else
  _fail "Errors and Edge Cases alone should mark the contract (advisory=$DOR_ADVISORY)"
fi

echo "--- 8. the existing switches are unchanged; a partial copy still works ---"
# The planner's Refinement prefix does not promote any of the new codes.
DOR_STRICT_TEST_DATA=true DOR_STRICT_VPLAN=true _check "$untagged"
if _in "$DOR_MISSING" AC_UNTAGGED; then
  _fail "DOR_STRICT_TEST_DATA/DOR_STRICT_VPLAN must not promote AC_UNTAGGED"
else
  _pass "the Refinement prefix leaves AC_UNTAGGED advisory"
fi
# No switch leaks out of a call prefix.
assert_eq "no switch leaked" "${DOR_STRICT_VERIFY_MODE-}${DOR_STRICT_EDGE_CASES-}${DOR_STRICT_AC_SHAPE-}${DOR_STRICT_SCOPE_FILES-}" ""
# Without the sibling file the check still runs and reports none of the codes.
out=$(
  mkdir -p "$TMP_ROOT/lib-partial"
  cp "$LIB_DIR"/*.sh "$TMP_ROOT/lib-partial/"
  rm -f "$TMP_ROOT/lib-partial/dor-body-v2.sh"
  f="$TMP_ROOT/partial.md"
  printf '%s\n' "$untagged" >"$f"
  bash -c '
    set -eo pipefail
    source "$1/dor-check.sh"
    resolve_test_user_catalog() { return 1; }
    rc=0
    check_ticket_ready PARTIAL-1 --body "$2" --type feature --no-fetch || rc=$?
    echo "$rc $DOR_STATUS $(jq -r "has(\"AC_UNTAGGED\")" <<<"$DOR_CHECKS")"
  ' _ "$TMP_ROOT/lib-partial" "$f" 2>&1
)
assert_eq "a copy without dor-body-v2.sh still gives a verdict" "$out" "0 ready false"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
