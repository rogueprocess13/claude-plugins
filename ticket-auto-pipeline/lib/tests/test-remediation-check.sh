#!/usr/bin/env bash
# test-remediation-check.sh — unit tests for lib/remediation-check.sh
# (ticket-implement Step 2.5 + references/rework.md integrity check,
# skill-deterministic-extraction 5).
#
# The integrity and REWORK_OPEN parity oracle is the pre-extraction bash
# itself, run from main @ 20b4113 in this test (_old_integrity /
# _old_rework_open are those fences verbatim, placeholders filled), never the
# script. FAIL_COUNT/SECTION_COUNT were prose counts: their expectations are
# the prose's own definition (notes.md `### {date} — Verification FAIL`
# entries vs the plan's `## Verification #` sections).
#
# Usage: bash test-remediation-check.sh
set -eo pipefail

RCK_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RCK_LIB_DIR="$(cd "$RCK_TEST_DIR/.." && pwd)"
RCK="$RCK_LIB_DIR/remediation-check.sh"
TID="T-7"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION

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

_ws_new() {
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/logs" "$WS/home/.claude/skills" "$WS/tickets/$TID--fix-it"
  mkdir -m 700 "$WS/scratch"
  ln -s "$RCK_LIB_DIR" "$WS/home/.claude/skills/lib"
  export HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch" TAP_LOG="$WS/logs/$TID-pipeline.log"
  : >"$TAP_LOG"
  TD="$WS/tickets/$TID--fix-it"
  PLAN="$TD/simple-fix.md"
  printf '# Simple fix\n\n## Completion Checklist\n- [x] a\n' >"$PLAN"
  printf '# Notes\n\n## Session Log\n' >"$TD/notes.md"
}
_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }
_mask() { sed -e "s|$WS|\$WS|g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g'; }

# references/rework.md integrity fences, main @ 20b4113 (PLAN set).
_old_integrity() (
  set +eo pipefail # an agent shell runs the fence without errexit
  LAST_SECTION_LINE=$(grep -n '^## Verification #' "$PLAN" | tail -1 | cut -d: -f1)
  SECTION_TAIL=$(awk "NR>$LAST_SECTION_LINE && /^## / {exit} NF" "$PLAN" 2>/dev/null | tail -1)
  if [ "$SECTION_TAIL" != "<!-- /REMEDIATION_BRIEF -->" ]; then
    bash ~/.claude/skills/lib/plog.sh META gate-stop fail "REMEDIATION_BRIEF_TRUNCATED — marker missing in: $PLAN"
  fi
)
# SKILL.md "Reference files (load condition)" awk, main @ 20b4113.
_old_rework_open() {
  awk '/^### .* — verification re-run #/{r=NR} /^### .* — committed/{c=NR} END{print (r>c)?"REWORK_OPEN=true":"REWORK_OPEN=false"}' "$TD/notes.md"
}

_sec_intact() { printf '\n## Verification #1\n\nbrief\n\n<!-- /REMEDIATION_BRIEF -->\n' >>"$PLAN"; }
_sec_cut() { printf '\n## Verification #1\n\nbrief that stops mid\n' >>"$PLAN"; }

echo "=== integrity: parity with references/rework.md ==="
for c in intact truncated intact_then_heading cut_after_intact none; do
  _ws_new
  case "$c" in
  intact) _sec_intact ;;
  truncated) _sec_cut ;;
  intact_then_heading)
    _sec_intact
    printf '\n## PR Review #1\n\nstuff\n' >>"$PLAN"
    ;;
  cut_after_intact)
    _sec_intact
    _sec_cut
    ;;
  none) ;;
  esac
  _old_integrity
  want=$(_mask <"$TAP_LOG")
  : >"$TAP_LOG"
  rc=0
  bash "$RCK" integrity "$TID" --plan "$PLAN" >/dev/null || rc=$?
  _same "$c: log" "$want" "$(_mask <"$TAP_LOG")"
  if [ -z "$want" ]; then wrc=0; else wrc=1; fi
  [ "$rc" = "$wrc" ] && _ok "$c: exit $wrc" || _ko "$c: rc=$rc want $wrc"
  _ws_rm
done

echo "=== status ==="
# label | FAIL entries | sections | notes tail | want FAIL SECTION REWORK REWORK_OPEN
_status_case() {
  _ws_new
  local i
  for i in $(seq 1 "$2"); do printf '\n### 2026-11-0%s — Verification FAIL (local)\n- x\n' "$i" >>"$TD/notes.md"; done
  for i in $(seq 1 "$3"); do printf '\n## Verification #%s\n\nb\n\n<!-- /REMEDIATION_BRIEF -->\n' "$i" >>"$PLAN"; done
  case "$4" in
  rerun) printf '\n### 2026-11-09 — verification re-run #2\n- y\n' >>"$TD/notes.md" ;;
  rerun-committed) printf '\n### 2026-11-09 — verification re-run #2\n\n### 2026-11-09 — committed\n' >>"$TD/notes.md" ;;
  esac
  local old out
  old=$(_old_rework_open)
  out=$(cd "$WS/tickets" && bash "$RCK" status "$TID" --ticket-dir "$TD" --root .)
  _same "$1" "PLAN=$PLAN FAIL_COUNT=$2 SECTION_COUNT=$3 REWORK=$5 $old" "$(echo $out)"
  _ws_rm
}
_status_case "first attempt" 0 0 - false
_status_case "verify wrote its section" 1 1 - false
_status_case "verify FAIL without a plan section" 1 0 - true
_status_case "rework open on resume" 2 1 rerun true
_status_case "rework committed" 2 2 rerun-committed false

_ws_new
rm "$PLAN"
out=$(cd "$WS/tickets" && bash "$RCK" status "$TID" --ticket-dir "$TD")
grep -q "^PLAN=''$" <<<"$out" && grep -q '^SECTION_COUNT=0$' <<<"$out" && _ok "no plan: PLAN empty, 0 sections" || _ko "no plan: $out"
_ws_rm

echo "=== usage ==="
for args in "" "status" "status $TID" "integrity $TID" "bogus $TID"; do
  rc=0
  bash "$RCK" $args >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && _ok "usage: '$args' → 2" || _ko "usage: '$args' rc=$rc"
done

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
