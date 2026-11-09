#!/usr/bin/env bash
# draft-readiness-loop-harness.sh — shared harness for the
# test-planner-draft-readiness-loop-*.sh suites (planner-draft-readiness slice
# S3b, design D8, D11, D12, D14): the bounded auto-revise loop of the draft
# readiness gate, driven exactly as SKILL.md steps 1d + 1e drive it.
#
# Sourced, never run. The scenarios are split over several files so the
# parallel test runner can spread them; each file sources this harness, runs
# its scenarios, then calls _loop_side_effects and _loop_finish.
#
# Agents are stubbed. An evaluation spawn writes a canned DOR_SEMANTIC_SCAN /
# AUDIT block; a revise spawn edits the spec and writes revise.r<N>.md
# according to REVISE_<slug> (fix | nofix | extend | rebut | frozen |
# missing | missing-once | forge | assume | assume-norow | missfix).
#
# Compose memo: planner_draft_readiness_compose is re-run on every refresh
# (begin, each next, apply, gate) for every spec, and was ~2/3 of the run
# time. The harness memoises it on everything it reads — its arguments, the
# PLANNER_*/DOR_* environment, the first Crosscheck|check|done line, and the
# bytes of every file under artifacts/ except draft-readiness/ — and replays
# the stored stdout, stderr and exit code, so a hit is byte-identical to a
# fresh compose. A failed compose is never stored. LOOP_TEST_COMPOSE_MEMO=0
# turns the memo off.

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
source "${LIB_DIR}/planner-draft-carryover.sh"
_planner_refinement_source_deps || exit 1

if [ "${LOOP_TEST_COMPOSE_MEMO:-1}" != 0 ]; then
  COMPOSE_MEMO="${TMP_ROOT}/compose-memo"
  mkdir -p "$COMPOSE_MEMO"
  eval "$(declare -f planner_draft_readiness_compose | sed '1s/^planner_draft_readiness_compose /_loop_compose_uncached /')"
  planner_draft_readiness_compose() {
    local idir="${REPOS_ROOT}/.ticket-auto/initiatives/$1" key f rc=0
    key=$({
      printf '%s\0' "$@"
      env | grep -E '^(PLANNER|DOR)_' | sort
      grep -E '^[^|]*\|Crosscheck\|check\|done\|' "${idir}/state.log" 2>/dev/null | head -1
      if [ -d "${idir}/artifacts" ]; then
        find "${idir}/artifacts" -path "${idir}/artifacts/draft-readiness" -prune -o -type f -print0 |
          sort -z | xargs -0 -r sha256sum
      fi
    } | sha256sum | cut -c1-64)
    f="${COMPOSE_MEMO}/${key}"
    if [ ! -f "${f}.out" ]; then
      _loop_compose_uncached "$@" >"${f}.out.tmp" 2>"${f}.err" || rc=$?
      if [ "$rc" -ne 0 ]; then
        cat "${f}.out.tmp"
        cat "${f}.err" >&2
        rm -f "${f}.out.tmp" "${f}.err"
        return "$rc"
      fi
      mv -f "${f}.out.tmp" "${f}.out"
    fi
    cat "${f}.err" >&2
    cat "${f}.out"
  }
fi

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

FIXTEXT="Export shows a progress message while the download starts"
ASM="Exports cap at 10000 rows per file"
ASM_AC="An export of more than 10000 invoices is split into files of 10000 rows"
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
  unset MISSED_a_schema MISSED_b_api MISSED_AFTER_b_api STRUCT_b_api
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
# Scan: FINDINGS_<slug> (code|quote[|detail]) is raised until the body holds
# FIXTEXT or the "for a finance user" extension; then
# AFTER_<slug> (code|quote[|detail]), if set. STRUCT_<slug> is always raised.
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
  local rest
  for f in "${list[@]}"; do
    i=$((i + 1))
    rest="${f#*|}"
    echo "FINDING_${i}_CODE: ${f%%|*}"
    echo "FINDING_${i}_QUOTE: ${rest%%|*}"
    if [[ "$rest" == *"|"* ]]; then
      echo "FINDING_${i}_DETAIL: ${rest#*|}"
    else
      echo "FINDING_${i}_DETAIL: fixture gap"
    fi
  done
  for g in REQUIREMENT_COMPLETENESS CONTRADICTORY_REQUIREMENTS DEEP_SCOPE_AMBIGUITY EDGE_CASE_SUFFICIENCY; do
    echo "GAP_${g}: clear"
    echo "GAP_${g}_REASON: fixture"
  done
  echo "=== END DOR_SEMANTIC_SCAN ==="
}
# MISSED_<slug> (code|reason) is reported by the audit until the body holds
# MISSFIX; MISSED_AFTER_<slug> after that, if set.
MISSFIX="Article bodies render as text, never as HTML"
_audit_block() {
  local var m
  echo "=== DOR_SEMANTIC_AUDIT ==="
  echo "SCHEMA_VERSION: 1"
  echo "TICKET: DRAFT-$1"
  echo "BODY_HASH: $(_hash_of "$1")"
  var="MISSED_${1//-/_}"
  grep -qF "$MISSFIX" "${DR}/$1/body.md" && var="MISSED_AFTER_${1//-/_}"
  m="${!var:-}"
  if [ -n "$m" ]; then
    echo "MISSED_1_CODE: ${m%%|*}"
    echo "MISSED_1_REASON: ${m#*|}"
  fi
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
  fix)
    if grep -qF "$FIXTEXT" "$spec"; then
      _add_criterion "$spec" "Invoice file names are HTML-escaped before display"
    else
      _add_criterion "$spec" "$FIXTEXT"
    fi
    ;;
  nofix) _add_criterion "$spec" "The export file name includes the date in round ${n}" ;;
  extend) sed -i 's/Export responds with 200/Export responds with 200 for a finance user/g' "$spec" ;;
  frozen) sed -i 's/^Scheduled exports\.$/Scheduled exports and reminders./' "$spec" ;;
  forge)
    # A hostile agent: a real fix, plus a forged round plan in the
    # workspace claiming the round is settled with no rows.
    _add_criterion "$spec" "$FIXTEXT"
    printf 'snap forged\nsettled\n' >"${DR}/round"
    ;;
  assume)
    # No source states the decision: a conservative default as a Scope
    # assumption row, plus a criterion that tests it.
    _add_criterion "$spec" "$ASM_AC"
    sed -i "s/^| BE | web | export route |\$/&\n\n- Assumption: ${ASM}/" "$spec"
    ;;
  assume-norow) _add_criterion "$spec" "$ASM_AC" ;;
  missfix) _add_criterion "$spec" "$MISSFIX" ;;
  esac
  : >"$rf"
  for id in $ids; do
    if [ "$mode" = "assume" ] || [ "$mode" = "assume-norow" ]; then
      echo "ASSUMED ${id} — added a row-cap criterion — assumption: \"${ASM}\"" >>"$rf"
    elif [ "$mode" = "rebut" ]; then
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

# ── 12. side effects (run at the end of every file) ───────────────────────
_loop_side_effects() {
  echo "--- 12. no Linear, no manifest, no snapshot left ---"
  if [ ! -s "$LINEAR_CALLS" ] && [ -z "$(find "$REPOS_ROOT" -name manifest.json)" ] &&
    [ ! -e "${REPOS_ROOT}/.ticket-auto/initiatives/_index" ] &&
    [ -z "$(find "$PLANNER_DRAFT_SNAPSHOT_ROOT" -mindepth 2 -maxdepth 2 2>/dev/null)" ] &&
    [ -z "$(ls -A "$TMPDIR")" ]; then
    pass "no Linear call, no ticket manifest, every snapshot dropped, no temp leftovers"
  else
    fail "side effects" "$(find "$REPOS_ROOT" -name manifest.json) $(find "$PLANNER_DRAFT_SNAPSHOT_ROOT" -mindepth 2 -maxdepth 2 2>/dev/null) $(ls -A "$TMPDIR")"
  fi
}

_loop_finish() {
  echo ""
  echo "=== ${PASS} passed, ${FAIL} failed ==="
  [ "$FAIL" -eq 0 ]
}
