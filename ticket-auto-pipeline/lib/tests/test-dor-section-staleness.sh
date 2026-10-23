#!/usr/bin/env bash
# test-dor-section-staleness.sh — section and unit hashes, section-scoped
# staleness and the check-profile recompute (planner-refinement-convergence,
# group 1: dor-check.sh _dor_section_hashes/_dor_unit_hashes,
# manifest-write.sh set_ticket_readiness rebase rule, ensure_ticket_readiness
# check_profile).
# Usage: bash test-dor-section-staleness.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LIB_DIR/notes-parse.sh"
source "$LIB_DIR/dor-check.sh"

# Hermetic: no developer catalog.
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
unset DOR_SEMANTIC_INERT_SECTIONS DOR_STRICT_TEST_DATA DOR_STRICT_VPLAN

base_body='Intro before any heading.

## Summary
Save handovers reliably from the settings page.

## Background / Motivation
Attorneys report the Save button silently failing on the handovers settings page, with no error shown and no data saved.

## Proposed Behaviour
Saving on the handovers settings page always either succeeds with a confirmation toast or fails with a visible error toast — never silently.

## Acceptance Criteria
- [ ] Save button works
- [ ] Error toast appears
- [ ] Confirmation toast appears

## Test User
`admin` — password `admin`

## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |

## Navigation Path
`Settings > Handovers > Save`

## Related Tickets
- none

## Planner Context
**Initiative:** INIT-1
'

# ── 1. Hash shapes ─────────────────────────────────────────────────────────

fence_body='## Summary
text
```
## Not a heading
```
### Sub heading folds into Summary
more
## Summary
second summary
'
sec=$(_dor_section_hashes "$fence_body")
echo "$sec" | jq -e 'has("Not a heading") | not' >/dev/null &&
  _pass "section hashes: a heading inside a fence is ignored" ||
  _fail "section hashes: fenced '## Not a heading' should not be a key (got $sec)"
echo "$sec" | jq -e 'has("Sub heading folds into Summary") | not' >/dev/null &&
  _pass "section hashes: ### folds into its parent" ||
  _fail "section hashes: ### should fold into its parent (got $sec)"
echo "$sec" | jq -e 'has("Summary") and has("Summary#2")' >/dev/null &&
  _pass "section hashes: a repeated heading is keyed <heading>#2" ||
  _fail "section hashes: expected Summary and Summary#2 (got $sec)"
echo "$sec" | jq -e 'has("_preamble") | not' >/dev/null &&
  _pass "section hashes: no _preamble key when nothing precedes the first heading" ||
  _fail "section hashes: blank preamble should be omitted (got $sec)"

sec=$(_dor_section_hashes "$base_body")
echo "$sec" | jq -e 'has("_preamble") and (.Summary | startswith("sha256:"))' >/dev/null &&
  _pass "section hashes: text before the first heading is _preamble; values are sha256:<hex>" ||
  _fail "section hashes: expected _preamble and sha256 values (got $sec)"

# Whitespace-only differences never read as an edit.
sec_ws=$(_dor_section_hashes "$(printf '%s' "$base_body" | sed 's/$/  \r/')")
[ "$(echo "$sec" | jq -S -c .)" = "$(echo "$sec_ws" | jq -S -c .)" ] &&
  _pass "section hashes: CR and trailing whitespace are normalised away" ||
  _fail "section hashes: CR/trailing whitespace should not change any hash"

units=$(_dor_unit_hashes "$base_body")
n_ac=$(echo "$units" | jq '[keys[] | select(startswith("Acceptance Criteria/ac:"))] | length')
[ "$n_ac" = "3" ] &&
  _pass "unit hashes: each AC item is its own unit" ||
  _fail "unit hashes: expected 3 AC item units (got $n_ac: $units)"
echo "$units" | jq -e 'keys | all(test("^Acceptance Criteria/ac:[0-9a-f]{8}$") or (startswith("Acceptance Criteria") | not))' >/dev/null &&
  _pass "unit hashes: AC unit keys are <heading>/ac:<sha8>" ||
  _fail "unit hashes: bad AC unit key shape (got $units)"
echo "$units" | jq -e 'has("Acceptance Criteria") | not' >/dev/null &&
  _pass "unit hashes: an AC section of items only has no residual section unit" ||
  _fail "unit hashes: no residual AC unit expected (got $units)"
echo "$units" | jq -e 'has("Summary") and has("Related Tickets")' >/dev/null &&
  _pass "unit hashes: non-AC sections are single units" ||
  _fail "unit hashes: non-AC sections should be units (got $units)"

edited_ac_body=${base_body/Error toast appears/Error toast appears within 2s}
units2=$(_dor_unit_hashes "$edited_ac_body")
kept=$(jq -n --argjson a "$units" --argjson b "$units2" \
  '[$a | keys[] | select(startswith("Acceptance Criteria/ac:")) | select($b[.] != null)] | length')
[ "$kept" = "2" ] &&
  _pass "unit hashes: editing one of three AC items keeps the other two keys" ||
  _fail "unit hashes: expected 2 unchanged AC unit keys (got $kept)"

# Item normalisation follows _dor_ac_lines: case and marker do not matter.
k1=$(_dor_unit_hashes $'## Acceptance Criteria\n- [ ] User Can Save' | jq -r 'keys[0]')
k2=$(_dor_unit_hashes $'## Acceptance Criteria\n* user   can save' | jq -r 'keys[0]')
[ "$k1" = "$k2" ] &&
  _pass "unit hashes: AC item key uses _dor_ac_lines normalisation" ||
  _fail "unit hashes: expected identical keys (got $k1 vs $k2)"

# ── 2. Reset between calls ─────────────────────────────────────────────────

body_file="$TMP_ROOT/body.md"
printf '%s' "$base_body" >"$body_file"
check_ticket_ready "SHAPE-1" --body "$body_file" --type feature --no-fetch >/dev/null 2>&1 || true
[ -n "$DOR_SECTION_HASHES" ] && [ -n "$DOR_UNIT_HASHES" ] &&
  [ "$(echo "$DOR_SECTION_HASHES" | jq -c .)" = "$(_dor_section_hashes "$base_body")" ] &&
  _pass "check_ticket_ready: sets DOR_SECTION_HASHES and DOR_UNIT_HASHES" ||
  _fail "check_ticket_ready: should set both hash maps (got '$DOR_SECTION_HASHES')"
check_ticket_ready "SHAPE-1" --body "$TMP_ROOT/missing.md" --type feature --no-fetch >/dev/null 2>&1 || true
[ -z "$DOR_SECTION_HASHES" ] && [ -z "$DOR_UNIT_HASHES" ] &&
  _pass "check_ticket_ready: hashes reset when the next body is missing" ||
  _fail "check_ticket_ready: hashes should be empty after a missing body (got '$DOR_SECTION_HASHES')"

# ── 3. Rebase / stale rule ─────────────────────────────────────────────────

# _seed <TID> <body> <findings_json> — fresh deterministic verdict on <body>
# with section hashes, a fresh semantic verdict on the same body, and a
# lineage at round 2.
_seed() {
  local tid="$1" body="$2" findings="${3:-[]}"
  write_ticket_manifest "$tid" "INIT-1" "feature" '[]'
  local h s u
  h=$(_dor_body_hash "$body")
  s=$(_dor_section_hashes "$body")
  u=$(_dor_unit_hashes "$body")
  set_ticket_readiness "$tid" "ready" '[]' '[]' \
    "$(jq -nc --arg h "$h" --argjson s "$s" --argjson u "$u" '{body_hash: $h, section_hashes: $s, unit_hashes: $u}')"
  set_ticket_semantic "$tid" "$(jq -nc --arg h "$h" --argjson f "$findings" \
    '{evaluator: "dor-semantic-v2", body_hash: $h, findings: $f}')"
  set_ticket_lineage "$tid" "$(jq -nc --arg h "$h" --argjson s "$s" --argjson u "$u" \
    '{round: 2, evaluator: "dor-semantic-v2", body_hash: $h, section_hashes: $s, units: $u, findings: []}')"
}

# _recheck <TID> <body> — what a re-scan writes for <body>.
_recheck() {
  local tid="$1" body="$2" missing="${3:-[]}"
  local h s u
  h=$(_dor_body_hash "$body")
  s=$(_dor_section_hashes "$body")
  u=$(_dor_unit_hashes "$body")
  set_ticket_readiness "$tid" "ready" "$missing" '[]' \
    "$(jq -nc --arg h "$h" --argjson s "$s" --argjson u "$u" '{body_hash: $h, section_hashes: $s, unit_hashes: $u}')"
}

blocking_ac_finding='[{"code":"EDGE_CASE_GAP","dimension":"edge_cases","severity":"blocking","quote":"Save button works","detail":"d","verified":true,"unit":"Acceptance Criteria/ac:00000000","units":["Acceptance Criteria/ac:00000000"]}]'

related_body=${base_body/- none/- PRO-0 (sibling)}

# 3a. Related Tickets edit rebases without changing the round.
_seed "REB-1" "$base_body" "$blocking_ac_finding"
_recheck "REB-1" "$related_body"
r=$(get_ticket_manifest_field "REB-1" ready)
new_h=$(_dor_body_hash "$related_body")
old_h=$(_dor_body_hash "$base_body")
echo "$r" | jq -e '.missing | index("SEMANTIC_STALE") | not' >/dev/null &&
  _pass "rebase: a Related Tickets edit does not add SEMANTIC_STALE" ||
  _fail "rebase: Related Tickets edit should not stale (got $(echo "$r" | jq -c .missing))"
echo "$r" | jq -e '.missing | index("SEMANTIC_EDGE_CASES")' >/dev/null &&
  _pass "rebase: the verdict's SEMANTIC_* codes are kept" ||
  _fail "rebase: SEMANTIC_EDGE_CASES should survive (got $(echo "$r" | jq -c .missing))"
echo "$r" | jq -e --arg n "$new_h" --arg o "$old_h" \
  '.semantic.body_hash == $n and .semantic.rebased_from == $o and (.semantic.stale // false | not)' >/dev/null &&
  _pass "rebase: semantic.body_hash moves to the new hash, rebased_from records the old" ||
  _fail "rebase: semantic hash/rebased_from wrong (got $(echo "$r" | jq -c .semantic))"
echo "$r" | jq -e --arg n "$new_h" '.lineage.round == 2 and .lineage.body_hash == $n
    and .lineage.section_hashes["Related Tickets"] != null' >/dev/null &&
  _pass "rebase: lineage round unchanged, lineage hashes moved to the new body" ||
  _fail "rebase: lineage wrong (got $(echo "$r" | jq -c .lineage))"
[ "$(echo "$r" | jq -r '.lineage.section_hashes["Related Tickets"]')" = "$(echo "$r" | jq -r '.section_hashes["Related Tickets"]')" ] &&
  _pass "rebase: lineage.section_hashes equals the new section_hashes" ||
  _fail "rebase: lineage.section_hashes should equal ready.section_hashes"

# 3b. Planner Context edit stales and records changed_sections.
pc_body=${base_body/INIT-1/INIT-2}
_seed "STL-1" "$base_body"
_recheck "STL-1" "$pc_body"
r=$(get_ticket_manifest_field "STL-1" ready)
echo "$r" | jq -e '(.missing | index("SEMANTIC_STALE")) and .semantic.stale == true
    and .semantic.changed_sections == ["Planner Context"]' >/dev/null &&
  _pass "stale: a Planner Context edit stales with changed_sections [\"Planner Context\"]" ||
  _fail "stale: Planner Context edit wrong (got missing=$(echo "$r" | jq -c .missing) sem=$(echo "$r" | jq -c .semantic))"
echo "$r" | jq -e '.lineage.round == 2 and .lineage.body_hash != .body_hash' >/dev/null &&
  _pass "stale: lineage is copied forward untouched" ||
  _fail "stale: lineage should be untouched (got $(echo "$r" | jq -c .lineage))"

# 3c. AC edit stales with the AC heading.
_seed "STL-2" "$base_body"
_recheck "STL-2" "$edited_ac_body"
r=$(get_ticket_manifest_field "STL-2" ready)
echo "$r" | jq -e '(.missing | index("SEMANTIC_STALE")) and .semantic.changed_sections == ["Acceptance Criteria"]' >/dev/null &&
  _pass "stale: an AC edit stales with changed_sections [\"Acceptance Criteria\"]" ||
  _fail "stale: AC edit wrong (got $(echo "$r" | jq -c .semantic))"

# 3d. A second edit on an already-stale verdict accumulates changed_sections.
both_body=${edited_ac_body/- none/- PRO-0 (sibling)}
_recheck "STL-2" "$both_body"
r=$(get_ticket_manifest_field "STL-2" ready)
echo "$r" | jq -e '(.missing | index("SEMANTIC_STALE")) and .semantic.changed_sections == ["Acceptance Criteria","Related Tickets"]' >/dev/null &&
  _pass "stale: an already-stale verdict accumulates changed_sections and does not rebase" ||
  _fail "stale: accumulation wrong (got $(echo "$r" | jq -c .semantic))"

# 3e. Legacy verdict (no section hashes stored) stales as before.
write_ticket_manifest "LEG-1" "INIT-1" "feature" '[]'
set_ticket_readiness "LEG-1" "ready" '[]' '[]' "$(jq -nc --arg h "$old_h" '{body_hash: $h}')"
set_ticket_semantic "LEG-1" "$(jq -nc --arg h "$old_h" '{evaluator: "dor-semantic-v2", body_hash: $h, findings: []}')"
_recheck "LEG-1" "$related_body"
r=$(get_ticket_manifest_field "LEG-1" ready)
echo "$r" | jq -e '(.missing | index("SEMANTIC_STALE")) and .semantic.stale == true and (.semantic | has("changed_sections") | not)' >/dev/null &&
  _pass "legacy: a verdict without stored section hashes stales as before (no changed_sections)" ||
  _fail "legacy: should stale with no changed_sections (got $(echo "$r" | jq -c .semantic))"
echo "$r" | jq -e 'has("lineage") | not' >/dev/null &&
  _pass "legacy: no lineage key appears from nowhere" ||
  _fail "legacy: lineage should be absent"

# 3f. Non-empty ready.demoted blocks the rebase.
_seed "DEM-1" "$base_body"
mp=$(get_ticket_manifest_path "DEM-1")
jq -c '.ready.demoted = {"AC_VAGUE": {"by": "audit", "body_hash": "x"}}' "$mp" >"$mp.new" && mv "$mp.new" "$mp"
_recheck "DEM-1" "$related_body"
r=$(get_ticket_manifest_field "DEM-1" ready)
echo "$r" | jq -e '(.missing | index("SEMANTIC_STALE")) and .semantic.changed_sections == ["Related Tickets"]' >/dev/null &&
  _pass "rebase: a non-empty ready.demoted blocks the rebase" ||
  _fail "rebase: demoted should block the rebase (got $(echo "$r" | jq -c .semantic))"

# 3g. A finding anchored in the changed inert heading blocks the rebase.
anchored='[{"code":"UNSTATED_DEPENDENCY","dimension":"dependencies","severity":"blocking","quote":"none","detail":"d","verified":true,"unit":"Related Tickets","units":["Related Tickets"]}]'
_seed "ANC-1" "$base_body" "$anchored"
_recheck "ANC-1" "$related_body"
r=$(get_ticket_manifest_field "ANC-1" ready)
echo "$r" | jq -e '(.missing | index("SEMANTIC_STALE"))' >/dev/null &&
  _pass "rebase: a finding anchored in the changed section blocks the rebase" ||
  _fail "rebase: anchored finding should block (got $(echo "$r" | jq -c .missing))"

# 3h. A verified finding with no recorded anchor blocks the rebase.
unanchored='[{"code":"EDGE_CASE_GAP","dimension":"edge_cases","severity":"blocking","quote":"Save button works","detail":"d","verified":true}]'
_seed "ANC-2" "$base_body" "$unanchored"
_recheck "ANC-2" "$related_body"
r=$(get_ticket_manifest_field "ANC-2" ready)
echo "$r" | jq -e '(.missing | index("SEMANTIC_STALE"))' >/dev/null &&
  _pass "rebase: a verified finding without an anchor blocks the rebase" ||
  _fail "rebase: unanchored finding should block (got $(echo "$r" | jq -c .missing))"

# 3i. DOR_SEMANTIC_INERT_SECTIONS widens the inert set.
_seed "INR-1" "$base_body"
DOR_SEMANTIC_INERT_SECTIONS="Related Tickets|Planner Context" _recheck "INR-1" "$pc_body"
r=$(get_ticket_manifest_field "INR-1" ready)
echo "$r" | jq -e '(.missing | index("SEMANTIC_STALE") | not) and .semantic.rebased_from != null' >/dev/null &&
  _pass "rebase: DOR_SEMANTIC_INERT_SECTIONS overrides the inert set" ||
  _fail "rebase: override should rebase a Planner Context edit (got $(echo "$r" | jq -c .missing))"

# ── 4. Check-profile recompute ─────────────────────────────────────────────

# strict_body: non-self-verifying ACs and no Verification Plan, so
# VPLAN_MISSING is advisory under host defaults and hard under planner-strict.
strict_body=$(printf '%s' "$base_body" | sed '/^## Related Tickets/,$d')
pdir="$TMP_ROOT/.ticket-auto/initiatives/INIT-1/tickets/PROF-1/planner"
mkdir -p "$pdir"
printf '%s' "$strict_body" >"$pdir/body.md"
resolve_planner_dir() { echo "$TMP_ROOT/.ticket-auto/initiatives/INIT-1/tickets/$1/planner"; }

# Control: host-default recompute leaves VPLAN_MISSING advisory.
DOR_STRICT_TEST_DATA=true DOR_STRICT_VPLAN=true \
  check_ticket_ready "PROF-0" --body "$pdir/body.md" --type feature --no-fetch >/dev/null 2>&1 || true
echo "$DOR_MISSING" | jq -e 'index("VPLAN_MISSING")' >/dev/null &&
  _pass "profile: fixture body fails VPLAN_MISSING hard under planner-strict" ||
  _fail "profile: fixture should fail VPLAN_MISSING under strict (got $DOR_MISSING)"
check_ticket_ready "PROF-0" --body "$pdir/body.md" --type feature --no-fetch >/dev/null 2>&1 || true
echo "$DOR_MISSING" | jq -e 'index("VPLAN_MISSING") | not' >/dev/null &&
  _pass "profile: fixture body has VPLAN_MISSING non-blocking under host defaults" ||
  _fail "profile: fixture should not block on VPLAN_MISSING by default (got $DOR_MISSING)"

write_ticket_manifest "PROF-1" "INIT-1" "feature" '[]'
set_ticket_readiness "PROF-1" "ready" '[]' '[]' '{"body_hash": "sha256:old", "check_profile": "planner-strict"}'
ensure_ticket_readiness "PROF-1" >/dev/null 2>&1 || true
r=$(get_ticket_manifest_field "PROF-1" ready)
echo "$r" | jq -e '(.missing | index("VPLAN_MISSING")) and .check_profile == "planner-strict"' >/dev/null &&
  _pass "profile: a dispatch recompute keeps the planner-strict codes and the profile" ||
  _fail "profile: recompute should run planner-strict (got $(echo "$r" | jq -c '{missing, check_profile}'))"
echo "$r" | jq -e '(.section_hashes | type) == "object" and (.unit_hashes | type) == "object"' >/dev/null &&
  _pass "profile: the recompute writes section and unit hashes" ||
  _fail "profile: recompute should write the hashes (got $(echo "$r" | jq -c 'keys'))"
[ -z "${DOR_STRICT_VPLAN:-}" ] && [ -z "${DOR_STRICT_TEST_DATA:-}" ] &&
  _pass "profile: the strict prefix does not leak into the caller" ||
  _fail "profile: DOR_STRICT_* leaked (VPLAN=${DOR_STRICT_VPLAN:-} TD=${DOR_STRICT_TEST_DATA:-})"

write_ticket_manifest "PROF-2" "INIT-1" "feature" '[]'
mkdir -p "$TMP_ROOT/.ticket-auto/initiatives/INIT-1/tickets/PROF-2/planner"
printf '%s' "$strict_body" >"$TMP_ROOT/.ticket-auto/initiatives/INIT-1/tickets/PROF-2/planner/body.md"
set_ticket_readiness "PROF-2" "ready" '[]' '[]' '{"body_hash": "sha256:old"}'
ensure_ticket_readiness "PROF-2" >/dev/null 2>&1 || true
r=$(get_ticket_manifest_field "PROF-2" ready)
echo "$r" | jq -e '(.missing | index("VPLAN_MISSING") | not) and (has("check_profile") | not)' >/dev/null &&
  _pass "profile: no stored profile recomputes with host defaults" ||
  _fail "profile: no profile should mean host defaults (got $(echo "$r" | jq -c '{missing, check_profile}'))"

# Cache miss (no ready yet) also writes the hashes.
write_ticket_manifest "MISS-1" "INIT-1" "feature" '[]'
ensure_ticket_readiness "MISS-1" --body "$pdir/body.md" >/dev/null 2>&1 || true
r=$(get_ticket_manifest_field "MISS-1" ready)
echo "$r" | jq -e '(.section_hashes | has("Acceptance Criteria")) and (.unit_hashes | type) == "object"' >/dev/null &&
  _pass "ensure_ticket_readiness: the cache-miss write path stores the hashes too" ||
  _fail "ensure_ticket_readiness: cache-miss path should store hashes (got $(echo "$r" | jq -c 'keys'))"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
