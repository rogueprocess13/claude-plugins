#!/usr/bin/env bash
# test-kc-skill-blocks.sh — kc-item.sh next-id / flush-queue and
# kc-ingest.sh audit, which replaced inline fences in kc-capture Step 3,
# kc-capture's plan-mode flush, and kc-import Step 2
# (skill-deterministic-extraction 6b).
#
# The old fences are embedded verbatim below as oracles (CI checkouts are
# shallow, so they cannot be read back with `git show`). Only change: the
# flush oracle takes its queue dir from $Q instead of the real /tmp.
#
# Usage: bash knowledge-curator/test/test-kc-skill-blocks.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KI="$PLUGIN_DIR/lib/kc-item.sh"
KG="$PLUGIN_DIR/lib/kc-ingest.sh"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export KC_RANK_LOG=0

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
eq() { # eq NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected '$2', got '$3'"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

item() { # item DIR ID SLUG [SOURCE] [TITLE]
  cat >"$1/$2--$3.md" <<EOF
---
id: $2
type: idea
title: "${5:-Item $2}"
status: active
priority: p2
project: test
created: 2026-11-01T00:00:00Z
updated: 2026-11-01T00:00:00Z
source: ${4:-manual}
why: "test"
tags: []
relates: []
---
# ${5:-Item $2}
EOF
}

# ── Oracles: the pre-extraction fences (main @ 5474173) ──────────────

old_next_id() { # run in the workspace dir; prints next_id
  latest=$(ls knowledge/KC-[0-9][0-9][0-9][0-9]--*.md 2>/dev/null | sort -V | tail -1)
  if [ -n "$latest" ]; then
    latest_id=$(basename "$latest" | grep -oE 'KC-[0-9]{4}' | head -1)
    next_num=$((10#${latest_id#KC-} + 1))
    printf -v next_id "KC-%04d" "$next_num"
  else
    next_id="KC-0001"
  fi
  echo "$next_id"
}

old_flush() { # run in the workspace dir; queue dir is $Q (was /tmp)
  for qf in "$Q"/kc-capture-queue-*.md; do
    [ -f "$qf" ] || continue
    mv "$qf" "knowledge/$(basename "$qf" | sed 's/^kc-capture-queue-//')"
  done
  bash "${CLAUDE_PLUGIN_ROOT}/lib/kc-index.sh" knowledge/
}

old_audit() { # run in the workspace dir; prints the loop's variables, tab-separated
  for change_dir in openspec/changes/*/; do
    name=$(basename "$change_dir")
    [ "$name" = "archive" ] && continue
    # Check for existing item
    existing=$(grep -l "source: openspec:${name}" knowledge/KC-*.md 2>/dev/null | head -1)

    # Get title from proposal.md: its first `# ` heading (fence-aware), else its
    # first `## `, else the change name
    title=$(bash "${CLAUDE_PLUGIN_ROOT}/lib/kc-ingest.sh" title "${change_dir}proposal.md" "$name")

    # Get completion from tasks.md
    # `|| true`, not `|| echo 0`: grep -c already prints "0" on zero matches
    total=$(grep -c '^\- \[' "${change_dir}tasks.md" 2>/dev/null || true)
    total=${total:-0}
    done=$(grep -c '^\- \[x\]' "${change_dir}tasks.md" 2>/dev/null || true)
    done=${done:-0}

    if [ "$done" -eq "$total" ] && [ "$total" -gt 0 ]; then
      status="done"
    else
      status="active"
    fi

    # Create or update item...
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$status" "$done" "$total" "$existing" "$title"
  done
}

ws() { # ws NAME — fresh workspace with knowledge/ and queue dir
  W="$TMP/$1"
  Q="$W/q"
  mkdir -p "$W/knowledge" "$Q"
}

echo "next-id"

ws n1
eq "empty store → KC-0001 (oracle)" "$(cd "$W" && old_next_id)" "KC-0001"
eq "empty store → KC-0001" "$(cd "$W" && bash "$KI" next-id --queue-dir "$Q")" "KC-0001"

item "$W/knowledge" KC-0001 a
item "$W/knowledge" KC-0009 b
item "$W/knowledge" KC-0010 c
echo "stray" >"$W/knowledge/notes.md"
old=$(cd "$W" && old_next_id)
new=$(cd "$W" && bash "$KI" next-id --queue-dir "$Q")
eq "highest id + 1, numeric order (matches oracle $old)" "$old" "$new"
eq "next after KC-0010 is KC-0011" "KC-0011" "$new"
new=$(cd "$W" && KNOWLEDGE_DIR="$W/knowledge" bash "$KI" next-id --queue-dir "$Q")
eq "honours KNOWLEDGE_DIR" "KC-0011" "$new"

# Behaviour change: a queued (plan-mode) draft holds its id.
echo "draft" >"$Q/kc-capture-queue-KC-0011.md"
eq "oracle ignores the queue (reuses KC-0011)" "KC-0011" "$(cd "$W" && old_next_id)"
eq "queued draft holds its id → KC-0012" "KC-0012" "$(cd "$W" && bash "$KI" next-id --queue-dir "$Q")"
item "$W/knowledge" KC-0012 d
eq "item created between two calls → greater id" "KC-0013" "$(cd "$W" && bash "$KI" next-id --queue-dir "$Q")"
if (cd "$W" && bash "$KI" next-id --bogus >/dev/null 2>&1); then fail "bad flag exits non-zero"; else pass "bad flag exits non-zero"; fi

echo "flush-queue"

ws f1
item "$W/knowledge" KC-0001 first
item "$Q" KC-0002 ignored
mv "$Q/KC-0002--ignored.md" "$Q/kc-capture-queue-KC-0002.md"
sed -i 's/title: "Item KC-0002"/title: "Queued Draft"/' "$Q/kc-capture-queue-KC-0002.md"
cp -r "$W" "$TMP/f1-old"
err=$( (cd "$TMP/f1-old" && Q="$TMP/f1-old/q" old_flush) 2>&1 >/dev/null)
if [ -f "$TMP/f1-old/knowledge/KC-0002.md" ] && grep -q "Orphaned file.*KC-0002.md" <<<"$err" &&
  ! grep -q "KC-0002" "$TMP/f1-old/knowledge/INDEX.md"; then
  pass "oracle: flushed draft lands as orphan KC-0002.md, never indexed"
else
  fail "oracle orphan behaviour changed: $err"
fi

out=$(cd "$W" && bash "$KI" flush-queue --queue-dir "$Q" 2>&1)
rc=$?
eq "flush exit 0" "0" "$rc"
if [ -f "$W/knowledge/KC-0002--queued-draft.md" ] && [ ! -e "$Q/kc-capture-queue-KC-0002.md" ]; then
  pass "draft added as KC-0002--queued-draft.md and dequeued"
else
  fail "draft not added/dequeued: $out"
fi
if grep -q "KC-0002" "$W/knowledge/INDEX.md"; then pass "flushed draft is indexed"; else fail "flushed draft missing from INDEX.md"; fi
if grep -q "^Added: KC-0002" <<<"$out"; then pass "reports Added: line"; else fail "no Added: line: $out"; fi

# A draft that fails validation stays queued; one whose id is taken too.
printf -- '---\nid: KC-0003\ntitle: "broken"\n---\n' >"$Q/kc-capture-queue-KC-0003.md"
item "$Q" KC-0001 dup
mv "$Q/KC-0001--dup.md" "$Q/kc-capture-queue-KC-0001.md"
out=$(cd "$W" && bash "$KI" flush-queue --queue-dir "$Q" 2>&1)
rc=$?
eq "failed drafts → exit 4" "4" "$rc"
if [ -f "$Q/kc-capture-queue-KC-0003.md" ] && grep -q "Still queued: $Q/kc-capture-queue-KC-0003.md" <<<"$out"; then
  pass "invalid draft stays queued and is named"
else
  fail "invalid draft: $out"
fi
if [ -f "$Q/kc-capture-queue-KC-0001.md" ] && grep -q "^id: KC-0001" "$W/knowledge/KC-0001--first.md" &&
  ! grep -q "dup" "$W/knowledge/KC-0001--first.md"; then
  pass "draft whose id is taken never overwrites the existing item"
else
  fail "id collision overwrote or dequeued"
fi
ws f2
out=$(cd "$W" && bash "$KI" flush-queue --queue-dir "$Q" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "empty queue → exit 0, silent"; else fail "empty queue rc=$rc '$out'"; fi

echo "audit"

ws a1
C="$W/openspec/changes"
mkdir -p "$C"/{all-done,partial,no-tasks,zero-match,archive/old,fenced}
printf '# All Done\n' >"$C/all-done/proposal.md"
printf -- '- [x] 1\n- [x] 2\n' >"$C/all-done/tasks.md"
printf '## Why\n\nreasons\n' >"$C/partial/proposal.md"
printf -- '- [x] 1\n- [ ] 2\n- [X] 3\n  - [x] nested\n' >"$C/partial/tasks.md"
printf 'no heading\n' >"$C/zero-match/tasks.md"
printf '```\n# fenced\n```\n# Real\n' >"$C/fenced/proposal.md"
item "$W/knowledge" KC-0001 x "openspec:partial"
item "$W/knowledge" KC-0002 y "openspec:all-done"
old=$(cd "$W" && old_audit)
new=$(cd "$W" && bash "$KG" audit)
eq "audit lines equal the oracle's variables" "$old" "$new"
n=$(grep -c . <<<"$new")
eq "one line per change, archive/ skipped" "5" "$n"
line=$(grep '^partial' <<<"$new")
eq "partial: active 1 of 3 (uppercase X counts in total only)" \
  "partial	active	1	3	knowledge/KC-0001--x.md	Why" "$line"
eq "explicit dirs equal defaults" "$new" "$(cd "$W" && bash "$KG" audit --changes-dir openspec/changes --knowledge-dir knowledge)"

# Behaviour change: the existing-item match is the whole source value.
ws a2
C="$W/openspec/changes"
mkdir -p "$C/foo" "$C/foo-bar" "$C/quoted"
item "$W/knowledge" KC-0001 x "openspec:foo-bar"
item "$W/knowledge" KC-0002 y '"openspec:quoted"'
old=$(cd "$W" && old_audit | grep '^foo	' | cut -f5)
new=$(cd "$W" && bash "$KG" audit | grep '^foo	' | cut -f5)
eq "oracle: foo matched foo-bar's item (prefix)" "knowledge/KC-0001--x.md" "$old"
eq "foo no longer matches foo-bar's item" "" "$new"
eq "quoted source value still matches" "knowledge/KC-0002--y.md" \
  "$(cd "$W" && bash "$KG" audit | grep '^quoted' | cut -f5)"
out=$(cd "$TMP" && bash "$KG" audit --changes-dir "$TMP/none" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "missing changes dir → empty, exit 0"; else fail "missing dir rc=$rc '$out'"; fi
if bash "$KG" audit --bogus x >/dev/null 2>&1; then fail "bad flag exits non-zero"; else pass "bad flag exits non-zero"; fi

echo "skills"
CAP="$PLUGIN_DIR/skills/kc-capture/SKILL.md"
IMP="$PLUGIN_DIR/skills/kc-import/SKILL.md"
grep -q 'kc-item.sh" next-id' "$CAP" && pass "kc-capture Step 3 calls next-id" || fail "kc-capture Step 3 calls next-id"
grep -q 'kc-item.sh" flush-queue' "$CAP" && pass "kc-capture plan mode calls flush-queue" || fail "kc-capture flush-queue"
if grep -q 'sort -V | tail -1\|mv "\$qf"' "$CAP"; then fail "kc-capture inline fences gone"; else pass "kc-capture inline fences gone"; fi
grep -q 'kc-ingest.sh" audit' "$IMP" && pass "kc-import Step 2 calls audit" || fail "kc-import Step 2 calls audit"
if grep -q "grep -c '^\\\\- \\\\\[" "$IMP"; then fail "kc-import inline task count gone"; else pass "kc-import inline task count gone"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
