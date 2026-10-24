#!/usr/bin/env bash
# test-wiki-route.sh — wiki-route.sh (ticket-appraise Step 3a.0b, DET-AP-8)
# and the ticket filter on prescan-route.sh --mode repos.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
WR="$LIB_DIR/wiki-route.sh"
ROUTE="$LIB_DIR/prescan-route.sh"

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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Workspace with 5 repos (a .git dir is all prescan-route's find needs)
WS="$TMP/ws"
for r in web-app billing-api auth-service notifications reports; do
  mkdir -p "$WS/$r/.git"
done
# Wiki with a topic table
WIKI="$TMP/wiki"
mkdir -p "$WIKI/flows"
echo "# invoicing flow" >"$WIKI/flows/invoicing.md"
cat >"$WIKI/index.md" <<'EOF'
# Wiki Index

## Lookup by Topic

| Topic | File |
|-------|------|
| invoicing | flows/invoicing.md |

## Lookup by Service

| Service | File |
|---------|------|
| (no entries yet) | |
EOF

wr() { (eval "$(bash "$WR" "$@")" && printf '%s|%s|%s|%s\n' "$WIKI_ROUTE" "$WIKI_ROUTE_REASON" "$WIKI_ROUTE_REPO_COUNT" "$WIKI_ROUTE_LINE"); }

# 1. regression: 5-repo workspace, ticket naming one repo → not multi-repo
r=$(wr --wiki-root "$WIKI" --repos-root "$WS" --ticket-title "Fix date picker in web-app" --ticket-desc "The form crashes")
if [[ "$r" == "false|none|1|"* ]]; then ok "1 named repo of 5 → not routed"; else nok "1 named repo of 5 → not routed: $r"; fi

# 2. ticket naming two repos → multi-repo(2)
r=$(wr --wiki-root "$WIKI" --repos-root "$WS" --ticket-title "Sync totals" --ticket-desc "web-app shows totals from billing-api wrongly")
if [[ "$r" == "true|multi-repo(2)|2|**Wiki routing:** multi-repo (2 repos)" ]]; then ok "2 named repos → multi-repo(2)"; else nok "2 named repos → multi-repo(2): $r"; fi

# 3. Affected Services with two entries → routed
r=$(wr --wiki-root "$WIKI" --repos-root "$WS" --ticket-title "Something" --affected-services "svc-a, svc-b")
if [[ "$r" == "true|multi-service(2)|0|"* ]]; then ok "Affected Services a, b → routed"; else nok "Affected Services a, b → routed: $r"; fi
r=$(wr --wiki-root "$WIKI" --repos-root "$WS" --ticket-title "Something" --affected-services "svc-a")
if [[ "$r" == "false|none|"* ]]; then ok "single Affected Service → not routed"; else nok "single Affected Service → not routed: $r"; fi

# 4. topic match via the wiki index (case-insensitive substring)
out=$(bash "$WR" --wiki-root "$WIKI" --repos-root "$WS" --ticket-title "Invoicing totals off by one")
r=$( (eval "$out" && printf '%s|%s|%s' "$WIKI_ROUTE" "$WIKI_ROUTE_REASON" "$WIKI_ROUTE_TOPIC_FILES"))
if [ "$r" = "true|topic|$WIKI/flows/invoicing.md" ]; then ok "topic match routes with files"; else nok "topic match routes with files: $r"; fi

# 5. parity: topic files equal prescan-route --mode index on the same index
p=$(bash "$ROUTE" --mode index --index "$WIKI/index.md" --ticket-title "Invoicing totals off by one" | grep -v '^PRESCAN_ROUTE_COUNT=')
if [ "$p" = "$WIKI/flows/invoicing.md" ]; then ok "parity with prescan-route --mode index"; else nok "parity with prescan-route --mode index: $p"; fi

# 6. no index.md → not routed, reason no-index, exit 0
mkdir -p "$TMP/emptywiki"
out=$(bash "$WR" --wiki-root "$TMP/emptywiki" --repos-root "$WS" --ticket-title "x")
rc=$?
r=$( (eval "$out" && printf '%s|%s' "$WIKI_ROUTE" "$WIKI_ROUTE_REASON"))
if [ "$rc" -eq 0 ] && [ "$r" = "false|no-index" ]; then ok "no index.md → no-index, exit 0"; else nok "no index.md → no-index, exit 0 (rc=$rc $r)"; fi

# 7. WIKI_ROOT unset → false, exit 0
out=$(bash "$WR" --repos-root "$WS" --ticket-title "web-app and billing-api")
rc=$?
r=$( (eval "$out" && printf '%s|%s' "$WIKI_ROUTE" "$WIKI_ROUTE_REASON"))
if [ "$rc" -eq 0 ] && [ "$r" = "false|no-wiki" ]; then ok "WIKI_ROOT unset → no-wiki, exit 0"; else nok "WIKI_ROOT unset → no-wiki, exit 0 (rc=$rc $r)"; fi

# 8. eval-safety: shell metacharacters in ticket text are inert
out=$(bash "$WR" --wiki-root "$WIKI" --repos-root "$WS" --ticket-title 'x $(touch '"$TMP"'/pwned) `id`')
(eval "$out") >/dev/null 2>&1
if [ ! -e "$TMP/pwned" ]; then ok "ticket text is not executed"; else nok "ticket text is not executed"; fi

# 9. prescan-route repos filter: whole-word, case-insensitive; no text → all
out=$(bash "$ROUTE" --mode repos --repos-root "$WS" --ticket-desc "REPORTS page is rapid" 2>/dev/null)
if printf '%s\n' "$out" | grep -qx 'PRESCAN_ROUTE_COUNT=1' && printf '%s\n' "$out" | grep -q '/reports$'; then
  ok "repos filter keeps named repo only"
else
  nok "repos filter keeps named repo only: $out"
fi
out=$(bash "$ROUTE" --mode repos --repos-root "$WS" 2>/dev/null)
if printf '%s\n' "$out" | grep -qx 'PRESCAN_ROUTE_COUNT=5' && printf '%s\n' "$out" | grep -qxF "$WS/web-app" &&
  ! printf '%s\n' "$out" | grep -qxF "$WS"; then ok "repos without ticket text lists all"; else nok "repos without ticket text lists all: $out"; fi
mkdir -p "$TMP/ws2/api/.git"
out=$(bash "$ROUTE" --mode repos --repos-root "$TMP/ws2" --ticket-desc "rapid change" 2>/dev/null || true)
if printf '%s\n' "$out" | grep -qx 'PRESCAN_ROUTE_COUNT=0'; then ok "repo name matches whole words only"; else nok "repo name matches whole words only: $out"; fi

# 10. the skill no longer counts ${#REPOS[@]}
SKILL="$PLUGIN_DIR/skills/ticket-appraise/SKILL.md"
if grep -qF '${#REPOS[@]}' "$SKILL" || ! grep -q 'wiki-route.sh' "$SKILL"; then
  nok "ticket-appraise 3a.0b uses wiki-route.sh"
else
  ok "ticket-appraise 3a.0b uses wiki-route.sh"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
