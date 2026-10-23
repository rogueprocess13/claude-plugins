#!/usr/bin/env bash
# test-planner-refinement-convergence.sh — Refinement rounds, the trend line,
# converge, the scoped rescan, the v2 migration call, the audit kill switch
# and Refinement after Completed (planner-refinement-convergence, group 6:
# planner-refinement.sh planner_refinement_apply / _unavailable / _scan /
# _prompt / _converge / _report / _advisory_summary).
#
# Every semantic result is a canned DOR_SEMANTIC_SCAN/AUDIT block rendered
# against the child's current body hash — no agent is spawned.
#
# Run: bash ticket-planner/lib/tests/test-planner-refinement-convergence.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
FIXTURES_DIR="${LIB_DIR}/../../ticket-auto-pipeline/lib/tests/fixtures/dor"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Empty HOME: every cross-plugin dependency resolves to the sibling
# ticket-auto-pipeline/lib under test, as in CI.
export HOME="${TMPDIR}/home"
mkdir -p "$HOME"

unset DOR_SEMANTIC_MAX_ROUNDS DOR_SEMANTIC_DRIFT_DEMOTE DOR_SEMANTIC_ROUND_RESET_SHARE \
  DOR_SEMANTIC_STRUCTURAL_CODES DOR_SEMANTIC_ADVISORY_CODES DOR_SEMANTIC_INERT_SECTIONS \
  DOR_AUDIT_DEMOTABLE_CODES DOR_AUDIT_DEMOTE_MAX \
  PLANNER_REFINEMENT_MAX_ROUNDS PLANNER_REFINEMENT_AUDIT_DEMOTE

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-refinement.sh"
_planner_refinement_source_deps

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

echo "=== planner-refinement-convergence tests ==="

# ── helpers ────────────────────────────────────────────────────────────────

_pdir() { echo "${REPOS_ROOT}/.ticket-auto/initiatives/${1}/tickets/${2}/planner"; }

# _setup <INIT> <EPIC>
_setup() {
  planner_state_init "$1" "refinement convergence idea" >/dev/null
  planner_state_write "$1" "EpicGen" "create" "done" "EPIC_ID=${2}"
  planner_state_write "$1" "TicketGen" "verify" "done" "ok"
  write_epic_manifest "$2" "" "per-ticket" "" '[]' >/dev/null
}

# _child <INIT> <EPIC> <TID> [<fixture>]
_child() {
  local pdir
  write_ticket_manifest "$3" "$1" "feature" '[]' >/dev/null
  add_epic_manifest_child "$2" "$3" >/dev/null
  pdir=$(_pdir "$1" "$3")
  mkdir -p "$pdir"
  cp "${FIXTURES_DIR}/${4:-22-sourced-contract}.md" "${pdir}/body.md"
}

_hash() { _dor_body_hash "$(cat "$(_pdir "$1" "$2")/body.md")"; }
_hash8() { _hash "$1" "$2" | sed 's/^sha256://' | cut -c1-8; }

# _edit <INIT> <TID> <from> <to> — replace one literal string in body.md.
_edit() {
  local f
  f="$(_pdir "$1" "$2")/body.md"
  FROM="$3" TO="$4" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$f"
}

# _scan <INIT> <TID> [<CODE>|<quote>|<detail> ...] — canned scan result.
# A gap is marked "finding" when a finding falls in its dimension.
_scan() {
  local init="$1" tid="$2"
  shift 2
  local hash out n=0 spec code quote detail dims=""
  hash=$(_hash "$init" "$tid")
  out="=== DOR_SEMANTIC_SCAN ===
SCHEMA_VERSION: 1
TICKET: ${tid}
BODY_HASH: ${hash}"
  for spec in "$@"; do
    n=$((n + 1))
    code="${spec%%|*}"
    quote="${spec#*|}"
    detail="${quote#*|}"
    quote="${quote%%|*}"
    dims="$dims ${DOR_SEMANTIC_CODES[$code]}"
    out="${out}
FINDING_${n}_CODE: ${code}
FINDING_${n}_QUOTE: ${quote}
FINDING_${n}_DETAIL: ${detail}"
  done
  local gap dim verdict
  for gap in REQUIREMENT_COMPLETENESS:requirement_completeness CONTRADICTORY_REQUIREMENTS:acceptance_criteria \
    DEEP_SCOPE_AMBIGUITY:scope EDGE_CASE_SUFFICIENCY:edge_cases; do
    dim="${gap#*:}"
    verdict="clear"
    case " $dims " in *" $dim "*) verdict="finding" ;; esac
    out="${out}
GAP_${gap%%:*}: ${verdict}
GAP_${gap%%:*}_REASON: canned"
  done
  printf '%s\n=== END DOR_SEMANTIC_SCAN ===\n' "$out" >"$(_pdir "$init" "$tid")/semantic-scan-result.txt"
}

# _audit <INIT> <TID> [<extra lines>] — canned audit result.
_audit() {
  local hash
  hash=$(_hash "$1" "$2")
  {
    printf '=== DOR_SEMANTIC_AUDIT ===\nSCHEMA_VERSION: 1\nTICKET: %s\nBODY_HASH: %s\n' "$2" "$hash"
    [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf 'SCORE_PLAUSIBLE: yes\nSCORE_REASON: matches\n=== END DOR_SEMANTIC_AUDIT ===\n'
  } >"$(_pdir "$1" "$2")/semantic-audit-result.txt"
}

_ready() { get_ticket_manifest_field "$1" ready 2>/dev/null; }
_status() { _ready "$1" | jq -r '.status // "none"'; }
_round() { _ready "$1" | jq -r '.lineage.round // "none"'; }
_blocking() { _ready "$1" | jq '[(.semantic.findings // [])[] | select(.severity == "blocking")] | length'; }
_dem() { _ready "$1" | jq -r --arg c "$2" '[(.semantic.findings // [])[] | select(.code == $c)][0].demoted // "none"'; }
_has_missing() { _ready "$1" | jq -e --arg c "$2" '(.missing // []) | index($c) != null' >/dev/null 2>&1; }
_trend() { grep -F '|META|refinement-round|done|' "$(planner_state_log "$1")" 2>/dev/null | grep -F "|${2} " || true; }
_trend_count() { _trend "$1" "$2" | grep -c . || true; }

# Quotes, each verbatim from dor fixture 22 and each in its own unit.
Q_AC1='Uploading a valid 1,000-row file imports all 1,000 rows'
Q_PROP='rejects the file with a per-row error list when any row is invalid'
Q_BG='the errors only surface at month-end reconciliation'
Q_SCOPE_AMB='The upload page validates every row before import'

# ── 1. Rounds over four canned verdicts ────────────────────────────────────

echo "--- rounds: blocking count drops, round 3 passes, structural halts at 4 ---"

R_INIT="INIT-1700000100-0001"
R_EPIC="PRO-200"
_setup "$R_INIT" "$R_EPIC"
_child "$R_INIT" "$R_EPIC" "PRO-201"

# Round 1: three blocking findings.
planner_refinement_scan "$R_INIT" >/dev/null
_scan "$R_INIT" "PRO-201" "MISSING_CORE_AC|${Q_AC1}|no criterion for a partial import" \
  "EDGE_CASE_GAP|${Q_PROP}|an empty file is not covered" \
  "UNSTATED_DEPENDENCY|${Q_BG}|the reconciliation job is not named"
_audit "$R_INIT" "PRO-201"
planner_refinement_apply "$R_INIT" "PRO-201" >/dev/null 2>&1
b1=$(_blocking "PRO-201")
r1_hash8=$(_hash8 "$R_INIT" "PRO-201")
if [ "$(_round "PRO-201")" = "1" ] && [ "$b1" = "3" ] && [ "$(_status "PRO-201")" = "not-ready" ]; then
  pass "round 1: three blocking findings, not ready"
else
  fail "round 1: three blocking findings, not ready" "round=$(_round "PRO-201") blocking=$b1"
fi
if _trend "$R_INIT" "PRO-201" | grep -qF "PRO-201 round=1 new=3 carried=0 drift=0 resolved=0 unverified=0 reset=0 [${r1_hash8}]"; then
  pass "round 1: trend line written"
else
  fail "round 1: trend line written" "got: $(_trend "$R_INIT" "PRO-201")"
fi

# Same body, same results: no second trend line (retry / resume).
planner_refinement_apply "$R_INIT" "PRO-201" >/dev/null 2>&1
if [ "$(_trend_count "$R_INIT" "PRO-201")" = "1" ]; then
  pass "trend line is deduped per ticket and hash8"
else
  fail "trend line is deduped per ticket and hash8" "count=$(_trend_count "$R_INIT" "PRO-201")"
fi

# Round 2: Summary edited, MISSING_CORE_AC fixed, two carried.
_edit "$R_INIT" "PRO-201" "Validate bulk client uploads before import." "Validate bulk client uploads before any import."
planner_refinement_scan "$R_INIT" >/dev/null
scan_prompt2=$(planner_refinement_prompt "$R_INIT" "PRO-201" scan)
if echo "$scan_prompt2" | grep -qF "**Changed sections**" && echo "$scan_prompt2" | grep -qF "Summary"; then
  pass "scan prompt after an edit names the changed sections (--changed-sections)"
else
  fail "scan prompt after an edit names the changed sections (--changed-sections)" "no Changed sections block"
fi
_scan "$R_INIT" "PRO-201" "EDGE_CASE_GAP|${Q_PROP}|an empty file is not covered" \
  "UNSTATED_DEPENDENCY|${Q_BG}|the reconciliation job is not named"
_audit "$R_INIT" "PRO-201"
planner_refinement_apply "$R_INIT" "PRO-201" >/dev/null 2>&1
b2=$(_blocking "PRO-201")
if [ "$(_round "PRO-201")" = "2" ] && [ "$b2" -lt "$b1" ]; then
  pass "round 2: the blocking count drops ($b1 → $b2)"
else
  fail "round 2: the blocking count drops" "round=$(_round "PRO-201") blocking=$b2"
fi
if _trend "$R_INIT" "PRO-201" | grep -qF "PRO-201 round=2 new=0 carried=2 drift=0 resolved=1 unverified=0 reset=0"; then
  pass "round 2: trend line counts carried and resolved"
else
  fail "round 2: trend line counts carried and resolved" "got: $(_trend "$R_INIT" "PRO-201")"
fi

report2=$(planner_refinement_report "$R_INIT")
if echo "$report2" | grep -q "^Round: 2" && echo "$report2" | grep -qF "Blocking (carried since round 1) EDGE_CASE_GAP"; then
  pass "report: shows the round and carried blocking findings"
else
  fail "report: shows the round and carried blocking findings" "got: $report2"
fi

# Round 3: only the non-structural EDGE_CASE_GAP is left → demoted, ready.
_edit "$R_INIT" "PRO-201" "before any import." "before any import starts."
planner_refinement_scan "$R_INIT" >/dev/null
_scan "$R_INIT" "PRO-201" "EDGE_CASE_GAP|${Q_PROP}|an empty file is not covered"
_audit "$R_INIT" "PRO-201"
planner_refinement_apply "$R_INIT" "PRO-201" >/dev/null 2>&1
if [ "$(_round "PRO-201")" = "3" ] && [ "$(_dem "PRO-201" EDGE_CASE_GAP)" = "round-limit" ] &&
  [ "$(_status "PRO-201")" = "ready" ]; then
  pass "round 3: a non-structural leftover is demoted (round-limit) and the ticket is ready"
else
  fail "round 3: a non-structural leftover is demoted (round-limit) and the ticket is ready" \
    "round=$(_round "PRO-201") demoted=$(_dem "PRO-201" EDGE_CASE_GAP) status=$(_status "PRO-201")"
fi
if planner_refinement_gate "$R_INIT" >/dev/null 2>&1; then
  pass "round 3: the gate passes"
else
  fail "round 3: the gate passes" "gate returned nonzero"
fi
summary3=$(planner_refinement_advisory_summary "$R_INIT")
if echo "$summary3" | grep -qF "Advisory (does not block) PRO-201 EDGE_CASE_GAP (demoted: round-limit)"; then
  pass "advisory summary names the demoted finding with round-limit"
else
  fail "advisory summary names the demoted finding with round-limit" "got: $summary3"
fi

# Round 4: the dependency gap comes back on unchanged text — structural, so
# it still blocks (and is labelled drift).
_edit "$R_INIT" "PRO-201" "before any import starts." "before any import starts at all."
planner_refinement_scan "$R_INIT" >/dev/null
_scan "$R_INIT" "PRO-201" "EDGE_CASE_GAP|${Q_PROP}|an empty file is not covered" \
  "UNSTATED_DEPENDENCY|${Q_BG}|the reconciliation job is not named"
_audit "$R_INIT" "PRO-201"
planner_refinement_apply "$R_INIT" "PRO-201" >/dev/null 2>&1
if [ "$(_round "PRO-201")" = "4" ] && _has_missing "PRO-201" "SEMANTIC_DEPENDENCIES" &&
  [ "$(_status "PRO-201")" = "not-ready" ]; then
  pass "round 4: UNSTATED_DEPENDENCY still halts after the limit"
else
  fail "round 4: UNSTATED_DEPENDENCY still halts after the limit" "round=$(_round "PRO-201") ready=$(_ready "PRO-201")"
fi
report4=$(planner_refinement_report "$R_INIT")
if echo "$report4" | grep -qF "Structural drift (blocks) UNSTATED_DEPENDENCY" &&
  echo "$report4" | grep -q "^Demoted (does not block):" &&
  echo "$report4" | grep -qF "  - EDGE_CASE_GAP (round-limit)"; then
  pass "report: structural drift and the Demoted (does not block) list"
else
  fail "report: structural drift and the Demoted (does not block) list" "got: $report4"
fi

# 6.2: an unavailable result keeps the lineage.
planner_refinement_unavailable "$R_INIT" "PRO-201" >/dev/null 2>&1
if _has_missing "PRO-201" "SEMANTIC_UNAVAILABLE" && [ "$(_round "PRO-201")" = "4" ]; then
  pass "planner_refinement_unavailable: SEMANTIC_UNAVAILABLE recorded and ready.lineage survives"
else
  fail "planner_refinement_unavailable: SEMANTIC_UNAVAILABLE recorded and ready.lineage survives" "ready=$(_ready "PRO-201")"
fi

# ── 2. Reset after a rewrite, unverified count ─────────────────────────────

echo "--- reset after a rewrite ---"

_child "$R_INIT" "$R_EPIC" "PRO-202"
planner_refinement_scan "$R_INIT" >/dev/null
_scan "$R_INIT" "PRO-202" "EDGE_CASE_GAP|${Q_PROP}|an empty file is not covered" \
  "SCOPE_AMBIGUOUS|this sentence is not in the body|unclear"
_audit "$R_INIT" "PRO-202"
planner_refinement_apply "$R_INIT" "PRO-202" >/dev/null 2>&1
if _trend "$R_INIT" "PRO-202" | grep -qF "PRO-202 round=1 new=1 carried=0 drift=0 resolved=0 unverified=1 reset=0"; then
  pass "trend line counts an unverified finding"
else
  fail "trend line counts an unverified finding" "got: $(_trend "$R_INIT" "PRO-202")"
fi
_edit "$R_INIT" "PRO-202" "Validate bulk client uploads before import." "Validate bulk uploads."
planner_refinement_scan "$R_INIT" >/dev/null
_scan "$R_INIT" "PRO-202" "EDGE_CASE_GAP|${Q_PROP}|an empty file is not covered"
_audit "$R_INIT" "PRO-202"
planner_refinement_apply "$R_INIT" "PRO-202" >/dev/null 2>&1
# Rewrite five of the nine non-inert sections.
_edit "$R_INIT" "PRO-202" "Validate bulk uploads." "Reject malformed client uploads early."
_edit "$R_INIT" "PRO-202" "Operators upload client files that silently import malformed rows" "Support staff upload client spreadsheets that quietly import broken rows"
_edit "$R_INIT" "PRO-202" "The upload page validates every row before import" "The upload screen checks each row before anything is stored"
_edit "$R_INIT" "PRO-202" '`ops-lead@example.com`' '`ops-admin@example.com`'
_edit "$R_INIT" "PRO-202" "- A 1,000-row valid upload file. Source" "- A valid upload file of 1,000 rows. Source"
planner_refinement_scan "$R_INIT" >/dev/null
_scan "$R_INIT" "PRO-202" "EDGE_CASE_GAP|rejects the file with a per-row error list|an empty file is not covered"
_audit "$R_INIT" "PRO-202"
planner_refinement_apply "$R_INIT" "PRO-202" >/dev/null 2>&1
if [ "$(_round "PRO-202")" = "1" ] && _trend "$R_INIT" "PRO-202" | tail -1 | grep -qF "round=1 " &&
  _trend "$R_INIT" "PRO-202" | tail -1 | grep -qF "reset=1"; then
  pass "a wholesale rewrite resets the round (reset=1)"
else
  fail "a wholesale rewrite resets the round (reset=1)" "round=$(_round "PRO-202") trend: $(_trend "$R_INIT" "PRO-202")"
fi

# ── 3. Policy override warn line ───────────────────────────────────────────

echo "--- policy override ---"

log_r=$(planner_state_log "$R_INIT")
if ! grep -qF '|META|refinement|warn|policy override' "$log_r"; then
  pass "default policy: no policy override line"
else
  fail "default policy: no policy override line" "found one"
fi
_child "$R_INIT" "$R_EPIC" "PRO-203"
planner_refinement_scan "$R_INIT" >/dev/null
_scan "$R_INIT" "PRO-203"
_audit "$R_INIT" "PRO-203"
DOR_SEMANTIC_STRUCTURAL_CODES="NEEDS_HUMAN_DECISION" planner_refinement_apply "$R_INIT" "PRO-203" >/dev/null 2>&1
if grep -F '|META|refinement|warn|policy override' "$log_r" | grep -qF "PRO-203"; then
  pass "an overridden structural list writes a policy override warn line"
else
  fail "an overridden structural list writes a policy override warn line" "line missing"
fi

# ── 4. v2 verdicts are migrated by the scan, not rescanned ─────────────────

echo "--- v2 migration ---"

_child "$R_INIT" "$R_EPIC" "PRO-204"
planner_refinement_scan "$R_INIT" >/dev/null
_scan "$R_INIT" "PRO-204"
_audit "$R_INIT" "PRO-204"
DOR_SEMANTIC_EVALUATOR="dor-semantic-v2" planner_refinement_apply "$R_INIT" "PRO-204" >/dev/null 2>&1
needs_mig=$(planner_refinement_scan "$R_INIT")
if ! echo "$needs_mig" | grep -qx "PRO-204" &&
  _ready "PRO-204" | jq -e '.semantic.evaluator == "dor-semantic-v3" and .semantic.migrated_from == "dor-semantic-v2"' >/dev/null; then
  pass "planner_refinement_scan migrates an unchanged v2 verdict instead of listing it"
else
  fail "planner_refinement_scan migrates an unchanged v2 verdict instead of listing it" "needs=$needs_mig sem=$(_ready "PRO-204" | jq -c '.semantic | {evaluator, migrated_from}')"
fi

# ── 5. Audit demotion kill switch ──────────────────────────────────────────

echo "--- audit demotion kill switch ---"

A_INIT="INIT-1700000100-0002"
A_EPIC="PRO-250"
_setup "$A_INIT" "$A_EPIC"
_child "$A_INIT" "$A_EPIC" "PRO-251" "29-vplan-row-gap-dispute"
_child "$A_INIT" "$A_EPIC" "PRO-252" "29-vplan-row-gap-dispute"
planner_refinement_scan "$A_INIT" >/dev/null
AUDIT_29=$(sed -n '/^AUDIT_1_/p' "${FIXTURES_DIR}/semantic/29-audit.txt")
for _t in PRO-251 PRO-252; do
  _scan "$A_INIT" "$_t"
  _audit "$A_INIT" "$_t" "$AUDIT_29"
done
planner_refinement_apply "$A_INIT" "PRO-251" >/dev/null 2>&1
log_a=$(planner_state_log "$A_INIT")
if ! grep -qF '|META|refinement-dispute|' "$log_a" && ! _ready "PRO-251" | jq -e '.demoted' >/dev/null 2>&1 &&
  _has_missing "PRO-251" "VPLAN_ROW_GAP"; then
  pass "audit demotion is off by default (no dispute line, code still blocks)"
else
  fail "audit demotion is off by default (no dispute line, code still blocks)" "ready=$(_ready "PRO-251")"
fi
PLANNER_REFINEMENT_AUDIT_DEMOTE=true planner_refinement_apply "$A_INIT" "PRO-252" >/dev/null 2>&1
if grep -F '|META|refinement-dispute|' "$log_a" | grep -qF "PRO-252 VPLAN_ROW_GAP" &&
  _ready "PRO-252" | jq -e '.demoted.VPLAN_ROW_GAP' >/dev/null 2>&1 && [ "$(_status "PRO-252")" = "ready" ]; then
  pass "PLANNER_REFINEMENT_AUDIT_DEMOTE=true demotes and logs refinement-dispute"
else
  fail "PLANNER_REFINEMENT_AUDIT_DEMOTE=true demotes and logs refinement-dispute" "ready=$(_ready "PRO-252") log=$(grep refinement-dispute "$log_a")"
fi
summary_a=$(planner_refinement_advisory_summary "$A_INIT")
if echo "$summary_a" | grep -qF "Advisory (does not block) PRO-252 VPLAN_ROW_GAP (demoted: audit dispute)"; then
  pass "advisory summary names an audit demotion"
else
  fail "advisory summary names an audit demotion" "got: $summary_a"
fi
report_a=$(planner_refinement_report "$A_INIT")
if echo "$report_a" | grep -q "^## PRO-251" && echo "$report_a" | grep -qF "dor-check.sh --waive PRO-251 VPLAN_ROW_GAP"; then
  pass "report: a non-demoted dispute still offers the waive"
else
  fail "report: a non-demoted dispute still offers the waive" "got: $report_a"
fi

# ── 6. Converge ────────────────────────────────────────────────────────────

echo "--- converge ---"

C_INIT="INIT-1700000100-0003"
C_EPIC="PRO-300"
_setup "$C_INIT" "$C_EPIC"
for _t in PRO-301 PRO-302 PRO-303 PRO-304; do _child "$C_INIT" "$C_EPIC" "$_t"; done
planner_refinement_scan "$C_INIT" >/dev/null
_scan "$C_INIT" "PRO-301" "SCOPE_AMBIGUOUS|${Q_SCOPE_AMB}|which rows count as invalid"
_scan "$C_INIT" "PRO-302" "NEEDS_HUMAN_DECISION|${Q_BG}|who owns reconciliation" \
  "EDGE_CASE_GAP|${Q_PROP}|an empty file is not covered"
_scan "$C_INIT" "PRO-303" "EDGE_CASE_GAP|${Q_PROP}|an empty file is not covered"
_scan "$C_INIT" "PRO-304" "EDGE_CASE_GAP|${Q_PROP}|an empty file is not covered"
for _t in PRO-301 PRO-302 PRO-303 PRO-304; do
  _audit "$C_INIT" "$_t"
  planner_refinement_apply "$C_INIT" "$_t" >/dev/null 2>&1
done
# PRO-303's body is edited after its verdict → stale.
_edit "$C_INIT" "PRO-303" "Validate bulk client uploads before import." "Validate client uploads."
planner_refinement_scan "$C_INIT" >/dev/null
sem303_before=$(_ready "PRO-303" | jq -c '.semantic')
p304_before=$(_ready "PRO-304" | jq -c '.semantic')

SPAWN_MARK="${TMPDIR}/spawned"
_saved_prompt=$(declare -f dor_semantic_prompt)
eval 'dor_semantic_prompt() { echo spawn >>"'"$SPAWN_MARK"'"; }'
conv_out=$(planner_refinement_converge "$C_INIT" "PRO-301,PRO-302,PRO-303" "alice" 2>&1)
conv_rc=$?
eval "$_saved_prompt"
log_c=$(planner_state_log "$C_INIT")

if [ "$conv_rc" = "0" ] && [ ! -e "$SPAWN_MARK" ]; then
  pass "converge returns 0 and builds no agent prompt"
else
  fail "converge returns 0 and builds no agent prompt" "rc=$conv_rc spawned=$([ -e "$SPAWN_MARK" ] && echo yes)"
fi
if [ "$(_dem "PRO-301" SCOPE_AMBIGUOUS)" = "converge" ] && [ "$(_status "PRO-301")" = "ready" ] &&
  _ready "PRO-301" | jq -e '.semantic.findings[0].converged_by == "alice"' >/dev/null &&
  grep -qF '|META|refinement-converge|done|PRO-301 demoted=1 by=alice' "$log_c"; then
  pass "converge releases a ticket held only by a non-structural finding"
else
  fail "converge releases a ticket held only by a non-structural finding" "ready=$(_ready "PRO-301")"
fi
if [ "$(_dem "PRO-302" EDGE_CASE_GAP)" = "converge" ] && [ "$(_dem "PRO-302" NEEDS_HUMAN_DECISION)" = "none" ] &&
  _has_missing "PRO-302" "SEMANTIC_REQUIREMENT_COMPLETENESS" && [ "$(_status "PRO-302")" = "not-ready" ] &&
  grep -qF '|META|refinement-converge|done|PRO-302 demoted=1 by=alice' "$log_c"; then
  pass "a structural code survives converge"
else
  fail "a structural code survives converge" "ready=$(_ready "PRO-302")"
fi
if [ "$(_ready "PRO-303" | jq -c '.semantic')" = "$sem303_before" ] && echo "$conv_out" | grep -q "PRO-303.*scan" &&
  ! grep -qF '|META|refinement-converge|done|PRO-303' "$log_c"; then
  pass "a stale ticket is refused, unchanged, and named as needing a scan"
else
  fail "a stale ticket is refused, unchanged, and named as needing a scan" "out=$conv_out"
fi
if [ "$(_ready "PRO-304" | jq -c '.semantic')" = "$p304_before" ]; then
  pass "converge touches only the named tickets"
else
  fail "converge touches only the named tickets" "PRO-304 changed"
fi
needs_after=$(planner_refinement_scan "$C_INIT")
if ! echo "$needs_after" | grep -qx "PRO-301" && [ "$(_status "PRO-301")" = "ready" ]; then
  pass "a later deterministic scan keeps the converged verdict"
else
  fail "a later deterministic scan keeps the converged verdict" "needs=$needs_after status=$(_status "PRO-301")"
fi
conv_report=$(planner_refinement_report "$C_INIT")
if echo "$conv_report" | grep -q "^## PRO-302" && echo "$conv_report" | grep -qF "  - EDGE_CASE_GAP (converge, by alice)"; then
  pass "report: a converged finding is listed under Demoted with its operator"
else
  fail "report: a converged finding is listed under Demoted with its operator" "got: $conv_report"
fi

# Argument validation (SKILL.md step 2a calls it).
if ! planner_refinement_converge_args_validate "true" "" "alice" >/dev/null 2>&1; then
  pass "--converge without --only is rejected"
else
  fail "--converge without --only is rejected" "accepted"
fi
if ! planner_refinement_converge_args_validate "" "PRO-1" "" >/dev/null 2>&1; then
  pass "--only without --converge is rejected"
else
  fail "--only without --converge is rejected" "accepted"
fi
if ! planner_refinement_converge_args_validate "true" "PRO-1,not a tid" "alice" >/dev/null 2>&1; then
  pass "--only with a malformed ticket id is rejected"
else
  fail "--only with a malformed ticket id is rejected" "accepted"
fi
if planner_refinement_converge_args_validate "true" "PRO-1,PRO-22" "alice" >/dev/null 2>&1 &&
  planner_refinement_converge_args_validate "" "" "" >/dev/null 2>&1; then
  pass "well-formed --converge --only, and no flags at all, are accepted"
else
  fail "well-formed --converge --only, and no flags at all, are accepted" "rejected"
fi

# One-shot config key, consumed and cleared.
if planner_config_set "$C_INIT" "converge" "PRO-304 bob" 2>/dev/null; then
  pass "converge is a known config key"
else
  fail "converge is a known config key" "planner_config_set refused it"
fi
planner_refinement_converge_consume "$C_INIT" >/dev/null 2>&1
if [ "$(_dem "PRO-304" EDGE_CASE_GAP)" = "converge" ] && [ -z "$(planner_config_get "$C_INIT" converge)" ] &&
  grep -qF '|META|refinement-converge|done|PRO-304 demoted=1 by=bob' "$log_c"; then
  pass "converge_consume runs the persisted converge and clears the key"
else
  fail "converge_consume runs the persisted converge and clears the key" "config=$(planner_config_get "$C_INIT" converge)"
fi
n_before=$(grep -c . "$log_c")
planner_refinement_converge_consume "$C_INIT" >/dev/null 2>&1
if [ "$(grep -c . "$log_c")" = "$n_before" ]; then
  pass "converge_consume with no key set writes nothing"
else
  fail "converge_consume with no key set writes nothing" "log grew"
fi

# ── 7. After Completed ─────────────────────────────────────────────────────

echo "--- after Completed ---"

D_INIT="INIT-1700000100-0004"
D_EPIC="PRO-400"
_setup "$D_INIT" "$D_EPIC"
_child "$D_INIT" "$D_EPIC" "PRO-401"
_child "$D_INIT" "$D_EPIC" "PRO-402"
planner_refinement_scan "$D_INIT" >/dev/null
_scan "$D_INIT" "PRO-401" "SCOPE_AMBIGUOUS|${Q_SCOPE_AMB}|which rows count as invalid"
_scan "$D_INIT" "PRO-402"
for _t in PRO-401 PRO-402; do
  _audit "$D_INIT" "$_t"
  planner_refinement_apply "$D_INIT" "$_t" >/dev/null 2>&1
done
# Operator waived it to finish the run; Completed done.
planner_state_write "$D_INIT" "Refinement" "gate" "done" "forced for the fixture"
planner_state_write "$D_INIT" "Completed" "summary" "done" "fixture"
log_d=$(planner_state_log "$D_INIT")

if [ -z "$(planner_position_derive "$D_INIT")" ] && ! planner_refinement_after_completed_pending "$D_INIT"; then
  pass "a Completed initiative with no refresh/converge has nothing pending"
else
  fail "a Completed initiative with no refresh/converge has nothing pending" "pending"
fi
planner_config_set "$D_INIT" "converge" "PRO-401 carol"
if planner_refinement_after_completed_pending "$D_INIT"; then
  pass "a Completed initiative with converge set is pending"
else
  fail "a Completed initiative with converge set is pending" "not pending"
fi
planner_config_set "$D_INIT" "converge" "none"
planner_config_set "$D_INIT" "refresh-bodies" "true"
if planner_refinement_after_completed_pending "$D_INIT"; then
  pass "a Completed initiative with refresh-bodies set is pending"
else
  fail "a Completed initiative with refresh-bodies set is pending" "not pending"
fi
planner_config_set "$D_INIT" "refresh-bodies" "none"
if ! planner_refinement_after_completed_pending "$R_INIT"; then
  pass "an initiative that is not Completed is never pending"
else
  fail "an initiative that is not Completed is never pending" "pending"
fi

planner_config_set "$D_INIT" "converge" "PRO-401 carol"
phase_lines_before=$(grep -vc '|META|' "$log_d")
planner_refinement_converge_consume "$D_INIT" >/dev/null 2>&1
planner_refinement_after_completed_finish "$D_INIT" >/dev/null 2>&1
if [ "$(_status "PRO-401")" = "ready" ] && [ "$(_dem "PRO-401" SCOPE_AMBIGUOUS)" = "converge" ]; then
  pass "converge works after Completed"
else
  fail "converge works after Completed" "ready=$(_ready "PRO-401")"
fi
if [ "$(grep -vc '|META|' "$log_d")" = "$phase_lines_before" ] && [ -z "$(planner_position_derive "$D_INIT")" ] &&
  grep -qF '|META|refinement-after-completed|done|' "$log_d"; then
  pass "after Completed: only META lines written, position still finished"
else
  fail "after Completed: only META lines written, position still finished" "position=$(planner_position_derive "$D_INIT")"
fi

# Scan restricted to named children (the affected set after Completed).
_edit "$D_INIT" "PRO-402" "Validate bulk client uploads before import." "Validate client uploads."
_edit "$D_INIT" "PRO-401" "Validate bulk client uploads before import." "Validate client uploads."
only_needs=$(planner_refinement_scan "$D_INIT" --only "PRO-402")
if [ "$only_needs" = "PRO-402" ] && ! _has_missing "PRO-401" "SEMANTIC_STALE"; then
  pass "planner_refinement_scan --only touches only the named children"
else
  fail "planner_refinement_scan --only touches only the named children" "needs=$only_needs"
fi

# ── 8. No prefix variable leaks ────────────────────────────────────────────

echo "--- no prefix leak ---"

leak=""
for _v in DOR_SEMANTIC_MAX_ROUNDS DOR_SEMANTIC_DRIFT_DEMOTE DOR_SEMANTIC_ROUND_RESET_SHARE \
  DOR_SEMANTIC_STRUCTURAL_CODES DOR_STRICT_TEST_DATA DOR_STRICT_VPLAN; do
  [ -n "${!_v+x}" ] && leak="$leak $_v"
done
if [ -z "$leak" ]; then
  pass "no prefix variable leaks into the caller"
else
  fail "no prefix variable leaks into the caller" "set:$leak"
fi
(
  DOR_SEMANTIC_MAX_ROUNDS=7
  planner_refinement_apply "$R_INIT" "PRO-201" >/dev/null 2>&1
  [ "$DOR_SEMANTIC_MAX_ROUNDS" = "7" ] && echo KEPT
) >"${TMPDIR}/leak.txt" 2>&1
if grep -q KEPT "${TMPDIR}/leak.txt"; then
  pass "a caller's own DOR_SEMANTIC_MAX_ROUNDS is restored after the apply"
else
  fail "a caller's own DOR_SEMANTIC_MAX_ROUNDS is restored after the apply" "$(cat "${TMPDIR}/leak.txt")"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
