#!/usr/bin/env bash
# test-retro-claude-log-marker.sh — regression test for
# skills/ticket-retro/retro.sh's scan_claude_log_failures (GitHub #207).
#
# The keyword list matched against a manually curated set of English-language
# failure phrases, missing the pipeline's own structured error marker
# (META|error|fail|). Structured errors with wording outside the keyword
# list (e.g. "ticket directory not found for X") were invisible to the
# Claude Log Failures section even though the pipeline itself already
# flagged them. This test asserts any META|error|fail| line is caught
# regardless of message wording.
#
# Usage: bash test-retro-claude-log-marker.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RETRO_SH="$(cd "$LIB_DIR/../skills/ticket-retro" && pwd)/retro.sh"

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

_TEST_TMPDIRS=()
_mktemp_test_dir() {
  local d
  d=$(mktemp -d)
  _TEST_TMPDIRS+=("$d")
  echo "$d"
}
_cleanup_test_tmpdirs() {
  local d
  for d in "${_TEST_TMPDIRS[@]}"; do
    rm -rf "$d" 2>/dev/null || true
  done
}
trap _cleanup_test_tmpdirs EXIT

# Extract the helpers by pattern rather than sourcing retro.sh, so these
# tests exercise the helper bodies independently of retro.sh's source guard
# (GitHub #420), which test_sourcing_* below covers on its own.
_source_scan_helper() {
  local fn_src
  fn_src="$(awk '/^scan_claude_log_failures\(\)/,/^}/' "$RETRO_SH")"
  eval "$fn_src"
  fn_src="$(awk '/^correlate_failures_with_phase\(\)/,/^}/' "$RETRO_SH")"
  eval "$fn_src"
}
_source_scan_helper

# ── GitHub #207: META|error|fail| structured marker must be caught ───────

test_meta_error_fail_marker_is_caught() {
  local tmpdir claude_log output
  tmpdir=$(_mktemp_test_dir)
  claude_log="$tmpdir/claude.log"
  output="$tmpdir/failures.txt"
  cat >"$claude_log" <<'EOF'
2026-08-30T07:13:40Z|META|error|fail|[12] ticket directory not found for CRE-22
EOF
  scan_claude_log_failures "$claude_log" "$output"
  grep -q "ticket directory not found for CRE-22" "$output"
}

test_meta_error_fail_marker_with_unmatched_wording() {
  local tmpdir claude_log output
  tmpdir=$(_mktemp_test_dir)
  claude_log="$tmpdir/claude.log"
  output="$tmpdir/failures.txt"
  cat >"$claude_log" <<'EOF'
2026-08-30T07:13:41Z|META|error|fail|[12] env-check: required configuration missing
EOF
  scan_claude_log_failures "$claude_log" "$output"
  grep -q "env-check: required configuration missing" "$output"
}

test_non_matching_lines_still_excluded() {
  local tmpdir claude_log output
  tmpdir=$(_mktemp_test_dir)
  claude_log="$tmpdir/claude.log"
  output="$tmpdir/failures.txt"
  cat >"$claude_log" <<'EOF'
2026-08-30T07:13:42Z|META|title|info|CRE-22: unrelated ticket title
EOF
  scan_claude_log_failures "$claude_log" "$output"
  [ ! -s "$output" ]
}

# ── GitHub #420: grep -c || echo 0 must not yield "0\n0" ────────────────
# correlate_failures_with_phase counts each phase with grep -c; on a phase
# with zero failures grep -c prints "0" AND exits 1, so `|| echo 0` appended
# a second "0" and the following `[ "$count" -gt 0 ]` printed
# "integer expression expected" once per empty phase.

test_correlate_zero_count_phase_no_integer_error() {
  local tmpdir claude_log failures output errfile
  tmpdir=$(_mktemp_test_dir)
  claude_log="$tmpdir/claude.log"
  failures="$tmpdir/failures.txt"
  output="$tmpdir/correlated.txt"
  errfile="$tmpdir/stderr.txt"
  cat >"$claude_log" <<'EOF'
some unrelated line
fatal: could not read from remote
EOF
  echo "2:fatal: could not read from remote" >"$failures"
  correlate_failures_with_phase "$claude_log" "$failures" "$output" 2>"$errfile"
  ! grep -q "integer expression expected" "$errfile" &&
    grep -q "^### Unknown phase — 1 failure(s)" "$output" &&
    [ "$(grep -c '^### ' "$output")" = "1" ]
}

# Sourcing retro.sh (ticket-retro SKILL.md Step 1.5) must define the helpers
# only — not run the whole aggregation inline in the caller's shell, and not
# leak errexit into it.
test_sourcing_defines_helpers_without_running_retro() {
  local tmpdir out
  tmpdir=$(_mktemp_test_dir)
  out=$(HOME="$tmpdir" REPOS_ROOT="$tmpdir" bash -c '
    set +e
    source "$1" --window 7d
    declare -F scan_claude_log_failures >/dev/null &&
      declare -F correlate_failures_with_phase >/dev/null &&
      [[ $- != *e* ]] &&
      echo SOURCED_OK
  ' _ "$RETRO_SH" 2>/dev/null) || true
  [ "$out" = "SOURCED_OK" ]
}

# Direct execution must still run the aggregation (the guard only short-
# circuits when sourced).
test_direct_execution_still_runs() {
  local tmpdir rc=0
  tmpdir=$(_mktemp_test_dir)
  HOME="$tmpdir" REPOS_ROOT="$tmpdir" bash "$RETRO_SH" --window 7d >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
  # No logs in an empty HOME: retro.sh reports that and exits non-zero —
  # proof the main body ran rather than returning at the guard.
  [ "$rc" -ne 0 ] && [ -s "$tmpdir/err" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────

FILTER="${1:-}"
for fn in \
  test_meta_error_fail_marker_is_caught \
  test_meta_error_fail_marker_with_unmatched_wording \
  test_non_matching_lines_still_excluded \
  test_correlate_zero_count_phase_no_integer_error \
  test_sourcing_defines_helpers_without_running_retro \
  test_direct_execution_still_runs; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
