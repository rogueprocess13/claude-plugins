#!/usr/bin/env bash
# test-retro-lib-layout.sh — regression test for GitHub #600.
#
# retro.sh resolved its lib dir as `<script dir>/../lib`. That is right in the
# synced skills layout (~/.claude/skills/ticket-retro -> ~/.claude/skills/lib)
# but wrong in the plugin layout (<plugin>/skills/ticket-retro -> <plugin>/lib),
# where `<plugin>/skills/lib` does not exist. notes-parse.sh was then silently
# skipped, heartbeat.sh never got sourced, and the cursor write died on an
# undefined `_iso_now` with exit 127 after the JSON was already printed.
#
# This runs a copy of retro.sh from both layouts, with no `_iso_now` in the
# environment (the other retro suites export a stub; this one must not), and
# asserts exit 0, a written cursor file, and that the layout's own
# notes-parse.sh was the one sourced.
#
# Usage: bash test-retro-lib-layout.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RETRO_SRC="$(cd "$LIB_DIR/../skills/ticket-retro" && pwd)/retro.sh"
FILTER="${1:-}"

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

_TMP=$(mktemp -d)
trap 'rm -rf "$_TMP"' EXIT

# No inherited stub: the bug only shows when nothing else defines _iso_now.
unset -f _iso_now 2>/dev/null || true

# _layout <root> <skills-dir> <lib-dir> — copies retro.sh and the lib into the
# given layout, and marks the copied notes-parse.sh so the test can prove it
# was sourced from there.
_layout() {
  local skills_dir="$1" lib_dir="$2"
  mkdir -p "$skills_dir/ticket-retro" "$lib_dir"
  cp "$RETRO_SRC" "$skills_dir/ticket-retro/retro.sh"
  cp "$LIB_DIR"/*.sh "$lib_dir/"
  printf '\n: >"${RETRO_LAYOUT_MARKER:-/dev/null}"\n' >>"$lib_dir/notes-parse.sh"
}

# _run_retro <retro.sh> <workdir> — runs a window scan of one fresh log.
_run_retro() {
  local retro="$1" work="$2"
  mkdir -p "$work/logs"
  cat >"$work/logs/LAY-1-pipeline.log" <<'EOF'
2026-08-31T20:00:00Z|META|schema|info|1
2026-08-31T20:01:00Z|META|gate-stop|fail|EXEC_NO_ARTIFACT missing simple-fix.md
EOF
  (
    cd "$work"
    env -i PATH="$PATH" HOME="$work" \
      CURSOR_FILE="$work/cursor.json" REPOS_ROOT="$work/reposroot" \
      RETRO_LAYOUT_MARKER="$work/marker" \
      bash "$retro" --window 3650 >"$work/out.json" 2>"$work/err.txt"
  )
}

_assert_ran_clean() {
  local work="$1" rc="$2"
  [ "$rc" -eq 0 ] || {
    echo "  exit $rc: $(cat "$work/err.txt")"
    return 1
  }
  ! grep -q 'command not found' "$work/err.txt" || {
    echo "  stderr: $(cat "$work/err.txt")"
    return 1
  }
  [ -f "$work/marker" ] || {
    echo "  notes-parse.sh of this layout was not sourced"
    return 1
  }
  ! grep -q 'using fallback' "$work/err.txt" || {
    echo "  unexpected fallback: $(cat "$work/err.txt")"
    return 1
  }
  jq -e '."LAY-1".scanned_at | test("^[0-9]{4}-")' "$work/cursor.json" >/dev/null || {
    echo "  cursor not written: $(cat "$work/cursor.json" 2>/dev/null)"
    return 1
  }
}

test_plugin_layout() {
  local root="$_TMP/plugin" rc=0
  _layout "$root/skills" "$root/lib"
  [ ! -d "$root/skills/lib" ] || return 1
  _run_retro "$root/skills/ticket-retro/retro.sh" "$_TMP/work-plugin" || rc=$?
  _assert_ran_clean "$_TMP/work-plugin" "$rc"
}

test_synced_skills_layout() {
  local root="$_TMP/home/.claude/skills" rc=0
  _layout "$root" "$root/lib"
  _run_retro "$root/ticket-retro/retro.sh" "$_TMP/work-skills" || rc=$?
  _assert_ran_clean "$_TMP/work-skills" "$rc"
}

test_missing_lib_warns_and_still_writes_cursor() {
  # No lib in either place: retro.sh must say so on stderr (one line per
  # fallback) instead of degrading silently, and still write the cursor.
  local root="$_TMP/bare" work="$_TMP/work-bare" rc=0
  mkdir -p "$root/skills/ticket-retro"
  cp "$RETRO_SRC" "$root/skills/ticket-retro/retro.sh"
  _run_retro "$root/skills/ticket-retro/retro.sh" "$work" || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "  exit $rc: $(cat "$work/err.txt")"
    return 1
  }
  grep -q '^retro: notes-parse.sh not found under .*, using fallback$' "$work/err.txt" &&
    grep -q '^retro: heartbeat.sh not loaded from .*, using fallback _iso_now$' "$work/err.txt" || {
    echo "  missing fallback warning: $(cat "$work/err.txt")"
    return 1
  }
  jq -e '."LAY-1".scanned_at | test("^[0-9]{4}-")' "$work/cursor.json" >/dev/null
}

for fn in test_plugin_layout test_synced_skills_layout test_missing_lib_warns_and_still_writes_cursor; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
