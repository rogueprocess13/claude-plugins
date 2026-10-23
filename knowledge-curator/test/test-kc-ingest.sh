#!/usr/bin/env bash
# Unit tests for kc-ingest.sh (kc-sweep first-run plan pickup; kc-import title)
#
# Usage: bash test/test-kc-ingest.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KI="$PLUGIN_DIR/lib/kc-ingest.sh"

PASS=0
FAIL=0
pass() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  ✗ $1"
  FAIL=$((FAIL + 1))
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PLANS="$TMP/plans"
K="$TMP/knowledge"
mkdir -p "$PLANS" "$K"

echo "# fresh" >"$PLANS/fresh-plan.md"
echo "# imported" >"$PLANS/imported-plan.md"
echo "# old" >"$PLANS/old-plan.md"
touch -d '3 days ago' "$PLANS/old-plan.md"
echo "not markdown" >"$PLANS/notes.txt"
printf -- '---\nid: KC-0001\nsource: plan:imported-plan\n---\n' >"$K/KC-0001--imported.md"

echo "new-plans"

# 1. first sweep (no marker): last 24h, minus imported
out=$(bash "$KI" new-plans --plans-dir "$PLANS" --knowledge-dir "$K" 2>&1)
if [ "$out" = "$PLANS/fresh-plan.md" ]; then
  pass "no marker → plans from the last 24h, imported one excluded"
else
  fail "no marker → plans from the last 24h, imported one excluded: '$out'"
fi

# 2. marker set after the files, nothing new → nothing (idempotency)
touch "$K/.kc-sweep-marker"
sleep 1
out=$(bash "$KI" new-plans --plans-dir "$PLANS" --knowledge-dir "$K" 2>&1)
if [ -z "$out" ]; then pass "marker newer than every plan → nothing"; else fail "marker newer than every plan → nothing: '$out'"; fi

# 3. a plan written after the marker is listed
echo "# later" >"$PLANS/later-plan.md"
out=$(bash "$KI" new-plans --plans-dir "$PLANS" --knowledge-dir "$K" 2>&1)
if [ "$out" = "$PLANS/later-plan.md" ]; then pass "plan newer than marker → listed"; else fail "plan newer than marker → listed: '$out'"; fi

# 4. --since-hours widens the first-sweep window
rm -f "$K/.kc-sweep-marker"
out=$(bash "$KI" new-plans --plans-dir "$PLANS" --knowledge-dir "$K" --since-hours 96 2>&1)
if printf '%s\n' "$out" | grep -qx "$PLANS/old-plan.md"; then pass "--since-hours 96 includes a 3-day-old plan"; else fail "--since-hours 96: '$out'"; fi

# 5. missing plans dir / empty knowledge dir → no error
out=$(bash "$KI" new-plans --plans-dir "$TMP/nope" --knowledge-dir "$K" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "missing plans dir → empty, exit 0"; else fail "missing plans dir (rc=$rc '$out')"; fi
mkdir -p "$TMP/k2"
out=$(bash "$KI" new-plans --plans-dir "$PLANS" --knowledge-dir "$TMP/k2" 2>&1)
if printf '%s\n' "$out" | grep -qx "$PLANS/imported-plan.md"; then pass "no items yet → nothing excluded"; else fail "no items yet: '$out'"; fi

echo "title"

t() { bash "$KI" title "$@" 2>&1; }
cat >"$TMP/p1.md" <<'EOF'
# Add CSV export

Some intro.

## Why

Because.
EOF
[ "$(t "$TMP/p1.md")" = "Add CSV export" ] && pass "H1 wins over a later H2" || fail "H1 wins over a later H2: '$(t "$TMP/p1.md")'"

cat >"$TMP/p2.md" <<'EOF'
## Why

Only H2 headings here.
EOF
[ "$(t "$TMP/p2.md")" = "Why" ] && pass "no H1 → first H2" || fail "no H1 → first H2"

cat >"$TMP/p3.md" <<'EOF'
Line one
line two
line three
line four
line five
line six
# Late title
EOF
[ "$(t "$TMP/p3.md")" = "Late title" ] && pass "H1 beyond line 5 is still found" || fail "H1 beyond line 5"

cat >"$TMP/p4.md" <<'EOF'
```
# not a title
```
# Real title
EOF
[ "$(t "$TMP/p4.md")" = "Real title" ] && pass "fenced heading ignored" || fail "fenced heading ignored: '$(t "$TMP/p4.md")'"

echo "no headings" >"$TMP/my-plan.md"
[ "$(t "$TMP/my-plan.md")" = "my-plan" ] && pass "no heading → slug" || fail "no heading → slug"
[ "$(t "$TMP/my-plan.md" change-x)" = "change-x" ] && pass "explicit fallback" || fail "explicit fallback"
[ "$(t "$TMP/absent.md" change-y)" = "change-y" ] && pass "missing file → fallback" || fail "missing file → fallback"

printf '# CRLF title  \r\n' >"$TMP/p5.md"
[ "$(t "$TMP/p5.md")" = "CRLF title" ] && pass "CRLF and trailing space stripped" || fail "CRLF: '$(t "$TMP/p5.md")'"

if bash "$KI" bogus >/dev/null 2>&1; then fail "unknown command exits non-zero"; else pass "unknown command exits non-zero"; fi

echo "skills"
SW="$PLUGIN_DIR/skills/kc-sweep/SKILL.md"
if grep -q 'find ~/.claude/plans/ -name "\*.md" -newer' "$SW" || ! grep -q 'kc-ingest.sh" new-plans' "$SW"; then
  fail "kc-sweep Step 3 uses kc-ingest.sh new-plans"
else
  pass "kc-sweep Step 3 uses kc-ingest.sh new-plans"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
