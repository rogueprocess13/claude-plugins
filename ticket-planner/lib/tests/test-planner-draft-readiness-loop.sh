#!/usr/bin/env bash
# test-planner-draft-readiness-loop.sh — planner-draft-readiness slice S3b
# (design D8, D11, D12, D14): the bounded auto-revise loop of the draft
# readiness gate, driven exactly as SKILL.md steps 1d + 1e drive it.
#
# Agents are stubbed. An evaluation spawn writes a canned DOR_SEMANTIC_SCAN /
# AUDIT block; a revise spawn edits the spec and writes revise.r<N>.md
# according to REVISE_<slug> (fix | nofix | extend | rebut | frozen |
# missing | missing-once).
#
# Covers (tasks.md 6.7):
#   1. converges in one round; a cached re-run spawns nothing
#   2. budget of 2 rounds honoured across a simulated resume; round 3 is
#      demoted round-limit with reason class `revised`
#   3. a fixable spec is revised before a structural halt in another spec
#   4. rebuttal: no re-evaluation, no second revision, demoted `rebutted`
#   5. guard revert: spec restored, demoted `reverted`; DEMOTE_CEILING halts
#   6. Crosscheck re-run after an applied round; regression reverts the spec
#   7. agent retry: one retry, then failed:AGENT_FAILED (demoted `failed`);
#      a retry that succeeds
#   8. new gap on a revised unit: `round-limit`/`revised`; same code on the
#      same unit: `drift`
#   9. spawn budget halts before spawning
#  10. MAX_ROUNDS=0 is halt-only; an invalid value is refused
#  11. crash between spawn and status file resumes the same round (also
#      through a fresh begin)
#  12. no Linear call, no ticket manifest, no snapshot left behind
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-readiness-loop.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="${TMP_ROOT}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${TMP_ROOT}/repos"
export TMPDIR="${TMP_ROOT}/tmp"
mkdir -p "$TMPDIR"
export PLANNER_DRAFT_SNAPSHOT_ROOT="${TMP_ROOT}/snaps"
unset PLANNER_DRAFT_REVISE_MAX_ROUNDS PLANNER_DRAFT_SPAWN_BUDGET PLANNER_DRAFT_DEMOTE_CEILING

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-draft-readiness-gate.sh"
source "${LIB_DIR}/planner-stop-describe.sh"
_planner_refinement_source_deps || exit 1

# Crosscheck is stubbed. CROSSCHECK_RCS is a queue of return codes (one per
# call, 0 once empty); every call is counted.
CROSSCHECK_CALLS="${TMP_ROOT}/crosscheck-calls"
CROSSCHECK_QUEUE="${TMP_ROOT}/crosscheck-queue"
: >"$CROSSCHECK_CALLS"
: >"$CROSSCHECK_QUEUE"
planner_crosscheck_run() {
  local rc=0
  echo x >>"$CROSSCHECK_CALLS"
  if [ -s "$CROSSCHECK_QUEUE" ]; then
    rc=$(head -1 "$CROSSCHECK_QUEUE")
    sed -i 1d "$CROSSCHECK_QUEUE"
  fi
  planner_state_write "$1" "Crosscheck" "check" "start" ""
  if [ "$rc" -eq 0 ]; then
    planner_state_write "$1" "Crosscheck" "check" "done" "clean"
    return 0
  fi
  planner_state_write "$1" "META" "crosscheck" "fail" "CITATION_UNRESOLVED specs/b-api.md cites nowhere.ts:1"
  planner_state_write "$1" "Crosscheck" "check" "fail" "1 blocking"
  return 1
}
planner_crosscheck_findings_report() { echo "CROSSCHECK REPORT"; }
LINEAR_CALLS="${TMP_ROOT}/linear-calls"
planner_linear_graphql() {
  echo x >>"$LINEAR_CALLS"
  return 1
}

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

echo "=== planner draft readiness revise loop (S3b) ==="

FIXTEXT="Export shows a progress message while the download starts"
SOURCE_QUOTE="Finance staff rebuild the invoice list by hand for every audit."

# _setup <INIT> — a fresh initiative with two specs, Crosscheck passed.
_setup() {
  INIT="$1"
  IDIR="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
  SPECS="${IDIR}/artifacts/specs"
  LOG="${IDIR}/state.log"
  DR="${IDIR}/artifacts/draft-readiness"
  mkdir -p "$SPECS"
  _spec "a-schema" "Persist invoice exports" "planned, feature" \
    "- [ ] The Export button appears on the invoice list"
  _spec "b-api" "Finance can export invoices" "planned, feature, blocked-by:a" \
    "- [ ] Export responds with 200
- [ ] Export downloads a file named invoices.csv"
  {
    echo "2026-10-01T00:00:00Z|META|schema|done|1"
    for p in Appraisal Discovery Architecture Specify Review Consensus; do
      echo "2026-10-01T00:00:00Z|${p}|run|start|"
      echo "2026-10-01T00:00:00Z|${p}|run|done|"
    done
    echo "2026-10-01T00:00:01Z|Crosscheck|check|start|"
    echo "2026-10-01T00:00:01Z|Crosscheck|check|done|clean"
  } >"$LOG"
  : >"$CROSSCHECK_CALLS"
  : >"$CROSSCHECK_QUEUE"
  unset FINDINGS_a_schema FINDINGS_b_api STRUCT_a_schema AFTER_b_api REVISE_a_schema REVISE_b_api
}

_spec() {
  local slug="$1" title="$2" labels="$3" acs="$4" ac crit rows=""
  while IFS= read -r ac; do
    crit="${ac#- \[ \] }"
    rows+="| ${crit} | finance user | none | Invoices > Export | done | yes |"$'\n'
  done <<<"$acs"
  cat >"${SPECS}/${slug}.md" <<SPEC
# ${slug}

## Title

${title}

## Description

## Summary

${title}, in plain language.

## Why

${SOURCE_QUOTE}

## Scope

| Layer | Service | Change |
|---|---|---|
| BE | web | export route |

## Outcome

**Serves:** O1

**Outcome:** Invoices can be exported.

## Proposed Behaviour

An Export action on the invoice list.

## Technical Context

- Route \`GET /api/invoices/export\`.

## Acceptance Criteria

${acs}

## Out of Scope

Scheduled exports.

## Related Tickets

None

## Labels

${labels}

## Signals

\`\`\`json
{"services_identified": 2, "symbols_resolved": 3, "prior_art_found": true, "complexity": "simple", "exploration_depth": "standard", "Strategy": "Balanced", "Decision": "Add an export route", "AffectedServices": "web", "TargetSymbols": "exportInvoices:web/src/invoices.ts:10", "Kind": "business", "Serves": ["O1"], "Enables": []}
\`\`\`

## Verification Notes

| Criterion | Role | Test data | Navigation path | Expected | Verifiable |
|---|---|---|---|---|---|
${rows}
SPEC
}

# ── stub agents ───────────────────────────────────────────────────────────
# Scan: FINDINGS_<slug> (code|quote) is raised until the body holds FIXTEXT
# or the "for a finance user" extension; then AFTER_<slug> (code|quote), if
# set. STRUCT_<slug> (code|quote) is always raised as well.
_hash_of() { planner_draft_readiness_body_hash "${DR}/$1/body.md"; }
_scan_block() {
  local slug="$1" tid="DRAFT-$1" h body var i=0 f g
  h=$(_hash_of "$slug")
  body=$(cat "${DR}/${slug}/body.md")
  local -a list=()
  var="FINDINGS_${slug//-/_}"
  if [[ "$body" == *"$FIXTEXT"* || "$body" == *"for a finance user"* ]]; then
    var="AFTER_${slug//-/_}"
  fi
  [ -n "${!var:-}" ] && list+=("${!var}")
  var="STRUCT_${slug//-/_}"
  [ -n "${!var:-}" ] && list+=("${!var}")
  echo "=== DOR_SEMANTIC_SCAN ==="
  echo "SCHEMA_VERSION: 1"
  echo "TICKET: ${tid}"
  echo "BODY_HASH: ${h}"
  for f in "${list[@]}"; do
    i=$((i + 1))
    echo "FINDING_${i}_CODE: ${f%%|*}"
    echo "FINDING_${i}_QUOTE: ${f#*|}"
    echo "FINDING_${i}_DETAIL: fixture gap"
  done
  for g in REQUIREMENT_COMPLETENESS CONTRADICTORY_REQUIREMENTS DEEP_SCOPE_AMBIGUITY EDGE_CASE_SUFFICIENCY; do
    echo "GAP_${g}: clear"
    echo "GAP_${g}_REASON: fixture"
  done
  echo "=== END DOR_SEMANTIC_SCAN ==="
}
_audit_block() {
  echo "=== DOR_SEMANTIC_AUDIT ==="
  echo "SCHEMA_VERSION: 1"
  echo "TICKET: DRAFT-$1"
  echo "BODY_HASH: $(_hash_of "$1")"
  echo "SCORE_PLAUSIBLE: yes"
  echo "SCORE_REASON: fixture"
  echo "=== END DOR_SEMANTIC_AUDIT ==="
}

# _add_criterion <spec> <text>: one AC item and its Verification Notes row.
_add_criterion() {
  local spec="$1" text="$2"
  python3 - "$spec" "$text" <<'PY'
import sys
p, t = sys.argv[1], sys.argv[2]
lines = open(p).read().split("\n")
out, sec, last_ac = [], None, None
for i, l in enumerate(lines):
    if l.startswith("## "):
        sec = l[3:].strip()
    if sec == "Acceptance Criteria" and l.startswith("- [ ]"):
        last_ac = i
lines.insert(last_ac + 1, "- [ ] " + t)
# Verification Notes: append after the last table row.
sec, last_row = None, None
for i, l in enumerate(lines):
    if l.startswith("## "):
        sec = l[3:].strip()
    if sec == "Verification Notes" and l.startswith("|"):
        last_row = i
lines.insert(last_row + 1, "| %s | finance user | none | Invoices > Export | done | yes |" % t)
open(p, "w").write("\n".join(lines))
PY
}

REVISE_SPAWNS="${TMP_ROOT}/revise-spawns"
_revise_agent() {
  local slug="$1" rf="$2" dir n ff spec mode var ids id
  dir=$(dirname "$rf")
  n="${rf##*/revise.r}"
  n="${n%.md}"
  ff="${dir}/findings.r${n}.json"
  spec="${SPECS}/${slug}.md"
  echo "$slug" >>"$REVISE_SPAWNS"
  var="REVISE_${slug//-/_}"
  mode="${!var:-fix}"
  ids=$(jq -r '.[] | .id // .code' "$ff")
  case "$mode" in
  missing) return 0 ;;
  missing-once)
    if [ ! -f "${TMP_ROOT}/stub-once-${slug}" ]; then
      : >"${TMP_ROOT}/stub-once-${slug}"
      return 0
    fi
    mode=fix
    ;;
  esac
  case "$mode" in
  fix) _add_criterion "$spec" "$FIXTEXT" ;;
  nofix) _add_criterion "$spec" "The export file name includes the date in round ${n}" ;;
  extend) sed -i 's/Export responds with 200/Export responds with 200 for a finance user/g' "$spec" ;;
  frozen) sed -i 's/^Scheduled exports\.$/Scheduled exports and reminders./' "$spec" ;;
  esac
  : >"$rf"
  for id in $ids; do
    if [ "$mode" = "rebut" ]; then
      echo "REBUTTED ${id} — already covered by the Export button criterion" >>"$rf"
    else
      echo "RESOLVED ${id} — added a criterion — source: \"${SOURCE_QUOTE}\"" >>"$rf"
    fi
  done
}

_spawn_list() {
  local list="$1" slug kind type pf rf
  while IFS=$'\t' read -r slug kind type pf rf; do
    [ -n "$slug" ] || continue
    [ -s "$pf" ] || echo "empty prompt $pf" >&2
    case "$kind" in
    scan)
      [ "$type" = "ticket-auto-pipeline:dor-semantic-agent" ] || echo "bad agent type $type" >&2
      _scan_block "$slug" >"$rf"
      ;;
    audit) _audit_block "$slug" >"$rf" ;;
    revise)
      [ "$type" = "ticket-planner:draft-revise-agent" ] || echo "bad agent type $type" >&2
      _revise_agent "$slug" "$rf"
      ;;
    esac
  done <<<"$list"
}

# SKILL.md step 1d + 1e: begin → (next → spawn → apply)* → gate.
# GATE_RC, SPAWNS, REVISES; MAXITER caps iterations (a simulated crash).
_gate() {
  local list rc=0 i iters="${MAXITER:-30}"
  SPAWNS=0
  REVISES=0
  : >"$REVISE_SPAWNS"
  planner_draft_readiness_begin "$INIT" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    for ((i = 1; i <= iters; i++)); do
      list=$(planner_draft_readiness_next "$INIT" 2>/dev/null) || {
        rc=1
        break
      }
      [ "$list" = "done 0" ] && break
      [ -n "$list" ] || {
        rc=1
        break
      }
      SPAWNS=$((SPAWNS + $(printf '%s\n' "$list" | grep -c .)))
      REVISES=$((REVISES + $(printf '%s\n' "$list" | grep -c $'\trevise\t')))
      _spawn_list "$list"
      planner_draft_readiness_apply "$INIT" >/dev/null 2>&1 || rc=1
    done
    if [ "$rc" -eq 0 ] && [ "$i" -le "$iters" ]; then
      GATE_OUT=$(planner_draft_readiness_gate "$INIT" 2>/dev/null) || rc=$?
    fi
  fi
  GATE_RC=$rc
}

_status() { cat "${DR}/$1/revise.r$2.status" 2>/dev/null; }
_run_lines() { _planner_draft_run_lines "$INIT"; }

# ── 1. converges ─────────────────────────────────────────────────────────
echo "--- 1. converges in one round ---"
_setup INIT-L1
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$SPAWNS" -eq 7 ] && [ "$REVISES" -eq 1 ] &&
  [ "$(_status b-api 1)" = "applied" ] && grep -qF "$FIXTEXT" "${SPECS}/b-api.md" &&
  [ -s "${DR}/b-api/revise.r1.diff" ] && [ -s "${DR}/b-api/spec.r0.md" ] && [ -s "${DR}/b-api/findings.r1.json" ] &&
  [ ! -e "${DR}/round" ] && [ ! -e "${DR}/a-schema/revise.r1.status" ]; then
  pass "4 evaluation spawns, 1 revise, 2 re-evaluation spawns (b-api only); applied; passes"
else
  fail "converge" "rc=$GATE_RC spawns=$SPAWNS revises=$REVISES status=$(_status b-api 1) $(tail -5 "$LOG")"
fi
if [ "$(wc -l <"$CROSSCHECK_CALLS")" -eq 1 ] && [ -s "${DR}/b-api/lineage.json" ] &&
  [ "$(jq -r .round "${DR}/b-api/lineage.json")" = 2 ] && [ -s "${DR}/b-api/lineage.prev.json" ] &&
  _run_lines | grep -q '|META|draft-revise|start|b-api round=1 findings=1$' &&
  _run_lines | grep -q '|META|draft-revise|done|b-api round=1 status=applied resolved=1 rebutted=0 unaddressed=0 added=1 extended=0$' &&
  _run_lines | grep -q '|META|draft-readiness|info|round=1 revise=1 reevaluate=0 spawns=5/16$'; then
  pass "Crosscheck re-ran once; draft lineage round 2 on disk; start/done/info lines"
else
  fail "converge details" "xc=$(wc -l <"$CROSSCHECK_CALLS") $(_run_lines | grep -E 'draft-revise|info')"
fi
if printf '%s\n' "$GATE_OUT" | grep -q '^Revision history:' && printf '%s\n' "$GATE_OUT" | grep -q 'b-api: 1 revision(s): applied'; then
  pass "pass summary lists the revision history"
else
  fail "pass summary" "$GATE_OUT"
fi
_gate
[ "$GATE_RC" -eq 0 ] && [ "$SPAWNS" -eq 0 ] && pass "cached re-run: no spawn, still passes" ||
  fail "cache" "rc=$GATE_RC spawns=$SPAWNS"

# ── 2. max rounds across a resume ────────────────────────────────────────
echo "--- 2. budget of 2 honoured across a resume ---"
_setup INIT-L2
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=nofix
# Crash after the first revise round settles (iterations: scan, audit,
# revise, then stop before re-evaluating).
MAXITER=3 _gate
r1=$(planner_draft_revise_rounds_used "$INIT" b-api)
_gate
if [ "$r1" -eq 1 ] && [ "$GATE_RC" -eq 0 ] && [ "$(planner_draft_revise_rounds_used "$INIT" b-api)" -eq 2 ] &&
  [ ! -e "${DR}/b-api/revise.r3.status" ] && [ "$(jq -r .round "${DR}/b-api/lineage.json")" = 3 ]; then
  pass "two revisions in total across the resume; round 3 evaluation, no third revision"
else
  fail "max rounds" "r1=$r1 rc=$GATE_RC used=$(planner_draft_revise_rounds_used "$INIT" b-api) $(tail -4 "$LOG")"
fi
if jq -e '[.findings[] | select(.code == "EDGE_CASE_GAP" and .severity == "advisory" and .demoted == "round-limit" and .demote_reason == "revised")] | length == 1' \
  "${DR}/b-api/semantic.json" >/dev/null &&
  _run_lines | grep -q '|META|draft-readiness|info|b-api DEMOTED EDGE_CASE_GAP round-limit revised '; then
  pass "the remaining finding is demoted round-limit, reason class revised, and logged"
else
  fail "demotion revised" "$(jq -c '.findings' "${DR}/b-api/semantic.json")"
fi

# ── 3. structural halt after revising the fixable spec ───────────────────
echo "--- 3. fixable spec revised before a structural halt ---"
_setup INIT-L3
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export STRUCT_a_schema="INTENT_AC_MISMATCH|The Export button appears on the invoice list"
_gate
if [ "$GATE_RC" -eq 3 ] && [ "$(_status b-api 1)" = "applied" ] && [ ! -e "${DR}/a-schema/findings.r1.json" ] &&
  _run_lines | grep -q '|META|draft-readiness|fail|a-schema INTENT_AC_MISMATCH ' &&
  ! _run_lines | grep -q '|META|draft-readiness|fail|b-api ' &&
  _run_lines | grep -q '|META|draft-readiness|done|blocked 1/2$'; then
  pass "b-api revised and ready; a-schema never revised; halt on its structural finding"
else
  fail "structural" "rc=$GATE_RC b=$(_status b-api 1) $(_run_lines | grep -E 'fail|done')"
fi
desc=$(planner_stop_describe_json "$INIT")
[ "$(echo "$desc" | jq -r .reason)" = "DRAFT_NOT_READY" ] && pass "describer: DRAFT_NOT_READY" || fail "describer" "$desc"

# ── 4. rebuttal ──────────────────────────────────────────────────────────
echo "--- 4. rebuttal ---"
_setup INIT-L4
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=rebut
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$SPAWNS" -eq 5 ] && [ "$(_status b-api 1)" = "unchanged" ] &&
  [ ! -e "${DR}/b-api/revise.r2.status" ] &&
  _run_lines | grep -q '|META|draft-revise|info|b-api REBUTTAL EDGE_CASE_GAP ' &&
  jq -e '[.findings[] | select(.demote_reason == "rebutted" and .demoted == "round-limit")] | length == 1' "${DR}/b-api/semantic.json" >/dev/null; then
  pass "unchanged: no re-evaluation, no second revision, demoted with reason rebutted"
else
  fail "rebuttal" "rc=$GATE_RC spawns=$SPAWNS st=$(_status b-api 1) $(jq -c .findings "${DR}/b-api/semantic.json")"
fi

# ── 5. guard revert and the demotion ceiling ─────────────────────────────
echo "--- 5. guard revert, demotion ceiling ---"
_setup INIT-L5
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=frozen
cp "${SPECS}/b-api.md" "${TMP_ROOT}/b-api.orig"
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$(_status b-api 1)" = "reverted:FROZEN_CHANGED" ] &&
  [ "$(_status b-api 2)" = "reverted:FROZEN_CHANGED" ] && cmp -s "${SPECS}/b-api.md" "${TMP_ROOT}/b-api.orig" &&
  [ "$(wc -l <"$CROSSCHECK_CALLS")" -eq 0 ] &&
  _run_lines | grep -q '|META|draft-revise|fail|b-api round=1 FROZEN_CHANGED ' &&
  jq -e '[.findings[] | select(.demote_reason == "reverted")] | length == 1' "${DR}/b-api/semantic.json" >/dev/null; then
  pass "both rounds reverted, spec byte-identical, no Crosscheck, demoted reverted (1/2 = ceiling, passes)"
else
  fail "revert" "rc=$GATE_RC $(_status b-api 1) $(_status b-api 2) xc=$(wc -l <"$CROSSCHECK_CALLS")"
fi
PLANNER_DRAFT_DEMOTE_CEILING=0.4 _gate
if [ "$GATE_RC" -eq 3 ] && [ "$SPAWNS" -eq 0 ] &&
  _run_lines | grep -q '|META|draft-readiness|fail|(run) DEMOTE_CEILING "1/2 specs' &&
  _run_lines | grep -q '|META|draft-readiness|done|blocked 0/2 DEMOTE_CEILING$'; then
  pass "a ceiling of 0.4 halts with DEMOTE_CEILING"
else
  fail "ceiling" "rc=$GATE_RC $(_run_lines | grep -E 'fail|done')"
fi
desc=$(planner_stop_describe_json "$INIT")
if echo "$desc" | jq -e '[.questions[].id] | index("draft-run") != null' >/dev/null; then
  pass "describer names the run-level halt"
else
  fail "describer run" "$desc"
fi

# ── 6. Crosscheck regression ─────────────────────────────────────────────
echo "--- 6. Crosscheck regression reverts the round ---"
_setup INIT-L6
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
printf '1\n0\n' >"$CROSSCHECK_QUEUE"
cp "${SPECS}/b-api.md" "${TMP_ROOT}/b-api.orig"
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$(_status b-api 1)" = "reverted:CROSSCHECK_REGRESSION" ] && cmp -s "${SPECS}/b-api.md" "${TMP_ROOT}/b-api.orig" &&
  [ "$(wc -l <"$CROSSCHECK_CALLS")" -eq 2 ] &&
  _run_lines | grep -q '|META|draft-revise|fail|b-api round=1 CROSSCHECK_REGRESSION "CITATION_UNRESOLVED"' &&
  [ "$GATE_RC" -eq 0 ] &&
  jq -e '[.findings[] | select(.demote_reason == "reverted")] | length == 1' "${DR}/b-api/semantic.json" >/dev/null; then
  pass "regression: spec restored, status reverted:CROSSCHECK_REGRESSION, Crosscheck passes again"
else
  fail "regression" "rc=$GATE_RC st=$(_status b-api 1) xc=$(wc -l <"$CROSSCHECK_CALLS") $(_run_lines | grep draft-revise)"
fi
# Crosscheck still blocking after the revert halts the run.
_setup INIT-L6b
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
printf '1\n1\n' >"$CROSSCHECK_QUEUE"
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$GATE_RC" -eq 3 ] && _run_lines | grep -q '|META|draft-readiness|fail|(run) CROSSCHECK_BLOCKED "CITATION_UNRESOLVED"'; then
  pass "Crosscheck still blocking after the revert halts with CROSSCHECK_BLOCKED"
else
  fail "regression halt" "rc=$GATE_RC $(_run_lines | grep -E 'fail|done')"
fi

# ── 7. agent retry ───────────────────────────────────────────────────────
echo "--- 7. revise agent retry ---"
_setup INIT-L7
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=missing
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$REVISES" -eq 2 ] && [ "$(_status b-api 1)" = "failed:AGENT_FAILED" ] && [ "$GATE_RC" -eq 0 ] &&
  jq -e '[.findings[] | select(.demote_reason == "failed")] | length == 1' "${DR}/b-api/semantic.json" >/dev/null; then
  pass "two spawns, then failed:AGENT_FAILED; demoted with reason failed"
else
  fail "retry fail" "revises=$REVISES st=$(_status b-api 1) rc=$GATE_RC"
fi
_setup INIT-L7b
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=missing-once
rm -f "${TMP_ROOT}/stub-once-b-api"
_gate
if [ "$REVISES" -eq 2 ] && [ "$(_status b-api 1)" = "applied" ] && [ ! -e "${DR}/b-api/revise.r2.status" ] && [ "$GATE_RC" -eq 0 ]; then
  pass "a retry that writes its result settles the same round"
else
  fail "retry ok" "revises=$REVISES st=$(_status b-api 1) $(_status b-api 2) rc=$GATE_RC"
fi

# ── 8. drift on revised units ────────────────────────────────────────────
echo "--- 8. new finding on a revised unit ---"
_setup INIT-L8
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=extend
export AFTER_b_api="SCOPE_AMBIGUOUS|Export responds with 200 for a finance user"
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$GATE_RC" -eq 0 ] && [ "$(_status b-api 1)" = "applied" ] &&
  jq -e '[.findings[] | select(.code == "SCOPE_AMBIGUOUS" and .demoted == "round-limit" and .demote_reason == "revised")] | length == 1' \
    "${DR}/b-api/semantic.json" >/dev/null; then
  pass "a different code on the revised unit: round-limit / revised, not drift"
else
  fail "new gap" "rc=$GATE_RC $(jq -c .findings "${DR}/b-api/semantic.json")"
fi
_setup INIT-L8b
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=extend
export AFTER_b_api="EDGE_CASE_GAP|Export responds with 200 for a finance user"
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$GATE_RC" -eq 0 ] &&
  jq -e '[.findings[] | select(.code == "EDGE_CASE_GAP" and .demoted == "drift" and .demote_reason == "revised")] | length == 1' \
    "${DR}/b-api/semantic.json" >/dev/null &&
  _run_lines | grep -q '|META|draft-readiness|info|b-api DEMOTED EDGE_CASE_GAP drift revised '; then
  pass "the addressed code re-phrased on the same unit: drift / revised"
else
  fail "drift" "rc=$GATE_RC $(jq -c .findings "${DR}/b-api/semantic.json")"
fi

# ── 9. spawn budget ──────────────────────────────────────────────────────
echo "--- 9. spawn budget ---"
_setup INIT-L9
export FINDINGS_a_schema="EDGE_CASE_GAP|The Export button appears on the invoice list"
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
PLANNER_DRAFT_SPAWN_BUDGET=5 _gate
if [ "$GATE_RC" -eq 3 ] && [ "$SPAWNS" -eq 4 ] && [ "$REVISES" -eq 0 ] &&
  [ ! -e "${DR}/b-api/findings.r1.json" ] && [ ! -e "${DR}/round" ] &&
  _run_lines | grep -q '|META|draft-readiness|fail|(run) SPAWN_BUDGET ' &&
  _run_lines | grep -q '|META|draft-readiness|done|blocked 2/2 SPAWN_BUDGET$'; then
  pass "the revise list (2) would exceed 5: halt before spawning, no round files"
else
  fail "budget" "rc=$GATE_RC spawns=$SPAWNS revises=$REVISES $(_run_lines | grep -E 'fail|done|warn')"
fi
report=$(planner_draft_readiness_report "$INIT")
printf '%s\n' "$report" | grep -q 'SPAWN_BUDGET' && pass "report shows SPAWN_BUDGET" || fail "budget report" "$report"
if ! (PLANNER_DRAFT_SPAWN_BUDGET=abc planner_draft_readiness_begin "$INIT" >/dev/null 2>&1); then
  pass "an invalid spawn budget is refused at gate start"
else
  fail "budget validate" "accepted"
fi

# ── 10. MAX_ROUNDS=0 and validation ──────────────────────────────────────
echo "--- 10. MAX_ROUNDS=0 is halt-only ---"
_setup INIT-L10
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
PLANNER_DRAFT_REVISE_MAX_ROUNDS=0 _gate
if [ "$GATE_RC" -eq 3 ] && [ "$REVISES" -eq 0 ] && [ "$SPAWNS" -eq 4 ] &&
  [ ! -e "${DR}/b-api/findings.r1.json" ] && ! grep -q '|META|draft-readiness|info|' "$LOG" &&
  _run_lines | grep -q '|META|draft-readiness|fail|b-api EDGE_CASE_GAP "Export responds with 200"'; then
  pass "no revision, no info line, halt on the fixable finding"
else
  fail "max0" "rc=$GATE_RC revises=$REVISES $(_run_lines | tail -3)"
fi
rc=0
PLANNER_DRAFT_REVISE_MAX_ROUNDS=x planner_draft_readiness_begin "$INIT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && pass "a non-integer MAX_ROUNDS is refused (rc 1)" || fail "max validate" "rc=$rc"

# ── 11. crash between spawn and status ───────────────────────────────────
echo "--- 11. crash between spawn and status file ---"
_setup INIT-L11
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1
for k in 1 2; do
  _spawn_list "$(planner_draft_readiness_next "$INIT" 2>/dev/null)"
  planner_draft_readiness_apply "$INIT" >/dev/null 2>&1
done
l=$(planner_draft_readiness_next "$INIT" 2>/dev/null)
_spawn_list "$l"
# Crash: no apply. A new invocation re-enters through begin.
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1
l2=$(planner_draft_readiness_next "$INIT" 2>/dev/null)
if printf '%s\n' "$l" | grep -q $'^b-api\trevise\t' && [ "$(_status b-api 1)" = "applied" ] &&
  [ ! -e "${DR}/b-api/revise.r2.status" ] && printf '%s\n' "$l2" | grep -q $'^b-api\tscan\t' &&
  ! grep -q 'OUT_OF_SCOPE_EDIT' "$LOG" && grep -q '|META|draft-readiness|start|evaluator=.* resume-round$' "$LOG"; then
  pass "the same round settles after the crash (no OUT_OF_SCOPE_EDIT); next re-evaluates b-api"
else
  fail "crash" "st1=$(_status b-api 1) l2=$l2 $(grep -E 'draft-revise' "$LOG")"
fi
_spawn_list "$l2"
planner_draft_readiness_apply "$INIT" >/dev/null 2>&1
_spawn_list "$(planner_draft_readiness_next "$INIT" 2>/dev/null)"
planner_draft_readiness_apply "$INIT" >/dev/null 2>&1
l3=$(planner_draft_readiness_next "$INIT" 2>/dev/null)
rc=0
planner_draft_readiness_gate "$INIT" >/dev/null 2>&1 || rc=$?
[ "$l3" = "done 0" ] && [ "$rc" -eq 0 ] && pass "the resumed loop converges" || fail "crash converge" "l3=$l3 rc=$rc"

# ── 12. side effects ─────────────────────────────────────────────────────
echo "--- 12. no Linear, no manifest, no snapshot left ---"
if [ ! -s "$LINEAR_CALLS" ] && [ -z "$(find "$REPOS_ROOT" -name manifest.json)" ] &&
  [ ! -e "${REPOS_ROOT}/.ticket-auto/initiatives/_index" ] &&
  [ -z "$(find "$PLANNER_DRAFT_SNAPSHOT_ROOT" -mindepth 2 -maxdepth 2 2>/dev/null)" ] &&
  [ -z "$(ls -A "$TMPDIR")" ]; then
  pass "no Linear call, no ticket manifest, every snapshot dropped, no temp leftovers"
else
  fail "side effects" "$(find "$REPOS_ROOT" -name manifest.json) $(find "$PLANNER_DRAFT_SNAPSHOT_ROOT" -mindepth 2 -maxdepth 2 2>/dev/null) $(ls -A "$TMPDIR")"
fi

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
