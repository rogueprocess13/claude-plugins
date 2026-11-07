#!/usr/bin/env bash
# test-reconcile-comments.sh — unit tests for lib/reconcile-comments.sh
# reconcile-comments.sh is a standalone script: args <ticket_id> <log_file>, stdin = comments JSON.
# It sources linear-api.sh internally for normalize_comments.
# Usage: bash test-reconcile-comments.sh [test_name_filter]
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

test_finds_appraisal_comment_boundary() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file"

  local comments='[{"id":"c1","body":"**Ticket appraised** — complexity: simple","createdAt":"2024-01-01T10:00:00Z","user":{"name":"bot"}}]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "APPRAISAL_COMMENT_AT: 2024-01-01T10:00:00Z"
}

test_falls_back_to_log_when_no_appraisal_comment() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  echo "2024-01-01T09:00:00Z|APPRAISE|appraise|done|complexity: simple" >"$log_file"

  local comments='[{"id":"c1","body":"regular user comment","createdAt":"2024-01-01T08:00:00Z","user":{"name":"alice"}}]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "APPRAISAL_COMMENT_AT: 2024-01-01T09:00:00Z"
}

test_amendment_boundary_wins_when_later() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file"

  local comments='[
    {"id":"c1","body":"**Ticket appraised** — info","createdAt":"2024-01-01T10:00:00Z","user":{"name":"bot"}},
    {"id":"c2","body":"**Amendment cycle #1** — changes applied","createdAt":"2024-01-01T11:00:00Z","user":{"name":"bot"}}
  ]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "LAST_RECONCILE_AT: 2024-01-01T11:00:00Z"
}

test_excludes_pipeline_authored_comments() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file"

  # Appraisal at 10:00, amendment at 11:00 — no user comments after boundary
  local comments='[
    {"id":"c1","body":"**Ticket appraised** — info","createdAt":"2024-01-01T10:00:00Z","user":{"name":"bot"}},
    {"id":"c2","body":"**Amendment cycle #1** — details","createdAt":"2024-01-01T11:00:00Z","user":{"name":"bot"}}
  ]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "(none)"
}

test_returns_none_when_no_unprocessed() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file"

  # Appraisal at 10:00, user comment at 09:00 (before boundary)
  local comments='[
    {"id":"c1","body":"**Ticket appraised** — complexity: simple","createdAt":"2024-01-01T10:00:00Z","user":{"name":"bot"}},
    {"id":"c2","body":"user comment before appraisal","createdAt":"2024-01-01T09:00:00Z","user":{"name":"alice"}}
  ]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "UNPROCESSED_COMMENTS:" && echo "$output" | grep -q "(none)"
}

# GitHub #568/#582: an agent-paraphrased heading ("**Ticket appraised.**")
# must still be recognised as the pipeline's own appraisal comment.
test_paraphrased_appraisal_heading_is_boundary() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  echo "2024-01-01T08:00:00Z|APPRAISE|appraise|done|complexity: simple" >"$log_file"

  local comments='[
    {"id":"c1","body":"**Ticket appraised.** The local workspace was created.","createdAt":"2024-01-01T10:00:00Z","user":{"name":"bot"}},
    {"id":"c2","body":"operator note","createdAt":"2024-01-01T09:00:00Z","user":{"name":"alice"}}
  ]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "LAST_RECONCILE_AT: 2024-01-01T10:00:00Z" &&
    echo "$output" | grep -q "(none)"
}

# The hidden marker is authoritative regardless of the heading's wording,
# for both appraisal and amendment comments.
test_marker_identifies_pipeline_comments() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file"

  local comments='[
    {"id":"c1","body":"Appraisal done.\n\n<!-- ticket-auto:appraisal -->","createdAt":"2024-01-01T10:00:00Z","user":{"name":"bot"}},
    {"id":"c2","body":"user answer","createdAt":"2024-01-01T10:30:00Z","user":{"name":"alice"}},
    {"id":"c3","body":"## Amendment 1\nChanges applied\n<!-- ticket-auto:amendment -->","createdAt":"2024-01-01T11:00:00Z","user":{"name":"bot"}},
    {"id":"c4","body":"follow-up question","createdAt":"2024-01-01T12:00:00Z","user":{"name":"alice"}}
  ]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "APPRAISAL_COMMENT_AT: 2024-01-01T10:00:00Z" &&
    echo "$output" | grep -q "LAST_RECONCILE_AT: 2024-01-01T11:00:00Z" &&
    echo "$output" | grep -q "^2024-01-01T12:00:00Z|alice|follow-up question$" &&
    ! echo "$output" | grep -q "user answer\|ticket-auto:"
}

# A user comment that merely mentions the phrase mid-body is not pipeline output.
test_user_comment_mentioning_phrase_is_unprocessed() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file"

  local comments='[
    {"id":"c1","body":"**Ticket appraised** — info","createdAt":"2024-01-01T10:00:00Z","user":{"name":"bot"}},
    {"id":"c2","body":"Re the **Ticket appraised** note: scope is wrong","createdAt":"2024-01-01T11:00:00Z","user":{"name":"alice"}}
  ]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "LAST_RECONCILE_AT: 2024-01-01T10:00:00Z" &&
    echo "$output" | grep -q "|alice|Re the"
}

# The posting skills must carry the markers the script matches on.
test_skill_templates_carry_markers() {
  grep -qF '<!-- ticket-auto:appraisal -->' "$LIB_DIR/../skills/ticket-appraise-exec/SKILL.md" &&
    grep -qF '<!-- ticket-auto:amendment -->' "$LIB_DIR/../skills/ticket-gate-reconcile/SKILL.md"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_finds_appraisal_comment_boundary \
  test_falls_back_to_log_when_no_appraisal_comment \
  test_amendment_boundary_wins_when_later \
  test_excludes_pipeline_authored_comments \
  test_returns_none_when_no_unprocessed \
  test_paraphrased_appraisal_heading_is_boundary \
  test_marker_identifies_pipeline_comments \
  test_user_comment_mentioning_phrase_is_unprocessed \
  test_skill_templates_carry_markers; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
