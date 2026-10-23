#!/usr/bin/env bash
# test-retro-complexity-calibration.sh — tests for skills/ticket-retro/retro.sh's
# complexity_calibration object (complexity-classifier-calibration), which
# replaced the scalar complexity_accuracy.
#
# Covers: the 2x3 declared x outcome matrix; false_simple_rate computed from
# the declared=simple row only (a complex classification changes the
# treatment, so that row is confounded and marked as such); false_simple_tickets
# naming the under-classified tickets; unscoreable counts for incomplete pairs;
# the small-sample floor (null, never 0); and — carried over from #367
# (RETRO_CURSOR_METRIC_SKEW) — the population is every ticket-auto log in the
# window regardless of cursor state, while failure-histogram dedup via the
# cursor is unaffected.
#
# Usage: bash test-retro-complexity-calibration.sh [test_name_filter]
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

# See test-retro-outcome-parse.sh — retro.sh calls _iso_now without sourcing
# heartbeat.sh itself; stub it so these tests exercise the scope fix in
# isolation from that unrelated latent bug.
_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
export -f _iso_now

# Hermeticity: retro.sh also discovers ticket-planner state.log files under
# PLANNER_INITIATIVES_DIR, which defaults to ${REPOS_ROOT:-$HOME/repos}/
# .ticket-auto/initiatives. On a host with a recent planner run that default
# holds a real state.log, which inflates logs_scanned/logs_skipped (5 instead
# of 4) and fails the exact-count assertions below. CI has no such directory,
# so the leak only shows locally. Point it at a path that never exists — same
# isolation test-retro-gate-held.sh applies — so every case in this file sees
# only its own seeded fixtures. Window selection is by file mtime (fixtures are
# written fresh), so the fixed timestamps inside the log lines never age out.
PLANNER_INITIATIVES_DIR="$(mktemp -u -d)/no-such-planner-dir"
export PLANNER_INITIATIVES_DIR

# _seed <tmpdir> <TID> <declared|-> <outcome|-> [extra-log-line]
# One ticket-auto log plus (unless declared is "-") a notes.md carrying its
# declared complexity. Outcome "-" writes no outcome-label marker. retro.sh
# resolves the ticket dir via its `find . -name "${ticket_id}*"` fallback.
_seed() {
  local tmpdir="$1" tid="$2" declared="$3" outcome="$4" extra="${5:-}"
  mkdir -p "$tmpdir/logs"
  {
    echo "2026-09-01T20:00:00Z|META|schema|info|1"
    [ -n "$extra" ] && echo "$extra"
    [ "$outcome" != "-" ] && echo "2026-09-01T20:01:01Z|META|outcome-label|info|$outcome"
    true
  } >"$tmpdir/logs/${tid}-pipeline.log"
  if [ "$declared" != "-" ]; then
    mkdir -p "$tmpdir/${tid}--fix"
    printf '## Complexity\n**Score:** %s\n' "$declared" >"$tmpdir/${tid}--fix/notes.md"
  fi
}

# _retro_json <tmpdir> [VAR=value...] — one --force run, stdout JSON
_retro_json() {
  local tmpdir="$1"
  shift
  (cd "$tmpdir" && env CURSOR_FILE="$tmpdir/cursor.json" "$@" bash "$RETRO_SH" --window 30 --force 2>/dev/null)
}

# The 4-ticket population from #367: one ticket in each of simple/Smooth,
# complex/Smooth, simple/Rough, complex/Hard. CRE-1 also carries an
# EXEC_NO_ARTIFACT gate-stop so failure dedup can be asserted independently.
_seed_population() {
  local tmpdir="$1"
  _seed "$tmpdir" CRE-1 simple Smooth "2026-09-01T20:01:00Z|META|gate-stop|fail|EXEC_NO_ARTIFACT missing simple-fix.md"
  _seed "$tmpdir" CRE-2 complex Smooth
  _seed "$tmpdir" CRE-3 simple Rough
  _seed "$tmpdir" CRE-4 complex Hard
}

# Runs retro.sh twice from inside tmpdir: once with --force to populate the
# cursor, once without (no file touched in between) — the exact repro shape
# from #367 (a second run inside the same window, cursor fully warm).
# Echoes the SECOND run's stdout JSON.
_retro_second_run_json() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  _seed_population "$tmpdir"

  (
    cd "$tmpdir"
    CURSOR_FILE="$tmpdir/cursor.json" bash "$RETRO_SH" --window 30 --force >/dev/null 2>&1
  )
  (
    cd "$tmpdir"
    CURSOR_FILE="$tmpdir/cursor.json" bash "$RETRO_SH" --window 30 2>/dev/null
  )
}

# ── Population scope (#367, carried over) ──────────────────────────────────

test_calibration_computed_over_full_population_despite_cursor_skip() {
  local out
  out=$(_retro_second_run_json)
  # Nothing changed between runs — every log is cursor-skipped for the
  # failure scan, yet the calibration population is still all 4 tickets.
  [ "$(echo "$out" | jq -r '.logs_scanned')" = "0" ] &&
    [ "$(echo "$out" | jq -r '.logs_skipped')" = "4" ] &&
    [ "$(echo "$out" | jq -c '.complexity_calibration.matrix')" = '{"simple":{"Smooth":1,"Rough":1,"Hard":0},"complex":{"Smooth":1,"Rough":0,"Hard":1}}' ]
}

test_failure_dedup_unaffected_by_metrics_scope() {
  local out
  out=$(_retro_second_run_json)
  # The gate-stop on CRE-1 was already reported on the first (--force) run;
  # the second run must not re-count it into the histogram.
  [ "$(echo "$out" | jq -r '.failure_histogram.EXEC_NO_ARTIFACT // 0')" = "0" ] &&
    [ "$(echo "$out" | jq -r '.gate_stop_total')" = "0" ]
}

test_accuracy_fields_removed() {
  local out
  out=$(_retro_second_run_json)
  [ "$(echo "$out" | jq -c '[keys[] | select(test("complexity_(accuracy|over|under)"))]')" = "[]" ] &&
    [ "$(echo "$out" | jq -r '.complexity_predictions | length')" = "4" ] &&
    [ "$(echo "$out" | jq -c '.complexity_predictions[0] | keys')" = '["actual","actual_source","declared","ticket"]' ]
}

# ── Matrix and rate ─────────────────────────────────────────────────────────

test_all_six_cells_populate() {
  local tmpdir out
  tmpdir=$(_mktemp_test_dir)
  _seed "$tmpdir" CRE-1 simple Smooth
  _seed "$tmpdir" CRE-2 simple Rough
  _seed "$tmpdir" CRE-3 simple Hard
  _seed "$tmpdir" CRE-4 complex Smooth
  _seed "$tmpdir" CRE-5 complex Rough
  _seed "$tmpdir" CRE-6 complex Hard
  out=$(_retro_json "$tmpdir")
  [ "$(echo "$out" | jq -c '.complexity_calibration.matrix')" = '{"simple":{"Smooth":1,"Rough":1,"Hard":1},"complex":{"Smooth":1,"Rough":1,"Hard":1}}' ]
}

# Spec worked example: 8 simple (6/1/1) + 4 complex (3/1/0) → 0.250, and
# the complex row (including 3 complex x Smooth) cannot move it.
test_worked_example_rate_uses_simple_row_only() {
  local tmpdir out i
  tmpdir=$(_mktemp_test_dir)
  for i in 1 2 3 4 5 6; do _seed "$tmpdir" "CRE-$i" simple Smooth; done
  _seed "$tmpdir" CRE-7 simple Rough
  _seed "$tmpdir" CRE-8 simple Hard
  for i in 9 10 11; do _seed "$tmpdir" "CRE-$i" complex Smooth; done
  _seed "$tmpdir" CRE-12 complex Rough
  out=$(_retro_json "$tmpdir")
  [ "$(echo "$out" | jq -r '.complexity_calibration.false_simple_rate')" = "0.250" ] &&
    [ "$(echo "$out" | jq -r '.complexity_calibration.simple_row_n')" = "8" ] &&
    [ "$(echo "$out" | jq -r '.complexity_calibration.suppressed')" = "false" ] &&
    [ "$(echo "$out" | jq -r '.complexity_calibration.matrix.complex.Smooth')" = "3" ]
}

test_complex_smooth_does_not_move_rate() {
  local tmpdir out i
  tmpdir=$(_mktemp_test_dir)
  for i in 1 2 3; do _seed "$tmpdir" "CRE-$i" simple Smooth; done
  out=$(_retro_json "$tmpdir")
  local before
  before=$(echo "$out" | jq -r '.complexity_calibration.false_simple_rate')
  _seed "$tmpdir" CRE-4 complex Smooth
  _seed "$tmpdir" CRE-5 complex Smooth
  out=$(_retro_json "$tmpdir")
  [ "$before" = "0.000" ] &&
    [ "$(echo "$out" | jq -r '.complexity_calibration.false_simple_rate')" = "0.000" ] &&
    [ "$(echo "$out" | jq -r '.complexity_calibration.matrix.complex.Smooth')" = "2" ]
}

# A window with logs but no complete pair. (A window with no logs at all
# exits before any JSON is emitted — "No pipeline logs found in window".)
test_no_scoreable_pair_rate_is_null() {
  local tmpdir out
  tmpdir=$(_mktemp_test_dir)
  _seed "$tmpdir" CRE-1 simple -
  _seed "$tmpdir" CRE-2 - Smooth
  out=$(_retro_json "$tmpdir" COMPLEXITY_CALIBRATION_MIN_N=0)
  [ "$(echo "$out" | jq -r '.complexity_calibration.false_simple_rate')" = "null" ] &&
    [ "$(echo "$out" | jq -c '[.complexity_calibration.matrix[][]] | add')" = "0" ] &&
    [ "$(echo "$out" | jq -r '.complexity_calibration.suppressed')" = "true" ]
}

test_confounded_marker_present() {
  local out
  out=$(_retro_second_run_json)
  [ "$(echo "$out" | jq -c '.complexity_calibration.confounded_rows')" = '["declared=complex"]' ] &&
    echo "$out" | jq -r '.complexity_calibration.confounded_reason' | grep -q "changes the treatment"
}

# ── False-simple list and unscoreable counts ───────────────────────────────

test_false_simple_tickets_named() {
  local tmpdir out
  tmpdir=$(_mktemp_test_dir)
  _seed "$tmpdir" CRE-101 simple Hard
  _seed "$tmpdir" CRE-102 simple Smooth
  _seed "$tmpdir" CRE-103 simple Rough
  _seed "$tmpdir" CRE-104 complex Hard
  out=$(_retro_json "$tmpdir")
  [ "$(echo "$out" | jq -c '.complexity_calibration.false_simple_tickets | sort_by(.ticket)')" = '[{"ticket":"CRE-101","outcome":"Hard"},{"ticket":"CRE-103","outcome":"Rough"}]' ]
}

test_unscoreable_counts_independent() {
  local tmpdir out
  tmpdir=$(_mktemp_test_dir)
  _seed "$tmpdir" CRE-1 simple Smooth
  _seed "$tmpdir" CRE-2 simple -
  _seed "$tmpdir" CRE-3 complex -
  _seed "$tmpdir" CRE-4 - Rough
  out=$(_retro_json "$tmpdir")
  [ "$(echo "$out" | jq -c '.complexity_calibration.unscoreable')" = '{"missing_declared":1,"missing_outcome":2}' ] &&
    [ "$(echo "$out" | jq -c '[.complexity_calibration.matrix[][]] | add')" = "1" ]
}

# ── Ticket-dir lookup ──────────────────────────────────────────────────────

# CRE-1 must not read CRE-12--fix/notes.md (prefix collision), must find a
# nested ticket dir, and must not stop at a .ticket-auto worktree checkout.
test_ticket_dir_lookup_is_anchored_and_nested() {
  local tmpdir out
  tmpdir=$(_mktemp_test_dir)
  _seed "$tmpdir" CRE-12 complex Hard
  _seed "$tmpdir" CRE-1 - Hard
  mkdir -p "$tmpdir/.ticket-auto/worktrees/CRE-1--decoy" "$tmpdir/area/sub/CRE-1--nested"
  printf '## Complexity\n**Score:** complex\n' >"$tmpdir/.ticket-auto/worktrees/CRE-1--decoy/notes.md"
  printf '## Complexity\n**Score:** simple\n' >"$tmpdir/area/sub/CRE-1--nested/notes.md"
  out=$(_retro_json "$tmpdir")
  [ "$(echo "$out" | jq -r '.complexity_predictions[] | select(.ticket=="CRE-1") | .declared')" = "simple" ] &&
    [ "$(echo "$out" | jq -r '.complexity_predictions[] | select(.ticket=="CRE-12") | .declared')" = "complex" ]
}

# ── Small-n suppression ─────────────────────────────────────────────────────

test_small_n_suppresses_rate() {
  local tmpdir out
  tmpdir=$(_mktemp_test_dir)
  _seed "$tmpdir" CRE-9 simple Smooth
  _seed "$tmpdir" CRE-10 simple Hard
  out=$(_retro_json "$tmpdir")
  # 2 simple tickets is below the default floor of 3 — rate suppressed, but
  # the matrix and the named false-simple are still emitted in full.
  [ "$(echo "$out" | jq -r '.complexity_calibration.simple_row_n')" = "2" ] &&
    [ "$(echo "$out" | jq -r '.complexity_calibration.false_simple_rate')" = "null" ] &&
    [ "$(echo "$out" | jq -r '.complexity_calibration.suppressed')" = "true" ] &&
    [ "$(echo "$out" | jq -r '.complexity_calibration.false_simple_tickets[0].ticket')" = "CRE-10" ]
}

test_min_n_floor_is_overridable() {
  local tmpdir out
  tmpdir=$(_mktemp_test_dir)
  _seed "$tmpdir" CRE-10 simple Smooth
  out=$(_retro_json "$tmpdir" COMPLEXITY_CALIBRATION_MIN_N=1)
  [ "$(echo "$out" | jq -r '.complexity_calibration.min_n')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.complexity_calibration.false_simple_rate')" = "0.000" ] &&
    [ "$(echo "$out" | jq -r '.complexity_calibration.suppressed')" = "false" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────

FILTER="${1:-}"
for fn in \
  test_calibration_computed_over_full_population_despite_cursor_skip \
  test_failure_dedup_unaffected_by_metrics_scope \
  test_accuracy_fields_removed \
  test_all_six_cells_populate \
  test_worked_example_rate_uses_simple_row_only \
  test_complex_smooth_does_not_move_rate \
  test_no_scoreable_pair_rate_is_null \
  test_confounded_marker_present \
  test_false_simple_tickets_named \
  test_unscoreable_counts_independent \
  test_ticket_dir_lookup_is_anchored_and_nested \
  test_small_n_suppresses_rate \
  test_min_n_floor_is_overridable; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
