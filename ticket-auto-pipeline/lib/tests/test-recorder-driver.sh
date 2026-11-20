#!/usr/bin/env bash
# test-recorder-driver.sh — tests for lib/board-drivers/recorder.sh, its
# board-shot.mjs and the Recording rows of env-check (openspec change
# ticket-auto-record, PR 4).
#
# The screenshot is a stub: RECORDER_SHOT_OVERRIDE names a bash script and
# RECORDER_NODE_OVERRIDE=bash runs it, so no browser, no Playwright and no
# network is used. The real board-shot.mjs is only syntax-checked, asked for
# a browser it cannot find, and used to save a session from stdin; the real
# browser path is covered by the live check alone.
# -u (nounset) intentionally omitted — see test-detect-resume.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DRIVER="$LIB_DIR/board-drivers/recorder.sh"
SHOT="$LIB_DIR/board-drivers/record/board-shot.mjs"
DRAIN="$LIB_DIR/../skills/ticket-flow/outbox-drain.sh"
CURSOR="$LIB_DIR/board-cursor.sh"
STITCH="$LIB_DIR/record-stitch.sh"

exec </dev/null

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Never let an operator's settings reach the code under test.
unset REPOS_ROOT FLEET_PIPELINE_LOG_DIR TAP_LOG LOG_FILE LOCAL_URL UAT_URL \
  RECORD_ALLOWED RECORD_UAT_SYNTHETIC RECORD_BOARD_URL RECORD_DISABLE \
  RECORD_SHOT_TIMEOUT TICKET_RECORD FLEET_BOARD_DRIVERS FLEET_GENERATION \
  FLEET_STATE_DIR STATE_ROOT_STRICT OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE

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

# ── The stub screenshot ───────────────────────────────────────────────────────
# STUB_MODE: ok | mismatch | expired | nosession | hang | check-<word>.
# Every call is listed in $STUB_CALLS.
STUB="$WORK/stub/board-shot.mjs"
mkdir -p "$WORK/stub"
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_CALLS"
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "--out" ] && out="$a"
  prev="$a"
done
case "${STUB_MODE:-ok}" in
ok)
  printf 'PNG-stub' >"$out.tmp-stub" && mv "$out.tmp-stub" "$out"
  exit 0
  ;;
mismatch) exit 3 ;;
expired) exit 4 ;;
nosession) exit 7 ;;
hang) exec sleep 30 ;;
check-*)
  echo "${STUB_MODE#check-}"
  exit 0
  ;;
esac
exit 1
STUBEOF

N=0
ROOT="" LOGS="" TDIR="" REC="" LOG="" OUTBOX="" MAN=""

# _setup — a fresh tickets root with one recording ticket, CRE-12.
_setup() {
  N=$((N + 1))
  ROOT="$WORK/root$N"
  LOGS="$ROOT/logs"
  TDIR="$ROOT/tickets/CRE-12--demo"
  REC="$TDIR/artifacts/recordings"
  LOG="$LOGS/CRE-12-pipeline.log"
  OUTBOX="$LOGS/CRE-12-outbox.jsonl"
  MAN="$REC/manifest.jsonl"
  mkdir -p "$LOGS" "$TDIR"
  printf '2026-01-01T00:00:00Z|META|schema|info|1\n2026-01-01T00:00:00Z|META|record|info|on\n' >"$LOG"
  export REPOS_ROOT="$ROOT" FLEET_PIPELINE_LOG_DIR="$LOGS"
  export RECORD_BOARD_URL="https://linear.app/acme/project/demo-1a2b/board"
  export RECORDER_SHOT_OVERRIDE="$STUB" RECORDER_NODE_OVERRIDE=bash
  export STUB_CALLS="$ROOT/calls" STUB_MODE=ok
  : >"$STUB_CALLS"
}

_event() { # seq event [data]
  printf '{"seq":%s,"tid":"CRE-12","ts":"t","gen":null,"event":"%s","data":%s,"from_hint":null,"idem":null}\n' \
    "$1" "$2" "${3:-{\}}" >>"$OUTBOX"
}

_linear_at() { bash "$CURSOR" advance CRE-12 linear "$1" >/dev/null 2>&1; }

_apply() { bash "$DRIVER" apply CRE-12 "$@"; }

_calls() { wc -l <"$STUB_CALLS" | tr -d ' '; }

_entries() { [ -f "$MAN" ] && wc -l <"$MAN" | tr -d ' ' || echo 0; }

_last() { tail -1 "$MAN" | jq -r "$1"; }

# ── Only card moves of recording tickets ──────────────────────────────────────

test_non_recording_ticket_does_nothing() {
  _setup
  printf '2026-01-01T00:00:00Z|META|schema|info|1\n' >"$LOG"
  _event 3 appraise-completed
  _linear_at 3
  _apply appraise-completed 3 '{}' && [ "$(_calls)" -eq 0 ] && [ ! -e "$MAN" ] && [ ! -d "$REC" ]
}

test_record_disable_does_nothing() {
  _setup
  _event 7 human-approved
  _linear_at 7
  RECORD_DISABLE=true _apply human-approved 7 '{}' && [ "$(_calls)" -eq 0 ] && [ ! -e "$MAN" ]
}

test_event_that_moves_no_card() {
  _setup
  _event 5 implement-outcome-recorded
  _linear_at 5
  _apply implement-outcome-recorded 5 '{}' && [ "$(_calls)" -eq 0 ] && [ ! -e "$MAN" ]
}

test_repos_root_unset_writes_nothing() {
  _setup
  _event 7 human-approved
  _linear_at 7
  (unset REPOS_ROOT && _apply human-approved 7 '{}') && [ "$(_calls)" -eq 0 ] && [ ! -e "$MAN" ]
}

test_no_workspace_writes_nothing() {
  _setup
  _event 7 human-approved
  _linear_at 7
  rm -rf "$TDIR"
  _apply human-approved 7 '{}' && [ "$(_calls)" -eq 0 ] && [ ! -d "$ROOT/tickets/CRE-12--demo" ]
}

test_bad_arguments_exit_zero() {
  _setup
  bash "$DRIVER" apply 'CRE-12/../x' human-approved 7 '{}' &&
    bash "$DRIVER" apply CRE-12 'Human Approved' 7 '{}' &&
    bash "$DRIVER" apply CRE-12 human-approved seven '{}' &&
    bash "$DRIVER" apply CRE-12 human-approved 7 'not json' &&
    bash "$DRIVER" apply &&
    bash "$DRIVER" nonsense 2>/dev/null &&
    [ "$(_calls)" -le 1 ]
}

# ── Only the last pending move, after linear applied it ───────────────────────

test_backlog_is_superseded() {
  _setup
  _event 7 human-approved
  _event 8 implement-outcome-recorded
  _event 9 implement-completed
  _linear_at 9
  _apply human-approved 7 '{}' && [ "$(_calls)" -eq 0 ] &&
    [ "$(_last '.status + "/" + .reason')" = "skipped/superseded" ] &&
    [ "$(_last '.seq')" = 7 ] && [ ! -e "$REC/board-7-human-approved.png" ]
}

test_later_non_move_does_not_supersede() {
  _setup
  _event 7 human-approved
  _event 8 implement-outcome-recorded
  _linear_at 8
  _apply human-approved 7 '{}' && [ "$(_calls)" -eq 1 ] && [ "$(_last .status)" = ok ]
}

test_linear_behind() {
  _setup
  _event 6 appraise-completed
  _event 7 human-approved
  _linear_at 6
  _apply human-approved 7 '{}' && [ "$(_calls)" -eq 0 ] &&
    [ "$(_last '.status + "/" + .reason')" = "skipped/board-not-applied" ]
}

# ── A frame only when the card is seen in its column ──────────────────────────

test_card_in_place() {
  _setup
  _event 7 human-approved
  _linear_at 7
  _apply human-approved 7 '{}' || return 1
  local f="$REC/board-7-human-approved.png"
  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(_entries)" -eq 1 ] &&
    [[ "$(_last .file)" =~ ^board-[0-9]+-[a-z0-9-]+\.png$ ]] &&
    [ "$(_last '[.source, .status, .column, .event, (.seq|tostring)] | join(" ")')" = "board ok Ready human-approved 7" ] &&
    [ "$(_last '[.env, .phase, .attempt, .step, .reason] | map(. == null) | all')" = true ] &&
    [ "$(_last '.tid')" = CRE-12 ] &&
    [ "$(_last 'keys_unsorted | join(",")')" = "ts,tid,source,phase,attempt,step,file,env,event,seq,column,status,reason" ] &&
    [[ "$(_last .ts)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]] &&
    grep -q -- "--tid CRE-12 --column Ready" "$STUB_CALLS" &&
    grep -q -- "--url https://linear.app/acme/project/demo-1a2b/board" "$STUB_CALLS"
}

test_column_from_event_data() {
  _setup
  _event 11 pr-review-passed '{"uat_required":true}'
  _linear_at 11
  _apply pr-review-passed 11 '{"uat_required":true}' && [ "$(_last .column)" = UAT ] || return 1
  _setup
  _event 11 pr-review-passed
  _linear_at 11
  _apply pr-review-passed 11 '{}' && [ "$(_last .column)" = Done ]
}

test_card_not_yet_moved() {
  _setup
  _event 7 human-approved
  _linear_at 7
  STUB_MODE=mismatch _apply human-approved 7 '{}' && [ "$(_calls)" -eq 1 ] &&
    [ ! -e "$REC/board-7-human-approved.png" ] &&
    [ "$(_last '.status + "/" + .reason')" = "skipped/column-mismatch" ] &&
    [ "$(_last .file)" = null ]
}

test_replay_is_a_noop() {
  _setup
  _event 7 human-approved
  _linear_at 7
  _apply human-approved 7 '{}' || return 1
  _apply human-approved 7 '{}' && [ "$(_calls)" -eq 1 ] && [ "$(_entries)" -eq 1 ]
}

test_stitch_plans_the_board_frame() {
  _setup
  _event 7 human-approved
  _linear_at 7
  _apply human-approved 7 '{}' || return 1
  local plan
  plan=$(RECORD_ALLOWED=local bash "$STITCH" plan video CRE-12 2>/dev/null)
  grep -q "board-7-human-approved.png'" <<<"$plan" && grep -qx 'duration 2' <<<"$plan"
}

# ── Bounded, failures isolated ────────────────────────────────────────────────

test_hung_browser_times_out() {
  _setup
  _event 7 human-approved
  _linear_at 7
  local t0 t1
  t0=$(date +%s)
  STUB_MODE=hang RECORD_SHOT_TIMEOUT=2 _apply human-approved 7 '{}' || return 1
  t1=$(date +%s)
  [ $((t1 - t0)) -le 5 ] && [ "$(_last '.status + "/" + .reason')" = "fail/timeout" ] &&
    [ ! -e "$REC/board-7-human-approved.png" ]
}

test_timeout_setting_is_capped() {
  (
    source "$DRIVER"
    [ "$(_recorder_shot_timeout)" = 25 ] &&
      [ "$(RECORD_SHOT_TIMEOUT=600 _recorder_shot_timeout)" = 25 ] &&
      [ "$(RECORD_SHOT_TIMEOUT=abc _recorder_shot_timeout)" = 25 ] &&
      [ "$(RECORD_SHOT_TIMEOUT=10 _recorder_shot_timeout)" = 10 ]
  )
}

test_session_expired_and_no_session() {
  _setup
  _event 7 human-approved
  _linear_at 7
  STUB_MODE=expired _apply human-approved 7 '{}' &&
    [ "$(_last '.status + "/" + .reason')" = "fail/session-expired" ] || return 1
  STUB_MODE=nosession _apply human-approved 7 '{}' &&
    [ "$(_last '.status + "/" + .reason')" = "fail/no-session" ]
}

test_no_node_is_browser_missing() {
  _setup
  _event 7 human-approved
  _linear_at 7
  RECORDER_NODE_OVERRIDE=no-such-node-binary _apply human-approved 7 '{}' &&
    [ "$(_calls)" -eq 0 ] && [ "$(_last '.status + "/" + .reason')" = "fail/browser-missing" ]
}

test_board_url_shape() {
  _setup
  _event 7 human-approved
  _linear_at 7
  local u
  for u in "https://linear.app/acme/team/CRE/active" "http://linear.app/acme/view/x" \
    "https://example.com/acme/project/x" "linear.app/acme/project/x"; do
    RECORD_BOARD_URL="$u" _apply human-approved 7 '{}' &&
      [ "$(_last '.status + "/" + .reason')" = "fail/bad-board-url" ] || return 1
  done
  (unset RECORD_BOARD_URL && _apply human-approved 7 '{}') &&
    [ "$(_last '.status + "/" + .reason')" = "fail/no-board-url" ] || return 1
  [ "$(_calls)" -eq 0 ] || return 1
  RECORD_BOARD_URL="https://linear.app/acme/view/demo-9f" _apply human-approved 7 '{}' &&
    [ "$(_last .status)" = ok ]
}

test_board_url_from_claude_md() {
  _setup
  _event 7 human-approved
  _linear_at 7
  unset RECORD_BOARD_URL
  printf 'RECORD_BOARD_URL=https://linear.app/acme/project/from-md/board\n' >"$ROOT/CLAUDE.md"
  _apply human-approved 7 '{}' && grep -q -- "--url https://linear.app/acme/project/from-md/board" "$STUB_CALLS"
}

test_symlinked_recordings_dir_is_refused() {
  _setup
  _event 7 human-approved
  _linear_at 7
  mkdir -p "$TDIR/artifacts" "$ROOT/elsewhere"
  ln -s "$ROOT/elsewhere" "$REC"
  _apply human-approved 7 '{}' && [ "$(_calls)" -eq 0 ] && [ -z "$(ls -A "$ROOT/elsewhere")" ]
}

test_pipeline_log_and_cursor_untouched() {
  _setup
  _event 7 human-approved
  _linear_at 7
  local before after cur
  before=$(sha256sum "$LOG" "$LOGS/.CRE-12-cursor-linear.json" | sha256sum)
  _apply human-approved 7 '{}'
  STUB_MODE=mismatch _apply human-approved 7 '{}'
  STUB_MODE=expired _apply appraise-completed 7 '{}'
  RECORD_BOARD_URL=bad _apply human-rejected 7 '{}'
  after=$(sha256sum "$LOG" "$LOGS/.CRE-12-cursor-linear.json" | sha256sum)
  cur=$(find "$LOGS" -name '.CRE-12-cursor-recorder*' | wc -l)
  [ "$before" = "$after" ] && [ "$cur" -eq 0 ]
}

# ── A real drain ──────────────────────────────────────────────────────────────

# _drain_fixture — a stub linear driver that lists what it was handed.
_drain_fixture() {
  _setup
  mkdir -p "$ROOT/drivers"
  cat >"$ROOT/drivers/linear.sh" <<'DRV'
#!/usr/bin/env bash
echo "$*" >>"$LINEAR_CALLS"
exit 0
DRV
  export LINEAR_CALLS="$ROOT/linear-calls"
  : >"$LINEAR_CALLS"
  printf '{"origin":"new","origin_seq":0}\n' >"$LOGS/.CRE-12-outbox-origin.json"
  _event 1 appraise-started
  _event 2 appraise-completed
  _event 3 gate-held '{"reason":"a"}'
  _event 4 human-approved
  printf '2026-01-01T00:00:09Z|META|outcome|info|held: gate\n' >>"$LOG"
}

_drain() {
  (cd "$ROOT" && OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE="$ROOT/drivers" bash "$DRAIN" CRE-12 2>"$ROOT/drain.err")
}

test_drain_linear_then_recorder() {
  _drain_fixture
  FLEET_BOARD_DRIVERS=linear,recorder _drain || return 1
  [ "$(bash "$CURSOR" get CRE-12 linear)" = 4 ] && [ "$(bash "$CURSOR" get CRE-12 recorder)" = 4 ] &&
    [ "$(wc -l <"$LINEAR_CALLS")" -eq 4 ] && [ "$(_calls)" -eq 1 ] &&
    [ -f "$REC/board-4-human-approved.png" ] && [ ! -e "$REC/board-2-appraise-completed.png" ] &&
    [ "$(jq -sr '[.[] | .status + "/" + (.reason // "")] | join(" ")' "$MAN")" = "skipped/superseded skipped/superseded ok/" ]
}

test_drain_outcome_stays_last() {
  _drain_fixture
  local before
  before=$(sha256sum <"$LOG")
  FLEET_BOARD_DRIVERS=linear,recorder _drain || return 1
  grep -q '|META|outcome|' <<<"$(tail -1 "$LOG")" && [ "$before" = "$(sha256sum <"$LOG")" ]
}

test_drain_linear_sees_the_same_with_and_without_recorder() {
  _drain_fixture
  FLEET_BOARD_DRIVERS=linear _drain || return 1
  local alone
  alone=$(cat "$LINEAR_CALLS")
  _drain_fixture
  STUB_MODE=expired FLEET_BOARD_DRIVERS=linear,recorder _drain || return 1
  [ -n "$alone" ] && [ "$alone" = "$(cat "$LINEAR_CALLS")" ] && [ "$(bash "$CURSOR" get CRE-12 linear)" = 4 ]
}

test_drain_survives_a_hung_screenshot() {
  _drain_fixture
  local t0 t1
  t0=$(date +%s)
  STUB_MODE=hang RECORD_SHOT_TIMEOUT=1 FLEET_BOARD_DRIVERS=linear,recorder _drain || return 1
  t1=$(date +%s)
  [ $((t1 - t0)) -le 6 ] && [ "$(bash "$CURSOR" get CRE-12 recorder)" = 4 ] &&
    [ "$(_last '.status + "/" + .reason')" = "fail/timeout" ] &&
    grep -q '|META|outcome|' <<<"$(tail -1 "$LOG")"
}

test_drain_recorder_first_shoots_nothing() {
  _drain_fixture
  FLEET_BOARD_DRIVERS=recorder,linear _drain || return 1
  [ "$(_calls)" -eq 0 ] && [ "$(_last '.status + "/" + .reason')" = "skipped/board-not-applied" ] &&
    [ "$(wc -l <"$LINEAR_CALLS")" -eq 4 ]
}

# ── board-shot.mjs itself (no browser) ────────────────────────────────────────

test_board_shot_syntax() {
  command -v node >/dev/null 2>&1 || {
    echo "  (node not installed; syntax check skipped)"
    return 0
  }
  node --check "$SHOT"
}

test_board_shot_without_playwright() {
  command -v node >/dev/null 2>&1 || return 0
  _setup
  local rc=0 word
  node "$SHOT" shoot --repos-root "$ROOT" --url "$RECORD_BOARD_URL" --tid CRE-12 \
    --column Ready --columns '["Ready"]' --out "$ROOT/x.png" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 5 ] && [ ! -e "$ROOT/x.png" ] || return 1
  rc=0
  word=$(node "$SHOT" --check --repos-root "$ROOT" 2>/dev/null) || rc=$?
  [ "$rc" -eq 5 ] && [ "$word" = browser-missing ] || return 1
  rc=0
  node "$SHOT" bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_driver_with_real_script_and_no_playwright() {
  command -v node >/dev/null 2>&1 || return 0
  _setup
  _event 7 human-approved
  _linear_at 7
  unset RECORDER_SHOT_OVERRIDE RECORDER_NODE_OVERRIDE
  _apply human-approved 7 '{}' && [ "$(_last '.status + "/" + .reason')" = "fail/browser-missing" ]
}

# _fake_playwright — a `playwright` module under the record dir, where
# board-shot.mjs looks for it. FAKE_PW: launch-fail | login | in-column.
_fake_playwright() {
  local d="$ROOT/.ticket-auto/record/node_modules/playwright"
  mkdir -p "$d"
  printf '{"name":"playwright","main":"index.js"}\n' >"$d/package.json"
  cat >"$d/index.js" <<'FAKEEOF'
const fs = require('fs');
const mode = process.env.FAKE_PW;
const page = {
  goto: async () => {},
  url: () => (mode === 'login' ? 'https://linear.app/login' : 'https://linear.app/acme/project/x/board'),
  evaluate: async (fn, arg) => {
    fs.appendFileSync(process.env.FAKE_PW_LOG, JSON.stringify(arg) + '\n');
    return { state: 'in-column', clip: { x: 1, y: 2, width: 300, height: 400 } };
  },
  screenshot: async (o) => fs.writeFileSync(o.path, 'PNG ' + JSON.stringify(o.clip)),
};
exports.chromium = {
  launch: async () => {
    if (mode === 'launch-fail') throw new Error("Executable doesn't exist");
    return { newContext: async () => ({ newPage: async () => page }), close: async () => {} };
  },
};
FAKEEOF
  export FAKE_PW_LOG="$ROOT/fake-pw.log"
  : >"$FAKE_PW_LOG"
}

_shoot() {
  local rc=0
  node "$SHOT" shoot --repos-root "$ROOT" --url "$RECORD_BOARD_URL" --tid CRE-12 \
    --column Ready --columns '["Ready","Todo"]' --out "$ROOT/shots/board-7-human-approved.png" \
    >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

test_board_shot_flow_with_a_fake_playwright() {
  command -v node >/dev/null 2>&1 || return 0
  _setup
  _fake_playwright
  mkdir -p "$ROOT/shots"
  # No session yet.
  [ "$(FAKE_PW=in-column _shoot)" -eq 7 ] || return 1
  printf '{"cookies":[],"origins":[]}' | node "$SHOT" --import --repos-root "$ROOT" 2>/dev/null || return 1
  [ "$(FAKE_PW=launch-fail _shoot)" -eq 5 ] && [ "$(FAKE_PW=login _shoot)" -eq 4 ] &&
    [ -z "$(ls -A "$ROOT/shots")" ] || return 1
  [ "$(FAKE_PW=in-column _shoot)" -eq 0 ] &&
    [ "$(cat "$ROOT/shots/board-7-human-approved.png")" = 'PNG {"x":1,"y":2,"width":300,"height":400}' ] &&
    [ "$(ls -A "$ROOT/shots" | wc -l)" -eq 1 ] &&
    [ "$(tail -1 "$FAKE_PW_LOG" | jq -r '.tid + " " + .column + " " + (.columns | join(","))')" = "CRE-12 Ready Ready,Todo" ] || return 1
  [ "$(FAKE_PW=login node "$SHOT" --check --repos-root "$ROOT" 2>/dev/null)" = expired ] &&
    [ "$(FAKE_PW=in-column node "$SHOT" --check --repos-root "$ROOT" 2>/dev/null)" = ok ]
}

test_driver_end_to_end_with_a_fake_playwright() {
  command -v node >/dev/null 2>&1 || return 0
  _setup
  _fake_playwright
  _event 7 human-approved
  _linear_at 7
  unset RECORDER_SHOT_OVERRIDE RECORDER_NODE_OVERRIDE
  printf '{"cookies":[],"origins":[]}' | node "$SHOT" --import --repos-root "$ROOT" 2>/dev/null || return 1
  FAKE_PW=in-column _apply human-approved 7 '{}' && [ "$(_last .status)" = ok ] &&
    [ -f "$REC/board-7-human-approved.png" ] && [ -z "$(find "$REC" -name '.board-*')" ]
}

test_session_is_saved_private() {
  command -v node >/dev/null 2>&1 || return 0
  _setup
  # A record dir npm already made with the default umask.
  mkdir -p "$ROOT/.ticket-auto/record"
  chmod 755 "$ROOT/.ticket-auto/record"
  local out secret="s3cr3t-cookie-value"
  out=$(printf '{"cookies":[{"name":"session","value":"%s"}],"origins":[]}' "$secret" |
    (umask 022 && node "$SHOT" --import --repos-root "$ROOT" 2>&1)) || return 1
  local f="$ROOT/.ticket-auto/record/linear-session.json"
  [ "$(stat -c %a "$f")" = 600 ] && [ "$(stat -c %a "$ROOT/.ticket-auto/record")" = 700 ] &&
    [ "$(cat "$ROOT/.ticket-auto/record/.gitignore")" = "*" ] &&
    ! grep -q "$secret" <<<"$out" && grep -q "$secret" "$f" &&
    [ -z "$(find "$ROOT/.ticket-auto/record" -name '*.tmp-*')" ]
}

test_session_import_refuses_garbage() {
  command -v node >/dev/null 2>&1 || return 0
  _setup
  local rc=0
  printf 'not json' | node "$SHOT" --import --repos-root "$ROOT" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] && [ ! -e "$ROOT/.ticket-auto/record/linear-session.json" ]
}

test_operator_check_passes_the_word_through() {
  _setup
  local word
  word=$(cd "$ROOT" && STUB_MODE=check-expired bash "$DRIVER" check 2>/dev/null)
  [ "$word" = expired ] && grep -q -- "--check --repos-root $ROOT --url https://linear.app/" "$STUB_CALLS" || return 1
  local rc=0
  (unset REPOS_ROOT && cd "$WORK" && bash "$DRIVER" check >/dev/null 2>&1) || rc=$?
  [ "$rc" -eq 2 ]
}

# ── env-check: the Recording rows ─────────────────────────────────────────────

_rows() { (source "$LIB_DIR/record-env-check.sh" && record_env_check_rows "$ROOT"); }

_row() { grep "^$1|" <<<"$2" | head -1; }

test_env_rows_absent_without_record_allowed() {
  _setup
  [ -z "$(_rows)" ]
}

test_env_rows_expired_session() {
  _setup
  local rows
  rows=$(RECORD_ALLOWED=local FLEET_BOARD_DRIVERS=linear,recorder STUB_MODE=check-expired _rows)
  [[ "$(_row RECORD_SESSION "$rows")" == "RECORD_SESSION|warn|expired|"* ]] &&
    [[ "$(_row RECORD_BROWSER "$rows")" == "RECORD_BROWSER|ok|"* ]] &&
    [[ "$(_row RECORD_ALLOWED "$rows")" == "RECORD_ALLOWED|ok|local|"* ]] &&
    [[ "$(_row RECORD_BOARD_DRIVERS "$rows")" == "RECORD_BOARD_DRIVERS|ok|"* ]] &&
    [[ "$(_row RECORD_BOARD_URL "$rows")" == "RECORD_BOARD_URL|ok|present|"* ]] &&
    [ "$(wc -l <<<"$rows")" -eq 8 ] &&
    [ -z "$(awk -F'|' '$2 != "ok" && $2 != "warn"' <<<"$rows")" ] &&
    [ -z "$(awk -F'|' 'NF != 5' <<<"$rows")" ] &&
    ! grep -q "demo-1a2b" <<<"$rows"
}

test_env_rows_warn_on_each_gap() {
  _setup
  local rows
  rows=$(RECORD_ALLOWED=uat RECORD_BOARD_URL=https://linear.app/acme/team/x STUB_MODE=check-browser-missing _rows)
  [[ "$(_row RECORD_ALLOWED "$rows")" == "RECORD_ALLOWED|warn|"* ]] &&
    [[ "$(_row RECORD_BOARD_DRIVERS "$rows")" == "RECORD_BOARD_DRIVERS|warn|linear|"* ]] &&
    [[ "$(_row RECORD_BOARD_URL "$rows")" == "RECORD_BOARD_URL|warn|"* ]] &&
    [[ "$(_row RECORD_BROWSER "$rows")" == "RECORD_BROWSER|warn|"* ]] &&
    [[ "$(_row RECORD_SESSION "$rows")" == "RECORD_SESSION|warn|"* ]] &&
    [[ "$(_row RECORD_SESSION_MODE "$rows")" == "RECORD_SESSION_MODE|warn|"* ]] &&
    [[ "$(_row RECORD_SESSION_IGNORED "$rows")" == "RECORD_SESSION_IGNORED|warn|"* ]] &&
    [[ "$(_row RECORD_FFMPEG "$rows")" == "RECORD_FFMPEG|"* ]]
}

test_env_rows_ffmpeg_uses_command_v() {
  _setup
  mkdir -p "$ROOT/bin"
  printf '#!/bin/sh\nexit 0\n' >"$ROOT/bin/ffmpeg"
  chmod +x "$ROOT/bin/ffmpeg"
  local with without
  with=$(RECORD_ALLOWED=local STUB_MODE=check-ok PATH="$ROOT/bin:$PATH" _rows)
  [[ "$(_row RECORD_FFMPEG "$with")" == "RECORD_FFMPEG|ok|$ROOT/bin/ffmpeg|"* ]] || return 1
  # A PATH with the tools this function needs, minus ffmpeg.
  mkdir -p "$ROOT/tools"
  local t p
  for t in bash jq timeout stat git tr tail grep sed cat dirname date flock mkdir wc find sort realpath; do
    p=$(command -v "$t") && ln -sf "$p" "$ROOT/tools/$t"
  done
  without=$(RECORD_ALLOWED=local STUB_MODE=check-ok PATH="$ROOT/tools" _rows)
  [[ "$(_row RECORD_FFMPEG "$without")" == "RECORD_FFMPEG|warn|"* ]]
}

test_env_rows_session_mode_and_ignore() {
  _setup
  local d="$ROOT/.ticket-auto/record" rows
  mkdir -p "$d"
  printf '{}' >"$d/linear-session.json"
  chmod 644 "$d/linear-session.json"
  chmod 755 "$d"
  git -C "$ROOT" init -q 2>/dev/null
  rows=$(RECORD_ALLOWED=local STUB_MODE=check-ok _rows)
  [[ "$(_row RECORD_SESSION_MODE "$rows")" == "RECORD_SESSION_MODE|warn|file 644, dir 755|"* ]] &&
    [[ "$(_row RECORD_SESSION_IGNORED "$rows")" == "RECORD_SESSION_IGNORED|warn|"* ]] &&
    [[ "$(_row RECORD_SESSION "$rows")" == "RECORD_SESSION|ok|"* ]] || return 1
  chmod 600 "$d/linear-session.json"
  chmod 700 "$d"
  printf '*\n' >"$d/.gitignore"
  rows=$(RECORD_ALLOWED=local STUB_MODE=check-ok _rows)
  [[ "$(_row RECORD_SESSION_MODE "$rows")" == "RECORD_SESSION_MODE|ok|"* ]] &&
    [[ "$(_row RECORD_SESSION_IGNORED "$rows")" == "RECORD_SESSION_IGNORED|ok|git-ignored|"* ]]
}

# env-check.sh itself: the section is there only with RECORD_ALLOWED, and it
# never changes the exit code.
_env_check() {
  local rc=0
  ENV_CHECK_SKIP_LINEAR=1 ENV_CHECK_USER_SKILLS_DIR="$ROOT/noskills" \
    bash "$LIB_DIR/env-check.sh" --mode=full "$ROOT" 2>/dev/null || rc=$?
  echo "RC=$rc"
}

test_env_check_section_only_when_set_and_exit_code_unchanged() {
  _setup
  mkdir -p "$ROOT/noskills"
  printf 'REPOS_ROOT=%s\nLOCAL_URL=http://localhost:3000\n' "$ROOT" >"$ROOT/CLAUDE.md"
  local off on
  off=$(_env_check)
  ! grep -q '^RECORD_' <<<"$off" || return 1
  printf 'RECORD_ALLOWED=local\n' >>"$ROOT/CLAUDE.md"
  on=$(STUB_MODE=check-expired _env_check)
  [ "$(grep -c '^RECORD_' <<<"$on")" -eq 8 ] &&
    grep -q '^RECORD_SESSION|warn|expired|' <<<"$on" &&
    ! grep -q '^RECORD_[A-Z_]*|missing|' <<<"$on" &&
    [ "$(grep '^RC=' <<<"$off")" = "$(grep '^RC=' <<<"$on")" ] &&
    [ "$(grep '^ROWCOUNT=' <<<"$on" | cut -d= -f2)" -eq $(($(grep '^ROWCOUNT=' <<<"$off" | cut -d= -f2) + 8)) ]
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  _run "$t" "$t"
done

echo ""
echo "test-recorder-driver.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
