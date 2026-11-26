#!/usr/bin/env bash
# test-notes-field.sh — lib/notes-field.sh and its callers (GitHub #822).
#
# ticket-implement writes the pre-implementation checkpoint as one line,
# `- Repos: … | Branch: … | Worktree: <path> | Mode: …`. ticket-verify Step 6
# read it with `sed 's/.*Worktree: //'`, which kept ` | Mode: …`, so the
# worktree path did not exist. These tests pin the helper's parse and fail if
# any skill goes back to an unbounded `Worktree:` read.
#
# Usage: bash test-notes-field.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
NF="$LIB_DIR/notes-field.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

_eq() {
  [ "$1" = "$2" ] || {
    echo "  expected [$2], got [$1]" >&2
    return 1
  }
}

# The exact line ticket-implement Step 3 writes.
mkdir -p "$_tmp/t1"
cat >"$_tmp/t1/notes.md" <<'EOF'
### 2026-11-20 — pre-implementation checkpoint
- Repos: app | Branch: t-9-fix | Worktree: /root/.ticket-auto/worktrees/T-9/app | Mode: simple-fix
EOF

test_worktree_stops_at_next_field() {
  _eq "$(bash "$NF" worktree "$_tmp/t1")" "/root/.ticket-auto/worktrees/T-9/app"
}
_run "worktree value stops before ' | Mode: …'" test_worktree_stops_at_next_field

test_other_fields() {
  _eq "$(bash "$NF" branch "$_tmp/t1/notes.md")" "t-9-fix" &&
    _eq "$(bash "$NF" repos "$_tmp/t1")" "app" &&
    _eq "$(bash "$NF" mode "$_tmp/t1")" "simple-fix"
}
_run "branch, repos and mode read from the same line" test_other_fields

test_last_checkpoint_wins_and_backticks_trimmed() {
  mkdir -p "$_tmp/t2"
  cat >"$_tmp/t2/notes.md" <<'EOF'
- Repos: app | Branch: b1 | Worktree: /old/app | Mode: simple-fix
- Repos: app | Branch: b2 | Worktree: `/new/app`   | Mode: openspec: x
EOF
  _eq "$(bash "$NF" worktree "$_tmp/t2")" "/new/app"
}
_run "last checkpoint wins; backticks and padding trimmed" test_last_checkpoint_wins_and_backticks_trimmed

test_worktree_last_field() {
  mkdir -p "$_tmp/t3"
  printf -- '- Worktree: /only/path  \n' >"$_tmp/t3/notes.md"
  _eq "$(bash "$NF" worktree "$_tmp/t3")" "/only/path"
}
_run "a Worktree field with nothing after it" test_worktree_last_field

test_missing_is_exit_1() {
  mkdir -p "$_tmp/t4"
  printf '# notes\n' >"$_tmp/t4/notes.md"
  local rc=0
  bash "$NF" worktree "$_tmp/t4" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || return 1
  rc=0
  bash "$NF" worktree "$_tmp/nope" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || return 1
  rc=0
  bash "$NF" bogus "$_tmp/t1" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}
_run "no field or no notes.md is exit 1; bad usage is exit 2" test_missing_is_exit_1

# The regression itself: the verify skill's worktree read, as written, must
# give the bare path on the checkpoint line.
test_verify_skill_reads_through_helper() {
  local f="$PLUGIN_DIR/skills/ticket-verify/SKILL.md"
  grep -qF 'notes-field.sh worktree' "$f" || {
    echo "  ticket-verify/SKILL.md does not read the worktree through notes-field.sh" >&2
    return 1
  }
}
_run "ticket-verify Step 6 reads the worktree through notes-field.sh" test_verify_skill_reads_through_helper

test_no_unbounded_worktree_read() {
  local hits
  hits=$(grep -rnE "sed '?\"?s/\.\*Worktree: //" "$PLUGIN_DIR/skills" "$PLUGIN_DIR/agents" "$PLUGIN_DIR/lib" \
    --include='*.md' --include='*.sh' 2>/dev/null | grep -v '/tests/' || true)
  [ -z "$hits" ] || {
    echo "  unbounded Worktree: read (keeps ' | Mode: …'):" >&2
    echo "$hits" >&2
    return 1
  }
}
_run "no skill or lib reads Worktree: with an unbounded sed" test_no_unbounded_worktree_read

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
