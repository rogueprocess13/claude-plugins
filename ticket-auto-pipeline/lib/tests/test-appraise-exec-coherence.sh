#!/usr/bin/env bash
# test-appraise-exec-coherence.sh — unit tests for lib/appraise-exec-coherence.sh
# (ticket-appraise-exec Step 3.4, skill-deterministic-extraction 5).
#
# fixtures/appraise-exec-coherence/<case>.log were produced by running the
# pre-extraction Step 3.4 fences of ticket-appraise-exec SKILL.md (main @
# 20b4113: the get_complexity line, the artifact-presence block, then either
# the gate-stop line or the commit block, as the prose's coherence rules
# choose) over the workspaces built below — never by the script. Timestamps
# are masked to TS and the workspace path to $WS. In the gate-stop line the
# prose's {artifact-found} placeholder is filled with what the block found:
# simple-fix, ambiguous (several change dirs), openspec, else none.
#
# Usage: bash test-appraise-exec-coherence.sh
# With AEC_TEST_LIB_ONLY=1 the file only defines its helpers.
set -eo pipefail

AEC_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEC_LIB_DIR="$(cd "$AEC_TEST_DIR/.." && pwd)"
AEC="$AEC_LIB_DIR/appraise-exec-coherence.sh"
AEC_FX="$AEC_TEST_DIR/fixtures/appraise-exec-coherence"
TID="T-5"
AEC_CASES="simple_ok simple_missing simple_openspec complex_ok complex_noop complex_no_tasks no_score ambiguous complex_not_git"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION

_ws_new() { # case
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/logs" "$WS/home/.claude/skills" "$WS/tickets/$TID--fix-it"
  mkdir -m 700 "$WS/scratch"
  ln -s "$AEC_LIB_DIR" "$WS/home/.claude/skills/lib"
  export HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch" CLAUDE_SKILLS_LIB="$AEC_LIB_DIR"
  export TAP_LOG="$WS/logs/$TID-pipeline.log" HB_LOG_FILE="$WS/logs/$TID-heartbeat.log"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  : >"$TAP_LOG"
  TD="$WS/tickets/$TID--fix-it"
  local score="" sf=0 os=0 tasks=1 git=1 two=0 pre=0
  case "$1" in
  simple_ok) score=simple sf=1 ;;
  simple_missing) score=simple ;;
  simple_openspec) score=simple os=1 ;;
  complex_ok) score=complex os=1 ;;
  complex_noop) score=complex os=1 pre=1 ;;
  complex_no_tasks) score=complex os=1 tasks=0 ;;
  no_score) sf=1 ;;
  ambiguous) score=complex os=1 two=1 ;;
  complex_not_git) score=complex os=1 git=0 ;;
  esac
  {
    echo "# Notes"
    echo
    echo "## Complexity"
    [ -z "$score" ] || echo "**Score:** $score"
    echo
    echo "## Initial Investigation"
  } >"$TD/notes.md"
  [ "$sf" = 0 ] || printf '# Simple fix\n' >"$TD/simple-fix.md"
  if [ "$os" = 1 ]; then
    mkdir -p "$WS/tickets/openspec/changes/t-5-fix-it"
    printf '# Proposal\n' >"$WS/tickets/openspec/changes/t-5-fix-it/proposal.md"
    [ "$tasks" = 0 ] || printf -- '- [ ] 1.1 do it\n' >"$WS/tickets/openspec/changes/t-5-fix-it/tasks.md"
  fi
  if [ "$two" = 1 ]; then
    mkdir -p "$WS/tickets/openspec/changes/t-5-other"
    printf -- '- [ ] 1.1\n' >"$WS/tickets/openspec/changes/t-5-other/tasks.md"
  fi
  if [ "$git" = 1 ]; then
    git -C "$WS/tickets" init -q
    printf 'openspec/\n' >"$WS/tickets/.gitignore"
    git -C "$WS/tickets" add .gitignore
    git -C "$WS/tickets" commit -q -m init
    if [ "$pre" = 1 ]; then
      git -C "$WS/tickets" add -f openspec/changes/t-5-fix-it/
      git -C "$WS/tickets" commit -q -m pre
    fi
  fi
}
_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }
_mask() { sed -e "s|$WS|\$WS|g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g'; }

[ "${AEC_TEST_LIB_ONLY:-0}" = 1 ] && return 0

PASS=0 FAIL=0
_ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
_ko() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}
_same() { # label want got
  if [ "$2" = "$3" ]; then _ok "$1"; else
    _ko "$1"
    diff <(echo "$2") <(echo "$3") | sed 's/^/    /' || true
  fi
}

echo "=== parity with the Step 3.4 fences ==="
for c in $AEC_CASES; do
  _ws_new "$c"
  rc=0
  out=$(cd "$WS/tickets" && bash "$AEC" "$TID" "$TD") || rc=$?
  _same "$c: log" "$(cat "$AEC_FX/$c.log")" "$(_mask <"$TAP_LOG")"
  case "$c" in
  simple_ok | complex_ok | complex_noop | complex_not_git) want=0 ;;
  *) want=1 ;;
  esac
  [ "$rc" = "$want" ] && _ok "$c: exit $want" || _ko "$c: exit $rc (want $want)"
  case "$c" in
  complex_ok)
    n=$(git -C "$WS/tickets" ls-files openspec/changes/t-5-fix-it | wc -l | tr -d ' ')
    [ "$n" = 2 ] && _ok "complex_ok: change dir committed" || _ko "complex_ok: $n files tracked"
    grep -q '^COMMIT_RC=0$' <<<"$out" && _ok "complex_ok: COMMIT_RC=0 printed" || _ko "complex_ok: $out"
    grep -q '|gate|artifact-persisted|ok|committed|' "$HB_LOG_FILE" && _ok "complex_ok: artifact-persisted heartbeat" || _ko "complex_ok: no persisted heartbeat"
    ;;
  complex_not_git)
    grep -q '^COMMIT_RC=2$' <<<"$out" && _ok "complex_not_git: COMMIT_RC=2" || _ko "complex_not_git: $out"
    grep -q '|gate|artifact-persisted|warn|commit-failed|' "$HB_LOG_FILE" && _ok "complex_not_git: warn heartbeat" || _ko "complex_not_git: heartbeat"
    ;;
  simple_missing)
    grep -q '^ARTIFACT=none$' <<<"$out" && _ok "simple_missing: ARTIFACT=none" || _ko "simple_missing: $out"
    grep -q '|gate|coherence-check|fail|' "$HB_LOG_FILE" && _ok "simple_missing: fail heartbeat" || _ko "simple_missing: heartbeat"
    ;;
  simple_ok)
    grep -q '|gate|coherence-check|ok|complexity-artifact match|{"declared":"simple","artifact":"simple-fix"}' "$HB_LOG_FILE" &&
      _ok "simple_ok: ok heartbeat" || _ko "simple_ok: heartbeat"
    ;;
  esac
  _ws_rm
done

echo "=== usage ==="
rc=0
bash "$AEC" "$TID" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && _ok "missing TICKET_DIR: exit 2" || _ko "missing TICKET_DIR: rc=$rc"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
