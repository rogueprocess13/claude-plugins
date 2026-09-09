#!/usr/bin/env bash
# run-score-export.sh — fleetd-owned sweeper turning finished runs in
# runs.jsonl into per-run Langfuse scores plus a ticket-level rollup on the
# merged run (run-score-export, langfuse-evidence-layer Phase 5).
#
# Off by default and fail-soft throughout: no credentials, an unreachable
# backend, a request timeout, or a malformed evidence record each warn and
# continue. This sweeper never blocks fleetd's loop and never touches a
# ticket — it is a pure reader of runs.jsonl and the pipeline logs beside it,
# and its only side effect is an outbound HTTP POST plus its own cursor file.
#
# NOTE: Does NOT set -euo pipefail — this is a sourceable library, invoked
# by fleetd's supervisor loop, which must not have its own shell flags
# mutated by a library it shells out to.

_SCORE_EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$_SCORE_EXPORT_DIR/fleet-config.sh" ]; then
  source "$_SCORE_EXPORT_DIR/fleet-config.sh"
fi

# Bridge to ticket-auto-pipeline's exit-path.sh for derive_failure_class /
# derive_failure_phase — same canonical-source bridge every other
# fleet-controller script uses for its ticket-auto-pipeline dependencies
# (fleet-controller/CLAUDE.md, "Canonical library sources").
if ! declare -f derive_failure_class >/dev/null 2>&1; then
  for _SE_TAP_LIB in "$_SCORE_EXPORT_DIR/../../ticket-auto-pipeline/lib" "$HOME/.claude/skills/lib"; do
    [ -f "$_SE_TAP_LIB/exit-path.sh" ] && source "$_SE_TAP_LIB/exit-path.sh" && break
  done
fi

# ── Configuration ────────────────────────────────────────────────────────────

FLEET_SCORE_EXPORT_ENABLE="${FLEET_SCORE_EXPORT_ENABLE:-false}"
LANGFUSE_HOST="${LANGFUSE_HOST:-}"
LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-}"
LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-}"

#: Local, fleetd-owned per-model USD-per-million-token pricing table (SC5) —
#: never a request in the sweeper's cost path. Overridable for tests/a
#: different deployment via SCORE_EXPORT_PRICING_FILE.
SCORE_EXPORT_PRICING_FILE="${SCORE_EXPORT_PRICING_FILE:-$_SCORE_EXPORT_DIR/../fleetd/model-pricing.json}"

# ── Enablement guard ─────────────────────────────────────────────────────────

# _score_export_enabled
# False when the feature flag is off or either credential is missing — the
# sweeper then no-ops with no request attempted (task: "No credentials means
# no-op").
_score_export_enabled() {
  [ "$FLEET_SCORE_EXPORT_ENABLE" = "true" ] || return 1
  [ -n "$LANGFUSE_HOST" ] || return 1
  [ -n "$LANGFUSE_PUBLIC_KEY" ] || return 1
  [ -n "$LANGFUSE_SECRET_KEY" ] || return 1
  return 0
}

# ── Cursor (idempotency — advisory, not authoritative; SC3) ─────────────────
# Keyed by run_id: {"<run_id>": {"run": true, "rollup": true}}. "run" marks
# the base per-run score set shipped; "rollup" marks the ticket-level rollup
# shipped once a merge decision exists for that run. Losing this file costs a
# harmless re-ship — every score id is derived from (run_id, name), so a
# re-submit overwrites rather than duplicates (SC3/task 11.4).
_score_export_cursor_file() {
  local runs_file="$1"
  echo "$(dirname "$runs_file")/score-export-cursor.json"
}

_score_export_cursor_get() {
  local cursor_file="$1" run_id="$2" field="$3"
  [ -f "$cursor_file" ] || {
    echo "false"
    return
  }
  jq -r --arg rid "$run_id" --arg f "$field" \
    '.[$rid][$f] // false' "$cursor_file" 2>/dev/null || echo "false"
}

_score_export_cursor_set() {
  local cursor_file="$1" run_id="$2" field="$3"
  local lock="${cursor_file}.lock"
  mkdir -p "$(dirname "$cursor_file")" 2>/dev/null
  (
    flock -x 9 2>/dev/null || true
    [ -f "$cursor_file" ] || echo '{}' >"$cursor_file"
    local updated
    updated=$(jq --arg rid "$run_id" --arg f "$field" \
      '.[$rid] = ((.[$rid] // {}) + {($f): true})' \
      "$cursor_file" 2>/dev/null) && [ -n "$updated" ] &&
      echo "$updated" >"${cursor_file}.tmp.$$" && mv "${cursor_file}.tmp.$$" "$cursor_file"
    rm -f "${cursor_file}.tmp.$$" 2>/dev/null
  ) 9>"$lock"
}

# ── HTTP transport ───────────────────────────────────────────────────────────
# Plain curl, on PATH — tests stub the `curl` binary itself (task 12.1), the
# same convention test-merge-poll.sh uses for `gh`. Bounded with --max-time so
# an unreachable or slow backend can never stall the sweep beyond it.

_score_export_post() {
  local path="$1" body="$2"
  curl -sS --max-time 15 \
    -u "${LANGFUSE_PUBLIC_KEY}:${LANGFUSE_SECRET_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${LANGFUSE_HOST%/}${path}" 2>/dev/null
}

# _score_export_score_id RUN_ID NAME
# Deterministic per (run_id, score name) — a re-ship overwrites rather than
# duplicates (SC3, task 11.4). A plain hash rather than the raw strings
# concatenated, so no character in either input can produce an invalid id.
_score_export_score_id() {
  printf '%s' "${1}::${2}" | sha256sum | cut -c1-32
}

# _score_export_submit NAME VALUE_JSON DATA_TYPE RUN_ID [COMMENT]
# VALUE_JSON is a JSON *literal* — a bare number, `true`/`false`, or an
# already-quoted string — never a shell string needing quoting here.
_score_export_submit() {
  local name="$1" value_json="$2" data_type="$3" run_id="$4" comment="${5:-}"
  local id body
  id=$(_score_export_score_id "$run_id" "$name")
  body=$(jq -nc \
    --arg id "$id" --arg sessionId "$run_id" --arg name "$name" \
    --arg dataType "$data_type" --arg comment "$comment" \
    --argjson value "$value_json" \
    '{id: $id, sessionId: $sessionId, name: $name, value: $value, dataType: $dataType}
     + (if $comment == "" then {} else {comment: $comment} end)')
  [ -n "$body" ] || return 0
  _score_export_post "/api/public/scores" "$body" >/dev/null 2>&1 || true
}

_score_export_submit_numeric() {
  local name="$1" value="$2" run_id="$3"
  [ -n "$value" ] && [ "$value" != "null" ] || return 0
  _score_export_submit "$name" "$value" "NUMERIC" "$run_id"
}

_score_export_submit_boolean() {
  local name="$1" value="$2" run_id="$3"
  _score_export_submit "$name" "$value" "BOOLEAN" "$run_id"
}

_score_export_submit_categorical() {
  local name="$1" value="$2" run_id="$3"
  [ -n "$value" ] && [ "$value" != "null" ] || return 0
  local quoted
  quoted=$(jq -nc --arg v "$value" '$v')
  _score_export_submit "$name" "$quoted" "CATEGORICAL" "$run_id"
}

# ── Cost derivation (SC5) ────────────────────────────────────────────────────

# _score_export_cost_events RUNS_FILE RUN_ID
# Sums every `cost` event's `usd` field for this run_id (a run can have one
# per phase under phase dispatch). Empty output means no cost evidence.
_score_export_cost_events_sum() {
  local runs_file="$1" run_id="$2"
  jq -sc --arg rid "$run_id" \
    '[.[] | select(.kind == "cost" and .run_id == $rid) | .usd] | select(length > 0) | add' \
    "$runs_file" 2>/dev/null
}

# _score_export_pricing_rate MODEL
# Prints "<input_per_mtok> <output_per_mtok>", falling back to the table's
# "_default" entry, and to a hardcoded default when the table itself is
# missing or unreadable — never a request, and never a fatal cost-path error.
_score_export_pricing_rate() {
  local model="$1"
  local input_rate output_rate
  if [ -f "$SCORE_EXPORT_PRICING_FILE" ]; then
    input_rate=$(jq -r --arg m "$model" \
      '.[$m].input_per_mtok // ._default.input_per_mtok // empty' \
      "$SCORE_EXPORT_PRICING_FILE" 2>/dev/null)
    output_rate=$(jq -r --arg m "$model" \
      '.[$m].output_per_mtok // ._default.output_per_mtok // empty' \
      "$SCORE_EXPORT_PRICING_FILE" 2>/dev/null)
  fi
  echo "${input_rate:-3.0} ${output_rate:-15.0}"
}

# _score_export_token_derived_cost RUN_JSON
# Cost derived from `run.tokens.in`/`.out` and the first entry of
# `run.models`, when no cost event exists for the run (SC5). Cache tokens are
# excluded — this table prices input/output only, the two rates every model
# publishes; a cache-aware table is future work, not a silent guess.
_score_export_token_derived_cost() {
  local run_json="$1"
  local in_tok out_tok model
  in_tok=$(echo "$run_json" | jq -r '.tokens.in // empty')
  out_tok=$(echo "$run_json" | jq -r '.tokens.out // empty')
  [ -n "$in_tok" ] && [ -n "$out_tok" ] || return 1
  model=$(echo "$run_json" | jq -r '.models[0] // empty')
  local rates input_rate output_rate
  rates=$(_score_export_pricing_rate "$model")
  input_rate=$(echo "$rates" | awk '{print $1}')
  output_rate=$(echo "$rates" | awk '{print $2}')
  awk -v i="$in_tok" -v o="$out_tok" -v ir="$input_rate" -v or_="$output_rate" \
    'BEGIN { printf "%.6f", (i / 1000000 * ir) + (o / 1000000 * or_) }'
}

# ── Merge-decision resolution ────────────────────────────────────────────────
# `runs.jsonl` is append-only, so a `run` event's own `merge_decision` field
# — set once at finalize time, before merge truth is usually knowable — is
# never rewritten. Merge truth normally arrives afterward as a separate
# `merge`-kind event (merge-poll.sh, "Merge truth arrives on a later pass").
# The inline field is still checked first as the fast path — an inline
# auto-merge or a fast poll may already have recorded it there.

_score_export_resolve_merge_decision() {
  local run_json="$1" runs_file="$2"
  local inline
  inline=$(echo "$run_json" | jq -r '.merge_decision // empty')
  if [ -n "$inline" ] && [ "$inline" != "null" ]; then
    echo "$inline"
    return
  fi
  local tid pr_num
  tid=$(echo "$run_json" | jq -r '.tid // empty')
  pr_num=$(echo "$run_json" | jq -r '.pr.pr // empty')
  [ -n "$tid" ] && [ -n "$pr_num" ] && [ "$pr_num" != "null" ] || return 0
  jq -rs --arg tid "$tid" --argjson pr "$pr_num" \
    '[.[] | select(.kind == "merge" and .tid == $tid and .pr == $pr)]
     | sort_by(.observed_at // "") | last | .state // empty' \
    "$runs_file" 2>/dev/null
}

# ── Failure classification, scoped to this run's own log window ────────────
# `derive_failure_class`/`derive_failure_phase` read a whole file; a ticket's
# pipeline log spans every run it ever had, so scoring an older run after a
# newer one has been appended requires isolating that run's own slice first —
# the lines from its own `META|run-id` line to the next one (or EOF).

_score_export_run_window() {
  local log_file="$1" run_id="$2"
  [ -f "$log_file" ] || return 1
  local run_id_lines start_line end_line total
  run_id_lines=$(grep -n '|META|run-id|info|' "$log_file" 2>/dev/null)
  [ -n "$run_id_lines" ] || return 1
  start_line=$(echo "$run_id_lines" | grep -F "\"run_id\":\"${run_id}\"" | head -1 | cut -d: -f1)
  [ -n "$start_line" ] || return 1
  total=$(wc -l <"$log_file")
  end_line=$(echo "$run_id_lines" | awk -F: -v s="$start_line" '$1 > s { print $1; exit }')
  if [ -n "$end_line" ]; then
    end_line=$((end_line - 1))
  else
    end_line="$total"
  fi
  sed -n "${start_line},${end_line}p" "$log_file"
}

_score_export_classify() {
  local log_dir="$1" tid="$2" run_id="$3"
  local log_file="${log_dir}/${tid}-pipeline.log"
  local window window_file class phase
  window=$(_score_export_run_window "$log_file" "$run_id")
  if [ -z "$window" ]; then
    echo "none none"
    return
  fi
  window_file=$(mktemp)
  printf '%s\n' "$window" >"$window_file"
  class=$(derive_failure_class "$window_file" 2>/dev/null)
  phase=$(derive_failure_phase "$window_file" 2>/dev/null)
  rm -f "$window_file"
  echo "${class:-none} ${phase:-none}"
}

# ── Per-run score mapping (task 11.2) ───────────────────────────────────────

_score_export_ship_run() {
  local run_json="$1" runs_file="$2" log_dir="$3"
  local run_id tid outcome merge_decision verify_attempts review_iterations
  local fix_rounds reconcile_cycles started_at ended_at complexity gate_stops_len
  run_id=$(echo "$run_json" | jq -r '.run_id // empty')
  tid=$(echo "$run_json" | jq -r '.tid // empty')
  [ -n "$run_id" ] && [ -n "$tid" ] || return 0

  outcome=$(echo "$run_json" | jq -r '.outcome // empty')
  merge_decision=$(_score_export_resolve_merge_decision "$run_json" "$runs_file")
  verify_attempts=$(echo "$run_json" | jq -r '.verify_attempts // 0')
  review_iterations=$(echo "$run_json" | jq -r '.review_iterations // 0')
  fix_rounds=$(echo "$run_json" | jq -r '.fix_rounds // 0')
  reconcile_cycles=$(echo "$run_json" | jq -r '.reconcile_cycles // 0')
  started_at=$(echo "$run_json" | jq -r '.started_at // empty')
  ended_at=$(echo "$run_json" | jq -r '.ended_at // empty')
  complexity=$(echo "$run_json" | jq -r '.complexity // empty')
  gate_stops_len=$(echo "$run_json" | jq -r '.gate_stops | length')

  _score_export_submit_categorical "outcome" "$outcome" "$run_id"
  _score_export_submit_numeric "verify_attempts" "$verify_attempts" "$run_id"
  _score_export_submit_numeric "review_iterations" "$review_iterations" "$run_id"
  _score_export_submit_numeric "fix_rounds" "$fix_rounds" "$run_id"
  _score_export_submit_numeric "reconcile_cycles" "$reconcile_cycles" "$run_id"
  _score_export_submit_boolean "gate_stopped" "$([ "$gate_stops_len" -gt 0 ] && echo true || echo false)" "$run_id"

  # Cycle time — this run's own started_at → ended_at.
  if [ -n "$started_at" ] && [ -n "$ended_at" ]; then
    local cycle_ms
    cycle_ms=$(_score_export_iso_diff_ms "$started_at" "$ended_at")
    [ -n "$cycle_ms" ] && _score_export_submit_numeric "cycle_time_ms" "$cycle_ms" "$run_id"
  fi

  # Cost — envelope preferred, token-derived fallback, omitted otherwise (SC5).
  local cost cost_source
  cost=$(_score_export_cost_events_sum "$runs_file" "$run_id")
  if [ -n "$cost" ] && [ "$cost" != "null" ]; then
    cost_source="envelope"
  else
    cost=$(_score_export_token_derived_cost "$run_json")
    [ -n "$cost" ] && cost_source="tokens"
  fi
  if [ -n "$cost" ]; then
    _score_export_submit_numeric "cost_usd" "$cost" "$run_id"
    _score_export_submit_categorical "cost_source" "$cost_source" "$run_id"
  fi

  # First-pass success (per run) — merged with no verify retry and no PR
  # review iteration needed.
  if [ -n "$merge_decision" ] && [ "$merge_decision" != "null" ]; then
    _score_export_submit_categorical "merge_decision" "$merge_decision" "$run_id"
    local first_pass="false"
    if [ "$merge_decision" = "merged" ] && [ "$verify_attempts" -le 1 ] &&
      [ "$review_iterations" -eq 0 ]; then
      first_pass="true"
    fi
    _score_export_submit_boolean "first_pass_success" "$first_pass" "$run_id"
  fi

  # Complexity-estimate accuracy — a declared "simple" ticket that needed
  # real gating/retries was underestimated; a declared "complex" ticket that
  # sailed through cleanly was overestimated. No claim either way when
  # complexity was never recorded.
  if [ -n "$complexity" ] && [ "$complexity" != "null" ]; then
    local needed_work="false"
    if [ "$gate_stops_len" -gt 0 ] || [ "$verify_attempts" -gt 2 ] || [ "$review_iterations" -gt 1 ]; then
      needed_work="true"
    fi
    local accuracy="accurate"
    if [ "$complexity" = "simple" ] && [ "$needed_work" = "true" ]; then
      accuracy="underestimated"
    elif [ "$complexity" = "complex" ] && [ "$needed_work" = "false" ]; then
      accuracy="overestimated"
    fi
    _score_export_submit_categorical "complexity_estimate_accuracy" "$accuracy" "$run_id"
  fi

  # Failure phase and failure class — every run, including a clean one
  # (SC6: `none`/`none` rather than an absent score).
  local classified class phase
  classified=$(_score_export_classify "$log_dir" "$tid" "$run_id")
  class=$(echo "$classified" | awk '{print $1}')
  phase=$(echo "$classified" | awk '{print $2}')
  _score_export_submit_categorical "failure_class" "$class" "$run_id"
  _score_export_submit_categorical "failure_phase" "$phase" "$run_id"
}

# _score_export_iso_diff_ms START_ISO END_ISO
# Millisecond difference between two `%Y-%m-%dT%H:%M:%SZ` timestamps. Empty
# on any parse failure rather than a bogus number.
_score_export_iso_diff_ms() {
  local start_iso="$1" end_iso="$2"
  local start_epoch end_epoch
  start_epoch=$(date -u -d "$start_iso" +%s 2>/dev/null) || return 1
  end_epoch=$(date -u -d "$end_iso" +%s 2>/dev/null) || return 1
  echo $(((end_epoch - start_epoch) * 1000))
}

# ── Ticket-level rollup (task 11.5, on the run whose merge decision landed) ─

_score_export_ship_ticket_rollup() {
  local run_json="$1" runs_file="$2"
  local run_id tid ticket_created_at merged_at
  run_id=$(echo "$run_json" | jq -r '.run_id // empty')
  tid=$(echo "$run_json" | jq -r '.tid // empty')
  ticket_created_at=$(echo "$run_json" | jq -r '.ticket_created_at // empty')
  [ -n "$run_id" ] && [ -n "$tid" ] || return 0

  # Every run event this ticket has produced, oldest first.
  local ticket_runs_json
  ticket_runs_json=$(jq -sc --arg tid "$tid" \
    '[.[] | select(.kind == "run" and .tid == $tid)] | sort_by(.started_at // "")' \
    "$runs_file" 2>/dev/null)
  [ -n "$ticket_runs_json" ] && [ "$ticket_runs_json" != "null" ] || return 0

  local run_count
  run_count=$(echo "$ticket_runs_json" | jq 'length')
  _score_export_submit_numeric "ticket_runs" "$run_count" "$run_id"

  # Total cost across every run of the ticket — envelope cost when present,
  # token-derived otherwise, per run (SC5), summed.
  local total_cost="0" had_cost="false"
  local i n
  n=$(echo "$ticket_runs_json" | jq 'length')
  for ((i = 0; i < n; i++)); do
    local one_run one_run_id one_cost
    one_run=$(echo "$ticket_runs_json" | jq -c ".[$i]")
    one_run_id=$(echo "$one_run" | jq -r '.run_id // empty')
    [ -n "$one_run_id" ] || continue
    one_cost=$(_score_export_cost_events_sum "$runs_file" "$one_run_id")
    if [ -z "$one_cost" ] || [ "$one_cost" = "null" ]; then
      one_cost=$(_score_export_token_derived_cost "$one_run")
    fi
    if [ -n "$one_cost" ]; then
      had_cost="true"
      total_cost=$(awk -v a="$total_cost" -v b="$one_cost" 'BEGIN { printf "%.6f", a + b }')
    fi
  done
  [ "$had_cost" = "true" ] && _score_export_submit_numeric "ticket_cost_total" "$total_cost" "$run_id"

  # Ticket cycle time — creation to merge, including any hold.
  local merge_event
  merge_event=$(jq -sc --arg tid "$tid" \
    '[.[] | select(.kind == "merge" and .tid == $tid and .state == "merged")] | sort_by(.merged_at // "") | last' \
    "$runs_file" 2>/dev/null)
  if [ -n "$merge_event" ] && [ "$merge_event" != "null" ] && [ -n "$ticket_created_at" ]; then
    merged_at=$(echo "$merge_event" | jq -r '.merged_at // empty')
    if [ -n "$merged_at" ]; then
      local cycle_ms
      cycle_ms=$(_score_export_iso_diff_ms "$ticket_created_at" "$merged_at")
      [ -n "$cycle_ms" ] && _score_export_submit_numeric "ticket_cycle_ms" "$cycle_ms" "$run_id"
    fi
  fi

  # Ticket-level first-pass success — merged with zero verify retries,
  # counting only runs that were not held pending a person (a gate hold or a
  # human hold both open a fresh run; neither is a verify retry).
  local retry_total=0
  for ((i = 0; i < n; i++)); do
    local one_run one_outcome one_attempts
    one_run=$(echo "$ticket_runs_json" | jq -c ".[$i]")
    one_outcome=$(echo "$one_run" | jq -r '.outcome // empty')
    case "$one_outcome" in
    held:*) continue ;;
    esac
    one_attempts=$(echo "$one_run" | jq -r '.verify_attempts // 0')
    if [ "$one_attempts" -gt 1 ]; then
      retry_total=$((retry_total + one_attempts - 1))
    fi
  done
  local ticket_first_pass="false"
  if [ -n "$merge_event" ] && [ "$merge_event" != "null" ] && [ "$retry_total" -eq 0 ]; then
    ticket_first_pass="true"
  fi
  _score_export_submit_boolean "ticket_first_pass_success" "$ticket_first_pass" "$run_id"
}

# ── The sweep (task 11.1, 11.9) ─────────────────────────────────────────────

# run_score_export_sweep RUNS_FILE
# Reads every `run` event, ships its per-run scores once, and ships the
# ticket-level rollup once its merge decision is known — both idempotent via
# the cursor above. Every failure path is soft: a malformed line is skipped
# with a warning, an unreachable backend costs a warning and nothing more,
# and the function always returns 0.
run_score_export_sweep() {
  local runs_file="$1"
  [ -f "$runs_file" ] || return 0
  _score_export_enabled || return 0

  local log_dir cursor_file
  log_dir="$(dirname "$runs_file")"
  cursor_file=$(_score_export_cursor_file "$runs_file")

  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "$line" | jq -e . >/dev/null 2>&1 || {
      echo "run-score-export: skipping unparseable line" >&2
      continue
    }
    local kind
    kind=$(echo "$line" | jq -r '.kind // empty' 2>/dev/null)
    [ "$kind" = "run" ] || continue

    local run_id merge_decision
    run_id=$(echo "$line" | jq -r '.run_id // empty' 2>/dev/null)
    [ -n "$run_id" ] || continue

    if [ "$(_score_export_cursor_get "$cursor_file" "$run_id" "run")" != "true" ]; then
      _score_export_ship_run "$line" "$runs_file" "$log_dir"
      _score_export_cursor_set "$cursor_file" "$run_id" "run"
    fi

    merge_decision=$(_score_export_resolve_merge_decision "$line" "$runs_file")
    if [ -n "$merge_decision" ] && [ "$merge_decision" != "null" ] &&
      [ "$(_score_export_cursor_get "$cursor_file" "$run_id" "rollup")" != "true" ]; then
      _score_export_ship_ticket_rollup "$line" "$runs_file"
      _score_export_cursor_set "$cursor_file" "$run_id" "rollup"
    fi
  done <"$runs_file"

  return 0
}

# ── CLI entrypoint ───────────────────────────────────────────────────────────

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
  sweep)
    shift
    run_score_export_sweep "$@"
    ;;
  *)
    echo "Usage: run-score-export.sh sweep RUNS_FILE" >&2
    exit 1
    ;;
  esac
fi
