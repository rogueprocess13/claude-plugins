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

# ── #416: worktree exclusion + time bound on the class-name check ──────────────

test_class_only_in_worktree_trees_is_unknown() {
  # A class defined only inside .ticket-auto/ worktrees, .verify-worktrees/,
  # or a build output must NOT count as resolved: those trees are excluded
  # from the walk (they multiply the search by every in-flight ticket).
  _setup
  mkdir -p "$_ws/repos/.ticket-auto/worktrees/T-1--slug/src" \
    "$_ws/repos/.verify-worktrees/T-1/src" "$_ws/repos/bom/build"
  printf 'class TotallyMadeUpClass {}\n' >"$_ws/repos/.ticket-auto/worktrees/T-1--slug/src/A.java"
  printf 'class TotallyMadeUpClass {}\n' >"$_ws/repos/.verify-worktrees/T-1/src/A.java"
  printf 'class TotallyMadeUpClass {}\n' >"$_ws/repos/bom/build/A.java"
  _write_wiki_file "a.md" "$(_fm_unknown_class)"
  local out
  out=$(bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md)
  local ok=1
  echo "$out" | grep -qF 'unknown_classes=1:TotallyMadeUpClass' && ok=0
  _teardown
  [ "$ok" -eq 0 ]
}

test_class_budget_exhausted_skips_not_unknown() {
  # Budget of 0s: every name is skipped. Skipped names are not unknown, the
  # stdout grammar is unchanged, and a WIKI_CHECK_NOTE lands on stderr.
  _setup
  _write_wiki_file "a.md" "$(_fm_unknown_class)"
  local out err rc=0
  err="$_ws/err.txt"
  out=$(WIKI_CHECK_CLASS_BUDGET_SECS=0 bash "$CHECK" --wiki-root "$_ws/wiki" \
    --repos-root "$_ws/repos" --file a.md 2>"$err") || rc=$?
  local ok=1
  if echo "$out" | grep -qF 'unknown_classes=0|' &&
    echo "$out" | grep -q '^WIKI_CHECK_SUMMARY|' &&
    ! echo "$out" | grep -q 'WIKI_CHECK_NOTE' &&
    grep -qF 'WIKI_CHECK_NOTE|a.md|class_check=partial|skipped=1|' "$err" &&
    [ "$rc" -eq 0 ]; then
    ok=0
  fi
  _teardown
  [ "$ok" -eq 0 ]
}

test_class_grep_hang_is_time_bounded() {
  # A grep that would hang (stubbed to sleep) is killed by the per-grep
  # timeout and degrades to "skipped" instead of blocking the lint.
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    echo "SKIP: no timeout binary"
    return 0
  fi
  _setup
  _write_wiki_file "a.md" "$(_fm_unknown_class)"
  local real_grep
  real_grep=$(command -v grep)
  mkdir -p "$_ws/bin"
  cat >"$_ws/bin/grep" <<EOF
#!/usr/bin/env bash
# Recursive tree walks hang; every other grep behaves normally.
for a in "\$@"; do
  case "\$a" in -r*) exec sleep 30 ;; esac
done
exec "$real_grep" "\$@"
EOF
  chmod +x "$_ws/bin/grep"
  local out err start elapsed
  err="$_ws/err.txt"
  start=$(date +%s)
  out=$(PATH="$_ws/bin:$PATH" WIKI_CHECK_CLASS_GREP_TIMEOUT_SECS=1 bash "$CHECK" \
    --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md 2>"$err") || true
  elapsed=$(($(date +%s) - start))
  local ok=1
  if [ "$elapsed" -lt 15 ] &&
    echo "$out" | grep -qF 'unknown_classes=0|' &&
    grep -qF 'class_check=partial|skipped=1|' "$err"; then
    ok=0
  fi
  _teardown
  [ "$ok" -eq 0 ]
}

# ── verified_against shapes (#576) ─────────────────────────────────────────────

_sha_ledger=""
_setup_two_repos() {
  _setup
  git init -q "$_ws/repos/ledger"
  printf 'x\n' >"$_ws/repos/ledger/a.txt"
  git -C "$_ws/repos/ledger" add -A
  git -C "$_ws/repos/ledger" -c user.email=t@t.com -c user.name=t commit -q -m init
  _sha_ledger=$(git -C "$_ws/repos/ledger" rev-parse HEAD)
}

# _fm_va <verified_against-lines> — a complete frontmatter whose
# verified_against key (and anything under it) is the given text.
_fm_va() {
  cat <<EOF
---
services: [bom]
related: []
verified_at: "$(date -u +%Y-%m-%d)"
$1
stale_after: 90
verified: machine-verified
---

# Flow
EOF
}

_va_run() {
  # _va_run <verified_against-lines> [env...] — prints the WIKI_CHECK line
  _write_wiki_file "a.md" "$(_fm_va "$1")"
  shift
  env "$@" bash "$CHECK" --wiki-root "$_ws/wiki" --repos-root "$_ws/repos" --file a.md 2>/dev/null || true
}

test_va_block_repo_sha_is_complete() {
  _setup
  local out
  out=$(_va_run "$(printf 'verified_against:\n  repo: bom\n  sha: %s' "$_sha_v2")")
  _teardown
  [[ "$out" == *"frontmatter=complete"* && "$out" == *"freshness=fresh"* ]]
}

test_va_multiline_map_is_complete_and_fresh() {
  _setup_two_repos
  local out
  out=$(_va_run "$(printf 'verified_against:\n  bom: %s\n  ledger: %s' "${_sha_v2:0:12}" "$_sha_ledger")")
  _teardown
  [[ "$out" == *"frontmatter=complete"* && "$out" == *"freshness=fresh"* ]]
}

test_va_inline_flow_map_is_complete() {
  _setup_two_repos
  local out
  out=$(_va_run "verified_against: {bom: \"$_sha_v2\", ledger: $_sha_ledger}")
  _teardown
  [[ "$out" == *"frontmatter=complete"* && "$out" == *"freshness=fresh"* ]]
}

test_va_map_worst_entry_wins_stale() {
  _setup_two_repos
  local out
  # bom is one commit behind, ledger is current: the file is stale, not fresh.
  out=$(_va_run "$(printf 'verified_against:\n  ledger: %s\n  bom: %s' "$_sha_ledger" "$_sha_v1")")
  _teardown
  [[ "$out" == *"frontmatter=complete"* && "$out" == *"freshness=stale"* ]]
}

test_va_map_worst_entry_wins_decayed() {
  _setup_two_repos
  local out
  out=$(_va_run "$(printf 'verified_against:\n  ledger: %s\n  bom: %s' "$_sha_ledger" "$_sha_v1")" WIKI_CHECK_DECAY_COMMIT_LIMIT=1)
  _teardown
  [[ "$out" == *"frontmatter=complete"* && "$out" == *"freshness=decayed"* ]]
}

test_va_map_unresolvable_repo_is_stale() {
  _setup_two_repos
  local out
  out=$(_va_run "$(printf 'verified_against:\n  ledger: %s\n  no-such-repo: abcdef1234' "$_sha_ledger")")
  _teardown
  [[ "$out" == *"frontmatter=complete"* && "$out" == *"freshness=stale"* ]]
}

test_va_map_bad_sha_is_incomplete() {
  _setup_two_repos
  local out
  out=$(_va_run "$(printf 'verified_against:\n  ledger: %s\n  bom: not-a-sha' "$_sha_ledger")")
  _teardown
  [[ "$out" == *"frontmatter=incomplete:verified_against"* && "$out" == *"freshness=decayed"* ]]
}

test_va_empty_block_is_incomplete() {
  _setup
  local out
  out=$(_va_run "verified_against:")
  _teardown
  [[ "$out" == *"frontmatter=incomplete:verified_against"* ]]
}

# ── Runner ───────────────────────────────────────────────────────────────────

for t in test_complete_frontmatter_fresh test_stale_after_one_commit \
  test_decayed_by_age test_no_frontmatter_is_incomplete_and_decayed \
  test_broken_related_link_detected test_related_link_that_exists_not_flagged \
  test_unknown_class_flagged test_known_class_not_flagged \
  test_no_repos_root_skips_class_check test_index_md_excluded_from_full_scan \
  test_exit_code_zero_when_clean test_exit_code_nonzero_when_issues_found \
  test_missing_wiki_root_errors test_changed_only_scopes_to_git_status \
  test_class_only_in_worktree_trees_is_unknown \
  test_class_budget_exhausted_skips_not_unknown \
  test_class_grep_hang_is_time_bounded \
  test_va_block_repo_sha_is_complete \
  test_va_multiline_map_is_complete_and_fresh \
  test_va_inline_flow_map_is_complete \
  test_va_map_worst_entry_wins_stale \
  test_va_map_worst_entry_wins_decayed \
  test_va_map_unresolvable_repo_is_stale \
  test_va_map_bad_sha_is_incomplete \
  test_va_empty_block_is_incomplete; do
  if "$t"; then
    _pass "$t"
  else
    _fail "$t"
  fi
done

echo ""
echo "=== test-wiki-check.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
