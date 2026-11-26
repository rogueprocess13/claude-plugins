#!/usr/bin/env bash
# test-outcome-label-check.sh — unit tests for lib/outcome-label-check.sh
# (tracker-flow-projection-cutover task 8.5: the outcome is local-only now,
# no tracker read/write — these tests need no get_issue/flow.sh mock at all).
# Usage: bash test-outcome-label-check.sh [test_name_filter]
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

# ── Scaffold ───────────────────────────────────────────────────────────────────

_ws=""         # workspace dir
_tid=""        # ticket ID
_repos_root="" # scratch REPOS_ROOT for manifest fixtures

_setup() {
  _ws=$(mktemp -d)
  _tid="CRE-47"
  _repos_root=$(mktemp -d)

  LOG_FILE="${_ws}/${_tid}-pipeline.log"
  TICKET_ID="$_tid"
  REPOS_ROOT="$_repos_root"

  write_ticket_manifest "$_tid" "INIT-1" "bug" '[]' >/dev/null
}

_teardown() {
  rm -rf "$_ws" "$_repos_root" 2>/dev/null || true
  unset REPOS_ROOT
}

_plog_raw() {
  local phase="$1" step="$2" status="$3" msg="$4"
  local iso="${5:-2026-06-05T10:00:00Z}"
  echo "${iso}|${phase}|${step}|${status}|${msg}" >>"$LOG_FILE"
}

# ── Source manifest-write.sh first (outcome-label-check.sh needs it already
# sourced or sources it itself via CLAUDE_SKILLS_LIB/SCRIPT_DIR fallback —
# sourcing it here first means write_ticket_manifest is available to
# _setup above too) ──────────────────────────────────────────────────────
source "$LIB_DIR/manifest-write.sh"
source "$LIB_DIR/outcome-label-check.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════════

# 1-3. Each outcome value already recorded in the manifest → exit 0.
test_outcome_smooth_present_exits_0() {
  _setup
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Smooth"
  write_ticket_outcome_label "$_tid" "Smooth" >/dev/null

  _outcome_label_check
  local rc=$?
  _teardown
  [ "$rc" -eq 0 ]
}

test_outcome_rough_present_exits_0() {
  _setup
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Rough"
  write_ticket_outcome_label "$_tid" "Rough" >/dev/null

  _outcome_label_check
  local rc=$?
  _teardown
  [ "$rc" -eq 0 ]
}

test_outcome_hard_present_exits_0() {
  _setup
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Hard"
  write_ticket_outcome_label "$_tid" "Hard" >/dev/null

  _outcome_label_check
  local rc=$?
  _teardown
  [ "$rc" -eq 0 ]
}

# 4. Outcome missing from manifest → written via write_ticket_outcome_label.
test_outcome_label_missing_writes_to_manifest() {
  _setup
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Rough"

  _outcome_label_check
  local rc=$?
  local mirrored
  mirrored=$(get_ticket_manifest_field "$_tid" outcome_label 2>/dev/null)
  _teardown
  [ "$rc" -eq 0 ] && [ "$mirrored" = "Rough" ]
}

# 5. Outcome read from pipeline log.
test_outcome_read_from_pipeline_log() {
  _setup
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Smooth"

  _outcome_label_check
  local rc=$?
  local mirrored
  mirrored=$(get_ticket_manifest_field "$_tid" outcome_label 2>/dev/null)
  _teardown
  [ "$rc" -eq 0 ] && [ "$mirrored" = "Smooth" ]
}

# 6. Already-recorded outcome still writes META|outcome-label so auto-merge
# eligibility (which reads the pipeline log, not the manifest directly)
# has a source regardless of which branch confirmed the value.
test_outcome_label_present_writes_meta_line() {
  _setup
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Smooth"
  write_ticket_outcome_label "$_tid" "Smooth" >/dev/null

  _outcome_label_check
  local rc=$?
  local meta_line
  meta_line=$(grep '|META|outcome-label|info|Smooth' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] && [ -n "$meta_line" ]
}

# 7. Missing outcome, once applied → META|outcome-label written with the
# applied value.
test_outcome_label_missing_writes_meta_line_after_apply() {
  _setup
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Rough"

  _outcome_label_check
  local rc=$?
  local meta_line
  meta_line=$(grep '|META|outcome-label|info|Rough' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] && [ -n "$meta_line" ]
}

# 8. No IMPLEMENT|implement-outcome line at all → return 1.
test_outcome_no_log_line_fails() {
  _setup
  _outcome_label_check
  local rc=$?
  _teardown
  [ "$rc" -eq 1 ]
}

# 9. Unrecognized outcome value → return 1, nothing written to the manifest.
test_outcome_unknown_value_fails() {
  _setup
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Medium"

  _outcome_label_check
  local rc=$?
  local mirrored
  mirrored=$(get_ticket_manifest_field "$_tid" outcome_label 2>/dev/null)
  _teardown
  [ "$rc" -eq 1 ] && [ -z "$mirrored" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# manifest mirror tests (tracker-local-facts-read-migration task 5.11/1.7,
# now the sole write of record per tracker-flow-projection-cutover task 8.5)
# ═══════════════════════════════════════════════════════════════════════════════

test_outcome_mirrored_to_manifest_when_already_present() {
  _setup
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Smooth"
  write_ticket_outcome_label "$_tid" "Smooth" >/dev/null

  _outcome_label_check >/dev/null 2>&1
  local mirrored
  mirrored=$(get_ticket_manifest_field "$_tid" outcome_label 2>/dev/null)
  _teardown
  [ "$mirrored" = "Smooth" ]
}

test_outcome_mirrored_to_manifest_after_applying_label() {
  _setup
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Rough"

  _outcome_label_check >/dev/null 2>&1
  local mirrored
  mirrored=$(get_ticket_manifest_field "$_tid" outcome_label 2>/dev/null)
  _teardown
  [ "$mirrored" = "Rough" ]
}

test_outcome_mirror_is_best_effort_without_manifest() {
  # No manifest anywhere — the outcome check itself must still succeed
  # (the mirror is best-effort, never a failure of the check).
  _ws=$(mktemp -d)
  _tid="CRE-99"
  _repos_root=$(mktemp -d) # no write_ticket_manifest call — no manifest exists
  LOG_FILE="${_ws}/${_tid}-pipeline.log"
  TICKET_ID="$_tid"
  REPOS_ROOT="$_repos_root"

  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Hard"

  local rc=0
  _outcome_label_check >/dev/null 2>&1 || rc=$?
  _teardown

  [ "$rc" -eq 0 ]
}

# Issue #393 — `outcome=Hard` value format in the log line is accepted.
test_outcome_prefixed_value_accepted() {
  _setup
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "outcome=Hard"

  _outcome_label_check
  local rc=$?
  local meta_line
  meta_line=$(grep '|META|outcome-label|info|Hard$' "$LOG_FILE" 2>/dev/null || true)
  _teardown
  [ "$rc" -eq 0 ] && [ -n "$meta_line" ]
}

# ── Track 0.1: the prose fallback may only withhold a merge ─────────────────
# With no dedicated IMPLEMENT|implement-outcome line, the agent's own prose on
# IMPLEMENT|implement|done| is a self-grade. It may record Rough/Hard (which
# withholds auto-merge) but never Smooth (which would unlock it).

# Must-fail: "not Hard, Smooth" used to recover Smooth (tail -1) → auto-merge.
test_prose_fallback_never_records_smooth() {
  _setup
  _plog_raw "IMPLEMENT" "implement" "done" "outcome not Hard, Smooth"
  local rc=0
  _outcome_label_check || rc=$?
  local smooth
  smooth=$(grep '|META|outcome-label|info|' "$LOG_FILE" 2>/dev/null | grep -c 'Smooth' || true)
  _teardown
  [ "$rc" -eq 0 ] && [ "$smooth" = "0" ]
}

# Must-fail: prose that names only Smooth records nothing (unrecorded → no merge).
test_prose_fallback_smooth_only_is_unrecorded() {
  _setup
  _plog_raw "IMPLEMENT" "implement" "done" "Smooth run, 2 files changed"
  local rc=0
  _outcome_label_check || rc=$?
  local line
  line=$(grep '|META|outcome-label|info|' "$LOG_FILE" 2>/dev/null || true)
  _teardown
  [ "$rc" -ne 0 ] && [ -z "$line" ]
}

# Must-pass: prose naming Rough still withholds (recorded as Rough).
test_prose_fallback_records_rough() {
  _setup
  _plog_raw "IMPLEMENT" "implement" "done" "Rough — two fix cycles"
  local rc=0
  _outcome_label_check || rc=$?
  local line
  line=$(grep '|META|outcome-label|info|Rough$' "$LOG_FILE" 2>/dev/null || true)
  _teardown
  [ "$rc" -eq 0 ] && [ -n "$line" ]
}

# Must-pass: the worst token wins, never the last one.
test_prose_fallback_worst_token_wins() {
  _setup
  _plog_raw "IMPLEMENT" "implement" "done" "Hard parts were Rough, ended Smooth"
  local rc=0
  _outcome_label_check || rc=$?
  local line
  line=$(grep '|META|outcome-label|info|' "$LOG_FILE" 2>/dev/null | tail -1 || true)
  _teardown
  [ "$rc" -eq 0 ] && [[ "$line" == *"|Hard" ]]
}

# Must-pass: the dedicated (script-written) line still records Smooth.
test_dedicated_smooth_beats_prose() {
  _setup
  _plog_raw "IMPLEMENT" "implement" "done" "not Hard"
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Smooth"
  local rc=0
  _outcome_label_check || rc=$?
  local line
  line=$(grep '|META|outcome-label|info|Smooth$' "$LOG_FILE" 2>/dev/null || true)
  _teardown
  [ "$rc" -eq 0 ] && [ -n "$line" ]
}

# ── #827: a failed PR review plus a pr-iterate round floors the outcome ────────

_last_outcome_label() {
  grep '|META|outcome-label|info|' "$LOG_FILE" | tail -1 | cut -d'|' -f5
}

# The #827 shape: review WARN + pr-iterate in a run held at the reapprove
# gate, re-implement in the next run, both rounds self-graded Smooth.
test_review_warn_iterate_across_held_run_is_rough() {
  _setup
  _plog_raw "META" "run-id" "info" '{"run_id":"r1"}'
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Smooth"
  _outcome_label_check >/dev/null 2>&1
  _plog_raw "PR-REVIEW" "pr-review" "done" "WARN — WARN 18/20: gap"
  _plog_raw "PR-REVIEW" "pr-iterate" "start" "Iterate on PR feedback"
  _plog_raw "PR-REVIEW" "pr-iterate" "done" "plan amended"
  _plog_raw "GATE" "reapprove" "fail" "held: needs a person"
  _plog_raw "META" "outcome" "info" "held: gate"
  _plog_raw "META" "run-id" "info" '{"run_id":"r2"}'
  _plog_raw "GATE" "reapprove" "done" "released: human"
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Smooth"
  _outcome_label_check >/dev/null 2>&1
  local label mirrored
  label=$(_last_outcome_label)
  mirrored=$(get_ticket_manifest_field "$_tid" outcome_label 2>/dev/null)
  _teardown
  [ "$label" = "Rough" ] && [ "$mirrored" = "Rough" ]
}

test_two_iterate_rounds_are_hard() {
  _setup
  _plog_raw "PR-REVIEW" "pr-review" "done" "WARN — 1"
  _plog_raw "PR-REVIEW" "pr-iterate" "done" "round 1"
  _plog_raw "PR-REVIEW" "pr-review" "done" "WARN — 2"
  _plog_raw "PR-REVIEW" "pr-iterate" "done" "round 2"
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Rough"
  _outcome_label_check >/dev/null 2>&1
  local label
  label=$(_last_outcome_label)
  _teardown
  [ "$label" = "Hard" ]
}

test_reapprove_alone_is_rough() {
  _setup
  _plog_raw "GATE" "reapprove" "done" "released: human"
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Smooth"
  _outcome_label_check >/dev/null 2>&1
  local label
  label=$(_last_outcome_label)
  _teardown
  [ "$label" = "Rough" ]
}

test_floor_never_lowers_hard() {
  _setup
  _plog_raw "PR-REVIEW" "pr-review" "done" "WARN — 1"
  _plog_raw "PR-REVIEW" "pr-iterate" "done" "round 1"
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Hard"
  _outcome_label_check >/dev/null 2>&1
  local label
  label=$(_last_outcome_label)
  _teardown
  [ "$label" = "Hard" ]
}

test_passing_review_without_iterate_stays_smooth() {
  _setup
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Smooth"
  _plog_raw "PR-REVIEW" "pr-review" "done" "OK — 20/20"
  _outcome_label_check >/dev/null 2>&1
  local label
  label=$(_last_outcome_label)
  _teardown
  [ "$label" = "Smooth" ]
}

# A fix round from an earlier, completed attempt does not count.
test_iterate_before_completed_run_ignored() {
  _setup
  _plog_raw "META" "run-id" "info" '{"run_id":"r1"}'
  _plog_raw "PR-REVIEW" "pr-review" "done" "WARN — old"
  _plog_raw "PR-REVIEW" "pr-iterate" "done" "old round"
  _plog_raw "GATE" "reapprove" "done" "released: human"
  _plog_raw "META" "outcome" "info" "completed: STEP_6"
  _plog_raw "META" "run-id" "info" '{"run_id":"r2"}'
  _plog_raw "IMPLEMENT" "implement-outcome" "info" "Smooth"
  _outcome_label_check >/dev/null 2>&1
  local label
  label=$(_last_outcome_label)
  _teardown
  [ "$label" = "Smooth" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dispatcher
# ═══════════════════════════════════════════════════════════════════════════════

FILTER="${1:-}"

for fn in \
  test_outcome_smooth_present_exits_0 \
  test_outcome_rough_present_exits_0 \
  test_outcome_hard_present_exits_0 \
  test_outcome_label_missing_writes_to_manifest \
  test_outcome_read_from_pipeline_log \
  test_outcome_label_present_writes_meta_line \
  test_outcome_label_missing_writes_meta_line_after_apply \
  test_outcome_no_log_line_fails \
  test_outcome_unknown_value_fails \
  test_outcome_mirrored_to_manifest_when_already_present \
  test_outcome_mirrored_to_manifest_after_applying_label \
  test_outcome_mirror_is_best_effort_without_manifest \
  test_outcome_prefixed_value_accepted \
  test_prose_fallback_never_records_smooth \
  test_prose_fallback_smooth_only_is_unrecorded \
  test_prose_fallback_records_rough \
  test_prose_fallback_worst_token_wins \
  test_dedicated_smooth_beats_prose \
  test_review_warn_iterate_across_held_run_is_rough \
  test_two_iterate_rounds_are_hard \
  test_reapprove_alone_is_rough \
  test_floor_never_lowers_hard \
  test_passing_review_without_iterate_stays_smooth \
  test_iterate_before_completed_run_ignored; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
