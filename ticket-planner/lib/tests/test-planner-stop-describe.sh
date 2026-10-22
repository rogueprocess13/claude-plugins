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
