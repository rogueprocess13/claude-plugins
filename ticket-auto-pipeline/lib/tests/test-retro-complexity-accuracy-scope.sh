#!/usr/bin/env bash
# test-retro-complexity-accuracy-scope.sh — regression tests for skills/ticket-retro/retro.sh's
# complexity_accuracy population scope (GitHub #367: RETRO_CURSOR_METRIC_SKEW).
#
# #367: retro.sh's cursor dedup (which exists to stop re-reporting failures
# already surfaced in a prior retro run) also gated the complexity-prediction
# accuracy pairing. A second retro run within the same window would only see
# the handful of logs whose mtime had changed, and report an accuracy figure
# (e.g. 1.000 from a single lucky prediction) computed over that arbitrary
# cursor-left residue instead of the full window population (a real 0.500).
#
# This exercises: complexity_accuracy is computed over every ticket-auto log
# in the window regardless of cursor state; the sample size n is reported
# alongside it; a below-floor n suppresses the figure (null) rather than
# showing a misleadingly confident ratio; the floor is overridable; over-
# vs. under-estimation is broken out; and failure-histogram dedup via the
# cursor is unaffected (still skips re-scanning unchanged logs).
#
# Usage: bash test-retro-complexity-accuracy-scope.sh [test_name_filter]
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

# Builds a workdir with 4 ticket-auto pipeline logs whose declared/actual
# complexity is known: 2 correct, 1 overestimate, 1 underestimate (a
# population accuracy of 0.500 — the "real 0.50" from the issue). One log
# also carries an EXEC_NO_ARTIFACT gate-stop so failure-dedup can be
# asserted independently of the complexity-metrics scope.
_seed_population() {
  local tmpdir="$1"
  mkdir -p "$tmpdir/logs"

  cat >"$tmpdir/logs/CRE-1-pipeline.log" <<'EOF'
2026-09-01T20:00:00Z|META|schema|info|1
2026-09-01T20:01:00Z|META|gate-stop|fail|EXEC_NO_ARTIFACT missing simple-fix.md
2026-09-01T20:01:01Z|META|outcome-label|info|Smooth
EOF
  mkdir -p "$tmpdir/CRE-1--fix-a"
  cat >"$tmpdir/CRE-1--fix-a/notes.md" <<'EOF'
## Complexity
**Score:** simple
EOF

  cat >"$tmpdir/logs/CRE-2-pipeline.log" <<'EOF'
2026-09-01T20:00:00Z|META|schema|info|1
2026-09-01T20:01:01Z|META|outcome-label|info|Smooth
EOF
  mkdir -p "$tmpdir/CRE-2--fix-b"
  cat >"$tmpdir/CRE-2--fix-b/notes.md" <<'EOF'
## Complexity
**Score:** complex
EOF

  cat >"$tmpdir/logs/CRE-3-pipeline.log" <<'EOF'
2026-09-01T20:00:00Z|META|schema|info|1
2026-09-01T20:01:01Z|META|outcome-label|info|Rough
EOF
  mkdir -p "$tmpdir/CRE-3--fix-c"
  cat >"$tmpdir/CRE-3--fix-c/notes.md" <<'EOF'
## Complexity
**Score:** simple
EOF

  cat >"$tmpdir/logs/CRE-4-pipeline.log" <<'EOF'
2026-09-01T20:00:00Z|META|schema|info|1
2026-09-01T20:01:01Z|META|outcome-label|info|Hard
EOF
  mkdir -p "$tmpdir/CRE-4--fix-d"
  cat >"$tmpdir/CRE-4--fix-d/notes.md" <<'EOF'
## Complexity
**Score:** complex
EOF

  # retro.sh resolves ticket_dir via the |META|artifact|info|notes: marker
  # first, falling back to `find . -name "${ticket_id}*"` — the fallback is
  # sufficient here and matches test-retro-planner-source.sh's fixture style.
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

# ── Core repro: accuracy computed over full population, not cursor residue ──

test_accuracy_computed_over_full_population_despite_cursor_skip() {
  local out
  out=$(_retro_second_run_json)
  # Nothing changed between runs — every log is cursor-skipped for the
  # failure scan, yet the complexity population is still all 4 tickets.
  [ "$(echo "$out" | jq -r '.logs_scanned')" = "0" ] &&
    [ "$(echo "$out" | jq -r '.logs_skipped')" = "4" ] &&
    [ "$(echo "$out" | jq -r '.complexity_accuracy_n')" = "4" ] &&
    [ "$(echo "$out" | jq -r '.complexity_accuracy')" = "0.500" ] &&
    [ "$(echo "$out" | jq -r '.complexity_accuracy_suppressed')" = "false" ]
}

test_over_under_directionality_reported() {
  local out
  out=$(_retro_second_run_json)
  [ "$(echo "$out" | jq -r '.complexity_over_count')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.complexity_under_count')" = "1" ]
}

test_failure_dedup_unaffected_by_metrics_scope_fix() {
  local out
  out=$(_retro_second_run_json)
  # The gate-stop on CRE-1 was already reported on the first (--force) run;
  # the second run must not re-count it into the histogram.
  [ "$(echo "$out" | jq -r '.failure_histogram.EXEC_NO_ARTIFACT // 0')" = "0" ] &&
    [ "$(echo "$out" | jq -r '.gate_stop_total')" = "0" ]
}

# ── Small-n suppression ─────────────────────────────────────────────────────

test_small_n_suppresses_accuracy() {
  local tmpdir out
  tmpdir=$(_mktemp_test_dir)
  mkdir -p "$tmpdir/logs"
  cat >"$tmpdir/logs/CRE-9-pipeline.log" <<'EOF'
2026-09-01T20:00:00Z|META|schema|info|1
2026-09-01T20:01:01Z|META|outcome-label|info|Smooth
EOF
  mkdir -p "$tmpdir/CRE-9--fix"
  cat >"$tmpdir/CRE-9--fix/notes.md" <<'EOF'
## Complexity
**Score:** simple
EOF
  out=$(cd "$tmpdir" && CURSOR_FILE="$tmpdir/cursor.json" bash "$RETRO_SH" --window 30 --force 2>/dev/null)
  # 1/1 = 1.000 would be misleadingly confident — default floor suppresses it.
  [ "$(echo "$out" | jq -r '.complexity_accuracy_n')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.complexity_accuracy')" = "null" ] &&
    [ "$(echo "$out" | jq -r '.complexity_accuracy_suppressed')" = "true" ]
}

test_min_n_floor_is_overridable() {
  local tmpdir out
  tmpdir=$(_mktemp_test_dir)
  mkdir -p "$tmpdir/logs"
  cat >"$tmpdir/logs/CRE-10-pipeline.log" <<'EOF'
2026-09-01T20:00:00Z|META|schema|info|1
2026-09-01T20:01:01Z|META|outcome-label|info|Smooth
EOF
  mkdir -p "$tmpdir/CRE-10--fix"
  cat >"$tmpdir/CRE-10--fix/notes.md" <<'EOF'
## Complexity
**Score:** simple
EOF
  out=$(cd "$tmpdir" && CURSOR_FILE="$tmpdir/cursor.json" COMPLEXITY_ACCURACY_MIN_N=1 \
    bash "$RETRO_SH" --window 30 --force 2>/dev/null)
  [ "$(echo "$out" | jq -r '.complexity_accuracy_n')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.complexity_accuracy')" = "1.000" ] &&
    [ "$(echo "$out" | jq -r '.complexity_accuracy_suppressed')" = "false" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────

FILTER="${1:-}"
for fn in \
  test_accuracy_computed_over_full_population_despite_cursor_skip \
  test_over_under_directionality_reported \
  test_failure_dedup_unaffected_by_metrics_scope_fix \
  test_small_n_suppresses_accuracy \
  test_min_n_floor_is_overridable; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
