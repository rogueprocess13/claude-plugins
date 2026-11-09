#!/usr/bin/env bash
# draft-readiness-gate-harness.sh — shared harness for the
# test-planner-draft-readiness-gate-*.sh suites (planner-draft-readiness slice
# S2b, design D1, D4–D7, D16): the halt-only gate, --accept DRAFT_NOT_READY,
# the stop describer, and the spawn-list protocol SKILL.md step 1e drives.
#
# Sourced, never run. The eight scenarios are split over three files so the
# parallel test runner can spread them (flow: 1–3, block: 4–5, recover: 6–8);
# each file sources this harness, runs its scenarios, then calls _gate_finish.
# A file that starts mid-sequence first runs _gate_prelude to reach the state
# its first scenario expects.
#
# Agents are stubbed: a "spawn" writes a canned DOR_SEMANTIC_SCAN/AUDIT block
# to the result file the spawn list names. planner_draft_readiness_compose is
# memoised (draft-readiness-compose-memo.sh; LOOP_TEST_COMPOSE_MEMO=0 turns
# it off).

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
# S2b's halt-only gate is PLANNER_DRAFT_REVISE_MAX_ROUNDS=0 since S3b (the
# revise loop has its own suites, test-planner-draft-readiness-loop-*.sh): this
# suite unchanged is the MAX_ROUNDS=0 parity check.
export PLANNER_DRAFT_REVISE_MAX_ROUNDS=0

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-draft-readiness-gate.sh"
source "${LIB_DIR}/planner-stop-describe.sh"
_planner_refinement_source_deps || exit 1
source "${SCRIPT_DIR}/draft-readiness-compose-memo.sh"

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

# _gate_prelude [<text>]: brings the fresh initiative to a passed first run
# (scenario 1's end state, without its checks). With <text>, b-api's
# "Export responds with 200" criterion first becomes "Export responds with
# <text>" — the wording the file's first scenario edits.
_gate_prelude() {
  if [ -n "${1:-}" ]; then
    sed -i "s/Export responds with 200/Export responds with $1/" "${SPECS}/b-api.md"
  fi
  _gate
  if [ "$GATE_RC" -eq 0 ] && [ "$SPAWNS" -eq 4 ]; then
    pass "prelude: a clean first run passes"
  else
    fail "prelude" "rc=$GATE_RC spawns=$SPAWNS $(tail -3 "$LOG")"
  fi
}

# Scenario 1's side-effect check, repeated at the end of every file: no
# ticket manifest, no _index entry, no Linear call, no sandbox left behind.
_gate_side_effects() {
  if [ ! -e "${REPOS_ROOT}/.ticket-auto/initiatives/_index" ] && [ ! -e "${IDIR}/tickets" ] &&
    [ ! -s "$LINEAR_CALLS" ] && [ -z "$(ls -A "$TMPDIR")" ]; then
    pass "end of file: no ticket manifest, no _index entry, no Linear call, sandbox removed"
  else
    fail "end-of-file side effects" "$(find "$REPOS_ROOT" -name manifest.json) $(ls -A "$TMPDIR")"
  fi
}

# _gate_finish <min-done-lines>: every gate run in the file wrote its own
# done line, the side-effect check, then the summary. Its status is the
# file's exit status.
_gate_finish() {
  local min="$1"
  if ! grep -q 'duplicate done entry' "$LOG" 2>/dev/null && [ "$(_done_count)" -ge "$min" ]; then
    pass "every gate run wrote its own done line ($(_done_count))"
  else
    fail "done lines" "$(_done_count)"
  fi
  _gate_side_effects
  echo ""
  echo "=== ${PASS} passed, ${FAIL} failed ==="
  [ "$FAIL" -eq 0 ]
}
