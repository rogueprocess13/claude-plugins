#!/usr/bin/env bash
# test-prescan-system-index.sh — prescan-system-index.sh keeps curated
# system.md rows across rebuilds (DET-SU-15: the inline heredoc wiped them).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
SI="$LIB_DIR/prescan-system-index.sh"

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
TA="$TMP/.ticket-auto"
mkdir -p "$TA/web-app/docs" "$TA/api/docs"
echo "# INDEX" >"$TA/web-app/docs/INDEX.md"
echo "# INDEX" >"$TA/api/docs/INDEX.md"

# 1. missing system.md → created from template with both repos
out=$(bash "$SI" --repos-root "$TMP" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "SYSTEM_INDEX_REPOS=2" ] &&
  grep -q '^| api | ' "$TA/system.md" && grep -q '^| web-app | ' "$TA/system.md" &&
  grep -qxF '## FE → BE Contract Map' "$TA/system.md" && grep -qxF '## Shared Types' "$TA/system.md"; then
  ok "creates system.md from template"
else
  nok "creates system.md from template (rc=$rc out=$out)"
fi

# 2. curated rows survive a rebuild, and a new repo is indexed
cat >"$TA/system.md" <<'EOF'
# Cross-Repo System Map

Generated: 2026-01-01T00:00:00Z

## Indexed Repos

| old-repo | /gone/docs/INDEX.md |

## FE → BE Contract Map

| Frontend (Repo) | API Call | Backend Endpoint (Repo) | Handler |
|-----------------|----------|------------------------|---------|
| web-app | GET /api/users | api: /users | UserController#list |
| web-app | POST /api/orders | api: /orders | OrderController#create |

## Shared Types

| Type | Defined In (Repo) | Consumed By (Repos) |
|------|-------------------|---------------------|
| UserDTO | api | web-app |

## Notes

hand-written note
EOF
mkdir -p "$TA/worker/docs"
echo "# INDEX" >"$TA/worker/docs/INDEX.md"
out=$(bash "$SI" --repos-root "$TMP" 2>&1)
f="$TA/system.md"
if grep -qF '| web-app | GET /api/users | api: /users | UserController#list |' "$f" &&
  grep -qF '| web-app | POST /api/orders | api: /orders | OrderController#create |' "$f" &&
  grep -qF '| UserDTO | api | web-app |' "$f"; then
  ok "contract-map and shared-types rows preserved"
else
  nok "contract-map and shared-types rows preserved"
  cat "$f"
fi
if [ "$out" = "SYSTEM_INDEX_REPOS=3" ] && grep -q '^| worker | ' "$f" && ! grep -q 'old-repo' "$f" &&
  ! grep -q '2026-01-01T00:00:00Z' "$f"; then
  ok "indexed-repos table and Generated line refreshed"
else
  nok "indexed-repos table and Generated line refreshed (out=$out)"
fi
if grep -qxF 'hand-written note' "$f" && [ "$(grep -cxF '## FE → BE Contract Map' "$f")" -eq 1 ]; then
  ok "other sections kept, no duplicated headings"
else
  nok "other sections kept, no duplicated headings"
fi

# 3. idempotent: a second run leaves the rows identical
before=$(grep -v '^Generated:' "$f")
bash "$SI" --repos-root "$TMP" >/dev/null 2>&1
after=$(grep -v '^Generated:' "$f")
if [ "$before" = "$after" ]; then ok "rebuild is idempotent"; else nok "rebuild is idempotent"; fi

# 4. usage errors
if bash "$SI" >/dev/null 2>&1; then nok "no --repos-root exits 2"; else ok "no --repos-root exits 2"; fi
bash "$SI" --repos-root "$TMP/nope" >/dev/null 2>&1
if [ $? -eq 2 ]; then ok "missing .ticket-auto exits 2"; else nok "missing .ticket-auto exits 2"; fi

# 5. the skill no longer rewrites system.md with a heredoc
SKILL="$PLUGIN_DIR/skills/ticket-prescan/SKILL.md"
if grep -q 'cat > "$REPOS_ROOT/.ticket-auto/system.md"' "$SKILL" || ! grep -q 'prescan-system-index.sh' "$SKILL"; then
  nok "ticket-prescan Step 5.5 uses prescan-system-index.sh"
else
  ok "ticket-prescan Step 5.5 uses prescan-system-index.sh"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
