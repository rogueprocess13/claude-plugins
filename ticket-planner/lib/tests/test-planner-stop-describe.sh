#!/usr/bin/env bash
# test-planner-stop-describe.sh — Tests for planner-stop-describe.sh
# (planner-headless-questions).
#
# Three things are pinned here:
#   1. Every real halt (halt-fixtures.sh runs each SKILL.md halt block
#      verbatim) still prints exactly its golden stdout/stderr/exit code —
#      the describer must not change any halt.
#   2. On the state each halt leaves behind, the describer names the same
#      reason the halt fired for, and its block parses as a valid
#      human-hold Schema-Version 2 block.
#   3. The terminal reasons, round numbering and byte-for-byte stability.
#
# Run: bash ticket-planner/lib/tests/test-planner-stop-describe.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
GOLDEN_DIR="${SCRIPT_DIR}/fixtures/halt-goldens"
HOLD_PARSER="${LIB_DIR}/../../ticket-auto-pipeline/lib/human-hold-parse.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# A scratch HOME, so the cross-plugin resolvers use this checkout's
# ticket-auto-pipeline — the same condition the goldens were captured under.
export HOME="${WORK}/home"
mkdir -p "$HOME"
export CLAUDE_PLUGIN_ROOT
CLAUDE_PLUGIN_ROOT="$(cd "$LIB_DIR/.." && pwd)"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-stop-describe.sh"
source "${SCRIPT_DIR}/halt-fixtures.sh"
# The describer sources it too; sourced here so the Specify-decision cases
# can read the scan directly (and fail, not abort, if it is missing).
[ -f "${LIB_DIR}/planner-specify-decisions.sh" ] && source "${LIB_DIR}/planner-specify-decisions.sh"

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

INIT="INIT-1700000000-4242"

# fresh_root <name> — point REPOS_ROOT at an empty directory.
fresh_root() {
  export REPOS_ROOT="${WORK}/repos-$1"
  rm -rf "$REPOS_ROOT"
  mkdir -p "$REPOS_ROOT"
}

reason_of() {
  planner_stop_describe_json "$1" | jq -r '.reason'
}

echo "=== planner-stop-describe tests ==="

# ── 1 + 2: halt goldens and reason parity ──────────────────────────────────

echo "--- halts: goldens unchanged, describer agrees ---"

for pair in $HALT_FIXTURE_REASONS; do
  name="${pair%%:*}"
  expected="${pair#*:}"
  fresh_root "$name"
  halt_fixture_init "$name" "$INIT" >/dev/null
  halt_fixture_run "$name" "$INIT" "${WORK}/run"

  drift=""
  for ext in out err rc; do
    if ! cmp -s "${WORK}/run/${name}.${ext}" "${GOLDEN_DIR}/${name}.${ext}"; then
      drift="${drift} .${ext}"
    fi
  done
  if [ -z "$drift" ]; then
    pass "${name}: halt output matches its golden"
  else
    fail "${name}: halt output matches its golden" "differs in${drift} — diff ${WORK}/run/${name}.* ${GOLDEN_DIR}/"
  fi

  got=$(reason_of "$INIT")
  if [ "$got" = "$expected" ]; then
    pass "${name}: describer names ${expected}"
  else
    fail "${name}: describer names ${expected}" "got '${got}'"
  fi

  # Every planner stop is an operator decision, except a Specify business
  # decision: the client's question, which the operator may answer for them.
  want_audience=operator
  [ "$expected" != "SPECIFY_DECISION" ] || want_audience=either
  planner_stop_describe "$INIT" >"${WORK}/${name}.hold"
  parsed=$(bash "$HOLD_PARSER" --phase PLANNER --return-file "${WORK}/${name}.hold" 2>&1)
  if [ "$(printf '%s' "$parsed" | jq -r '.parse_status' 2>/dev/null)" = "ok" ] &&
    [ "$(printf '%s' "$parsed" | jq -r '.schema_version')" = "2" ] &&
    [ "$(printf '%s' "$parsed" | jq -r '.reason')" = "$expected" ] &&
    [ "$(printf '%s' "$parsed" | jq -r '.audience')" = "$want_audience" ]; then
    pass "${name}: block parses as a valid v2 human-hold"
  else
    fail "${name}: block parses as a valid v2 human-hold" "$parsed"
  fi

  # Stability: same log, byte-identical output.
  if cmp -s "${WORK}/${name}.hold" <(planner_stop_describe "$INIT"); then
    pass "${name}: re-describing is byte-identical"
  else
    fail "${name}: re-describing is byte-identical" "output changed with no log change"
  fi
done

# ── per-reason question shape ──────────────────────────────────────────────

echo "--- question shapes ---"

fresh_root shape-create
halt_fixture_init create-gate-stop "$INIT" >/dev/null
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '.kind + " " + (.questions | length | tostring) + " " + .questions[0].id + " " + .questions[0].binding + " " + (.questions[0].options | join("|")) + " " + .questions[0].default')" = "approval 1 create flag:create yes|no no" ]; then
  pass "CREATE_GATE: one operator approval bound to flag:create, default no"
else
  fail "CREATE_GATE: one operator approval bound to flag:create, default no" "$m"
fi

fresh_root shape-cc
halt_fixture_init crosscheck "$INIT" >/dev/null
halt_fixture_run crosscheck "$INIT" "${WORK}/run" # records the findings
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '[.questions[].binding] | join(" ")')" = "flag:accept:CARVE_SCOPE_LOST flag:accept:CITATION_UNRESOLVED" ]; then
  pass "CROSSCHECK_BLOCKED: one question per blocking code; warn codes excluded"
else
  fail "CROSSCHECK_BLOCKED: one question per blocking code; warn codes excluded" "$m"
fi

source "${LIB_DIR}/planner-crosscheck.sh"
planner_crosscheck_accept_set "$INIT" "CARVE_SCOPE_LOST" "documented rescope"
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '[.questions[].id] | join(" ")')" = "accept-CITATION_UNRESOLVED" ]; then
  pass "CROSSCHECK_BLOCKED: an accepted code is no longer asked"
else
  fail "CROSSCHECK_BLOCKED: an accepted code is no longer asked" "$m"
fi

planner_crosscheck_accept_set "$INIT" "CITATION_UNRESOLVED" "known stale path"
if [ "$(reason_of "$INIT")" = "RUNNING" ]; then
  pass "CROSSCHECK_BLOCKED: every code accepted → RUNNING (resume re-runs Crosscheck)"
else
  fail "CROSSCHECK_BLOCKED: every code accepted → RUNNING (resume re-runs Crosscheck)" "$(reason_of "$INIT")"
fi

fresh_root shape-project
halt_fixture_init project-gate "$INIT" >/dev/null
halt_fixture_run project-gate "$INIT" "${WORK}/run"
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '.questions[0].binding + " " + (.questions[0].options | join("|"))')" = "flag:project Ledgerly|__none__" ]; then
  pass "PROJECT_GATE: options are the candidate plus __none__"
else
  fail "PROJECT_GATE: options are the candidate plus __none__" "$m"
fi

fresh_root shape-refinement
halt_fixture_init refinement "$INIT" >/dev/null
halt_fixture_run refinement "$INIT" "${WORK}/run"
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '[.questions[].binding] | join(" ")')" = "waive:PRO-102:INTENT_MISSING" ]; then
  pass "REFINEMENT_HALT: one waiver question per (not-ready ticket, code); ready tickets excluded"
else
  fail "REFINEMENT_HALT: one waiver question per (not-ready ticket, code); ready tickets excluded" "$m"
fi

fresh_root shape-body-drift
halt_fixture_init refinement-body-drift "$INIT" >/dev/null
halt_fixture_run refinement-body-drift "$INIT" "${WORK}/run"
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '[.questions[].binding] | join(" ")')" = "flag:refresh-bodies waive:PRO-102:INTENT_MISSING" ] &&
  [ "$(echo "$m" | jq -r '.questions[0].id + " " + (.questions[0].options | join("|")) + " " + .questions[0].default')" = "refresh-bodies yes|no no" ] &&
  echo "$m" | jq -r '.questions[0].text' | grep -qF "PRO-101" &&
  ! echo "$m" | jq -r '[.questions[].binding] | join(" ")' | grep -q "BODY_"; then
  pass "REFINEMENT_HALT: BODY_DRIFT offers the refresh-bodies binding, never a waive"
else
  fail "REFINEMENT_HALT: BODY_DRIFT offers the refresh-bodies binding, never a waive" "$m"
fi
source "${LIB_DIR}/planner-answers.sh"
_ans="${WORK}/answers-refresh.json"
jq -n --argjson r "$(echo "$m" | jq '.round')" '{schema_version: 1, round: $r, answers: [
  {id: "refresh-bodies", value: "yes", answered_by: "op", role: "operator", ts: "2026-10-22T00:00:00Z"}]}' >"$_ans"
if planner_answers_apply "$INIT" "$_ans" >/dev/null 2>&1 &&
  [ "$(planner_config_get "$INIT" "refresh-bodies")" = "true" ]; then
  pass "answers: refresh-bodies yes persists the one-shot refresh-bodies config"
else
  fail "answers: refresh-bodies yes persists the one-shot refresh-bodies config" "config=$(planner_config_get "$INIT" "refresh-bodies")"
fi

fresh_root shape-demoted
halt_fixture_init refinement-demoted "$INIT" >/dev/null
halt_fixture_run refinement-demoted "$INIT" "${WORK}/run"
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '[.questions[].binding] | join(" ")')" = "waive:PRO-102:INTENT_MISSING" ]; then
  pass "REFINEMENT_HALT: an audit-demoted code is not offered as a waiver"
else
  fail "REFINEMENT_HALT: an audit-demoted code is not offered as a waiver" "$m"
fi

fresh_root shape-adr
halt_fixture_init adr-gate "$INIT" >/dev/null
m=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$m" | jq -r '.questions[0].id + " " + .questions[0].binding')" = "adr-ADR-0007 note" ]; then
  pass "ADR_GATE: bound as note (adr-store accept refuses inside an agent session)"
else
  fail "ADR_GATE: bound as note (adr-store accept refuses inside an agent session)" "$m"
fi

# ── terminal reasons ───────────────────────────────────────────────────────

echo "--- terminal reasons ---"

fresh_root completed
planner_state_init "$INIT" "idea" >/dev/null
_halt_done "$INIT" Appraisal Discovery Architecture Specify Review Consensus Crosscheck EpicGen TicketGen Refinement Completed
out=$(planner_stop_describe "$INIT")
rc=$?
if [ "$out" = "REASON=COMPLETED" ] && [ "$rc" -eq 0 ]; then
  pass "COMPLETED: empty position prints REASON=COMPLETED, exit 0"
else
  fail "COMPLETED: empty position prints REASON=COMPLETED, exit 0" "rc=$rc out=$out"
fi

fresh_root running
planner_state_init "$INIT" "idea" >/dev/null
_halt_done "$INIT" Appraisal
planner_state_write "$INIT" "Discovery" "explore" "start" "x"
if [ "$(planner_stop_describe "$INIT")" = "REASON=RUNNING" ]; then
  pass "RUNNING: an interrupted phase needs only a resume"
else
  fail "RUNNING: an interrupted phase needs only a resume" "$(planner_stop_describe "$INIT")"
fi

echo "$$" >"$(planner_state_log "$INIT").phase-lock"
_halt_done "$INIT" Discovery Architecture Specify Review Consensus Crosscheck
if [ "$(planner_stop_describe "$INIT")" = "REASON=RUNNING" ]; then
  pass "RUNNING: a live phase lock wins over any gate"
else
  fail "RUNNING: a live phase lock wins over any gate" "$(planner_stop_describe "$INIT")"
fi
rm -f "$(planner_state_log "$INIT").phase-lock"

fresh_root exhausted
planner_state_init "$INIT" "idea" >/dev/null
_halt_done "$INIT" Appraisal
for _i in 1 2 3; do
  planner_state_write "$INIT" "Discovery" "explore" "start" "x"
  planner_state_write "$INIT" "Discovery" "explore" "fail" "boom"
done
if [ "$(planner_stop_describe "$INIT")" = "REASON=FAILED_RETRY_EXHAUSTED" ]; then
  pass "FAILED_RETRY_EXHAUSTED: a phase past PLANNER_MAX_PHASE_RETRIES"
else
  fail "FAILED_RETRY_EXHAUSTED: a phase past PLANNER_MAX_PHASE_RETRIES" "$(planner_stop_describe "$INIT")"
fi

# ── test-data questions (planner-test-data-derivation) ─────────────────────

echo "--- test-data questions ---"

fresh_root shape-td
halt_fixture_init crosscheck-testdata "$INIT" >/dev/null
halt_fixture_run crosscheck-testdata "$INIT" "${WORK}/run"
TD_ART="$(planner_initiative_dir "$INIT")/artifacts"
h_audit=$(planner_testdata_confirm_hash audit-log "The audit page lists 3 audit entries")
h_inv=$(planner_testdata_confirm_hash invoice-list "The list shows 5 overdue invoices")
m=$(planner_stop_describe_json "$INIT")
got=$(echo "$m" | jq -r '[.questions[] | .id + "=" + .binding] | join(" ")')
want="testdata-audit-log-${h_audit}=consensus-answer:testdata:audit-log testdata-invoice-list-${h_inv}=consensus-answer:testdata:invoice-list accept-TEST_DATA_IMPLIED=flag:accept:TEST_DATA_IMPLIED"
if [ "$got" = "$want" ]; then
  pass "TEST_DATA_IMPLIED: one testdata question per spec, ahead of the accept question"
else
  fail "TEST_DATA_IMPLIED: one testdata question per spec, ahead of the accept question" "$got"
fi
if [ "$(echo "$m" | jq -r '.questions[0] | (.options | join("|")) + " / " + .default')" = "none|generate: 3 audit entries|exists|external / generate: 3 audit entries" ]; then
  pass "TEST_DATA_IMPLIED: options none|generate: <phrase>|exists|external, default generate: <matched phrase>"
else
  fail "TEST_DATA_IMPLIED: options none|generate: <phrase>|exists|external, default generate: <matched phrase>" "$(echo "$m" | jq -c '.questions[0]')"
fi
if [ "$(planner_stop_describe_json "$INIT" | jq -r '[.questions[].id] | join(" ")')" = "$(echo "$m" | jq -r '[.questions[].id] | join(" ")')" ]; then
  pass "TEST_DATA_IMPLIED: ids are stable across re-describes"
else
  fail "TEST_DATA_IMPLIED: ids are stable across re-describes" "ids changed with no artifact change"
fi

# An answer under the current hash resolves the spec: its question goes.
planner_testdata_answer_set "${TD_ART}/consensus.md" audit-log "$h_audit" none >/dev/null
got=$(planner_stop_describe_json "$INIT" | jq -r '[.questions[].id] | join(" ")')
if [ "$got" = "testdata-invoice-list-${h_inv} accept-TEST_DATA_IMPLIED" ]; then
  pass "TEST_DATA_IMPLIED: a spec answered under its current hash is not asked again"
else
  fail "TEST_DATA_IMPLIED: a spec answered under its current hash is not asked again" "$got"
fi

# Rewriting the criterion re-asks under a new id (and voids the old answer).
sed -i 's/lists 3 audit entries/lists 4 audit entries/' "${TD_ART}/specs/audit-log.md"
h_new=$(planner_testdata_confirm_hash audit-log "The audit page lists 4 audit entries")
got=$(planner_stop_describe_json "$INIT" | jq -r '[.questions[].id] | join(" ")')
if [ "$h_new" != "$h_audit" ] && [ "$got" = "testdata-audit-log-${h_new} testdata-invoice-list-${h_inv} accept-TEST_DATA_IMPLIED" ]; then
  pass "TEST_DATA_IMPLIED: a rewritten criterion is re-asked under its new hash"
else
  fail "TEST_DATA_IMPLIED: a rewritten criterion is re-asked under its new hash" "$got"
fi

planner_crosscheck_accept_set "$INIT" "TEST_DATA_IMPLIED" "data is seeded out of band"
if [ "$(reason_of "$INIT")" = "RUNNING" ]; then
  pass "TEST_DATA_IMPLIED: an accepted code asks no testdata questions"
else
  fail "TEST_DATA_IMPLIED: an accepted code asks no testdata questions" "$(planner_stop_describe_json "$INIT")"
fi

# ── round numbering ────────────────────────────────────────────────────────

echo "--- rounds ---"

fresh_root rounds
halt_fixture_init create-gate-stop "$INIT" >/dev/null
r1=$(planner_stop_describe_json "$INIT" | jq -r '.round')
planner_state_write "$INIT" "META" "human-hold" "start" "round=1 sha=aaa"
planner_state_write "$INIT" "META" "human-hold" "done" "round=1 sha=aaa"
r2=$(planner_stop_describe_json "$INIT" | jq -r '.round')
if [ "$r1" = "1" ] && [ "$r2" = "2" ]; then
  pass "ROUND is one more than the count of META|human-hold|done lines"
else
  fail "ROUND is one more than the count of META|human-hold|done lines" "r1=$r1 r2=$r2"
fi

if planner_stop_describe "$INIT" | grep -qx 'QUESTION_1_ID: create'; then
  pass "question ids do not change between rounds"
else
  fail "question ids do not change between rounds" "$(planner_stop_describe "$INIT")"
fi

# ── Specify decisions (planner-specify-waiting-on-human) ───────────────────

echo "--- Specify decisions ---"

# specify_fixture <name> — Specify done, position Review, proposal.md from
# stdin. Feed it a here-string, never a pipe: a pipe runs it in a subshell
# and the REPOS_ROOT that fresh_root exports would not reach this shell.
specify_fixture() {
  fresh_root "$1"
  planner_state_init "$INIT" "idea" >/dev/null
  _halt_done "$INIT" Appraisal Discovery Architecture Specify
  cat >"$(planner_initiative_dir "$INIT")/artifacts/proposal.md"
}

# answer_line <oid> — replace that outcome's marker line with an answer, as
# intake does (one line for one line).
answer_line() {
  local p
  p="$(planner_initiative_dir "$INIT")/artifacts/proposal.md"
  sed -i "/^### $1\$/,/^### /s/^\*\*Outcome:\*\* NEEDS_HUMAN_DECISION.*/**Outcome:** Human decision (verbatim, round 1, client): \"answered\"/" "$p"
}

SD_PROPOSAL='# Proposal

## Business Outcomes

### O1
**Who:** Not specified
**Need:** Not specified
**Outcome:** NEEDS_HUMAN_DECISION — which role consumes the classified documents?

### O2
**Outcome:** Finance users export invoices without asking support.

### O3
**Outcome:** NEEDS_HUMAN_DECISION: how often is the export run?

## Risks

None.'

if ! declare -f planner_specify_decisions_open >/dev/null 2>&1; then
  fail "SPECIFY_DECISION: tests" "planner_specify_decisions_open missing (planner-specify-decisions.sh not sourced)"
else
  specify_fixture sd-two <<<"$SD_PROPOSAL"
  m=$(planner_stop_describe_json "$INIT")
  scan=$(planner_specify_decisions_open "$INIT")
  h1=$(printf '%s\n' "$scan" | awk -F'\t' '$1 == "O1" { print $2 }')
  h3=$(printf '%s\n' "$scan" | awk -F'\t' '$1 == "O3" { print $2 }')
  got=$(echo "$m" | jq -r '.reason + " " + .kind + " " + .audience + " " + .blocks + " " + ([.questions[] | .id + "=" + .binding] | join(" "))')
  want="SPECIFY_DECISION input either artifacts/proposal.md decision-O1-${h1}=specify-answer:O1 decision-O3-${h3}=specify-answer:O3"
  if [ -n "$h1" ] && [ -n "$h3" ] && [ "$got" = "$want" ]; then
    pass "SPECIFY_DECISION: one input question per open decision, in file order, audience either"
  else
    fail "SPECIFY_DECISION: one input question per open decision, in file order, audience either" "$got"
  fi

  if echo "$m" | jq -e '[.questions[] | has("options") or has("default")] | any | not' >/dev/null 2>&1 &&
    echo "$m" | jq -e '.questions[0].text | contains("which role consumes the classified documents?") and contains("__defer__") and contains("500 characters")' >/dev/null 2>&1; then
    pass "SPECIFY_DECISION: no OPTIONS, no DEFAULT; the text quotes the question and names __defer__"
  else
    fail "SPECIFY_DECISION: no OPTIONS, no DEFAULT; the text quotes the question and names __defer__" "$(echo "$m" | jq -c '.questions')"
  fi

  planner_stop_describe "$INIT" >"${WORK}/sd.hold"
  parsed=$(bash "$HOLD_PARSER" --phase PLANNER --return-file "${WORK}/sd.hold" 2>&1)
  if [ "$(printf '%s' "$parsed" | jq -r '.parse_status' 2>/dev/null)" = "ok" ] &&
    [ "$(printf '%s' "$parsed" | jq -r '.reason + " " + .kind + " " + .audience')" = "SPECIFY_DECISION input either" ] &&
    [ "$(printf '%s' "$parsed" | jq -r '[.questions[].binding] | join(" ")')" = "specify-answer:O1 specify-answer:O3" ] &&
    ! grep -q '_OPTIONS:\|_DEFAULT:' "${WORK}/sd.hold"; then
    pass "SPECIFY_DECISION: block parses as a valid v2 human-hold"
  else
    fail "SPECIFY_DECISION: block parses as a valid v2 human-hold" "$parsed"
  fi

  if cmp -s "${WORK}/sd.hold" <(planner_stop_describe "$INIT"); then
    pass "SPECIFY_DECISION: re-describing is byte-identical"
  else
    fail "SPECIFY_DECISION: re-describing is byte-identical" "output changed with no change"
  fi

  if ! grep -q 'specify-gate' "$(planner_state_log "$INIT")"; then
    pass "SPECIFY_DECISION: describing writes nothing to the state log"
  else
    fail "SPECIFY_DECISION: describing writes nothing to the state log" "found a specify-gate line"
  fi

  # A 700-character question is cut at 600, not the default 200.
  long=$(printf 'a%.0s' $(seq 1 700))
  specify_fixture sd-long <<<"$(printf '# Proposal\n\n## Business Outcomes\n\n### O1\n**Outcome:** NEEDS_HUMAN_DECISION — %s\n' "$long")"
  if planner_stop_describe_json "$INIT" | jq -e --arg a600 "${long:0:600}" --arg a601 "${long:0:601}" \
    '.questions[0].text | contains($a600 + "…") and (contains($a601) | not)' >/dev/null 2>&1; then
    pass "SPECIFY_DECISION: a 700-character question is cut at 600"
  else
    fail "SPECIFY_DECISION: a 700-character question is cut at 600" "$(planner_stop_describe_json "$INIT" | jq -r '.questions[0].text | length')"
  fi

  # --until Specify: the decision first, the until stop once it is answered.
  specify_fixture sd-until <<<"$(printf '%s\n' "$SD_PROPOSAL" | sed '/^### O3$/,$d')"
  planner_stop_after_set "$INIT" "Specify"
  first=$(reason_of "$INIT")
  answer_line O1
  second=$(reason_of "$INIT")
  if [ "$first" = "SPECIFY_DECISION" ] && [ "$second" = "UNTIL_STOP" ]; then
    pass "SPECIFY_DECISION: with --until Specify, the decision comes first, then UNTIL_STOP"
  else
    fail "SPECIFY_DECISION: with --until Specify, the decision comes first, then UNTIL_STOP" "first=${first} second=${second}"
  fi

  # Partly answered: only O3 is asked; all answered: RUNNING.
  specify_fixture sd-answered <<<"$SD_PROPOSAL"
  answer_line O1
  got=$(planner_stop_describe_json "$INIT" | jq -r '[.questions[].binding] | join(" ")')
  answer_line O3
  if [ "$got" = "specify-answer:O3" ] && [ "$(planner_stop_describe "$INIT")" = "REASON=RUNNING" ]; then
    pass "SPECIFY_DECISION: an answered decision is not asked; all answered → REASON=RUNNING"
  else
    fail "SPECIFY_DECISION: an answered decision is not asked; all answered → REASON=RUNNING" "partial=${got} all=$(planner_stop_describe "$INIT")"
  fi

  # Only at Review: the same proposal at Consensus asks nothing.
  specify_fixture sd-later <<<"$SD_PROPOSAL"
  _halt_done "$INIT" Review
  if [ "$(reason_of "$INIT")" = "RUNNING" ]; then
    pass "SPECIFY_DECISION: asked only at position Review"
  else
    fail "SPECIFY_DECISION: asked only at position Review" "$(reason_of "$INIT")"
  fi
fi

# ── Specify parameters (planner-specify-parameters) ────────────────────────

echo "--- Specify parameters ---"

PP_PROPOSAL='# Proposal

## Business Outcomes

### O1
**Outcome:** NEEDS_HUMAN_DECISION — which role signs off the exported invoices?

## Parameters

| Name | Key | Kind | Default | Value | Source |
|------|-----|------|---------|-------|--------|
| Invoice rounding | `billing.total_rounding` | rounding | half-up, 2 decimal places | NEEDS_HUMAN_DECISION — round each line, or only the invoice total? | — |
| Idle session timeout | `auth.session_idle_minutes` | duration | 30 minutes | 30 minutes | default |
| Payment retry delay | `payments.retry_delay` | duration | 5 minutes | 5 minutes | default |
| Export link lifetime | `export.link_ttl` | policy | — | NEEDS_HUMAN_DECISION | — |

## Risks

None.'

# param_fixture <name> [legacy] — specify_fixture plus the contract marker
# (unless legacy) and two specs that name billing.total_rounding.
param_fixture() {
  specify_fixture "$1" <<<"$PP_PROPOSAL"
  [ "${2:-}" = legacy ] || planner_state_write "$INIT" META contract start specify-parameters-v1
  local sd
  sd="$(planner_initiative_dir "$INIT")/artifacts/specs"
  mkdir -p "$sd"
  printf '# Invoice total\n\n## Technical Context\n\nRounds per `billing.total_rounding`.\n' >"${sd}/invoice-total.md"
  printf '# Export link\n\nUses `billing.total_rounding` and `export.link_ttl`.\n' >"${sd}/export-link.md"
  printf '# Index\n\n`billing.total_rounding`\n' >"${sd}/INDEX.md"
}

# qtext <model> <id>
qtext() { echo "$1" | jq -r --arg id "$2" '.questions[] | select(.id == $id) | .text'; }

# in_order <text> <needle...> — every needle occurs, each after the previous.
in_order() {
  local t="$1" n rest
  shift
  rest="$t"
  for n in "$@"; do
    case "$rest" in *"$n"*) rest="${rest#*"$n"}" ;; *) return 1 ;; esac
  done
  return 0
}

if ! declare -f planner_params_scan >/dev/null 2>&1; then
  fail "SPECIFY_DECISION parameters: tests" "planner_params_scan missing"
else
  param_fixture pp-review
  m=$(planner_stop_describe_json "$INIT")
  h1=$(planner_specify_decisions_open "$INIT" | awk -F'\t' '$1 == "O1" { print $2 }')
  got=$(echo "$m" | jq -r '.reason + " " + .kind + " " + .audience + " " + ([.questions[] | .id + "=" + .binding] | join(" "))')
  want="SPECIFY_DECISION input either decision-O1-${h1}=specify-answer:O1 param-billing.total_rounding=specify-param:billing.total_rounding param-payments.retry_delay=specify-param:payments.retry_delay param-export.link_ttl=specify-param:export.link_ttl"
  if [ "$got" = "$want" ]; then
    pass "SPECIFY_DECISION parameters: outcomes first, then one question per open row in table order"
  else
    fail "SPECIFY_DECISION parameters: outcomes first, then one question per open row in table order" "$got"
  fi

  t=$(qtext "$m" param-billing.total_rounding)
  if [[ "$t" == "round each line, or only the invoice total? "* ]] &&
    in_order "$t" 'Suggested: "half-up, 2 decimal places"' 'reply with exactly that text' \
      '(Invoice rounding; key billing.total_rounding, rounding; used by export-link, invoice-total)' &&
    [[ "$t" != *"number with a unit"* ]] && [[ "$t" != *"__defer__"* ]]; then
    pass "parameter question: plain question, suggestion, then name/key/kind/used-by; no format hint for rounding"
  else
    fail "parameter question: plain question, suggestion, then name/key/kind/used-by; no format hint for rounding" "$t"
  fi

  t=$(qtext "$m" param-payments.retry_delay)
  if [[ "$t" == 'Specify assumed "5 minutes" — is that right? '* ]] &&
    in_order "$t" 'Suggested: "5 minutes"' 'as a number with a unit, e.g. 30 minutes' \
      '(Payment retry delay; key payments.retry_delay, duration)'; then
    pass "parameter question: keyword-promoted duration row gets the number+unit hint after the suggestion"
  else
    fail "parameter question: keyword-promoted duration row gets the number+unit hint after the suggestion" "$t"
  fi

  t=$(qtext "$m" param-export.link_ttl)
  if [[ "$t" == "(no question was written — what should Export link lifetime be?)"* ]] &&
    [[ "$t" != *"Suggested:"* ]] && [[ "$t" == *"(Export link lifetime; key export.link_ttl, policy; used by export-link)" ]]; then
    pass "parameter question: no suggestion → no Suggested sentence"
  else
    fail "parameter question: no suggestion → no Suggested sentence" "$t"
  fi

  if echo "$m" | jq -e '[.questions[] | has("options") or has("default")] | any | not' >/dev/null 2>&1 &&
    echo "$m" | jq -e '[.questions[].text | length <= 601] | all' >/dev/null 2>&1; then
    pass "parameter questions: no OPTIONS, no DEFAULT, text capped at 600"
  else
    fail "parameter questions: no OPTIONS, no DEFAULT, text capped at 600" "$(echo "$m" | jq -c '.questions')"
  fi

  planner_stop_describe "$INIT" >"${WORK}/pp.hold"
  parsed=$(bash "$HOLD_PARSER" --phase PLANNER --return-file "${WORK}/pp.hold" 2>&1)
  if [ "$(printf '%s' "$parsed" | jq -r '.parse_status' 2>/dev/null)" = "ok" ] &&
    [ "$(printf '%s' "$parsed" | jq -r '[.questions[].binding] | join(" ")')" = "specify-answer:O1 specify-param:billing.total_rounding specify-param:payments.retry_delay specify-param:export.link_ttl" ]; then
    pass "mixed SPECIFY_DECISION block parses with this checkout's human-hold-parse.sh"
  else
    fail "mixed SPECIFY_DECISION block parses with this checkout's human-hold-parse.sh" "$parsed"
  fi
  if cmp -s "${WORK}/pp.hold" <(planner_stop_describe "$INIT"); then
    pass "mixed SPECIFY_DECISION: re-describing is byte-identical"
  else
    fail "mixed SPECIFY_DECISION: re-describing is byte-identical" "output changed with no change"
  fi

  # The outcome question keeps its pre-parameter text.
  t=$(qtext "$m" "decision-O1-${h1}")
  if [ "$t" = "Specify could not source business outcome O1 and needs a decision: which role signs off the exported invoices?. Answer in one line (at most 500 characters); it is written into proposal.md as a verbatim human decision. Answer __defer__ to leave it open and carry the question into the epic unresolved." ]; then
    pass "mixed SPECIFY_DECISION: the outcome question text is unchanged"
  else
    fail "mixed SPECIFY_DECISION: the outcome question text is unchanged" "$t"
  fi

  # An earlier round's answer for the key is a hint only.
  mkdir -p "$(planner_initiative_dir "$INIT")/artifacts/answers"
  jq -n '{schema_version: 1, round: 1, answers: [
    {id: "param-export.link_ttl", binding: "specify-param:export.link_ttl", value: "7 days", role: "client"}]}' \
    >"$(planner_initiative_dir "$INIT")/artifacts/answers/round-1.json"
  t=$(qtext "$(planner_stop_describe_json "$INIT")" param-export.link_ttl)
  if in_order "$t" 'what should Export link lifetime be?)' 'Previously answered in round 1: "7 days".' '(Export link lifetime;'; then
    pass "parameter question: an earlier round's answer is shown as a hint"
  else
    fail "parameter question: an earlier round's answer is shown as a hint" "$t"
  fi

  # Legacy initiative: the same table asks nothing.
  param_fixture pp-legacy legacy
  got=$(planner_stop_describe_json "$INIT" | jq -r '[.questions[].binding] | join(" ")')
  if [ "$got" = "specify-answer:O1" ]; then
    pass "legacy initiative: a hand-written ## Parameters table asks nothing"
  else
    fail "legacy initiative: a hand-written ## Parameters table asks nothing" "$got"
  fi

  # Second stop: position Crosscheck, contract initiative.
  param_fixture pp-cc
  _halt_done "$INIT" Review Consensus
  m=$(planner_stop_describe_json "$INIT")
  if [ "$(echo "$m" | jq -r '.reason + " " + (.questions | length | tostring)')" = "SPECIFY_DECISION 4" ]; then
    pass "Crosscheck position: open items report SPECIFY_DECISION"
  else
    fail "Crosscheck position: open items report SPECIFY_DECISION" "$(echo "$m" | jq -c '{reason, n: (.questions | length)}')"
  fi
  # A failed Crosscheck run on record still reports the decision first.
  planner_state_write "$INIT" Crosscheck check start "x"
  planner_state_write "$INIT" META crosscheck fail "SIGNALS_UNIFORM a.md b.md share a Signals block"
  planner_state_write "$INIT" Crosscheck check fail "1 blocking"
  if [ "$(reason_of "$INIT")" = "SPECIFY_DECISION" ]; then
    pass "Crosscheck position: SPECIFY_DECISION is reported ahead of CROSSCHECK_BLOCKED"
  else
    fail "Crosscheck position: SPECIFY_DECISION is reported ahead of CROSSCHECK_BLOCKED" "$(reason_of "$INIT")"
  fi
  printf '# Consensus\n\n## Readiness\nblocked — no.\n' >"$(planner_initiative_dir "$INIT")/artifacts/consensus.md"
  if [ "$(reason_of "$INIT")" = "CONSENSUS_BLOCKED" ]; then
    pass "Crosscheck position: consensus readiness is checked before the second stop"
  else
    fail "Crosscheck position: consensus readiness is checked before the second stop" "$(reason_of "$INIT")"
  fi

  param_fixture pp-cc-legacy legacy
  _halt_done "$INIT" Review Consensus
  if [ "$(reason_of "$INIT")" = "RUNNING" ]; then
    pass "Crosscheck position: a legacy initiative never stops there"
  else
    fail "Crosscheck position: a legacy initiative never stops there" "$(reason_of "$INIT")"
  fi

  # PARAM_LITERAL: no blanket accept; one param-literals note instead.
  fresh_root pp-literal
  planner_state_init "$INIT" "idea" >/dev/null
  planner_state_write "$INIT" META contract start specify-parameters-v1
  _halt_done "$INIT" Appraisal Discovery Architecture Specify Review Consensus
  printf '# Proposal\n\n## Parameters\n\nNone.\n' >"$(planner_initiative_dir "$INIT")/artifacts/proposal.md"
  planner_state_write "$INIT" Crosscheck check start "x"
  planner_state_write "$INIT" META crosscheck fail "PARAM_LITERAL export-link.md: \"30 seconds\" (time:30000) in Acceptance Criteria is not declared in ## Parameters — resume ${INIT} --accept PARAM_LITERAL@export-link:\"30 seconds\""
  planner_state_write "$INIT" META crosscheck fail "PARAM_LITERAL export-link.md: \"2 GB\" (size:2147483648) in Expected is not declared in ## Parameters — resume ${INIT} --accept PARAM_LITERAL@export-link:\"2 GB\""
  planner_state_write "$INIT" META crosscheck fail "SIGNALS_UNIFORM a.md b.md share a Signals block"
  planner_state_write "$INIT" Crosscheck check fail "3 blocking"
  m=$(planner_stop_describe_json "$INIT")
  got=$(echo "$m" | jq -r '.reason + " " + ([.questions[] | .id + "=" + .binding] | join(" "))')
  t=$(qtext "$m" param-literals)
  if [ "$got" = "CROSSCHECK_BLOCKED param-literals=note accept-SIGNALS_UNIFORM=flag:accept:SIGNALS_UNIFORM" ] &&
    in_order "$t" 'export-link "30 seconds"' 'export-link "2 GB"' "resume ${INIT} --accept PARAM_LITERAL@<slug>:\"<literal>\""; then
    pass "PARAM_LITERAL: a param-literals note naming each literal and the per-literal command, no flag:accept:PARAM_LITERAL"
  else
    fail "PARAM_LITERAL: a param-literals note naming each literal and the per-literal command, no flag:accept:PARAM_LITERAL" "$got / $t"
  fi
  if [ "$(qtext "$m" accept-SIGNALS_UNIFORM)" = "Crosscheck blocking finding SIGNALS_UNIFORM (1x): a.md b.md share a Signals block — Accept it as genuine and expected? Answer with the reason, or __skip__ to fix the artifacts instead." ]; then
    pass "PARAM_LITERAL: other codes' accept questions are unchanged"
  else
    fail "PARAM_LITERAL: other codes' accept questions are unchanged" "$(qtext "$m" accept-SIGNALS_UNIFORM)"
  fi
  planner_stop_describe "$INIT" >"${WORK}/pl.hold"
  if [ "$(bash "$HOLD_PARSER" --phase PLANNER --return-file "${WORK}/pl.hold" 2>&1 | jq -r '.parse_status')" = "ok" ]; then
    pass "PARAM_LITERAL: block parses"
  else
    fail "PARAM_LITERAL: block parses" "$(cat "${WORK}/pl.hold")"
  fi
fi

# Per-instance accept table (planner-crosscheck-ownership D10): a listed code
# never gets a flag:accept:<CODE> question. FAKE_INSTANCE is test-only and has
# no note function, so it gets no question at all; the other code keeps its own.
declare -f planner_crosscheck_instance_field >/dev/null 2>&1 ||
  source "${LIB_DIR}/planner-crosscheck.sh"
if ! declare -f planner_crosscheck_instance_field >/dev/null 2>&1; then
  fail "planner_crosscheck_instance_field missing" "not defined"
else
  PLANNER_CROSSCHECK_INSTANCE_CODES="${PLANNER_CROSSCHECK_INSTANCE_CODES} FAKE_INSTANCE::::"
  fresh_root fake-instance
  planner_state_init "$INIT" "idea" >/dev/null
  _halt_done "$INIT" Appraisal Discovery Architecture Specify Review Consensus
  planner_state_write "$INIT" Crosscheck check start "x"
  planner_state_write "$INIT" META crosscheck fail "FAKE_INSTANCE alpha is wrong — resume ${INIT} --accept FAKE_INSTANCE@alpha:\"<reason>\""
  planner_state_write "$INIT" META crosscheck fail "SIGNALS_UNIFORM a.md b.md share a Signals block"
  planner_state_write "$INIT" Crosscheck check fail "2 blocking"
  got=$(planner_stop_describe_json "$INIT" | jq -r '.reason + " " + ([.questions[] | .id + "=" + .binding] | join(" "))')
  if [ "$got" = "CROSSCHECK_BLOCKED accept-SIGNALS_UNIFORM=flag:accept:SIGNALS_UNIFORM" ]; then
    pass "instance table: a listed code gets no flag:accept question"
  else
    fail "instance table: a listed code gets no flag:accept question" "$got"
  fi
  PLANNER_CROSSCHECK_INSTANCE_CODES="${PLANNER_CROSSCHECK_INSTANCE_CODES% FAKE_INSTANCE:*}"
fi

# CREATE_GATE output, captured before SPECIFY_DECISION was added (L5): the
# new optional kind/audience arguments must not move a byte.
fresh_root create-bytes
halt_fixture_init create-gate-stop "$INIT" >/dev/null
cat >"${WORK}/create-before.hold" <<HOLD
=== HUMAN_HOLD ===
SCHEMA_VERSION: 2
PHASE: PLANNER
REASON: CREATE_GATE
BLOCKS: artifacts/specs/
ROUND: 1
KIND: approval
AUDIENCE: operator
QUESTION_1: Planning for ${INIT} reached the create gate: Crosscheck passed and nothing is in Linear yet. Create the epic and its tickets in Linear?
QUESTION_1_ID: create
QUESTION_1_OPTIONS: yes|no
QUESTION_1_DEFAULT: no
QUESTION_1_BINDING: flag:create
=== END HUMAN_HOLD ===
HOLD
if cmp -s "${WORK}/create-before.hold" <(planner_stop_describe "$INIT") &&
  [ "$(planner_stop_describe_json "$INIT")" = '{"reason":"CREATE_GATE","terminal":false,"phase":"PLANNER","kind":"approval","audience":"operator","round":1,"blocks":"artifacts/specs/","questions":[{"id":"create","text":"Planning for '"$INIT"' reached the create gate: Crosscheck passed and nothing is in Linear yet. Create the epic and its tickets in Linear?","binding":"flag:create","options":["yes","no"],"default":"no"}]}' ]; then
  pass "CREATE_GATE: block and model byte-identical to the pre-change capture"
else
  fail "CREATE_GATE: block and model byte-identical to the pre-change capture" "$(planner_stop_describe "$INIT" | diff "${WORK}/create-before.hold" - | head -5)"
fi

# ── CLI ────────────────────────────────────────────────────────────────────

echo "--- CLI ---"

if [ "$(bash "${LIB_DIR}/planner-stop-describe.sh" "$INIT" | head -1)" = "=== HUMAN_HOLD ===" ] &&
  bash "${LIB_DIR}/planner-stop-describe.sh" "$INIT" --json | jq -e '.reason == "CREATE_GATE"' >/dev/null; then
  pass "CLI prints the block, and the model with --json"
else
  fail "CLI prints the block, and the model with --json" "unexpected CLI output"
fi

if ! bash "${LIB_DIR}/planner-stop-describe.sh" "INIT-does-not-exist" >/dev/null 2>&1; then
  pass "CLI fails for an initiative with no state log"
else
  fail "CLI fails for an initiative with no state log" "exit 0"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
