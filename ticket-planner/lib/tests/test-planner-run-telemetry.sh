#!/usr/bin/env bash
# test-planner-run-telemetry.sh — planner run telemetry (GitHub #631).
#
# Pins:
#   1. A fixture subagent transcript yields the expected token record (usage
#      counted once per message id, torn lines skipped, window filter).
#   2. state.log → phase attempts (multi-step phases, retries, halts, the
#      DraftReadiness pseudo-phase absorbing a Crosscheck re-run).
#   3. A halted run still writes its `planner_run` summary through the Stop
#      hook, with phase records, tokens, and UNMEASURED (null) where no
#      transcript exists; a run never closed by its hook is closed by the
#      next begin.
#   4. ticket-auto's runs.jsonl readers ignore the new kinds.
#   5. planner-run-report.sh prints the expected table and Timing/Cost lines.
#
# Run: bash ticket-planner/lib/tests/test-planner-run-telemetry.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK="${LIB_DIR}/../hooks/planner-telemetry-stop.sh"
FIX="${SCRIPT_DIR}/fixtures/telemetry"
TAP_LIB="${LIB_DIR}/../../ticket-auto-pipeline/lib"
FC_LIB="${LIB_DIR}/../../fleet-controller/lib"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
export REPOS_ROOT="${WORK}/repos"
export PLANNER_TRANSCRIPT_ROOT="${WORK}/projects"
export PLANNER_TELEMETRY_STATE_DIR="${WORK}/state"
export CLAUDE_CODE_SESSION_ID="sess-1"
mkdir -p "$HOME"

PASS=0
FAIL=0
_pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
_fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}
_eq() {
  if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1 (got '$2', want '$3')"; fi
}

# shellcheck source=../planner-run-telemetry.sh
source "${LIB_DIR}/planner-run-telemetry.sh"

INIT="INIT-tel1"
IDIR="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
RUNS="${IDIR}/telemetry/runs.jsonl"
SUB="${PLANNER_TRANSCRIPT_ROOT}/-proj/sess-1/subagents"

setup() {
  rm -rf "$REPOS_ROOT" "$PLANNER_TRANSCRIPT_ROOT" "$PLANNER_TELEMETRY_STATE_DIR"
  mkdir -p "$IDIR" "$SUB"
  cp "$FIX/state-halted.log" "$IDIR/state.log"
  cp "$FIX/subagent-appraisal.jsonl" "$SUB/agent-a1.jsonl"
  cp "$FIX/subagent-appraisal.meta.json" "$SUB/agent-a1.meta.json"
  cp "$FIX/session-main.jsonl" "${PLANNER_TRANSCRIPT_ROOT}/-proj/sess-1.jsonl"
}

echo "=== 1. transcript usage ==="
u=$(planner_transcript_usage "$FIX/subagent-appraisal.jsonl")
_eq "fixture token record" "$(echo "$u" | jq -c '{input, output, cache_read, cache_create, messages, model}')" \
  '{"input":12,"output":12,"cache_read":150,"cache_create":20,"messages":2,"model":"claude-opus-5-5"}'
_eq "transcript span" "$(echo "$u" | jq -r '"\(.first_ts) \(.last_ts)"')" "2026-11-01T10:00:02Z 2026-11-01T10:01:04Z"
u=$(planner_transcript_usage "$FIX/session-main.jsonl" 2026-11-01T10:00:00Z 2026-11-01T10:04:00Z)
_eq "window filter" "$(echo "$u" | jq -c '[.input, .output, .cache_read, .cache_create]')" '[11,22,33,44]'
_eq "no usage in window -> null" "$(planner_transcript_usage "$FIX/session-main.jsonl" 2030-01-01T00:00:00Z)" "null"
_eq "missing transcript -> null" "$(planner_transcript_usage "$WORK/nope.jsonl")" "null"

echo "=== 2. attempts from state.log ==="
setup
_eq "halted log attempts" "$(planner_telemetry_attempts "$INIT" | cut -f1,2,5,6,8 | tr '\t' ' ' | paste -sd ';')" \
  "Appraisal 1 done - 1;Discovery 1 done - 1;Crosscheck 1 halt CROSSCHECK_BLOCKED 1"
cat >"$IDIR/state.log" <<'EOF'
2026-11-01T10:00:00Z|EpicGen|create|start|x
2026-11-01T10:00:10Z|EpicGen|create|done|EPIC_ID=E-1
2026-11-01T10:00:11Z|EpicGen|branch-directive|start|x
2026-11-01T10:00:20Z|EpicGen|branch-directive|done|x
2026-11-01T10:00:30Z|META|create-authorized|done|x
2026-11-01T10:01:00Z|Specify|synthesize|start|x
2026-11-01T10:02:00Z|Specify|synthesize|fail|x
2026-11-01T10:03:00Z|Specify|synthesize|start|x
2026-11-01T10:04:00Z|Specify|synthesize|done|x
2026-11-01T10:05:00Z|META|draft-readiness|start|x
2026-11-01T10:05:30Z|META|draft-revise|start|slug-a round=1
2026-11-01T10:06:00Z|Crosscheck|check|start|re-run
2026-11-01T10:06:05Z|Crosscheck|check|done|clean
2026-11-01T10:06:10Z|META|draft-revise|start|slug-a round=2
2026-11-01T10:07:00Z|META|draft-readiness|done|blocked 1/2
2026-11-01T10:08:00Z|META|refinement|step|scan
2026-11-01T10:09:00Z|META|refinement-gate|fail|1 not ready
2026-11-01T10:10:00Z|META|refinement|step|scan
EOF
_eq "multi-step, retry, absorbed re-run, halts, open tail" \
  "$(planner_telemetry_attempts "$INIT" | cut -f1,2,4,5,6,7,8 | tr '\t' ' ' | paste -sd ';')" \
  "EpicGen 1 2026-11-01T10:00:20Z done - 0 1;Specify 1 2026-11-01T10:02:00Z fail - 0 1;Specify 2 2026-11-01T10:04:00Z done - 0 1;DraftReadiness 1 2026-11-01T10:07:00Z halt DRAFT_NOT_READY 2 1;Refinement 1 2026-11-01T10:09:00Z halt REFINEMENT_HALT 0 1;Refinement 2 2026-11-01T10:10:00Z open - 0 0"

echo "=== 3. halted run writes its summary (Stop hook) ==="
setup
out=$(PLANNER_TELEMETRY_NOW=2026-11-01T10:00:00Z planner_telemetry_begin "$INIT")
case "$out" in PLANNER_RUN_ID=planner-INIT-tel1-*) _pass "begin prints the run id" ;; *) _fail "begin output: $out" ;; esac
_eq "begin is idempotent in one session" "$(PLANNER_TELEMETRY_NOW=2026-11-01T10:00:09Z planner_telemetry_begin "$INIT")" "$out"
[ -f "${PLANNER_TELEMETRY_STATE_DIR}/sessions/sess-1" ] && _pass "session marker written" || _fail "session marker missing"
echo '{"session_id":"sess-1","hook_event_name":"Stop"}' | PLANNER_TELEMETRY_NOW=2026-11-01T10:04:00Z bash "$HOOK"
_eq "hook exit 0" "$?" "0"
[ -f "${PLANNER_TELEMETRY_STATE_DIR}/sessions/sess-1" ] && _fail "marker not removed" || _pass "marker removed"
[ -f "$IDIR/telemetry/open-run.json" ] && _fail "run still open" || _pass "run closed"
ph() { jq -c --arg p "$1" 'select(.kind == "planner_phase" and .phase == $p)' "$RUNS"; }
_eq "Appraisal record" "$(ph Appraisal | jq -c '{attempt, wall_ms, outcome, agents, agent_types, tokens, model}')" \
  '{"attempt":1,"wall_ms":60000,"outcome":"done","agents":1,"agent_types":["general-purpose"],"tokens":{"input":12,"output":12,"cache_read":150,"cache_create":20},"model":"claude-opus-5-5"}'
_eq "Discovery tokens null (no transcript)" "$(ph Discovery | jq -c '{agents, tokens}')" '{"agents":0,"tokens":null}'
_eq "Crosscheck halt" "$(ph Crosscheck | jq -c '{outcome, halt_code, wall_ms}')" '{"outcome":"halt","halt_code":"CROSSCHECK_BLOCKED","wall_ms":5000}'
RUN_ID=${out#PLANNER_RUN_ID=}
_eq "phase records carry the run id" "$(jq -r 'select(.kind == "planner_phase") | .run_id' "$RUNS" | sort -u)" "$RUN_ID"
run=$(jq -c 'select(.kind == "planner_run")' "$RUNS")
_eq "one run summary" "$(echo "$run" | wc -l | tr -d ' ')" "1"
_eq "run summary" "$(echo "$run" | jq -c '{started_at, ended_at, wall_ms, furthest_phase, phase_attempts, draft_revise_rounds, human_answer_rounds, unmeasured_phases, closed_by}')" \
  '{"started_at":"2026-11-01T10:00:00Z","ended_at":"2026-11-01T10:04:00Z","wall_ms":240000,"furthest_phase":"Crosscheck","phase_attempts":3,"draft_revise_rounds":0,"human_answer_rounds":0,"unmeasured_phases":["Discovery","Crosscheck"],"closed_by":"stop-hook"}'
_eq "halt recorded" "$(echo "$run" | jq -r '"\(.stop_reason) \(.halt_code)"')" "CROSSCHECK_BLOCKED CROSSCHECK_BLOCKED"
_eq "run tokens (phases + orchestrator window)" "$(echo "$run" | jq -c '.tokens')" \
  '{"phases":{"input":12,"output":12,"cache_read":150,"cache_create":20},"orchestrator":{"input":11,"output":22,"cache_read":33,"cache_create":44,"messages":2,"model":"claude-opus-5-5","first_ts":"2026-11-01T09:59:58Z","last_ts":"2026-11-01T10:09:00Z"},"total":{"input":23,"output":34,"cache_read":183,"cache_create":64}}'
before=$(wc -l <"$RUNS")
planner_telemetry_sync "$INIT"
_eq "sync is idempotent" "$(wc -l <"$RUNS")" "$before"
_eq "finish with no open run is a no-op" "$(
  planner_telemetry_finish "$INIT" manual
  wc -l <"$RUNS"
)" "$before"

echo "=== 3b. a run the Stop hook never closed is closed by the next begin ==="
PLANNER_TELEMETRY_NOW=2026-11-01T11:00:00Z planner_telemetry_begin "$INIT" >/dev/null
printf '%s\n' "2026-11-01T11:00:05Z|Crosscheck|check|start|resume" "2026-11-01T11:00:09Z|Crosscheck|check|done|clean" >>"$IDIR/state.log"
CLAUDE_CODE_SESSION_ID=sess-2 PLANNER_TELEMETRY_NOW=2026-11-01T12:00:00Z planner_telemetry_begin "$INIT" >/dev/null
last=$(jq -c 'select(.kind == "planner_run")' "$RUNS" | tail -1)
_eq "closed by next-begin at its last state.log line" "$(echo "$last" | jq -c '{closed_by, ended_at, furthest_phase}')" \
  '{"closed_by":"next-begin","ended_at":"2026-11-01T11:00:09Z","furthest_phase":"Crosscheck"}'
_eq "new run open for the new session" "$(jq -r '.session_id' "$IDIR/telemetry/open-run.json")" "sess-2"
_eq "both sessions registered" "$(paste -sd, "$IDIR/telemetry/sessions")" "sess-1,sess-2"
_eq "run ids are distinct" "$(jq -r 'select(.kind == "planner_run") | .run_id' "$RUNS" | sort -u | wc -l | tr -d ' ')" "2"

echo "=== 4. ticket-auto runs.jsonl readers ignore the new kinds ==="
WS="$WORK/ws"
mkdir -p "$WS"
TA_LINES='{"kind":"run","tid":"T-1","run_id":"T-1-r1","pr":{"pr":42,"url":null,"repo":"acme/repo"},"ended_at":"2026-01-01T00:00:09Z"}
{"kind":"merge","tid":"T-1","pr":42,"repo":"acme/repo","state":"merged","base":"develop"}
{"kind":"cost","tid":"T-1","run_id":"T-1-r1","gen":1,"phase":"IMPLEMENT","usd":1.5}'
printf '%s\n' "$TA_LINES" >"$WS/clean.jsonl"
# Interleave every planner/grill kind, including ones carrying tid/pr-shaped
# fields, so a reader that forgot its kind filter would trip.
{
  jq -c '. + {tid: "T-1", pr: 42, state: "open"}' "$RUNS"
  printf '%s\n' "$TA_LINES"
  echo '{"kind":"grill_round","tid":"T-1","pr":42,"state":"closed","round":1}'
  echo '{"kind":"grill_session","tid":"T-1","run_id":"T-1-r1","usd":9,"status":"sealed"}'
} >"$WS/runs.jsonl"
for k in planner_phase planner_run grill_round grill_session; do
  grep -q "\"kind\":\"$k\"" "$WS/runs.jsonl" && _pass "mixed file holds $k" || _fail "mixed file lacks $k"
done
(
  source "$TAP_LIB/merge-poll.sh"
  a=$(merge_poll_candidates "$WS/clean.jsonl")
  b=$(merge_poll_candidates "$WS/runs.jsonl")
  [ "$a" = "$b" ] && echo same || echo "differ: $a vs $b"
) | {
  read -r r
  _eq "merge-poll.sh merge_poll_candidates" "$r" "same"
}
printf '%s\n' '2026-01-01T00:00:01Z|META|pr-created|info|{"pr":42,"url":"https://github.com/acme/repo/pull/42","repo":"acme/repo"}' \
  '2026-01-01T00:00:09Z|META|outcome|info|completed: STEP_6' >"$WS/T-1-pipeline.log"
_eq "manifest-read.sh ticket_pipeline_merge_state" \
  "$(bash -c 'source "$1/manifest-read.sh"; ticket_pipeline_merge_state T-1 "$2"' _ "$TAP_LIB" "$WS")" "merged"
_eq "pipeline-finalize.sh run-event lookup (select kind run)" \
  "$(jq -c 'select(.kind == "run" and .run_id == "T-1-r1") | .tid' "$WS/runs.jsonl")" '"T-1"'
if [ -f "$FC_LIB/run-score-export.sh" ]; then
  _eq "run-score-export.sh cost lookup" \
    "$(bash -c 'source "$1/run-score-export.sh" >/dev/null 2>&1; _score_export_cost_events_sum "$2" T-1-r1' _ "$FC_LIB" "$WS/runs.jsonl")" "1.5"
fi
if command -v python3 >/dev/null 2>&1 && [ -f "$LIB_DIR/../../fleet-controller/fleetd/otel.py" ]; then
  _eq "fleetd otel cost index" "$(
    python3 - "$WS/runs.jsonl" <<'PY'
import json, sys
index = {}
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get('kind') != 'cost':   # the same filter otel.py's _refresh_cost_index applies
        continue
    index[(e.get('tid'), e.get('gen'), e.get('phase'))] = e.get('usd')
print(index)
PY
  )" "{('T-1', 1, 'IMPLEMENT'): 1.5}"
fi

echo "=== 5. read-out ==="
report=$(bash "${LIB_DIR}/planner-run-report.sh" "$INIT" --no-sync)
_eq "report exit 0" "$?" "0"
if [ -n "${SHOW_REPORT:-}" ]; then printf '%s\n' "$report"; fi
for want in \
  "| Phase | Attempt | Started (UTC) | Wall-clock | Outcome | Agents | Input | Output | Cache read | Cache write |" \
  "| Appraisal | 1 | 2026-11-01T10:00:05Z | 1m 0s | done | 1 | 12 | 12 | 150 | 20 |" \
  "| Discovery | 1 | 2026-11-01T10:01:10Z | 2m 0s | done | 0 | UNMEASURED | | | |" \
  "| Crosscheck | 1 | 2026-11-01T10:03:20Z | 5s | halt CROSSCHECK_BLOCKED | 0 | n/a (bash) | | | |" \
  "Cost: tokens in 23 / out 34 / cache read 183 / cache write 64 (phase agents + orchestrator); UNMEASURED: Discovery"; do
  if grep -Fxq -- "$want" <<<"$report"; then _pass "report line: ${want:0:60}"; else _fail "report lacks: $want"; fi
done
grep -q '^Timing: 4m 9s wall-clock across 2 run(s); phases ' <<<"$report" && _pass "Timing line" || _fail "Timing line: $(printf '%s\n' "$report" | grep '^Timing')"
bash "${LIB_DIR}/planner-run-report.sh" INIT-none >/dev/null 2>&1
_eq "no telemetry -> exit 1" "$?" "1"

echo "=== 6. hook ignores sessions it does not know ==="
echo '{"session_id":"../etc"}' | bash "$HOOK"
_eq "bad session id -> exit 0" "$?" "0"
echo 'not json' | bash "$HOOK"
_eq "bad payload -> exit 0" "$?" "0"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
