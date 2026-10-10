#!/usr/bin/env bash
# test-notes-parse.sh — unit tests for lib/notes-parse.sh
# get_complexity takes a ticket directory, reads $dir/notes.md.
# Correct fixture format: "## Complexity\n\n**Score:** simple"
# Usage: bash test-notes-parse.sh [test_name_filter]
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

# ── tests ──────────────────────────────────────────────────────────────────────

test_extracts_simple() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Complexity\n\n**Score:** simple\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "simple" ]
}

test_extracts_complex() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Complexity\n\n**Score:** complex\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "complex" ]
}

test_missing_notes_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  # No notes.md created
  local exit_code=0
  bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  # Migration to error-handler.sh: E_ENV=12 for file-not-found
  [ "$exit_code" -eq 12 ]
}

test_missing_score_section() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Complexity\n\nNo score line here.\n' >"$tmpdir/notes.md"
  local exit_code=0
  bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 2 ]
}

test_windows_line_endings() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Complexity\r\n\r\n**Score:** simple\r\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "simple" ]
}

test_critique_single_section_score() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Readiness Critique\n\n**Status:** CLEAR\n**Score:** 90\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_critique_score '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "90" ]
}

test_critique_single_section_status() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Readiness Critique\n\n**Status:** CLEAR\n**Score:** 90\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_critique_status '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "CLEAR" ]
}

# Reproduces #292: a re-run appends a second "## Readiness Critique (re-run
# <date>)" heading rather than replacing the first. Both headings contain
# "## Readiness Critique", so a naive sed range anchored on the first match
# would return the stale BLOCKED/20 values instead of the superseding
# re-run's CLEAR/80.
test_critique_rerun_score_takes_latest() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Readiness Critique\n\n**Status:** BLOCKED\n**Score:** 20\n\n## Readiness Critique (re-run 2026-09-03)\n\n**Status:** CLEAR\n**Score:** 80\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_critique_score '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "80" ]
}

test_critique_rerun_status_takes_latest() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Readiness Critique\n\n**Status:** BLOCKED\n**Score:** 20\n\n## Readiness Critique (re-run 2026-09-03)\n\n**Status:** CLEAR\n**Score:** 80\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_critique_status '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "CLEAR" ]
}

test_critique_rerun_stops_at_next_heading() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Readiness Critique\n\n**Status:** BLOCKED\n**Score:** 20\n\n## Readiness Critique (re-run 2026-09-03)\n\n**Status:** CLEAR\n**Score:** 80\n\n## Some Later Section\n\n**Status:** IGNORED\n**Score:** 5\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_critique_score '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "80" ]
}

# get_ac_count fallback (no "## Acceptance Criteria" heading) tests.
# Regression for #345: the old '^#*\s*(...)' boundary regex matched a
# keyword preceded by ANY leading whitespace, not just the single space
# after a markdown '#'. An indented prose continuation line satisfied it
# purely by vocabulary and truncated the scan before the real AC section.

# Indented prose line containing a boundary keyword ("context") must NOT
# be treated as a section boundary — the scan must continue past it to
# count the later plain-text "Acceptance criteria:" label's items.
test_ac_count_indented_prose_not_boundary() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf 'Some intro line.\n\n  context, so behavior parity with the existing call sites is an explicit requirement for this change.\n\nAcceptance criteria:\n1. First criterion\n2. Second criterion\n3. Third criterion\n' >"$tmpdir/context.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_ac_count '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "3" ]
}

# A plain-text "Acceptance criteria:" label (no "##" heading) with no
# interfering indented prose still counts the true number of items.
test_ac_count_plain_text_label_no_heading() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf 'Some background text.\n\nAcceptance criteria:\n1. One\n2. Two\n' >"$tmpdir/context.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_ac_count '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "2" ]
}

# Existing "## Acceptance Criteria" heading path (primary, non-fallback)
# still parses correctly — no regression from the fallback regex change.
test_ac_count_heading_section_still_works() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Acceptance Criteria\n\n1. First\n2. Second\n- [ ] Third\n' >"$tmpdir/context.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_ac_count '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "3" ]
}

# A real markdown heading boundary (e.g. "## Background") still stops the
# fallback scan as intended — only indentation-based false positives were
# the bug, not headings themselves.
test_ac_count_heading_boundary_still_stops_fallback() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '1. Leading numbered line not actually an AC\n\n## Background\n\n1. Should not be counted\n2. Should not be counted\n' >"$tmpdir/context.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_ac_count '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "1" ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

# Reproduces #403: warning/blocker counts and has_finding must read the latest
# critique section, not the superseded first one.
_rerun_notes() {
  printf '## Readiness Critique\n\n**Status:** BLOCKED\n**Score:** 60\n- [BLOCKER] a\n- [BLOCKER] b\n- [WARNING] w1\n- [WARNING] w2\n- [WARNING] w3\n- stale-only-finding\n\n## Readiness Critique (re-run 2026-09-24)\n\n**Status:** CLEAR\n**Score:** 100\n- [WARNING] w4\n\n## Later\n\n- [BLOCKER] ignored\n' >"$1/notes.md"
}

test_critique_rerun_blocker_count_takes_latest() {
  local tmpdir result
  tmpdir=$(mktemp -d)
  _rerun_notes "$tmpdir"
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_critique_blocker_count '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "0" ]
}

test_critique_rerun_warning_count_takes_latest() {
  local tmpdir result
  tmpdir=$(mktemp -d)
  _rerun_notes "$tmpdir"
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_critique_warning_count '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "1" ]
}

test_critique_rerun_has_finding_takes_latest() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _rerun_notes "$tmpdir"
  if bash -c "source $LIB_DIR/notes-parse.sh; get_critique_has_finding '$tmpdir' 'stale-only-finding'" >/dev/null 2>&1; then
    rm -rf "$tmpdir"
    return 1
  fi
  rm -rf "$tmpdir"
}

# ── get_blast_radius_override (issue #413) ────────────────────────────────────
# Step 2.8's complexity override used to fire on any target with 3+ d=1
# callers, even when the planned edit was purely additive (a new case arm
# before an unchanged default) and could not change any caller's behaviour.

# _blast <notes-body> — writes notes.md, evals the override result into the
# caller's scope (BLAST_OVERRIDE / BLAST_REASON / BLAST_ADDITIVE_SKIP), and
# returns the function's own exit code.
_blast() {
  local tmpdir out rc=0
  tmpdir=$(mktemp -d)
  printf '%b' "$1" >"$tmpdir/notes.md"
  out=$(bash -c "source $LIB_DIR/notes-parse.sh; get_blast_radius_override '$tmpdir'" 2>/dev/null) || rc=$?
  rm -rf "$tmpdir"
  BLAST_OVERRIDE="" BLAST_REASON="" BLAST_ADDITIVE_SKIP=""
  eval "$out"
  return "$rc"
}

_BR_HDR='## Blast Radius\n\n| Target | Risk | d=1 (WILL BREAK) | d=2 (LIKELY AFFECTED) | Affected Flows | Edit |\n|--------|------|-------------------|------------------------|----------------|------|\n'

test_blast_additive_skips_caller_count() {
  _blast "${_BR_HDR}| \`can()\` | LOW | 23 callers | 4 indirect | none | additive |\n" || return 1
  [ "$BLAST_OVERRIDE" = "none" ] && [ -z "$BLAST_REASON" ] &&
    [ "$BLAST_ADDITIVE_SKIP" = "can() (23 callers)" ]
}

test_blast_modifying_caller_count_overrides() {
  _blast "${_BR_HDR}| \`can()\` | LOW | 23 callers | 4 indirect | none | modifying |\n" || return 1
  [ "$BLAST_OVERRIDE" = "complex" ] && [ "$BLAST_REASON" = "23 d=1 callers (can())" ] &&
    [ -z "$BLAST_ADDITIVE_SKIP" ]
}

test_blast_legacy_table_without_edit_column_overrides() {
  _blast '## Blast Radius\n\n| Target | Risk | d=1 (WILL BREAK) | d=2 (LIKELY AFFECTED) | Affected Flows |\n|---|---|---|---|---|\n| `can()` | LOW | 3 callers | 0 indirect | none |\n' || return 1
  [ "$BLAST_OVERRIDE" = "complex" ]
}

test_blast_additive_still_overrides_on_high_risk() {
  _blast "${_BR_HDR}| \`can()\` | HIGH | 23 callers | 4 indirect | none | additive |\n" || return 1
  [ "$BLAST_OVERRIDE" = "complex" ] && [ "$BLAST_REASON" = "risk HIGH (can())" ] &&
    [ "$BLAST_ADDITIVE_SKIP" = "can() (23 callers)" ]
}

test_blast_additive_still_overrides_on_two_flows() {
  _blast "${_BR_HDR}| \`a\` | LOW | 5 callers | 0 indirect | Login, Checkout | additive |\n| \`b\` | LOW | 1 callers | 0 indirect | login | modifying |\n" || return 1
  [ "$BLAST_OVERRIDE" = "complex" ] && [ "$BLAST_REASON" = "2 execution flows" ]
}

test_blast_below_thresholds_is_none() {
  _blast "${_BR_HDR}| \`a\` | MEDIUM | 2 callers | 9 indirect | Login | modifying |\n" || return 1
  [ "$BLAST_OVERRIDE" = "none" ] && [ -z "$BLAST_REASON" ]
}

test_blast_reason_is_eval_safe() {
  _blast "${_BR_HDR}| \`it's; \$(touch /nonexistent-413)\` | CRITICAL | 0 callers | 0 indirect | none | modifying |\n" || return 1
  [ "$BLAST_OVERRIDE" = "complex" ] &&
    [ "$BLAST_REASON" = "risk CRITICAL (it's; \$(touch /nonexistent-413))" ]
}

test_blast_takes_last_section() {
  _blast "${_BR_HDR}| \`a\` | LOW | 9 callers | 0 indirect | none | modifying |\n\n${_BR_HDR}| \`a\` | LOW | 9 callers | 0 indirect | none | additive |\n\n## Later\n\n| x | HIGH | 9 | 0 | none | modifying |\n" || return 1
  [ "$BLAST_OVERRIDE" = "none" ]
}

test_blast_section_absent_exit_2() {
  local rc=0
  _blast '## Complexity\n\n**Score:** simple\n' || rc=$?
  [ "$rc" -eq 2 ]
}

FILTER="${1:-}"

for fn in \
  test_extracts_simple \
  test_extracts_complex \
  test_missing_notes_file \
  test_missing_score_section \
  test_windows_line_endings \
  test_critique_single_section_score \
  test_critique_single_section_status \
  test_critique_rerun_score_takes_latest \
  test_critique_rerun_status_takes_latest \
  test_critique_rerun_stops_at_next_heading \
  test_critique_rerun_blocker_count_takes_latest \
  test_critique_rerun_warning_count_takes_latest \
  test_critique_rerun_has_finding_takes_latest \
  test_ac_count_indented_prose_not_boundary \
  test_ac_count_plain_text_label_no_heading \
  test_ac_count_heading_section_still_works \
  test_ac_count_heading_boundary_still_stops_fallback \
  test_blast_additive_skips_caller_count \
  test_blast_modifying_caller_count_overrides \
  test_blast_legacy_table_without_edit_column_overrides \
  test_blast_additive_still_overrides_on_high_risk \
  test_blast_additive_still_overrides_on_two_flows \
  test_blast_below_thresholds_is_none \
  test_blast_reason_is_eval_safe \
  test_blast_takes_last_section \
  test_blast_section_absent_exit_2; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
