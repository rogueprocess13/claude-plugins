#!/usr/bin/env bash
# test-run-score-export.sh — tests for lib/run-score-export.sh
# (run-score-export, langfuse-evidence-layer Phase 5).
#
# All tests stub `curl` via PATH — the same convention test-merge-poll.sh
# uses for `gh`. No network required.
# -u (nounset) intentionally omitted — see test-detect-resume.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TAP_LIB="$(cd "$LIB_DIR/../../ticket-auto-pipeline/lib" && pwd)"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_ws=""
_orig_path=""
_setup() {
  _ws=$(mktemp -d)
  mkdir -p "$_ws/bin" "$_ws/logs"
  _orig_path="$PATH"
  PATH="$_ws/bin:$PATH"
  export FLEET_SCORE_EXPORT_ENABLE=true
  export LANGFUSE_HOST="https://fake.langfuse.test"
  export LANGFUSE_PUBLIC_KEY="pk-test"
  export LANGFUSE_SECRET_KEY="sk-test"
}
_teardown() {
  PATH="$_orig_path"
  unset FLEET_SCORE_EXPORT_ENABLE LANGFUSE_HOST LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY
  rm -rf "$_ws" 2>/dev/null || true
}

# Records every curl invocation's -d payload, one JSON line per call, into
# $_ws/capture.jsonl. Always "succeeds" (echoes a minimal ok body) unless
# $_ws/curl-fail is present, which simulates an unreachable backend.
_stub_curl_capturing() {
  cat >"$_ws/bin/curl" <<'STUB'
#!/usr/bin/env bash
capture=""
CAPDIR="$(dirname "$0")/.."
if [ -f "$CAPDIR/curl-fail" ]; then
  exit 7
fi
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = "-d" ]; then
    echo "${args[$((i+1))]}" >> "$CAPDIR/capture.jsonl"
  fi
done
echo '{"id":"stubbed"}'
STUB
  chmod +x "$_ws/bin/curl"
}

_capture_count() {
  [ -f "$_ws/capture.jsonl" ] && wc -l <"$_ws/capture.jsonl" || echo 0
}

_capture_names() {
  [ -f "$_ws/capture.jsonl" ] || return 0
  jq -r '.name' "$_ws/capture.jsonl" 2>/dev/null
}

_capture_value_for() {
  local name="$1"
  [ -f "$_ws/capture.jsonl" ] || return 1
  jq -c --arg n "$name" 'select(.name == $n) | .value' "$_ws/capture.jsonl" 2>/dev/null | tail -1
}

_source_lib() {
  source "$LIB_DIR/run-score-export.sh"
}

_write_run_event() {
  local runs_file="$1" run_id="$2" tid="$3" extra="${4:-}"
  local base
  base=$(jq -nc --arg kind "run" --arg tid "$tid" --arg run_id "$run_id" \
    --arg started_at "2026-01-01T00:00:00Z" --arg ended_at "2026-01-01T00:10:00Z" \
    --arg ticket_created_at "2025-12-30T00:00:00Z" --arg outcome "completed: STEP_6" \
    '{kind:$kind, tid:$tid, run_id:$run_id, gen:null, trigger:"manual",
      versions:{}, models:["claude-sonnet-5"], complexity:"simple", type:"bug",
      planned:false, estimate:null, autonomy:"auto",
      ticket_created_at:$ticket_created_at, started_at:$started_at, ended_at:$ended_at,
      outcome:$outcome, exit_code:0, gate_held_at:null, resumed_after_hold_ms:null,
      verify_attempts:1, review_iterations:0, fix_rounds:0, reconcile_cycles:0,
      gate_stops:[], pr:null, merge_decision:null,
      tokens:{"in":1000,"out":500,"cache":0,"cache_read":0,"cache_write":0},
      phase_elapsed_ms:{}, human_hold_requested:false, human_hold_parse_status:null,
      observed_at:$ended_at}')
  if [ -n "$extra" ]; then
    base=$(echo "$base" | jq -c ". + ${extra}")
  fi
  echo "$base" >>"$runs_file"
}

# ── Enablement / fail-soft guards ────────────────────────────────────────────

test_no_credentials_means_no_op() {
  _setup
  unset LANGFUSE_SECRET_KEY
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  _write_run_event "$runs_file" "T-1-2026-01-01T00:00:00Z-1" "T-1"
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  [ "$(_capture_count)" -eq 0 ]
  ok=$?
  _teardown
  return $ok
}

test_feature_flag_off_means_no_op() {
  _setup
  export FLEET_SCORE_EXPORT_ENABLE=false
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  _write_run_event "$runs_file" "T-2-2026-01-01T00:00:00Z-1" "T-2"
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  [ "$(_capture_count)" -eq 0 ]
  ok=$?
  _teardown
  return $ok
}

test_missing_runs_file_is_a_clean_no_op() {
  _setup
  _stub_curl_capturing
  (_source_lib && run_score_export_sweep "$_ws/logs/nonexistent.jsonl")
  local rc=$?
  local ok
  [ "$rc" -eq 0 ] && [ "$(_capture_count)" -eq 0 ]
  ok=$?
  _teardown
  return $ok
}

# ── Basic run scoring ────────────────────────────────────────────────────────

test_a_completed_run_is_scored() {
  _setup
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  _write_run_event "$runs_file" "T-3-2026-01-01T00:00:00Z-1" "T-3"
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  [ "$(_capture_count)" -gt 0 ] &&
    _capture_names | grep -q '^outcome$' &&
    _capture_names | grep -q '^failure_class$' &&
    _capture_names | grep -q '^failure_phase$'
  ok=$?
  _teardown
  return $ok
}

test_a_clean_run_scores_none_none_for_class_and_phase() {
  _setup
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  local run_id="T-4-2026-01-01T00:00:00Z-1"
  _write_run_event "$runs_file" "$run_id" "T-4"
  cat >"$_ws/logs/T-4-pipeline.log" <<EOF
2026-01-01T00:00:00Z|META|run-id|info|{"run_id":"$run_id","gen":null}
2026-01-01T00:00:05Z|IMPLEMENT|implement|waiting|x
2026-01-01T00:00:10Z|IMPLEMENT|implement|done|ok
2026-01-01T00:10:00Z|META|outcome|info|completed: STEP_6
EOF
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  [ "$(_capture_value_for failure_class)" = '"none"' ] &&
    [ "$(_capture_value_for failure_phase)" = '"none"' ]
  ok=$?
  _teardown
  return $ok
}

test_a_run_with_no_cost_evidence_omits_the_cost_score() {
  _setup
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  local run_id="T-5-2026-01-01T00:00:00Z-1"
  _write_run_event "$runs_file" "$run_id" "T-5" '{"tokens":null}'
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  ! _capture_names | grep -q '^cost_usd$'
  ok=$?
  _teardown
  return $ok
}

test_envelope_cost_is_preferred_over_token_derived() {
  _setup
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  local run_id="T-6-2026-01-01T00:00:00Z-1"
  _write_run_event "$runs_file" "$run_id" "T-6"
  echo "$(jq -nc --arg rid "$run_id" '{kind:"cost", tid:"T-6", run_id:$rid, gen:1, phase:"IMPLEMENT", usd:1.5}')" >>"$runs_file"
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  [ "$(_capture_value_for cost_usd)" = "1.5" ] &&
    [ "$(_capture_value_for cost_source)" = '"envelope"' ]
  ok=$?
  _teardown
  return $ok
}

test_a_killed_run_with_tokens_but_no_cost_event_falls_back_to_tokens() {
  _setup
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  local run_id="T-7-2026-01-01T00:00:00Z-1"
  _write_run_event "$runs_file" "$run_id" "T-7"
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  _capture_names | grep -q '^cost_usd$' &&
    [ "$(_capture_value_for cost_source)" = '"tokens"' ]
  ok=$?
  _teardown
  return $ok
}

# ── Merge decision / first-pass / rollup ────────────────────────────────────

test_a_gated_ticket_is_not_a_first_pass_failure() {
  _setup
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  local run1="TCK-1-2026-01-01T00:00:00Z-1"
  local run2="TCK-1-2026-01-02T00:00:00Z-1"
  # First run: held at the gate.
  _write_run_event "$runs_file" "$run1" "TCK-1" '{"outcome":"held: gate","verify_attempts":0}'
  # Second run: merges cleanly with no verify retries.
  _write_run_event "$runs_file" "$run2" "TCK-1" \
    '{"pr":{"pr":7,"url":"https://github.com/acme/repo/pull/7","repo":"acme/repo"},"verify_attempts":1}'
  echo "$(jq -nc '{kind:"merge", tid:"TCK-1", pr:7, repo:"acme/repo", state:"merged", merged_at:"2026-01-03T00:00:00Z", merge_sha:"abc123"}')" >>"$runs_file"
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  [ "$(_capture_value_for ticket_runs)" = "2" ] &&
    [ "$(_capture_value_for ticket_first_pass_success)" = "true" ]
  ok=$?
  _teardown
  return $ok
}

test_ticket_cost_sums_every_run() {
  _setup
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  local run1="TCK-2-2026-01-01T00:00:00Z-1"
  local run2="TCK-2-2026-01-02T00:00:00Z-1"
  _write_run_event "$runs_file" "$run1" "TCK-2" '{"outcome":"held: gate"}'
  _write_run_event "$runs_file" "$run2" "TCK-2" \
    '{"pr":{"pr":8,"url":"https://github.com/acme/repo/pull/8","repo":"acme/repo"}}'
  echo "$(jq -nc --arg rid "$run1" '{kind:"cost", tid:"TCK-2", run_id:$rid, gen:1, phase:"IMPLEMENT", usd:1.0}')" >>"$runs_file"
  echo "$(jq -nc --arg rid "$run2" '{kind:"cost", tid:"TCK-2", run_id:$rid, gen:2, phase:"IMPLEMENT", usd:2.0}')" >>"$runs_file"
  echo "$(jq -nc '{kind:"merge", tid:"TCK-2", pr:8, repo:"acme/repo", state:"merged", merged_at:"2026-01-03T00:00:00Z", merge_sha:"def456"}')" >>"$runs_file"
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  # Compare numerically — the sweeper preserves full USD precision (e.g.
  # "3.000000"), it does not trim trailing zeros.
  awk -v v="$(_capture_value_for ticket_cost_total)" 'BEGIN { exit !(v == 3) }'
  ok=$?
  _teardown
  return $ok
}

test_a_merge_decision_arriving_later_ships_the_rollup_on_a_later_sweep() {
  _setup
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  local run_id="TCK-3-2026-01-01T00:00:00Z-1"
  _write_run_event "$runs_file" "$run_id" "TCK-3" \
    '{"pr":{"pr":9,"url":"https://github.com/acme/repo/pull/9","repo":"acme/repo"}}'
  (_source_lib && run_score_export_sweep "$runs_file")
  local first_count
  first_count=$(_capture_count)
  # No merge event yet — no rollup score this sweep.
  local no_rollup_yet
  ! _capture_names | grep -q '^ticket_first_pass_success$'
  no_rollup_yet=$?

  echo "$(jq -nc '{kind:"merge", tid:"TCK-3", pr:9, repo:"acme/repo", state:"merged", merged_at:"2026-01-03T00:00:00Z", merge_sha:"ghi789"}')" >>"$runs_file"
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  [ "$no_rollup_yet" -eq 0 ] &&
    [ "$(_capture_count)" -gt "$first_count" ] &&
    _capture_names | grep -q '^ticket_first_pass_success$'
  ok=$?
  _teardown
  return $ok
}

# ── Idempotency ──────────────────────────────────────────────────────────────

test_a_second_sweep_over_unchanged_evidence_ships_nothing_new() {
  _setup
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  _write_run_event "$runs_file" "T-8-2026-01-01T00:00:00Z-1" "T-8"
  (_source_lib && run_score_export_sweep "$runs_file")
  local first_count
  first_count=$(_capture_count)
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  [ "$(_capture_count)" -eq "$first_count" ]
  ok=$?
  _teardown
  return $ok
}

test_a_lost_cursor_reships_with_identical_score_identifiers() {
  _setup
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  _write_run_event "$runs_file" "T-9-2026-01-01T00:00:00Z-1" "T-9"
  (_source_lib && run_score_export_sweep "$runs_file")
  local first_ids
  first_ids=$(jq -r '.id' "$_ws/capture.jsonl" | sort)
  rm -f "$_ws/capture.jsonl"
  rm -f "$(dirname "$runs_file")/score-export-cursor.json"
  (_source_lib && run_score_export_sweep "$runs_file")
  local second_ids
  second_ids=$(jq -r '.id' "$_ws/capture.jsonl" | sort)
  local ok
  [ "$first_ids" = "$second_ids" ] && [ -n "$first_ids" ]
  ok=$?
  _teardown
  return $ok
}

# ── Fail-soft / content-free ─────────────────────────────────────────────────

test_an_unreachable_backend_warns_and_exits_zero() {
  _setup
  _stub_curl_capturing
  touch "$_ws/curl-fail"
  local runs_file="$_ws/logs/runs.jsonl"
  _write_run_event "$runs_file" "T-10-2026-01-01T00:00:00Z-1" "T-10"
  (_source_lib && run_score_export_sweep "$runs_file")
  local rc=$?
  [ "$rc" -eq 0 ]
}

test_a_malformed_record_is_skipped_not_fatal() {
  _setup
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  echo 'this is not json' >>"$runs_file"
  _write_run_event "$runs_file" "T-11-2026-01-01T00:00:00Z-1" "T-11"
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  [ "$(_capture_count)" -gt 0 ]
  ok=$?
  _teardown
  return $ok
}

test_no_content_bearing_fields_in_any_payload() {
  _setup
  _stub_curl_capturing
  local runs_file="$_ws/logs/runs.jsonl"
  _write_run_event "$runs_file" "T-12-2026-01-01T00:00:00Z-1" "T-12"
  (_source_lib && run_score_export_sweep "$runs_file")
  local ok
  ! grep -qiE '"(prompt|completion|tool_input|tool_output|body)"' "$_ws/capture.jsonl"
  ok=$?
  _teardown
  return $ok
}

_run "no credentials means no-op" test_no_credentials_means_no_op
_run "feature flag off means no-op" test_feature_flag_off_means_no_op
_run "missing runs file is a clean no-op" test_missing_runs_file_is_a_clean_no_op
_run "a completed run is scored" test_a_completed_run_is_scored
_run "a clean run scores none/none for class and phase" test_a_clean_run_scores_none_none_for_class_and_phase
_run "a run with no cost evidence omits the cost score" test_a_run_with_no_cost_evidence_omits_the_cost_score
_run "envelope cost is preferred over token-derived" test_envelope_cost_is_preferred_over_token_derived
_run "a killed run with tokens but no cost event falls back to tokens" test_a_killed_run_with_tokens_but_no_cost_event_falls_back_to_tokens
_run "a gated ticket is not a first-pass failure" test_a_gated_ticket_is_not_a_first_pass_failure
_run "ticket cost sums every run" test_ticket_cost_sums_every_run
_run "a merge decision arriving later ships the rollup on a later sweep" test_a_merge_decision_arriving_later_ships_the_rollup_on_a_later_sweep
_run "a second sweep over unchanged evidence ships nothing new" test_a_second_sweep_over_unchanged_evidence_ships_nothing_new
_run "a lost cursor re-ships with identical score identifiers" test_a_lost_cursor_reships_with_identical_score_identifiers
_run "an unreachable backend warns and exits zero" test_an_unreachable_backend_warns_and_exits_zero
_run "a malformed record is skipped, not fatal" test_a_malformed_record_is_skipped_not_fatal
_run "no content-bearing fields in any payload" test_no_content_bearing_fields_in_any_payload

echo ""
echo "run-score-export: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
