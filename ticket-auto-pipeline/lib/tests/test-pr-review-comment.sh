#!/usr/bin/env bash
# test-pr-review-comment.sh — unit tests for lib/pr-review-comment.sh, the
# findings comment ticket-pr-review writes (Step 6) and ticket-pr-iterate
# reads (Step 2c) (skill-deterministic-extraction 2).
#
# fixtures/pr-review/comment-*.md are the Step 6 heredoc template from the
# pre-extraction SKILL.md, filled in by hand — never regenerated from the
# script. render must reproduce them byte for byte; parse must recover every
# field render wrote.
# Usage: bash test-pr-review-comment.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
PRC="$LIB_DIR/pr-review-comment.sh"
FX="$SCRIPT_DIR/fixtures/pr-review"
URL="https://linear.app/acme/issue/TEST-7"

PASS=0
FAIL=0
FILTER="${1:-}"

_run() {
  local name="$1"
  shift
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return 0
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_render_gaps() {
  bash "$PRC" render --ticket TEST-7 --url "$URL" --rows "$FX/comment-gaps.rows" \
    --impact "$FX/comment-gaps.impact" --next-steps "$FX/comment-gaps.steps"
}

test_render_gaps_matches_fixture() {
  diff <(_render_gaps) "$FX/comment-gaps.md" >/dev/null
}

test_render_pass_matches_fixture() {
  diff <(bash "$PRC" render --ticket TEST-7 --url "$URL" --rows "$FX/comment-pass.rows") \
    "$FX/comment-pass.md" >/dev/null
}

test_round_trip_recovers_every_field() {
  local parsed
  parsed=$(_render_gaps | bash "$PRC" parse) || return 1
  grep -qx 'TICKET=TEST-7' <<<"$parsed" && grep -qx "URL=$URL" <<<"$parsed" &&
    grep -qx 'VERDICT=gaps' <<<"$parsed" && grep -qx 'GAPS=2' <<<"$parsed" &&
    diff <(grep '^ROW' <<<"$parsed" | cut -f2-) \
      <(awk -F'\t' '{print $1 "\t" $3 "\t" $2}' "$FX/comment-gaps.rows") >/dev/null &&
    diff <(grep '^IMPACT' <<<"$parsed" | cut -f2-) "$FX/comment-gaps.impact" >/dev/null &&
    diff <(grep '^NEXT_STEP' <<<"$parsed" | cut -f2-) "$FX/comment-gaps.steps" >/dev/null
}

test_pass_verdict_parses_with_no_gaps() {
  local parsed
  parsed=$(bash "$PRC" parse "$FX/comment-pass.md") || return 1
  grep -qx 'VERDICT=pass' <<<"$parsed" && grep -qx 'GAPS=0' <<<"$parsed"
}

# A re-reviewed PR carries several review comments; the last one wins.
test_parse_uses_last_review_comment() {
  local parsed
  parsed=$(cat "$FX/comment-gaps.md" "$FX/comment-pass.md" | bash "$PRC" parse) || return 1
  grep -qx 'VERDICT=pass' <<<"$parsed" && ! grep -q '^ROW.*Audit row' <<<"$parsed"
}

test_parse_without_review_comment_fails() {
  local rc=0
  printf 'LGTM\n' | bash "$PRC" parse >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || return 1
  rc=0
  sed '/^\*\*Verdict/d' "$FX/comment-pass.md" | bash "$PRC" parse >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ]
}

# ⚠ without the variation selector (U+FE0F) is the same status.
test_warning_sign_without_variation_selector() {
  local d rows out
  d=$(mktemp -d)
  printf '1\tx\t\xe2\x9a\xa0\n' >"$d/rows"
  out=$(bash "$PRC" render --ticket T-1 --url u --rows "$d/rows" | bash "$PRC" parse)
  rm -rf "$d"
  grep -qx $'ROW\t1\t⚠️\tx' <<<"$out" && grep -qx 'VERDICT=gaps' <<<"$out"
}

test_render_rejects_bad_status_and_no_rows() {
  local d rc=0 rc2=0
  d=$(mktemp -d)
  printf '1\tx\tOK\n' >"$d/bad"
  : >"$d/empty"
  bash "$PRC" render --ticket T-1 --url u --rows "$d/bad" >/dev/null 2>&1 || rc=$?
  bash "$PRC" render --ticket T-1 --url u --rows "$d/empty" >/dev/null 2>&1 || rc2=$?
  rm -rf "$d"
  [ "$rc" = 2 ] && [ "$rc2" = 2 ]
}

test_no_high_risk_no_warning_line() {
  local d
  d=$(mktemp -d)
  printf 'AuditWriter\tLOW\n' >"$d/impact"
  bash "$PRC" render --ticket T-1 --url u --rows "$FX/comment-pass.rows" --impact "$d/impact" >"$d/out"
  local ok=1
  grep -q '### Structural impact' "$d/out" && ! grep -q 'High structural impact' "$d/out" || ok=0
  rm -rf "$d"
  [ "$ok" = 1 ]
}

test_skills_use_the_script() {
  local review="$PLUGIN_DIR/skills/ticket-pr-review/SKILL.md"
  local iterate="$PLUGIN_DIR/skills/ticket-pr-iterate/SKILL.md"
  grep -q 'pr-review-comment.sh" render' "$review" &&
    grep -q 'pr-review-comment.sh" parse' "$iterate" &&
    ! grep -q '^## Ticket alignment review' "$review"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  _run "$t" "$t"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
