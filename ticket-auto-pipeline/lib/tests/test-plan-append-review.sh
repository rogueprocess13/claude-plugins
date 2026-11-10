#!/usr/bin/env bash
# test-plan-append-review.sh — unit tests for lib/plan-append-review.sh,
# ticket-pr-iterate Steps 3–4 (skill-deterministic-extraction 2).
#
# Expected log lines and the iteration-guard message are fixtures lifted from
# the pre-extraction SKILL.md (fixtures/pr-review/iterate-*), timestamps
# masked.
# Usage: bash test-plan-append-review.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
PAR="$LIB_DIR/plan-append-review.sh"
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

unset LOG_FILE TAP_LOG HB_LOG_FILE REPOS_ROOT

_ws=""
# _setup [reviews] — a simple-fix ticket dir holding <reviews> PR Review sections.
_setup() {
  _ws=$(mktemp -d)
  mkdir -p "$_ws/TEST-7--fix-login"
  : >"$_ws/log"
  {
    printf '# Simple fix\n\n## Completion Checklist\n- [x] done\n'
    local i
    for ((i = 1; i <= ${1:-0}; i++)); do printf '\n## PR Review #%d — 2026-11-0%d\n\nold\n' "$i" "$i"; done
  } >"$_ws/TEST-7--fix-login/simple-fix.md"
}
_teardown() { rm -rf "$_ws" 2>/dev/null || true; }

_par() {
  _rc=0
  _out=$(cd "$_ws" && bash "$PAR" "$1" TEST-7 --ticket-dir "$_ws/TEST-7--fix-login" \
    --log-file "$_ws/log" "${@:2}" 2>/dev/null) || _rc=$?
}

_section() {
  printf '## PR Review #%s — 2026-11-10\n\n**Source:** PR #12\n**Verdict:** 1 gap(s) found\n' "$1" >"$_ws/section.md"
}

test_next_counts_existing_sections() {
  _setup 1
  _par next
  local ok=1
  [ "$_rc" = 0 ] && grep -qx 'N=2' <<<"$_out" && grep -qx 'PLAN_MODE=simple-fix' <<<"$_out" &&
    grep -qx 'ARTIFACT=simple-fix.md' <<<"$_out" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_next_first_iteration_is_one() {
  _setup 0
  _par next
  local ok=1
  [ "$_rc" = 0 ] && grep -qx 'N=1' <<<"$_out" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_iteration_guard_stops_past_three() {
  _setup 3
  _par next
  local ok=1
  [ "$_rc" = 4 ] && diff <(tail -1 <<<"$_out") "$FX/iterate-guard.msg" >/dev/null || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_no_plan_artifact_exits_12() {
  _setup 0
  rm "$_ws/TEST-7--fix-login/simple-fix.md"
  _par next
  local ok=1
  [ "$_rc" = 12 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_append_writes_section_and_logs_fixture() {
  _setup 1
  _section 2
  _par append --n 2 --section "$_ws/section.md"
  local ok=1 f="$_ws/TEST-7--fix-login/simple-fix.md"
  [ "$_rc" = 0 ] &&
    diff <(sed -E 's/^[^|]+\|/TS|/' "$_ws/log") "$FX/iterate-plan-done.log" >/dev/null &&
    [ "$(grep -c '^## PR Review #' "$f")" = 2 ] &&
    diff <(tail -n 4 "$f") "$_ws/section.md" >/dev/null &&
    [ "$(tail -n 6 "$f" | head -2 | tr -d '\n')" = "old" ] || ok=0
  ls -A "$_ws/TEST-7--fix-login" | grep -q '^\.simple-fix' && ok=0
  _teardown
  [ "$ok" = 1 ]
}

# A resumed run re-appending the same N writes nothing twice.
test_append_is_idempotent() {
  _setup 1
  _section 2
  _par append --n 2 --section "$_ws/section.md"
  _par append --n 2 --section "$_ws/section.md"
  local ok=1
  [ "$_rc" = 0 ] && [ "$(grep -c '^## PR Review #2' "$_ws/TEST-7--fix-login/simple-fix.md")" = 1 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_append_rejects_wrong_heading() {
  _setup 1
  _section 3
  _par append --n 2 --section "$_ws/section.md"
  local ok=1
  [ "$_rc" = 3 ] && [ ! -s "$_ws/log" ] && [ "$(grep -c '^## PR Review #' "$_ws/TEST-7--fix-login/simple-fix.md")" = 1 ] || ok=0
  _section 22
  _par append --n 2 --section "$_ws/section.md"
  [ "$_rc" = 3 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_append_openspec_tasks() {
  _ws=$(mktemp -d)
  mkdir -p "$_ws/TEST-7--x" "$_ws/openspec/changes/test-7-fix-login"
  printf '## 1. Fix\n- [x] 1.1 done\n' >"$_ws/openspec/changes/test-7-fix-login/tasks.md"
  : >"$_ws/log"
  _section 1
  _out=$(cd "$_ws" && bash "$PAR" append TEST-7 --ticket-dir "$_ws/TEST-7--x" --log-file "$_ws/log" \
    --n 1 --section "$_ws/section.md" 2>/dev/null) || _rc=$?
  local ok=1
  [ "${_rc:-0}" = 0 ] && grep -q '^## PR Review #1' "$_ws/openspec/changes/test-7-fix-login/tasks.md" &&
    grep -q '|PR-REVIEW|iterate-plan|done|tasks.md updated, iteration #1$' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_skill_steps_call_the_script() {
  local skill="$PLUGIN_DIR/skills/ticket-pr-iterate/SKILL.md"
  grep -q 'plan-append-review.sh next' "$skill" && grep -q 'plan-append-review.sh append' "$skill" &&
    ! grep -q '_section_count=' "$skill"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  _rc=0
  _run "$t" "$t"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
