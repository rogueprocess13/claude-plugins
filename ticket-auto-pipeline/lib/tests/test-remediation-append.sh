#!/usr/bin/env bash
# test-remediation-append.sh — unit tests for lib/remediation-append.sh
# (ticket-verify Step 7c5, skill-deterministic-extraction 4).
#
# fixtures/remediation-append/<case>.plan and <case>.log were produced by
# running the pre-extraction Step 7c5 bash block of ticket-verify SKILL.md
# (main @ eacacbf), with its heredoc filled from fixtures/remediation-append/
# body.md, over the workspaces built below — never by the script. Timestamps
# are masked to TS and the workspace path to $WS.
#
# Usage: bash test-remediation-append.sh
# With REMEDIATION_APPEND_TEST_LIB_ONLY=1 the file only defines its helpers.
set -eo pipefail

RA_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RA_LIB_DIR="$(cd "$RA_TEST_DIR/.." && pwd)"
RA="$RA_LIB_DIR/remediation-append.sh"
RA_FX="$RA_TEST_DIR/fixtures/remediation-append"
TID="T-3"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION

_ws_new() {
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/logs" "$WS/home" "$WS/tickets/$TID--fix-it" "$WS/bin"
  mkdir -m 700 "$WS/scratch"
  export HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch" CLAUDE_SKILLS_LIB="$RA_LIB_DIR"
  export TAP_LOG="$WS/logs/$TID-pipeline.log"
  : >"$TAP_LOG"
  PLAN="$WS/tickets/$TID--fix-it/simple-fix.md"
  printf '# Simple fix\n\n## Completion Checklist\n- [x] change\n' >"$PLAN"
}
_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }
_mask() { sed -e "s|$WS|\$WS|g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g'; }

_case_first() { :; }
_case_second() { printf '\n## Verification #1\n\nolder brief\n\n<!-- /REMEDIATION_BRIEF -->\n' >>"$PLAN"; }
_case_mv_fails() {
  printf '#!/bin/sh\nexit 1\n' >"$WS/bin/mv"
  chmod +x "$WS/bin/mv"
  export PATH="$WS/bin:$PATH"
}

[ "${REMEDIATION_APPEND_TEST_LIB_ONLY:-0}" = 1 ] && return 0

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

echo "=== parity with the Step 7c5 block ==="
for c in first second mv_fails; do
  _ws_new
  _OLDPATH=$PATH
  "_case_$c"
  rc=0
  out=$(bash "$RA" "$TID" --section "$RA_FX/body.md" --root "$WS/tickets") || rc=$?
  PATH=$_OLDPATH
  _same "$c: plan" "$(cat "$RA_FX/$c.plan")" "$(_mask <"$PLAN")"
  _same "$c: log" "$(cat "$RA_FX/$c.log")" "$(_mask <"$TAP_LOG")"
  case "$c" in
  first) _same "first: exit 0 + PLAN/N" "0|PLAN=$PLAN N=1" "$rc|$(echo $out)" ;;
  second) _same "second: N counts existing sections" "0|PLAN=$PLAN N=2" "$rc|$(echo $out)" ;;
  mv_fails)
    [ "$rc" = 1 ] && _ok "mv_fails: exit 1" || _ko "mv_fails: rc=$rc"
    [ ! -e "$PLAN.tmp" ] && _ok "mv_fails: temp file removed" || _ko "mv_fails: temp file left"
    ;;
  esac
  _ws_rm
done

echo "=== verbatim body ==="
_ws_new
before=$(cat "$PLAN")
bash "$RA" "$TID" --section "$RA_FX/body.md" --root "$WS/tickets" >/dev/null
want="$before"$'\n\n## Verification #1\n\n'"$(cat "$RA_FX/body.md")"$'\n\n<!-- /REMEDIATION_BRIEF -->'
_same "the section file is appended byte for byte" "$want" "$(cat "$PLAN")"
cmp -s <(tail -c 29 "$PLAN") <(printf '\n<!-- /REMEDIATION_BRIEF -->\n') && _ok "plan ends with the closing marker line" || _ko "closing marker"
_ws_rm

_ws_new
printf 'no final newline' >"$WS/nonl.md"
bash "$RA" "$TID" --section "$WS/nonl.md" --root "$WS/tickets" >/dev/null
tail -3 "$PLAN" | {
  read -r a
  read -r b
  read -r c
  [ "$a" = "no final newline" ] && [ -z "$b" ] && [ "$c" = "<!-- /REMEDIATION_BRIEF -->" ]
} && _ok "a section without a final newline still gets a blank line before the marker" || _ko "no-final-newline layout"
_ws_rm

echo "=== no plan / usage ==="
_ws_new
rm -f "$PLAN"
rc=0
out=$(bash "$RA" "$TID" --section "$RA_FX/body.md" --root "$WS/tickets") || rc=$?
[ "$rc" = 3 ] && grep -q 'No plan artifact found for REMEDIATION_BRIEF' <<<"$out" && [ ! -s "$TAP_LOG" ] &&
  _ok "no plan -> exit 3, report line, nothing logged" || _ko "no plan: rc=$rc out=$out"
rc=0
bash "$RA" "$TID" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && _ok "missing --section -> exit 2" || _ko "missing --section rc=$rc"
rc=0
bash "$RA" "$TID" --section "$WS/absent.md" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && _ok "missing section file -> exit 2" || _ko "absent section rc=$rc"
_ws_rm

echo ""
echo "remediation-append: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
