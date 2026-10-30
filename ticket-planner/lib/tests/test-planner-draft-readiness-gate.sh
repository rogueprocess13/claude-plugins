#!/usr/bin/env bash
# test-planner-draft-readiness-gate.sh — planner-draft-readiness slice S2b
# (design D1, D4–D7, D16): the halt-only gate, --accept DRAFT_NOT_READY, the
# stop describer, and the spawn-list protocol SKILL.md step 1e drives.
#
# Agents are stubbed: a "spawn" writes a canned DOR_SEMANTIC_SCAN/AUDIT block
# to the result file the spawn list names.
#
# Covers:
#   1. A first run lists a scan per draft, then an audit, then `done 0`;
#      every draft gets a verdict and the gate passes. No ticket manifest, no
#      _index entry and no Linear call.
#   2. A second run on unchanged specs spawns nothing; both runs write their
#      own `draft-readiness|done` line.
#   3. Editing one spec re-evaluates only that spec.
#   4. A blocking finding halts (rc 3) with one fail line per finding; the
#      report and the describer read only the latest run (halt lines scoped
#      to the latest start); the describer reports DRAFT_NOT_READY.
#   5. --accept DRAFT_NOT_READY binds to the current draft hashes: the gate
#      passes with a warn line; no META|crosscheck|accepted from the accept
#      function or from planner-answers.sh; a spec edit re-arms the gate and
#      re-runs Crosscheck first.
#   6. A blocked run followed by a spec edit re-runs Crosscheck; a blocking
#      Crosscheck halts with Crosscheck's report.
#   7. Two failed agent attempts make the verdict `unavailable` (blocks);
#      the next run retries it.
#   8. A removed spec loses its directory; --until Crosscheck skips the gate.
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-readiness-gate.sh

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

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-draft-readiness-gate.sh"
source "${LIB_DIR}/planner-stop-describe.sh"
_planner_refinement_source_deps || exit 1

# Crosscheck is stubbed: the gate's re-run (D5) is what is under test, not
# the checks themselves. CROSSCHECK_RC decides the outcome; every call is
# counted.
CROSSCHECK_CALLS="${TMP_ROOT}/crosscheck-calls"
: >"$CROSSCHECK_CALLS"
CROSSCHECK_RC=0
planner_crosscheck_run() {
  echo x >>"$CROSSCHECK_CALLS"
  planner_state_write "$1" "Crosscheck" "check" "start" ""
  if [ "$CROSSCHECK_RC" -eq 0 ]; then
    planner_state_write "$1" "Crosscheck" "check" "done" "clean"
    return 0
  fi
  planner_state_write "$1" "META" "crosscheck" "fail" "CITATION_UNRESOLVED specs/a-schema.md cites nowhere.ts:1"
  planner_state_write "$1" "Crosscheck" "check" "fail" "1 blocking"
  return 1
}
planner_crosscheck_findings_report() { echo "CROSSCHECK REPORT"; }
# Any Linear call is a failure.
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

echo "=== planner draft readiness gate (S2b) ==="

INIT="INIT-DRG"
IDIR="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
SPECS="${IDIR}/artifacts/specs"
LOG="${IDIR}/state.log"
DR="${IDIR}/artifacts/draft-readiness"
mkdir -p "$SPECS"

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

Finance staff rebuild the invoice list by hand for every audit.

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
{"services_identified": 2, "symbols_resolved": 3, "prior_art_found": true, "Strategy": "Balanced", "Decision": "Add an export route", "AffectedServices": "web", "TargetSymbols": "exportInvoices:web/src/invoices.ts:10", "Kind": "business", "Serves": ["O1"], "Enables": []}
\`\`\`

## Verification Notes

| Criterion | Role | Test data | Navigation path | Expected | Verifiable |
|---|---|---|---|---|---|
${rows}
SPEC
}

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

# ── stub agents ───────────────────────────────────────────────────────────
# FINDINGS_<slug> (code|quote) makes that draft's scan raise one finding.
# BROKEN_<slug>=1 writes an unparseable result; MISSING_<slug>=1 writes none.
_hash_of() { planner_draft_readiness_body_hash "${DR}/$1/body.md"; }
_spawn_list() {
  local list="$1" slug kind type pf rf tid h var code quote
  while IFS=$'\t' read -r slug kind type pf rf; do
    [ -n "$slug" ] || continue
    [ "$type" = "ticket-auto-pipeline:dor-semantic-agent" ] || echo "bad agent type $type" >&2
    [ -s "$pf" ] || echo "empty prompt $pf" >&2
    var="MISSING_${slug//-/_}"
    [ "${!var:-}" = "1" ] && continue
    var="BROKEN_${slug//-/_}"
    if [ "${!var:-}" = "1" ]; then
      echo "garbage" >"$rf"
      continue
    fi
    tid="DRAFT-${slug}"
    h=$(_hash_of "$slug")
    if [ "$kind" = "scan" ]; then
      var="FINDINGS_${slug//-/_}"
      {
        echo "=== DOR_SEMANTIC_SCAN ==="
        echo "SCHEMA_VERSION: 1"
        echo "TICKET: ${tid}"
        echo "BODY_HASH: ${h}"
        if [ -n "${!var:-}" ]; then
          code="${!var%%|*}"
          quote="${!var#*|}"
          echo "FINDING_1_CODE: ${code}"
          echo "FINDING_1_QUOTE: ${quote}"
          echo "FINDING_1_DETAIL: an edge case is missing"
        fi
        local g
        for g in REQUIREMENT_COMPLETENESS CONTRADICTORY_REQUIREMENTS DEEP_SCOPE_AMBIGUITY EDGE_CASE_SUFFICIENCY; do
          if [ -n "${!var:-}" ] && [ "$g" = EDGE_CASE_SUFFICIENCY ]; then
            echo "GAP_${g}: finding"
          else
            echo "GAP_${g}: clear"
          fi
          echo "GAP_${g}_REASON: fixture"
        done
        echo "=== END DOR_SEMANTIC_SCAN ==="
      } >"$rf"
    else
      {
        echo "=== DOR_SEMANTIC_AUDIT ==="
        echo "SCHEMA_VERSION: 1"
        echo "TICKET: ${tid}"
        echo "BODY_HASH: ${h}"
        echo "SCORE_PLAUSIBLE: yes"
        echo "SCORE_REASON: fixture"
        echo "=== END DOR_SEMANTIC_AUDIT ==="
      } >"$rf"
    fi
  done <<<"$list"
}

# Runs SKILL.md step 1d + 1e: begin → (next → spawn → apply)* → gate.
# Sets GATE_RC and SPAWNS (lines spawned).
_gate() {
  local list rc=0
  SPAWNS=0
  planner_draft_readiness_begin "$INIT" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    local i
    for i in 1 2 3 4 5 6 7 8; do
      list=$(planner_draft_readiness_next "$INIT") || {
        rc=1
        break
      }
      [ "$list" = "done 0" ] && break
      SPAWNS=$((SPAWNS + $(printf '%s\n' "$list" | grep -c .)))
      _spawn_list "$list"
      planner_draft_readiness_apply "$INIT" || rc=1
    done
    [ "$rc" -eq 0 ] && { planner_draft_readiness_gate "$INIT" >/dev/null 2>&1 || rc=$?; }
  fi
  GATE_RC=$rc
}

_done_count() { grep -c '^[^|]*|META|draft-readiness|done|' "$LOG"; }

# ── 1. first run ─────────────────────────────────────────────────────────
echo "--- 1. first run: scan, audit, verdicts ---"
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1
l1=$(planner_draft_readiness_next "$INIT")
if [ "$(printf '%s\n' "$l1" | cut -f1,2 | tr '\t\n' ': ')" = "a-schema:scan b-api:scan " ]; then
  pass "first list: one scan per draft"
else
  fail "first list" "$l1"
fi
_spawn_list "$l1"
planner_draft_readiness_apply "$INIT"
l2=$(planner_draft_readiness_next "$INIT")
if [ "$(printf '%s\n' "$l2" | cut -f2 | sort -u)" = "audit" ] && [ "$(printf '%s\n' "$l2" | grep -c .)" = 2 ]; then
  pass "second list: the audits, built after the scans returned"
else
  fail "second list" "$l2"
fi
_spawn_list "$l2"
planner_draft_readiness_apply "$INIT"
l3=$(planner_draft_readiness_next "$INIT")
rc=0
planner_draft_readiness_gate "$INIT" >/dev/null 2>&1 || rc=$?
if [ "$l3" = "done 0" ] && [ "$rc" -eq 0 ] &&
  grep -q '|META|draft-readiness|done|ready 2/2$' "$LOG" &&
  [ "$(cut -d' ' -f3 "${DR}/a-schema/verdict")" = "ready" ] && [ -s "${DR}/b-api/semantic.json" ]; then
  pass "done 0, verdicts ready, gate passes with ready 2/2"
else
  fail "first gate" "l3=$l3 rc=$rc $(tail -3 "$LOG")"
fi
if [ ! -e "${REPOS_ROOT}/.ticket-auto/initiatives/_index" ] && [ ! -e "${IDIR}/tickets" ] &&
  [ ! -s "$LINEAR_CALLS" ] && [ -z "$(ls -A "$TMPDIR")" ]; then
  pass "no ticket manifest, no _index entry, no Linear call, sandbox removed"
else
  fail "side effects" "$(find "$REPOS_ROOT" -name manifest.json) $(ls -A "$TMPDIR")"
fi

# ── 2. cache ─────────────────────────────────────────────────────────────
echo "--- 2. unchanged specs: cache hit ---"
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$SPAWNS" -eq 0 ] && [ "$(_done_count)" -eq 2 ]; then
  pass "second run spawns nothing; both runs wrote their own done line"
else
  fail "cache" "rc=$GATE_RC spawns=$SPAWNS done=$(_done_count)"
fi

# ── 3. one spec edited ───────────────────────────────────────────────────
echo "--- 3. one edited spec ---"
sed -i 's/The Export button appears on the invoice list/The Export button appears on the invoice list toolbar/' "${SPECS}/a-schema.md"
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1
l=$(planner_draft_readiness_next "$INIT")
if [ "$(printf '%s\n' "$l" | cut -f1,2)" = "$(printf 'a-schema\tscan')" ]; then
  pass "only the edited spec is re-evaluated"
else
  fail "edit" "$l"
fi
_spawn_list "$l"
planner_draft_readiness_apply "$INIT"
_spawn_list "$(planner_draft_readiness_next "$INIT")"
planner_draft_readiness_apply "$INIT"
planner_draft_readiness_gate "$INIT" >/dev/null 2>&1
[ "$(wc -l <"$CROSSCHECK_CALLS")" -eq 0 ] && pass "no blocked run before: Crosscheck not re-run" ||
  fail "crosscheck rerun" "$(wc -l <"$CROSSCHECK_CALLS")"

# A spawn list from a crashed run is dropped by begin (no failed attempt),
# and every list is strictly spawn rows or `done N`.
sed -i 's/invoice list toolbar/invoice list toolbar menu/' "${SPECS}/a-schema.md"
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1
planner_draft_readiness_next "$INIT" >/dev/null 2>&1 # crash: no agent ran
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1
l=$(planner_draft_readiness_next "$INIT" 2>/dev/null)
if [ ! -e "${DR}/a-schema/attempts" ] && printf '%s\n' "$l" | grep -q $'^a-schema\tscan\t' &&
  printf '%s\n' "$l" | awk -F'\t' 'NF != 5 { bad = 1 } END { exit bad }'; then
  pass "begin drops a stale spawn list; list rows have 5 fields"
else
  fail "stale pending" "attempts=$(cat "${DR}/a-schema/attempts" 2>/dev/null) l=$l"
fi
_spawn_list "$l"
planner_draft_readiness_apply "$INIT"
_spawn_list "$(planner_draft_readiness_next "$INIT")"
planner_draft_readiness_apply "$INIT"
planner_draft_readiness_gate "$INIT" >/dev/null 2>&1

# ── 4. blocking finding ──────────────────────────────────────────────────
echo "--- 4. blocking finding halts ---"
sed -i 's/Export responds with 200/Export responds with 200 OK/' "${SPECS}/b-api.md"
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200 OK"
_gate
unset FINDINGS_b_api
run_fails=$(grep -c '|META|draft-readiness|fail|b-api EDGE_CASE_GAP "Export responds with 200 OK"' "$LOG")
if [ "$GATE_RC" -eq 3 ] && [ "$SPAWNS" -eq 2 ] && [ "$run_fails" -eq 1 ] &&
  grep -q '|META|draft-readiness|done|blocked 1/2$' "$LOG" &&
  [ "$(cut -d' ' -f3 "${DR}/b-api/verdict")" = "blocked" ] && [ -s "${DR}/blocked-specs" ]; then
  pass "rc 3, one fail line per finding, done blocked 1/2, blocked-specs recorded"
else
  fail "blocked" "rc=$GATE_RC spawns=$SPAWNS fails=$run_fails $(tail -4 "$LOG")"
fi
# A second, cached run: still blocked, no spawn, and the report shows the
# finding once — readers scope to the latest start.
_gate
report=$(planner_draft_readiness_report "$INIT")
if [ "$GATE_RC" -eq 3 ] && [ "$SPAWNS" -eq 0 ] &&
  [ "$(grep -c '|META|draft-readiness|fail|b-api EDGE_CASE_GAP' "$LOG")" -eq 2 ] &&
  [ "$(printf '%s\n' "$report" | grep -c 'EDGE_CASE_GAP')" -eq 1 ] &&
  printf '%s\n' "$report" | grep -q '^b-api (artifacts/specs/b-api.md)$' &&
  printf '%s\n' "$report" | grep -q 'does not guarantee Refinement passes' &&
  printf '%s\n' "$report" | grep -q -- '--accept DRAFT_NOT_READY'; then
  pass "cached re-run still blocks; report reads only the latest run"
else
  fail "scoped report" "rc=$GATE_RC spawns=$SPAWNS $report"
fi
desc=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$desc" | jq -r .reason)" = "DRAFT_NOT_READY" ] &&
  [ "$(echo "$desc" | jq -r '[.questions[].id] | join(",")')" = "draft-b-api,accept-DRAFT_NOT_READY,draft-resolved" ] &&
  echo "$desc" | jq -e '.questions[0].text | contains("EDGE_CASE_GAP")' >/dev/null &&
  case " $PLANNER_STOP_BLOCK_REASONS " in *" DRAFT_NOT_READY "*) true ;; *) false ;; esac then
  pass "describer: DRAFT_NOT_READY before CREATE_GATE, note per spec + accept + resolved"
else
  fail "describer" "$desc"
fi
planner_stop_describe "$INIT" | grep -q 'DRAFT_NOT_READY' && pass "describer block prints DRAFT_NOT_READY" ||
  fail "describer block" "$(planner_stop_describe "$INIT")"

# ── 5. accept ────────────────────────────────────────────────────────────
echo "--- 5. --accept DRAFT_NOT_READY ---"
planner_draft_readiness_accept "$INIT" "known gap, tracked elsewhere" >/dev/null 2>&1
acc_hash=$(planner_draft_readiness_combined_hash "$INIT")
if grep -q "|META|draft-readiness|accepted|${acc_hash} known gap, tracked elsewhere$" "$LOG" &&
  ! grep -q '|META|crosscheck|accepted|' "$LOG"; then
  pass "accept binds to the combined hash; no META|crosscheck|accepted"
else
  fail "accept" "$(grep accepted "$LOG")"
fi
[ "$(planner_draft_readiness_state "$INIT")" = "accepted" ] && pass "state: accepted" ||
  fail "state accepted" "$(planner_draft_readiness_state "$INIT")"
[ "$(planner_stop_describe_json "$INIT" | jq -r .reason)" = "CREATE_GATE" ] &&
  pass "describer: an accepted halt is no longer DRAFT_NOT_READY" ||
  fail "describer accepted" "$(planner_stop_describe_json "$INIT" | jq -c .)"
rc=0
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ] && tail -2 "$LOG" | grep -q "|META|draft-readiness|warn|accepted ${acc_hash} known gap" &&
  tail -1 "$LOG" | grep -q '|META|draft-readiness|done|accepted 2/2$'; then
  pass "gate passes on the accept, with a warn line"
else
  fail "accepted gate" "rc=$rc $(tail -2 "$LOG")"
fi
if ! planner_draft_readiness_accept "$INIT" "   " >/dev/null 2>&1; then
  pass "an empty reason is refused"
else
  fail "empty reason" "accepted"
fi

# planner-answers.sh: its own branch ahead of flag:accept:*.
source "${LIB_DIR}/planner-answers.sh"
# Re-block on a fresh edit first so the describer offers the accept question.
sed -i 's/Export responds with 200 OK/Export responds with HTTP 200 OK/' "${SPECS}/b-api.md"
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with HTTP 200 OK"
: >"$CROSSCHECK_CALLS"
_gate
unset FINDINGS_b_api
if [ "$GATE_RC" -eq 3 ] && [ "$(wc -l <"$CROSSCHECK_CALLS")" -eq 1 ]; then
  pass "a spec edit re-arms the accepted gate, after re-running Crosscheck"
else
  fail "re-arm" "rc=$GATE_RC crosscheck=$(wc -l <"$CROSSCHECK_CALLS")"
fi
round=$(planner_stop_round "$INIT")
jq -n --argjson r "$round" '{schema_version: 1, round: $r, answers: [
  {id: "accept-DRAFT_NOT_READY", value: "accepted via answers", answered_by: "U1", role: "operator", ts: "2026-10-30T00:00:00Z"}]}' \
  >"${TMP_ROOT}/answers.json"
arc=0
planner_answers_apply "$INIT" "${TMP_ROOT}/answers.json" >/dev/null 2>&1 || arc=$?
acc2=$(planner_draft_readiness_combined_hash "$INIT")
if [ "$arc" -eq 0 ] && grep -q "|META|draft-readiness|accepted|${acc2} accepted via answers$" "$LOG" &&
  ! grep -q '|META|crosscheck|accepted|' "$LOG"; then
  pass "answers flag:accept:DRAFT_NOT_READY → draft accept, never a Crosscheck accept"
else
  fail "answers accept" "rc=$arc $(grep accepted "$LOG")"
fi

# ── 6. Crosscheck re-run blocks ──────────────────────────────────────────
echo "--- 6. spec edit after a blocked run: Crosscheck first ---"
sed -i 's/Export responds with HTTP 200 OK/Export responds with HTTP 200/' "${SPECS}/b-api.md"
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with HTTP 200"
_gate
unset FINDINGS_b_api
[ "$GATE_RC" -eq 3 ] && pass "blocked again (setup)" || fail "setup" "rc=$GATE_RC"
sed -i 's/Export responds with HTTP 200/Export responds with status 200/' "${SPECS}/b-api.md"
CROSSCHECK_RC=1
_gate
CROSSCHECK_RC=0
report=$(planner_draft_readiness_report "$INIT")
if [ "$GATE_RC" -eq 3 ] && [ "$SPAWNS" -eq 0 ] &&
  tail -1 "$LOG" | grep -q '|META|draft-readiness|done|blocked crosscheck$' &&
  printf '%s\n' "$report" | grep -q 'CROSSCHECK REPORT' &&
  [ "$(planner_draft_readiness_state "$INIT")" = "crosscheck" ]; then
  pass "Crosscheck blocks: halt with Crosscheck's report, no draft spawn"
else
  fail "crosscheck halt" "rc=$GATE_RC spawns=$SPAWNS $report"
fi

# ── 7. unavailable ───────────────────────────────────────────────────────
echo "--- 7. two failed attempts → unavailable ---"
export BROKEN_b_api=1
_gate
unset BROKEN_b_api
if [ "$GATE_RC" -eq 3 ] && [ "$(cut -d' ' -f3 "${DR}/b-api/verdict")" = "unavailable" ] &&
  tail -3 "$LOG" | grep -q '|META|draft-readiness|fail|b-api SEMANTIC_UNAVAILABLE' && [ "$SPAWNS" -eq 4 ]; then
  pass "unparseable twice: unavailable, blocks, after exactly one retry"
else
  fail "unavailable" "rc=$GATE_RC spawns=$SPAWNS $(cat "${DR}/b-api/verdict" 2>/dev/null) $(tail -3 "$LOG")"
fi
sed -i 's/Export responds with status 200/Export responds with status code 200/' "${SPECS}/b-api.md"
export MISSING_b_api=1
_gate
unset MISSING_b_api
if [ "$GATE_RC" -eq 3 ] && [ "$(cut -d' ' -f3 "${DR}/b-api/verdict")" = "unavailable" ] && [ "$SPAWNS" -eq 2 ]; then
  pass "no result file written twice: unavailable"
else
  fail "missing result" "rc=$GATE_RC spawns=$SPAWNS"
fi
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$SPAWNS" -eq 2 ] && [ "$(cut -d' ' -f3 "${DR}/b-api/verdict")" = "ready" ]; then
  pass "the next run retries an unavailable draft (no edit needed)"
else
  fail "unavailable retry" "rc=$GATE_RC spawns=$SPAWNS"
fi

# ── 8. removed spec, --until Crosscheck ──────────────────────────────────
echo "--- 8. removed spec and --until Crosscheck ---"
rm -f "${SPECS}/b-api.md"
_gate
if [ ! -e "${DR}/b-api" ] && [ "$GATE_RC" -eq 0 ] && tail -1 "$LOG" | grep -q 'ready 1/1$'; then
  pass "a removed spec drops its directory; the rest passes"
else
  fail "removed spec" "rc=$GATE_RC $(ls "$DR") $(tail -1 "$LOG")"
fi
planner_stop_after_set "$INIT" "Crosscheck"
rc=0
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ] && tail -1 "$LOG" | grep -q '|META|draft-readiness|skip|--until Crosscheck$'; then
  pass "--until Crosscheck skips the gate with a skip line"
else
  fail "until skip" "rc=$rc $(tail -1 "$LOG")"
fi
planner_stop_after_set "$INIT" ""

if ! grep -q 'duplicate done entry' "$LOG" 2>/dev/null && [ "$(_done_count)" -ge 8 ]; then
  pass "every gate run wrote its own done line ($(_done_count))"
else
  fail "done lines" "$(_done_count)"
fi

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
