#!/usr/bin/env bash
# test-planner-testdata-implied.sh — planner-test-data-derivation groups 1-2:
# the implied-data heuristic (_planner_testdata_implies_data, table-tested),
# the Test Data Inventory reader, the TESTDATA_CONFIRM answer line (hash,
# parser, normaliser, writer), effective Sources from exists:/external:
# answers, and the tripwire family's findings.
#
# Run: bash ticket-planner/lib/tests/test-planner-testdata-implied.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck-propagation.sh"
source "${LIB_DIR}/planner-crosscheck-testdata.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"

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
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_contains() {
  case "$2" in
  *"$3"*) pass "$1" ;;
  *) fail "$1" "missing '$3' in: $2" ;;
  esac
}

# ── 2.2 heuristic table ─────────────────────────────────────────────────────

echo "--- _planner_testdata_implies_data: tier table ---"
INV=$'invoice\nline item\nclient'
INV2=$'article\nuser\ncomment\nprofile'
# <expected tier>|<entities: inv or empty>|<criterion>
while IFS='|' read -r want ents crit; do
  [ -n "$want" ] || continue
  e=""
  [ "$ents" = inv ] && e="$INV"
  [ "$ents" = inv2 ] && e="$INV2"
  got=$(_planner_testdata_implies_data "$crit" "$e")
  assert_eq "${want}: ${crit}" "$got" "$want"
done <<'TABLE'
strong||Given 5 overdue `invoice` records, the dashboard shows 5
strong|inv|The dashboard shows 5 overdue invoices
strong|inv|Shows 2 line items per order
strong|inv|The archived client is hidden from the list
strong|inv|Clients with no orders show an empty state
strong||An existing customer record can be edited
strong||Seeded products appear in the catalogue
strong||Duplicate email that already exists shows an error
strong||Given a user with two saved addresses, checkout offers both
strong||When there are no pending jobs, the queue shows empty
strong||When the user filters orders by status, only paid ones show
strong||Given the report page, when the user exports transactions, a CSV downloads
weak||The profile page shows 3 badges
weak||Archived entries are hidden
weak||The category list has 12 entries
weak|inv|The profile page shows 3 badges
none||the session expires after 15 minutes
none||lock after 5 attempts
none||Retries 3 times then fails
none||Requests time out after 30 seconds
none||Polling backs off to 500 ms
none||Upload rejects files over 10 MB
none||Upload rejects files over 10MB
none||Responses stay under 512 bytes
none||Coverage stays at 80 %
none||50% of users see the banner
none||The API returns 404 when the id is unknown
none||Response is 200 OK
none||The existing behaviour is unchanged
none||The button is blue
none||Call `planner_state_write` once
none||The `GET /health` endpoint answers
none||The user can search
none||The README states that `conduit-dev-secret` is for local development only
none||Running `npm run build` in `frontend/` exits with code 0
none||The CLAUDE.md Build & Test row for `npm run build` is labelled "FE build"
none||`git status` shows a clean tree after `make seed`
none||Running `seed-tool --reset` exits 0
none|inv|The docs mention that a `client` can export an `invoice`
none||`frontend/package.json` defines the scripts `dev`, `build` and `preview`
none||With a `jwt` value in localStorage, a request sent through the API helper `request` carries the header
none||The create response author has no `following` field
none||With port 5173 already in use, `npm run dev` exits with an error
none||A request to an unknown route returns the backend's 404 body
none|inv|Signed out, the header shows no "New Article" link
none|inv|The page title reads "Invoice list"
strong|inv|The archived "Q3" invoice is hidden from the list
strong||With the `jake` account signed in, the header shows `jake`
strong||`alice` can log in
strong||The `welcome-post` article is listed on the home page
strong||Running `npm test` passes and the `welcome-post` article is listed
strong|inv|The README is shown to the client after login
strong|inv2|`curl /api/profiles/jake` returns 200
strong|inv2|`GET /api/profiles/jake` returns 200
strong|inv2|`curl -s localhost:3000/api/articles/how-to-train-your-dragon` returns 200
strong|inv2|The Getting Started guide lists `jake` as the demo login and logging in shows the feed
strong||The fixture `users.json` includes `jake`, whose profile page renders
none|inv2|The README states that `jake` and `jakejake` are demo logins
none|inv2|A request to `http://localhost:5173/api/unknown` returns the backend's 404 body
TABLE

echo "--- F28: command spans and document wording are quoted content ---"
for s in 'npm run build' 'git status' 'make seed' 'seed-tool --reset' 'a && b' 'echo $HOME'; do
  _planner_testdata_span_is_command "$s" && pass "command span: $s" || fail "command span: $s" "not a command"
done
for s in 'alice' 'welcome-post' 'line item' 'npm' 'make' 'bin/seed' 'GET /api/profiles/jake' '/api/profiles/jake'; do
  _planner_testdata_span_is_command "$s" && fail "name span: $s" "read as a command" || pass "name span: $s"
done
_planner_testdata_crit_is_doc_text 'The README states that `x` is local only' &&
  pass "README + states is doc text" || fail "README + states is doc text" "not doc text"
_planner_testdata_crit_is_doc_text 'The `welcome-post` article is listed' &&
  fail "no document named is not doc text" "doc text" || pass "no document named is not doc text"
_planner_testdata_crit_is_doc_text 'The README states that `jake` logs in and the feed shows' &&
  fail "a behaviour clause is not doc text" "doc text" || pass "a behaviour clause is not doc text"
_planner_testdata_crit_is_doc_text 'Logging states that the README exists' &&
  fail "verb before the document is not doc text" "doc text" || pass "verb before the document is not doc text"
assert_eq "command args keep the path" "$(_planner_testdata_span_args 'curl -s -X GET /api/profiles/jake')" "GET /api/profiles/jake"
assert_eq "UI copy quote dropped, value quote kept" \
  "$(_planner_testdata_strip_quotes 'Click "New Article" as "alice@example.com" then "x" button' false | tr -s ' ')" \
  "Click as alice@example.com then button"
assert_eq "quoted username stays in scan and matches an entity" \
  "$(_planner_testdata_implies_data 'Logging in as "alice" shows the dashboard' alice)" "strong"
# Known miss: a quoted email stays in the scanned text, but an inventory
# entity never matches it (entity names are normalised to [a-z0-9 _-]).

echo "--- _planner_testdata_implied_match: reason and phrase ---"
m=$(_planner_testdata_implied_match 'Given 5 overdue `invoice` records, the dashboard shows 5' "" | tr '\037' '|')
assert_eq "count+entity phrase" "$m" "strong|count+entity|5 overdue invoice records"
m=$(_planner_testdata_implied_match 'The profile page shows 3 badges' "" | tr '\037' '|')
assert_eq "weak count+noun phrase" "$m" "weak|count+noun|3 badges"
m=$(_planner_testdata_implied_match 'An existing customer record can be edited' "" | tr '\037' '|')
assert_eq "existing-state phrase" "$m" "strong|existing-state|existing customer record"
m=$(_planner_testdata_implied_match 'The button is blue' "" | tr '\037' '|')
assert_eq "none has empty reason and phrase" "$m" "none||"

# ── 2.4 hash, normaliser, parser ────────────────────────────────────────────

echo "--- planner_testdata_confirm_hash ---"
h=$(planner_testdata_confirm_hash audit-log "Given 3 audit entries, the log shows 3")
[[ "$h" =~ ^[0-9a-f]{8}$ ]] && pass "hash is 8 hex" || fail "hash is 8 hex" "$h"
want=$(printf '%s\n%s' audit-log "Given 3 audit entries, the log shows 3" | sha256sum | cut -c1-8)
assert_eq "hash = sha256(slug LF criterion)" "$h" "$want"
assert_eq "criterion is trimmed" "$(planner_testdata_confirm_hash audit-log "  Given 3 audit entries, the log shows 3 ")" "$h"
[ "$(planner_testdata_confirm_hash audit-log "Given 4 audit entries, the log shows 4")" != "$h" ] &&
  pass "rewritten criterion changes the hash" || fail "rewritten criterion changes the hash" "same hash"
[ "$(planner_testdata_confirm_hash other "Given 3 audit entries, the log shows 3")" != "$h" ] &&
  pass "slug is part of the hash" || fail "slug is part of the hash" "same hash"

echo "--- planner_testdata_answer_normalize ---"
while IFS='|' read -r input want; do
  got=$(planner_testdata_answer_normalize "$input" 2>/dev/null) || got="REJECT"
  assert_eq "normalize '${input}'" "$got" "$want"
done <<'TABLE'
none|none
 NONE |none
generate: 3 audit entries|generate: 3 audit entries
Generate:3 audit entries|generate: 3 audit entries
exists: staging seed set|exists:staging seed set
external:client finance team|external:client finance team
exists:`db/seed.sql`|exists:db/seed.sql
generate:|REJECT
generate|REJECT
generate:   |REJECT
exists:|REJECT
external:|REJECT
|REJECT
maybe|REJECT
seeded-by:pack|REJECT
TABLE
got=$(planner_testdata_answer_normalize $'generate: rows a|b\r\nc' 2>/dev/null)
assert_eq "normalize strips | CR LF" "$got" "generate: rows abc"
why=$(planner_testdata_answer_normalize "generate:" 2>&1 >/dev/null)
assert_contains "empty generate names the fix" "$why" "generate: <description>"

echo "--- _planner_testdata_confirm_parse ---"
p=$(_planner_testdata_confirm_parse '- TESTDATA_CONFIRM: `audit-log` [0a1b2c3d] — Answer: none' | tr '\037' '|')
assert_eq "parse none" "$p" "audit-log|0a1b2c3d|none||none"
p=$(_planner_testdata_confirm_parse 'TESTDATA_CONFIRM: `audit-log` [0A1B2C3D] - Answer: generate: 3 entries. Answer: x' | tr '\037' '|')
assert_eq "parse generate, first Answer: wins, hash lowercased" "$p" "audit-log|0a1b2c3d|generate|3 entries. Answer: x|generate: 3 entries. Answer: x"
p=$(_planner_testdata_confirm_parse 'TESTDATA_CONFIRM: `audit-log` [0a1b2c3d] — Answer: PENDING' | tr '\037' '|')
assert_eq "parse invalid answer" "$p" "audit-log|0a1b2c3d|invalid||PENDING"
_planner_testdata_confirm_parse 'TESTDATA_CONFIRM: audit-log [0a1b2c3d] — Answer: none' >/dev/null &&
  fail "unbackticked slug is not a line" "parsed" || pass "unbackticked slug is not a line"
_planner_testdata_confirm_parse 'CITED_ARTIFACT: `x` — Answer: generate' >/dev/null &&
  fail "cited line is not a testdata line" "parsed" || pass "cited line is not a testdata line"

# ── 2.4 writer ──────────────────────────────────────────────────────────────

echo "--- planner_testdata_answer_set ---"
C="${TMPDIR}/consensus.md"
printf '# Consensus\n\n## Open Questions\n\n- CITED_ARTIFACT: `f` — cited. Answer: generate\n' >"$C"
planner_testdata_answer_set "$C" audit-log 0a1b2c3d none
assert_eq "append: rc 0" "$?" "0"
assert_eq "append: one line under a new heading" "$(grep -c 'TESTDATA_CONFIRM' "$C") $(grep -c '^## Test Data Confirmations' "$C")" "1 1"
assert_eq "append: exact line shape" "$(grep TESTDATA_CONFIRM "$C")" '- TESTDATA_CONFIRM: `audit-log` [0a1b2c3d] — Answer: none'
planner_testdata_answer_set "$C" invoice-list 11111111 "generate: 5 invoices"
planner_testdata_answer_set "$C" audit-log 22222222 "exists: staging seed"
lines=$(planner_testdata_confirm_lines "$C" | cut -d$'\037' -f1-5 | tr '\037' '|' | paste -sd';' -)
assert_eq "replace keeps one line per slug, in place" "$lines" "1|audit-log|22222222|exists|staging seed;2|invoice-list|11111111|generate|5 invoices"
before=$(cat "$C")
planner_testdata_answer_set "$C" audit-log 22222222 "exists: staging seed"
assert_eq "idempotent" "$(cat "$C")" "$before"
assert_contains "cited line untouched" "$(cat "$C")" '- CITED_ARTIFACT: `f` — cited. Answer: generate'
planner_testdata_answer_set "$C" audit-log 22222222 "generate:" 2>/dev/null
assert_eq "empty generate: rc 2" "$?" "2"
assert_eq "empty generate: nothing written" "$(cat "$C")" "$before"
planner_testdata_answer_set "$C" 'bad slug' 22222222 none 2>/dev/null
assert_eq "bad slug: rc 2" "$?" "2"
planner_testdata_answer_set "$C" audit-log XYZ none 2>/dev/null
assert_eq "bad hash: rc 2" "$?" "2"
planner_testdata_answer_set "${TMPDIR}/nope.md" audit-log 22222222 none 2>/dev/null
assert_eq "missing file: rc 1" "$?" "1"
printf 'line one\r\n' >"${TMPDIR}/crlf.md"
planner_testdata_answer_set "${TMPDIR}/crlf.md" a-b 33333333 none
assert_eq "CRLF file keeps CRLF" "$(grep -c $'\r$' "${TMPDIR}/crlf.md")" "$(wc -l <"${TMPDIR}/crlf.md" | tr -d ' ')"

# ── 1.3 inventory reader + 2.3/2.5 over an initiative ───────────────────────

new_init() {
  local id="$1"
  planner_state_init "$id" "test" >/dev/null 2>&1
  mkdir -p "$(_planner_testdata_state_dir "$id")/artifacts/specs"
  printf '%s' "$(_planner_testdata_state_dir "$id")/artifacts"
}

echo "--- planner_testdata_inventory_entities ---"
A=$(new_init INIT-inv-1)
cat >"${A}/discovery.md" <<'EOF'
# Discovery

## Test Data Inventory

| Entity | States/variants | Roles | Volume | Source | Load via | Privacy |
|--------|-----------------|-------|--------|--------|----------|---------|
| `Invoice` | draft, overdue | finance user | 5 | generate | SQL | synthetic |
| Line  Item | open | any | 10 | exists:seed | factories | synthetic |

## Constraints

None.
EOF
got=$(planner_testdata_inventory_entities INIT-inv-1 | tr '\037' '=' | paste -sd';' -)
assert_eq "entities normalised with load via" "$got" "invoice=sql;line item=factories"
A2=$(new_init INIT-inv-2)
printf '# Discovery\n\n## Test Data Inventory\n\nNone.\n' >"${A2}/discovery.md"
assert_eq "None. inventory has no entities" "$(planner_testdata_inventory_entities INIT-inv-2)" ""

echo "--- tripwires: contract vs legacy ---"
spec_none() {
  cat <<EOF
# $1

## Acceptance Criteria

- [ ] $2

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| $2 | finance user | none | — | ok | yes |
EOF
}
B=$(new_init INIT-trip-1)
cp "${A}/discovery.md" "${B}/discovery.md"
spec_none dash 'The dashboard shows 5 overdue invoices' >"${B}/specs/dash.md"
printf '# bare\n\n## Acceptance Criteria\n\n- [ ] Something happens.\n' >"${B}/specs/bare.md"
out=$(planner_crosscheck_testdata_tripwires INIT-trip-1)
rc=$?
assert_eq "contract: blocking rc" "$rc" "1"
H=$(planner_testdata_confirm_hash dash 'The dashboard shows 5 overdue invoices')
assert_contains "IMPLIED carries slug+hash+match" "$out" "TEST_DATA_IMPLIED dash.md [${H}] match=\"5 overdue invoices\" (strong: count+entity)"
assert_contains "NOTES_MISSING names the spec" "$out" "VERIFICATION_NOTES_MISSING bare.md has 1 acceptance criteria"

# Legacy: same specs, no contract marker → warn variants only.
L="${REPOS_ROOT}/.ticket-auto/initiatives/INIT-trip-legacy"
mkdir -p "${L}/artifacts"
cp -r "${B}/specs" "${L}/artifacts/specs"
grep -v '|META|contract|' "$(planner_state_log INIT-trip-1)" >"${L}/state.log"
out=$(planner_crosscheck_testdata_tripwires INIT-trip-legacy)
rc=$?
assert_eq "legacy: not blocking" "$rc" "0"
assert_contains "legacy: strong match warns" "$out" "TEST_DATA_IMPLIED_WEAK dash.md"
assert_contains "legacy: notes missing warns" "$out" "VERIFICATION_NOTES_MISSING_LEGACY bare.md"
case "$out" in *"TEST_DATA_INVENTORY_MISSING"*) fail "legacy: no inventory warn" "$out" ;; *) pass "legacy: no inventory warn" ;; esac

echo "--- 2.3/2.5: answers ---"
rm -f "${B}/specs/bare.md"
printf '# Consensus\n' >"${B}/consensus.md"
planner_testdata_answer_set "${B}/consensus.md" dash "$H" "external:billing team"
out=$(planner_crosscheck_testdata_tripwires INIT-trip-1)
assert_eq "external answer resolves the finding" "$?:$out" "0:"
eff=$(planner_testdata_spec_effective_needs INIT-trip-1 "${B}/specs/dash.md" | tr '\037' '|')
assert_eq "external answer is the effective Source of the matching row" "$eff" "1|5 overdue invoices|external|billing team"
assert_eq "spec file is not edited" "$(grep -c 'billing team' "${B}/specs/dash.md")" "0"
assert_eq "no generate needs" "$(planner_testdata_confirm_generate_needs INIT-trip-1)" ""

planner_testdata_answer_set "${B}/consensus.md" dash "$H" "generate: 5 overdue invoices, distinct dates"
assert_eq "generate answer becomes a synthesis need" \
  "$(planner_testdata_confirm_generate_needs INIT-trip-1 | tr '\037' '|')" "dash|${H}|5 overdue invoices, distinct dates"
eff=$(planner_testdata_spec_effective_needs INIT-trip-1 "${B}/specs/dash.md" | tr '\037' '|')
assert_eq "generate answer leaves the rows alone" "$eff" "1|none||"

planner_testdata_answer_set "${B}/consensus.md" dash "$H" none
out=$(planner_crosscheck_testdata_tripwires INIT-trip-1)
assert_eq "none answer suppresses" "$?:$out" "0:"
spec_none dash 'The dashboard shows 6 overdue invoices' >"${B}/specs/dash.md"
out=$(planner_crosscheck_testdata_tripwires INIT-trip-1)
assert_contains "rewritten criterion re-raises" "$out" "TEST_DATA_IMPLIED dash.md"
assert_eq "stale answer is not resolved" "$(planner_testdata_confirm_resolved INIT-trip-1)" ""

echo "--- synth marker and enabler exemptions ---"
E=$(new_init INIT-trip-2)
printf '# td\n\n%s\n\n## Acceptance Criteria\n\n- [ ] Shows 5 invoices.\n' "$PLANNER_TESTDATA_SYNTH_MARKER" >"${E}/specs/td.md"
printf '# en\n\n## Acceptance Criteria\n\n- [ ] Worker starts.\n\n## Signals\n\n```json\n{"Kind": "enabler"}\n```\n' >"${E}/specs/en.md"
out=$(planner_crosscheck_testdata_tripwires INIT-trip-2)
assert_eq "synth-marked and enabler specs are exempt" "$?:$out" "0:"

echo "--- F28: quoted content in a contract initiative ---"
F=$(new_init INIT-trip-f28)
printf '# Discovery\n\n## Test Data Inventory\n\n| Entity | Load via |\n|---|---|\n| user | factories |\n| article | factories |\n' >"${F}/discovery.md"
spec_none docs 'The README states that `conduit-dev-secret` is for local development only' >"${F}/specs/docs.md"
spec_none fe 'Running `npm run build` in `frontend/` exits with code 0' >"${F}/specs/fe.md"
out=$(planner_crosscheck_testdata_tripwires INIT-trip-f28)
assert_eq "F28: doc-wording and command criteria raise nothing" "$?:$out" "0:"
spec_none feed 'The `welcome-post` article is listed on the home page' >"${F}/specs/feed.md"
out=$(planner_crosscheck_testdata_tripwires INIT-trip-f28)
assert_contains "F28: a named record still blocks" "$out" "TEST_DATA_IMPLIED feed.md"
case "$out" in *"docs.md"* | *"fe.md"*) fail "F28: only feed.md is reported" "$out" ;; *) pass "F28: only feed.md is reported" ;; esac

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
