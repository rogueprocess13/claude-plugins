#!/usr/bin/env bash
# test-dor-semantic-draft.sh — the evaluator extractions draft readiness
# needs (planner-draft-readiness S1, design D3/D11/D13/D16):
# dor_semantic_findings, dor_semantic_blocking_codes,
# dor_semantic_lineage_from (incl. the DOR_SEMANTIC_PRIOR_PASSED policy),
# dor_semantic_assemble and dor_semantic_import. Deterministic: canned
# scan/audit blocks stand in for the agent.
# Usage: bash test-dor-semantic-draft.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$LIB_DIR/tests/fixtures/dor"
SEMANTIC_DIR="$FIXTURES_DIR/semantic"
PARSER="$LIB_DIR/dor-semantic-parse.sh"

source "$LIB_DIR/dor-semantic.sh"

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
_check() { # _check <desc> <command...>
  local desc="$1"
  shift
  if "$@"; then _pass "$desc"; else _fail "$desc"; fi
}

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
unset DOR_SEMANTIC_INERT_SECTIONS DOR_SEMANTIC_MAX_ROUNDS DOR_SEMANTIC_DRIFT_DEMOTE \
  DOR_SEMANTIC_ROUND_RESET_SHARE DOR_SEMANTIC_STRUCTURAL_CODES DOR_SEMANTIC_ADVISORY_CODES \
  DOR_SEMANTIC_PRIOR_PASSED DOR_AUDIT_DEMOTABLE_CODES

_ALL_CLEAR_GAPS='{"requirement_completeness":{"verdict":"clear","reason":"r"},"contradictory_requirements":{"verdict":"clear","reason":"r"},"deep_scope_ambiguity":{"verdict":"clear","reason":"r"},"edge_case_sufficiency":{"verdict":"clear","reason":"r"}}'

_body_of() { # fixture path for <nn>
  local f
  for f in "$FIXTURES_DIR/$1"-*.md; do
    echo "$f"
    return 0
  done
}

# _canned <src> <tid> <body-file> <kind> — parse a canned block for <tid>.
_canned() {
  local src="$1" tid="$2" body_file="$3" kind="$4" hash out
  hash=$(_dor_body_hash "$(cat "$body_file")")
  out="$TMP_ROOT/canned-$tid-$kind.txt"
  sed -e "s|@TICKET@|$tid|" -e "s|@BODY_HASH@|$hash|" "$src" >"$out"
  bash "$PARSER" --kind "$kind" --result-file "$out" 2>/dev/null
}

# _scan_json <tid> <body-file> <findings-json> [<gaps-json>]
_scan_json() {
  local h
  h=$(_dor_body_hash "$(cat "$2")")
  jq -nc --arg t "$1" --arg h "$h" --argjson f "$3" --argjson g "${4:-$_ALL_CLEAR_GAPS}" \
    '{schema_version:1, kind:"scan", ticket:$t, body_hash:$h, findings:$f, gaps:$g, parse_status:"ok", parse_error:""}'
}
_audit_json() {
  local h
  h=$(_dor_body_hash "$(cat "$2")")
  jq -nc --arg t "$1" --arg h "$h" \
    '{schema_version:1, kind:"audit", ticket:$t, body_hash:$h, audit:[], missed:[],
      score_plausible:true, score_reason:"ok", parse_status:"ok", parse_error:""}'
}
_f() { # _f <code> <quote> [<quote_b>]
  jq -nc --arg c "$1" --arg d "${DOR_SEMANTIC_CODES[$1]}" --arg q "$2" --arg qb "${3:-}" \
    '{code: $c, dimension: $d, quote: $q, detail: "a specific gap"} + (if $qb != "" then {quote_b: $qb} else {} end)'
}

_fresh_manifest() { # _fresh_manifest <tid> <body-file>
  local h
  h=$(_dor_body_hash "$(cat "$2")")
  write_ticket_manifest "$1" "INIT-1" "feature" '[]' >/dev/null
  set_ticket_readiness "$1" "ready" '[]' '[]' "{\"body_hash\": \"$h\"}" >/dev/null
}

# _draft_eval <tid> <body-file> <scan-json> <audit-json> <prior-lineage> <out-dir>
# The draft path: findings + lineage_from + assemble, written to
# <out-dir>/semantic.json and lineage.json; codes to codes.json.
_draft_eval() {
  local tid="$1" bf="$2" scan="$3" audit="$4" prior="$5" out="$6" body judged built hash sem
  mkdir -p "$out"
  body=$(cat "$bf")
  hash=$(_dor_body_hash "$body")
  judged=$(dor_semantic_findings "$tid" "$body" "$scan" "$audit") || return 1
  built=$(dor_semantic_lineage_from "$prior" "$body" "$hash" "$(echo "$judged" | jq -c .findings)" \
    "$(echo "$audit" | jq -c '.audit // []')") || return 1
  sem=$(dor_semantic_assemble "$hash" "$(echo "$built" | jq -c .findings)" \
    "$(echo "$judged" | jq -c .unverified_gaps)" "$scan" "$audit") || return 1
  echo "$sem" >"$out/semantic.json"
  echo "$built" | jq -c .lineage >"$out/lineage.json"
  dor_semantic_blocking_codes "$sem" >"$out/codes.json"
}

# ── 1. dor_semantic_blocking_codes ─────────────────────────────────────────

codes=$(dor_semantic_blocking_codes '{"unavailable":true,"unverified_gaps":["edge_case_sufficiency"],"findings":[
  {"severity":"blocking","dimension":"scope","verified":true},
  {"severity":"advisory","dimension":"test_uat","verified":true},
  {"severity":"blocking","dimension":"edge_cases","verified":false},
  {"severity":"blocking","dimension":"scope","verified":true}]}')
_check "blocking_codes: unavailable + unverified + one code per blocking dimension, sorted unique" \
  [ "$codes" = '["SEMANTIC_EDGE_CASES","SEMANTIC_SCOPE","SEMANTIC_UNAVAILABLE","SEMANTIC_UNVERIFIED"]' ]
_check "blocking_codes: an empty verdict yields []" [ "$(dor_semantic_blocking_codes '{"findings":[]}')" = "[]" ]
rc=0
dor_semantic_blocking_codes '[1]' >/dev/null || rc=$?
_check "blocking_codes: a non-object is rc 1" [ "$rc" = "1" ]

# ── 2. dor_semantic_findings: rc 2 on mismatch; apply keeps rc 1 ──────────

b22=$(_body_of 22)
s=$(_scan_json "MM-1" "$b22" '[]')
a=$(_audit_json "MM-1" "$b22")
rc=0
dor_semantic_findings "MM-2" "$(cat "$b22")" "$s" "$a" >/dev/null 2>&1 || rc=$?
_check "findings: ticket mismatch is rc 2" [ "$rc" = "2" ]
rc=0
dor_semantic_findings "MM-1" "$(cat "$b22") changed" "$s" "$a" >/dev/null 2>&1 || rc=$?
_check "findings: body-hash mismatch is rc 2" [ "$rc" = "2" ]
_fresh_manifest "MM-2" "$b22"
rc=0
dor_semantic_apply "MM-2" "$b22" "$s" "$a" >/dev/null 2>&1 || rc=$?
_check "apply: still rc 1 on a ticket mismatch (maps findings' 2)" [ "$rc" = "1" ]

# ── 3. Parity (D16) over the golden set ────────────────────────────────────
# apply on a fresh manifest vs findings + lineage_from(null) + blocking codes.

_parity() { # _parity <label> <tid> <body-file> <scan-json> <audit-json>
  local label="$1" tid="$2" bf="$3" scan="$4" audit="$5" ready d
  _fresh_manifest "$tid" "$bf"
  dor_semantic_apply "$tid" "$bf" "$scan" "$audit" >/dev/null 2>&1 || {
    _fail "parity $label: apply failed"
    return 0
  }
  d="$TMP_ROOT/parity-$tid"
  _draft_eval "$tid" "$bf" "$scan" "$audit" null "$d" || {
    _fail "parity $label: draft path failed"
    return 0
  }
  ready=$(get_ticket_manifest_field "$tid" ready)
  if [ "$(echo "$ready" | jq -cS '.semantic.findings')" = "$(jq -cS '.findings' "$d/semantic.json")" ] &&
    [ "$(echo "$ready" | jq -cS '.semantic.unverified_gaps')" = "$(jq -cS '.unverified_gaps' "$d/semantic.json")" ] &&
    [ "$(echo "$ready" | jq -cS '.semantic | del(.checked_at)')" = "$(jq -cS 'del(.checked_at)' "$d/semantic.json")" ] &&
    [ "$(echo "$ready" | jq -c '[.missing[] | select(startswith("SEMANTIC_"))] | sort')" = "$(cat "$d/codes.json")" ] &&
    [ "$(echo "$ready" | jq -cS '.lineage')" = "$(jq -cS . "$d/lineage.json")" ]; then
    _pass "parity $label: findings, severity, verified, gaps, ids, lineage and SEMANTIC_* codes equal"
  else
    _fail "parity $label: apply and draft path disagree"
  fi
}

for nn in 26 27 28 29 30; do
  bf=$(_body_of "$nn")
  tid="PAR-$nn"
  scan=$(_canned "$SEMANTIC_DIR/$nn-scan.txt" "$tid" "$bf" scan)
  audit=$(_canned "$SEMANTIC_DIR/$nn-audit.txt" "$tid" "$bf" audit)
  _parity "fixture $nn" "$tid" "$bf" "$scan" "$audit"
done

# Synthetic: an unverified quote, an unverified gap, a structural pair, a
# blocking non-structural finding and an advisory code.
gaps_uv=$(echo "$_ALL_CLEAR_GAPS" | jq -c '.edge_case_sufficiency.verdict = "finding"')
syn=$(jq -nc --argjson a "$(_f CONTRADICTORY_REQUIREMENTS "Uploading a valid 1,000-row file imports all 1,000 rows" "imports nothing")" \
  --argjson b "$(_f SCOPE_AMBIGUOUS "Frontend everything")" \
  --argjson c "$(_f AC_NOT_TESTABLE "A user without the ops role does not see the Upload menu item")" \
  --argjson d "$(_f TEST_DATA_GAP "Uploading a file with an invalid row shows an error message naming the row number and imports nothing")" \
  '[$a, $b, $c, $d]')
_parity "synthetic mix" "PAR-S" "$b22" "$(_scan_json PAR-S "$b22" "$syn" "$gaps_uv")" "$(_audit_json PAR-S "$b22")"
DOR_SEMANTIC_ADVISORY_CODES="AC_NOT_TESTABLE" _parity "synthetic, advisory env" "PAR-E" "$b22" \
  "$(_scan_json PAR-E "$b22" "$syn")" "$(_audit_json PAR-E "$b22")"

# ── 4. lineage_from: wrapper output unchanged; null prior is round 1 ──────

base_body='## Summary
Save handovers reliably from the settings page.

## Background
Attorneys report the Save button silently failing on the settings page.

## Acceptance Criteria
- [ ] Save button stores the handover
- [ ] Error toast appears on a failed save
- [ ] Confirmation toast appears on success

## Scope
Frontend settings page only.

## Related Tickets
- none
'
bfile="$TMP_ROOT/conv.md"
printf '%s' "$base_body" >"$bfile"
cf=$(jq -nc --argjson a "$(_f EDGE_CASE_GAP "Error toast appears on a failed save")" \
  --argjson b "$(_f AC_NOT_TESTABLE "Confirmation toast appears on success")" '[$a, $b]')
write_ticket_manifest "CONV-1" "INIT-1" "feature" '[]' >/dev/null
set_ticket_readiness "CONV-1" "ready" '[]' '[]' >/dev/null
dor_semantic_apply "CONV-1" "$bfile" "$(_scan_json CONV-1 "$bfile" "$cf")" "$(_audit_json CONV-1 "$bfile")" >/dev/null
printf '%s' "${base_body/Confirmation toast appears on success/Confirmation toast appears within 2s of success}" >"$bfile"
body2=$(cat "$bfile")
h2=$(_dor_body_hash "$body2")
judged=$(dor_semantic_findings CONV-1 "$body2" "$(_scan_json CONV-1 "$bfile" "$cf")" "$(_audit_json CONV-1 "$bfile")")
fj=$(echo "$judged" | jq -c .findings)
prior=$(get_ticket_manifest_field CONV-1 ready | jq -c .lineage)
for max in "" 1; do
  w=$(DOR_SEMANTIC_MAX_ROUNDS="$max" DOR_SEMANTIC_DRIFT_DEMOTE=true _dor_semantic_lineage CONV-1 "$body2" "$h2" "$fj" '[]' 2>/dev/null)
  p=$(DOR_SEMANTIC_MAX_ROUNDS="$max" DOR_SEMANTIC_DRIFT_DEMOTE=true dor_semantic_lineage_from "$prior" "$body2" "$h2" "$fj" '[]' 2>/dev/null)
  _check "lineage_from: equals the manifest wrapper on a round-2 convergence fixture (MAX_ROUNDS='$max')" \
    [ "$(echo "$w" | jq -cS .)" = "$(echo "$p" | jq -cS .)" ]
done
_check "lineage_from: the convergence fixture is round 2 with a carried finding" \
  [ "$(echo "$p" | jq -r '.lineage.round')" = "2" ]
_check "lineage_from: MAX_ROUNDS=1 demotes the non-structural finding round-limit" \
  [ "$(echo "$p" | jq -r '[.findings[] | select(.demoted == "round-limit")] | length')" = "2" ]
p0=$(dor_semantic_lineage_from null "$body2" "$h2" "$fj" '[]')
_check "lineage_from: a null prior gives round 1, every finding new" \
  [ "$(echo "$p0" | jq -r '"\(.lineage.round) \([.findings[].lineage] | unique | join(","))"')" = "1 new" ]
_check "lineage_from: policy has no prior_passed key when the policy is off" \
  [ "$(echo "$p0" | jq -r '.lineage.policy | has("prior_passed")')" = "false" ]

# ── 5. Draft-passed policy (DOR_SEMANTIC_PRIOR_PASSED, D13) ────────────────

pp_a="$base_body"
pp_b=${base_body/Confirmation toast appears on success/Confirmation toast appears within 2s of success}
printf '%s' "$pp_a" >"$TMP_ROOT/pp-a.md"
printf '%s' "$pp_b" >"$TMP_ROOT/pp-b.md"
pa=$(cat "$TMP_ROOT/pp-a.md")
pb=$(cat "$TMP_ROOT/pp-b.md")
prior_pp=$(dor_semantic_lineage_from null "$pa" "$(_dor_body_hash "$pa")" '[]' '[]' | jq -c .lineage)
ppf=$(jq -nc \
  --argjson a "$(_f EDGE_CASE_GAP "Error toast appears on a failed save")" \
  --argjson b "$(_f CONTRADICTORY_REQUIREMENTS "Save button stores the handover" "Error toast appears on a failed save")" \
  --argjson c "$(_f INTENT_AC_MISMATCH "Confirmation toast appears within 2s of success")" \
  --argjson d "$(_f SCOPE_AMBIGUOUS "text that is not in the body")" '[$a, $b, $c, $d]')
ppj=$(dor_semantic_findings PP-1 "$pb" "$(_scan_json PP-1 "$TMP_ROOT/pp-b.md" "$ppf")" "$(_audit_json PP-1 "$TMP_ROOT/pp-b.md")" | jq -c .findings)
on=$(DOR_SEMANTIC_PRIOR_PASSED=true dor_semantic_lineage_from "$prior_pp" "$pb" "$(_dor_body_hash "$pb")" "$ppj" '[]')
off=$(dor_semantic_lineage_from "$prior_pp" "$pb" "$(_dor_body_hash "$pb")" "$ppj" '[]')
_g() { echo "$1" | jq -r --arg c "$2" "[.findings[] | select(.code == \$c)][0] | $3"; }
_check "prior-passed: a verified non-structural finding is advisory, demoted draft-passed" \
  [ "$(_g "$on" EDGE_CASE_GAP '"\(.severity) \(.demoted)"')" = "advisory draft-passed" ]
_check "prior-passed: a new structural finding on unchanged units is draft-passed-structural with a reason" \
  [ "$(_g "$on" CONTRADICTORY_REQUIREMENTS '"\(.severity) \(.demoted) \(.demote_reason)"')" = "advisory draft-passed-structural unchanged-unit" ]
_check "prior-passed: a structural finding on a changed unit still blocks" \
  [ "$(_g "$on" INTENT_AC_MISMATCH '"\(.severity) \(.demoted // "none")"')" = "blocking none" ]
_check "prior-passed: an unverified finding is untouched (blocking, unverified)" \
  [ "$(_g "$on" SCOPE_AMBIGUOUS '"\(.severity) \(.verified) \(.demoted // "none")"')" = "blocking false none" ]
_check "prior-passed: the policy snapshot records prior_passed" \
  [ "$(echo "$on" | jq -r '.lineage.policy.prior_passed')" = "true" ]
_check "prior-passed off: the same inputs keep all three verified findings blocking" \
  [ "$(echo "$off" | jq -r '[.findings[] | select(.verified and .severity == "blocking")] | length')" = "3" ]
# Reset disabled: rewrite most sections (the reset rule would restart at 1).
pp_r=${base_body/Save handovers reliably from the settings page./Rewrite: archive handovers instead.}
pp_r=${pp_r/Attorneys report the Save button silently failing on the settings page./New background entirely./}
pp_r=${pp_r/Frontend settings page only./Backend archive service and frontend list./}
r_off=$(dor_semantic_lineage_from "$prior_pp" "$pp_r" "$(_dor_body_hash "$pp_r")" '[]' '[]')
r_on=$(DOR_SEMANTIC_PRIOR_PASSED=true dor_semantic_lineage_from "$prior_pp" "$pp_r" "$(_dor_body_hash "$pp_r")" '[]' '[]')
_check "prior-passed: the reset rule is disabled (round 2, not a reset to 1)" \
  [ "$(echo "$r_off" | jq -r '"\(.lineage.round) \(.lineage.reset)"')/$(echo "$r_on" | jq -r '"\(.lineage.round) \(.lineage.reset)"')" = "1 true/2 false" ]

# ── 6. dor_semantic_import ─────────────────────────────────────────────────

draft_body="$(_body_of 30)"
draft_tid="DRAFT-client-upload-validate"
TOKMAP='{"DRAFT-client-upload-row-schema":"WIL-126","DRAFT-client-upload-test-data":"WIL-127","DRAFT":"WIL-125"}'
real_body="$TMP_ROOT/real.md"
sed -e 's/DRAFT-client-upload-row-schema/WIL-126/; s/DRAFT-client-upload-test-data/WIL-127/; s/\*\*Epic:\*\* DRAFT/**Epic:** WIL-125/' \
  "$draft_body" >"$real_body"
# A Linear-style rendering of the Related Tickets line: the rewritten quote
# no longer locates there.
linked_body="$TMP_ROOT/linked.md"
sed -e 's/Blocked by WIL-126 — /Blocked by [WIL-126](https:\/\/linear.app\/x\/issue\/WIL-126) — /' "$real_body" >"$linked_body"

dep_quote="Blocked by DRAFT-client-upload-row-schema — Shared client upload row schema"

# Blocking draft verdict: the live scan (INTENT_AC_MISMATCH, EDGE_CASE_GAP,
# 2x TEST_DATA_GAP) plus one finding quoting a draft id. Evaluated twice so
# the stored lineage is round 2, the second time past MAX_ROUNDS=1, so the
# EDGE_CASE_GAP carries a round-limit demotion.
live=$(_canned "$SEMANTIC_DIR/30-scan.txt" "$draft_tid" "$draft_body" scan)
# The live scan marks GAP_REQUIREMENT_COMPLETENESS "finding" with no finding
# in that dimension (an unverified gap, SEMANTIC_UNVERIFIED); clear it so the
# only blocking code left is the structural one.
live=$(echo "$live" | jq -c --argjson x "$(_f AC_NOT_TESTABLE "$dep_quote")" \
  '.findings += [$x] | .gaps.requirement_completeness.verdict = "clear"')
daud=$(_canned "$SEMANTIC_DIR/30-audit.txt" "$draft_tid" "$draft_body" audit)
v0="$TMP_ROOT/draft-v0.md"
sed -e 's/^Validate bulk client uploads before import./Validate bulk client uploads./' "$draft_body" >"$v0"
_draft_eval "$draft_tid" "$v0" "$(_scan_json "$draft_tid" "$v0" '[]')" "$(_audit_json "$draft_tid" "$v0")" null "$TMP_ROOT/d0"
DOR_SEMANTIC_MAX_ROUNDS=1 _draft_eval "$draft_tid" "$draft_body" "$live" "$daud" "$(cat "$TMP_ROOT/d0/lineage.json")" "$TMP_ROOT/dB"
_check "import setup: the blocking draft is round 2 with EDGE_CASE_GAP demoted round-limit" \
  [ "$(jq -r '.round' "$TMP_ROOT/dB/lineage.json")/$(jq -r '[.findings[] | select(.code == "EDGE_CASE_GAP")][0].demoted' "$TMP_ROOT/dB/semantic.json")" = "2/round-limit" ]

# (a) blocking import on an equivalent body.
_fresh_manifest "WIL-130" "$real_body"
out=$(dor_semantic_import "WIL-130" "$real_body" "$TMP_ROOT/dB/semantic.json" "$TMP_ROOT/dB/lineage.json" "$TOKMAP")
rd=$(get_ticket_manifest_field WIL-130 ready)
_check "import: prints round=2 (unchanged), the two round-limit demotions and no drops" [ "$out" = "round=2 demoted=2 dropped=0" ]
_check "import: the blocking structural finding keeps its code (SEMANTIC_INTENT), no SEMANTIC_UNVERIFIED" \
  [ "$(echo "$rd" | jq -c '[.missing[] | select(startswith("SEMANTIC_"))]')" = '["SEMANTIC_INTENT"]' ]
_check "import: the round-limit demotion stays advisory" \
  [ "$(echo "$rd" | jq -r '[.semantic.findings[] | select(.code == "EDGE_CASE_GAP")][0] | "\(.severity) \(.demoted)"')" = "advisory round-limit" ]
_check "import: the DRAFT-<slug> quote is rewritten to the real id and verified" \
  [ "$(echo "$rd" | jq -r '[.semantic.findings[] | select(.code == "AC_NOT_TESTABLE")][0] | "\(.verified) \(.quote)"')" = "true Blocked by WIL-126 — Shared client upload row schema" ]
_check "import: labels, first rounds and severities equal the draft's; lineage bound to the real body hash" \
  [ "$(echo "$rd" | jq -r --arg h "$(_dor_body_hash "$(cat "$real_body")")" \
    '"\(.lineage.body_hash == $h) \(.semantic.body_hash == $h) \([.semantic.findings[] | [.code, .lineage, .first_round, .severity]])"')" = \
  "true true $(jq -c '[.findings[] | [.code, .lineage, .first_round, .severity]]' "$TMP_ROOT/dB/semantic.json")" ]
_check "import: the verdict records imported_from the draft hash" \
  [ "$(echo "$rd" | jq -r '.semantic.imported_from')" = "$(jq -r .body_hash "$TMP_ROOT/dB/semantic.json")" ]
# A deterministic rescan on the same body keeps the imported verdict.
set_ticket_readiness "WIL-130" "ready" '[]' '[]' "{\"body_hash\": \"$(_dor_body_hash "$(cat "$real_body")")\"}" >/dev/null
_check "import: a later deterministic rescan on the same body keeps the verdict (not stale)" \
  [ "$(get_ticket_manifest_field WIL-130 ready | jq -r '.semantic.stale // false')" = "false" ]

# (b) the draft-id quote does not locate after rewrite: dropped, no UNVERIFIED.
# This case passes the map as a TSV file (ticket-planner's
# planner_draft_readiness_token_map format), longest token first.
TOKTSV="$TMP_ROOT/token-map.tsv"
printf 'DRAFT-client-upload-row-schema\tWIL-126\nDRAFT-client-upload-test-data\tWIL-127\nDRAFT\tWIL-125\n' >"$TOKTSV"
_fresh_manifest "WIL-131" "$linked_body"
out=$(dor_semantic_import "WIL-131" "$linked_body" "$TMP_ROOT/dB/semantic.json" "$TMP_ROOT/dB/lineage.json" "$TOKTSV")
rd=$(get_ticket_manifest_field WIL-131 ready)
_check "import: an unlocatable rewritten quote is dropped (dropped=1)" [ "${out##* }" = "dropped=1" ]
_check "import: the dropped finding is gone and no SEMANTIC_UNVERIFIED results" \
  [ "$(echo "$rd" | jq -r '"\([.semantic.findings[] | select(.code == "AC_NOT_TESTABLE")] | length) \(.missing | index("SEMANTIC_UNVERIFIED"))"')" = "0 null" ]
_check "import: the dropped finding leaves the lineage, not reported resolved" \
  [ "$(echo "$rd" | jq -r '"\(.lineage.findings | length) \(.lineage.resolved | length)"')" = "4 0" ]

# The TSV map rewrites exactly like the JSON map.
_fresh_manifest "WIL-135" "$real_body"
out=$(dor_semantic_import "WIL-135" "$real_body" "$TMP_ROOT/dB/semantic.json" "$TMP_ROOT/dB/lineage.json" "$TOKTSV")
_check "import: a TSV token map gives the same verdict as the JSON map" \
  [ "$out/$(get_ticket_manifest_field WIL-135 ready | jq -cS '.semantic.findings')" = \
  "round=2 demoted=2 dropped=0/$(get_ticket_manifest_field WIL-130 ready | jq -cS '.semantic.findings')" ]

# (c) advisory-only import: no SEMANTIC_* code at all.
adv=$(jq -nc --argjson a "$(_f TEST_DATA_GAP "A user without the ops role does not see the Upload menu item")" '[$a]')
_draft_eval "$draft_tid" "$draft_body" "$(_scan_json "$draft_tid" "$draft_body" "$adv")" \
  "$(_audit_json "$draft_tid" "$draft_body")" null "$TMP_ROOT/dA"
_fresh_manifest "WIL-132" "$real_body"
dor_semantic_import "WIL-132" "$real_body" "$TMP_ROOT/dA/semantic.json" "$TMP_ROOT/dA/lineage.json" "$TOKMAP" >/dev/null
rd=$(get_ticket_manifest_field WIL-132 ready)
_check "import: advisory-only import adds no SEMANTIC_* code and the ticket stays ready" \
  [ "$(echo "$rd" | jq -r '"\([.missing[] | select(startswith("SEMANTIC_"))] | length) \(.status)"')" = "0 ready" ]

# (d) no ready object: created.
write_ticket_manifest "WIL-133" "INIT-1" "feature" '[]' >/dev/null
rc=0
dor_semantic_import "WIL-133" "$real_body" "$TMP_ROOT/dA/semantic.json" "$TMP_ROOT/dA/lineage.json" "$TOKMAP" >/dev/null || rc=$?
rd=$(get_ticket_manifest_field WIL-133 ready)
_check "import: with no ready object it creates one and stores the verdict" \
  [ "$rc/$(echo "$rd" | jq -r '"\(.semantic.evaluator) \(.body_hash == .semantic.body_hash)"')" = "0/$DOR_SEMANTIC_EVALUATOR true" ]

# (e) existing ready.semantic: refused, unchanged.
before=$(get_ticket_manifest_field WIL-132 ready | jq -cS .)
rc=0
dor_semantic_import "WIL-132" "$real_body" "$TMP_ROOT/dB/semantic.json" "$TMP_ROOT/dB/lineage.json" "$TOKMAP" >/dev/null 2>&1 || rc=$?
_check "import: an existing ready.semantic is refused (rc 2) and left untouched" \
  [ "$rc/$(get_ticket_manifest_field WIL-132 ready | jq -cS .)" = "2/$before" ]

# (f) another evaluator: refused. No manifest: rc 1.
_fresh_manifest "WIL-134" "$real_body"
rc=0
dor_semantic_import "WIL-134" "$real_body" "$(jq -c '.evaluator = "dor-semantic-v2"' "$TMP_ROOT/dA/semantic.json")" null >/dev/null 2>&1 || rc=$?
_check "import: a draft from another evaluator is refused (rc 2)" [ "$rc" = "2" ]
rc=0
dor_semantic_import "WIL-999" "$real_body" "$TMP_ROOT/dA/semantic.json" null >/dev/null 2>&1 || rc=$?
_check "import: no manifest is rc 1" [ "$rc" = "1" ]

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
