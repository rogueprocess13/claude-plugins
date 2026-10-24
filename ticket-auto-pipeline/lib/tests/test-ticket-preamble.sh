#!/usr/bin/env bash
# test-ticket-preamble.sh — tests for lib/ticket-preamble.sh (task 4.10).
#
# The preamble's whole job is establishing an environment nothing else builds,
# so the assertions are about what exists afterwards — env file, schema line,
# branch-context line — and about the two properties fleetd actually depends
# on: re-entry is idempotent, and a recorded branch decision is never
# re-resolved.
#
# Linear is never called: preflight is skipped and branch resolution is
# stubbed, because the interesting behaviour here is the ordering and the
# guards, not the API clients those already have tests for.
# -u (nounset) intentionally omitted — see test-detect-resume.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREAMBLE_SH="$LIB_DIR/ticket-preamble.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_field() {
  local block="$1" field="$2"
  echo "$block" | grep "^  ${field}:" | sed -E "s/^  ${field}: *//"
}

# Run the preamble inside a throwaway project dir, with branch-resolve.sh
# stubbed by a shim on PATH-equivalent terms: the stub is a file the preamble
# sources by name, so it is installed into a copied lib dir.
#
# Echoes the TICKET_PREAMBLE_RESULT block; leaves the sandbox at $_SANDBOX for
# the caller to inspect, and it is the caller's to remove.
_preamble() {
  local ticket_id="$1"
  shift
  (cd "$_SANDBOX" && bash "$_SANDBOX/lib/ticket-preamble.sh" \
    TICKET_ID="$ticket_id" PROJECT_DIR="$_SANDBOX" SKIP_PREFLIGHT=true "$@")
}

# Build a sandbox: a copy of lib/ with branch-resolve.sh replaced by a stub
# that records every call, so "was it called again?" is an assertable fact.
_sandbox_new() {
  _SANDBOX="$(mktemp -d)"
  mkdir -p "$_SANDBOX/lib" "$_SANDBOX/logs"
  cp "$LIB_DIR"/*.sh "$_SANDBOX/lib/"

  cat >"$_SANDBOX/lib/branch-resolve.sh" <<'STUB'
#!/usr/bin/env bash
resolve_branch_context() {
  echo "$*" >>"${BRANCH_RESOLVE_CALLS:-/dev/null}"
  if [ -n "${BRANCH_RESOLVE_FAIL:-}" ]; then
    echo "$BRANCH_RESOLVE_FAIL" >&2
    return 1
  fi
  cat <<'BLOCK'
BRANCH_CONTEXT_RESULT:
  TICKET_BRANCH: feat/test-1
  BASE_BRANCH: develop
  INTEGRATION_BRANCH: epic/thing
  BRANCH_SOURCE: epic-directive
  UAT_POLICY: epic
  MERGE_POLICY: auto
BLOCK
}
STUB

  export BRANCH_RESOLVE_CALLS="$_SANDBOX/branch-calls.txt"
  : >"$BRANCH_RESOLVE_CALLS"
  unset BRANCH_RESOLVE_FAIL
}

_sandbox_rm() {
  [ -n "$_SANDBOX" ] && rm -rf "$_SANDBOX"
  rm -f /tmp/ticket-auto-TEST-PRE*-env.sh
  _SANDBOX=""
}

# ── The environment the preamble is responsible for ───────────────────────────

test_writes_env_file_log_and_branch_context() {
  _sandbox_new
  local out rc=0
  out=$(_preamble TEST-PRE-1 AUTONOMY=auto) || rc=$?
  local log="$_SANDBOX/logs/TEST-PRE-1-pipeline.log"

  [ "$rc" -eq 0 ] &&
    [ -f /tmp/ticket-auto-TEST-PRE-1-env.sh ] &&
    grep -q '^[^|]*|META|schema|info|1$' "$log" &&
    grep -q '|META|branch-context|info|base=develop;integration=epic/thing;source=epic-directive;ticket=feat/test-1;uat-policy=epic;merge-policy=auto$' "$log" &&
    grep -q '|META|autonomy|info|auto$' "$log" &&
    grep -q '|META|from-planned|info|false$' "$log" &&
    [ "$(_field "$out" BRANCH_ORIGIN)" = "resolved" ] &&
    [ "$(_field "$out" INTEGRATION_BRANCH)" = "epic/thing" ]
  local ok=$?
  _sandbox_rm
  return $ok
}

# The schema line must be the log's first line. If a gate-stop lands in an
# empty log first, detect-resume.sh reads the file as a v0 log and applies
# grace — silently, and with the gate-stop no longer first in the cascade.
test_schema_line_precedes_a_branch_gate_stop() {
  _sandbox_new
  export BRANCH_RESOLVE_FAIL="BRANCH_DIRECTIVE_INVALID: malformed"
  local rc=0
  _preamble TEST-PRE-2 >/dev/null 2>&1 || rc=$?
  unset BRANCH_RESOLVE_FAIL
  local log="$_SANDBOX/logs/TEST-PRE-2-pipeline.log"

  [ "$rc" -eq 2 ] &&
    head -1 "$log" | grep -q '|META|schema|info|1$' &&
    grep -q '|META|gate-stop|fail|BRANCH_DIRECTIVE_INVALID$' "$log"
  local ok=$?
  _sandbox_rm
  return $ok
}

# A branch resolution that fails for a non-directive reason is not a gate-stop:
# an API blip must not be recorded as a malformed directive, which is an
# operator-fix-it state a retry can never clear.
test_non_directive_branch_failure_is_not_a_gate_stop() {
  _sandbox_new
  export BRANCH_RESOLVE_FAIL="linear-api: 502 Bad Gateway"
  local rc=0
  _preamble TEST-PRE-3 >/dev/null 2>&1 || rc=$?
  unset BRANCH_RESOLVE_FAIL

  [ "$rc" -eq 3 ] &&
    ! grep -q 'gate-stop' "$_SANDBOX/logs/TEST-PRE-3-pipeline.log"
  local ok=$?
  _sandbox_rm
  return $ok
}

# ── Re-entry after a fleetd restart ───────────────────────────────────────────

test_reentry_rehydrates_and_does_not_re_resolve() {
  _sandbox_new
  _preamble TEST-PRE-4 >/dev/null
  local first_calls
  first_calls=$(wc -l <"$BRANCH_RESOLVE_CALLS")

  local out
  out=$(_preamble TEST-PRE-4)
  local second_calls
  second_calls=$(wc -l <"$BRANCH_RESOLVE_CALLS")

  [ "$first_calls" -eq 1 ] && [ "$second_calls" -eq 1 ] &&
    [ "$(_field "$out" BRANCH_ORIGIN)" = "rehydrated" ] &&
    [ "$(_field "$out" BASE_BRANCH)" = "develop" ] &&
    [ "$(_field "$out" MERGE_POLICY)" = "auto" ]
  local ok=$?
  _sandbox_rm
  return $ok
}

test_reentry_appends_no_duplicate_meta_lines() {
  _sandbox_new
  _preamble TEST-PRE-5 AUTONOMY=auto >/dev/null
  _preamble TEST-PRE-5 AUTONOMY=auto >/dev/null
  _preamble TEST-PRE-5 AUTONOMY=auto >/dev/null
  local log="$_SANDBOX/logs/TEST-PRE-5-pipeline.log"
  local hb="$_SANDBOX/logs/TEST-PRE-5-heartbeat.log"

  [ "$(grep -c '|META|schema|info|' "$log")" -eq 1 ] &&
    [ "$(grep -c '|META|branch-context|' "$log")" -eq 1 ] &&
    [ "$(grep -c '|META|autonomy|' "$log")" -eq 1 ] &&
    [ "$(grep -c '|META|from-planned|' "$log")" -eq 1 ] &&
    [ "$(grep -c '|heartbeat|pipeline-start|' "$hb")" -eq 1 ]
  local ok=$?
  _sandbox_rm
  return $ok
}

# An autonomy that differs from the recorded one is a logged change, never a
# silent overwrite: gate decisions already taken under the old mode have to
# stay explicable.
test_autonomy_change_is_logged_not_overwritten() {
  _sandbox_new
  _preamble TEST-PRE-6 AUTONOMY=manual >/dev/null
  _preamble TEST-PRE-6 AUTONOMY=auto >/dev/null
  local log="$_SANDBOX/logs/TEST-PRE-6-pipeline.log"

  grep -q '|META|autonomy|info|manual$' "$log" &&
    grep -q '|META|mode-change|warn|auto (was manual)$' "$log"
  local ok=$?
  _sandbox_rm
  return $ok
}

# The env file is rewritten on a rehydrated entry too — a tmp sweep can remove
# it between two phases of one ticket, and the next phase would source
# nothing (the preamble in skill-preamble-auto.md sources it with `|| true`,
# so its absence is silent).
test_reentry_repairs_a_swept_env_file() {
  _sandbox_new
  _preamble TEST-PRE-7 >/dev/null
  rm -f /tmp/ticket-auto-TEST-PRE-7-env.sh
  _preamble TEST-PRE-7 >/dev/null

  [ -f /tmp/ticket-auto-TEST-PRE-7-env.sh ] &&
    grep -q 'export BASE_BRANCH="develop"' /tmp/ticket-auto-TEST-PRE-7-env.sh &&
    grep -q 'export UAT_POLICY="epic"' /tmp/ticket-auto-TEST-PRE-7-env.sh
  local ok=$?
  _sandbox_rm
  return $ok
}

# ── Project context extraction ────────────────────────────────────────────────

test_context_reads_claude_md_and_env_wins() {
  local tmp
  tmp="$(mktemp -d)"
  cat >"$tmp/CLAUDE.md" <<'MD'
# Project

`REPOS_ROOT` = `/repos/from/md`
ISSUE_PREFIX: CRE
`BE_TEST_CMD` = `mvn -q test`
MD

  local out
  out=$(REPOS_ROOT=/repos/from/env bash -c \
    "source '$PREAMBLE_SH'; ticket_preamble_project_context '$tmp'")

  echo "$out" | grep -qx 'REPOS_ROOT=/repos/from/env' &&
    echo "$out" | grep -qx 'ISSUE_PREFIX=CRE' &&
    echo "$out" | grep -qx 'BE_TEST_CMD=mvn -q test' &&
    echo "$out" | grep -qx 'WIKI_ROOT='
  local ok=$?
  rm -rf "$tmp"
  return $ok
}

# Every field is emitted even when nothing declares it, so the caller reads a
# fixed field set rather than distinguishing "absent" from "empty".
test_context_emits_every_field_for_a_bare_project() {
  local tmp out
  tmp="$(mktemp -d)"
  out=$(env -u REPOS_ROOT -u ISSUE_PREFIX -u BE_SERVICES -u WIKI_ROOT \
    -u BE_TEST_CMD -u BE_TEST_RUNNER -u FE_TEST_CMD -u LOCAL_URL \
    -u UAT_URL -u SLACK_CHANNEL \
    bash -c "source '$PREAMBLE_SH'; ticket_preamble_project_context '$tmp'")
  [ "$(echo "$out" | wc -l)" -eq 10 ] && ! echo "$out" | grep -qv '=$'
  local ok=$?
  rm -rf "$tmp"
  return $ok
}

# ── Argument handling ─────────────────────────────────────────────────────────

# Both usage errors exit 1, and 1 is deliberately not the gate-stop code: a
# caller's typo must never be recorded on a ticket as a malformed directive.
test_missing_ticket_id_fails_with_the_usage_code() {
  local rc=0
  bash "$PREAMBLE_SH" SKIP_PREFLIGHT=true >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

test_unknown_parameter_fails_with_the_usage_code() {
  local rc=0
  bash "$PREAMBLE_SH" TICKET_ID=X NONSENSE=1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

test_unrecognised_autonomy_falls_back_to_manual() {
  _sandbox_new
  local out
  out=$(_preamble TEST-PRE-8 AUTONOMY=turbo 2>/dev/null)
  [ "$(_field "$out" AUTONOMY)" = "manual" ]
  local ok=$?
  _sandbox_rm
  return $ok
}

# ── Run identity (Branch A) ───────────────────────────────────────────────────

# fleetd re-enters the preamble once per phase; run_identity_stamp's own
# open-run guard is what keeps two calls within one run down to one line —
# the preamble does not call it any differently the second time.
test_two_preamble_calls_in_one_run_write_one_run_id_line() {
  _sandbox_new
  _preamble TEST-PRE-9 >/dev/null
  _preamble TEST-PRE-9 >/dev/null
  local log="$_SANDBOX/logs/TEST-PRE-9-pipeline.log"
  [ "$(grep -c '|META|run-id|info|' "$log")" -eq 1 ]
  local ok=$?
  _sandbox_rm
  return $ok
}

test_preamble_starts_a_new_run_after_an_outcome() {
  _sandbox_new
  _preamble TEST-PRE-10 >/dev/null
  local log="$_SANDBOX/logs/TEST-PRE-10-pipeline.log"
  echo '2026-01-01T00:00:00Z|META|outcome|info|{"status":"done"}' >>"$log"
  _preamble TEST-PRE-10 >/dev/null
  [ "$(grep -c '|META|run-id|info|' "$log")" -eq 2 ]
  local ok=$?
  _sandbox_rm
  return $ok
}

# ── Manual-router mode (skill-glue-collapse) ──────────────────────────────────
#
# ticket-auto SKILL.md Steps 0.1–0.6 call the preamble with TICKET_ARG,
# NEW_RUN and ANNOUNCE_START. Every test here also guards the other direction:
# without those parameters nothing about the fleetd path may change.

# Like _preamble, but the ticket id comes only from the caller's arguments.
_preamble_raw() {
  (cd "$_SANDBOX" && bash "$_SANDBOX/lib/ticket-preamble.sh" \
    PROJECT_DIR="$_SANDBOX" SKIP_PREFLIGHT=true "$@")
}

test_new_run_opens_a_run_where_the_default_rehydrates() {
  _sandbox_new
  _preamble TEST-PRE-11 >/dev/null
  _preamble TEST-PRE-11 >/dev/null
  local log="$_SANDBOX/logs/TEST-PRE-11-pipeline.log"
  local after_default after_new
  after_default=$(grep -c '|META|run-id|info|' "$log")
  _preamble TEST-PRE-11 NEW_RUN=true >/dev/null
  after_new=$(grep -c '|META|run-id|info|' "$log")

  [ "$after_default" -eq 1 ] && [ "$after_new" -eq 2 ]
  local ok=$?
  _sandbox_rm
  return $ok
}

test_new_run_after_an_outcome_opens_a_new_run() {
  _sandbox_new
  _preamble TEST-PRE-12 NEW_RUN=true >/dev/null
  local log="$_SANDBOX/logs/TEST-PRE-12-pipeline.log"
  echo '2026-01-01T00:00:00Z|META|outcome|info|{"status":"done"}' >>"$log"
  _preamble TEST-PRE-12 NEW_RUN=true >/dev/null
  [ "$(grep -c '|META|run-id|info|' "$log")" -eq 2 ] &&
    tail -n +"$(grep -n '|META|outcome|' "$log" | cut -d: -f1)" "$log" |
    grep -q '|META|run-id|info|'
  local ok=$?
  _sandbox_rm
  return $ok
}

test_ticket_arg_strips_every_flag() {
  _sandbox_new
  local out
  out=$(_preamble_raw "TICKET_ARG=TEST-PRE-13 --auto --from-planned --branch epic/x")
  [ "$(_field "$out" TICKET_ID)" = "TEST-PRE-13" ] &&
    [ "$(_field "$out" AUTONOMY)" = "auto" ] &&
    [ "$(_field "$out" FROM_PLANNED)" = "true" ] &&
    grep -qx 'TEST-PRE-13 --branch epic/x' "$BRANCH_RESOLVE_CALLS" &&
    [ -f "$_SANDBOX/logs/TEST-PRE-13-pipeline.log" ]
  local ok=$?
  _sandbox_rm
  return $ok
}

# The router's grep cascade checked --semi-auto first, then --auto, then
# --manual, so that is the precedence whatever order the flags arrive in.
test_ticket_arg_autonomy_precedence() {
  _sandbox_new
  local a b c
  a=$(_preamble_raw "TICKET_ARG=--auto TEST-PRE-14 --semi-auto")
  b=$(_preamble_raw "TICKET_ARG=--manual TEST-PRE-15 --auto")
  c=$(_preamble_raw "TICKET_ARG=TEST-PRE-16 --manual")
  [ "$(_field "$a" AUTONOMY)" = "semi-auto" ] &&
    [ "$(_field "$b" AUTONOMY)" = "auto" ] &&
    [ "$(_field "$c" AUTONOMY)" = "manual" ] &&
    [ "$(_field "$c" FROM_PLANNED)" = "false" ] &&
    ! grep -q -- '--branch' "$BRANCH_RESOLVE_CALLS"
  local ok=$?
  _sandbox_rm
  return $ok
}

test_ticket_arg_env_fallback_for_autonomy() {
  _sandbox_new
  local out unset_out
  out=$(TICKET_AUTONOMY=semi-auto _preamble_raw "TICKET_ARG=TEST-PRE-17")
  unset_out=$(env -u TICKET_AUTONOMY bash -c \
    "cd '$_SANDBOX' && bash '$_SANDBOX/lib/ticket-preamble.sh' PROJECT_DIR='$_SANDBOX' SKIP_PREFLIGHT=true TICKET_ARG=TEST-PRE-18")
  [ "$(_field "$out" AUTONOMY)" = "semi-auto" ] &&
    [ "$(_field "$unset_out" AUTONOMY)" = "manual" ]
  local ok=$?
  _sandbox_rm
  return $ok
}

test_explicit_args_win_over_ticket_arg() {
  _sandbox_new
  local out
  out=$(_preamble_raw "TICKET_ARG=TEST-PRE-19 --auto --from-planned --branch epic/x" \
    TICKET_ID=TEST-PRE-20 AUTONOMY=manual FROM_PLANNED=false BRANCH_FLAG=feat/y)
  [ "$(_field "$out" TICKET_ID)" = "TEST-PRE-20" ] &&
    [ "$(_field "$out" AUTONOMY)" = "manual" ] &&
    [ "$(_field "$out" FROM_PLANNED)" = "false" ] &&
    grep -qx 'TEST-PRE-20 --branch feat/y' "$BRANCH_RESOLVE_CALLS"
  local ok=$?
  _sandbox_rm
  return $ok
}

# A stray token would become part of every path derived from the id, so it is
# a usage error rather than a ticket called "CRE-1 --typo".
test_ticket_arg_usage_errors() {
  _sandbox_new
  local rc1=0 rc2=0 rc3=0
  _preamble_raw "TICKET_ARG=TEST-PRE-21 --typo" >/dev/null 2>&1 || rc1=$?
  _preamble_raw "TICKET_ARG=TEST-PRE-21 --branch" >/dev/null 2>&1 || rc2=$?
  _preamble_raw "TICKET_ARG=--auto" >/dev/null 2>&1 || rc3=$?
  [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$rc3" -eq 1 ] &&
    [ ! -e "$_SANDBOX/logs/TEST-PRE-21-pipeline.log" ]
  local ok=$?
  _sandbox_rm
  return $ok
}

test_announce_start_is_written_once() {
  _sandbox_new
  _preamble TEST-PRE-22 >/dev/null
  local hb="$_SANDBOX/logs/TEST-PRE-22-heartbeat.log"
  local before
  before=$(grep -c '|gate|phase-transition|ok|START → APPRAISE' "$hb" || true)
  _preamble TEST-PRE-22 ANNOUNCE_START=true NEW_RUN=true >/dev/null
  _preamble TEST-PRE-22 ANNOUNCE_START=true NEW_RUN=true >/dev/null
  [ "$before" -eq 0 ] &&
    [ "$(grep -c '|gate|phase-transition|ok|START → APPRAISE' "$hb")" -eq 1 ]
  local ok=$?
  _sandbox_rm
  return $ok
}

test_dashboard_fields_only_in_new_run_mode() {
  _sandbox_new
  local plain manual
  plain=$(_preamble TEST-PRE-23)
  manual=$(_preamble TEST-PRE-23 NEW_RUN=true)
  local log="$_SANDBOX/logs/TEST-PRE-23-pipeline.log"
  ! echo "$plain" | grep -q 'DASHBOARD_CMD' &&
    [ "$(echo "$plain" | grep -c '^  [A-Z_]*:')" -eq 15 ] &&
    [ "$(_field "$manual" DASHBOARD_CMD_LOG)" = "python3 ~/.claude/skills/ticket-auto/dashboard.py $log" ] &&
    [ "$(_field "$manual" DASHBOARD_CMD_FLEET)" = "python3 ~/.claude/skills/ticket-auto/dashboard.py --fleet $_SANDBOX/logs" ] &&
    [ "$(echo "$manual" | tail -1 | sed 's/:.*//')" = "  DASHBOARD_CMD_FLEET" ]
  local ok=$?
  _sandbox_rm
  return $ok
}

test_manual_mode_schema_line_precedes_branch_context() {
  _sandbox_new
  _preamble_raw "TICKET_ARG=TEST-PRE-24 --auto" NEW_RUN=true ANNOUNCE_START=true >/dev/null
  local log="$_SANDBOX/logs/TEST-PRE-24-pipeline.log"
  local schema_n branch_n
  schema_n=$(grep -n '|META|schema|info|1$' "$log" | head -1 | cut -d: -f1)
  branch_n=$(grep -n '|META|branch-context|info|' "$log" | head -1 | cut -d: -f1)
  [ "$schema_n" = "1" ] && [ -n "$branch_n" ] && [ "$branch_n" -gt 1 ] &&
    [ "$(grep -c '|META|run-id|info|' "$log")" -eq 1 ]
  local ok=$?
  _sandbox_rm
  return $ok
}

# detect-resume.sh must route a log the manual preamble wrote exactly as it
# routes the log the old prose Steps 0.1–0.6 wrote (no schema line, branch
# context first). The only intended difference is the schema line itself,
# which spares the legacy log its v0-grace migration.
test_detect_resume_routes_a_manual_preamble_log_like_a_legacy_one() {
  _sandbox_new
  _preamble_raw "TICKET_ARG=TEST-PRE-25 --auto" NEW_RUN=true ANNOUNCE_START=true >/dev/null
  local legacy_dir
  legacy_dir="$(mktemp -d)"
  mkdir -p "$legacy_dir/logs"
  grep -v '|META|schema|' "$_SANDBOX/logs/TEST-PRE-25-pipeline.log" \
    >"$legacy_dir/logs/TEST-PRE-25-pipeline.log"

  local detect="$LIB_DIR/../skills/ticket-detect-resume/detect-resume.sh"
  local a b
  a=$(cd "$_SANDBOX" && CLAUDE_SKILLS_LIB="$LIB_DIR" env -u LINEAR_API_KEY \
    bash "$detect" TEST-PRE-25 2>/dev/null | grep -v 'LOG_FILE')
  b=$(cd "$legacy_dir" && CLAUDE_SKILLS_LIB="$LIB_DIR" env -u LINEAR_API_KEY \
    bash "$detect" TEST-PRE-25 2>/dev/null | grep -v 'LOG_FILE')
  local migrated
  migrated=$(grep -c '|META|migration|info|v0-grace-applied' \
    "$legacy_dir/logs/TEST-PRE-25-pipeline.log" || true)

  [ -n "$a" ] && [ "$a" = "$b" ] &&
    echo "$a" | grep -q 'RESUME_STEP: *STEP_1$' &&
    echo "$a" | grep -q 'AUTONOMY: *auto$' &&
    [ "$migrated" -eq 1 ] &&
    ! grep -q '|META|migration|' "$_SANDBOX/logs/TEST-PRE-25-pipeline.log"
  local ok=$?
  rm -rf "$legacy_dir"
  _sandbox_rm
  return $ok
}

# ── Preflight (assertions formerly pinned on ticket-auto SKILL.md Step 0.4) ───

# A sandbox whose linear-api.sh answers the teams query with $TEAMS_RESPONSE,
# and whose workflow.json exists, so preflight reaches the team-count guard.
_preflight_sandbox() {
  _sandbox_new
  mkdir -p "$_SANDBOX/skills/ticket-flow"
  echo '{}' >"$_SANDBOX/skills/ticket-flow/workflow.json"
  cat >"$_SANDBOX/lib/linear-api.sh" <<'STUB'
linear_graphql() { printf '%s' "${TEAMS_RESPONSE:-}"; }
get_me() { echo '{"name":"stub"}'; }
STUB
}

_preflight() {
  (cd "$_SANDBOX" && env -u LINEAR_TEAM_ID HOME="$_SANDBOX" \
    TICKET_FLOW_STATE_DIR="$_SANDBOX/state" \
    bash -c "source '$_SANDBOX/lib/ticket-preamble.sh'; ticket_preamble_preflight")
}

# The team count must be numeric before it is compared: a failed query used to
# reach `[ "" -eq 1 ]` and report "multiple teams", sending the operator to
# set LINEAR_TEAM_ID when the real fault was the key or the network.
test_preflight_teams_query_failure_has_its_own_message() {
  _preflight_sandbox
  local err rc=0
  err=$(TEAMS_RESPONSE='not json' _preflight 2>&1 >/dev/null) || rc=$?
  [ "$rc" -eq 5 ] &&
    echo "$err" | grep -q 'Linear teams query failed' &&
    ! echo "$err" | grep -q 'set LINEAR_TEAM_ID'
  local ok=$?
  _sandbox_rm
  return $ok
}

test_preflight_multiple_teams_asks_for_linear_team_id() {
  _preflight_sandbox
  local err rc=0
  err=$(TEAMS_RESPONSE='{"data":{"teams":{"nodes":[{"id":"a"},{"id":"b"}]}}}' \
    _preflight 2>&1 >/dev/null) || rc=$?
  [ "$rc" -eq 4 ] &&
    echo "$err" | grep -q '2 Linear teams visible — set LINEAR_TEAM_ID' &&
    ! echo "$err" | grep -q 'query failed'
  local ok=$?
  _sandbox_rm
  return $ok
}

test_preflight_numeric_guard_is_in_the_script() {
  grep -q '\[\[ "\$team_count" =~ \^\[0-9\]+\$ \]\]' "$PREAMBLE_SH"
}

_run "writes env file, log and branch context" test_writes_env_file_log_and_branch_context
_run "schema line precedes a branch gate-stop" test_schema_line_precedes_a_branch_gate_stop
_run "non-directive branch failure is not a gate-stop" test_non_directive_branch_failure_is_not_a_gate_stop
_run "re-entry rehydrates and does not re-resolve" test_reentry_rehydrates_and_does_not_re_resolve
_run "re-entry appends no duplicate META lines" test_reentry_appends_no_duplicate_meta_lines
_run "autonomy change is logged not overwritten" test_autonomy_change_is_logged_not_overwritten
_run "re-entry repairs a swept env file" test_reentry_repairs_a_swept_env_file
_run "context reads CLAUDE.md and env wins" test_context_reads_claude_md_and_env_wins
_run "context emits every field for a bare project" test_context_emits_every_field_for_a_bare_project
_run "missing TICKET_ID fails with the usage code" test_missing_ticket_id_fails_with_the_usage_code
_run "unknown parameter fails with the usage code" test_unknown_parameter_fails_with_the_usage_code
_run "unrecognised autonomy falls back to manual" test_unrecognised_autonomy_falls_back_to_manual
_run "two preamble calls in one run write one run-id line" test_two_preamble_calls_in_one_run_write_one_run_id_line
_run "preamble starts a new run after an outcome" test_preamble_starts_a_new_run_after_an_outcome
_run "NEW_RUN opens a run where the default rehydrates" test_new_run_opens_a_run_where_the_default_rehydrates
_run "NEW_RUN after an outcome opens a new run" test_new_run_after_an_outcome_opens_a_new_run
_run "TICKET_ARG strips every flag" test_ticket_arg_strips_every_flag
_run "TICKET_ARG autonomy precedence" test_ticket_arg_autonomy_precedence
_run "TICKET_ARG env fallback for autonomy" test_ticket_arg_env_fallback_for_autonomy
_run "explicit args win over TICKET_ARG" test_explicit_args_win_over_ticket_arg
_run "TICKET_ARG usage errors" test_ticket_arg_usage_errors
_run "ANNOUNCE_START is written once" test_announce_start_is_written_once
_run "dashboard fields only in NEW_RUN mode" test_dashboard_fields_only_in_new_run_mode
_run "manual mode: schema line precedes branch context" test_manual_mode_schema_line_precedes_branch_context
_run "detect-resume routes a manual preamble log like a legacy one" test_detect_resume_routes_a_manual_preamble_log_like_a_legacy_one
_run "preflight: teams query failure has its own message" test_preflight_teams_query_failure_has_its_own_message
_run "preflight: multiple teams asks for LINEAR_TEAM_ID" test_preflight_multiple_teams_asks_for_linear_team_id
_run "preflight: numeric team-count guard is in the script" test_preflight_numeric_guard_is_in_the_script

echo ""
echo "ticket-preamble: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
