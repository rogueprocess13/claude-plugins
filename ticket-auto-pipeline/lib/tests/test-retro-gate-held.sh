#!/usr/bin/env bash
# test-retro-gate-held.sh — regression tests for skills/ticket-retro/retro.sh's
# handling of gate-check.sh's entry-gate hold lines (GitHub #319).
#
# #319: retro.sh's failure-aggregation loop only inspected lines where
# phase == "META", so gate-check.sh's own hold line — GATE|gate|fail|held:...,
# a distinct, earlier-stage event from the META|gate-stop| hard-stop codes —
# was silently skipped. A recurring nav_gap/user_gap/repro_gap cross-
# validation false-hold (or any other entry-gate hold) could never accumulate
# in the Failure Histogram and cross the count>=2 diff-proposal threshold.
#
# This exercises: a GATE-phase hold now appears in the histogram; a
# META|gate-stop|fail| — only log (the pre-existing, working path) is
# unaffected; distinct hold-message shapes bucket distinctly rather than
# collapsing on a naive first-word split; and a recurring hold across two
# tickets' logs crosses the count>=2 threshold.
#
# Usage: bash test-retro-gate-held.sh [test_name_filter]
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
# heartbeat.sh itself; stub it so this test exercises gate-held parsing in
# isolation from that unrelated latent bug.
_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
export -f _iso_now

# Runs retro.sh directly against a single constructed pipeline-log fixture and
# echoes its stdout JSON. $1 = ticket id (used as the log's stem), remaining
# args = log lines. Also points PLANNER_INITIATIVES_DIR at a directory that
# never exists, so a host with real planner state under $HOME/repos or
# $REPOS_ROOT never leaks into these single-log assertions.
_retro_with_log() {
  local ticket_id="$1"
  shift
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/${ticket_id}-pipeline.log"
  local line
  for line in "$@"; do
    echo "$line" >>"$log_file"
  done
  CURSOR_FILE="$tmpdir/cursor.json" \
    PLANNER_INITIATIVES_DIR="$tmpdir/no-such-planner-dir" \
    bash "$RETRO_SH" --window 30 --force "$log_file" 2>/dev/null
}

# Runs retro.sh in no-positional-log discovery mode against a `./logs/`
# directory containing multiple `*-pipeline.log` fixtures, so their failure
# counts accumulate into one histogram the way a real multi-ticket retro
# window would. $1 = tmpdir root (caller creates `$1/logs/*-pipeline.log`
# ahead of the call).
_retro_with_logs_dir() {
  local tmpdir="$1"
  (
    cd "$tmpdir" &&
      CURSOR_FILE="$tmpdir/cursor.json" \
        PLANNER_INITIATIVES_DIR="$tmpdir/no-such-planner-dir" \
        bash "$RETRO_SH" --window 30 --force 2>/dev/null
  )
}

# ── #319 AC: GATE|gate|fail|held:... now appears in the Failure Histogram ──

test_gate_held_line_appears_in_histogram() {
  local out
  out=$(_retro_with_log "CRE-24" \
    "2026-09-07T18:00:00Z|META|schema|info|1" \
    "2026-09-07T18:20:58Z|GATE|gate|fail|held: critique-plan cross-validation failed — 1 critique gap(s) still unaddressed (nav_gap=true user_gap=false repro_gap=false)")
  [ "$(echo "$out" | jq -r '.failure_histogram.GATE_HELD_CRITIQUE_CROSS_VALIDATION')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.logs_with_failures')" = "1" ]
}

# ── #319 regression: META|gate-stop|fail| — only log is unaffected ─────────

test_meta_gate_stop_only_log_unaffected() {
  local out
  out=$(_retro_with_log "CRE-25" \
    "2026-09-07T18:00:00Z|META|schema|info|1" \
    "2026-09-07T18:05:00Z|META|gate-stop|fail|EXEC_NO_ARTIFACT")
  [ "$(echo "$out" | jq -r '.failure_histogram.EXEC_NO_ARTIFACT')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.gate_stop_total')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.logs_with_failures')" = "1" ] &&
    [ "$(echo "$out" | jq -r 'any(.failure_histogram | keys[]; startswith("GATE_HELD_"))')" = "false" ]
}

# ── distinct hold-message shapes bucket distinctly, not by naive first word ─
# (both "plan missing ... prerequisites" variants share the word "plan" but
# are the same underlying hold reason and should collapse into one bucket;
# "complex ticket" and "manual mode" must NOT collapse into that bucket or
# into each other just because gate-check.sh's prose varies)

test_distinct_hold_shapes_bucket_distinctly() {
  local out
  out=$(_retro_with_log "CRE-26" \
    "2026-09-07T18:00:00Z|META|schema|info|1" \
    "2026-09-07T18:05:00Z|GATE|gate|fail|held: plan missing 2/4 verification prerequisites (mode=build build_command=false build_outcome=true)" \
    "2026-09-07T18:06:00Z|GATE|gate|fail|held: plan missing 3/4 verification prerequisites (mode=ui test_user=false nav=true expected=true env=true)" \
    "2026-09-07T18:07:00Z|GATE|gate|fail|held: complex ticket" \
    "2026-09-07T18:08:00Z|GATE|gate|fail|held: manual mode")
  [ "$(echo "$out" | jq -r '.failure_histogram.GATE_HELD_MISSING_VERIFICATION_PREREQS')" = "2" ] &&
    [ "$(echo "$out" | jq -r '.failure_histogram.GATE_HELD_COMPLEX_TICKET')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.failure_histogram.GATE_HELD_MANUAL_MODE')" = "1" ]
}

# ── an unrecognized future hold message still buckets, visibly generic ─────

test_unrecognized_hold_message_falls_back() {
  local out
  out=$(_retro_with_log "CRE-27" \
    "2026-09-07T18:00:00Z|META|schema|info|1" \
    "2026-09-07T18:05:00Z|GATE|gate|fail|held: brand-new-reason not yet classified")
  [ "$(echo "$out" | jq -r '.failure_histogram.GATE_HELD_BRAND_NEW_REASON')" = "1" ]
}

# ── #319 AC: a recurring GATE hold across 2+ tickets crosses count>=2 ───────

test_recurring_gate_hold_crosses_threshold() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  mkdir -p "$tmpdir/logs"
  cat >"$tmpdir/logs/CRE-30-pipeline.log" <<'EOF'
2026-09-07T18:00:00Z|META|schema|info|1
2026-09-07T18:20:58Z|GATE|gate|fail|held: critique-plan cross-validation failed — 1 critique gap(s) still unaddressed (nav_gap=true user_gap=false repro_gap=false)
EOF
  cat >"$tmpdir/logs/CRE-31-pipeline.log" <<'EOF'
2026-09-07T19:00:00Z|META|schema|info|1
2026-09-07T19:15:12Z|GATE|gate|fail|held: critique-plan cross-validation failed — 1 critique gap(s) still unaddressed (nav_gap=true user_gap=false repro_gap=false)
EOF
  local out
  out=$(_retro_with_logs_dir "$tmpdir")
  [ "$(echo "$out" | jq -r '.failure_histogram.GATE_HELD_CRITIQUE_CROSS_VALIDATION')" = "2" ] &&
    [ "$(echo "$out" | jq -r '.logs_with_failures')" = "2" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────

FILTER="${1:-}"
for fn in \
  test_gate_held_line_appears_in_histogram \
  test_meta_gate_stop_only_log_unaffected \
  test_distinct_hold_shapes_bucket_distinctly \
  test_unrecognized_hold_message_falls_back \
  test_recurring_gate_hold_crosses_threshold; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
