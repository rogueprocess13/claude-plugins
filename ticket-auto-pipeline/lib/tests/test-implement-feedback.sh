#!/usr/bin/env bash
# test-implement-feedback.sh — unit tests for lib/implement-feedback.sh and
# lib/implement-rate.sh (ticket-implement Step 4c, skill-deterministic-
# extraction 5).
#
# fixtures/implement-feedback/<case>.{log,notes} were produced by running the
# pre-extraction fences from main @ 20b4113 — ticket-implement SKILL.md Step
# 4c's flow-run line and write_verifier_result block, and references/
# feedback.md's two append_correction blocks (run in one shell, after the
# first block's `source`) — with their placeholders filled, over the
# workspaces _if_ws builds; never by the script. The wiki-ok line is the
# literal Part 3 prose names. Timestamps are masked to TS, the workspace to
# $WS, CORRECTIONS ids/dates to ID/DATE.
#
# Usage: bash test-implement-feedback.sh
# With IF_TEST_LIB_ONLY=1 the file only defines its helpers.
set -eo pipefail

IF_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IF_LIB_DIR="$(cd "$IF_TEST_DIR/.." && pwd)"
IFB="$IF_LIB_DIR/implement-feedback.sh"
IRATE="$IF_LIB_DIR/implement-rate.sh"
IF_FX="$IF_TEST_DIR/fixtures/implement-feedback"
TID="T-6"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION

_if_ws() { # flow-rc
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/logs" "$WS/home/.claude/skills" "$WS/td" "$WS/bin"
  mkdir -m 700 "$WS/scratch"
  ln -s "$IF_LIB_DIR" "$WS/home/.claude/skills/lib"
  export HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch" CLAUDE_SKILLS_LIB="$IF_LIB_DIR"
  LOGF="$WS/logs/$TID-pipeline.log"
  : >"$LOGF"
  printf '#!/usr/bin/env bash\n[ "%s" = 0 ] || { echo "boom" >&2; exit %s; }\nexit 0\n' "${1:-0}" "${1:-0}" >"$WS/bin/flow.sh"
  chmod +x "$WS/bin/flow.sh"
  export FLOW_RUN_FLOW_SH="$WS/bin/flow.sh"
  printf '# Notes\n\n## Complexity\n**Score:** simple\n\n## Initial Investigation\n- **Wiki bootstrap:** flows/x.md (routed: topic-match)\n' >"$WS/td/notes.md"
}
_if_rm() { [ -n "${WS:-}" ] && {
  chmod -R u+w "$WS" 2>/dev/null || true
  rm -rf "$WS"
} || true; }
_if_mask() {
  sed -e "s|$WS|\$WS|g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g' \
    -e 's/"ts":"[^"]*"/"ts":"TS"/g' -e 's/^\(\*\*[Ii][Dd]:\*\*\).*/\1 ID/' \
    -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]/DATE/g'
}

[ "${IF_TEST_LIB_ONLY:-0}" = 1 ] && return 0

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

echo "=== record: parity with the Step 4c fences ==="
for c in record_ok record_flow_fail; do
  frc=0
  [ "$c" = record_flow_fail ] && frc=1
  _if_ws "$frc"
  rc=0
  out=$(bash "$IFB" record "$TID" --ticket-dir "$WS/td" --outcome Rough --verdict PASS --corrections 1 --log-file "$LOGF" 2>/dev/null) || rc=$?
  _same "$c: log" "$(cat "$IF_FX/$c.log")" "$(_if_mask <"$LOGF")"
  _same "$c: exit 0 + decisions" "0|PREDICTED=simple MISMATCH=true WIKI_CONSULTED=true" "$rc|$(echo $out)"
  _if_rm
done

echo "=== record: mismatch rule ==="
for row in "simple Smooth false" "simple Rough true" "simple Hard true" "complex Smooth true" "complex Rough false" "complex Hard false" "none Hard false"; do
  set -- $row
  _if_ws 0
  if [ "$1" = none ]; then printf '# Notes\n' >"$WS/td/notes.md"; else sed -i "s/simple/$1/" "$WS/td/notes.md"; fi
  out=$(bash "$IFB" record "$TID" --ticket-dir "$WS/td" --outcome "$2" --verdict PASS --log-file "$LOGF" 2>/dev/null)
  grep -q "^MISMATCH=$3$" <<<"$out" && _ok "$1/$2 → MISMATCH=$3" || _ko "$1/$2: $out"
  [ "$1" != none ] || { grep -q '^WIKI_CONSULTED=false$' <<<"$out" && _ok "no Wiki bootstrap line → WIKI_CONSULTED=false" || _ko "wiki: $out"; }
  _if_rm
done

echo "=== correction: parity with references/feedback.md ==="
for c in correction_both correction_fail; do
  _if_ws 0
  [ "$c" = correction_fail ] && chmod a-w "$WS/td"
  rc=0
  (
    export TAP_LOG="$LOGF"
    bash "$IFB" correction --ticket-dir "$WS/td" --source appraise \
      --fact "Predicted simple but actual outcome was Rough" --detail "The export path was undocumented"
    bash "$IFB" correction --ticket-dir "$WS/td" --source wiki \
      --fact "Wiki flow file flows/x.md missing or stale for the export step" --detail "Wiki gap found: no export step"
  ) 2>/dev/null || rc=$?
  _same "$c: notes" "$(cat "$IF_FX/$c.notes")" "$(_if_mask <"$WS/td/notes.md")"
  _same "$c: log" "$(cat "$IF_FX/$c.log")" "$(_if_mask <"$LOGF")"
  [ "$rc" = 0 ] && _ok "$c: exit 0" || _ko "$c: rc=$rc"
  _if_rm
done

echo "=== wiki-ok ==="
_if_ws 0
bash "$IFB" wiki-ok --log-file "$LOGF"
_same "wiki-ok line" "TS|META|wiki-check|info|wiki consulted, no gap found" "$(_if_mask <"$LOGF")"
rc=0
(
  set -e
  unset LOG_FILE TAP_LOG
  bash "$IFB" wiki-ok 2>/dev/null
) || rc=$?
[ "$rc" = 0 ] && _ok "wiki-ok with no log: exit 0 under set -e" || _ko "wiki-ok no log rc=$rc"
_if_rm

echo "=== usage ==="
for args in "" "record $TID --outcome Meh --verdict PASS --ticket-dir /x" "correction --ticket-dir /x --source prescan --fact a --detail b" "wiki-ok extra"; do
  rc=0
  bash "$IFB" $args >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && _ok "usage: '$args' → 2" || _ko "usage: '$args' rc=$rc"
done

echo "=== implement-rate ==="
for row in "0 0 followed Smooth" "1 0 followed Rough" "2 0 followed Rough" "3 0 followed Hard" \
  "0 1 followed Rough" "0 3 followed Hard" "0 0 adapted Rough" "0 0 rewrote Hard" "1 3 adapted Hard"; do
  set -- $row
  out=$(bash "$IRATE" --fix-cycles "$1" --discovery-rounds "$2" --plan-deviation "$3")
  _same "rate $1/$2/$3" "OUTCOME=$4" "$out"
done
SUMF=$(mktemp)
printf '{"fix_cycles":1,"discovery_rounds":0,"plan_deviation":"followed","changes_made":[],"notes":""}' >"$SUMF"
_same "rate --summary" "OUTCOME=Rough" "$(bash "$IRATE" --summary "$SUMF")"
printf '{"fix_cycles":"x"}' >"$SUMF"
rc=0
bash "$IRATE" --summary "$SUMF" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && _ok "rate: unreadable summary → 2" || _ko "rate: rc=$rc"
rm -f "$SUMF"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
