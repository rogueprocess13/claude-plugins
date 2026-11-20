#!/usr/bin/env bash
# test-initial-stage.sh — flow.sh's warn-only from-check on a ticket with no
# recorded stage (GitHub #766).
#
# New manifests carry no `stage` field, and a ticket run by hand may have no
# manifest at all. The from-check compared that empty stage with the trigger's
# `from`, so the first appraise-start of every ticket logged
# "ILLEGAL_TRANSITION ... from <none>". It now reads an absent stage as
# workflow.json's `initial_state`.
#
# Usage: bash test-initial-stage.sh [filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FLOW_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FLOW_SH="$FLOW_DIR/flow.sh"
FILTER="${1:-}"

PASS=0
FAIL=0
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

_run() {
  local name="$1" err
  [ -z "$FILTER" ] || [[ "$name" == *"$FILTER"* ]] || return 0
  err=$(mktemp)
  if "$name" 2>"$err"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    sed 's/^/    /' "$err"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$err"
}

# _ws — a fresh workspace dir with logs/ and repos/.
_ws() {
  local d
  d=$(mktemp -d -p "$TMP_ROOT")
  mkdir -p "$d/logs" "$d/repos"
  echo "$d"
}

_manifest_path() { # <ws> <tid> [init]
  echo "$1/repos/.ticket-auto/initiatives/${3:-INIT-1}/tickets/$2/planner/manifest.json"
}

# _seed <ws> <tid> [stage] [init] — a planner-shaped ticket manifest. With no
# stage argument the field is absent, as write_ticket_manifest leaves it.
_seed() {
  local ws="$1" tid="$2" stage="${3:-}" init="${4:-INIT-1}" m
  m=$(_manifest_path "$ws" "$tid" "$init")
  mkdir -p "$(dirname "$m")" "$ws/repos/.ticket-auto/initiatives/_index"
  echo "$init" >"$ws/repos/.ticket-auto/initiatives/_index/${tid}.initiative"
  jq -n --arg init "$init" --arg stage "$stage" \
    '{type: "bug", initiative: $init, blocked_by: [], dispatch: false}
     + (if $stage == "" then {} else {stage: $stage} end)' >"$m"
}

# _seed_epic <ws> <epic> [stage]
_seed_epic() {
  local ws="$1" epic="$2" stage="${3:-}"
  local m="$ws/repos/.ticket-auto/initiatives/$epic/epic/manifest.json"
  mkdir -p "$(dirname "$m")"
  jq -n --arg stage "$stage" \
    '{branch: "epic/demo", uat_policy: "epic", merge_policy: "manual", children: [], dispatch: true}
     + (if $stage == "" then {} else {stage: $stage} end)' >"$m"
}

# _flow <ws> <tid> <trigger> [args...] — FLOW_SH_UNDER_TEST overrides the script.
_flow() {
  local ws="$1" tid="$2" trigger="$3"
  shift 3
  env -u FLEET_GENERATION -u FLEET_WORKER_PID \
    FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none \
    CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" LOG_FILE="$ws/logs/${tid}-pipeline.log" \
    HB_LOG_FILE="$ws/logs/${tid}-heartbeat.log" \
    TICKET_FLOW_LOCK_DIR="$ws/logs" REPOS_ROOT="$ws/repos" \
    FLEET_PIPELINE_LOG_DIR="$ws/logs" \
    "${FLOW_SH_UNDER_TEST:-$FLOW_SH}" "$tid" "$trigger" "$@"
}

_illegal_lines() { # <ws> <tid>
  grep 'ILLEGAL_TRANSITION' "$1/logs/$2-pipeline.log" 2>/dev/null || true
}

_stage() { # <manifest>
  jq -r '.stage // empty' "$1" 2>/dev/null
}

# ── workflow.json declares the initial state ────────────────────────────────
test_workflow_declares_initial_state() {
  local wf="$FLOW_DIR/workflow.json" init
  init=$(jq -r '.initial_state // empty' "$wf")
  [ -n "$init" ] || {
    echo "workflow.json has no initial_state" >&2
    return 1
  }
  # It must be a state some trigger can leave, or the stand-in matches nothing.
  jq -e --arg s "$init" \
    '[.triggers[].from | if type == "array" then .[] else . end] | index($s) != null' \
    "$wf" >/dev/null || {
    echo "initial_state '$init' is in no trigger's from" >&2
    return 1
  }
}

# ── The issue's case: planner manifest with no stage, first appraise-start ──
test_fresh_manifest_appraise_start_is_legal() {
  local ws m rc=0
  ws=$(_ws)
  _seed "$ws" TEST-1
  m=$(_manifest_path "$ws" TEST-1)
  _flow "$ws" TEST-1 appraise-start --data complexity=simple >/dev/null || rc=$?
  local illegal hb_warn stage rev
  illegal=$(_illegal_lines "$ws" TEST-1)
  hb_warn=$(grep -c 'ILLEGAL_TRANSITION' "$ws/logs/TEST-1-heartbeat.log" 2>/dev/null || true)
  stage=$(_stage "$m")
  rev=$(jq -r '.rev // 0' "$m")
  if [ "$rc" -ne 0 ] || [ -n "$illegal" ] || [ "${hb_warn:-0}" -ne 0 ] ||
    [ "$stage" != "Todo" ] || [ "$rev" != "1" ]; then
    echo "rc=$rc stage=$stage rev=$rev hb_warn=$hb_warn illegal=$illegal" >&2
    return 1
  fi
  # Exactly one appraise-started fact.
  local n
  n=$(jq -c 'select(.event == "appraise-started")' "$ws/logs/TEST-1-outbox.jsonl" | wc -l)
  [ "$n" -eq 1 ] || {
    echo "appraise-started records: $n" >&2
    return 1
  }
}

# ── No manifest at all (a ticket run by hand) ───────────────────────────────
test_no_manifest_appraise_start_is_legal() {
  local ws rc=0
  ws=$(_ws)
  _flow "$ws" TEST-2 appraise-start --data complexity=simple >/dev/null || rc=$?
  local illegal stage
  illegal=$(_illegal_lines "$ws" TEST-2)
  stage=$(_stage "$(_manifest_path "$ws" TEST-2 _adhoc)")
  if [ "$rc" -ne 0 ] || [ -n "$illegal" ] || [ "$stage" != "Todo" ]; then
    echo "rc=$rc stage=$stage illegal=$illegal" >&2
    return 1
  fi
}

# ── A real, wrong stage still warns, with its real name ─────────────────────
test_wrong_real_stage_still_warns() {
  local ws rc=0
  ws=$(_ws)
  _seed "$ws" TEST-3 Review
  _flow "$ws" TEST-3 appraise-start --data complexity=simple >/dev/null || rc=$?
  local illegal hb
  illegal=$(_illegal_lines "$ws" TEST-3)
  hb=$(grep 'ILLEGAL_TRANSITION' "$ws/logs/TEST-3-heartbeat.log" 2>/dev/null | tail -1 | cut -d'|' -f6-)
  if [ "$rc" -ne 0 ] || [ "$(echo "$illegal" | grep -c .)" -ne 1 ] ||
    [[ "$illegal" != *"attempted appraise-start from Review, expected from Backlog,Todo"* ]] ||
    [ "$(echo "$hb" | jq -r '.actual' 2>/dev/null)" != "Review" ]; then
    echo "rc=$rc illegal=$illegal hb=$hb" >&2
    return 1
  fi
}

# ── A recorded initial stage behaves like an absent one ─────────────────────
test_recorded_initial_stage_is_legal() {
  local ws rc=0
  ws=$(_ws)
  _seed "$ws" TEST-4 Backlog
  _flow "$ws" TEST-4 appraise-start --data complexity=simple >/dev/null || rc=$?
  [ "$rc" -eq 0 ] && [ -z "$(_illegal_lines "$ws" TEST-4)" ] &&
    [ "$(_stage "$(_manifest_path "$ws" TEST-4)")" = "Todo" ]
}

# ── Another trigger from a no-stage manifest: still illegal, never <none> ───
# implement-complete expects Ready. A ticket nothing has moved is not in Ready,
# so the warning stays; it names the initial state and says the stage was not
# recorded. The transition is still applied (the check is warn-only).
test_no_stage_other_trigger_warns_with_initial_state() {
  local ws rc=0
  ws=$(_ws)
  _seed "$ws" TEST-5
  _flow "$ws" TEST-5 implement-complete >/dev/null || rc=$?
  local illegal stage
  illegal=$(_illegal_lines "$ws" TEST-5)
  stage=$(_stage "$(_manifest_path "$ws" TEST-5)")
  if [ "$rc" -ne 0 ] || [[ "$illegal" == *"<none>"* ]] ||
    [[ "$illegal" != *"attempted implement-complete from Backlog (no stage recorded), expected from Ready"* ]] ||
    [ "$stage" != "Review" ]; then
    echo "rc=$rc stage=$stage illegal=$illegal" >&2
    return 1
  fi
}

# ── A trigger with no `from` and no `to` leaves "no stage" as it is ─────────
# The stand-in is for the check only: needs-info must not write the initial
# state into the manifest (manifest-backfill.sh reads a present stage as
# "already backfilled"), and the next appraise-start is still legal.
test_no_stage_null_trigger_keeps_stage_absent() {
  local ws m rc=0
  ws=$(_ws)
  _seed "$ws" TEST-6
  m=$(_manifest_path "$ws" TEST-6)
  _flow "$ws" TEST-6 needs-info >/dev/null || rc=$?
  local has_stage
  has_stage=$(jq -r 'if (.stage // "") == "" then "no" else "yes" end' "$m")
  if [ "$rc" -ne 0 ] || [ "$has_stage" != "no" ] || [ -n "$(_illegal_lines "$ws" TEST-6)" ]; then
    echo "rc=$rc has_stage=$has_stage stage=$(_stage "$m") illegal=$(_illegal_lines "$ws" TEST-6)" >&2
    return 1
  fi
  _flow "$ws" TEST-6 appraise-start --data complexity=simple >/dev/null || rc=$?
  [ "$rc" -eq 0 ] && [ -z "$(_illegal_lines "$ws" TEST-6)" ] && [ "$(_stage "$m")" = "Todo" ]
}

# ── Dry run reports the manifest's own (empty) stage, not the stand-in ──────
test_dry_run_current_stage_stays_empty() {
  local ws out
  ws=$(_ws)
  _seed "$ws" TEST-7
  out=$(_flow "$ws" TEST-7 appraise-start --dry-run 2>/dev/null)
  [ "$(echo "$out" | jq -r '.current.stage')" = "" ] &&
    [ "$(echo "$out" | jq -r '.computed.stage')" = "Todo" ]
}

# ── Epics: a new epic manifest has no stage either ──────────────────────────
test_fresh_epic_integration_open_is_legal() {
  local ws rc=0
  ws=$(_ws)
  _seed_epic "$ws" EPIC-1
  _flow "$ws" EPIC-1 epic-integration-open >/dev/null || rc=$?
  local illegal stage
  illegal=$(_illegal_lines "$ws" EPIC-1)
  stage=$(_stage "$ws/repos/.ticket-auto/initiatives/EPIC-1/epic/manifest.json")
  if [ "$rc" -ne 0 ] || [ -n "$illegal" ] || [ "$stage" != "Review" ]; then
    echo "rc=$rc stage=$stage illegal=$illegal" >&2
    return 1
  fi
}

# ── The name comes from workflow.json, not from flow.sh ─────────────────────
# A copy of the flow dir whose workflow.json declares another initial state
# (and lets appraise-start leave it) must follow that file.
test_initial_state_is_read_from_workflow_json() {
  local ws copy rc=0
  ws=$(_ws)
  copy="$ws/flow"
  mkdir -p "$copy"
  cp "$FLOW_DIR"/*.sh "$FLOW_DIR"/*.json "$copy/"
  jq '.initial_state = "Triage" | .triggers["appraise-start"].from = ["Triage", "Todo"]' \
    "$FLOW_DIR/workflow.json" >"$copy/workflow.json"
  _seed "$ws" TEST-8
  FLOW_SH_UNDER_TEST="$copy/flow.sh" _flow "$ws" TEST-8 appraise-start >/dev/null || rc=$?
  local illegal
  illegal=$(_illegal_lines "$ws" TEST-8)
  if [ "$rc" -ne 0 ] || [ -n "$illegal" ]; then
    echo "declared Triage: rc=$rc illegal=$illegal" >&2
    return 1
  fi
  # With no initial_state declared there is no stand-in: the old warning stays.
  jq 'del(.initial_state)' "$FLOW_DIR/workflow.json" >"$copy/workflow.json"
  _seed "$ws" TEST-9
  rc=0
  FLOW_SH_UNDER_TEST="$copy/flow.sh" _flow "$ws" TEST-9 appraise-start >/dev/null || rc=$?
  illegal=$(_illegal_lines "$ws" TEST-9)
  if [ "$rc" -ne 0 ] || [[ "$illegal" != *"from <none>, expected from Backlog,Todo"* ]]; then
    echo "undeclared: rc=$rc illegal=$illegal" >&2
    return 1
  fi
}

for t in \
  test_workflow_declares_initial_state \
  test_fresh_manifest_appraise_start_is_legal \
  test_no_manifest_appraise_start_is_legal \
  test_wrong_real_stage_still_warns \
  test_recorded_initial_stage_is_legal \
  test_no_stage_other_trigger_warns_with_initial_state \
  test_no_stage_null_trigger_keeps_stage_absent \
  test_dry_run_current_stage_stays_empty \
  test_fresh_epic_integration_open_is_legal \
  test_initial_state_is_read_from_workflow_json; do
  _run "$t"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
