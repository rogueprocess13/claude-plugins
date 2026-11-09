#!/usr/bin/env bash
# test-return-completeness.sh — unit tests for lib/return-completeness-check.sh
# Usage: bash test-return-completeness.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
RCC="$LIB_DIR/return-completeness-check.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  # Toggle -e off to capture test function return values correctly.
  # Test functions may legitimately return non-zero for assertion failures.
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc)"
    ((FAIL++)) || true
  fi
}

# ── Mock environment ──────────────────────────────────────────────────────────

_ws=""   # workspace dir
_root="" # mock REPOS_ROOT
_repo="" # mock git repo under REPOS_ROOT

_setup() {
  _ws=$(mktemp -d)
  _root="$_ws/repos-root"
  _repo="$_root/test-repo"
  mkdir -p "$_repo"
  git -C "$_repo" init -q
  git -C "$_repo" config user.email "test@test.com"
  git -C "$_repo" config user.name "Test"
  echo "// test source" >"$_repo/main.ts"
  git -C "$_repo" add main.ts
  git -C "$_repo" commit -q -m "initial commit"
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

# Write a tasks.md for a ticket under the mock repo's openspec/changes dir.
# Args: ticket-id  body (heredoc-style unchecked/checked lines)
_write_tasks() {
  local ticket_id="$1" body="$2"
  local change_dir="$_repo/openspec/changes/${ticket_id,,}--fix-thing"
  mkdir -p "$change_dir"
  printf '%s\n' "$body" >"$change_dir/tasks.md"
}

# Write a simple-fix.md for a ticket under a mock ticket workspace directory.
# Args: ticket-id  body (heredoc-style, including ## Completion Checklist section)
_write_simple_fix() {
  local ticket_id="$1" body="$2"
  local ws_dir="$_repo/${ticket_id,,}--fix-thing"
  mkdir -p "$ws_dir"
  printf '%s\n' "$body" >"$ws_dir/simple-fix.md"
}

# Run return-completeness-check.sh against REPOS_ROOT and source its output.
_run_check() {
  local ticket_id="$1"
  local _tmp_out="$_ws/rcc-out.env"
  local _saved_opts="$-"
  set +e
  "$RCC" "$ticket_id" --repos-root "$_root" >"$_tmp_out" 2>/dev/null
  RCC_EXIT=$?
  case "$_saved_opts" in *e*) set -e ;; esac
  # shellcheck disable=SC1090
  source "$_tmp_out"
}

# ── Tests ──────────────────────────────────────────────────────────────────────

test_all_checked_exits_0() {
  _setup
  _write_tasks "TEST-1" "$(
    cat <<'EOF'
## 1. Section
- [x] 1.1 done thing
- [x] 1.2 also done
EOF
  )"
  _run_check "TEST-1"
  [ "$RCC_EXIT" -eq 0 ] && [ "$RETURN_COMPLETENESS_STATUS" = "complete" ] && [ "$UNCHECKED_COUNT" -eq 0 ]
  local rc=$?
  _teardown
  return $rc
}

test_unchecked_box_exits_1() {
  _setup
  _write_tasks "TEST-2" "$(
    cat <<'EOF'
## 1. Section
- [x] 1.1 done thing
- [ ] 1.2 not done
EOF
  )"
  _run_check "TEST-2"
  [ "$RCC_EXIT" -eq 1 ] && [ "$RETURN_COMPLETENESS_STATUS" = "incomplete" ] && [ "$UNCHECKED_COUNT" -eq 1 ] && [ "$REASON" = "UNCHECKED_BOXES" ]
  local rc=$?
  _teardown
  return $rc
}

test_multiple_unchecked_counted() {
  _setup
  _write_tasks "TEST-3" "$(
    cat <<'EOF'
## 1. Section
- [ ] 1.1 not done
- [ ] 1.2 also not done
- [x] 1.3 done
EOF
  )"
  _run_check "TEST-3"
  [ "$RCC_EXIT" -eq 1 ] && [ "$UNCHECKED_COUNT" -eq 2 ] && [ "$TOTAL_COUNT" -eq 3 ]
  local rc=$?
  _teardown
  return $rc
}

test_missing_tasks_file_exits_2() {
  _setup
  # No tasks.md written for this ticket at all.
  _run_check "NOPE-999"
  [ "$RCC_EXIT" -eq 2 ] && [ "$RETURN_COMPLETENESS_STATUS" = "error" ] && [ "$REASON" = "NO_PLAN_ARTIFACT_FOUND" ]
  local rc=$?
  _teardown
  return $rc
}

test_tasks_file_flag_bypasses_search() {
  _setup
  _write_tasks "TEST-4" "$(
    cat <<'EOF'
- [x] 1.1 done
EOF
  )"
  local direct_path="$_repo/openspec/changes/test-4--fix-thing/tasks.md"
  local _tmp_out="$_ws/rcc-direct-out.env"
  "$RCC" "TEST-4" --tasks-file "$direct_path" >"$_tmp_out" 2>/dev/null
  local rc=$?
  # shellcheck disable=SC1090
  source "$_tmp_out"
  [ "$rc" -eq 0 ] && [ "$TASKS_FILE" = "$direct_path" ]
  rc=$?
  _teardown
  return $rc
}

test_unchecked_items_lists_content() {
  _setup
  _write_tasks "TEST-5" "$(
    cat <<'EOF'
- [ ] 1.1 write the docs
- [x] 1.2 done
EOF
  )"
  _run_check "TEST-5"
  grep -q "write the docs" <<<"$UNCHECKED_ITEMS"
  local rc=$?
  _teardown
  return $rc
}

# ── Simple-fix path tests (Completion Checklist section) ─────────────────────

test_simple_fix_all_checked_exits_0() {
  _setup
  _write_simple_fix "TEST-SF-1" "$(
    cat <<'EOF'
# Simple Fix — TEST-SF-1
## Summary
Fix thing.
## How to implement
Do X then Y.
## Completion Checklist
- [x] AC-1: User can click button
- [x] AC-2: Modal closes on save
EOF
  )"
  _run_check "TEST-SF-1"
  [ "$RCC_EXIT" -eq 0 ] && [ "$RETURN_COMPLETENESS_STATUS" = "complete" ] && [ "$UNCHECKED_COUNT" -eq 0 ] && [ "$ARTIFACT_TYPE" = "simple-fix" ]
  local rc=$?
  _teardown
  return $rc
}

test_simple_fix_unchecked_box_exits_1() {
  _setup
  _write_simple_fix "TEST-SF-2" "$(
    cat <<'EOF'
# Simple Fix — TEST-SF-2
## Summary
Fix thing.
## Completion Checklist
- [x] AC-1: Done item
- [ ] AC-2: Not done item
EOF
  )"
  _run_check "TEST-SF-2"
  [ "$RCC_EXIT" -eq 1 ] && [ "$RETURN_COMPLETENESS_STATUS" = "incomplete" ] && [ "$UNCHECKED_COUNT" -eq 1 ] && [ "$REASON" = "UNCHECKED_BOXES" ]
  local rc=$?
  _teardown
  return $rc
}

test_simple_fix_missing_checklist_exits_2() {
  _setup
  _write_simple_fix "TEST-SF-3" "$(
    cat <<'EOF'
# Simple Fix — TEST-SF-3
## Summary
Fix thing but no checklist section.
## How to implement
Do X.
EOF
  )"
  _run_check "TEST-SF-3"
  [ "$RCC_EXIT" -eq 2 ] && [ "$RETURN_COMPLETENESS_STATUS" = "error" ] && [ "$REASON" = "COMPLETION_CHECKLIST_MISSING" ]
  local rc=$?
  _teardown
  return $rc
}

# DET-IP-2: TEST-7 must not count another ticket's test-77 boxes.
test_whole_id_tasks_not_matched_by_longer_id() {
  _setup
  _write_tasks "TEST-77" "- [ ] 1.1 belongs to TEST-77"
  _run_check "TEST-7"
  [ "$RCC_EXIT" -eq 2 ] && [ -z "$TASKS_FILE" ]
  local rc=$?
  _teardown
  return $rc
}

test_whole_id_simple_fix_not_matched_by_longer_id() {
  _setup
  _write_simple_fix "TEST-77" "$(printf '## Completion Checklist\n- [ ] belongs to TEST-77\n')"
  _run_check "TEST-7"
  [ "$RCC_EXIT" -eq 2 ] && [ -z "$TASKS_FILE" ]
  local rc=$?
  _teardown
  return $rc
}

# ── Verifier-result recording (GitHub #598) ───────────────────────────────────
# Each runs the script from this checkout's lib (CLAUDE_SKILLS_LIB) with the
# caller's LOG_FILE/TAP_LOG unset, as in the router shell after #575.

_rcc_logged() {
  # _rcc_logged <log> <args...> — stdout to $_ws/out.env, stderr to $_ws/err
  local log="$1" _saved_opts="$-"
  shift
  set +e
  env -u LOG_FILE -u TAP_LOG CLAUDE_SKILLS_LIB="$LIB_DIR" HB_LOG_FILE= \
    bash "$RCC" "$@" --repos-root "$_root" ${log:+--log-file "$log"} >"$_ws/out.env" 2>"$_ws/err"
  RCC_EXIT=$?
  case "$_saved_opts" in *e*) set -e ;; esac
}

_rc_lines() { grep -c '"verifier":"return_completeness"' "$1" 2>/dev/null || true; }

_latest_rc() {
  { grep '"verifier":"return_completeness"' "$1" 2>/dev/null || true; } | tail -1 | sed 's/^[^{]*//'
}

# C: a 36-box PASS is recorded as 36/36, not 1/1.
test_pass_records_real_box_count() {
  _setup
  local body="" i
  for i in $(seq 1 36); do body+="- [x] 1.$i task"$'\n'; done
  _write_tasks "TEST-30" "$body"
  local log="$_ws/TEST-30-pipeline.log"
  _rcc_logged "$log" "TEST-30"
  local j
  j=$(_latest_rc "$log")
  _teardown
  [ "$RCC_EXIT" -eq 0 ] &&
    [ "$(jq -r .verdict <<<"$j")" = "PASS" ] &&
    [ "$(jq -r .criteria_met <<<"$j")" = "36" ] &&
    [ "$(jq -r .criteria_total <<<"$j")" = "36" ] || {
    echo "rc=$RCC_EXIT record=$j" >&2
    return 1
  }
}

# B: with LOG_FILE/TAP_LOG unset in the caller, --log-file still records.
test_log_file_flag_records_without_env() {
  _setup
  _write_tasks "TEST-31" "- [x] 1.1 a"$'\n'"- [ ] 1.2 b"
  local log="$_ws/TEST-31-pipeline.log"
  _rcc_logged "$log" "TEST-31"
  local n j
  n=$(_rc_lines "$log")
  j=$(_latest_rc "$log")
  local recorded=1
  grep -qx 'VERIFIER_RESULT=recorded' "$_ws/out.env" && recorded=0
  _teardown
  [ "$RCC_EXIT" -eq 1 ] && [ "$n" -eq 1 ] && [ "$recorded" -eq 0 ] &&
    [ "$(jq -r .verdict <<<"$j")" = "FAIL" ] &&
    [ "$(jq -r .criteria_met <<<"$j")/$(jq -r .criteria_total <<<"$j")" = "1/2" ] || {
    echo "rc=$RCC_EXIT lines=$n recorded=$recorded record=$j" >&2
    return 1
  }
}

# B: no log anywhere → loud (stdout marker + stderr warning), never silent.
test_no_log_is_loud() {
  _setup
  _write_tasks "TEST-32" "- [ ] 1.1 open"
  _rcc_logged "" "TEST-32"
  local marker=1 warned=1
  grep -qx 'VERIFIER_RESULT=unrecorded' "$_ws/out.env" && marker=0
  grep -q 'NOT recorded; the verdict gate is unarmed' "$_ws/err" && warned=0
  _teardown
  [ "$RCC_EXIT" -eq 1 ] && [ "$marker" -eq 0 ] && [ "$warned" -eq 0 ] || {
    echo "rc=$RCC_EXIT marker=$marker warned=$warned" >&2
    return 1
  }
}

# A: implement leaves 2 boxes for verify → FAIL; verify ticks them; the
# post-verify --refresh writes PASS 4/4 and the FAIL is no longer live.
test_refresh_supersedes_stale_fail() {
  _setup
  _write_tasks "TEST-33" "- [x] 1.1 a"$'\n'"- [x] 1.2 b"$'\n'"- [ ] 1.3 c"$'\n'"- [ ] 1.4 d"
  local log="$_ws/TEST-33-pipeline.log"
  _rcc_logged "$log" "TEST-33"
  local first_rc=$RCC_EXIT
  _write_tasks "TEST-33" "- [x] 1.1 a"$'\n'"- [x] 1.2 b"$'\n'"- [x] 1.3 c"$'\n'"- [x] 1.4 d"
  _rcc_logged "$log" "TEST-33" --refresh
  local j live
  j=$(_latest_rc "$log")
  # shellcheck source=/dev/null
  live=$(source "$LIB_DIR/verifier-result.sh" && verifier_latest_verdict "$log")
  _teardown
  [ "$first_rc" -eq 1 ] && [ "$RCC_EXIT" -eq 0 ] && [ -z "$live" ] &&
    [ "$(jq -r .verdict <<<"$j")" = "PASS" ] &&
    [ "$(jq -r .criteria_met <<<"$j")/$(jq -r .criteria_total <<<"$j")" = "4/4" ] &&
    [ "$(jq -r .attempt <<<"$j")" = "2" ] || {
    echo "first_rc=$first_rc rc=$RCC_EXIT live='$live' record=$j" >&2
    return 1
  }
}

# A: --refresh writes nothing when the latest result is already PASS.
test_refresh_noop_when_latest_passes() {
  _setup
  _write_tasks "TEST-34" "- [x] 1.1 a"
  local log="$_ws/TEST-34-pipeline.log"
  _rcc_logged "$log" "TEST-34"
  _rcc_logged "$log" "TEST-34" --refresh
  local n status
  n=$(_rc_lines "$log")
  status=$(sed -n 's/^RETURN_COMPLETENESS_STATUS=//p' "$_ws/out.env")
  _teardown
  [ "$RCC_EXIT" -eq 0 ] && [ "$n" -eq 1 ] && [ "$status" = "current" ] || {
    echo "rc=$RCC_EXIT lines=$n status=$status" >&2
    return 1
  }
}

# A: boxes still open after verify → refresh records FAIL again (gate keeps blocking).
test_refresh_still_incomplete_stays_failing() {
  _setup
  _write_tasks "TEST-35" "- [x] 1.1 a"$'\n'"- [ ] 1.2 b"
  local log="$_ws/TEST-35-pipeline.log"
  _rcc_logged "$log" "TEST-35"
  _rcc_logged "$log" "TEST-35" --refresh
  local n live
  n=$(_rc_lines "$log")
  # shellcheck source=/dev/null
  live=$(source "$LIB_DIR/verifier-result.sh" && verifier_latest_verdict "$log")
  _teardown
  [ "$RCC_EXIT" -eq 1 ] && [ "$n" -eq 2 ] && [ "$live" = "return_completeness|IMPLEMENT|FAIL" ] || {
    echo "rc=$RCC_EXIT lines=$n live='$live'" >&2
    return 1
  }
}

# ── Runner ─────────────────────────────────────────────────────────────────────

echo "=== return-completeness-check.sh unit tests ==="
echo ""

_run "all boxes checked → exit 0" test_all_checked_exits_0
_run "unchecked box → exit 1" test_unchecked_box_exits_1
_run "multiple unchecked boxes counted correctly" test_multiple_unchecked_counted
_run "missing tasks.md → exit 2" test_missing_tasks_file_exits_2
_run "--tasks-file flag bypasses repo search" test_tasks_file_flag_bypasses_search
_run "UNCHECKED_ITEMS lists unchecked line content" test_unchecked_items_lists_content
_run "simple-fix all checked → exit 0" test_simple_fix_all_checked_exits_0
_run "simple-fix unchecked box → exit 1" test_simple_fix_unchecked_box_exits_1
_run "simple-fix missing checklist section → exit 2" test_simple_fix_missing_checklist_exits_2
_run "TEST-7 ignores test-77 tasks.md (whole-ID)" test_whole_id_tasks_not_matched_by_longer_id
_run "TEST-7 ignores test-77 simple-fix.md (whole-ID)" test_whole_id_simple_fix_not_matched_by_longer_id
_run "#598 C: PASS records n/n, not 1/1" test_pass_records_real_box_count
_run "#598 B: --log-file records with LOG_FILE/TAP_LOG unset" test_log_file_flag_records_without_env
_run "#598 B: no pipeline log is loud, not silent" test_no_log_is_loud
_run "#598 A: --refresh PASS supersedes stale FAIL" test_refresh_supersedes_stale_fail
_run "#598 A: --refresh no-op when latest is PASS" test_refresh_noop_when_latest_passes
_run "#598 A: --refresh keeps FAIL when boxes stay open" test_refresh_still_incomplete_stays_failing

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
