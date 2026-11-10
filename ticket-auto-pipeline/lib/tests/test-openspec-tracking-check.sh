#!/usr/bin/env bash
# test-openspec-tracking-check.sh — tests for lib/openspec-tracking-check.sh
# Covers the durability guard for openspec plan artifacts (issue #363,
# OPENSPEC_ARTIFACTS_UNTRACKED): commit (idempotent git add -f + commit),
# assert (close-out warn check), assert-warn (ticket-implement Step 5.5 in one
# call, skill-deterministic-extraction 5) and audit (one-off sweep).
#
# fixtures/openspec-assert-warn/<case>.{log,notes} were produced by running the
# pre-extraction Step 5.5 fences of ticket-implement SKILL.md (main @ 20b4113:
# the EXPECT_FLAG/assert block, then on a non-zero ASSERT_RC the gate-warn line
# and the notes.md entry with its placeholders filled from the assert output)
# over the workspaces _aw_ws builds — never by the script. Timestamps are
# masked to TS, the date to DATE, the workspace path to $WS.
# With OTC_TEST_LIB_ONLY=1 the file only defines its helpers.
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
CHECK="$LIB_DIR/openspec-tracking-check.sh"

PASS=0
FAIL=0

_pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_fail() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}

_ws=""

_setup() {
  _ws="$(mktemp -d)"
  git init -q "$_ws"
  git -C "$_ws" config user.email t@t.com
  git -C "$_ws" config user.name Test
  git -C "$_ws" commit -q --allow-empty -m init
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

# Seeds a blanket `openspec/` ignore rule in the mock tickets repo, mirroring
# the real-world convention that predates this durability requirement.
_seed_gitignore() {
  echo "openspec/" >"$_ws/.gitignore"
  git -C "$_ws" add .gitignore
  git -C "$_ws" commit -q -m "ignore openspec"
}

_write_change() {
  local ticket_lower="$1"
  mkdir -p "$_ws/openspec/changes/${ticket_lower}--fix-thing"
  printf '# tasks\n- [ ] do it\n' >"$_ws/openspec/changes/${ticket_lower}--fix-thing/tasks.md"
}

# ── assert-warn workspaces ────────────────────────────────────────────────

AW_FX="$TEST_DIR/fixtures/openspec-assert-warn"
AW_CASES="simple tracked gitignored missing"

_aw_ws() { # case
  _setup
  _ws=$(cd "$_ws" && pwd -P)
  mkdir -p "$_ws/home/.claude/skills" "$_ws/logs" "$_ws/WIL-30--fix-thing"
  ln -s "$LIB_DIR" "$_ws/home/.claude/skills/lib"
  export HOME="$_ws/home" TAP_LOG="$_ws/logs/WIL-30-pipeline.log"
  unset LOG_FILE HB_LOG_FILE
  printf '# Notes\n\n## Session Log\n' >"$_ws/WIL-30--fix-thing/notes.md"
  : >"$TAP_LOG"
  printf 'openspec/\nlogs/\nhome/\n' >"$_ws/.gitignore"
  git -C "$_ws" add .gitignore
  git -C "$_ws" commit -q -m ignore
  case "$1" in
  simple) printf '# fix\n' >"$_ws/WIL-30--fix-thing/simple-fix.md" ;;
  tracked)
    _write_change wil-30
    git -C "$_ws" add -f openspec/
    git -C "$_ws" commit -q -m plan
    ;;
  gitignored) _write_change wil-30 ;;
  missing) ;;
  esac
}
_aw_mask() {
  sed -e "s|$_ws|\$WS|g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g' \
    -e 's/^### [0-9]\{4\}-[0-9][0-9]-[0-9][0-9] —/### DATE —/'
}

[ "${OTC_TEST_LIB_ONLY:-0}" = 1 ] && return 0

# ── assert-warn ───────────────────────────────────────────────────────────

test_assert_warn_parity_with_step_5_5() {
  local c rc out want bad=0
  for c in $AW_CASES; do
    _aw_ws "$c"
    rc=0
    out=$(cd /tmp && bash "$CHECK" assert-warn WIL-30 --root "$_ws" --ticket-dir "$_ws/WIL-30--fix-thing") || rc=$?
    case "$c" in simple | tracked) want=0 ;; *) want=1 ;; esac
    [ "$rc" = "$want" ] || {
      echo "  $c: rc=$rc want $want"
      bad=1
    }
    [ "$(_aw_mask <"$TAP_LOG")" = "$(cat "$AW_FX/$c.log")" ] || {
      echo "  $c: log differs"
      bad=1
    }
    [ "$(_aw_mask <"$_ws/WIL-30--fix-thing/notes.md")" = "$(cat "$AW_FX/$c.notes")" ] || {
      echo "  $c: notes differ"
      diff <(_aw_mask <"$_ws/WIL-30--fix-thing/notes.md") "$AW_FX/$c.notes" | sed 's/^/    /' || true
      bad=1
    }
    _teardown
  done
  [ "$bad" = 0 ]
}

test_assert_warn_no_log_file_is_set_e_safe() {
  _aw_ws gitignored
  unset TAP_LOG
  local rc=0
  (
    set -e
    cd /tmp && bash "$CHECK" assert-warn WIL-30 --root "$_ws" --ticket-dir "$_ws/WIL-30--fix-thing" >/dev/null 2>&1
  ) || rc=$?
  local n
  n=$(grep -c 'plan artifact durability warning' "$_ws/WIL-30--fix-thing/notes.md" || true)
  _teardown
  [ "$rc" = 1 ] && [ "$n" = 1 ]
}

test_assert_warn_usage() {
  local rc=0
  bash "$CHECK" assert-warn WIL-30 --root /tmp >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ]
}

# ── commit ────────────────────────────────────────────────────────────────

test_commit_force_adds_gitignored_dir() {
  _setup
  _seed_gitignore
  _write_change "wil-1"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-1--fix-thing/" WIL-1) || rc=$?
  local tracked
  tracked=$(git -C "$_ws" ls-files -- openspec/changes/wil-1--fix-thing/ | wc -l | tr -d ' ')
  _teardown
  [ "$rc" -eq 0 ] && grep -q 'OPENSPEC_COMMIT_STATUS=committed' <<<"$out" && [ "$tracked" -eq 1 ]
}

test_commit_is_idempotent_noop_on_rerun() {
  _setup
  _seed_gitignore
  _write_change "wil-2"
  (cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-2--fix-thing/" WIL-2 >/dev/null)
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-2--fix-thing/" WIL-2) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && grep -q 'OPENSPEC_COMMIT_STATUS=noop' <<<"$out"
}

test_commit_picks_up_regenerated_content() {
  _setup
  _seed_gitignore
  _write_change "wil-3"
  (cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-3--fix-thing/" WIL-3 >/dev/null)
  echo "- [ ] a second task" >>"$_ws/openspec/changes/wil-3--fix-thing/tasks.md"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-3--fix-thing/" WIL-3) || rc=$?
  local log_count
  log_count=$(git -C "$_ws" log --oneline -- openspec/changes/wil-3--fix-thing/ | wc -l | tr -d ' ')
  _teardown
  [ "$rc" -eq 0 ] && grep -q 'OPENSPEC_COMMIT_STATUS=committed' <<<"$out" && [ "$log_count" -eq 2 ]
}

test_commit_errors_on_missing_dir() {
  _setup
  local rc=0
  (cd "$_ws" && bash "$CHECK" commit "openspec/changes/nope--x/" WIL-4) >/dev/null 2>&1 || rc=$?
  _teardown
  [ "$rc" -eq 2 ]
}

test_commit_errors_outside_git_repo() {
  local nogit
  nogit="$(mktemp -d)"
  mkdir -p "$nogit/openspec/changes/wil-5--x"
  echo x >"$nogit/openspec/changes/wil-5--x/tasks.md"
  local rc=0
  (cd "$nogit" && bash "$CHECK" commit "openspec/changes/wil-5--x/" WIL-5) >/dev/null 2>&1 || rc=$?
  rm -rf "$nogit"
  [ "$rc" -eq 2 ]
}

# ── assert ────────────────────────────────────────────────────────────────

test_assert_reports_gitignored_before_commit() {
  _setup
  _seed_gitignore
  _write_change "wil-6"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-6) || rc=$?
  _teardown
  [ "$rc" -eq 1 ] && grep -q 'OPENSPEC_TRACK_STATUS=gitignored' <<<"$out"
}

test_assert_reports_tracked_after_commit() {
  _setup
  _seed_gitignore
  _write_change "wil-7"
  (cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-7--fix-thing/" WIL-7 >/dev/null)
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-7) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && grep -q 'OPENSPEC_TRACK_STATUS=tracked' <<<"$out"
}

test_assert_no_change_dir_without_expect_is_not_applicable() {
  _setup
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-8) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && grep -q 'OPENSPEC_TRACK_STATUS=not-applicable' <<<"$out"
}

test_assert_no_change_dir_with_expect_is_missing() {
  _setup
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-9 --expect) || rc=$?
  _teardown
  [ "$rc" -eq 1 ] && grep -q 'OPENSPEC_TRACK_STATUS=missing' <<<"$out"
}

test_assert_untracked_but_not_ignored() {
  _setup
  _write_change "wil-10"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-10) || rc=$?
  _teardown
  [ "$rc" -eq 1 ] && grep -q 'OPENSPEC_TRACK_STATUS=untracked' <<<"$out"
}

test_assert_partial_when_some_files_committed_some_not() {
  _setup
  _write_change "wil-11"
  git -C "$_ws" add openspec/changes/wil-11--fix-thing/tasks.md
  git -C "$_ws" commit -q -m "partial commit"
  echo "extra" >"$_ws/openspec/changes/wil-11--fix-thing/design.md"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-11) || rc=$?
  _teardown
  [ "$rc" -eq 1 ] && grep -q 'OPENSPEC_TRACK_STATUS=partial' <<<"$out"
}

test_assert_reports_partial_for_uncommitted_modification_to_tracked_file() {
  _setup
  _write_change "wil-17"
  git -C "$_ws" add -f openspec/changes/wil-17--fix-thing/
  git -C "$_ws" commit -q -m "commit clean"
  echo "- [ ] a second, uncommitted task" >>"$_ws/openspec/changes/wil-17--fix-thing/tasks.md"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-17) || rc=$?
  _teardown
  [ "$rc" -eq 1 ] &&
    grep -q 'OPENSPEC_TRACK_STATUS=partial' <<<"$out" &&
    ! grep -q 'OPENSPEC_TRACK_STATUS=tracked' <<<"$out"
}

test_assert_reports_partial_for_staged_but_uncommitted_modification() {
  _setup
  _write_change "wil-18"
  git -C "$_ws" add -f openspec/changes/wil-18--fix-thing/
  git -C "$_ws" commit -q -m "commit clean"
  echo "- [ ] a second, staged task" >>"$_ws/openspec/changes/wil-18--fix-thing/tasks.md"
  git -C "$_ws" add openspec/changes/wil-18--fix-thing/tasks.md
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-18) || rc=$?
  _teardown
  [ "$rc" -eq 1 ] && grep -q 'OPENSPEC_TRACK_STATUS=partial' <<<"$out"
}

test_assert_root_flag_resolves_correctly_from_arbitrary_cwd() {
  _setup
  _write_change "wil-19"
  git -C "$_ws" add -f openspec/changes/wil-19--fix-thing/
  git -C "$_ws" commit -q -m "commit"
  local out rc=0
  # Deliberately invoked from an unrelated CWD (not $_ws) — --root must be
  # the only thing that matters, never ambient pwd.
  out=$(cd /tmp && bash "$CHECK" assert WIL-19 --root "$_ws") || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && grep -q 'OPENSPEC_TRACK_STATUS=tracked' <<<"$out"
}

test_assert_root_flag_with_untracked_change_from_arbitrary_cwd() {
  _setup
  _seed_gitignore
  _write_change "wil-20"
  local out rc=0
  out=$(cd /tmp && bash "$CHECK" assert WIL-20 --root "$_ws") || rc=$?
  _teardown
  [ "$rc" -eq 1 ] && grep -q 'OPENSPEC_TRACK_STATUS=gitignored' <<<"$out"
}

test_commit_refuses_path_outside_openspec_changes() {
  _setup
  local rc=0
  (cd "$_ws" && bash "$CHECK" commit "/etc" WIL-21) >/dev/null 2>&1 || rc=$?
  _teardown
  [ "$rc" -eq 2 ]
}

test_commit_refuses_path_traversal_outside_openspec_changes() {
  _setup
  local rc=0
  (cd "$_ws" && bash "$CHECK" commit "../../../../etc" WIL-22) >/dev/null 2>&1 || rc=$?
  _teardown
  [ "$rc" -eq 2 ]
}

# Round 3 finding 2: a bare string-prefix check on the *unresolved* path is
# bypassable — "openspec/changes/foo/../../../<target>" still starts with
# the literal text "openspec/changes/" even though, once the embedded ".."
# components collapse, it resolves to a sibling of openspec/changes/ — the
# exact repro was force-committing a gitignored secrets file elsewhere in
# the repo via this trick. The guard must reject based on the *resolved*
# path, not a prefix test on the unresolved one.
test_commit_refuses_traversal_embedded_after_valid_prefix() {
  # Directory target, not a file: `_cmd_commit`'s own `[ ! -d "$dir" ]` guard
  # rejects a file target before the traversal guard is ever reached, which
  # would make this test pass even against the pre-fix string-prefix check
  # (round 2) for the wrong reason. A directory target is what the real
  # repro used and what actually exercises the resolved-path guard.
  _setup
  _write_change "wil-23"
  mkdir -p "$_ws/secrets_dir"
  echo "topsecret" >"$_ws/secrets_dir/creds.env"
  local rc=0
  (cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-23--fix-thing/../../../secrets_dir" WIL-23) >/dev/null 2>&1 || rc=$?
  local leaked=0
  git -C "$_ws" ls-files 2>/dev/null | grep -qx "secrets_dir/creds.env" && leaked=1
  _teardown
  [ "$rc" -eq 2 ] && [ "$leaked" -eq 0 ]
}

# Round 3 finding 1: ticket-implement's Step 5.5 remediation snippet writes
# the literal CHANGE_DIR `assert --root` emitted (absolute, since --root was
# non-".") straight into `commit`'s <change-dir> argument. That must work —
# a resolved-path check accepts an absolute path under the right directory
# just as readily as a relative one.
test_commit_accepts_absolute_change_dir_from_assert_root() {
  _setup
  _write_change "wil-24"
  local assert_out change_dir rc=0 out
  assert_out=$(cd /tmp && bash "$CHECK" assert WIL-24 --root "$_ws") || true
  change_dir=$(echo "$assert_out" | grep '^CHANGE_DIR=' | cut -d= -f2-)
  case "$change_dir" in
  /*) ;;
  *)
    _teardown
    return 1
    ;;
  esac
  out=$(cd "$_ws" && bash "$CHECK" commit "$change_dir" WIL-24) || rc=$?
  local tracked
  tracked=$(git -C "$_ws" ls-files -- openspec/changes/wil-24--fix-thing/ | wc -l | tr -d ' ')
  _teardown
  [ "$rc" -eq 0 ] && grep -q 'OPENSPEC_COMMIT_STATUS=committed' <<<"$out" && [ "$tracked" -eq 1 ]
}

test_assert_is_case_insensitive_on_ticket_id() {
  _setup
  _write_change "wil-12"
  git -C "$_ws" add -f openspec/changes/wil-12--fix-thing/
  git -C "$_ws" commit -q -m "commit"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert wil-12) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && grep -q 'OPENSPEC_TRACK_STATUS=tracked' <<<"$out"
}

# ── audit ─────────────────────────────────────────────────────────────────

test_audit_reports_all_clean() {
  _setup
  _write_change "wil-13"
  git -C "$_ws" add -f openspec/changes/wil-13--fix-thing/
  git -C "$_ws" commit -q -m "commit"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" audit) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && grep -q 'OPENSPEC_TRACK_SUMMARY|total=1|issues=0' <<<"$out"
}

test_audit_detects_existing_untracked_changes() {
  _setup
  _seed_gitignore
  _write_change "wil-14"
  _write_change "wil-15"
  git -C "$_ws" add -f openspec/changes/wil-15--fix-thing/
  git -C "$_ws" commit -q -m "commit one of two"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" audit) || rc=$?
  _teardown
  [ "$rc" -eq 1 ] &&
    grep -q 'wil-14--fix-thing.*gitignored' <<<"$out" &&
    grep -q 'wil-15--fix-thing.*tracked' <<<"$out" &&
    grep -q 'OPENSPEC_TRACK_SUMMARY|total=2|issues=1' <<<"$out"
}

test_audit_with_explicit_root() {
  _setup
  _write_change "wil-16"
  git -C "$_ws" add -f openspec/changes/wil-16--fix-thing/
  git -C "$_ws" commit -q -m "commit"
  local out rc=0
  out=$(bash "$CHECK" audit --root "$_ws") || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && grep -q 'OPENSPEC_TRACK_SUMMARY|total=1|issues=0' <<<"$out"
}

test_audit_no_changes_is_clean() {
  _setup
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" audit) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && grep -q 'OPENSPEC_TRACK_SUMMARY|total=0|issues=0' <<<"$out"
}

# DET-IP-2: TEST-7 must not resolve to another ticket's test-77-* change dir.
test_assert_whole_id_does_not_match_longer_id() {
  _setup
  mkdir -p "$_ws/openspec/changes/test-77-other-ticket"
  echo "- [ ] x" >"$_ws/openspec/changes/test-77-other-ticket/tasks.md"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert TEST-7) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && grep -q 'OPENSPEC_TRACK_STATUS=not-applicable' <<<"$out" &&
    ! grep -q 'test-77' <<<"$out"
}

test_assert_whole_id_picks_own_dir_beside_longer_id() {
  _setup
  mkdir -p "$_ws/openspec/changes/test-77-other-ticket" "$_ws/openspec/changes/test-7-mine"
  echo "- [ ] x" >"$_ws/openspec/changes/test-77-other-ticket/tasks.md"
  echo "- [ ] y" >"$_ws/openspec/changes/test-7-mine/tasks.md"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert TEST-7) || rc=$?
  _teardown
  grep -q '^CHANGE_DIR=openspec/changes/test-7-mine/$' <<<"$out"
}

test_assert_two_change_dirs_is_ambiguous() {
  _setup
  mkdir -p "$_ws/openspec/changes/wil-30-a" "$_ws/openspec/changes/wil-30-b"
  echo x >"$_ws/openspec/changes/wil-30-a/tasks.md"
  echo x >"$_ws/openspec/changes/wil-30-b/tasks.md"
  local out err rc=0
  err=$(mktemp)
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-30 2>"$err") || rc=$?
  local both=0
  grep -q 'wil-30-a' "$err" && grep -q 'wil-30-b' "$err" && both=1
  rm -f "$err"
  _teardown
  [ "$rc" -eq 1 ] && grep -q 'OPENSPEC_TRACK_STATUS=ambiguous' <<<"$out" && [ "$both" -eq 1 ]
}

test_usage_exits_2_with_no_args() {
  local rc=0
  bash "$CHECK" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

# ── Runner ───────────────────────────────────────────────────────────────────

for t in test_commit_force_adds_gitignored_dir test_commit_is_idempotent_noop_on_rerun \
  test_commit_picks_up_regenerated_content test_commit_errors_on_missing_dir \
  test_commit_errors_outside_git_repo test_assert_reports_gitignored_before_commit \
  test_assert_reports_tracked_after_commit test_assert_no_change_dir_without_expect_is_not_applicable \
  test_assert_no_change_dir_with_expect_is_missing test_assert_untracked_but_not_ignored \
  test_assert_partial_when_some_files_committed_some_not \
  test_assert_reports_partial_for_uncommitted_modification_to_tracked_file \
  test_assert_reports_partial_for_staged_but_uncommitted_modification \
  test_assert_root_flag_resolves_correctly_from_arbitrary_cwd \
  test_assert_root_flag_with_untracked_change_from_arbitrary_cwd \
  test_commit_refuses_path_outside_openspec_changes \
  test_commit_refuses_path_traversal_outside_openspec_changes \
  test_commit_refuses_traversal_embedded_after_valid_prefix \
  test_commit_accepts_absolute_change_dir_from_assert_root \
  test_assert_is_case_insensitive_on_ticket_id \
  test_audit_reports_all_clean test_audit_detects_existing_untracked_changes \
  test_audit_with_explicit_root test_audit_no_changes_is_clean test_usage_exits_2_with_no_args \
  test_assert_whole_id_does_not_match_longer_id test_assert_whole_id_picks_own_dir_beside_longer_id \
  test_assert_two_change_dirs_is_ambiguous test_assert_warn_parity_with_step_5_5 \
  test_assert_warn_no_log_file_is_set_e_safe test_assert_warn_usage; do
  if "$t"; then
    _pass "$t"
  else
    _fail "$t"
  fi
done

echo ""
echo "=== test-openspec-tracking-check.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
