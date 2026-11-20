#!/usr/bin/env bash
# test-regression-risk.sh — the Regression Risk gate and its one actuator
# (GitHub #771): lib/regression-risk.sh (fingerprint, check),
# lib/regression-ack.sh (the operator script) and manifest-write.sh's
# set_ticket_regression_ack.
# Usage: bash test-regression-risk.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
RISK_SH="$LIB_DIR/regression-risk.sh"
ACK_SH="$LIB_DIR/regression-ack.sh"
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

_manifest() { echo "$1/repos/.ticket-auto/initiatives/INIT-1/tickets/$TID/planner/manifest.json"; }

# _mk — a tickets root with a ticket dir, a manifest and an empty pipeline log.
_mk() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/logs" "$t/tickets/${TID}--sample-fix" \
    "$t/repos/.ticket-auto/initiatives/_index" \
    "$t/repos/.ticket-auto/initiatives/INIT-1/tickets/$TID/planner"
  echo "INIT-1" >"$t/repos/.ticket-auto/initiatives/_index/${TID}.initiative"
  echo '{"type":"bug","initiative":"INIT-1","blocked_by":[],"dispatch":false,"stage":"Ready","approved":true,"approval_provenance":"human"}' >"$(_manifest "$t")"
  : >"$t/logs/${TID}-pipeline.log"
  echo "$t"
}

_notes() { echo "$1/tickets/${TID}--sample-fix/notes.md"; }

# _write_notes <tmp> <status|none> [detail] — notes.md with (or without) the section.
_write_notes() {
  local t="$1" status="$2" detail="${3:-prior fix guards the null case}"
  {
    echo "# Notes"
    echo
    echo "## Prior Art"
    echo "- TEST-3 [local-ticket]"
    if [ "$status" != "none" ]; then
      echo
      echo "## ⚠️ Regression Risk"
      echo
      echo "| Plan file | Prior art | Verdict | Detail |"
      echo "|-----------|-----------|---------|--------|"
      echo "| \`src/a.ts\` | TEST-3 [local-ticket] | CONFLICT | ${detail} |"
      echo
      echo "**Status:** ${status}"
      echo "→ A person acknowledges this from a terminal."
    fi
    echo
    echo "## Session Log"
    echo "- started"
  } >"$(_notes "$t")"
}

# _env <tmp> — the environment of a person at a terminal.
_env() {
  local t="$1"
  shift
  env -u CLAUDE_CODE_SESSION_ID -u FLEET_WORKER_PID -u FLEET_GENERATION -u TAP_LOG \
    -u TICKET_ID FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none CLAUDE_SKILLS_LIB="$LIB_DIR" \
    REPOS_ROOT="$t/repos" FLEET_PIPELINE_LOG_DIR="$t/logs" LOG_FILE="$t/logs/${TID}-pipeline.log" \
    HB_LOG_FILE= TICKET_ACK_BY="Test Operator" "$@"
}
_check() {
  local t="$1"
  _env "$t" bash "$RISK_SH" check "$TID" "$(_notes "$t")"
}
_ack() {
  local t="$1"
  shift
  _env "$t" bash "$ACK_SH" "$TID" --notes "$(_notes "$t")" "$@"
}
_id() { _env "$1" bash "$RISK_SH" fingerprint "$(_notes "$1")" | cut -c1-12; }
_events() {
  local f="$1/logs/${TID}-outbox.jsonl"
  [ -f "$f" ] && jq -c --arg e "$2" 'select(.event == $e)' "$f" | wc -l | tr -d ' ' || echo 0
}
_ack_field() { jq -r --arg f "$2" '.regression_ack[$f] // ""' "$(_manifest "$1")"; }

# ── gate ─────────────────────────────────────────────────────────────────────

test_no_section_is_clear() {
  local t out rc=0
  t=$(_mk)
  _write_notes "$t" none
  out=$(_check "$t") || rc=$?
  [ "$rc" -eq 0 ] || return 1
  grep -qx 'REGRESSION_RISK_GATE=clear' <<<"$out" || return 1
  [ ! -s "$t/logs/${TID}-pipeline.log" ]
}

test_unacknowledged_holds() {
  local t out rc=0
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  out=$(_check "$t") || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "rc=$rc" >&2
    return 1
  }
  grep -qx 'REGRESSION_RISK_GATE=hold' <<<"$out" || return 1
  grep -qx 'REGRESSION_RISK_REASON=unacknowledged' <<<"$out" || return 1
  grep -q 'regression-ack.sh TEST-7' <<<"$out" || return 1
  grep -q '|META|gate-stop|fail|REGRESSION_RISK_UNACKNOWLEDGED — reason=unacknowledged; risk=' "$t/logs/${TID}-pipeline.log" || return 1
  [ "$(_events "$t" gate-held)" = "1" ] || return 1
  jq -e 'select(.event == "gate-held") | .data.gate == "regression-risk" and .data.reason == "regression-risk-unacknowledged"' \
    "$t/logs/${TID}-outbox.jsonl" >/dev/null
}

# The retired acknowledgement: a hand edit of notes.md clears nothing.
test_hand_edit_does_not_clear() {
  local t out rc=0
  t=$(_mk)
  _write_notes "$t" ACKNOWLEDGED
  out=$(_check "$t") || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "a hand-edited ACKNOWLEDGED status passed the gate (rc=$rc)" >&2
    return 1
  }
  grep -qx 'REGRESSION_RISK_REASON=hand-edit' <<<"$out" || return 1
  grep -q 'reason=hand-edit' "$t/logs/${TID}-pipeline.log"
}

# Removing the status line, or the whole instruction, is still not an ack.
test_removed_status_does_not_clear() {
  local t rc=0
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  sed -i '/^\*\*Status:\*\*/d; /^→/d' "$(_notes "$t")"
  _check "$t" >/dev/null || rc=$?
  [ "$rc" -eq 1 ]
}

test_status_edit_keeps_fingerprint() {
  local t a b
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  a=$(_id "$t")
  _write_notes "$t" ACKNOWLEDGED
  b=$(_id "$t")
  [ -n "$a" ] && [ "$a" = "$b" ] || return 1
  _write_notes "$t" UNACKNOWLEDGED "a different risk"
  [ "$(_id "$t")" != "$a" ]
}

test_hold_event_once_per_risk() {
  local t
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  _check "$t" >/dev/null || true
  _check "$t" >/dev/null || true
  [ "$(_events "$t" gate-held)" = "1" ]
}

# ── actuator ─────────────────────────────────────────────────────────────────

test_show_acknowledges_nothing() {
  local t out rc=0
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  out=$(_ack "$t") || rc=$?
  [ "$rc" -eq 0 ] || return 1
  grep -qx "risk=$(_id "$t")" <<<"$out" || return 1
  grep -qx 'acknowledged=false' <<<"$out" || return 1
  grep -q 'CONFLICT' <<<"$out" || return 1
  [ -z "$(_ack_field "$t" risk)" ] || return 1
  rc=0
  _check "$t" >/dev/null || rc=$?
  [ "$rc" -eq 1 ]
}

test_ack_clears_and_records_provenance() {
  local t out rc=0 before
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  before=$(cat "$(_notes "$t")")
  out=$(_ack "$t" --risk "$(_id "$t")" --note "prior guard is kept") || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "ack rc=$rc" >&2
    return 1
  }
  grep -qx 'acknowledged=true' <<<"$out" || return 1
  grep -qx 'already_acknowledged=false' <<<"$out" || return 1
  grep -qx 'provenance=human' <<<"$out" || return 1
  [ "$(_ack_field "$t" provenance)" = "human" ] || return 1
  [ "$(_ack_field "$t" by)" = "Test Operator" ] || return 1
  [ "$(_ack_field "$t" note)" = "prior guard is kept" ] || return 1
  [[ "$(_ack_field "$t" at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || return 1
  [[ "$(_ack_field "$t" risk)" =~ ^[0-9a-f]{64}$ ]] || return 1
  # notes.md is never edited, and the approval fact is untouched.
  [ "$(cat "$(_notes "$t")")" = "$before" ] || return 1
  jq -e '.approved == true and .stage == "Ready"' "$(_manifest "$t")" >/dev/null || return 1
  [ "$(_events "$t" gate-released)" = "1" ] || return 1
  jq -e 'select(.event == "gate-released") | .data.provenance == "human" and .data.gate == "regression-risk"' \
    "$t/logs/${TID}-outbox.jsonl" >/dev/null || return 1
  # The ack itself writes no pipeline-log line; the gate logs it on its pass.
  [ ! -s "$t/logs/${TID}-pipeline.log" ] || return 1
  out=$(_check "$t") || return 1
  grep -qx 'REGRESSION_RISK_GATE=pass' <<<"$out" || return 1
  grep -q '|IMPLEMENT|regression-risk|done|acknowledged: risk=.*; provenance=human; by=Test Operator; at=' "$t/logs/${TID}-pipeline.log"
}

test_repeat_ack_is_noop() {
  local t out id at
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  id=$(_id "$t")
  _ack "$t" --risk "$id" >/dev/null
  at=$(_ack_field "$t" at)
  jq -c '.regression_ack.at = "2001-01-01T00:00:00Z"' "$(_manifest "$t")" >"$t/m" && mv "$t/m" "$(_manifest "$t")"
  out=$(TICKET_ACK_BY_IGNORED=1 _ack "$t" --risk "$id" --note "again")
  grep -qx 'already_acknowledged=true' <<<"$out" || return 1
  [ "$(_ack_field "$t" at)" = "2001-01-01T00:00:00Z" ] || return 1
  [ -z "$(_ack_field "$t" note)" ] || return 1
  [ -n "$at" ] || return 1
  [ "$(_events "$t" gate-released)" = "1" ]
}

test_wrong_risk_id_refused() {
  local t rc=0
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  _ack "$t" --risk 000000000000 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 6 ] || return 1
  rc=0
  _ack "$t" --risk abc >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 6 ] || return 1
  [ -z "$(_ack_field "$t" risk)" ]
}

test_no_section_nothing_to_ack() {
  local t rc=0
  t=$(_mk)
  _write_notes "$t" none
  _ack "$t" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 5 ]
}

# A changed or new risk after a re-appraisal needs a new acknowledgement.
test_changed_risk_reholds() {
  local t out rc=0 old
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  old=$(_id "$t")
  _ack "$t" --risk "$old" >/dev/null
  _check "$t" >/dev/null || return 1
  _write_notes "$t" UNACKNOWLEDGED "the plan now removes the prior guard"
  out=$(_check "$t") || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "a changed risk passed on the old acknowledgement" >&2
    return 1
  }
  grep -qx 'REGRESSION_RISK_REASON=risk-changed' <<<"$out" || return 1
  # The stale id no longer acknowledges; the new one does.
  rc=0
  _ack "$t" --risk "$old" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 6 ] || return 1
  _ack "$t" --risk "$(_id "$t")" >/dev/null || return 1
  _check "$t" >/dev/null || return 1
  [ "$(_events "$t" gate-released)" = "2" ]
}

# ── an agent cannot clear the gate for itself ────────────────────────────────

_agent_refused() {
  local var="$1" t rc=0
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  _env "$t" env "$var=1" bash "$ACK_SH" "$TID" --notes "$(_notes "$t")" --risk "$(_id "$t")" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 4 ] || {
    echo "$var: rc=$rc" >&2
    return 1
  }
  [ -z "$(_ack_field "$t" risk)" ] || return 1
  [ "$(_events "$t" gate-released)" = "0" ] || return 1
  # Show mode is refused too: an agent has no reason to run this script.
  rc=0
  _env "$t" env "$var=1" bash "$ACK_SH" "$TID" --notes "$(_notes "$t")" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 4 ]
}
test_agent_session_refused() { _agent_refused CLAUDE_CODE_SESSION_ID; }
test_fleet_worker_refused() { _agent_refused FLEET_WORKER_PID && _agent_refused FLEET_GENERATION; }

test_writer_refuses_agent_and_non_human() {
  local t rc=0 sha
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  sha=$(_env "$t" bash "$RISK_SH" fingerprint "$(_notes "$t")")
  _env "$t" env CLAUDE_CODE_SESSION_ID=abc bash -c \
    "source '$LIB_DIR/manifest-write.sh'; set_ticket_regression_ack $TID $sha human someone" 2>/dev/null || rc=$?
  [ "$rc" -eq 4 ] || return 1
  rc=0
  _env "$t" bash -c \
    "source '$LIB_DIR/manifest-write.sh'; set_ticket_regression_ack $TID $sha policy someone" 2>/dev/null || rc=$?
  [ "$rc" -eq 3 ] || return 1
  rc=0
  _env "$t" bash -c \
    "source '$LIB_DIR/manifest-write.sh'; set_ticket_regression_ack $TID $sha agent someone" 2>/dev/null || rc=$?
  [ "$rc" -eq 3 ] || return 1
  [ -z "$(_ack_field "$t" risk)" ]
}

# A fact that is not a human's (written around the writer) does not pass.
test_non_human_fact_holds() {
  local t out rc=0 sha
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  sha=$(_env "$t" bash "$RISK_SH" fingerprint "$(_notes "$t")")
  for prov in policy agent ""; do
    jq -c --arg r "$sha" --arg p "$prov" \
      '.regression_ack = {risk: $r, provenance: $p, by: "x", at: "2026-01-01T00:00:00Z"}' \
      "$(_manifest "$t")" >"$t/m" && mv "$t/m" "$(_manifest "$t")"
    rc=0
    out=$(_check "$t") || rc=$?
    [ "$rc" -eq 1 ] || {
      echo "provenance '$prov' passed the gate" >&2
      return 1
    }
    grep -qx 'REGRESSION_RISK_REASON=provenance' <<<"$out" || return 1
  done
}

# plog.sh (the agent-facing log writer) cannot produce a pass: the gate reads
# the manifest only.
test_log_line_does_not_clear() {
  local t rc=0
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  echo "2026-01-01T00:00:00Z|IMPLEMENT|regression-risk|done|acknowledged: risk=x; provenance=human; by=y; at=z" >>"$t/logs/${TID}-pipeline.log"
  _check "$t" >/dev/null || rc=$?
  [ "$rc" -eq 1 ]
}

# ── skill prose ──────────────────────────────────────────────────────────────

test_skills_call_the_gate_and_drop_the_hand_edit() {
  local impl="$PLUGIN_DIR/skills/ticket-implement/SKILL.md" exec="$PLUGIN_DIR/skills/ticket-appraise-exec/SKILL.md"
  grep -q 'lib/regression-risk.sh check' "$impl" || return 1
  ! grep -q 'Status:\*\* ACKNOWLEDGED' "$impl" || return 1
  ! grep -qi 'change Status to' "$impl" "$exec" || return 1
  ! grep -q 'Edit this file and change Status' "$exec" || return 1
  grep -q 'regression-ack.sh' "$exec"
}

_run "no Regression Risk section: clear, nothing logged" test_no_section_is_clear
_run "unacknowledged risk holds with a gate-stop and one gate-held event" test_unacknowledged_holds
_run "a hand-edited ACKNOWLEDGED status no longer clears the gate" test_hand_edit_does_not_clear
_run "deleting the status line does not clear the gate" test_removed_status_does_not_clear
_run "the status line is not part of the fingerprint; the table is" test_status_edit_keeps_fingerprint
_run "a repeated hold emits gate-held once per risk" test_hold_event_once_per_risk
_run "show mode prints the risk and acknowledges nothing" test_show_acknowledges_nothing
_run "the actuator clears the gate and records provenance, who and when" test_ack_clears_and_records_provenance
_run "a repeat acknowledgement is a no-op" test_repeat_ack_is_noop
_run "a wrong or short risk id is refused" test_wrong_risk_id_refused
_run "no section: nothing to acknowledge (exit 5)" test_no_section_nothing_to_ack
_run "a changed risk re-holds until it is acknowledged again" test_changed_risk_reholds
_run "the actuator refuses an agent session" test_agent_session_refused
_run "the actuator refuses a fleetd worker" test_fleet_worker_refused
_run "the manifest writer refuses agent context and non-human provenance" test_writer_refuses_agent_and_non_human
_run "a fact whose provenance is not human does not pass" test_non_human_fact_holds
_run "a pipeline-log line does not clear the gate" test_log_line_does_not_clear
_run "skill prose calls the gate script and no longer tells anyone to edit the status" test_skills_call_the_gate_and_drop_the_hand_edit

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
