#!/usr/bin/env bash
# test-appraise-handoff-check.sh — lib/appraise-handoff-check.sh
# (ticket-appraise Step 5 pre-handoff gate, skill-deterministic-extraction 6a).
#
# Parity oracle: the pre-extraction Step 5 fence (main @ 267c17f), embedded
# below with {ticket-dir} filled, run on the same notes.md; the pipeline log
# (timestamps masked) must match and the script exits 1 exactly when the
# fence logged a failure.
#
# Usage: bash test-appraise-handoff-check.sh
set -eo pipefail

AH_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AH_LIB_DIR="$(cd "$AH_TEST_DIR/.." && pwd)"
unset LOG_FILE HB_LOG_FILE

PASS=0 FAIL=0
_ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
_ko() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}
WS=$(mktemp -d)
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/home/.claude/skills" "$WS/td"
ln -s "$AH_LIB_DIR" "$WS/home/.claude/skills/lib"
export HOME="$WS/home" TAP_LOG="$WS/p.log"

_old() {
  NOTES_FILE="$WS/td/notes.md" bash -c '
_score=$(grep -A5 "^## Complexity" "$NOTES_FILE" 2>/dev/null | grep "^\*\*Score:\*\*" | grep -oi "simple\|complex" | head -1)
if [ -z "$_score" ]; then
  bash ~/.claude/skills/lib/plog.sh APPRAISE handoff fail "notes.md missing ## Complexity with Score"
fi
_inv_lines=$(awk '"'"'/^## Initial Investigation/{found=1; next} found && /^## /{exit} found{print}'"'"' "$NOTES_FILE" | grep -vc "^\s*$")
if [ "${_inv_lines:-0}" -lt 2 ]; then
  bash ~/.claude/skills/lib/plog.sh APPRAISE handoff fail "notes.md ## Initial Investigation is empty or stub"
fi' 2>/dev/null
}
_mask() { sed 's/^[^|]*|/TS|/' "$TAP_LOG"; }

for c in ready no_score empty_inv both stub_score lowercase missing_file; do
  case "$c" in
  ready) printf '## Complexity\n**Score:** simple\n\n## Initial Investigation\n- a\n- b\n\n## Next\n' ;;
  no_score) printf '## Complexity\nTBD\n\n## Initial Investigation\n- a\n- b\n' ;;
  empty_inv) printf '## Complexity\n**Score:** complex\n\n## Initial Investigation\n\n- only one\n\n## Next\n' ;;
  both) printf '# Notes\n' ;;
  stub_score) printf '## Complexity\n**Score:** {simple|complex}\n## Initial Investigation\na\nb\n' ;;
  lowercase) printf '## Complexity\n**Score:** COMPLEX (5)\n## Initial Investigation\na\nb\n' ;;
  missing_file) : ;;
  esac >"$WS/td/notes.md"
  [ "$c" = missing_file ] && rm -f "$WS/td/notes.md"
  : >"$TAP_LOG"
  _old || true
  old=$(_mask)
  : >"$TAP_LOG"
  rc=0
  bash "$AH_LIB_DIR/appraise-handoff-check.sh" "$WS/td" || rc=$?
  new=$(_mask)
  [ "$old" = "$new" ] && _ok "$c: same log lines" || _ko "$c: log '$old' vs '$new'"
  want=0
  [ -n "$old" ] && want=1
  [ "$rc" = "$want" ] && _ok "$c: exit $want" || _ko "$c: exit $rc, want $want"
done
rc=0
bash "$AH_LIB_DIR/appraise-handoff-check.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && _ok "usage exits 2" || _ko "usage exit $rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
