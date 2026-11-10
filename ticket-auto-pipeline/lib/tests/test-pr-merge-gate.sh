#!/usr/bin/env bash
# test-pr-merge-gate.sh — unit tests for lib/pr-merge-gate.sh, the
# ticket-pr-review Step 6b merge gate (skill-deterministic-extraction 2).
#
# Expected log lines and user messages are fixtures lifted from the
# pre-extraction SKILL.md (fixtures/pr-review/merge-gate-*), never regenerated
# from the script; timestamps are masked. `gh` is stubbed via PATH and every
# call recorded to $_ws/gh.calls, so a test can prove no merge call was made.
# Also carries the behavioural replacements for the Step 6b prose-grep tests
# that lived in test-pipeline-phases.sh (#365 checks schema, checkless PR,
# fail-closed checks command, bucket evaluation, #412 shared merge rule).
# Usage: bash test-pr-merge-gate.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
PMG="$LIB_DIR/pr-merge-gate.sh"
FX="$SCRIPT_DIR/fixtures/pr-review"

PASS=0
FAIL=0
FILTER="${1:-}"

_run() {
  local name="$1"
  shift
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return 0
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

unset LOG_FILE TAP_LOG HB_LOG_FILE AUTONOMY MERGE_POLICY UAT_POLICY

_ws=""
# _setup [conflict] — temp workspace, a worktree whose origin/main...origin/feat
# diff is clean (or carries a real conflict block), and a default gh stub.
_setup() {
  _ws=$(mktemp -d)
  mkdir -p "$_ws/bin" "$_ws/wt"
  : >"$_ws/gh.calls"
  : >"$_ws/log"
  (
    cd "$_ws/wt"
    git init -q -b main .
    git config user.email t@t && git config user.name t
    mkdir -p src && echo base >src/a.txt
    git add . && git commit -qm base
    git update-ref refs/remotes/origin/main HEAD
    git switch -qc feat
    if [ "${1:-}" = conflict ]; then
      printf '<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> b\n' >src/a.txt
    else
      printf 'Title\n=======\n' >src/a.txt
    fi
    git commit -qam change
    git update-ref refs/remotes/origin/feat HEAD
  ) >/dev/null 2>&1
  _stub_gh 0 '[]' 0
}
_teardown() { rm -rf "$_ws" 2>/dev/null || true; }

# _stub_gh <checks_rc> <checks_output> <merge_rc>
_stub_gh() {
  printf '%s' "$2" >"$_ws/checks.out"
  cat >"$_ws/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$_ws/gh.calls"
case "\$1 \$2" in
"pr checks") cat "$_ws/checks.out"; exit $1 ;;
esac
case "\$*" in
*"/merge -X PUT"*) exit $3 ;;
esac
exit 0
EOF
  chmod +x "$_ws/bin/gh"
}

_rc=0
_out=""
_pmg() {
  _rc=0
  _out=$(PATH="$_ws/bin:$PATH" AUTONOMY="${_AUTONOMY-auto}" MERGE_POLICY="" \
    bash "$PMG" --log-file "$_ws/log" --repo acme/app --pr 12 --base main --head feat \
    --worktree "$_ws/wt" "$@" TEST-7 2>/dev/null) || _rc=$?
}

_masked_log() { sed -E 's/^[^|]+\|/TS|/' "$_ws/log"; }
_log_is() { diff <(_masked_log) "$FX/$1" >/dev/null; }
# The message is everything after the first blank line of stdout.
_msg_is() { diff <(sed '1,/^$/d' <<<"$_out") "$FX/$1" >/dev/null; }
_merge_called() { grep -q '/merge -X PUT' "$_ws/gh.calls"; }
_comment_posted() { grep -q 'repos/acme/app/issues/12/comments' "$_ws/gh.calls"; }

# ── fixture parity ──────────────────────────────────────────────────────────

test_human_merge_skips_without_gh_checks() {
  _setup
  _AUTONOMY=manual _pmg
  local ok=1
  [ "$_rc" = 3 ] && _log_is merge-gate-human.log && _msg_is merge-gate-human.msg &&
    ! grep -q 'pr checks' "$_ws/gh.calls" && ! _merge_called && _comment_posted || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_checks_command_failure_blocks() {
  _setup
  _stub_gh 1 'error connecting to api.github.com' 0
  _pmg
  local ok=1
  [ "$_rc" = 3 ] && _log_is merge-gate-checks-failed.log &&
    _msg_is merge-gate-checks-failed.msg && ! _merge_called && _comment_posted || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_failing_checks_block_with_state_bucket_table() {
  _setup
  _stub_gh 0 '[{"name":"build","state":"SUCCESS","bucket":"pass"},{"name":"test","state":"FAILURE","bucket":"fail"},{"name":"lint","state":"IN_PROGRESS","bucket":"pending"}]' 0
  _pmg
  local ok=1
  [ "$_rc" = 3 ] && _log_is merge-gate-failing-checks.log &&
    _msg_is merge-gate-failing-checks.msg && ! _merge_called || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_conflict_markers_block() {
  _setup conflict
  _pmg
  local ok=1
  [ "$_rc" = 3 ] && _log_is merge-gate-conflict.log && _msg_is merge-gate-conflict.msg &&
    ! _merge_called || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_green_checks_merge_via_rest() {
  _setup
  _stub_gh 0 '[{"name":"build","state":"SUCCESS","bucket":"pass"},{"name":"e2e","state":"SKIPPED","bucket":"skipping"}]' 0
  _pmg
  local ok=1
  [ "$_rc" = 0 ] && _log_is merge-gate-merged.log &&
    grep -qx 'api repos/acme/app/pulls/12/merge -X PUT -f merge_method=squash' "$_ws/gh.calls" &&
    grep -q '^MERGE_RESULT=merged' <<<"$_out" && ! grep -q 'pr merge' "$_ws/gh.calls" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_merge_call_failure_logs_fail() {
  _setup
  _stub_gh 0 '[]' 1
  _pmg
  local ok=1
  [ "$_rc" = 4 ] && _log_is merge-gate-merge-failed.log && grep -q '^MERGE_RESULT=failed' <<<"$_out" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_skip_flags_make_no_gh_call() {
  _setup
  local ok=1
  _pmg --skip gate-blocked
  [ "$_rc" = 3 ] && _log_is merge-gate-gate-blocked.log && [ ! -s "$_ws/gh.calls" ] || ok=0
  : >"$_ws/log"
  _pmg --skip skipped
  [ "$_rc" = 3 ] && _log_is merge-gate-skipped.log && [ ! -s "$_ws/gh.calls" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

# ── #365: checks JSON schema, checkless PR, fail closed ────────────────────

test_checks_requests_real_json_fields() {
  _setup
  _pmg
  local ok=1
  grep -qx 'pr checks 12 --repo acme/app --json name,state,bucket' "$_ws/gh.calls" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_no_checks_reported_is_not_blocked() {
  _setup
  _stub_gh 8 "no checks reported on the 'feat' branch" 0
  _pmg
  local ok=1
  [ "$_rc" = 0 ] && _merge_called || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_empty_checks_array_merges() {
  _setup
  _pmg
  local ok=1
  [ "$_rc" = 0 ] && _merge_called || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_unparseable_checks_output_blocks() {
  _setup
  local ok=1 out
  for out in 'not json at all' '{"name":"x"}' '"a string"'; do
    _stub_gh 0 "$out" 0
    : >"$_ws/gh.calls"
    _pmg
    [ "$_rc" = 3 ] && ! _merge_called && grep -q 'blocked: checks command failed' "$_ws/log" || ok=0
  done
  _teardown
  [ "$ok" = 1 ]
}

test_cancel_and_unknown_buckets_block() {
  _setup
  local ok=1 b
  for b in cancel '' weird; do
    _stub_gh 0 "[{\"name\":\"c\",\"state\":\"X\",\"bucket\":\"$b\"}]" 0
    : >"$_ws/gh.calls"
    _pmg
    [ "$_rc" = 3 ] && ! _merge_called || ok=0
  done
  _stub_gh 0 '[{"name":"c","state":"X"}]' 0
  : >"$_ws/gh.calls"
  _pmg
  [ "$_rc" = 3 ] && ! _merge_called || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_failed_git_diff_blocks() {
  _setup
  rm -rf "$_ws/wt/.git"
  _pmg
  local ok=1
  [ "$_rc" = 3 ] && ! _merge_called && grep -q 'blocked: conflict markers' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

# ── #412: one merge-authorization rule ─────────────────────────────────────

test_epic_merge_policy_blocks() {
  _setup
  local ok=1
  _out=$(PATH="$_ws/bin:$PATH" AUTONOMY=auto MERGE_POLICY=manual \
    bash "$PMG" --log-file "$_ws/log" --repo acme/app --pr 12 --base main --head feat \
    --worktree "$_ws/wt" TEST-7 2>/dev/null) || _rc=$?
  [ "$_rc" = 3 ] && ! _merge_called &&
    grep -q 'merge-decision|done|skipped: epic Branch Directive Merge Policy: manual requires human merge' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_script_uses_shared_rule_and_scanner() {
  grep -q 'merge_blocked_reason "\$_pmg_tid"' "$PMG" && grep -q 'conflict-marker-scan.sh' "$PMG"
}

test_usage_errors_log_nothing() {
  _setup
  local ok=1 rc=0
  PATH="$_ws/bin:$PATH" bash "$PMG" --log-file "$_ws/log" --repo 'bad repo' --pr 12 --base main \
    --head feat --worktree "$_ws/wt" TEST-7 >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && [ ! -s "$_ws/log" ] && [ ! -s "$_ws/gh.calls" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

# ── SKILL.md wiring ─────────────────────────────────────────────────────────

test_skill_step6b_calls_the_gate() {
  local skill="$PLUGIN_DIR/skills/ticket-pr-review/SKILL.md" block
  block=$(sed -n '/^### Step 6b/,/^## Step 7 /p' "$skill")
  grep -q 'pr-merge-gate.sh' <<<"$block" && ! grep -q 'gh pr checks {number}' <<<"$block" &&
    ! grep -q 'pulls/{number}/merge' <<<"$block"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  _run "$t" "$t"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
