#!/usr/bin/env bash
# test-critique-no-post.sh — ticket-critique --no-post (dispatch-rehearsal-preflight):
# the read-only branch must name --result-file, must not reach any writer
# (flow-run.sh, write_verifier_result, notes.md, a Linear comment), and its
# bash block must render a CRITIQUE_RESULT block that e2e-preflight.sh parses.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
SKILL="$PLUGIN_DIR/skills/ticket-critique/SKILL.md"

PASS=0
FAIL=0
ok() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
nok() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

# The --no-post section: from its heading to the next ### heading.
SECTION=$(awk '/^### If `--no-post`/{f=1;print;next} f&&/^### /{exit} f' "$SKILL")

[ -n "$SECTION" ] && ok "--no-post section exists" || nok "--no-post section missing"
grep -q -- '--result-file' <<<"$SECTION" && ok "names --result-file" || nok "does not name --result-file"

# Writers must not be invoked from the section (prose may name them as skipped).
for w in '^bash .*flow-run\.sh' '^write_verifier_result' '>> *.*notes\.md' 'save_comment'; do
  if grep -Eq "$w" <<<"$SECTION"; then nok "section invokes writer /$w/"; else ok "no writer /$w/"; fi
done

# The section writes through critique-status.sh (never an inline writer).
grep -q 'critique-status.sh --score .*--result-file\|critique-status.sh --score' <<<"$SECTION" &&
  grep -q -- '--ticket {TICKET-ID} --result-file {RESULT_FILE}' <<<"$SECTION" &&
  ok "result written via critique-status.sh --result-file" || nok "section does not call critique-status.sh --result-file"
grep -q -- '--unavailable --ticket' <<<"$SECTION" && ok "fetch failure via --unavailable" || nok "no --unavailable call"

# critique-status.sh's writer: block shape, atomic write, findings, unavailable.
CS="$LIB_DIR/critique-status.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out/WIL-1.txt"
if bash "$CS" --score 85 --blockers 0 --warnings 1 --ticket WIL-1 --result-file "$OUT" \
  --finding "[WARNING] no edge case" >"$TMP/eval" 2>"$TMP/err"; then
  ok "writer runs"
else
  nok "writer failed: $(cat "$TMP/err")"
fi
grep -qx 'CRITIQUE_STATUS=CLEAR' "$TMP/eval" && ok "eval output unchanged" || nok "eval output changed"
if [ -f "$OUT" ] && [ ! -e "$OUT.tmp" ]; then ok "result written atomically"; else nok "result file missing or tmp left"; fi
[ "$(head -1 "$OUT" 2>/dev/null)" = "=== CRITIQUE_RESULT ===" ] && ok "opening marker" || nok "opening marker"
[ "$(tail -1 "$OUT" 2>/dev/null)" = "=== END CRITIQUE_RESULT ===" ] && ok "closing marker" || nok "closing marker"
for kv in 'TICKET: WIL-1' 'STATUS: CLEAR' 'SCORE: 85' 'BLOCKERS: 0' 'WARNINGS: 1' 'BLOCK_REASON: none' \
  'FINDING_1: [WARNING] no edge case'; do
  grep -qxF "$kv" "$OUT" 2>/dev/null && ok "field '$kv'" || nok "field '$kv' missing"
done

# Re-run overwrites (spec: only the second run's block).
bash "$CS" --score 10 --blockers 1 --warnings 0 --ticket WIL-1 --result-file "$OUT" >/dev/null
[ "$(grep -c '=== CRITIQUE_RESULT ===' "$OUT")" = 1 ] && grep -qx 'STATUS: BLOCKED' "$OUT" &&
  ok "re-run overwrites" || nok "re-run did not overwrite"

bash "$CS" --unavailable --ticket WIL-2 --result-file "$TMP/WIL-2.txt" >/dev/null
grep -qx 'STATUS: UNAVAILABLE' "$TMP/WIL-2.txt" && grep -qx 'SCORE: -' "$TMP/WIL-2.txt" &&
  ok "unavailable block" || nok "unavailable block wrong"

bash "$CS" --score 50 --blockers 0 --warnings 0 --result-file "$TMP/x.txt" >/dev/null 2>&1
[ $? -eq 2 ] && ok "--result-file without --ticket → exit 2" || nok "--result-file without --ticket accepted"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
