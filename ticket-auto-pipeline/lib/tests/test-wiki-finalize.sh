#!/usr/bin/env bash
# test-wiki-finalize.sh — unit tests for lib/wiki-finalize.sh and
# lib/ai-context-find.sh (wiki-maintenance Steps 2.5a, 4 and 4.5,
# skill-deterministic-extraction 6a).
#
# Parity oracle: the pre-extraction fences themselves, main @ 267c17f,
# embedded verbatim below (_old_step4 / _old_step45 / _old_find) with the
# placeholders filled. CI checkouts are shallow, so the oracle cannot be
# `git show`n. Both sides run in identical workspaces; the pipeline log
# (timestamps masked), stdout+stderr and exit code are compared.
#
# Usage: bash test-wiki-finalize.sh
set -eo pipefail

WF_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF_LIB_DIR="$(cd "$WF_TEST_DIR/.." && pwd)"
TID="T-1"
MSG="docs(wiki): T-1 incorporate errata"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export WIKI_LOCK_POLL_SECS=0 WIKI_LOCK_WAIT_SECS=0

PASS=0 FAIL=0
_ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
_ko() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}
_same() {
  if [ "$2" = "$3" ]; then _ok "$1"; else
    _ko "$1"
    diff <(echo "$2") <(echo "$3") | sed 's/^/    /' || true
  fi
}

# Workspace: $WS/home/.claude/skills/lib -> LIB (a copy when $1=copy, so a
# test can replace one script), a git wiki at $WS/wiki, log at $WS/p.log.
_ws_new() {
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/home/.claude/skills" "$WS/wiki/flows"
  if [ "${1:-}" = copy ]; then
    cp -r "$WF_LIB_DIR" "$WS/lib"
    LIB="$WS/lib"
  else
    LIB="$WF_LIB_DIR"
  fi
  ln -s "$LIB" "$WS/home/.claude/skills/lib"
  export HOME="$WS/home" TAP_LOG="$WS/p.log"
  : >"$TAP_LOG"
  WIKI="$WS/wiki"
  git -C "$WIKI" init -q
  printf '# Index\n' >"$WIKI/index.md"
  printf 'a\n' >"$WIKI/flows/a.md"
  git -C "$WIKI" add -A
  git -C "$WIKI" commit -q -m init
}
_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }
_mask() {
  sed -e "s|$WS|\$WS|g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g' \
    -e 's/WIKI_LOCK_COMMIT=[0-9a-f]*/WIKI_LOCK_COMMIT=SHA/'
}
_acquire() { bash "$LIB/wiki-lock.sh" acquire --wiki-root "$WIKI" --ticket "$TID" --log-file "$TAP_LOG" >/dev/null; }
_holder() { cut -d' ' -f1 "$WIKI/.git/wiki-maintenance.lock.d/owner" 2>/dev/null || true; }

# wiki-maintenance SKILL.md Step 4 fence, main @ 267c17f ({TICKET-ID}=T-1).
# Its `echo … | grep -q` is written as a here-string here (lint gate,
# GitHub #640); the fence ran without pipefail, so the result is the same.
_old_step4() {
  WIKI_ROOT="$1" bash -c '
_wlock="$HOME/.claude/skills/lib/wiki-lock.sh"
if [ -z "$WIKI_ROOT" ] || [ ! -d "$WIKI_ROOT/.git" ]; then
  echo "WARNING: WIKI_ROOT not configured or not a git repo — skipping wiki commit" >&2
  bash ~/.claude/skills/lib/plog.sh MAINTENANCE wiki-commit skip "WIKI_ROOT not configured or not a git repo"
else
  _adr_check_out=$(bash "$HOME/.claude/skills/lib/adr-check.sh" --wiki-root "$WIKI_ROOT" 2>&1)
  _adr_check_rc=$?
  if [ "$_adr_check_rc" -ne 0 ] && grep -q '"'"'ACCEPTED_ADR_MODIFIED'"'"' <<<"$_adr_check_out"; then
    echo "ERROR: adr-check.sh found a modification to an Accepted ADR — refusing to commit WIKI_ROOT." >&2
    echo "Accepted ADRs are immutable in meaning (docs/adr-schema.md). Revert the edit and draft a superseding ADR instead." >&2
    bash ~/.claude/skills/lib/plog.sh MAINTENANCE wiki-commit fail "ACCEPTED_ADR_MODIFIED — commit refused"
    bash "$_wlock" release --wiki-root "$WIKI_ROOT" --ticket "T-1" >/dev/null
    exit 1
  elif [ "$_adr_check_rc" -ne 0 ]; then
    bash ~/.claude/skills/lib/plog.sh MAINTENANCE adr-check warn "violations found — see command output"
  fi
  bash "$_wlock" commit --wiki-root "$WIKI_ROOT" --ticket "T-1" \
    --message "docs(wiki): T-1 incorporate errata"
  _wcommit_rc=$?
  case "$_wcommit_rc" in
    0) ;;
    6) echo "Nothing of this run'"'"'s to commit in WIKI_ROOT — skipping commit." ;;
    5)
      echo "WARNING: WIKI_ROOT lock no longer held by T-1 — commit refused" >&2
      bash ~/.claude/skills/lib/plog.sh MAINTENANCE wiki-commit fail "WIKI_ROOT lock not held — commit refused"
      ;;
    *) bash ~/.claude/skills/lib/plog.sh MAINTENANCE wiki-commit fail "git commit failed (rc $_wcommit_rc)" ;;
  esac
fi
if [ -n "$WIKI_ROOT" ] && [ -d "$WIKI_ROOT" ]; then
  bash "$_wlock" release --wiki-root "$WIKI_ROOT" --ticket "T-1"
fi
'
}
# Step 4.5 fence, main @ 267c17f. Its output was the agent's, not logged.
_old_step45() {
  WIKI_ROOT="$1" bash -c '
if [ -n "$WIKI_ROOT" ] && [ -d "$WIKI_ROOT" ]; then
  _wiki_verify_out=$(bash "$HOME/.claude/skills/lib/wiki-verify.sh" --wiki-root "$WIKI_ROOT" 2>&1)
  _wiki_verify_rc=$?
  _wiki_verify_count=$(echo "$_wiki_verify_out" | grep -oE '"'"'violations=[0-9]+'"'"' | tail -1 | cut -d= -f2)
  if [ "$_wiki_verify_rc" -eq 2 ]; then
    bash ~/.claude/skills/lib/plog.sh MAINTENANCE wiki-verify fail "setup error — see command output"
  elif [ "$_wiki_verify_rc" -ne 0 ]; then
    bash ~/.claude/skills/lib/plog.sh MAINTENANCE wiki-verify warn "${_wiki_verify_count:-?} violations found — see command output"
  fi
fi
'
}

# Runs the old flow (prose: re-acquire first, then Step 4; Step 4.5 runs
# only when Step 4 did not exit) and records LOG / RC.
_run_old() {
  local root="$1" rc=0
  [ -z "$root" ] || [ ! -d "$root/.git" ] || _acquire || true
  _old_step4 "$root" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || _old_step45 "$root" >/dev/null 2>&1 || true
  OLD_LOG=$(_mask <"$TAP_LOG")
  OLD_RC=$rc
  OLD_HOLDER=$(_holder)
  OLD_HEAD=$(git -C "$WIKI" log --format=%s -1 2>/dev/null || true)
}
_run_new() {
  local root="$1" rc=0
  NEW_OUT=$(bash "$WF_LIB_DIR/wiki-finalize.sh" --wiki-root "$root" --ticket "$TID" --message "$MSG" 2>&1) || rc=$?
  NEW_LOG=$(_mask <"$TAP_LOG")
  NEW_RC=$rc
  NEW_HOLDER=$(_holder)
  NEW_HEAD=$(git -C "$WIKI" log --format=%s -1 2>/dev/null || true)
}

_adr() { # <status>
  mkdir -p "$WIKI/decisions"
  cat >"$WIKI/decisions/0001-a.md" <<EOF
---
id: ADR-0001
status: $1
date: 2026-09-11
components: [foo]
ticket: T-1
deciders: [alice]
supersedes: ""
superseded_by: ""
---

# ADR-0001: Do the thing

## Context
Context text.

## Decision
We will do the thing.

## Considered Options
The alternative.

## Consequences
Some consequence.

## Affected Components
foo
EOF
}

# Builds case <c> in the current workspace; echoes the --wiki-root to use.
_case() {
  case "$1" in
  committed)
    _acquire
    printf 'a fixed\n' >"$WIKI/flows/a.md"
    echo "$WIKI"
    ;;
  nothing)
    _acquire
    echo "$WIKI"
    ;;
  adr_modified)
    _adr accepted
    git -C "$WIKI" add -A && git -C "$WIKI" commit -q -m adr
    _acquire
    sed -i 's/We will do the thing\./We will do another thing./' "$WIKI/decisions/0001-a.md"
    echo "$WIKI"
    ;;
  adr_violation)
    _acquire
    _adr proposed
    sed -i 's/We will do the thing\./We should maybe do it./' "$WIKI/decisions/0001-a.md"
    echo "$WIKI"
    ;;
  empty_root) echo "" ;;
  not_git)
    mkdir -p "$WS/plain"
    echo "$WS/plain"
    ;;
  esac
}

echo "=== wiki-finalize: parity with Steps 4 + 4.5 ==="
for c in committed nothing adr_modified adr_violation empty_root not_git; do
  _ws_new
  root=$(_case "$c")
  _run_old "$root"
  _ws_rm
  _ws_new
  root=$(_case "$c")
  _run_new "$root"
  _same "$c: log lines" "$OLD_LOG" "$NEW_LOG"
  [ -z "${WF_DEBUG:-}" ] || echo "$NEW_LOG"
  _same "$c: exit code" "$OLD_RC" "$NEW_RC"
  _same "$c: lock released" "$OLD_HOLDER" "$NEW_HOLDER"
  _same "$c: wiki HEAD" "$OLD_HEAD" "$NEW_HEAD"
  _ws_rm
done

echo "=== wiki-finalize: behaviour ==="
_ws_new
root=$(_case committed)
_run_new "$root"
grep -q '^WIKI_LOCK_STATUS=committed$' <<<"$NEW_OUT" && grep -q '^WIKI_LOCK_STATUS=released$' <<<"$NEW_OUT" &&
  _ok "commit and release output reach the agent" || _ko "commit and release output reach the agent: $NEW_OUT"
[ "$NEW_HEAD" = "$MSG" ] && _ok "commit carries the message" || _ko "commit message: $NEW_HEAD"
_ws_rm

# Lock re-acquire fails (another ticket broke ours as stale and holds it):
# the commit is skipped, logged, and the other ticket's lock is untouched.
_ws_new
_acquire
printf 'a fixed\n' >"$WIKI/flows/a.md"
echo "T-2 $(date +%s)" >"$WIKI/.git/wiki-maintenance.lock.d/owner"
_run_new "$WIKI"
grep -q '|MAINTENANCE|wiki-commit|skip|WIKI_ROOT lock not re-acquired (rc 3) — commit skipped$' "$TAP_LOG" &&
  _ok "re-acquire failure logs a skip" || _ko "re-acquire failure logs a skip: $(cat "$TAP_LOG")"
[ "$NEW_HOLDER" = "T-2" ] && [ "$NEW_HEAD" = init ] && [ "$NEW_RC" = 0 ] &&
  _ok "other ticket's lock kept, nothing committed" || _ko "holder=$NEW_HOLDER head=$NEW_HEAD rc=$NEW_RC"
_ws_rm

# --log-file wins over TAP_LOG.
_ws_new
root=$(_case empty_root)
bash "$WF_LIB_DIR/wiki-finalize.sh" --wiki-root "" --ticket "$TID" --message "$MSG" --log-file "$WS/other.log" 2>/dev/null
grep -q '|MAINTENANCE|wiki-commit|skip|' "$WS/other.log" && [ ! -s "$TAP_LOG" ] &&
  _ok "--log-file is honoured" || _ko "--log-file is honoured"
_ws_rm

rc=0
bash "$WF_LIB_DIR/wiki-finalize.sh" --ticket T-1 --message m >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && _ok "usage: missing --wiki-root exits 2" || _ko "usage exit $rc"

# Killed mid-run (adr-check hangs; the Bash tool's timeout kills the process
# group): the EXIT trap releases the lock.
_ws_new copy
_acquire
printf 'a fixed\n' >"$WIKI/flows/a.md"
printf '#!/usr/bin/env bash\nsleep 30\n' >"$LIB/adr-check.sh"
setsid bash "$LIB/wiki-finalize.sh" --wiki-root "$WIKI" --ticket "$TID" --message "$MSG" >/dev/null 2>&1 &
_pid=$!
for _ in $(seq 1 50); do
  pgrep -f "sleep 30" -s "$_pid" >/dev/null 2>&1 && break
  sleep 0.1
done
[ "$(_holder)" = "$TID" ] && _ok "lock held while the run is in flight" || _ko "lock not held mid-run"
kill -TERM -- "-$_pid" 2>/dev/null || true
wait "$_pid" 2>/dev/null || true
[ -z "$(_holder)" ] && _ok "killed run releases the lock" || _ko "killed run left the lock with $(_holder)"
_ws_rm

echo "=== ai-context-find ==="
_ws_new
mkdir -p "$WS/t/tickets/A-1--x" "$WS/t/tickets/A-2--y" "$WS/t/other"
: >"$WS/t/tickets/A-1--x/ai-context.md"
: >"$WS/t/tickets/A-2--y/ai-context.md"
: >"$WS/t/other/ai-context.md"
touch -d '200 days ago' "$WS/t/tickets/A-2--y/ai-context.md"
# Old fence (main @ 267c17f), run from the same root.
old=$(cd "$WS/t" && bash -c '_cutoff=$(date -u -d '"'"'90 days ago'"'"' +%Y-%m-%d 2>/dev/null || date -u -v-90d +%Y-%m-%d)
find . -path "*/tickets/*/ai-context.md" -newermt "$_cutoff"' | sort)
new=$(cd "$WS/t" && bash "$WF_LIB_DIR/ai-context-find.sh" | sort)
_same "find: same files as the old fence" "$old" "$new"
[ "$new" = "./tickets/A-1--x/ai-context.md" ] && _ok "find: only recent ticket files" || _ko "find: $new"
new=$(bash "$WF_LIB_DIR/ai-context-find.sh" --root "$WS/t" --days 365 | sort | sed "s|$WS|\$WS|g" | tr '\n' ' ')
[ "$new" = "\$WS/t/tickets/A-1--x/ai-context.md \$WS/t/tickets/A-2--y/ai-context.md " ] &&
  _ok "find: --root and --days" || _ko "find: --root/--days gave $new"
rc=0
bash "$WF_LIB_DIR/ai-context-find.sh" --root "$WS/missing" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] && _ok "find: a find error exits 1, never an empty success" || _ko "find error exit $rc"
rc=0
bash "$WF_LIB_DIR/ai-context-find.sh" --days x >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && _ok "find: bad --days exits 2" || _ko "find: bad --days exit $rc"
_ws_rm

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
