#!/usr/bin/env bash
# test-gate-reconcile.sh — lib/gate-reconcile-prep.sh and
# lib/gate-reconcile-finish.sh (ticket-gate-reconcile Steps 1-4 and 7-8,
# skill-deterministic-extraction 6a).
#
# Parity oracle: the pre-extraction fences (main @ 267c17f) embedded below,
# placeholders filled, run in an identical workspace. The old fences never
# shared shell state with each other, so the oracle runs them in one shell
# (what the prose meant). Their bare `hb-wrap.sh` / `hb_init` calls resolved
# to nothing in a real agent shell (not on PATH, heartbeat.sh not sourced);
# the oracle puts lib/ on PATH and sources heartbeat.sh so the heartbeats
# the prose asked for are what the scripts are compared with. Comments come
# from a file on both sides (the old LINEAR_API_KEY / MCP fetch is network).
#
# Usage: bash test-gate-reconcile.sh
set -eo pipefail

GR_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GR_LIB_DIR="$(cd "$GR_TEST_DIR/.." && pwd)"
TID="T-3"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION LINEAR_API_KEY COMPLEXITY

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

COMMENTS='[{"id":"a","body":"Plan\n<!-- ticket-auto:appraisal -->","createdAt":"2026-11-01T10:00:00Z","user":{"name":"bot"}},{"id":"b","body":"Use the v2 API","createdAt":"2026-11-02T10:00:00Z","user":{"name":"alice"}}]'

# $WS = tickets repo root. $1 = simple|openspec|missing-openspec.
_ws_new() {
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/home/.claude/skills" "$WS/logs" "$WS/$TID--fix/artifacts" "$WS/bin"
  mkdir -m 700 "$WS/scratch"
  ln -s "$GR_LIB_DIR" "$WS/home/.claude/skills/lib"
  export HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch"
  printf '#!/usr/bin/env bash\necho "flow.sh $*" >>"%s/flow-calls"\n' "$WS" >"$WS/bin/flow.sh"
  chmod +x "$WS/bin/flow.sh"
  export FLOW_RUN_FLOW_SH="$WS/bin/flow.sh"
  cat >"$WS/$TID--fix/notes.md" <<'EOF'
# Notes

## Complexity
**Score:** simple

## Open Questions
- [needs-human] Which API version?
- ~~[needs-human] Old one~~
- [agent-resolvable] path?

## Session Log
EOF
  echo "2026-11-01T09:00:00Z|APPRAISE|appraise|done|ok" >"$WS/logs/$TID-pipeline.log"
  case "${1:-simple}" in
  simple)
    echo "2026-11-01T09:01:00Z|EXEC|create-artifact|done|simple-fix" >>"$WS/logs/$TID-pipeline.log"
    touch "$WS/$TID--fix/simple-fix.md"
    ;;
  openspec)
    echo "2026-11-01T09:01:00Z|EXEC|create-artifact|done|openspec" >>"$WS/logs/$TID-pipeline.log"
    mkdir -p "$WS/openspec/changes/t-3-fix"
    echo "- [ ] task" >"$WS/openspec/changes/t-3-fix/tasks.md"
    ;;
  missing-openspec)
    echo "2026-11-01T09:01:00Z|EXEC|create-artifact|done|openspec" >>"$WS/logs/$TID-pipeline.log"
    mkdir -p "$WS/openspec/changes/t-33-other"
    echo "- [ ] other" >"$WS/openspec/changes/t-33-other/tasks.md"
    ;;
  esac
  echo "2026-10-30T00:00:00Z|GATE|reconcile|done|cycle#1 held: x" >>"$WS/logs/$TID-pipeline.log"
  echo "2026-10-30T00:00:01Z|GATE|reconcile|done|cycle#1 router echo" >>"$WS/logs/$TID-pipeline.log"
  printf '%s\n' "$COMMENTS" >"$WS/comments.json"
  printf 'desc\n## Acceptance Criteria\n1. works\n' >"$WS/$TID--fix/artifacts/tracker-description.md"
}
_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }
# The scripts warn once on stderr when no log-dir anchor exists
# (state-root-anchor legacy mode); the pre-extraction oracle never did.
_mask() { sed -e '/^log dir not anchored; using .* (legacy)$/d' -e "s|$WS|\$WS|g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g'; }
_logs() {
  _mask <"$WS/logs/$TID-pipeline.log"
  echo "--- hb"
  { _mask <"$WS/logs/$TID-heartbeat.log"; } 2>/dev/null || true
}
_reset_logs() { cp "$WS/logs/$TID-pipeline.log" "$WS/base.log"; }
_restore_logs() {
  cp "$WS/base.log" "$WS/logs/$TID-pipeline.log"
  rm -f "$WS/logs/$TID-heartbeat.log" "$WS/flow-calls"
}

# Steps 1-4 fences, main @ 267c17f ({TICKET-ID}=T-3), one shell. The comment
# fetch reads $WS/comments.json; Step 3 prints its reconcile output.
_old_prep() {
  (cd "$WS" && PATH="$GR_LIB_DIR:$PATH" bash -c '
set +eo pipefail
source ~/.claude/skills/lib/ticket-env.sh T-3
export TAP_LOG="$PWD/logs/T-3-pipeline.log"
export HB_LOG_FILE="$PWD/logs/T-3-heartbeat.log"
source ~/.claude/skills/lib/linear-api.sh
source ~/.claude/skills/lib/ticket-dir.sh
source ~/.claude/skills/lib/notes-parse.sh
set +eo pipefail
TICKET_DIR=$(resolve_ticket_dir "T-3" "." 2>/dev/null || echo ".")
NOTES_PATH="$TICKET_DIR/notes.md"
if [ -f "$NOTES_PATH" ]; then
  COMPLEXITY=$(get_complexity "$TICKET_DIR" 2>/dev/null || echo "$COMPLEXITY")
fi
ARTIFACT_TYPE=$(resolve_artifact_type "$TAP_LOG" "$NOTES_PATH")
ARTIFACT_TYPE="${ARTIFACT_TYPE:-simple-fix}"
PLAN_PATH=""
_plan_rc=0
_plan_out=$(resolve_plan_artifact "T-3" --root . --ticket-dir "$TICKET_DIR" --type "$ARTIFACT_TYPE") || _plan_rc=$?
[ "$_plan_rc" -eq 0 ] && eval "$_plan_out"
if [ "$ARTIFACT_TYPE" = "openspec" ]; then
  ARTIFACT_PATH="$PLAN_PATH"
  if [ "$_plan_rc" -ne 0 ] || [ ! -f "$ARTIFACT_PATH" ]; then
    bash ~/.claude/skills/lib/plog.sh GATE reconcile fail "openspec tasks.md for T-3 not found under $PWD/openspec/changes/ (resolver rc=$_plan_rc)"
    echo "ticket-gate-reconcile: no unique openspec change for T-3 under $PWD/openspec/changes/ — cannot amend the plan" >&2
    exit 1
  fi
else
  ARTIFACT_PATH="${PLAN_PATH:-$TICKET_DIR/simple-fix.md}"
fi
source ~/.claude/skills/lib/heartbeat.sh
set +eo pipefail
hb_init
hb-wrap.sh gate "reconcile" "info" "gate-reconcile agent starting" "{\"complexity\":\"$COMPLEXITY\"}"
RECONCILE_N=$(grep -o "^[^|]*|GATE|reconcile|done|cycle#[0-9]*" "$TAP_LOG" 2>/dev/null |
  sed "s/.*cycle#//" | sort -u | wc -l | tr -d " " || true)
RECONCILE_N=${RECONCILE_N:-0}
RECONCILE_N=$((RECONCILE_N + 1))
COMMENTS_JSON=$(cat comments.json)
COMMENTS_JSON=$(echo "$COMMENTS_JSON" | bash -c "source ~/.claude/skills/lib/linear-api.sh; normalize_comments")
RECONCILE_OUTPUT=$(echo "$COMMENTS_JSON" | bash ~/.claude/skills/lib/reconcile-comments.sh "T-3" "$TAP_LOG")
RAW_SECTION=$(sed -n "/^## Open Questions/,/^## /p" "$NOTES_PATH")
if echo "$RAW_SECTION" | grep "^## " >/dev/null; then
  RAW_SECTION=$(echo "$RAW_SECTION" | sed "/^## Open Questions$/!{/^## /q}")
fi
OPEN_QUESTIONS_LIST=$(echo "$RAW_SECTION" | grep "^\- \[needs-human\]" || true)
echo "TICKET_DIR=$TICKET_DIR"
echo "NOTES_PATH=$NOTES_PATH"
echo "ARTIFACT_TYPE=$ARTIFACT_TYPE"
echo "ARTIFACT_PATH=$ARTIFACT_PATH"
echo "COMPLEXITY=$COMPLEXITY"
echo "RECONCILE_N=$RECONCILE_N"
echo "TAP_LOG=$TAP_LOG"
echo "=== RECONCILE_OUTPUT ==="
echo "$RECONCILE_OUTPUT"
echo "=== OPEN_QUESTIONS ==="
echo "$OPEN_QUESTIONS_LIST"
')
}
_new_prep() { (cd "$WS" && bash "$GR_LIB_DIR/gate-reconcile-prep.sh" "$TID" --comments-file comments.json "$@"); }

echo "=== prep: parity with Steps 1-4 ==="
for c in simple openspec missing-openspec; do
  _ws_new "$c"
  _reset_logs
  orc=0
  old=$(_old_prep 2>/dev/null) || orc=$?
  OLD_LOGS=$(_logs)
  _restore_logs
  nrc=0
  new=$(_new_prep 2>/dev/null) || nrc=$?
  NEW_LOGS=$(_logs)
  _same "$c: exit code" "$orc" "$nrc"
  _same "$c: printed values" "$(_mask <<<"$old" | sed '/^$/d')" "$(_mask <<<"$new" | sed '/^$/d')"
  _same "$c: pipeline + heartbeat logs" "$OLD_LOGS" "$NEW_LOGS"
  _ws_rm
done

_ws_new simple
out=$(_new_prep)
grep -qx 'RECONCILE_N=2' <<<"$out" && _ok "prep: cycle counts distinct numbers" || _ko "prep: cycle: $out"
grep -qx -- '- \[needs-human\] Which API version?' <<<"$out" && ! grep -q 'Old one\|agent-resolvable' <<<"$out" &&
  _ok "prep: only unstruck needs-human questions" || _ko "prep: questions: $out"
grep -q '^- 2026-11-02T10:00:00Z|alice|Use the v2 API\|alice' <<<"$out" && _ok "prep: unprocessed comment listed" || _ko "prep: comments: $out"
head -1 "$WS/logs/$TID-heartbeat.log" | grep -q '|META|schema|info|' && _ok "prep: heartbeat log initialised" || _ko "prep: hb_init"
rc=0
(cd "$WS" && bash "$GR_LIB_DIR/gate-reconcile-prep.sh" "$TID" >/dev/null 2>&1) || rc=$?
_same "prep: no key and no --comments-file exits 4" 4 "$rc"
rc=0
bash "$GR_LIB_DIR/gate-reconcile-prep.sh" >/dev/null 2>&1 || rc=$?
_same "prep: usage exits 2" 2 "$rc"
_ws_rm

# state-root-anchor: with a log-dir anchor, prep and finish read and write the
# anchored dir, not ./logs under the tickets repo root.
_ws_new simple
mkdir -p "$WS/root/.ticket-auto" "$WS/state"
mv "$WS/logs/$TID-pipeline.log" "$WS/state/"
printf '%s\n' "$WS/state" >"$WS/root/.ticket-auto/log-dir"
out=$(cd "$WS" && REPOS_ROOT="$WS/root" bash "$GR_LIB_DIR/gate-reconcile-prep.sh" "$TID" --comments-file comments.json 2>/dev/null) || true
grep -qx "TAP_LOG=$WS/state/$TID-pipeline.log" <<<"$out" && grep -qx 'RECONCILE_N=2' <<<"$out" &&
  [ -s "$WS/state/$TID-heartbeat.log" ] && [ ! -e "$WS/logs/$TID-heartbeat.log" ] &&
  _ok "prep: anchored log dir wins over ./logs" || _ko "prep: anchored: $out"
(cd "$WS" && REPOS_ROOT="$WS/root" bash "$GR_LIB_DIR/gate-reconcile-finish.sh" "$TID" hold --reason open_questions >/dev/null 2>&1) || true
grep -q '|GATE|reconcile|done|cycle#2 held: open_questions' "$WS/state/$TID-pipeline.log" &&
  [ ! -e "$WS/logs/$TID-pipeline.log" ] &&
  _ok "finish: anchored log dir wins over ./logs" || _ko "finish: anchored"
_ws_rm

echo "=== finish: parity with Steps 7-8 ==="
# Step 7 held fences and Step 8 fences, main @ 267c17f, one shell.
_old_hold() {
  (cd "$WS" && PATH="$GR_LIB_DIR:$PATH" HB_LOG_FILE="$WS/logs/T-3-heartbeat.log" TAP_LOG="$WS/logs/T-3-pipeline.log" RECONCILE_N=2 HOLD_REASON=open_questions bash -c '
bash ~/.claude/skills/lib/flow-run.sh --log-file "$PWD/logs/T-3-pipeline.log" T-3 re-claim
bash ~/.claude/skills/lib/plog.sh GATE reconcile done "cycle#${RECONCILE_N} held: ${HOLD_REASON}"
hb-wrap.sh decision "reconcile-result" "fired" "held: ${HOLD_REASON}" "{\"cycle\":\"${RECONCILE_N}\",\"reason\":\"${HOLD_REASON}\"}"
') >/dev/null 2>&1
}
_old_clean() {
  (cd "$WS" && PATH="$GR_LIB_DIR:$PATH" HB_LOG_FILE="$WS/logs/T-3-heartbeat.log" TAP_LOG="$WS/logs/T-3-pipeline.log" TICKET_DIR="./T-3--fix" RECONCILE_N=2 bash -c '
bash ~/.claude/skills/lib/ac-drift.sh "$TICKET_DIR" --description-file "$TICKET_DIR/artifacts/tracker-description.md" --refresh --tag GATE --log-file "$TAP_LOG"
bash ~/.claude/skills/lib/plog.sh GATE reconcile done "clean"
hb-wrap.sh decision "reconcile-result" "fired" "clean pass — no open questions or new input" "{\"cycle\":\"${RECONCILE_N}\"}"
hb-wrap.sh gate "reconcile" "ok" "clean pass — proceeding to implement"
hb-wrap.sh gate "phase-transition" "ok" "GATE → IMPLEMENT"
')
}
_ws_new simple
printf '# Context\n\n## Acceptance Criteria\n1. works\n' >"$WS/$TID--fix/context.md"
_reset_logs
cp "$WS/$TID--fix/context.md" "$WS/ctx.bak"
_old_hold
OLD_LOGS=$(_logs)
OLD_FLOW=$(cat "$WS/flow-calls")
_restore_logs
(cd "$WS" && bash "$GR_LIB_DIR/gate-reconcile-finish.sh" "$TID" hold --reason open_questions >/dev/null 2>&1)
_same "hold: logs" "$OLD_LOGS" "$(_logs)"
_same "hold: re-claim fired" "$OLD_FLOW" "$(cat "$WS/flow-calls")"
_restore_logs
old=$(_old_clean 2>&1 || true)
OLD_LOGS=$(_logs)
OLD_CTX=$(cat "$WS/$TID--fix/context.md")
_restore_logs
cp "$WS/ctx.bak" "$WS/$TID--fix/context.md"
new=$(cd "$WS" && bash "$GR_LIB_DIR/gate-reconcile-finish.sh" "$TID" clean 2>&1)
_same "clean: logs" "$OLD_LOGS" "$(_logs)"
_same "clean: ac-drift output shown" "$(_mask <<<"$old")" "$(_mask <<<"$new")"
_same "clean: context.md refresh" "$OLD_CTX" "$(cat "$WS/$TID--fix/context.md")"

out=$(cd "$WS" && bash "$GR_LIB_DIR/gate-reconcile-finish.sh" "$TID" decide --comments 1 --new-input 0)
want=$(cd "$WS" && bash "$GR_LIB_DIR/reconcile-decide.sh" --notes "./$TID--fix/notes.md" --comments 1 --new-input 0)
_same "decide: reconcile-decide.sh output" "$want" "$(grep -v '^RECONCILE_N=' <<<"$out")"
grep -qx 'RECONCILE_N=2' <<<"$out" && _ok "decide: same cycle as prep" || _ko "decide: $out"
grep -q 'RECONCILE_DECISION=hold' <<<"$out" && _ok "decide: open question holds" || _ko "decide: $out"
_restore_logs
(cd "$WS" && bash "$GR_LIB_DIR/gate-reconcile-finish.sh" "$TID" decide --comments 1 --new-input 0 >/dev/null)
_same "decide: writes nothing" "$(_mask <"$WS/base.log")" "$(_mask <"$WS/logs/$TID-pipeline.log")"
rc=0
(cd "$WS" && bash "$GR_LIB_DIR/gate-reconcile-finish.sh" "$TID" hold >/dev/null 2>&1) || rc=$?
_same "finish: hold without --reason exits 2" 2 "$rc"
_ws_rm

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
