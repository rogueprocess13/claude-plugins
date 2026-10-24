#!/usr/bin/env bash
# test-conflict-marker-scan.sh — unit tests for lib/conflict-marker-scan.sh
# (review finding DET-IP-5: pr-review's merge gate treated any added line
# containing `=======` as a conflict marker, e.g. a markdown setext heading).
# Usage: bash test-conflict-marker-scan.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
CMS="$LIB_DIR/conflict-marker-scan.sh"

PASS=0
FAIL=0
FILTER="${1:-}"

_run() {
  local name="$1"
  shift
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return 0
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_rc=0
_out=""
# _scan <diff text> — runs the scanner on stdin.
_scan() {
  _rc=0
  _out=$(printf '%s\n' "$1" | bash "$CMS" 2>/dev/null) || _rc=$?
}

_hdr() {
  printf 'diff --git a/%s b/%s\nindex 111..222 100644\n--- a/%s\n+++ b/%s\n@@ -1,1 +1,9 @@\n' "$1" "$1" "$1" "$1"
}

test_real_conflict_block_blocks() {
  _scan "$(_hdr src/app.js)
 const a = 1;
+<<<<<<< HEAD
+const b = 2;
+=======
+const b = 3;
+>>>>>>> feature
 const c = 4;"
  [ "$_rc" = 1 ] && [ "$_out" = "src/app.js:<<<<<<< HEAD" ]
}

test_markdown_setext_heading_does_not_block() {
  _scan "$(_hdr README.md)
+Installation
+=======
+
+Run the installer."
  [ "$_rc" = 0 ] && [ -z "$_out" ]
}

test_lone_separator_does_not_block() {
  _scan "$(_hdr notes.txt)
+=======
+text"
  [ "$_rc" = 0 ]
}

test_inline_equals_does_not_block() {
  _scan "$(_hdr notes.txt)
+foo ======= bar
+==========
+# <<<<<<< not at line start"
  [ "$_rc" = 0 ]
}

test_removed_conflict_block_does_not_block() {
  # Resolving a conflict REMOVES markers; removed lines never count.
  _scan "$(_hdr src/app.js)
-<<<<<<< HEAD
-const b = 2;
-=======
-const b = 3;
->>>>>>> feature
+const b = 3;"
  [ "$_rc" = 0 ]
}

test_markers_split_across_files_do_not_block() {
  _scan "$(_hdr a.txt)
+<<<<<<< HEAD
+x
+=======
$(_hdr b.txt)
+>>>>>>> other"
  [ "$_rc" = 0 ]
}

test_diff3_base_section_still_blocks() {
  _scan "$(_hdr a.py)
+<<<<<<< ours
+x = 1
+||||||| base
+x = 0
+=======
+x = 2
+>>>>>>> theirs"
  [ "$_rc" = 1 ]
}

test_context_lines_between_markers_still_block() {
  _scan "$(_hdr a.py)
+<<<<<<< HEAD
 unchanged = True
+=======
 also_unchanged = True
+>>>>>>> feature"
  [ "$_rc" = 1 ]
}

test_crlf_conflict_blocks() {
  local body
  body=$(printf '+<<<<<<< HEAD\r\n+a\r\n+=======\r\n+b\r\n+>>>>>>> feature\r')
  _scan "$(_hdr win.txt)
${body}"
  [ "$_rc" = 1 ]
}

test_file_argument_and_unreadable_rc2() {
  local tmp rc=0
  tmp=$(mktemp)
  printf '%s\n' "$(_hdr a.txt)" '+<<<<<<< HEAD' '+=======' '+>>>>>>> x' >"$tmp"
  bash "$CMS" "$tmp" >/dev/null 2>&1 || rc=$?
  rm -f "$tmp"
  [ "$rc" = 1 ] || return 1
  rc=0
  bash "$CMS" /nonexistent/diff >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ]
}

# ticket-pr-review must use the script, not the over-matching grep.
test_pr_review_uses_script() {
  local skill="$PLUGIN_DIR/skills/ticket-pr-review/SKILL.md"
  grep -q 'conflict-marker-scan.sh' "$skill" &&
    ! grep -qF '\(<<<<<<<\|=======\|>>>>>>>\)' "$skill"
}

_run "real conflict block blocks" test_real_conflict_block_blocks
_run "markdown setext heading does not block" test_markdown_setext_heading_does_not_block
_run "lone ======= does not block" test_lone_separator_does_not_block
_run "inline/longer equals do not block" test_inline_equals_does_not_block
_run "removed conflict block does not block" test_removed_conflict_block_does_not_block
_run "markers split across files do not block" test_markers_split_across_files_do_not_block
_run "diff3 base section still blocks" test_diff3_base_section_still_blocks
_run "context lines between markers still block" test_context_lines_between_markers_still_block
_run "CRLF conflict blocks" test_crlf_conflict_blocks
_run "file argument; unreadable rc 2" test_file_argument_and_unreadable_rc2
_run "ticket-pr-review uses conflict-marker-scan.sh" test_pr_review_uses_script

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
