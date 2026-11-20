#!/usr/bin/env bash
# test-regression-risk.sh — the Regression Risk gate and its one actuator
# (GitHub #771): lib/regression-risk.sh (fingerprint, record, check),
# lib/regression-ack.sh (the operator script) and manifest-write.sh's
# set_ticket_regression_risk / set_ticket_regression_ack.
# The actuator needs a terminal, so the tests that acknowledge run it under a
# pseudo-terminal (python3 pty) and type the answer there.
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

# ── a pseudo-terminal runner ─────────────────────────────────────────────────
# pty_run.py <answer> <cmd...>: runs cmd with a controlling terminal, types
# <answer> + newline once the prompt shows, prints everything the terminal
# showed (CR stripped) and exits with cmd's status.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat >"$WORK/pty_run.py" <<'PY'
import os, pty, select, sys, time

answer, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
out, sent, deadline = b"", False, time.time() + 30
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if fd in r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    if not sent and b"anything else aborts" in out:
        os.write(fd, answer.encode() + b"\n")
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace").replace("\r", ""))
sys.exit(os.waitstatus_to_exitcode(status))
PY

# ── fixtures ─────────────────────────────────────────────────────────────────

_manifest() { echo "$1/repos/.ticket-auto/initiatives/INIT-1/tickets/$TID/planner/manifest.json"; }

# _mk — a tickets root with a ticket dir, a manifest and an empty pipeline log.
_mk() {
  local t
  t=$(mktemp -d -p "$WORK")
  mkdir -p "$t/logs" "$t/tickets/${TID}--sample-fix" \
    "$t/repos/.ticket-auto/initiatives/_index" \
    "$t/repos/.ticket-auto/initiatives/INIT-1/tickets/$TID/planner"
  echo "INIT-1" >"$t/repos/.ticket-auto/initiatives/_index/${TID}.initiative"
  echo '{"type":"bug","initiative":"INIT-1","blocked_by":[],"dispatch":false,"stage":"Ready","approved":true,"approval_provenance":"human"}' >"$(_manifest "$t")"
  : >"$t/logs/${TID}-pipeline.log"
  echo "$t"
}

_notes() { echo "$1/tickets/${TID}--sample-fix/notes.md"; }

# _write_notes <tmp> <status|none> [detail] — notes.md with (or without) the
# section, exactly as ticket-appraise-exec writes it (plus the old status line).
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
      echo "→ A person acknowledges this from a terminal: \`bash ~/.claude/skills/lib/regression-ack.sh ${TID}\`. An edit here does not."
    fi
    echo
    echo "## Session Log"
    echo "- started"
  } >"$(_notes "$t")"
}

# _env <tmp> cmd... — the environment of a person (no agent variables).
_env() {
  local t="$1"
  shift
  env -u CLAUDE_CODE_SESSION_ID -u FLEET_WORKER_PID -u FLEET_GENERATION -u TAP_LOG \
    -u TICKET_ID FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none CLAUDE_SKILLS_LIB="$LIB_DIR" \
    REPOS_ROOT="$t/repos" FLEET_PIPELINE_LOG_DIR="$t/logs" LOG_FILE="$t/logs/${TID}-pipeline.log" \
    HB_LOG_FILE= TICKET_ACK_BY="Test Operator" "$@"
}
_check() { _env "$1" bash "$RISK_SH" check "$TID" "$(_notes "$1")"; }
_record() { _env "$1" bash "$RISK_SH" record "$TID" "$(_notes "$1")"; }
# _ack <tmp> <typed answer> [args...] — the actuator at a terminal.
_ack() {
  local t="$1" answer="$2"
  shift 2
  _env "$t" python3 "$WORK/pty_run.py" "$answer" bash "$ACK_SH" "$TID" --notes "$(_notes "$t")" "$@"
}
_sha() { _env "$1" bash "$RISK_SH" fingerprint "$(_notes "$1")"; }
_id() { _sha "$1" | cut -c1-12; }
_events() {
  local f="$1/logs/${TID}-outbox.jsonl"
  [ -f "$f" ] && jq -c --arg e "$2" 'select(.event == $e)' "$f" | wc -l | tr -d ' ' || echo 0
}
_ack_field() { jq -r --arg f "$2" '(.regression_acks // [])[-1][$f] // ""' "$(_manifest "$1")"; }
_recorded() { jq -r '(.regression_risks // [])[-1].risk // ""' "$(_manifest "$1")"; }
_expect_rc() {
  local want="$1" rc=0
  shift
  "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq "$want" ] || {
    echo "expected exit $want, got $rc: $*" >&2
    return 1
  }
}

# ── gate ─────────────────────────────────────────────────────────────────────

test_no_section_is_clear() {
  local t out rc=0
  t=$(_mk)
  _write_notes "$t" none
  out=$(_check "$t") || rc=$?
  [ "$rc" -eq 0 ] || return 1
  grep -qx 'REGRESSION_RISK_GATE=clear' <<<"$out" || return 1
  [ ! -s "$t/logs/${TID}-pipeline.log" ] || return 1
  [ -z "$(_recorded "$t")" ]
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
    "$t/logs/${TID}-outbox.jsonl" >/dev/null || return 1
  # Seeing the section records that the risk exists.
  [ "$(_recorded "$t")" = "$(_sha "$t")" ]
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

test_status_edit_keeps_fingerprint() {
  local t a b
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  a=$(_id "$t")
  _write_notes "$t" ACKNOWLEDGED
  b=$(_id "$t")
  [ -n "$a" ] && [ "$a" = "$b" ] || return 1
  sed -i '/^\*\*Status:\*\*/d' "$(_notes "$t")"
  [ "$(_id "$t")" = "$a" ] || return 1
  _write_notes "$t" UNACKNOWLEDGED "a different risk"
  [ "$(_id "$t")" != "$a" ]
}

# Review finding 1: the risk lives in the manifest once recorded. Deleting or
# renaming the section in notes.md (agent-editable) does not clear the gate.
test_section_deleted_after_record_holds() {
  local t out rc=0
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  out=$(_record "$t") || return 1
  grep -q '^REGRESSION_RISK_RECORDED=[0-9a-f]\{12\}$' <<<"$out" || return 1
  _write_notes "$t" none
  out=$(_check "$t") || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "deleting the section cleared the gate (rc=$rc)" >&2
    return 1
  }
  grep -qx 'REGRESSION_RISK_REASON=section-removed' <<<"$out" || return 1
  grep -q 'reason=section-removed' "$t/logs/${TID}-pipeline.log"
}

test_section_renamed_after_record_holds() {
  local t rc=0
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  _record "$t" >/dev/null
  sed -i 's/^## ⚠️ Regression Risk$/## Notes on overlap/' "$(_notes "$t")"
  _check "$t" >/dev/null || rc=$?
  [ "$rc" -eq 1 ]
}

# A section seen only by the gate (never by `record`) is recorded by that
# first check, so a later deletion still holds.
test_section_deleted_after_first_check_holds() {
  local t
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  _expect_rc 1 _check "$t" || return 1
  _write_notes "$t" none
  _expect_rc 1 _check "$t"
}

# Heading level and case do not hide a section.
test_heading_level_and_case() {
  local t a
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  a=$(_sha "$t")
  sed -i 's/^## ⚠️ Regression Risk$/### regression RISK (see below)/' "$(_notes "$t")"
  [ "$(_sha "$t")" = "$a" ] || {
    echo "a level-3, lower-case heading was not read as the section" >&2
    return 1
  }
  _expect_rc 1 _check "$t"
}

# Review finding 2: only the exact boilerplate lines are left out. Risk text
# on a line that merely starts with **Status:** or → is fingerprinted.
test_status_prefixed_text_is_fingerprinted() {
  local t a
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  a=$(_sha "$t")
  sed -i 's/^\*\*Status:\*\* UNACKNOWLEDGED$/**Status:** UNACKNOWLEDGED and the plan also drops the audit log/' "$(_notes "$t")"
  [ "$(_sha "$t")" != "$a" ] || {
    echo "text on a **Status:** line is outside the fingerprint" >&2
    return 1
  }
}

test_arrow_prefixed_text_is_fingerprinted() {
  local t a b
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  a=$(_sha "$t")
  sed -i '/^\*\*Status:\*\*/a → The plan also deletes the retry guard in src/b.ts' "$(_notes "$t")"
  b=$(_sha "$t")
  [ "$b" != "$a" ] || {
    echo "text on a → line is outside the fingerprint" >&2
    return 1
  }
  # The old fixed instruction line is boilerplate too, and only that.
  _write_notes "$t" UNACKNOWLEDGED
  sed -i "s|^→ A person.*|→ Edit this file and change Status to \`ACKNOWLEDGED\` before running \`/ticket-implement ${TID}\`.|" "$(_notes "$t")"
  [ "$(_sha "$t")" = "$a" ]
}

# An acknowledged risk whose section later gains a → line holds again.
test_added_arrow_line_reholds() {
  local t out rc=0
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  _ack "$t" "$(_id "$t")" >/dev/null || return 1
  _check "$t" >/dev/null || return 1
  sed -i '/^\*\*Status:\*\*/a → Also rewrites the null guard the prior fix added' "$(_notes "$t")"
  out=$(_check "$t") || rc=$?
  [ "$rc" -eq 1 ] || return 1
  grep -qx 'REGRESSION_RISK_REASON=risk-changed' <<<"$out"
}

test_hold_event_once_per_risk() {
  local t
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  _check "$t" >/dev/null || true
  _check "$t" >/dev/null || true
  [ "$(_events "$t" gate-held)" = "1" ]
}

test_check_needs_repos_root() {
  local t
  t=$(_mk)
  _write_notes "$t" none
  _expect_rc 2 env -u REPOS_ROOT -u CLAUDE_CODE_SESSION_ID TICKET_TMP_DIR="$t/none" CLAUDE_SKILLS_LIB="$LIB_DIR" \
    bash "$RISK_SH" check "$TID" "$(_notes "$t")"
}

# ── actuator ─────────────────────────────────────────────────────────────────

test_ack_clears_and_records_provenance() {
  local t out rc=0 before
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  before=$(cat "$(_notes "$t")")
  out=$(_ack "$t" "$(_id "$t")" --note "prior guard is kept") || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "ack rc=$rc: $out" >&2
    return 1
  }
  # The person saw the risk before typing.
  grep -q 'CONFLICT' <<<"$out" || return 1
  grep -qx 'acknowledged=true' <<<"$out" || return 1
  grep -qx 'already_acknowledged=false' <<<"$out" || return 1
  grep -qx 'provenance=human' <<<"$out" || return 1
  [ "$(_ack_field "$t" provenance)" = "human" ] || return 1
  [ "$(_ack_field "$t" by)" = "Test Operator" ] || return 1
  [ "$(_ack_field "$t" note)" = "prior guard is kept" ] || return 1
  [[ "$(_ack_field "$t" at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || return 1
  [ "$(_ack_field "$t" risk)" = "$(_sha "$t")" ] || return 1
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

test_wrong_answer_records_nothing() {
  local t
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  _expect_rc 6 _ack "$t" "yes" || return 1
  _expect_rc 6 _ack "$t" "" || return 1
  _expect_rc 6 _ack "$t" "000000000000" || return 1
  [ -z "$(_ack_field "$t" risk)" ] || return 1
  [ "$(_events "$t" gate-released)" = "0" ] || return 1
  _expect_rc 1 _check "$t"
}

test_repeat_ack_is_noop() {
  local t out id
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  id=$(_id "$t")
  _ack "$t" "$id" >/dev/null || return 1
  jq -c '.regression_acks[0].at = "2001-01-01T00:00:00Z"' "$(_manifest "$t")" >"$t/m" && mv "$t/m" "$(_manifest "$t")"
  # No prompt on a repeat: a wrong answer would abort if one were asked.
  out=$(_ack "$t" "not-the-id" --note "again") || return 1
  grep -qx 'already_acknowledged=true' <<<"$out" || return 1
  [ "$(_ack_field "$t" at)" = "2001-01-01T00:00:00Z" ] || return 1
  [ -z "$(_ack_field "$t" note)" ] || return 1
  [ "$(_events "$t" gate-released)" = "1" ]
}

test_no_section_nothing_to_ack() {
  local t
  t=$(_mk)
  _write_notes "$t" none
  _expect_rc 5 _ack "$t" "x"
}

# A changed or new risk after a re-appraisal needs a new acknowledgement.
test_changed_risk_reholds() {
  local t out rc=0 old
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  old=$(_id "$t")
  _ack "$t" "$old" >/dev/null || return 1
  _check "$t" >/dev/null || return 1
  _write_notes "$t" UNACKNOWLEDGED "the plan now removes the prior guard"
  out=$(_check "$t") || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "a changed risk passed on the old acknowledgement" >&2
    return 1
  }
  grep -qx 'REGRESSION_RISK_REASON=risk-changed' <<<"$out" || return 1
  # The stale id no longer acknowledges; the new one does.
  _expect_rc 6 _ack "$t" "$old" || return 1
  _ack "$t" "$(_id "$t")" >/dev/null || return 1
  _check "$t" >/dev/null || return 1
  [ "$(_events "$t" gate-released)" = "2" ]
}

# A removed section is cleared the same way: by a person, for the recorded risk.
test_person_acknowledges_a_removed_section() {
  local t out id
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  _record "$t" >/dev/null
  id=$(_id "$t")
  _write_notes "$t" none
  out=$(_ack "$t" "$id") || return 1
  grep -q 'no longer has a Regression Risk section' <<<"$out" || return 1
  out=$(_check "$t") || return 1
  grep -qx 'REGRESSION_RISK_GATE=pass' <<<"$out"
}

# ── an agent cannot clear the gate for itself ────────────────────────────────

# Review finding 3: with the agent variables unset and no terminal, refused.
# setsid drops the controlling terminal a developer's shell may have.
test_no_tty_refused_even_with_env_unset() {
  local t rc=0 id
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  id=$(_id "$t")
  printf '%s\n' "$id" | _env "$t" setsid -w bash "$ACK_SH" "$TID" --notes "$(_notes "$t")" >/dev/null 2>"$t/err" || rc=$?
  [ "$rc" -eq 4 ] || {
    echo "no terminal: rc=$rc (stdin carried the right id)" >&2
    return 1
  }
  grep -q 'no terminal' "$t/err" || return 1
  [ -z "$(_ack_field "$t" risk)" ] || return 1
  [ "$(_events "$t" gate-released)" = "0" ]
}

# With a terminal, the agent variables still refuse (the second layer).
_agent_refused() {
  local var="$1" t rc=0
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  _env "$t" env "$var=1" python3 "$WORK/pty_run.py" "$(_id "$t")" \
    bash "$ACK_SH" "$TID" --notes "$(_notes "$t")" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 4 ] || {
    echo "$var: rc=$rc" >&2
    return 1
  }
  [ -z "$(_ack_field "$t" risk)" ] || return 1
  [ "$(_events "$t" gate-released)" = "0" ]
}
test_agent_session_refused() { _agent_refused CLAUDE_CODE_SESSION_ID; }
test_fleet_worker_refused() { _agent_refused FLEET_WORKER_PID && _agent_refused FLEET_GENERATION; }

test_no_bypass_flag() {
  local t
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  _expect_rc 2 _env "$t" bash "$ACK_SH" "$TID" --notes "$(_notes "$t")" --risk "$(_id "$t")" || return 1
  _expect_rc 2 _env "$t" bash "$ACK_SH" "$TID" --yes || return 1
  ! grep -qE 'REGRESSION_ACK_(SKIP|FORCE|NO_TTY)|--force|--yes' "$ACK_SH"
}

test_writer_refuses_agent_and_non_human() {
  local t rc=0 sha
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  sha=$(_sha "$t")
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
  local t out rc=0 sha prov
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  sha=$(_sha "$t")
  for prov in policy agent ""; do
    jq -c --arg r "$sha" --arg p "$prov" \
      '.regression_acks = [{risk: $r, provenance: $p, by: "x", at: "2026-01-01T00:00:00Z"}]' \
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
  local t
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  echo "2026-01-01T00:00:00Z|IMPLEMENT|regression-risk|done|acknowledged: risk=x; provenance=human; by=y; at=z" >>"$t/logs/${TID}-pipeline.log"
  _expect_rc 1 _check "$t"
}

# Review round 2, finding 1: the recorded history is append-only and every
# recorded version needs an acknowledgement. Putting an earlier, acknowledged
# text back does not clear a later version nobody acknowledged.
test_revert_to_acked_text_still_holds() {
  local t out rc=0 a b
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  a=$(_sha "$t")
  _ack "$t" "${a:0:12}" >/dev/null || return 1
  _check "$t" >/dev/null || return 1
  _write_notes "$t" UNACKNOWLEDGED "the plan now removes the prior guard"
  b=$(_sha "$t")
  _expect_rc 1 _check "$t" || return 1
  # Back to the acknowledged text.
  _write_notes "$t" UNACKNOWLEDGED
  [ "$(_sha "$t")" = "$a" ] || return 1
  out=$(_check "$t") || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "reverting notes.md to acknowledged text cleared the later risk" >&2
    return 1
  }
  grep -qx 'REGRESSION_RISK_REASON=earlier-risk' <<<"$out" || return 1
  grep -qx "REGRESSION_RISK_ID=${b:0:12}" <<<"$out" || return 1
  # Both versions stay on record, in order; nothing was replaced.
  [ "$(jq -c '[.regression_risks[].risk]' "$(_manifest "$t")")" = "[\"$a\",\"$b\"]" ] || return 1
  # The person is shown the unacknowledged text, though notes.md no longer has it.
  out=$(_ack "$t" "${b:0:12}") || return 1
  grep -q 'the plan now removes the prior guard' <<<"$out" || return 1
  grep -q 'notes.md no longer says this' <<<"$out" || return 1
  _check "$t" >/dev/null
}

test_record_is_append_only() {
  local t a
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  a=$(_sha "$t")
  _record "$t" >/dev/null
  _record "$t" >/dev/null
  [ "$(jq '.regression_risks | length' "$(_manifest "$t")")" = "1" ] || return 1
  _write_notes "$t" UNACKNOWLEDGED "second version"
  _record "$t" >/dev/null
  _write_notes "$t" UNACKNOWLEDGED
  _record "$t" >/dev/null
  [ "$(jq '.regression_risks | length' "$(_manifest "$t")")" = "2" ] || return 1
  [ "$(jq -r '.regression_risks[0].risk' "$(_manifest "$t")")" = "$a" ] || return 1
  # The writer has no way to drop or rewrite an entry.
  _env "$t" bash -c "source '$LIB_DIR/manifest-write.sh'; set_ticket_regression_risk $TID $a 'other text'" || return 1
  [ "$(jq -r '.regression_risks[0].body' "$(_manifest "$t")")" != "other text" ]
}

# Finding 2: a section the gate sees and cannot record is a hold, and
# `record` fails, so neither path goes on with nothing on record.
test_record_write_failure_holds() {
  [ "$(id -u)" != "0" ] || {
    echo "skipped as root: a read-only directory does not stop root" >&2
    return 0
  }
  local t out rc=0 dir
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  dir=$(dirname "$(_manifest "$t")")
  chmod 444 "$(_manifest "$t")"
  chmod 555 "$dir"
  out=$(_check "$t" 2>/dev/null) || rc=$?
  local rrc=0
  _record "$t" >/dev/null 2>&1 || rrc=$?
  chmod 755 "$dir"
  chmod 644 "$(_manifest "$t")"
  [ "$rc" -eq 1 ] || {
    echo "check rc=$rc with an unwritable manifest: $out" >&2
    return 1
  }
  grep -qx 'REGRESSION_RISK_GATE=hold' <<<"$out" || return 1
  grep -qx 'REGRESSION_RISK_REASON=record-failed' <<<"$out" || return 1
  [ "$rrc" -eq 1 ] || {
    echo "record rc=$rrc with an unwritable manifest" >&2
    return 1
  }
  [ -z "$(_recorded "$t")" ]
}

# Only exit 0 lets ticket-implement go on, and the skill says so.
test_skill_treats_any_nonzero_as_stop() {
  grep -q 'Exit 0 → proceed. Any other exit → stop' "$PLUGIN_DIR/skills/ticket-implement/SKILL.md"
}

# Finding 3: escape sequences in the agent-written text never reach the
# approver's terminal, and a section holding them is not acknowledged.
test_escape_sequence_refused() {
  local t out rc=0
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED $'removes the guard\e[1A\e[2Kharmless rename'
  out=$(_ack "$t" "$(_id "$t")" 2>&1) || rc=$?
  [ "$rc" -eq 7 ] || {
    echo "a section with ESC sequences: rc=$rc" >&2
    return 1
  }
  ! grep -q $'\e' <<<"$out" || {
    echo "an ESC byte reached the terminal" >&2
    return 1
  }
  ! grep -q 'harmless rename' <<<"$out" || return 1
  [ -z "$(_ack_field "$t" risk)" ] || return 1
  _expect_rc 1 _check "$t"
}

# Ordinary non-ASCII text is not a control character.
test_plain_unicode_accepted() {
  local t out
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED "café — 日本 😀 ⚠️ naïve"
  out=$(_ack "$t" "$(_id "$t")") || return 1
  grep -q 'café — 日本 😀' <<<"$out" || return 1
  ! grep -q 'WARNING' <<<"$out"
}

test_bidi_and_c1_refused() {
  local t
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED $'safe \xe2\x80\xaetxet neddih'
  _expect_rc 7 _ack "$t" "$(_id "$t")" || return 1
  _write_notes "$t" UNACKNOWLEDGED $'c1 \xc2\x9b2K control'
  _expect_rc 7 _ack "$t" "$(_id "$t")"
}

# Once recorded, a version with escape sequences cannot be rewritten. After
# the section is cleaned it is shown escaped, under a warning, and never raw.
test_recorded_escape_version_shown_escaped() {
  local t out bad
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED $'removes the guard\e[2Khidden'
  bad=$(_sha "$t")
  _expect_rc 1 _check "$t" || return 1
  _write_notes "$t" UNACKNOWLEDGED "removes the guard, stated plainly"
  out=$(_ack "$t" "$(_id "$t")") || {
    echo "a cleaned section could not be acknowledged: $out" >&2
    return 1
  }
  ! grep -q $'\e' <<<"$out" || return 1
  grep -q 'WARNING' <<<"$out" || return 1
  grep -qF 'removes the guard^[[2Khidden' <<<"$out" || return 1
  [ "$(jq '[.regression_acks[] | select(.provenance == "human")] | length' "$(_manifest "$t")")" = "2" ] || return 1
  jq -e --arg r "$bad" '.regression_acks | any(.risk == $r)' "$(_manifest "$t")" >/dev/null || return 1
  _check "$t" >/dev/null
}

# ── skill prose ──────────────────────────────────────────────────────────────

test_skills_call_the_scripts_and_drop_the_hand_edit() {
  local impl="$PLUGIN_DIR/skills/ticket-implement/SKILL.md" exec="$PLUGIN_DIR/skills/ticket-appraise-exec/SKILL.md"
  grep -q 'lib/regression-risk.sh check' "$impl" || return 1
  grep -q 'lib/regression-risk.sh record' "$exec" || return 1
  ! grep -q 'Status:\*\* ACKNOWLEDGED' "$impl" || return 1
  ! grep -qi 'change Status to' "$impl" "$exec" || return 1
  grep -q 'regression-ack.sh' "$exec" || return 1
  # The line the skill writes into notes.md is the boilerplate the
  # fingerprint drops: a notes.md built from the template fingerprints the
  # same with and without it.
  local t a line
  t=$(_mk)
  _write_notes "$t" UNACKNOWLEDGED
  a=$(_sha "$t")
  line=$(grep -m1 '^→ A person acknowledges' "$exec" | sed "s/{TICKET-ID}/$TID/")
  [ -n "$line" ] || return 1
  sed -i '/^→ /d' "$(_notes "$t")"
  [ "$(_sha "$t")" = "$a" ] || return 1
  printf '%s\n' "$line" >>"$t/line"
  sed -i "/^\*\*Status:\*\*/r $t/line" "$(_notes "$t")"
  [ "$(_sha "$t")" = "$a" ]
}

_run "no Regression Risk section and nothing recorded: clear" test_no_section_is_clear
_run "unacknowledged risk holds with a gate-stop, one gate-held event, and is recorded" test_unacknowledged_holds
_run "a hand-edited ACKNOWLEDGED status no longer clears the gate" test_hand_edit_does_not_clear
_run "the status line is not part of the fingerprint; the table is" test_status_edit_keeps_fingerprint
_run "section deleted after being recorded still holds" test_section_deleted_after_record_holds
_run "section renamed after being recorded still holds" test_section_renamed_after_record_holds
_run "section deleted after the gate first saw it still holds" test_section_deleted_after_first_check_holds
_run "a heading of another level or case is still the section" test_heading_level_and_case
_run "risk text on a **Status:**-prefixed line changes the fingerprint" test_status_prefixed_text_is_fingerprinted
_run "risk text on a → line changes the fingerprint; only the fixed lines are dropped" test_arrow_prefixed_text_is_fingerprinted
_run "a → line added after the acknowledgement re-holds" test_added_arrow_line_reholds
_run "reverting notes.md to acknowledged text does not clear a later risk" test_revert_to_acked_text_still_holds
_run "the recorded history is append-only" test_record_is_append_only
_run "a record write failure holds, and record itself fails" test_record_write_failure_holds
_run "ticket-implement stops on any non-zero exit of the gate" test_skill_treats_any_nonzero_as_stop
_run "a section with an ESC sequence is refused and never printed" test_escape_sequence_refused
_run "direction-override and C1 control characters are refused" test_bidi_and_c1_refused
_run "ordinary non-ASCII text is shown and accepted" test_plain_unicode_accepted
_run "a recorded version with ESC sequences is shown escaped under a warning" test_recorded_escape_version_shown_escaped
_run "a repeated hold emits gate-held once per risk" test_hold_event_once_per_risk
_run "the gate does not evaluate without REPOS_ROOT (exit 2)" test_check_needs_repos_root
_run "the actuator clears the gate and records provenance, who and when" test_ack_clears_and_records_provenance
_run "a wrong, empty or generic answer records nothing" test_wrong_answer_records_nothing
_run "a repeat acknowledgement is a no-op" test_repeat_ack_is_noop
_run "no section and nothing recorded: nothing to acknowledge (exit 5)" test_no_section_nothing_to_ack
_run "a changed risk re-holds until it is acknowledged again" test_changed_risk_reholds
_run "a person can acknowledge a recorded risk whose section was removed" test_person_acknowledges_a_removed_section
_run "no terminal: refused even with the agent variables unset and the id on stdin" test_no_tty_refused_even_with_env_unset
_run "the actuator refuses an agent session even at a terminal" test_agent_session_refused
_run "the actuator refuses a fleetd worker even at a terminal" test_fleet_worker_refused
_run "there is no flag or variable that skips the checks" test_no_bypass_flag
_run "the manifest writer refuses agent context and non-human provenance" test_writer_refuses_agent_and_non_human
_run "a fact whose provenance is not human does not pass" test_non_human_fact_holds
_run "a pipeline-log line does not clear the gate" test_log_line_does_not_clear
_run "skill prose calls the scripts and no longer tells anyone to edit the status" test_skills_call_the_scripts_and_drop_the_hand_edit

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
