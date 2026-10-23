#!/usr/bin/env bash
# test-planner-body-drift.sh — body drift on the planner side
# (planner-refinement-convergence group 7, design D6): the Refinement scan
# classifies every child against its Linear baseline, --refresh-bodies takes
# Linear for every drifted child, TicketGen records the baseline, and the halt
# report offers the refresh, never a waive.
#
# planner_linear_get_issue is stubbed: it answers from
# ${REPOS_ROOT}/linear/<TID>.md and fails when that file is absent or
# ${REPOS_ROOT}/linear/<TID>.fail exists. No network.
#
# Run: bash ticket-planner/lib/tests/test-planner-body-drift.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
TAP_LIB="${LIB_DIR}/../../ticket-auto-pipeline/lib"
FIXTURES_DIR="${TAP_LIB}/tests/fixtures/dor"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Empty HOME: every cross-plugin dependency resolves to the sibling
# ticket-auto-pipeline/lib under test, as in CI.
export HOME="${TMPDIR}/home"
mkdir -p "$HOME"

unset DOR_SEMANTIC_MAX_ROUNDS DOR_SEMANTIC_DRIFT_DEMOTE DOR_SEMANTIC_ROUND_RESET_SHARE \
  DOR_SEMANTIC_STRUCTURAL_CODES DOR_SEMANTIC_ADVISORY_CODES DOR_SEMANTIC_INERT_SECTIONS \
  PLANNER_REFINEMENT_MAX_ROUNDS PLANNER_REFINEMENT_AUDIT_DEMOTE \
  PLANNER_REFINEMENT_DRIFT_CHECK PLANNER_REFINEMENT_DRIFT_MAX_FAILS

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-refinement.sh"
_planner_refinement_source_deps
source "${TAP_LIB}/body-baseline.sh"

export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT/linear"

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

echo "=== planner body-drift tests ==="

# ── helpers ────────────────────────────────────────────────────────────────

planner_linear_get_issue() {
  echo "$1" >>"${REPOS_ROOT}/linear/calls"
  [ -f "${REPOS_ROOT}/linear/${1}.fail" ] && return 1
  [ -f "${REPOS_ROOT}/linear/${1}.md" ] || return 1
  jq -nc --rawfile d "${REPOS_ROOT}/linear/${1}.md" '{data:{issue:{identifier:"x",description:$d}}}'
}

_pdir() { echo "${REPOS_ROOT}/.ticket-auto/initiatives/${1}/tickets/${2}/planner"; }

# _setup <INIT> <EPIC>
_setup() {
  planner_state_init "$1" "body drift idea" >/dev/null
  planner_state_write "$1" "EpicGen" "create" "done" "EPIC_ID=${2}"
  planner_state_write "$1" "TicketGen" "verify" "done" "ok"
  write_epic_manifest "$2" "" "per-ticket" "" '[]' >/dev/null
}

# _child <INIT> <EPIC> <TID> — body.md = Linear = baseline = dor fixture 22.
_child() {
  local pdir
  write_ticket_manifest "$3" "$1" "feature" '[]' >/dev/null
  add_epic_manifest_child "$2" "$3" >/dev/null
  pdir=$(_pdir "$1" "$3")
  mkdir -p "$pdir"
  cp "${FIXTURES_DIR}/22-sourced-contract.md" "${pdir}/body.md"
  cp "${FIXTURES_DIR}/22-sourced-contract.md" "${REPOS_ROOT}/linear/${3}.md"
  body_baseline_write "$pdir" "$(cat "${pdir}/body.md")"
}

# _edit_file <file> <from> <to>
_edit_file() {
  FROM="$2" TO="$3" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$1"
}
_edit_body() { _edit_file "$(_pdir "$1" "$2")/body.md" "$3" "$4"; }
_edit_linear() { _edit_file "${REPOS_ROOT}/linear/${1}.md" "$2" "$3"; }

_hash() { _dor_body_hash "$(cat "$(_pdir "$1" "$2")/body.md")"; }

# Canned semantic results, no findings (the scan of the current body).
_scan_clean() {
  local hash gap
  hash=$(_hash "$1" "$2")
  {
    printf '=== DOR_SEMANTIC_SCAN ===\nSCHEMA_VERSION: 1\nTICKET: %s\nBODY_HASH: %s\n' "$2" "$hash"
    for gap in REQUIREMENT_COMPLETENESS CONTRADICTORY_REQUIREMENTS DEEP_SCOPE_AMBIGUITY EDGE_CASE_SUFFICIENCY; do
      printf 'GAP_%s: clear\nGAP_%s_REASON: canned\n' "$gap" "$gap"
    done
    printf '=== END DOR_SEMANTIC_SCAN ===\n'
  } >"$(_pdir "$1" "$2")/semantic-scan-result.txt"
  printf '=== DOR_SEMANTIC_AUDIT ===\nSCHEMA_VERSION: 1\nTICKET: %s\nBODY_HASH: %s\nSCORE_PLAUSIBLE: yes\nSCORE_REASON: matches\n=== END DOR_SEMANTIC_AUDIT ===\n' \
    "$2" "$hash" >"$(_pdir "$1" "$2")/semantic-audit-result.txt"
}

_ready() { get_ticket_manifest_field "$1" ready 2>/dev/null; }
_status() { _ready "$1" | jq -r '.status // "none"'; }
_round() { _ready "$1" | jq -r '.lineage.round // "none"'; }
_has_missing() { _ready "$1" | jq -e --arg c "$2" '(.missing // []) | index($c) != null' >/dev/null 2>&1; }
_result_has() { jq -e --arg c "$3" '(.missing // []) | index($c) != null' "$(_pdir "$1" "$2")/dor-result.json" >/dev/null 2>&1; }
_baseline() { body_baseline_read "$(_pdir "$1" "$2")" 2>/dev/null || echo none; }
_linear_hash() { body_baseline_hash "$(cat "${REPOS_ROOT}/linear/${1}.md")"; }

E_FROM="Validate bulk client uploads before import."

# ── 1. adopt ───────────────────────────────────────────────────────────────

echo "--- adopt: a Linear-only edit is taken, logged and rescanned ---"

A_INIT="INIT-1700000200-0001"
A_EPIC="PRO-500"
_setup "$A_INIT" "$A_EPIC"
_child "$A_INIT" "$A_EPIC" "PRO-501"
planner_refinement_scan "$A_INIT" >/dev/null
_scan_clean "$A_INIT" "PRO-501"
planner_refinement_apply "$A_INIT" "PRO-501" >/dev/null 2>&1
if [ "$(_status "PRO-501")" = "ready" ] && [ "$(_round "PRO-501")" = "1" ]; then
  pass "clean child: ready at round 1, no drift code"
else
  fail "clean child: ready at round 1, no drift code" "ready=$(_ready "PRO-501")"
fi

old8=$(_baseline "$A_INIT" "PRO-501" | cut -c1-8)
_edit_linear "PRO-501" "$E_FROM" "Validate every bulk client upload before import."
new8=$(_linear_hash "PRO-501" | cut -c1-8)
needs=$(planner_refinement_scan "$A_INIT")
if grep -qF "Validate every bulk client upload before import." "$(_pdir "$A_INIT" "PRO-501")/body.md" &&
  [ "$(_baseline "$A_INIT" "PRO-501")" = "$(_linear_hash "PRO-501")" ]; then
  pass "adopt: body.md and the baseline hold the Linear text"
else
  fail "adopt: body.md and the baseline hold the Linear text" "baseline=$(_baseline "$A_INIT" "PRO-501")"
fi
if grep -qF "|META|refinement|step|PRO-501 body adopted from Linear [${old8}→${new8}]" "$(planner_state_log "$A_INIT")"; then
  pass "adopt: META|refinement|step line names the old and new hash8"
else
  fail "adopt: META|refinement|step line names the old and new hash8" "$(grep refinement "$(planner_state_log "$A_INIT")")"
fi
if [ "$needs" = "PRO-501" ] && ! _has_missing "PRO-501" "BODY_DRIFT"; then
  pass "adopt: listed for a semantic pass, no BODY_DRIFT"
else
  fail "adopt: listed for a semantic pass, no BODY_DRIFT" "needs=$needs ready=$(_ready "PRO-501")"
fi
_scan_clean "$A_INIT" "PRO-501"
planner_refinement_apply "$A_INIT" "PRO-501" >/dev/null 2>&1
if [ "$(_round "PRO-501")" = "2" ] && [ "$(_status "PRO-501")" = "ready" ]; then
  pass "adopt: the adopted body is a new round (2)"
else
  fail "adopt: the adopted body is a new round (2)" "round=$(_round "PRO-501")"
fi
needs=$(planner_refinement_scan "$A_INIT")
if [ -z "$needs" ] && [ "$(grep -c 'body adopted from Linear' "$(planner_state_log "$A_INIT")")" = "1" ]; then
  pass "adopt: the next scan is clean — nothing adopted twice, nothing rescanned"
else
  fail "adopt: the next scan is clean" "needs=$needs"
fi

# ── 2. conflict and local-ahead ────────────────────────────────────────────

echo "--- conflict and local-ahead block with BODY_DRIFT ---"

C_INIT="INIT-1700000200-0002"
C_EPIC="PRO-510"
_setup "$C_INIT" "$C_EPIC"
_child "$C_INIT" "$C_EPIC" "PRO-511"
_child "$C_INIT" "$C_EPIC" "PRO-512"
_child "$C_INIT" "$C_EPIC" "PRO-513"
_edit_linear "PRO-511" "$E_FROM" "Validate uploads (Linear edit)."
_edit_body "$C_INIT" "PRO-511" "$E_FROM" "Validate uploads (local edit)."
_edit_body "$C_INIT" "PRO-512" "$E_FROM" "Validate uploads (local only)."
before_511=$(cat "$(_pdir "$C_INIT" "PRO-511")/body.md")
planner_refinement_scan "$C_INIT" >/dev/null
if _has_missing "PRO-511" "BODY_DRIFT" && [ "$(_status "PRO-511")" = "not-ready" ] &&
  [ "$(cat "$(_pdir "$C_INIT" "PRO-511")/body.md")" = "$before_511" ]; then
  pass "conflict: BODY_DRIFT, not ready, body.md untouched"
else
  fail "conflict: BODY_DRIFT, not ready, body.md untouched" "ready=$(_ready "PRO-511")"
fi
if _has_missing "PRO-512" "BODY_DRIFT" && [ "$(_status "PRO-512")" = "not-ready" ]; then
  pass "local-ahead: BODY_DRIFT, not ready"
else
  fail "local-ahead: BODY_DRIFT, not ready" "ready=$(_ready "PRO-512")"
fi
if ! _result_has "$C_INIT" "PRO-511" "BODY_DRIFT" && ! _result_has "$C_INIT" "PRO-512" "BODY_DRIFT" &&
  [ -s "$(_pdir "$C_INIT" "PRO-511")/dor-result.json" ]; then
  pass "BODY_DRIFT is absent from dor-result.json (the audit never judges it)"
else
  fail "BODY_DRIFT is absent from dor-result.json" "$(cat "$(_pdir "$C_INIT" "PRO-511")/dor-result.json")"
fi
if ! _has_missing "PRO-513" "BODY_DRIFT"; then
  pass "a clean sibling gets no drift code"
else
  fail "a clean sibling gets no drift code" "ready=$(_ready "PRO-513")"
fi
if ! bash "${TAP_LIB}/dor-check.sh" --waive PRO-511 BODY_DRIFT "x" >/dev/null 2>&1 && _has_missing "PRO-511" "BODY_DRIFT" &&
  [ "$(_ready "PRO-511" | jq -r '.waived.BODY_DRIFT // "none"')" = "none" ]; then
  pass "dor-check.sh --waive refuses BODY_DRIFT"
else
  fail "dor-check.sh --waive refuses BODY_DRIFT" "ready=$(_ready "PRO-511")"
fi
report=$(planner_refinement_report "$C_INIT")
if echo "$report" | grep -qF "PRO-511 body drift (conflict)" &&
  echo "$report" | grep -qF "/ticket-planner resume ${C_INIT} --refresh-bodies" &&
  echo "$report" | grep -qF "PRO-512 body drift (local-ahead)" &&
  echo "$report" | grep -A2 -F "PRO-512 body drift (local-ahead)" | grep -qi "copy the local edit into Linear first" &&
  ! echo "$report" | grep -q -- "--waive PRO-51[12] BODY_DRIFT"; then
  pass "report: names --refresh-bodies for conflict and local-ahead, never a waive"
else
  fail "report: names --refresh-bodies for conflict and local-ahead, never a waive" "$report"
fi
if ! planner_refinement_gate "$C_INIT" >/dev/null 2>&1; then
  pass "the gate halts on BODY_DRIFT"
else
  fail "the gate halts on BODY_DRIFT" "gate passed"
fi

# A failed read does not drop a known drift.
touch "${REPOS_ROOT}/linear/PRO-511.fail"
planner_refinement_scan "$C_INIT" >/dev/null
if _has_missing "PRO-511" "BODY_DRIFT" && ! _has_missing "PRO-511" "BODY_UNVERIFIED"; then
  pass "a failed read keeps a recorded BODY_DRIFT (fail-closed)"
else
  fail "a failed read keeps a recorded BODY_DRIFT (fail-closed)" "ready=$(_ready "PRO-511")"
fi
rm -f "${REPOS_ROOT}/linear/PRO-511.fail"

# ── 3. rebaseline ──────────────────────────────────────────────────────────

echo "--- rebaseline ---"

R_INIT="INIT-1700000200-0003"
R_EPIC="PRO-520"
_setup "$R_INIT" "$R_EPIC"
_child "$R_INIT" "$R_EPIC" "PRO-521"
_child "$R_INIT" "$R_EPIC" "PRO-522"
_child "$R_INIT" "$R_EPIC" "PRO-523"
# Both sides made the same edit.
_edit_linear "PRO-521" "$E_FROM" "Validate uploads (same edit)."
_edit_body "$R_INIT" "PRO-521" "$E_FROM" "Validate uploads (same edit)."
# No baseline, Linear == body.md.
rm -f "$(_pdir "$R_INIT" "PRO-522")/linear-baseline.sha"
# No baseline, Linear != body.md.
rm -f "$(_pdir "$R_INIT" "PRO-523")/linear-baseline.sha"
_edit_linear "PRO-523" "$E_FROM" "Validate uploads (differs)."
before_521=$(cat "$(_pdir "$R_INIT" "PRO-521")/body.md")
planner_refinement_scan "$R_INIT" >/dev/null
if [ "$(_baseline "$R_INIT" "PRO-521")" = "$(_linear_hash "PRO-521")" ] && ! _has_missing "PRO-521" "BODY_DRIFT" &&
  [ "$(cat "$(_pdir "$R_INIT" "PRO-521")/body.md")" = "$before_521" ] &&
  ! grep -qF "PRO-521 body adopted" "$(planner_state_log "$R_INIT")"; then
  pass "rebaseline (same edit): only the baseline is written"
else
  fail "rebaseline (same edit): only the baseline is written" "baseline=$(_baseline "$R_INIT" "PRO-521") ready=$(_ready "PRO-521")"
fi
if [ "$(_baseline "$R_INIT" "PRO-522")" = "$(_linear_hash "PRO-522")" ] && ! _has_missing "PRO-522" "BODY_DRIFT"; then
  pass "rebaseline (no baseline, same text): baseline written"
else
  fail "rebaseline (no baseline, same text): baseline written" "baseline=$(_baseline "$R_INIT" "PRO-522")"
fi
if _has_missing "PRO-523" "BODY_DRIFT" && [ "$(_baseline "$R_INIT" "PRO-523")" = "none" ]; then
  pass "no baseline and differing text: BODY_DRIFT, no baseline written"
else
  fail "no baseline and differing text: BODY_DRIFT" "ready=$(_ready "PRO-523")"
fi

# A missing body.md is fetched once and baselined in the same scan.
write_ticket_manifest "PRO-524" "$R_INIT" "feature" '[]' >/dev/null
add_epic_manifest_child "$R_EPIC" "PRO-524" >/dev/null
cp "${FIXTURES_DIR}/22-sourced-contract.md" "${REPOS_ROOT}/linear/PRO-524.md"
planner_refinement_scan "$R_INIT" >/dev/null
if [ -s "$(_pdir "$R_INIT" "PRO-524")/body.md" ] && [ "$(_baseline "$R_INIT" "PRO-524")" = "$(_linear_hash "PRO-524")" ] &&
  ! _has_missing "PRO-524" "BODY_DRIFT"; then
  pass "a fetched missing body.md is baselined, no drift"
else
  fail "a fetched missing body.md is baselined" "ready=$(_ready "PRO-524")"
fi

# ── 4. read failures ───────────────────────────────────────────────────────

echo "--- read failures: 1-2 warn, 3 blocks, a success resets ---"

F_INIT="INIT-1700000200-0004"
F_EPIC="PRO-530"
_setup "$F_INIT" "$F_EPIC"
_child "$F_INIT" "$F_EPIC" "PRO-531"
touch "${REPOS_ROOT}/linear/PRO-531.fail"
planner_refinement_scan "$F_INIT" >/dev/null
planner_refinement_scan "$F_INIT" >/dev/null
if ! _has_missing "PRO-531" "BODY_UNVERIFIED" && [ "$(cat "$(_pdir "$F_INIT" "PRO-531")/linear-read-fails")" = "2" ] &&
  [ "$(grep -c '|META|refinement|warn|PRO-531: Linear read failed' "$(planner_state_log "$F_INIT")")" = "2" ]; then
  pass "two failed reads: no code, counter 2, one warn line each"
else
  fail "two failed reads: no code, counter 2" "ready=$(_ready "PRO-531") fails=$(cat "$(_pdir "$F_INIT" "PRO-531")/linear-read-fails" 2>/dev/null)"
fi
planner_refinement_scan "$F_INIT" >/dev/null
if _has_missing "PRO-531" "BODY_UNVERIFIED" && [ "$(_status "PRO-531")" = "not-ready" ] &&
  ! _result_has "$F_INIT" "PRO-531" "BODY_UNVERIFIED"; then
  pass "third failed read: BODY_UNVERIFIED (not in dor-result.json)"
else
  fail "third failed read: BODY_UNVERIFIED" "ready=$(_ready "PRO-531")"
fi
if ! bash "${TAP_LIB}/dor-check.sh" --waive PRO-531 BODY_UNVERIFIED "x" >/dev/null 2>&1; then
  pass "dor-check.sh --waive refuses BODY_UNVERIFIED"
else
  fail "dor-check.sh --waive refuses BODY_UNVERIFIED" "waived"
fi
report=$(planner_refinement_report "$F_INIT")
if echo "$report" | grep -qF "PRO-531 body unverified" && echo "$report" | grep -qF -- "--refresh-bodies"; then
  pass "report: BODY_UNVERIFIED names the refresh"
else
  fail "report: BODY_UNVERIFIED names the refresh" "$report"
fi
rm -f "${REPOS_ROOT}/linear/PRO-531.fail"
planner_refinement_scan "$F_INIT" >/dev/null
if ! _has_missing "PRO-531" "BODY_UNVERIFIED" && [ ! -f "$(_pdir "$F_INIT" "PRO-531")/linear-read-fails" ]; then
  pass "a successful read clears BODY_UNVERIFIED and resets the counter"
else
  fail "a successful read clears BODY_UNVERIFIED and resets the counter" "ready=$(_ready "PRO-531")"
fi
touch "${REPOS_ROOT}/linear/PRO-531.fail"
planner_refinement_scan "$F_INIT" >/dev/null
if ! _has_missing "PRO-531" "BODY_UNVERIFIED" && [ "$(cat "$(_pdir "$F_INIT" "PRO-531")/linear-read-fails")" = "1" ]; then
  pass "after a reset, one failure is back to 1 and no code"
else
  fail "after a reset, one failure is back to 1" "ready=$(_ready "PRO-531")"
fi
rm -f "${REPOS_ROOT}/linear/PRO-531.fail"
PLANNER_REFINEMENT_DRIFT_MAX_FAILS=1
touch "${REPOS_ROOT}/linear/PRO-531.fail"
rm -f "$(_pdir "$F_INIT" "PRO-531")/linear-read-fails"
planner_refinement_scan "$F_INIT" >/dev/null
if _has_missing "PRO-531" "BODY_UNVERIFIED"; then
  pass "PLANNER_REFINEMENT_DRIFT_MAX_FAILS=1 blocks on the first failure"
else
  fail "PLANNER_REFINEMENT_DRIFT_MAX_FAILS=1 blocks on the first failure" "ready=$(_ready "PRO-531")"
fi
unset PLANNER_REFINEMENT_DRIFT_MAX_FAILS
rm -f "${REPOS_ROOT}/linear/PRO-531.fail"

# ── 5. refresh ─────────────────────────────────────────────────────────────

echo "--- refresh takes Linear for every drifted child, keeps waivers ---"

W_INIT="INIT-1700000200-0005"
W_EPIC="PRO-540"
_setup "$W_INIT" "$W_EPIC"
_child "$W_INIT" "$W_EPIC" "PRO-541"
_child "$W_INIT" "$W_EPIC" "PRO-542"
# PRO-541 lacks its intent sections; the operator waived INTENT_MISSING.
for _f in "$(_pdir "$W_INIT" "PRO-541")/body.md" "${REPOS_ROOT}/linear/PRO-541.md"; do
  awk '/^## /{skip=($0=="## Background / Motivation" || $0=="## Proposed Behaviour")} !skip' \
    "${FIXTURES_DIR}/22-sourced-contract.md" >"$_f"
done
body_baseline_write "$(_pdir "$W_INIT" "PRO-541")" "$(cat "${REPOS_ROOT}/linear/PRO-541.md")"
planner_refinement_scan "$W_INIT" >/dev/null
waive_ticket_readiness_code "PRO-541" "INTENT_MISSING" "alice" "intent lives in the epic" >/dev/null
for _t in PRO-541 PRO-542; do
  _scan_clean "$W_INIT" "$_t"
  planner_refinement_apply "$W_INIT" "$_t" >/dev/null 2>&1
done
if [ "$(_status "PRO-541")" = "ready" ] && [ "$(_status "PRO-542")" = "ready" ]; then
  pass "setup: a waived-ready child and a clean ready child"
else
  fail "setup: a waived-ready child and a clean ready child" "541=$(_ready "PRO-541") 542=$(_ready "PRO-542")"
fi
# Both sides of PRO-541 change differently.
_edit_linear "PRO-541" "$E_FROM" "Validate uploads (Linear wins)."
_edit_body "$W_INIT" "PRO-541" "$E_FROM" "Validate uploads (local loses)."
sum_542=$(cat "$(_pdir "$W_INIT" "PRO-542")/body.md" "$(_pdir "$W_INIT" "PRO-542")/linear-baseline.sha" | sha256sum)
mtime_542=$(stat -c %Y "$(_pdir "$W_INIT" "PRO-542")/body.md")
refreshed=$(planner_refinement_refresh_bodies "$W_INIT")
if [ "$refreshed" = "PRO-541" ] &&
  grep -qF "Validate uploads (Linear wins)." "$(_pdir "$W_INIT" "PRO-541")/body.md" &&
  [ "$(_baseline "$W_INIT" "PRO-541")" = "$(_linear_hash "PRO-541")" ]; then
  pass "refresh: a waived ready child in conflict takes Linear and is printed"
else
  fail "refresh: a waived ready child in conflict takes Linear and is printed" "refreshed=$refreshed"
fi
if [ "$(cat "$(_pdir "$W_INIT" "PRO-542")/body.md" "$(_pdir "$W_INIT" "PRO-542")/linear-baseline.sha" | sha256sum)" = "$sum_542" ] &&
  [ "$(stat -c %Y "$(_pdir "$W_INIT" "PRO-542")/body.md")" = "$mtime_542" ]; then
  pass "refresh: a clean child stays byte-identical"
else
  fail "refresh: a clean child stays byte-identical" "changed"
fi
needs=$(planner_refinement_scan "$W_INIT")
if [ "$needs" = "PRO-541" ] && [ "$(_ready "PRO-541" | jq -r '.waived.INTENT_MISSING.by // "none"')" = "alice" ] &&
  ! _has_missing "PRO-541" "BODY_DRIFT"; then
  pass "refresh: the refreshed child is re-evaluated and keeps its waiver"
else
  fail "refresh: the refreshed child is re-evaluated and keeps its waiver" "needs=$needs ready=$(_ready "PRO-541")"
fi

# A child carrying BODY_UNVERIFIED is printed even when its text is clean,
# so a Completed re-run rescans it.
touch "${REPOS_ROOT}/linear/PRO-542.fail"
PLANNER_REFINEMENT_DRIFT_MAX_FAILS=1 planner_refinement_scan "$W_INIT" >/dev/null
rm -f "${REPOS_ROOT}/linear/PRO-542.fail"
refreshed=$(planner_refinement_refresh_bodies "$W_INIT")
if _has_missing "PRO-542" "BODY_UNVERIFIED" && [ "$refreshed" = "PRO-542" ]; then
  pass "refresh: a child held on BODY_UNVERIFIED is listed for a rescan"
else
  fail "refresh: a child held on BODY_UNVERIFIED is listed for a rescan" "refreshed=$refreshed"
fi

# ── 6. refresh on a Completed initiative ───────────────────────────────────

echo "--- refresh on a Completed initiative ---"

K_INIT="INIT-1700000200-0006"
K_EPIC="PRO-550"
_setup "$K_INIT" "$K_EPIC"
_child "$K_INIT" "$K_EPIC" "PRO-551"
_child "$K_INIT" "$K_EPIC" "PRO-552"
planner_refinement_scan "$K_INIT" >/dev/null
for _t in PRO-551 PRO-552; do
  _scan_clean "$K_INIT" "$_t"
  planner_refinement_apply "$K_INIT" "$_t" >/dev/null 2>&1
done
planner_refinement_gate "$K_INIT" >/dev/null 2>&1
planner_state_write "$K_INIT" "Completed" "summary" "done" "fixture"
log_k=$(planner_state_log "$K_INIT")
# ticket-auto held PRO-551: someone edited Linear and body.md.
_edit_linear "PRO-551" "$E_FROM" "Validate uploads after completion."
_edit_body "$K_INIT" "PRO-551" "$E_FROM" "Validate uploads locally after completion."
planner_config_set "$K_INIT" "refresh-bodies" "true"
phase_lines_before=$(grep -vc '|META|' "$log_k")
if planner_refinement_after_completed_pending "$K_INIT"; then
  pass "Completed + refresh-bodies is pending"
else
  fail "Completed + refresh-bodies is pending" "not pending"
fi
# SKILL.md step 1b after Completed: refresh, scan --only the refreshed, finish.
_refreshed=$(planner_refinement_refresh_bodies "$K_INIT" | paste -sd, -)
planner_config_set "$K_INIT" "refresh-bodies" "none"
needs=$(planner_refinement_scan "$K_INIT" --only "$_refreshed")
_scan_clean "$K_INIT" "PRO-551"
planner_refinement_apply "$K_INIT" "PRO-551" >/dev/null 2>&1
planner_refinement_after_completed_finish "$K_INIT" >/dev/null 2>&1
if [ "$_refreshed" = "PRO-551" ] && [ "$needs" = "PRO-551" ] &&
  grep -qF "Validate uploads after completion." "$(_pdir "$K_INIT" "PRO-551")/body.md" &&
  [ "$(_status "PRO-551")" = "ready" ] && [ "$(_round "PRO-551")" = "2" ]; then
  pass "after Completed: the drifted child is refreshed and re-evaluated"
else
  fail "after Completed: the drifted child is refreshed and re-evaluated" "refreshed=$_refreshed needs=$needs ready=$(_ready "PRO-551")"
fi
if [ -z "$(planner_position_derive "$K_INIT")" ] && [ "$(grep -vc '|META|' "$log_k")" = "$phase_lines_before" ]; then
  pass "after Completed: position still empty, only META lines written"
else
  fail "after Completed: position still empty, only META lines written" "position=$(planner_position_derive "$K_INIT")"
fi

# ── 7. the off switch ──────────────────────────────────────────────────────

echo "--- PLANNER_REFINEMENT_DRIFT_CHECK=false ---"

O_INIT="INIT-1700000200-0007"
O_EPIC="PRO-560"
_setup "$O_INIT" "$O_EPIC"
_child "$O_INIT" "$O_EPIC" "PRO-561"
_edit_linear "PRO-561" "$E_FROM" "Validate uploads (Linear)."
_edit_body "$O_INIT" "PRO-561" "$E_FROM" "Validate uploads (local)."
: >"${REPOS_ROOT}/linear/calls"
PLANNER_REFINEMENT_DRIFT_CHECK=false planner_refinement_scan "$O_INIT" >/dev/null
if ! _has_missing "PRO-561" "BODY_DRIFT" && [ ! -s "${REPOS_ROOT}/linear/calls" ] &&
  grep -qF "Validate uploads (local)." "$(_pdir "$O_INIT" "PRO-561")/body.md"; then
  pass "off switch: no Linear read, no drift code, body.md untouched"
else
  fail "off switch: no Linear read, no drift code" "calls=$(cat "${REPOS_ROOT}/linear/calls") ready=$(_ready "PRO-561")"
fi
planner_refinement_scan "$O_INIT" >/dev/null
if _has_missing "PRO-561" "BODY_DRIFT"; then
  pass "switch back on: the same child is BODY_DRIFT"
else
  fail "switch back on: the same child is BODY_DRIFT" "ready=$(_ready "PRO-561")"
fi
PLANNER_REFINEMENT_DRIFT_CHECK=false planner_refinement_scan "$O_INIT" >/dev/null
if ! _has_missing "PRO-561" "BODY_DRIFT"; then
  pass "off switch: a recorded BODY_DRIFT is not carried"
else
  fail "off switch: a recorded BODY_DRIFT is not carried" "ready=$(_ready "PRO-561")"
fi

# ── 8. TicketGen baseline ──────────────────────────────────────────────────

echo "--- TicketGen records the baseline ---"

T_INIT="INIT-1700000200-0008"
_setup "$T_INIT" "PRO-570"
_tg_child() {
  local pdir
  pdir=$(_pdir "$T_INIT" "$1")
  mkdir -p "$pdir"
  cp "${FIXTURES_DIR}/22-sourced-contract.md" "${pdir}/body.md"
}
_tg_child "PRO-571"
cp "${FIXTURES_DIR}/22-sourced-contract.md" "${REPOS_ROOT}/linear/PRO-571.md"
planner_ticketgen_record_baseline "$T_INIT" "PRO-571" create
if [ "$(_baseline "$T_INIT" "PRO-571")" = "$(_linear_hash "PRO-571")" ]; then
  pass "create: the baseline is the read-back's hash"
else
  fail "create: the baseline is the read-back's hash" "baseline=$(_baseline "$T_INIT" "PRO-571")"
fi

# Linear stored its own rendering: body.md takes it, so Refinement evaluates
# what Linear holds and no local-ahead is reported.
_tg_child "PRO-572"
cp "${FIXTURES_DIR}/22-sourced-contract.md" "${REPOS_ROOT}/linear/PRO-572.md"
_edit_linear "PRO-572" "- [ ] Uploading a valid" "* [ ] Uploading a valid"
planner_ticketgen_record_baseline "$T_INIT" "PRO-572" create 2>/dev/null
if [ "$(_baseline "$T_INIT" "PRO-572")" = "$(_linear_hash "PRO-572")" ] &&
  grep -qF "* [ ] Uploading a valid" "$(_pdir "$T_INIT" "PRO-572")/body.md" &&
  grep -qF "|META|ticketgen|warn|PRO-572" "$(planner_state_log "$T_INIT")"; then
  pass "create: a different Linear rendering is taken into body.md with a warn line"
else
  fail "create: a different Linear rendering is taken into body.md" "baseline=$(_baseline "$T_INIT" "PRO-572")"
fi

_tg_child "PRO-573"
rc=0
planner_ticketgen_record_baseline "$T_INIT" "PRO-573" create 2>/dev/null || rc=$?
if [ "$rc" = 0 ] && [ "$(_baseline "$T_INIT" "PRO-573")" = "none" ] &&
  cmp -s "${FIXTURES_DIR}/22-sourced-contract.md" "$(_pdir "$T_INIT" "PRO-573")/body.md"; then
  pass "create: a failed read-back writes no baseline and never fails"
else
  fail "create: a failed read-back writes no baseline and never fails" "rc=$rc"
fi

_tg_child "PRO-574"
cp "${FIXTURES_DIR}/22-sourced-contract.md" "${REPOS_ROOT}/linear/PRO-574.md"
planner_ticketgen_record_baseline "$T_INIT" "PRO-574" skip
if [ "$(_baseline "$T_INIT" "PRO-574")" = "$(_linear_hash "PRO-574")" ]; then
  pass "skip: no baseline and equal text → baseline written"
else
  fail "skip: no baseline and equal text → baseline written" "baseline=$(_baseline "$T_INIT" "PRO-574")"
fi

_tg_child "PRO-575"
cp "${FIXTURES_DIR}/22-sourced-contract.md" "${REPOS_ROOT}/linear/PRO-575.md"
_edit_linear "PRO-575" "$E_FROM" "Validate uploads (edited in Linear)."
planner_ticketgen_record_baseline "$T_INIT" "PRO-575" skip
if [ "$(_baseline "$T_INIT" "PRO-575")" = "none" ] &&
  cmp -s "${FIXTURES_DIR}/22-sourced-contract.md" "$(_pdir "$T_INIT" "PRO-575")/body.md"; then
  pass "skip: mismatching text leaves no baseline and body.md untouched"
else
  fail "skip: mismatching text leaves no baseline" "baseline=$(_baseline "$T_INIT" "PRO-575")"
fi

_tg_child "PRO-576"
cp "${FIXTURES_DIR}/22-sourced-contract.md" "${REPOS_ROOT}/linear/PRO-576.md"
echo "0000000000000000000000000000000000000000000000000000000000000000" >"$(_pdir "$T_INIT" "PRO-576")/linear-baseline.sha"
planner_ticketgen_record_baseline "$T_INIT" "PRO-576" skip
if [ "$(_baseline "$T_INIT" "PRO-576")" = "0000000000000000000000000000000000000000000000000000000000000000" ]; then
  pass "skip: an existing baseline is never overwritten"
else
  fail "skip: an existing baseline is never overwritten" "baseline=$(_baseline "$T_INIT" "PRO-576")"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
