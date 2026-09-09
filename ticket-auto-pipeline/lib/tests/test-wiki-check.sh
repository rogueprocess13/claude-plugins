#!/usr/bin/env bash
# test-wiki-check.sh — tests for lib/wiki-check.sh
# Covers the freshness contract lint: frontmatter completeness, broken
# `related:` links, backticked class-name resolution against a repo tree, and
# fresh/stale/decayed classification (wiki-cross-repo-knowledge-layer, #335
# change 5).
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
CHECK="$LIB_DIR/wiki-check.sh"

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
_repo=""
_sha_v1=""
_sha_v2=""

_setup() {
  _ws="$(mktemp -d)"
  mkdir -p "$_ws/wiki"
  mkdir -p "$_ws/repos/bom"
  _repo="$_ws/repos/bom"
  git init -q "$_repo"
  printf 'public class BomFeignClient {}\n' >"$_repo/BomFeignClient.java"
  git -C "$_repo" add -A
  git -C "$_repo" -c user.email=t@t.com -c user.name=t commit -q -m init
  _sha_v1=$(git -C "$_repo" rev-parse HEAD)
  printf 'public class Extra {}\n' >"$_repo/Extra.java"
  git -C "$_repo" add -A
  git -C "$_repo" -c user.email=t@t.com -c user.name=t commit -q -m "add extra"
  _sha_v2=$(git -C "$_repo" rev-parse HEAD)
}

_teardown() {
  [ -n "$_ws" ] && rm -rf "$_ws"
  _ws=""
  _repo=""
  _sha_v1=""
  _sha_v2=""
}

_write_wiki_file() {
  # _write_wiki_file <relpath> <content>
  mkdir -p "$(dirname "$_ws/wiki/$1")"
  printf '%s' "$2" >"$_ws/wiki/$1"
}

# ── Fixtures (frontmatter templates) ────────────────────────────────────────────

_fm_complete_fresh() {
  cat <<EOF
---
services: [bom]
related: []
verified_at: "$(date -u +%Y-%m-%d)"
verified_against: {repo: "bom", sha: "$_sha_v2"}
stale_after: 90
verified: machine-verified
---

# Flow

Calls \`BomFeignClient.charge()\`.
EOF
}

_fm_stale() {
  cat <<EOF
---
services: [bom]
related: []
verified_at: "$(date -u +%Y-%m-%d)"
verified_against: {repo: "bom", sha: "$_sha_v1"}
stale_after: 90
verified: machine-verified
---

# Flow

One commit landed since verification.
EOF
}

_fm_decayed_age() {
  cat <<EOF
---
services: [bom]
related: []
verified_at: "2020-01-01"
verified_against: {repo: "bom", sha: "$_sha_v2"}
stale_after: 90
verified: human-reviewed
---

# Flow

Verified long ago — past stale_after.
EOF
}

_fm_broken_related() {
  cat <<EOF
---
services: [bom]
related: ["does-not-exist.md"]
verified_at: "$(date -u +%Y-%m-%d)"
verified_against: {repo: "bom", sha: "$_sha_v2"}
stale_after: 90
verified: machine-verified
---

# Flow
EOF
}

_fm_unknown_class() {
  cat <<EOF
---
services: [bom]
related: []
verified_at: "$(date -u +%Y-%m-%d)"
verified_against: {repo: "bom", sha: "$_sha_v2"}
stale_after: 90
verified: machine-verified
---

# Flow

Calls \`TotallyMadeUpClass.doThing()\`.
EOF
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_complete_frontmatter_fresh() {
  _setup
  _write_wiki_file "a.md" "$(_fm_complete_fresh)"
  local out
  out=$(bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md)
  local ok=1
  echo "$out" | grep -qF 'frontmatter=complete' &&
    echo "$out" | grep -qF 'freshness=fresh' &&
    echo "$out" | grep -qF 'broken_related=0' &&
    echo "$out" | grep -qF 'unknown_classes=0' && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_stale_after_one_commit() {
  _setup
  _write_wiki_file "a.md" "$(_fm_stale)"
  local out
  out=$(bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md)
  local ok=1
  echo "$out" | grep -qF 'freshness=stale' && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_decayed_by_age() {
  _setup
  _write_wiki_file "a.md" "$(_fm_decayed_age)"
  local out
  out=$(bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md)
  local ok=1
  echo "$out" | grep -qF 'freshness=decayed' && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_no_frontmatter_is_incomplete_and_decayed() {
  _setup
  _write_wiki_file "a.md" '# Plain file

No frontmatter block at all.
'
  local out
  out=$(bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md)
  local ok=1
  echo "$out" | grep -qF 'frontmatter=incomplete' &&
    echo "$out" | grep -qF 'freshness=decayed' && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_broken_related_link_detected() {
  _setup
  _write_wiki_file "a.md" "$(_fm_broken_related)"
  local out
  out=$(bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md)
  local ok=1
  echo "$out" | grep -qF 'broken_related=1:does-not-exist.md' && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_related_link_that_exists_not_flagged() {
  _setup
  _write_wiki_file "b.md" "# b"
  local content
  content=$(_fm_complete_fresh | sed 's/related: \[\]/related: ["b.md"]/')
  _write_wiki_file "a.md" "$content"
  local out
  out=$(bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md)
  local ok=1
  echo "$out" | grep -qF 'broken_related=0' && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_unknown_class_flagged() {
  _setup
  _write_wiki_file "a.md" "$(_fm_unknown_class)"
  local out
  out=$(bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md)
  local ok=1
  echo "$out" | grep -qF 'unknown_classes=1:TotallyMadeUpClass' && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_known_class_not_flagged() {
  _setup
  _write_wiki_file "a.md" "$(_fm_complete_fresh)"
  local out
  out=$(bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md)
  local ok=1
  echo "$out" | grep -qF 'unknown_classes=0' && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_no_repos_root_skips_class_check() {
  _setup
  _write_wiki_file "a.md" "$(_fm_unknown_class)"
  local out
  out=$(bash "$CHECK" --wiki-root "$_ws/wiki" --file a.md)
  local ok=1
  echo "$out" | grep -qF 'unknown_classes=0' && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_index_md_excluded_from_full_scan() {
  _setup
  _write_wiki_file "index.md" "# index"
  _write_wiki_file "a.md" "$(_fm_complete_fresh)"
  local out
  out=$(bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos")
  local ok=1
  echo "$out" | grep -qF 'files=1' && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_exit_code_zero_when_clean() {
  _setup
  _write_wiki_file "a.md" "$(_fm_complete_fresh)"
  local rc=0
  bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md >/dev/null || rc=$?
  _teardown
  [ "$rc" -eq 0 ]
}

test_exit_code_nonzero_when_issues_found() {
  _setup
  _write_wiki_file "a.md" "$(_fm_decayed_age)"
  local rc=0
  bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md >/dev/null || rc=$?
  _teardown
  [ "$rc" -eq 1 ]
}

test_missing_wiki_root_errors() {
  local rc=0
  bash "$CHECK" --wiki-root /nonexistent/path/xyz >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_changed_only_scopes_to_git_status() {
  _setup
  _write_wiki_file "committed.md" "$(_fm_complete_fresh)"
  git -C "$_ws/wiki" init -q
  git -C "$_ws/wiki" add -A
  git -C "$_ws/wiki" -c user.email=t@t.com -c user.name=t commit -q -m init
  _write_wiki_file "uncommitted.md" "$(_fm_complete_fresh)"
  local out
  out=$(bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --changed-only)
  local has_uncommitted=1 has_committed=1
  echo "$out" | grep -qF 'uncommitted.md' && has_uncommitted=0
  echo "$out" | grep -qF '|committed.md|' && has_committed=0
  _teardown
  [ "$has_uncommitted" -eq 0 ] && [ "$has_committed" -eq 1 ]
}

# ── Runner ───────────────────────────────────────────────────────────────────

for t in test_complete_frontmatter_fresh test_stale_after_one_commit \
  test_decayed_by_age test_no_frontmatter_is_incomplete_and_decayed \
  test_broken_related_link_detected test_related_link_that_exists_not_flagged \
  test_unknown_class_flagged test_known_class_not_flagged \
  test_no_repos_root_skips_class_check test_index_md_excluded_from_full_scan \
  test_exit_code_zero_when_clean test_exit_code_nonzero_when_issues_found \
  test_missing_wiki_root_errors test_changed_only_scopes_to_git_status; do
  if "$t"; then
    _pass "$t"
  else
    _fail "$t"
  fi
done

echo ""
echo "=== test-wiki-check.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
