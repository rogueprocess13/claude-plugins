#!/usr/bin/env bash
# test-ticket-cancel.sh — the cancel transition (GitHub #770): flow.sh's
# `cancel` trigger, the Canceled tombstone, skills/ticket-cancel/cancel.sh,
# the pipeline-log record, flow-run.sh's exit 14 and the blocked-by rule.
# The board projection of ticket-cancelled is in test-board-drivers.sh; fleet
# dispatch's handling is in fleet-controller/lib/tests/test-fleet-dispatch.sh.
# Usage: bash test-ticket-cancel.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
FLOW_SH="$PLUGIN_DIR/skills/ticket-flow/flow.sh"
CANCEL_SH="$PLUGIN_DIR/skills/ticket-cancel/cancel.sh"
FLOW_RUN_SH="$LIB_DIR/flow-run.sh"
WF="$PLUGIN_DIR/skills/ticket-flow/workflow.json"
TID="TEST-7"

PASS=0
FAIL=0
_run() {
  local name="$1"
  shift
  local _err _rc=0
  _err=$(mktemp)
  "$@" 2>"$_err" || _rc=$?
  if [ "$_rc" -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (exit $_rc)"
    [ -s "$_err" ] && sed 's/^/    /' "$_err"
    ((FAIL++)) || true
  fi
  rm -f "$_err"
}

# ── fixtures ─────────────────────────────────────────────────────────────────

_mk() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/logs" "$t/state" "$t/repos"
  echo "$t"
}

_manifest() { echo "$1/repos/.ticket-auto/initiatives/${3:-INIT-1}/tickets/$2/planner/manifest.json"; }

# _seed <tmp> <tid> [stage] [extra-jq-object]
_seed() {
  local t="$1" tid="$2" stage="${3:-}" extra="${4:-}"
  mkdir -p "$t/repos/.ticket-auto/initiatives/_index" \
    "$t/repos/.ticket-auto/initiatives/INIT-1/tickets/$tid/planner"
  echo "INIT-1" >"$t/repos/.ticket-auto/initiatives/_index/${tid}.initiative"
  local c='{"type":"bug","initiative":"INIT-1","blocked_by":[],"dispatch":false}'
  [ -z "$stage" ] || c=$(echo "$c" | jq -c --arg s "$stage" '.stage = $s')
  [ -z "$extra" ] || c=$(echo "$c" | jq -c ". + $extra")
  echo "$c" >"$(_manifest "$t" "$tid")"
}

# _flow <tmp> <tid> <trigger> [args...] — fence off, no log file, no board.
_flow() {
  local t="$1" tid="$2" trig="$3"
  shift 3
  env -u LOG_FILE -u TAP_LOG -u FLEET_GENERATION -u FLEET_WORKER_PID \
    FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none CLAUDE_SKILLS_LIB="$LIB_DIR" \
    TICKET_FLOW_LOCK_DIR="$t/logs" REPOS_ROOT="$t/repos" FLEET_PIPELINE_LOG_DIR="$t/logs" \
    bash "$FLOW_SH" "$tid" "$trig" "$@"
}

# _cancel <tmp> <tid> [args...] — the actuator, as a person at a terminal.
_cancel() {
  local t="$1" tid="$2"
  shift 2
  env -u LOG_FILE -u TAP_LOG -u FLEET_GENERATION -u FLEET_WORKER_PID -u CLAUDE_CODE_SESSION_ID \
    FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none CLAUDE_SKILLS_LIB="$LIB_DIR" \
    TICKET_FLOW_LOCK_DIR="$t/logs" REPOS_ROOT="$t/repos" FLEET_PIPELINE_LOG_DIR="$t/logs" \
    FLEET_STATE_DIR="$t/state" TICKET_CANCEL_PGREP=false FLOW_SH="$FLOW_SH" \
    bash "$CANCEL_SH" "$tid" "$@"
}

_events() {
  local f="$1/logs/$2-outbox.jsonl"
  [ -f "$f" ] && jq -c 'select(.event == "ticket-cancelled")' "$f" | wc -l | tr -d ' ' || echo 0
}
_lines() { [ -f "$1" ] && wc -l <"$1" | tr -d ' ' || echo 0; }

# ── workflow.json shape ──────────────────────────────────────────────────────

test_trigger_declared() {
  jq -e '.triggers.cancel
    | .from == null and .to == "Canceled" and .adds == []
      and (.removes | sort) == ["needs-adr","needs-info","rejected","reviewed"]
      and .precondition == "must_not_be_epic" and .refuse_from == ["Done"]
      and .requires_data == ["reason"] and .allow_from_tombstone == true
      and .emits == {event: "ticket-cancelled", data: {reason: "{reason}"}}' "$WF" >/dev/null || return 1
  jq -e '.tombstone_stages == ["Canceled"]' "$WF" >/dev/null || return 1
  jq -e '.vocabulary["ticket-cancelled"]
    | .trigger == "cancel" and .payload == {reason: "string"}' "$WF" >/dev/null || return 1
  # No other trigger may leave the tombstone.
  [ "$(jq -r '[.triggers | to_entries[] | select(.value.allow_from_tombstone == true) | .key] | join(",")' "$WF")" = "cancel" ]
}

# ── cancel from every non-terminal stage ─────────────────────────────────────

_cancel_from() {
  local stage="$1" t out rc=0
  t=$(_mk)
  _seed "$t" "$TID" "$stage" '{"flags":["needs-info","rejected","reviewed"],"approved":true,"approval_provenance":"human","rev":4}'
  out=$(_flow "$t" "$TID" cancel --reason "obsolete: the app is gone" 2>/dev/null) || rc=$?
  local m ok=0
  m=$(_manifest "$t" "$TID")
  [ "$rc" -eq 0 ] || ok=1
  [ "$(jq -r '.stage' "$m")" = "Canceled" ] || ok=1
  [ "$(jq -c '.flags' "$m")" = "[]" ] || ok=1
  [ "$(jq -r '.rev' "$m")" = "5" ] || ok=1
  [ "$(jq -r '(.approved // false | tostring) + ":" + (.approval_provenance // "")' "$m")" = "false:" ] || ok=1
  [ "$(jq -r 'has("pending_event")' "$m")" = "false" ] || ok=1
  [ "$(_events "$t" "$TID")" = "1" ] || ok=1
  [ "$(jq -r 'select(.event == "ticket-cancelled") | .data.reason' "$t/logs/$TID-outbox.jsonl")" = "obsolete: the app is gone" ] || ok=1
  [ "$(jq -r 'select(.event == "ticket-cancelled") | .idem' "$t/logs/$TID-outbox.jsonl")" = "$TID:5" ] || ok=1
  [ "$(echo "$out" | jq -r '.stage + ":" + (.event_emitted | tostring)')" = "Canceled:true" ] || ok=1
  [ "$ok" -eq 0 ] || echo "stage=$stage rc=$rc manifest=$(cat "$m") out=$out" >&2
  rm -rf "$t"
  return "$ok"
}

test_cancel_from_each_stage() {
  local s
  for s in Backlog Todo Approve Ready Review UAT Blocked; do
    _cancel_from "$s" || return 1
  done
}

test_cancel_ticket_with_no_stage_yet() {
  local t rc=0
  t=$(_mk)
  _seed "$t" "$TID"
  _flow "$t" "$TID" cancel --data "reason=duplicate" >/dev/null 2>&1 || rc=$?
  local stage
  stage=$(jq -r '.stage' "$(_manifest "$t" "$TID")")
  rm -rf "$t"
  [ "$rc" -eq 0 ] && [ "$stage" = "Canceled" ]
}

# ── refusals ─────────────────────────────────────────────────────────────────

test_cancel_refused_from_done() {
  local t rc=0 before after
  t=$(_mk)
  _seed "$t" "$TID" Done '{"rev":9}'
  before=$(cat "$(_manifest "$t" "$TID")")
  _flow "$t" "$TID" cancel --reason "too late" >/dev/null 2>&1 || rc=$?
  after=$(cat "$(_manifest "$t" "$TID")")
  local ev
  ev=$(_events "$t" "$TID")
  rm -rf "$t"
  [ "$rc" -eq 8 ] && [ "$before" = "$after" ] && [ "$ev" = "0" ]
}

test_cancel_requires_reason() {
  local t rc=0 rc2=0 before after
  t=$(_mk)
  _seed "$t" "$TID" Approve
  before=$(cat "$(_manifest "$t" "$TID")")
  _flow "$t" "$TID" cancel >/dev/null 2>&1 || rc=$?
  _flow "$t" "$TID" cancel --reason "   " >/dev/null 2>&1 || rc2=$?
  after=$(cat "$(_manifest "$t" "$TID")")
  local ev
  ev=$(_events "$t" "$TID")
  rm -rf "$t"
  [ "$rc" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$before" = "$after" ] && [ "$ev" = "0" ]
}

test_cancel_refused_on_epic() {
  local t rc=0
  t=$(_mk)
  mkdir -p "$t/repos/.ticket-auto/initiatives/TEST-50/epic"
  echo '{"branch":"epic/x","children":[],"stage":"Backlog"}' >"$t/repos/.ticket-auto/initiatives/TEST-50/epic/manifest.json"
  _flow "$t" TEST-50 cancel --reason "drop the epic" >/dev/null 2>&1 || rc=$?
  local stage
  stage=$(jq -r '.stage' "$t/repos/.ticket-auto/initiatives/TEST-50/epic/manifest.json")
  rm -rf "$t"
  [ "$rc" -eq 8 ] && [ "$stage" = "Backlog" ]
}

# ── tombstone: nothing leaves Canceled ───────────────────────────────────────

test_tombstone_refuses_every_other_trigger() {
  local t trig rc before after ok=0
  t=$(_mk)
  _seed "$t" "$TID" Review
  _flow "$t" "$TID" cancel --reason "superseded" >/dev/null 2>&1 || return 1
  before=$(cat "$(_manifest "$t" "$TID")")
  local outbox_before
  outbox_before=$(_lines "$t/logs/$TID-outbox.jsonl")
  while IFS= read -r trig; do
    [ "$trig" = "cancel" ] && continue
    case "$(jq -r --arg t "$trig" '.triggers[$t].precondition' "$WF")" in must_be_epic) continue ;; esac
    rc=0
    # With a log file, as a still-running worker would call it: the refusal
    # must leave the log alone too.
    LOG_FILE="$t/logs/$TID-pipeline.log" FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none \
      CLAUDE_SKILLS_LIB="$LIB_DIR" TICKET_FLOW_LOCK_DIR="$t/logs" REPOS_ROOT="$t/repos" \
      FLEET_PIPELINE_LOG_DIR="$t/logs" bash "$FLOW_SH" "$TID" "$trig" --data outcome=Smooth >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 14 ]; then
      echo "trigger $trig exited $rc on a cancelled ticket, expected 14" >&2
      ok=1
    fi
  done < <(jq -r '.triggers | keys[]' "$WF")
  after=$(cat "$(_manifest "$t" "$TID")")
  [ "$before" = "$after" ] || {
    echo "manifest changed: $after" >&2
    ok=1
  }
  [ "$(_lines "$t/logs/$TID-outbox.jsonl")" = "$outbox_before" ] || ok=1
  [ ! -e "$t/logs/$TID-pipeline.log" ] || {
    echo "a refused trigger wrote the pipeline log" >&2
    ok=1
  }
  rm -rf "$t"
  return "$ok"
}

test_flow_run_exit_14_writes_no_log_line() {
  local t rc=0 out
  t=$(_mk)
  _seed "$t" "$TID" Canceled
  echo "2026-01-01T00:00:00Z|META|outcome|info|cancelled: gone" >"$t/logs/$TID-pipeline.log"
  out=$(env -u FLEET_GENERATION -u FLEET_WORKER_PID -u HB_LOG_FILE FLEET_FENCE_ENFORCE=false \
    FLEET_BOARD_DRIVERS=none CLAUDE_SKILLS_LIB="$LIB_DIR" TICKET_FLOW_LOCK_DIR="$t/logs" \
    REPOS_ROOT="$t/repos" FLEET_PIPELINE_LOG_DIR="$t/logs" FLOW_RUN_FLOW_SH="$FLOW_SH" \
    bash "$FLOW_RUN_SH" --log-file "$t/logs/$TID-pipeline.log" "$TID" appraise-start 2>/dev/null) || rc=$?
  local n last
  n=$(_lines "$t/logs/$TID-pipeline.log")
  last=$(tail -1 "$t/logs/$TID-pipeline.log")
  rm -rf "$t"
  [ "$rc" -eq 14 ] && [ "$n" = "1" ] && [[ "$last" == *"|META|outcome|info|cancelled: gone" ]] &&
    grep -q '^FLOW_RC=14$' <<<"$out"
}

# ── idempotent repeat ────────────────────────────────────────────────────────

test_flow_repeat_keeps_state_and_advances_rev() {
  local t rc=0
  t=$(_mk)
  _seed "$t" "$TID" Ready
  _flow "$t" "$TID" cancel --reason "first" >/dev/null 2>&1 || return 1
  _flow "$t" "$TID" cancel --reason "again" >/dev/null 2>&1 || rc=$?
  local m stage flags rev ev
  m=$(_manifest "$t" "$TID")
  stage=$(jq -r '.stage' "$m")
  flags=$(jq -c '.flags' "$m")
  rev=$(jq -r '.rev' "$m")
  ev=$(_events "$t" "$TID")
  rm -rf "$t"
  # flow.sh's own rule: values unchanged, rev and the event still advance.
  [ "$rc" -eq 0 ] && [ "$stage" = "Canceled" ] && [ "$flags" = "[]" ] && [ "$rev" = "2" ] && [ "$ev" = "2" ]
}

test_actuator_repeat_is_a_noop() {
  local t rc=0 out
  t=$(_mk)
  _seed "$t" "$TID" Approve
  _cancel "$t" "$TID" --reason "obsolete" >/dev/null 2>&1 || return 1
  local m rev1 log1
  m=$(_manifest "$t" "$TID")
  rev1=$(jq -r '.rev' "$m")
  log1=$(cat "$t/logs/$TID-pipeline.log")
  out=$(_cancel "$t" "$TID" --reason "obsolete, second call" 2>/dev/null) || rc=$?
  local rev2 log2 ev
  rev2=$(jq -r '.rev' "$m")
  log2=$(cat "$t/logs/$TID-pipeline.log")
  ev=$(_events "$t" "$TID")
  rm -rf "$t"
  [ "$rc" -eq 0 ] && [ "$rev1" = "$rev2" ] && [ "$log1" = "$log2" ] && [ "$ev" = "1" ] &&
    grep -q '^already_cancelled=true$' <<<"$out"
}

test_actuator_repeat_completes_a_missing_log_record() {
  # First run died after flow.sh, before the log write.
  local t rc=0
  t=$(_mk)
  _seed "$t" "$TID" Approve
  _flow "$t" "$TID" cancel --reason "obsolete" >/dev/null 2>&1 || return 1
  [ ! -e "$t/logs/$TID-pipeline.log" ] || return 1
  _cancel "$t" "$TID" --reason "obsolete" >/dev/null 2>&1 || rc=$?
  local last ev
  last=$(tail -1 "$t/logs/$TID-pipeline.log")
  ev=$(_events "$t" "$TID")
  rm -rf "$t"
  [ "$rc" -eq 0 ] && [ "$ev" = "1" ] && [[ "$last" == *"|META|outcome|info|cancelled: obsolete" ]]
}

# ── generation fence ─────────────────────────────────────────────────────────

_flow_fenced() {
  local t="$1" tid="$2" trig="$3"
  shift 3
  env -u LOG_FILE -u TAP_LOG FLEET_FENCE_ENFORCE=true FLEET_STATE_DIR="$t/state" FLEET_BOARD_DRIVERS=none \
    CLAUDE_SKILLS_LIB="$LIB_DIR" TICKET_FLOW_LOCK_DIR="$t/logs" REPOS_ROOT="$t/repos" \
    FLEET_PIPELINE_LOG_DIR="$t/logs" bash "$FLOW_SH" "$tid" "$trig" "$@"
}

test_fenced_out_generation_refused() {
  local t rc=0 rc2=0
  t=$(_mk)
  _seed "$t" "$TID" Ready
  echo '{"fenced_generation": 3}' >"$t/state/$TID-fence"
  FLEET_GENERATION=3 FLEET_WORKER_PID=$$ _flow_fenced "$t" "$TID" cancel --reason "stale worker" >/dev/null 2>&1 || rc=$?
  env -u FLEET_GENERATION FLEET_WORKER_PID=$$ bash -c "$(declare -f _flow_fenced); FLOW_SH='$FLOW_SH' LIB_DIR='$LIB_DIR' _flow_fenced '$t' '$TID' cancel --reason 'no token'" >/dev/null 2>&1 || rc2=$?
  local stage ev
  stage=$(jq -r '.stage' "$(_manifest "$t" "$TID")")
  ev=$(_events "$t" "$TID")
  rm -rf "$t"
  [ "$rc" -eq 10 ] && [ "$rc2" -eq 9 ] && [ "$stage" = "Ready" ] && [ "$ev" = "0" ]
}

test_current_generation_and_operator_allowed() {
  local t rc=0 rc2=0
  t=$(_mk)
  _seed "$t" "$TID" Ready
  _seed "$t" TEST-8 Ready
  echo '{"fenced_generation": 3}' >"$t/state/$TID-fence"
  echo '{"fenced_generation": 3}' >"$t/state/TEST-8-fence"
  FLEET_GENERATION=4 FLEET_WORKER_PID=$$ _flow_fenced "$t" "$TID" cancel --reason "current worker" >/dev/null 2>&1 || rc=$?
  # A person at a terminal: no generation, no worker pid — not fenced.
  env -u FLEET_GENERATION -u FLEET_WORKER_PID bash -c "$(declare -f _flow_fenced); FLOW_SH='$FLOW_SH' LIB_DIR='$LIB_DIR' _flow_fenced '$t' TEST-8 cancel --reason 'operator'" >/dev/null 2>&1 || rc2=$?
  local s1 s2 gen
  s1=$(jq -r '.stage' "$(_manifest "$t" "$TID")")
  s2=$(jq -r '.stage' "$(_manifest "$t" TEST-8)")
  gen=$(jq -r 'select(.event == "ticket-cancelled") | .gen' "$t/logs/$TID-outbox.jsonl")
  rm -rf "$t"
  [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$s1" = "Canceled" ] && [ "$s2" = "Canceled" ] && [ "$gen" = "4" ]
}

# ── the actuator and its log record ──────────────────────────────────────────

test_actuator_writes_log_record_outcome_last() {
  local t rc=0 out
  t=$(_mk)
  _seed "$t" "$TID" Approve '{"flags":["needs-info"],"approved":true}'
  # A held ticket: the run is closed, its outcome is the last line.
  {
    echo "2026-01-01T00:00:00Z|META|schema|info|1"
    echo "2026-01-01T00:00:01Z|META|run-id|info|$TID-2026-01-01T00:00:01Z-1"
    echo "2026-01-01T00:00:02Z|GATE|gate|fail|held: complex ticket"
    echo "2026-01-01T00:00:03Z|META|outcome|info|held: gate"
  } >"$t/logs/$TID-pipeline.log"
  out=$(_cancel "$t" "$TID" --reason "obsolete | written for an app that no longer exists" 2>/dev/null) || rc=$?
  local log="$t/logs/$TID-pipeline.log" ok=0
  [ "$rc" -eq 0 ] || ok=1
  [ "$(_lines "$log")" = "6" ] || ok=1
  sed -n 5p "$log" | grep -qE '^[^|]+\|META\|cancel\|info\|reason=obsolete   written for an app that no longer exists; from=Approve; by=operator$' || ok=1
  sed -n 6p "$log" | grep -qE '^[^|]+\|META\|outcome\|info\|cancelled: obsolete   written for an app that no longer exists$' || ok=1
  # Every line still has exactly five fields.
  [ "$(awk -F'|' 'NF != 5' "$log" | wc -l | tr -d ' ')" = "0" ] || ok=1
  # No trigger-def or other flow.sh line: the two lines are the whole record.
  ! grep -q 'trigger-def' "$log" || ok=1
  grep -q '^stage=Canceled$' <<<"$out" || ok=1
  grep -q '^logged=true$' <<<"$out" || ok=1
  [ "$(jq -r '.approved // false' "$(_manifest "$t" "$TID")")" = "false" ] || ok=1
  [ "$ok" -eq 0 ] || {
    echo "rc=$rc out=$out" >&2
    cat "$log" >&2
  }
  rm -rf "$t"
  return "$ok"
}

test_actuator_creates_log_for_never_run_ticket() {
  local t rc=0
  t=$(_mk)
  _seed "$t" "$TID" Backlog
  _cancel "$t" "$TID" --reason "duplicate" >/dev/null 2>&1 || rc=$?
  local log="$t/logs/$TID-pipeline.log" first last n
  first=$(head -1 "$log")
  last=$(tail -1 "$log")
  n=$(_lines "$log")
  rm -rf "$t"
  [ "$rc" -eq 0 ] && [ "$n" = "3" ] && [[ "$first" == *"|META|schema|info|1" ]] &&
    [[ "$last" == *"|META|outcome|info|cancelled: duplicate" ]]
}

test_actuator_usage_and_refusals() {
  local t rc1=0 rc2=0 rc3=0 rc4=0
  t=$(_mk)
  _seed "$t" "$TID" Done
  _seed "$t" TEST-8 Todo
  _cancel "$t" TEST-8 >/dev/null 2>&1 || rc1=$?
  _cancel "$t" TEST-8 --reason "" >/dev/null 2>&1 || rc2=$?
  _cancel "$t" "$TID" --reason "too late" >/dev/null 2>&1 || rc3=$?
  mkdir -p "$t/repos/.ticket-auto/initiatives/TEST-50/epic"
  echo '{"branch":"epic/x","children":[]}' >"$t/repos/.ticket-auto/initiatives/TEST-50/epic/manifest.json"
  _cancel "$t" TEST-50 --reason "drop it" >/dev/null 2>&1 || rc4=$?
  local s8 sdone logs
  s8=$(jq -r '.stage' "$(_manifest "$t" TEST-8)")
  sdone=$(jq -r '.stage' "$(_manifest "$t" "$TID")")
  logs=$(find "$t/logs" -name '*-pipeline.log' | wc -l | tr -d ' ')
  local adhoc=0
  [ -e "$t/repos/.ticket-auto/initiatives/_adhoc" ] && adhoc=1
  rm -rf "$t"
  [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$rc3" -eq 5 ] && [ "$rc4" -eq 5 ] &&
    [ "$s8" = "Todo" ] && [ "$sdone" = "Done" ] && [ "$logs" = "0" ] && [ "$adhoc" = "0" ]
}

test_actuator_refuses_under_a_live_worker() {
  local t rc=0 rc2=0
  t=$(_mk)
  _seed "$t" "$TID" Ready
  sleep 300 &
  local wpid=$!
  jq -n --argjson p "$wpid" '{pid: $p, generation: 2}' >"$t/state/$TID-run.json"
  _cancel "$t" "$TID" --reason "obsolete" >/dev/null 2>&1 || rc=$?
  local stage1 ev1
  stage1=$(jq -r '.stage' "$(_manifest "$t" "$TID")")
  ev1=$(_events "$t" "$TID")
  _cancel "$t" "$TID" --reason "obsolete" --force >/dev/null 2>&1 || rc2=$?
  local stage2 alive=0
  stage2=$(jq -r '.stage' "$(_manifest "$t" "$TID")")
  kill -0 "$wpid" 2>/dev/null && alive=1
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  rm -rf "$t"
  # Refused with nothing written; --force cancels and never kills the worker.
  [ "$rc" -eq 6 ] && [ "$stage1" = "Ready" ] && [ "$ev1" = "0" ] &&
    [ "$rc2" -eq 0 ] && [ "$stage2" = "Canceled" ] && [ "$alive" = "1" ]
}

test_actuator_ignores_a_dead_registry_pid() {
  local t rc=0
  t=$(_mk)
  _seed "$t" "$TID" Ready
  (exit 0) &
  local dead=$!
  wait "$dead" 2>/dev/null || true
  jq -n --argjson p "$dead" '{pid: $p}' >"$t/state/$TID-run.json"
  _cancel "$t" "$TID" --reason "obsolete" >/dev/null 2>&1 || rc=$?
  local stage
  stage=$(jq -r '.stage' "$(_manifest "$t" "$TID")")
  rm -rf "$t"
  [ "$rc" -eq 0 ] && [ "$stage" = "Canceled" ]
}

# ── dependents are not released ──────────────────────────────────────────────

test_cancelled_blocker_does_not_release_dependents() {
  local t out rc=0
  t=$(_mk)
  _seed "$t" "$TID" UAT
  _seed "$t" TEST-8 Backlog "{\"blocked_by\":[\"$TID\"]}"
  _seed "$t" TEST-9 Backlog '{"blocked_by":["TEST-70"]}'
  # The strongest case for a wrong release: the blocker's run completed with
  # no PR, which alone reads as Done.
  echo "2026-01-01T00:00:00Z|META|outcome|info|completed: STEP_6" >"$t/logs/$TID-pipeline.log"
  local before
  before=$(REPOS_ROOT="$t/repos" bash -c "source '$LIB_DIR/manifest-read.sh'; ticket_pipeline_merge_state '$TID' '$t/logs'") || true
  out=$(_cancel "$t" "$TID" --reason "superseded" 2>/dev/null) || rc=$?
  local state state_rc=0 done_rc=0 dep_blocked
  state=$(REPOS_ROOT="$t/repos" bash -c "source '$LIB_DIR/manifest-read.sh'; ticket_pipeline_merge_state '$TID' '$t/logs'") || state_rc=$?
  REPOS_ROOT="$t/repos" bash -c "source '$LIB_DIR/manifest-read.sh'; ticket_pipeline_terminal_done '$TID' '$t/logs'" || done_rc=$?
  dep_blocked=$(jq -c '.blocked_by' "$(_manifest "$t" TEST-8)")
  rm -rf "$t"
  [ "$rc" -eq 0 ] && [ "$before" = "no-pr" ] && [ "$state" = "cancelled" ] && [ "$state_rc" -eq 1 ] &&
    [ "$done_rc" -ne 0 ] && [ "$dep_blocked" = "[\"$TID\"]" ] &&
    grep -q '^blocked_dependents=TEST-8$' <<<"$out"
}

# ── Linear config preflight ──────────────────────────────────────────────────
# The new trigger names a Canceled state. The preflight must pass on a board
# that spells its cancelled column differently (resolved by state type), or
# every /ticket-auto run on that board would stop at the preflight.

_validate_with_states() {
  # _validate_with_states <extra-states-json>  → exit code of the validator
  local extra="$1" t rc=0
  t=$(mktemp -d)
  mkdir -p "$t/lib" "$t/sentinel"
  local states labels
  states=$(jq -c --argjson x "$extra" '
    [(.triggers | to_entries[] | .value | (.from, .to) | select(. != null)
       | if type == "array" then .[] else . end), (.well_known_states[]? // empty)]
    | unique | map(select(. != "Canceled")) | to_entries
    | map({id: ("s-" + (.key | tostring)), name: .value, type: "started"}) + $x' "$WF")
  labels=$(jq -c '[(.triggers | to_entries[] | .value | (.adds[]?, .removes[]?)), (.well_known_labels[]? // empty)]
    | unique | to_entries | map({id: ("l-" + (.key | tostring)), name: .value})' "$WF")
  cat >"$t/lib/linear-api.sh" <<STUBEOF
check_api_key() { return 0; }
linear_graphql() { echo '{"data":{"teams":{"nodes":[{"id":"team-1","name":"Test"}]}}}'; }
get_team() { echo '{"states":$states,"labels":$labels}'; }
_plog() { :; }
STUBEOF
  env -u LOG_FILE -u TAP_LOG CLAUDE_SKILLS_LIB="$t/lib" SENTINEL_DIR="$t/sentinel" \
    bash "$PLUGIN_DIR/skills/ticket-flow/validate-linear-config.sh" >/dev/null 2>&1 || rc=$?
  rm -rf "$t"
  return "$rc"
}

test_preflight_accepts_cancelled_column_by_name_or_type() {
  _validate_with_states '[{"id":"s-c","name":"Canceled","type":"canceled"}]' || return 1
  _validate_with_states '[{"id":"s-c","name":"Cancelled","type":"canceled"}]' || return 1
  # No cancelled-type state at all: the column cannot be projected.
  ! _validate_with_states '[{"id":"s-c","name":"Archive","type":"completed"}]'
}

test_ticket_is_cancelled_fails_safe() {
  local t rc1=0 rc2=0 rc3=0
  t=$(_mk)
  _seed "$t" "$TID" Review
  REPOS_ROOT="$t/repos" bash -c "source '$LIB_DIR/manifest-read.sh'; ticket_is_cancelled '$TID'" || rc1=$?
  REPOS_ROOT="$t/repos" bash -c "source '$LIB_DIR/manifest-read.sh'; ticket_is_cancelled TEST-404" || rc2=$?
  env -u REPOS_ROOT bash -c "source '$LIB_DIR/manifest-read.sh'; ticket_is_cancelled '$TID'" || rc3=$?
  rm -rf "$t"
  [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$rc3" -eq 1 ]
}

_run "workflow.json declares the cancel trigger, event and tombstone" test_trigger_declared
_run "cancel from Backlog, Todo, Approve, Ready, Review, UAT and Blocked" test_cancel_from_each_stage
_run "cancel a ticket with no stage yet" test_cancel_ticket_with_no_stage_yet
_run "cancel is refused from Done, nothing written" test_cancel_refused_from_done
_run "cancel requires a non-blank reason" test_cancel_requires_reason
_run "cancel is refused on an epic" test_cancel_refused_on_epic
_run "every other trigger is refused on a cancelled ticket (exit 14), nothing written" test_tombstone_refuses_every_other_trigger
_run "flow-run.sh passes exit 14 through and leaves the log closed" test_flow_run_exit_14_writes_no_log_line
_run "flow.sh repeat: state unchanged, rev and event advance" test_flow_repeat_keeps_state_and_advances_rev
_run "ticket-cancel repeat is a no-op" test_actuator_repeat_is_a_noop
_run "ticket-cancel repeat completes a missing log record" test_actuator_repeat_completes_a_missing_log_record
_run "a fenced-out generation cannot cancel" test_fenced_out_generation_refused
_run "the current generation and an operator can cancel a fenced ticket" test_current_generation_and_operator_allowed
_run "ticket-cancel writes META|cancel then META|outcome, outcome last" test_actuator_writes_log_record_outcome_last
_run "ticket-cancel starts a log for a ticket that never ran" test_actuator_creates_log_for_never_run_ticket
_run "ticket-cancel usage, Done and epic refusals write nothing" test_actuator_usage_and_refusals
_run "ticket-cancel refuses under a live worker; --force cancels without killing it" test_actuator_refuses_under_a_live_worker
_run "ticket-cancel ignores a dead registry pid" test_actuator_ignores_a_dead_registry_pid
_run "a cancelled blocker does not release its dependents" test_cancelled_blocker_does_not_release_dependents
_run "Linear preflight accepts the cancelled column by name or by state type" test_preflight_accepts_cancelled_column_by_name_or_type
_run "ticket_is_cancelled is false without evidence" test_ticket_is_cancelled_fails_safe

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
