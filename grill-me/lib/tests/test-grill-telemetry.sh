#!/usr/bin/env bash
# ── test-grill-telemetry.sh ───────────────────────────────────────────────────
# grill-me run telemetry (GitHub #631): one grill_round record per scoring and
# one grill_session record per invocation, written by the Stop hook — sealed or
# waiting for answers — with tokens from a fixture session transcript (null,
# never estimated, when there is none). grill_score's stdout is unchanged.
# ───────────────────────────────────────────────────────────────────────────────

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PROFILE="$LIB_DIR/../profiles/product-idea.json"
HOOK="$LIB_DIR/../hooks/grill-telemetry-stop.sh"
FIX="$TEST_DIR/fixtures/telemetry-session.jsonl"

source "$LIB_DIR/grill-score.sh"
source "$LIB_DIR/grill-render.sh"
source "$LIB_DIR/grill-seal.sh"
set +eu

PASS=0
FAIL=0
pass() {
  PASS=$((PASS + 1))
  echo "  PASS $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL $1: $2"
}
eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2', want '$3'"; fi
}

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
export GRILL_TRANSCRIPT_ROOT="$SCRATCH/projects"
export GRILL_TELEMETRY_STATE_DIR="$SCRATCH/state"
mkdir -p "$GRILL_TRANSCRIPT_ROOT/-proj"
cp "$FIX" "$GRILL_TRANSCRIPT_ROOT/-proj/g-sess.jsonl"

assessment() {
  jq -n --argjson round "$1" '{
    profile: "product-idea", subject: "CSV export", round: $round,
    dimensions: [
      {id:"objective",status:"present",evidence:"Export invoices",gap:""},
      {id:"users_problem",status:"missing",evidence:"",gap:"Who exports"},
      {id:"success_criteria",status:"present",evidence:"Finance reconciles monthly",gap:""},
      {id:"scope",status:"present",evidence:"Invoices only",gap:""},
      {id:"acceptance_criteria",status:"present",evidence:"One row per invoice",gap:""},
      {id:"constraints",status:"present",evidence:"Reporting service",gap:""},
      {id:"dependencies",status:"present",evidence:"Reporting service",gap:""},
      {id:"risks",status:"present",evidence:"Timeouts",gap:""},
      {id:"edge_cases",status:"present",evidence:"Empty month",gap:""},
      {id:"test_data",status:"present",evidence:"Synthetic invoices",gap:""},
      {id:"assumptions",status:"present",evidence:"Dashboard access",gap:""}],
    flags: {}, assumptions: [], risks: [],
    questions: [{text:"Who exports?",dimension:"users_problem",impact:"high",why:"Defines done"}]}'
}

echo "=== outside a Claude session: nothing is written ==="
WD0="$SCRATCH/wd0"
mkdir -p "$WD0"
assessment 1 >"$WD0/assessment.json"
plain=$(env -u CLAUDE_CODE_SESSION_ID bash -c 'source "$1/grill-score.sh"; grill_score "$2/assessment.json" "$3" "$2/result.json"' _ "$LIB_DIR" "$WD0" "$PROFILE" | grep '^GRILL_')
[ -e "$WD0/telemetry" ] && fail "no session" "telemetry dir created" || pass "no telemetry without a session id"

echo "=== interactive session: two rounds, sealed ==="
WD="$SCRATCH/wd1"
mkdir -p "$WD"
export CLAUDE_CODE_SESSION_ID="g-sess"
assessment 1 >"$WD/assessment.json"
with=$(GRILL_TELEMETRY_NOW=2026-11-01T10:01:00Z grill_score "$WD/assessment.json" "$PROFILE" "$WD/result.json" 2>/dev/null | grep '^GRILL_')
eq "grill_score stdout unchanged by telemetry" "$with" "$plain"
RUNS="$WD/telemetry/runs.jsonl"
r1=$(jq -c 'select(.kind == "grill_round" and .round == 1)' "$RUNS")
eq "round 1 record" "$(echo "$r1" | jq -c '{invocation, started_at, ended_at, wall_ms, human_wait_ms, tokens, model}')" \
  '{"invocation":1,"started_at":"2026-11-01T10:00:00Z","ended_at":"2026-11-01T10:01:00Z","wall_ms":60000,"human_wait_ms":0,"tokens":{"input":100,"output":10,"cache_read":1000,"cache_create":50},"model":"claude-opus-5-5"}'
eq "round 1 carries the score" "$(echo "$r1" | jq -c '[.readiness, .recommendation, .questions]')" \
  "$(jq -c '[.readiness, .recommendation, (.questions | length)]' "$WD/result.json")"
[ -f "$GRILL_TELEMETRY_STATE_DIR/sessions/g-sess" ] && pass "session marker written" || fail "marker" "missing"

assessment 2 | jq '.dimensions[1].status = "present" | .dimensions[1].evidence = "Finance" | .questions = []' >"$WD/assessment.json"
GRILL_TELEMETRY_NOW=2026-11-01T10:04:00Z grill_score "$WD/assessment.json" "$PROFILE" "$WD/result.json" >/dev/null 2>&1
r2=$(jq -c 'select(.kind == "grill_round" and .round == 2)' "$RUNS")
eq "round 2: message counted once, answer wait measured" "$(echo "$r2" | jq -c '{started_at, wall_ms, human_wait_ms, tokens}')" \
  '{"started_at":"2026-11-01T10:01:00Z","wall_ms":180000,"human_wait_ms":120000,"tokens":{"input":12,"output":12,"cache_read":12,"cache_create":12}}'

DOC="$SCRATCH/intent.md"
grill_render "$WD/result.json" "$WD/assessment.json" "$DOC" >/dev/null 2>&1
grill_seal_generate "$DOC" product-idea "$(jq -r .readiness "$WD/result.json")" "$(jq -r .recommendation "$WD/result.json")" 2 2026-11-01T10:04:40Z >/dev/null 2>&1
eq "seal noted on the open session" "$(jq -r '.sealed' "$WD/telemetry/open.json")" "$DOC"

echo '{"session_id":"g-sess","hook_event_name":"Stop"}' | GRILL_TELEMETRY_NOW=2026-11-01T10:05:00Z bash "$HOOK"
eq "hook exit 0" "$?" "0"
[ -f "$GRILL_TELEMETRY_STATE_DIR/sessions/g-sess" ] && fail "marker" "not removed" || pass "marker removed"
s=$(jq -c 'select(.kind == "grill_session")' "$RUNS")
eq "session record" "$(echo "$s" | jq -c '{invocation, status, rounds, rounds_this_invocation, wall_ms, human_wait_ms, tokens, closed_by}')" \
  '{"invocation":1,"status":"sealed","rounds":2,"rounds_this_invocation":2,"wall_ms":300000,"human_wait_ms":120000,"tokens":{"input":113,"output":23,"cache_read":1013,"cache_create":63},"closed_by":"stop-hook"}'
eq "session verdict and score" "$(echo "$s" | jq -c '[.verdict, .score]')" \
  "$(jq -c '[.recommendation, .readiness]' "$WD/result.json")"

echo "=== headless round with no transcript: tokens null, waiting for answers ==="
WD2="$SCRATCH/wd2"
mkdir -p "$WD2"
assessment 1 >"$WD2/assessment.json"
CLAUDE_CODE_SESSION_ID=g-none GRILL_TELEMETRY_NOW=2026-11-02T09:00:00Z \
  grill_score "$WD2/assessment.json" "$PROFILE" "$WD2/result.json" >/dev/null 2>&1
echo '{"schema_version":1,"status":"awaiting-answers","round":1}' >"$WD2/state.json"
echo '{"session_id":"g-none"}' | GRILL_TELEMETRY_NOW=2026-11-02T09:00:30Z bash "$HOOK"
eq "round tokens null" "$(jq -c 'select(.kind == "grill_round") | .tokens' "$WD2/telemetry/runs.jsonl")" "null"
eq "halted session still recorded" "$(jq -c 'select(.kind == "grill_session") | {status, tokens, rounds}' "$WD2/telemetry/runs.jsonl")" \
  '{"status":"awaiting-answers","tokens":null,"rounds":1}'

echo "=== read-out ==="
report=$(bash "$LIB_DIR/grill-telemetry.sh" report "$WD")
eq "report exit 0" "$?" "0"
echo "$report" | grep -Fq '| 1 | 2 | 3m 0s | 2m 0s |' && pass "round row" || fail "round row" "$report"
echo "$report" | grep -Fq '| 1 | sealed |' && pass "session row" || fail "session row" "$report"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
