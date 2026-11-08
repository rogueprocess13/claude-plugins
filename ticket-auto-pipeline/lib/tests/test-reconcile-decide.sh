#!/usr/bin/env bash
# test-reconcile-decide.sh — lib/reconcile-decide.sh (GitHub #599): an
# answer-only reconcile cycle must not hold the ticket for another approval.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$LIB_DIR/../skills/ticket-gate-reconcile/SKILL.md"
DECIDE="$LIB_DIR/reconcile-decide.sh"

PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

_check() {
  local name="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name — want [$want] got [$got]"
    FAIL=$((FAIL + 1))
  fi
}

_decide() { bash "$DECIDE" "$@" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# notes.md after Step 6 struck every answered question (the #599 cycle 2).
cat >"$TMP/answered.md" <<'EOF'
## Open Questions
- ~~[needs-human] Keep the wider cancel rule? — RESOLVED: keep it~~
- [agent-resolvable] Which table? — `x.sql:3`

## Session Log
- [needs-human] not in the Open Questions section
EOF

cat >"$TMP/open.md" <<'EOF'
## Open Questions
- ~~[needs-human] Old one~~
- [needs-human] New question raised by the amendment
EOF

_check "answer-only comment, all questions struck -> clean-recorded" \
  "OPEN_QUESTIONS=0 RECONCILE_DECISION=clean-recorded HOLD_REASON=" \
  "$(_decide --notes "$TMP/answered.md" --comments 1 --new-input 0)"

_check "new-input comment -> hold unprocessed_comments" \
  "OPEN_QUESTIONS=0 RECONCILE_DECISION=hold HOLD_REASON=unprocessed_comments" \
  "$(_decide --notes "$TMP/answered.md" --comments 2 --new-input 1)"

_check "new question after amendment -> hold unanswered_questions" \
  "OPEN_QUESTIONS=1 RECONCILE_DECISION=hold HOLD_REASON=unanswered_questions" \
  "$(_decide --notes "$TMP/open.md" --comments 1 --new-input 0)"

_check "both -> combined reason" \
  "OPEN_QUESTIONS=1 RECONCILE_DECISION=hold HOLD_REASON=unanswered_questions+unprocessed_comments" \
  "$(_decide --notes "$TMP/open.md" --comments 1 --new-input 1)"

_check "no comments, nothing open -> clean" \
  "OPEN_QUESTIONS=0 RECONCILE_DECISION=clean HOLD_REASON=" \
  "$(_decide --notes "$TMP/answered.md" --comments 0)"

_check "--new-input omitted -> every comment counts as new input (safe default)" \
  "OPEN_QUESTIONS=0 RECONCILE_DECISION=hold HOLD_REASON=unprocessed_comments" \
  "$(_decide --notes "$TMP/answered.md" --comments 1)"

bash "$DECIDE" --notes "$TMP/answered.md" >/dev/null 2>&1
_check "missing --comments is a usage error" "2" "$?"

# The skill must route Step 7 through the script, not the old
# "any unprocessed comment holds" rule.
if grep -q 'reconcile-decide.sh' "$SKILL" && grep -q 'clean-recorded' "$SKILL" &&
  ! grep -q 'If `{UNPROCESSED_COMMENTS}` is non-empty → set `HOLD_REASON=unprocessed_comments`' "$SKILL"; then
  _check "SKILL.md decides the hold with reconcile-decide.sh" ok ok
else
  _check "SKILL.md decides the hold with reconcile-decide.sh" ok missing
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
