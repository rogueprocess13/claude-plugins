#!/usr/bin/env bash
# test-ticket-dir.sh — unit tests for lib/ticket-dir.sh
# Covers resolve_ticket_dir and the 3-tier resolve_plan_path fallback chain.
# Usage: bash test-ticket-dir.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# ── resolve_ticket_dir tests ──────────────────────────────────────────────────

test_resolves_single_match() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/WIL-42--fix-login"
  local result
  result=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_ticket_dir WIL-42 '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [[ "$result" == *"WIL-42--fix-login"* ]]
}

test_no_match_exits_1() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local exit_code=0
  bash -c "source $LIB_DIR/ticket-dir.sh; resolve_ticket_dir WIL-99 '$tmpdir'" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  # Migration to error-handler.sh: E_ENV=12 for directory-not-found
  [ "$exit_code" -eq 12 ]
}

test_multiple_matches_exits_2() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/WIL-42--fix-login"
  mkdir -p "$tmpdir/WIL-42--old-attempt"
  local exit_code=0
  bash -c "source $LIB_DIR/ticket-dir.sh; resolve_ticket_dir WIL-42 '$tmpdir'" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 2 ]
}

test_case_insensitive_match() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/wil-4--lowercase-dir"
  local result
  result=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_ticket_dir WIL-4 '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [[ "$result" == *"wil-4--lowercase-dir"* ]]
}

# ── resolve_plan_path tests ───────────────────────────────────────────────────

test_resolve_plan_from_log() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local tasks_file="$tmpdir/tasks.md"
  touch "$tasks_file"
  local log_file="$tmpdir/pipeline.log"
  echo "2024-01-01T00:00:00Z|META|artifact|info|plan:$tasks_file" >"$log_file"

  local result
  result=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_plan_path '$log_file' '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "$tasks_file" ]
}

test_resolve_plan_log_entry_stale() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local stale_path="/tmp/nonexistent-tasks-stale-$$.md"
  local log_file="$tmpdir/pipeline.log"
  echo "2024-01-01T00:00:00Z|META|artifact|info|plan:$stale_path" >"$log_file"

  # Tier 2: simple-fix.md exists in ticket dir
  local fix_file="$tmpdir/simple-fix.md"
  touch "$fix_file"

  local result
  result=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_plan_path '$log_file' '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "$fix_file" ]
}

test_resolve_plan_from_simple_fix() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file" # empty log — no artifact entry
  local fix_file="$tmpdir/simple-fix.md"
  touch "$fix_file"

  local result
  result=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_plan_path '$log_file' '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "$fix_file" ]
}

test_resolve_plan_from_openspec() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file"
  mkdir -p "$tmpdir/openspec/changes/wil-4-my-feature"
  touch "$tmpdir/openspec/changes/wil-4-my-feature/tasks.md"

  local result
  result=$(cd "$tmpdir" && bash -c "source $LIB_DIR/ticket-dir.sh; resolve_plan_path '$log_file' '$tmpdir' 'wil-4'" 2>/dev/null)
  rm -rf "$tmpdir"
  [[ "$result" == *"wil-4-my-feature/tasks.md"* ]]
}

test_resolve_plan_all_fail() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file"
  # No simple-fix.md, no openspec dir, no log artifact entry

  local exit_code=0
  bash -c "source $LIB_DIR/ticket-dir.sh; resolve_plan_path '$log_file' '$tmpdir'" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -ne 0 ]
}

# DET-IP-2: the legacy wrapper must not substring-match a longer id.
test_resolve_plan_path_whole_id() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file"
  mkdir -p "$tmpdir/openspec/changes/test-77-foo"
  touch "$tmpdir/openspec/changes/test-77-foo/tasks.md"
  local exit_code=0 result
  result=$(cd "$tmpdir" && bash -c "source $LIB_DIR/ticket-dir.sh; resolve_plan_path '$log_file' '$tmpdir/none' 'test-7'" 2>/dev/null) || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 12 ] && [ -z "$result" ]
}

# ── ticket_id_matches_name ────────────────────────────────────────────────────

test_matches_name_whole_id() {
  bash -c "
    source $LIB_DIR/ticket-dir.sh
    ticket_id_matches_name WIL-4 wil-4 &&
    ticket_id_matches_name WIL-4 wil-4-add-x &&
    ticket_id_matches_name WIL-4 WIL-4--slug &&
    ticket_id_matches_name wil-4 WIL-4-Upper &&
    ticket_id_matches_name WIL-4 wil-4-2fa-login &&
    ! ticket_id_matches_name WIL-4 wil-42-x &&
    ! ticket_id_matches_name WIL-4 wil-40 &&
    ! ticket_id_matches_name WIL-4 fix-wil-4-x &&
    ! ticket_id_matches_name WIL-4 wil-4x &&
    ! ticket_id_matches_name '' wil-4
  "
}

# ── resolve_change_dir ────────────────────────────────────────────────────────

test_change_dir_whole_id_beside_longer_ids() {
  local tmpdir r4 r42 rc=0
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/openspec/changes/wil-4-a" "$tmpdir/openspec/changes/wil-42-b" \
    "$tmpdir/openspec/changes/wil-40-c"
  r4=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_change_dir WIL-4 '$tmpdir'") || rc=$?
  r42=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_change_dir WIL-42 '$tmpdir'") || rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$r4" = "$tmpdir/openspec/changes/wil-4-a/" ] &&
    [ "$r42" = "$tmpdir/openspec/changes/wil-42-b/" ]
}

test_change_dir_no_substring_match_exits_12() {
  local tmpdir rc=0 out
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/openspec/changes/test-77-foo"
  out=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_change_dir TEST-7 '$tmpdir'" 2>/dev/null) || rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 12 ] && [ -z "$out" ]
}

test_change_dir_uppercase_name_and_relative_root() {
  local tmpdir out rc=0
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/openspec/changes/WIL-9-Upper-Case"
  out=$(cd "$tmpdir" && bash -c "source $LIB_DIR/ticket-dir.sh; resolve_change_dir wil-9") || rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$out" = "openspec/changes/WIL-9-Upper-Case/" ]
}

test_change_dir_ambiguous_exits_2_lists_both() {
  local tmpdir err rc=0
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/openspec/changes/wil-42-a" "$tmpdir/openspec/changes/wil-42-b"
  err=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_change_dir WIL-42 '$tmpdir'" 2>&1 >/dev/null) || rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 2 ] && [[ "$err" == *wil-42-a* ]] && [[ "$err" == *wil-42-b* ]]
}

test_change_dir_ignores_archive_dir() {
  local tmpdir rc=0
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/openspec/changes/archive/wil-5-old"
  bash -c "source $LIB_DIR/ticket-dir.sh; resolve_change_dir WIL-5 '$tmpdir'" >/dev/null 2>&1 || rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 12 ]
}

# ── resolve_plan_artifact ─────────────────────────────────────────────────────

# Runs resolve_plan_artifact in <cwd> and evals its output into PLAN_* vars.
_rpa() {
  local cwd="$1"
  shift
  PLAN_MODE="" PLAN_PATH="" CHANGE_DIR="" RPA_RC=0
  local out
  out=$(cd "$cwd" && bash -c "source $LIB_DIR/ticket-dir.sh; resolve_plan_artifact \"\$@\"" _ "$@" 2>/dev/null) || RPA_RC=$?
  eval "$out"
}

test_rpa_simple_fix() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/WIL-42--fix-login"
  touch "$t/WIL-42--fix-login/simple-fix.md"
  _rpa "$t" WIL-42
  rm -rf "$t"
  [ "$RPA_RC" -eq 0 ] && [ "$PLAN_MODE" = simple-fix ] &&
    [ "$PLAN_PATH" = "./WIL-42--fix-login/simple-fix.md" ] && [ -z "$CHANGE_DIR" ]
}

test_rpa_openspec() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/WIL-42--add-x" "$t/openspec/changes/wil-42-add-x"
  touch "$t/openspec/changes/wil-42-add-x/tasks.md"
  _rpa "$t" WIL-42
  rm -rf "$t"
  [ "$RPA_RC" -eq 0 ] && [ "$PLAN_MODE" = openspec ] &&
    [ "$PLAN_PATH" = "openspec/changes/wil-42-add-x/tasks.md" ] &&
    [ "$CHANGE_DIR" = "openspec/changes/wil-42-add-x/" ]
}

test_rpa_no_false_match_on_longer_id() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/TEST-77--other" "$t/openspec/changes/test-77-foo"
  touch "$t/TEST-77--other/simple-fix.md" "$t/openspec/changes/test-77-foo/tasks.md"
  _rpa "$t" TEST-7
  rm -rf "$t"
  [ "$RPA_RC" -eq 12 ] && [ -z "$PLAN_PATH" ]
}

test_rpa_ticket_dir_whole_id() {
  # WIL-4 must not pick up WIL-42--slug's simple-fix.md.
  local t
  t=$(mktemp -d)
  mkdir -p "$t/WIL-42--slug" "$t/WIL-4--mine"
  touch "$t/WIL-42--slug/simple-fix.md"
  _rpa "$t" WIL-4
  local rc1=$RPA_RC
  touch "$t/WIL-4--mine/simple-fix.md"
  _rpa "$t" WIL-4
  rm -rf "$t"
  [ "$rc1" -eq 12 ] && [ "$RPA_RC" -eq 0 ] && [ "$PLAN_PATH" = "./WIL-4--mine/simple-fix.md" ]
}

test_rpa_missing_artifact_exits_12() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/WIL-1--x" "$t/openspec/changes/wil-1-x" # change dir without tasks.md
  _rpa "$t" WIL-1
  rm -rf "$t"
  [ "$RPA_RC" -eq 12 ]
}

test_rpa_ambiguous_change_dirs_exits_2() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/openspec/changes/wil-42-a" "$t/openspec/changes/wil-42-b"
  touch "$t/openspec/changes/wil-42-a/tasks.md" "$t/openspec/changes/wil-42-b/tasks.md"
  _rpa "$t" WIL-42
  rm -rf "$t"
  [ "$RPA_RC" -eq 2 ]
}

test_rpa_stale_log_entry_falls_through() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/WIL-42--fix"
  touch "$t/WIL-42--fix/simple-fix.md"
  echo "2024-01-01T00:00:00Z|META|artifact|info|plan:$t/deleted/tasks.md" >"$t/p.log"
  _rpa "$t" WIL-42 --log-file "$t/p.log"
  rm -rf "$t"
  [ "$RPA_RC" -eq 0 ] && [ "$PLAN_MODE" = simple-fix ]
}

test_rpa_log_entry_wins() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/WIL-42--fix" "$t/openspec/changes/wil-42-x"
  touch "$t/WIL-42--fix/simple-fix.md" "$t/openspec/changes/wil-42-x/tasks.md"
  echo "2024-01-01T00:00:00Z|META|artifact|info|plan:openspec/changes/wil-42-x/tasks.md" >"$t/p.log"
  _rpa "$t" WIL-42 --log-file "$t/p.log"
  rm -rf "$t"
  [ "$RPA_RC" -eq 0 ] && [ "$PLAN_MODE" = openspec ] && [ "$CHANGE_DIR" = "openspec/changes/wil-42-x/" ]
}

test_rpa_root_flag_from_other_cwd() {
  local t other
  t=$(mktemp -d)
  other=$(mktemp -d)
  mkdir -p "$t/openspec/changes/wil-42-x"
  touch "$t/openspec/changes/wil-42-x/tasks.md"
  _rpa "$other" WIL-42 --root "$t"
  rm -rf "$t" "$other"
  [ "$RPA_RC" -eq 0 ] && [ "$PLAN_PATH" = "$t/openspec/changes/wil-42-x/tasks.md" ]
}

test_rpa_type_restricts_mode() {
  local t rc_os rc_sf path_os path_sf
  t=$(mktemp -d)
  mkdir -p "$t/WIL-42--fix" "$t/openspec/changes/wil-42-x"
  touch "$t/WIL-42--fix/simple-fix.md" "$t/openspec/changes/wil-42-x/tasks.md"
  _rpa "$t" WIL-42 --type openspec
  rc_os=$RPA_RC path_os=$PLAN_PATH
  rm "$t/WIL-42--fix/simple-fix.md"
  _rpa "$t" WIL-42 --type simple-fix
  rc_sf=$RPA_RC path_sf=$PLAN_PATH
  rm -rf "$t"
  [ "$rc_os" -eq 0 ] && [ "$path_os" = "openspec/changes/wil-42-x/tasks.md" ] &&
    [ "$rc_sf" -eq 12 ] && [ -z "$path_sf" ]
}

test_rpa_cli() {
  local t out rc=0
  t=$(mktemp -d)
  mkdir -p "$t/openspec/changes/wil-42-x"
  touch "$t/openspec/changes/wil-42-x/tasks.md"
  out=$(bash "$LIB_DIR/ticket-dir.sh" plan WIL-42 --root "$t" 2>/dev/null) || rc=$?
  rm -rf "$t"
  [ "$rc" -eq 0 ] && echo "$out" | grep -q '^PLAN_MODE=openspec$'
}

# ── resolve_artifact_type ─────────────────────────────────────────────────────

test_artifact_type_sources() {
  local t a b c d
  t=$(mktemp -d)
  echo "2024-01-01T00:00:00Z|EXEC|create-artifact|done|openspec" >"$t/exec.log"
  : >"$t/empty.log"
  printf '## Artifact\n- Artifact type: openspec:wil-42-add-x\n' >"$t/notes-os.md"
  printf 'nothing here\n' >"$t/notes-none.md"
  a=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_artifact_type '$t/exec.log' '$t/notes-none.md'")
  b=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_artifact_type '$t/empty.log' '$t/notes-os.md'")
  c=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_artifact_type '$t/empty.log' '$t/notes-none.md'")
  d=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_artifact_type '' ''")
  rm -rf "$t"
  [ "$a" = openspec ] && [ "$b" = openspec ] && [ -z "$c" ] && [ -z "$d" ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_resolves_single_match \
  test_no_match_exits_1 \
  test_multiple_matches_exits_2 \
  test_case_insensitive_match \
  test_resolve_plan_from_log \
  test_resolve_plan_log_entry_stale \
  test_resolve_plan_from_simple_fix \
  test_resolve_plan_from_openspec \
  test_resolve_plan_all_fail \
  test_resolve_plan_path_whole_id \
  test_matches_name_whole_id \
  test_change_dir_whole_id_beside_longer_ids \
  test_change_dir_no_substring_match_exits_12 \
  test_change_dir_uppercase_name_and_relative_root \
  test_change_dir_ambiguous_exits_2_lists_both \
  test_change_dir_ignores_archive_dir \
  test_rpa_simple_fix \
  test_rpa_openspec \
  test_rpa_no_false_match_on_longer_id \
  test_rpa_ticket_dir_whole_id \
  test_rpa_missing_artifact_exits_12 \
  test_rpa_ambiguous_change_dirs_exits_2 \
  test_rpa_stale_log_entry_falls_through \
  test_rpa_log_entry_wins \
  test_rpa_root_flag_from_other_cwd \
  test_rpa_type_restricts_mode \
  test_rpa_cli \
  test_artifact_type_sources; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
