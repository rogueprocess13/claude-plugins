#!/usr/bin/env bash
# test-prescan-wire-claude-md.sh — tests for lib/prescan-wire-claude-md.sh
# Covers the pre-existing CLAUDE.md managed-block injection and the new
# --wiki-root cross-repo row injection into the prescan INDEX.md
# (wiki-cross-repo-knowledge-layer, #335 change 1).
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
WIRE="$LIB_DIR/prescan-wire-claude-md.sh"

PASS=0
FAIL=0

_pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_fail() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}

_ws=""
_setup() {
  _ws="$(mktemp -d)"
  mkdir -p "$_ws/.ticket-auto/myrepo/docs"
  cat >"$_ws/.ticket-auto/myrepo/docs/INDEX.md" <<'EOF'
# Prescan Index — myrepo

## Lookup by Topic

| Topic | File |
|-------|------|
| Billing | services/billing.md |

## Lookup by Service

| Service | File |
|---------|------|
| Billing | services/billing.md |
EOF
  printf '# CLAUDE.md\n' >"$_ws/CLAUDE.md"
}
_teardown() {
  [ -n "$_ws" ] && rm -rf "$_ws"
  _ws=""
}

# ── CLAUDE.md managed block (pre-existing behavior) ─────────────────────────────

test_claude_md_block_inserted() {
  _setup
  bash "$WIRE" --claude-md "$_ws/CLAUDE.md" --prescan-index "$_ws/.ticket-auto/myrepo/docs/INDEX.md" --repo-slug myrepo >/dev/null
  local ok=1
  grep -qF '<!-- ticket-auto:agent-knowledge START -->' "$_ws/CLAUDE.md" && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_claude_md_block_idempotent() {
  _setup
  bash "$WIRE" --claude-md "$_ws/CLAUDE.md" --prescan-index "$_ws/.ticket-auto/myrepo/docs/INDEX.md" --repo-slug myrepo >/dev/null
  bash "$WIRE" --claude-md "$_ws/CLAUDE.md" --prescan-index "$_ws/.ticket-auto/myrepo/docs/INDEX.md" --repo-slug myrepo >/dev/null
  local count
  count=$(grep -c '<!-- ticket-auto:agent-knowledge START -->' "$_ws/CLAUDE.md")
  _teardown
  [ "$count" -eq 1 ]
}

# ── Cross-repo row in INDEX.md (--wiki-root) ────────────────────────────────────

test_no_wiki_root_no_cross_repo_row() {
  _setup
  bash "$WIRE" --claude-md "$_ws/CLAUDE.md" --prescan-index "$_ws/.ticket-auto/myrepo/docs/INDEX.md" --repo-slug myrepo >/dev/null
  local ok=1
  grep -qF '| Cross-repo |' "$_ws/.ticket-auto/myrepo/docs/INDEX.md" || ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_wiki_root_adds_cross_repo_row() {
  _setup
  bash "$WIRE" --claude-md "$_ws/CLAUDE.md" --prescan-index "$_ws/.ticket-auto/myrepo/docs/INDEX.md" --repo-slug myrepo --wiki-root "$_ws/wiki" >/dev/null
  local ok=1
  grep -qF "| Cross-repo | $_ws/wiki/index.md |" "$_ws/.ticket-auto/myrepo/docs/INDEX.md" && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_wiki_root_row_under_lookup_by_topic() {
  _setup
  bash "$WIRE" --claude-md "$_ws/CLAUDE.md" --prescan-index "$_ws/.ticket-auto/myrepo/docs/INDEX.md" --repo-slug myrepo --wiki-root "$_ws/wiki" >/dev/null
  # Cross-repo row must appear before Lookup by Service (i.e. inside Topic table)
  local topic_line service_line cross_line
  topic_line=$(grep -n '^## Lookup by Topic$' "$_ws/.ticket-auto/myrepo/docs/INDEX.md" | head -1 | cut -d: -f1)
  service_line=$(grep -n '^## Lookup by Service$' "$_ws/.ticket-auto/myrepo/docs/INDEX.md" | head -1 | cut -d: -f1)
  cross_line=$(grep -n '^| Cross-repo |' "$_ws/.ticket-auto/myrepo/docs/INDEX.md" | head -1 | cut -d: -f1)
  local ok=1
  [ "$cross_line" -gt "$topic_line" ] && [ "$cross_line" -lt "$service_line" ] && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_wiki_root_row_idempotent_no_duplicate() {
  _setup
  bash "$WIRE" --claude-md "$_ws/CLAUDE.md" --prescan-index "$_ws/.ticket-auto/myrepo/docs/INDEX.md" --repo-slug myrepo --wiki-root "$_ws/wiki" >/dev/null
  bash "$WIRE" --claude-md "$_ws/CLAUDE.md" --prescan-index "$_ws/.ticket-auto/myrepo/docs/INDEX.md" --repo-slug myrepo --wiki-root "$_ws/wiki" >/dev/null
  local count
  count=$(grep -c '^| Cross-repo |' "$_ws/.ticket-auto/myrepo/docs/INDEX.md")
  _teardown
  [ "$count" -eq 1 ]
}

test_wiki_root_row_replaced_on_change() {
  _setup
  bash "$WIRE" --claude-md "$_ws/CLAUDE.md" --prescan-index "$_ws/.ticket-auto/myrepo/docs/INDEX.md" --repo-slug myrepo --wiki-root "$_ws/wiki-old" >/dev/null
  bash "$WIRE" --claude-md "$_ws/CLAUDE.md" --prescan-index "$_ws/.ticket-auto/myrepo/docs/INDEX.md" --repo-slug myrepo --wiki-root "$_ws/wiki-new" >/dev/null
  local count old_present new_present
  count=$(grep -c '^| Cross-repo |' "$_ws/.ticket-auto/myrepo/docs/INDEX.md")
  old_present=0
  grep -qF 'wiki-old' "$_ws/.ticket-auto/myrepo/docs/INDEX.md" && old_present=1
  new_present=0
  grep -qF "$_ws/wiki-new/index.md" "$_ws/.ticket-auto/myrepo/docs/INDEX.md" && new_present=1
  _teardown
  [ "$count" -eq 1 ] && [ "$old_present" -eq 0 ] && [ "$new_present" -eq 1 ]
}

test_existing_topic_rows_preserved() {
  _setup
  bash "$WIRE" --claude-md "$_ws/CLAUDE.md" --prescan-index "$_ws/.ticket-auto/myrepo/docs/INDEX.md" --repo-slug myrepo --wiki-root "$_ws/wiki" >/dev/null
  local ok=1
  grep -qF '| Billing | services/billing.md |' "$_ws/.ticket-auto/myrepo/docs/INDEX.md" && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_missing_index_file_is_noop() {
  _setup
  rm -f "$_ws/.ticket-auto/myrepo/docs/INDEX.md"
  local rc=0
  bash "$WIRE" --claude-md "$_ws/CLAUDE.md" --prescan-index "$_ws/.ticket-auto/myrepo/docs/INDEX.md" --repo-slug myrepo --wiki-root "$_ws/wiki" >/dev/null 2>&1 || rc=$?
  _teardown
  [ "$rc" -eq 0 ]
}

# ── Runner ───────────────────────────────────────────────────────────────────

for t in test_claude_md_block_inserted test_claude_md_block_idempotent \
  test_no_wiki_root_no_cross_repo_row test_wiki_root_adds_cross_repo_row \
  test_wiki_root_row_under_lookup_by_topic test_wiki_root_row_idempotent_no_duplicate \
  test_wiki_root_row_replaced_on_change test_existing_topic_rows_preserved \
  test_missing_index_file_is_noop; do
  if "$t"; then
    _pass "$t"
  else
    _fail "$t"
  fi
done

echo ""
echo "=== test-prescan-wire-claude-md.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
