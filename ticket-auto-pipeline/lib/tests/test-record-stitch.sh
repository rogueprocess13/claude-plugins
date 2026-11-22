#!/usr/bin/env bash
# test-record-stitch.sh — lib/record-stitch.sh and the ticket-record-stitch
# skill (openspec change ticket-auto-record, PR 3).
#
# Planner cases run with a tripwire `ffmpeg` first on PATH: the planner must
# never start it. Render cases use the real ffmpeg and ffprobe and FAIL (not
# skip) when either is missing — CI installs both (.github/actions/install-deps).
# Failure paths (ffmpeg absent, ffmpeg failing) use a stripped PATH or a stub.
# -u (nounset) intentionally omitted — see test-detect-resume.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STITCH="$LIB_DIR/record-stitch.sh"
SKILL_MD="$LIB_DIR/../skills/ticket-record-stitch/SKILL.md"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Never let an operator's settings reach the code under test.
unset REPOS_ROOT FLEET_PIPELINE_LOG_DIR TAP_LOG LOG_FILE CLAUDE_LOG_FILE \
  LOCAL_URL UAT_URL RECORD_ALLOWED RECORD_UAT_SYNTHETIC RECORD_BOARD_URL \
  RECORD_DISABLE RECORD_STITCH_TIMEOUT

REAL_PATH="$PATH"
HAVE_FFMPEG=false
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
  HAVE_FFMPEG=true
fi

# Tripwire ffmpeg: records that it ran and fails.
TRIP_BIN="$WORK/trip-bin"
mkdir -p "$TRIP_BIN"
cat >"$TRIP_BIN/ffmpeg" <<EOF
#!/usr/bin/env bash
echo ran >>"$WORK/ffmpeg-ran"
exit 1
EOF
chmod +x "$TRIP_BIN/ffmpeg"

# A PATH with everything the script needs except ffmpeg.
NOFF_BIN="$WORK/noff-bin"
mkdir -p "$NOFF_BIN"
for _t in bash env jq sed grep cat mktemp dirname basename realpath find tr cut \
  paste sort head tail base64 rm mv timeout date wc; do
  ln -s "$(command -v "$_t")" "$NOFF_BIN/$_t"
done

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

# ── fixtures ──────────────────────────────────────────────────────────────────

# _root <name> — a fresh REPOS_ROOT; prints its path.
_root() {
  local r="$WORK/$1"
  rm -rf "$r"
  mkdir -p "$r"
  printf '%s\n' "$r"
}

# _ticket <root> <TID> <title> — workspace with context.md; prints the
# recordings dir.
_ticket() {
  local d
  d="$1/$2--$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')-slug"
  mkdir -p "$d/artifacts/recordings"
  printf '# %s: %s\n\n**Labels:** x\n' "$2" "$3" >"$d/context.md"
  printf '%s\n' "$d/artifacts/recordings"
}

# _entry <rec dir> <ts> <source> <attempt|-> <file|-> <env|-> <status> [tid]
# Appends one manifest line and, for a named file, creates it.
_entry() {
  local rec="$1" ts="$2" source="$3" attempt="$4" file="$5" env="$6" status="$7"
  local phase=verify
  [ "$source" = "board" ] && phase=""
  jq -nc --arg ts "$ts" --arg source "$source" --arg phase "$phase" \
    --arg attempt "$attempt" --arg file "$file" --arg env "$env" \
    --arg status "$status" '
    def n: if . == "-" or . == "" then null else . end;
    {ts: $ts, tid: "T", source: $source, phase: ($phase | n),
     attempt: (if $attempt == "-" then null else ($attempt | tonumber) end),
     step: "C1: total shows 120.00", file: ($file | n), env: ($env | n),
     event: null, seq: null, column: null, status: $status, reason: null}' \
    >>"$rec/manifest.jsonl"
  if [ "$file" != "-" ] && [ "${file##*/}" = "$file" ] && [ ! -e "$rec/$file" ]; then
    printf 'png-%s' "$file" >"$rec/$file"
  fi
}

# _plan <root> <args...> — the planner with the tripwire ffmpeg on PATH.
_plan() {
  local root="$1"
  shift
  REPOS_ROOT="$root" RECORD_ALLOWED="${ALLOWED-local}" PATH="$TRIP_BIN:$REAL_PATH" \
    bash "$STITCH" plan "$@"
}

_files() { grep '^file ' | sed -E "s/^file '.*\/([^/]+)'\$/\1/"; }
_durations() { grep '^duration ' | sed 's/^duration //' | paste -sd, -; }

# ── planner ───────────────────────────────────────────────────────────────────

test_clip_latest_attempt() {
  local root rec out i
  root=$(_root clip1)
  rec=$(_ticket "$root" CRE-12 "Total")
  for i in 1 2 3; do _entry "$rec" "2026-01-01T00:00:0$i.000Z" app 1 "verify-a1-00$i.png" local ok; done
  for i in 1 2 3 4 5; do _entry "$rec" "2026-01-01T00:01:0$i.000Z" app 2 "verify-a2-00$i.png" local ok; done
  out=$(_plan "$root" clip CRE-12) || return 1
  [ "$(_files <<<"$out" | paste -sd, -)" = "verify-a2-001.png,verify-a2-002.png,verify-a2-003.png,verify-a2-004.png,verify-a2-005.png" ] &&
    [ "$(_durations <<<"$out")" = "1.5,1.5,1.5,1.5,1.5" ] &&
    [ "$(head -1 <<<"$out")" = "ffconcat version 1.0" ] &&
    ! grep -q '^#title' <<<"$out"
}

test_clip_paths_are_absolute_and_real() {
  local root rec out
  root=$(_root clip2)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  out=$(_plan "$root" clip CRE-12) || return 1
  grep -qxF "file '$(realpath "$rec")/verify-a1-001.png'" <<<"$out"
}

test_failed_and_skipped_left_out() {
  local root rec out
  root=$(_root fail1)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-01-01T00:00:02.000Z" board - - - fail
  _entry "$rec" "2026-01-01T00:00:03.000Z" app 1 - local skipped
  _entry "$rec" "2026-01-01T00:00:04.000Z" app 1 verify-a1-002.png local ok
  out=$(_plan "$root" video CRE-12) || return 1
  [ "$(_files <<<"$out" | paste -sd, -)" = "verify-a1-001.png,verify-a1-002.png" ]
}

test_env_rechecked() {
  local root rec out
  root=$(_root env1)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png uat ok
  _entry "$rec" "2026-01-01T00:00:02.000Z" app 1 verify-a1-002.png local ok
  out=$(ALLOWED=local _plan "$root" video CRE-12) || return 1
  [ "$(_files <<<"$out" | paste -sd, -)" = "verify-a1-002.png" ]
}

test_env_uat_needs_synthetic_now() {
  local root rec out
  root=$(_root env2)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png uat ok
  out=$(ALLOWED=uat _plan "$root" clip CRE-12 2>/dev/null) || return 1
  [ -z "$(_files <<<"$out")" ] || return 1
  out=$(ALLOWED=uat RECORD_UAT_SYNTHETIC=true _plan "$root" clip CRE-12) || return 1
  [ "$(_files <<<"$out")" = "verify-a1-001.png" ]
}

test_nothing_allowed_plans_nothing() {
  local root rec out err
  root=$(_root env3)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-01-01T00:00:02.000Z" board - board-3-human-approved.png - ok
  out=$(ALLOWED="" _plan "$root" video CRE-12 2>"$WORK/env3.err") || return 1
  err=$(cat "$WORK/env3.err")
  [ "$out" = "ffconcat version 1.0" ] && grep -q 'RECORD_ALLOWED' <<<"$err" || return 1
  out=$(ALLOWED="local, staging" _plan "$root" video CRE-12 2>/dev/null) || return 1
  [ "$out" = "ffconcat version 1.0" ]
}

test_allowed_read_from_claude_md() {
  local root rec out
  root=$(_root env4)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  printf 'RECORD_ALLOWED = `local`\n' >"$root/CLAUDE.md"
  out=$(REPOS_ROOT="$root" PATH="$TRIP_BIN:$REAL_PATH" bash "$STITCH" plan clip CRE-12) || return 1
  [ "$(_files <<<"$out")" = "verify-a1-001.png" ]
}

test_video_order_and_durations() {
  local root rec out
  root=$(_root vid1)
  rec=$(_ticket "$root" CRE-12 "Total shows the right amount")
  # Written out of ts order on purpose: order is ts, not line order.
  _entry "$rec" "2026-01-01T00:00:03.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-01-01T00:00:01.000Z" board - board-3-appraise-completed.png - ok
  _entry "$rec" "2026-01-01T00:00:05.000Z" board - board-7-human-approved.png - ok
  _entry "$rec" "2026-01-01T00:00:04.000Z" app 1 verify-a1-002.png local ok
  out=$(_plan "$root" video CRE-12) || return 1
  [ "$(sed -n 2p <<<"$out")" = "#title 2 CRE-12 Total shows the right amount" ] &&
    [ "$(grep -c '^#title' <<<"$out")" -eq 1 ] &&
    [ "$(_files <<<"$out" | paste -sd, -)" = "board-3-appraise-completed.png,verify-a1-001.png,verify-a1-002.png,board-7-human-approved.png" ] &&
    [ "$(_durations <<<"$out")" = "2,1.5,1.5,2" ]
}

test_video_drops_earlier_verify_attempts() {
  local root rec out
  root=$(_root vid2)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-01-01T00:00:02.000Z" board - board-9-verify-failed.png - ok
  _entry "$rec" "2026-01-01T00:00:03.000Z" app 2 verify-a2-001.png local ok
  out=$(_plan "$root" video CRE-12) || return 1
  [ "$(_files <<<"$out" | paste -sd, -)" = "board-9-verify-failed.png,verify-a2-001.png" ]
}

test_latest_attempt_with_no_frames_is_empty() {
  local root rec out
  root=$(_root att1)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-01-01T00:00:02.000Z" app 2 - uat skipped
  out=$(_plan "$root" clip CRE-12 2>/dev/null) || return 1
  [ "$out" = "ffconcat version 1.0" ]
}

test_rerun_is_byte_identical() {
  local root rec a b before after
  root=$(_root rerun1)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" board - board-3-appraise-completed.png - ok
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-002.png local ok
  before=$(cd "$root" && find . -type f -exec sha256sum {} + | sort)
  a=$(_plan "$root" video CRE-12) || return 1
  b=$(_plan "$root" video CRE-12) || return 1
  after=$(cd "$root" && find . -type f -exec sha256sum {} + | sort)
  [ "$a" = "$b" ] && [ "$before" = "$after" ] &&
    # Equal ts keeps manifest order.
    [ "$(_files <<<"$a" | paste -sd, -)" = "board-3-appraise-completed.png,verify-a1-001.png,verify-a1-002.png" ]
}

test_traversal_refused() {
  local root rec out
  root=$(_root trav1)
  rec=$(_ticket "$root" CRE-12 "Total")
  mkdir -p "$root/.ticket-auto/record"
  echo secret >"$root/.ticket-auto/record/linear-session.json"
  echo png >"$rec/../verify-a1-009.png"
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 "../../.ticket-auto/record/linear-session.json" local ok
  _entry "$rec" "2026-01-01T00:00:02.000Z" app 1 "../verify-a1-009.png" local ok
  _entry "$rec" "2026-01-01T00:00:03.000Z" app 1 "$rec/verify-a1-001.png" local ok
  _entry "$rec" "2026-01-01T00:00:04.000Z" app 1 verify-a1-002.png local ok
  out=$(_plan "$root" video CRE-12) || return 1
  [ "$(_files <<<"$out")" = "verify-a1-002.png" ] && ! grep -q 'linear-session' <<<"$out"
}

test_name_whitelist() {
  local root rec out
  root=$(_root white1)
  rec=$(_ticket "$root" CRE-12 "Total")
  echo x >"$rec/CRE-12-verify.mp4"
  echo x >"$rec/manifest.jsonl.png"
  echo x >"$rec/verify-a1-01.png"
  echo x >"$rec/board-7-Human.png"
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 CRE-12-verify.mp4 local ok
  _entry "$rec" "2026-01-01T00:00:02.000Z" app 1 manifest.jsonl.png local ok
  _entry "$rec" "2026-01-01T00:00:03.000Z" app 1 verify-a1-01.png local ok
  _entry "$rec" "2026-01-01T00:00:04.000Z" board - board-7-Human.png - ok
  _entry "$rec" "2026-01-01T00:00:05.000Z" app 1 verify-a1-404.png local ok
  rm -f "$rec/verify-a1-404.png" # listed, but not on disk
  out=$(_plan "$root" video CRE-12 2>/dev/null) || return 1
  [ "$out" = "ffconcat version 1.0" ]
}

test_symlink_refused() {
  local root rec out
  root=$(_root sym1)
  rec=$(_ticket "$root" CRE-12 "Total")
  echo secret >"$root/outside.png"
  ln -s "$root/outside.png" "$rec/verify-a1-001.png"
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-01-01T00:00:02.000Z" app 1 verify-a1-002.png local ok
  out=$(_plan "$root" clip CRE-12) || return 1
  [ "$(_files <<<"$out")" = "verify-a1-002.png" ]
}

test_symlinked_recordings_dir_refused() {
  local root rec out
  root=$(_root sym2)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  mv "$rec" "$root/elsewhere"
  ln -s "$root/elsewhere" "$rec"
  out=$(_plan "$root" clip CRE-12 2>/dev/null) || return 1
  [ "$out" = "ffconcat version 1.0" ]
}

test_bad_id_refused() {
  local root out rc=0
  root=$(_root bad1)
  out=$(_plan "$root" video '../x' 2>/dev/null) || rc=$?
  [ "$rc" -eq 2 ] && [ -z "$out" ] || return 1
  rc=0
  out=$(_plan "$root" video CRE-12 'CRE-13;x' 2>/dev/null) || rc=$?
  [ "$rc" -eq 2 ] && [ -z "$out" ] || return 1
  rc=0
  out=$(_plan "$root" clip 2>/dev/null) || rc=$?
  [ "$rc" -eq 2 ] && [ -z "$out" ]
}

test_torn_line_tolerated() {
  local root rec out
  root=$(_root torn1)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  printf 'not json at all\n[1,2]\n"str"\n' >>"$rec/manifest.jsonl"
  _entry "$rec" "2026-01-01T00:00:02.000Z" app 1 verify-a1-002.png local ok
  printf '{"ts":"2026-01-01T00:00:03.000Z","tid":"T","source":"app","file":"verify-a1-0' >>"$rec/manifest.jsonl"
  out=$(_plan "$root" clip CRE-12) || return 1
  [ "$(_files <<<"$out" | paste -sd, -)" = "verify-a1-001.png,verify-a1-002.png" ]
}

test_nothing_globbed() {
  local root rec out
  root=$(_root glob1)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  echo x >"$rec/verify-a1-002.png"            # on disk, not in the manifest
  echo x >"$rec/../verify-CRE-12-c1-pass.png" # per-criterion evidence
  echo x >"$rec/../verify-CRE-12-c2-fail.png"
  out=$(_plan "$root" video CRE-12) || return 1
  [ "$(_files <<<"$out")" = "verify-a1-001.png" ]
}

test_missing_ticket_and_manifest() {
  local root out
  root=$(_root miss1)
  _ticket "$root" CRE-13 "No recording" >/dev/null
  out=$(_plan "$root" video CRE-12 CRE-13 2>"$WORK/miss1.err") || return 1
  [ "$out" = "ffconcat version 1.0" ] &&
    grep -q 'CRE-12: no ticket directory' "$WORK/miss1.err" &&
    grep -q 'CRE-13: no recordable frames' "$WORK/miss1.err"
}

test_no_repos_root() {
  local out
  out=$(cd "$WORK" && RECORD_ALLOWED=local PATH="$TRIP_BIN:$REAL_PATH" bash "$STITCH" plan clip CRE-12 2>/dev/null) || return 1
  [ "$out" = "ffconcat version 1.0" ]
}

test_multi_ticket_order() {
  local root r1 r2 r3 out
  root=$(_root multi1)
  r1=$(_ticket "$root" CRE-12 "Second by time")
  r2=$(_ticket "$root" CRE-13 "First by time")
  r3=$(_ticket "$root" CRE-14 "Nothing recorded")
  _entry "$r1" "2026-01-02T00:00:01.000Z" app 1 verify-a1-001.png local ok
  _entry "$r2" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  : "$r3"
  out=$(_plan "$root" video CRE-12 CRE-13 CRE-14 CRE-12 2>/dev/null) || return 1
  [ "$(grep '^#title' <<<"$out" | paste -sd'|' -)" = "#title 2 CRE-13 First by time|#title 2 CRE-12 Second by time" ] || return 1
  [ "$(grep -c '^file ' <<<"$out")" -eq 2 ] || return 1
  out=$(_plan "$root" video --order given CRE-12 CRE-13 CRE-14 2>/dev/null) || return 1
  [ "$(grep '^#title' <<<"$out" | paste -sd'|' -)" = "#title 2 CRE-12 Second by time|#title 2 CRE-13 First by time" ] || return 1
  # Each title is directly followed by that ticket's own frame.
  [ "$(sed -n 3p <<<"$out")" = "file '$(realpath "$r1")/verify-a1-001.png'" ]
}

test_title_is_one_plain_line() {
  local root rec out d
  root=$(_root title1)
  rec=$(_ticket "$root" CRE-12 "x")
  d=$(dirname "$(dirname "$rec")")
  printf "# CRE-12: It's 100%% \"done\": a\tb %s\n" "$(printf 'y%.0s' $(seq 1 120))" >"$d/context.md"
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  out=$(_plan "$root" video CRE-12) || return 1
  [ "$(grep -c '^#title' <<<"$out")" -eq 1 ] &&
    grep -q "^#title 2 CRE-12 It's 100% \"done\": ab y" <<<"$out" &&
    [ "$(grep '^#title' <<<"$out" | wc -c)" -le 100 ] || return 1
  rm "$d/context.md"
  out=$(_plan "$root" video CRE-12) || return 1
  [ "$(sed -n 2p <<<"$out")" = "#title 2 CRE-12" ]
}

test_planner_never_runs_ffmpeg() {
  [ ! -e "$WORK/ffmpeg-ran" ]
}

# ── planner overlay (record-stitch-overlay) ──────────────────────────────────

# _log <log dir> <TID> <line>... — writes the ticket's pipeline log.
_log() {
  local dir="$1" tid="$2"
  shift 2
  mkdir -p "$dir"
  printf '%s\n' "$@" >"$dir/$tid-pipeline.log"
}

# _ov <plan> — the #overlay lines, one per line, without the prefix.
_ov() { grep '^#overlay ' <<<"$1" | sed 's/^#overlay //'; }

# _ovplan <root> <log dir> <args...> — the planner with a log dir.
_ovplan() {
  local root="$1" logs="$2"
  shift 2
  FLEET_PIPELINE_LOG_DIR="$logs" _plan "$root" "$@"
}

test_overlay_elapsed() {
  local root rec logs out
  root=$(_root ov1)
  logs="$root/logs"
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-11-20T15:12:05.400Z" app 1 verify-a1-001.png local ok
  _log "$logs" CRE-12 "2026-11-20T13:59:00Z|META|schema|info|1" \
    "2026-11-20T14:00:00Z|META|autonomy|info|auto"
  out=$(_ovplan "$root" "$logs" clip CRE-12) || return 1
  [ "$(_ov "$out")" = "4325 0 0 0 idle" ] || {
    echo "  got: $(_ov "$out")" >&2
    return 1
  }
  # Directly after the file line.
  grep -A1 '^file ' <<<"$out" | sed -n 2p | grep -q '^#overlay '
}

test_overlay_tokens_summed() {
  local root rec logs out
  root=$(_root ov2)
  logs="$root/logs"
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-11-20T14:10:00.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-11-20T14:12:12.900Z" app 1 verify-a1-002.png local ok
  _log "$logs" CRE-12 "2026-11-20T14:00:00Z|META|autonomy|info|auto" \
    "2026-11-20T14:05:28Z|META|tokens|info|APPRAISE:68/14385/3412969|elapsed_ms=1375" \
    "2026-11-20T14:12:12Z|META|tokens|info|EXEC:10/5481/300493"
  out=$(_ovplan "$root" "$logs" clip CRE-12) || return 1
  [ "$(_ov "$out" | cut -d' ' -f2,3 | paste -sd, -)" = "3427422 14385,3733406 19866" ] || {
    echo "  got: $(_ov "$out" | paste -sd, -)" >&2
    return 1
  }
}

test_overlay_malformed_tokens_skipped() {
  local root rec logs out
  root=$(_root ov3)
  logs="$root/logs"
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-11-20T14:10:00.000Z" app 1 verify-a1-001.png local ok
  _log "$logs" CRE-12 "2026-11-20T14:00:00Z|META|autonomy|info|auto" \
    "2026-11-20T14:01:00Z|META|tokens|info|APPRAISE:1/2/x" \
    "2026-11-20T14:02:00Z|META|tokens|info|garbage" \
    "not a log line at all" \
    "2026-11-20T14:03:00Z|META|tokens|info|EXEC:1/2/3"
  out=$(_ovplan "$root" "$logs" clip CRE-12) || return 1
  [ "$(_ov "$out" | cut -d' ' -f2,3)" = "6 2" ]
}

test_overlay_no_log_matches_no_overlay() {
  local root rec logs a b c
  root=$(_root ov4)
  logs="$root/logs"
  mkdir -p "$logs"
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-11-20T14:10:00.000Z" app 1 verify-a1-001.png local ok
  a=$(_ovplan "$root" "$logs" video CRE-12) || return 1
  b=$(_ovplan "$root" "$logs" video --no-overlay CRE-12) || return 1
  # And with a log present, --no-overlay still prints the plain plan.
  _log "$logs" CRE-12 "2026-11-20T14:00:00Z|META|autonomy|info|auto"
  c=$(_ovplan "$root" "$logs" video --no-overlay CRE-12) || return 1
  [ "$a" = "$b" ] && [ "$b" = "$c" ] && ! grep -q '^#overlay\|^#ovts' <<<"$a" &&
    [ "$(_ovplan "$root" "$logs" video CRE-12 | grep -c '^#overlay ')" -eq 1 ]
}

test_overlay_title_card_has_none() {
  local root rec logs out
  root=$(_root ov5)
  logs="$root/logs"
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-11-20T14:10:00.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-11-20T14:10:01.000Z" board - board-7-human-approved.png - ok
  _log "$logs" CRE-12 "2026-11-20T14:00:00Z|META|autonomy|info|auto"
  out=$(_ovplan "$root" "$logs" video CRE-12) || return 1
  [ "$(grep -c '^#overlay ' <<<"$out")" -eq 2 ] &&
    [ "$(grep -A1 '^#title' <<<"$out" | sed -n 2p | cut -c1-5)" = "file " ]
}

test_overlay_deterministic_read_only() {
  local root rec logs a b before after
  root=$(_root ov6)
  logs="$root/logs"
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-11-20T14:10:00.000Z" app 1 verify-a1-001.png local ok
  _log "$logs" CRE-12 "2026-11-20T14:00:00Z|META|autonomy|info|auto" \
    "2026-11-20T14:01:00Z|APPRAISE|appraise|waiting|Agent launched — x" \
    "2026-11-20T14:02:00Z|META|tokens|info|APPRAISE:1/2/3"
  before=$(find "$root" -type f -exec sha256sum {} + | sort)
  a=$(_ovplan "$root" "$logs" video CRE-12) || return 1
  b=$(_ovplan "$root" "$logs" video CRE-12) || return 1
  after=$(find "$root" -type f -exec sha256sum {} + | sort)
  [ "$a" = "$b" ] && [ "$before" = "$after" ]
}

test_overlay_one_agent() {
  local root rec logs out
  root=$(_root ov7)
  logs="$root/logs"
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-11-20T15:03:00.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-11-20T15:07:00.000Z" app 1 verify-a1-002.png local ok
  _log "$logs" CRE-12 "2026-11-20T14:00:00Z|META|autonomy|info|auto" \
    "2026-11-20T15:00:00Z|IMPLEMENT|implement|waiting|Agent launched — Implement" \
    "2026-11-20T15:06:37Z|IMPLEMENT|implement|done|ok"
  out=$(_ovplan "$root" "$logs" clip CRE-12) || return 1
  [ "$(_ov "$out" | cut -d' ' -f4 | paste -sd, -)" = "1,0" ]
}

test_overlay_parallel_tickets() {
  local root ra rb logs out
  root=$(_root ov8)
  logs="$root/logs"
  ra=$(_ticket "$root" CRE-1 "A")
  rb=$(_ticket "$root" CRE-2 "B")
  _entry "$ra" "2026-11-20T15:03:00.000Z" app 1 verify-a1-001.png local ok
  _entry "$rb" "2026-11-20T15:04:00.000Z" app 1 verify-a1-001.png local ok
  _log "$logs" CRE-1 "2026-11-20T14:00:00Z|META|autonomy|info|auto" \
    "2026-11-20T15:00:00Z|VERIFY|verify|waiting|Agent launched — v" \
    "2026-11-20T15:10:00Z|VERIFY|verify|done|ok"
  _log "$logs" CRE-2 "2026-11-20T14:30:00Z|META|autonomy|info|auto" \
    "2026-11-20T15:01:00Z|IMPLEMENT|implement|waiting|Agent launched — i" \
    "2026-11-20T15:20:00Z|IMPLEMENT|implement|done|ok"
  out=$(_ovplan "$root" "$logs" video CRE-1 CRE-2) || return 1
  [ "$(_ov "$out" | cut -d' ' -f4,5 | paste -sd, -)" = "2 fast,2 fast" ] || {
    echo "  got: $(_ov "$out" | paste -sd, -)" >&2
    return 1
  }
}

test_overlay_unclosed_and_retry() {
  local root rec logs out
  root=$(_root ov9)
  logs="$root/logs"
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-11-20T15:20:00.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-11-20T15:55:00.000Z" app 1 verify-a1-002.png local ok
  _entry "$rec" "2026-11-20T16:10:00.000Z" app 1 verify-a1-003.png local ok
  # The retry at 15:10 closes the 15:00 interval: never two at once.
  _log "$logs" CRE-12 "2026-11-20T14:00:00Z|META|autonomy|info|auto" \
    "2026-11-20T15:00:00Z|VERIFY|verify|waiting|Agent launched — v" \
    "2026-11-20T15:10:00Z|VERIFY|verify|waiting|Agent launched — v again" \
    "2026-11-20T15:30:00Z|VERIFY|verify|done|ok" \
    "2026-11-20T15:50:00Z|PR-REVIEW|review|waiting|Agent launched — r" \
    "2026-11-20T16:00:00Z|META|note|info|last line"
  out=$(_ovplan "$root" "$logs" clip CRE-12) || return 1
  [ "$(_ov "$out" | cut -d' ' -f4 | paste -sd, -)" = "1,1,0" ] || {
    echo "  got: $(_ov "$out" | paste -sd, -)" >&2
    return 1
  }
}

test_overlay_tiers() {
  local root rec logs out
  root=$(_root ov10)
  logs="$root/logs"
  rec=$(_ticket "$root" CRE-12 "Total")
  # idle, first frame with an agent (rate 0: normal), +1200 out in 60 s (fast),
  # +10 out in 60 s (normal).
  _entry "$rec" "2026-11-20T14:59:00.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-11-20T15:01:00.000Z" app 1 verify-a1-002.png local ok
  _entry "$rec" "2026-11-20T15:02:00.000Z" app 1 verify-a1-003.png local ok
  _entry "$rec" "2026-11-20T15:03:00.000Z" app 1 verify-a1-004.png local ok
  _log "$logs" CRE-12 "2026-11-20T14:00:00Z|META|autonomy|info|auto" \
    "2026-11-20T14:58:00Z|META|tokens|info|APPRAISE:0/5000/0" \
    "2026-11-20T15:00:00Z|IMPLEMENT|implement|waiting|Agent launched — i" \
    "2026-11-20T15:01:30Z|META|tokens|info|IMPLEMENT:0/1200/0" \
    "2026-11-20T15:02:30Z|META|tokens|info|IMPLEMENT:0/10/0" \
    "2026-11-20T15:30:00Z|IMPLEMENT|implement|done|ok"
  out=$(_ovplan "$root" "$logs" clip CRE-12) || return 1
  [ "$(_ov "$out" | cut -d' ' -f5 | paste -sd, -)" = "idle,normal,fast,normal" ] || {
    echo "  got: $(_ov "$out" | paste -sd, -)" >&2
    return 1
  }
  # A higher threshold turns the fast frame normal.
  out=$(RECORD_ANIM_FAST_TPS=100 _ovplan "$root" "$logs" clip CRE-12) || return 1
  [ "$(_ov "$out" | cut -d' ' -f5 | paste -sd, -)" = "idle,normal,normal,normal" ]
}

test_overlay_bad_threshold() {
  local root rec logs out err
  root=$(_root ov11)
  logs="$root/logs"
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-11-20T15:01:00.000Z" app 1 verify-a1-001.png local ok
  _entry "$rec" "2026-11-20T15:02:00.000Z" app 1 verify-a1-002.png local ok
  _log "$logs" CRE-12 "2026-11-20T14:00:00Z|META|autonomy|info|auto" \
    "2026-11-20T15:00:00Z|IMPLEMENT|implement|waiting|Agent launched — i" \
    "2026-11-20T15:01:30Z|META|tokens|info|IMPLEMENT:0/1200/0" \
    "2026-11-20T15:30:00Z|IMPLEMENT|implement|done|ok"
  out=$(RECORD_ANIM_FAST_TPS=abc _ovplan "$root" "$logs" clip CRE-12 2>"$WORK/ov11.err") || return 1
  err=$(cat "$WORK/ov11.err")
  [ "$(_ov "$out" | cut -d' ' -f5 | paste -sd, -)" = "normal,fast" ] &&
    [ "$(grep -c 'RECORD_ANIM_FAST_TPS' <<<"$err")" -eq 1 ] &&
    ! grep -q 'RECORD_ANIM_FAST_TPS' <<<"$out"
}

test_overlay_option_errors() {
  local root
  root=$(_root ov12)
  set +e
  _plan "$root" clip --anim CRE-12 >/dev/null 2>&1
  local a=$?
  _plan "$root" clip --order time CRE-12 >/dev/null 2>&1
  local b=$?
  REPOS_ROOT="$root" RECORD_ALLOWED=local PATH="$TRIP_BIN:$REAL_PATH" \
    bash "$STITCH" video --bogus CRE-12 >/dev/null 2>&1
  local c=$?
  set -e
  [ "$a" -eq 2 ] && [ "$b" -eq 2 ] && [ "$c" -eq 2 ]
}

# ── render ────────────────────────────────────────────────────────────────────

# _png <file> <WxH> <colour> — a real PNG (needs ffmpeg).
_png() {
  ffmpeg -nostdin -loglevel error -y -f lavfi -i "color=c=$3:s=$2" -frames:v 1 "$1"
}

# _real_ticket <root> <TID> <frames> — a ticket with N real app frames of
# attempt 1; prints the recordings dir.
_real_ticket() {
  local rec i
  rec=$(_ticket "$1" "$2" "Total shows 120.00")
  for i in $(seq 1 "$3"); do
    _png "$rec/verify-a1-00$i.png" 1280x800 red || return 1
    _entry "$rec" "2026-01-01T00:00:0$i.000Z" app 1 "verify-a1-00$i.png" local ok
  done
  printf '%s\n' "$rec"
}

_probe() {
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height:format=duration -of csv=p=0 "$1" | paste -sd, -
}

# _dur_ok <probe line> <want seconds> — duration within ± 0.2 s.
_dur_ok() {
  awk -v d="${1##*,}" -v w="$2" 'BEGIN { exit !(d >= w - 0.2 && d <= w + 0.2) }'
}

test_ffmpeg_present() {
  # Render scenarios must run; a host without ffmpeg fails here, loudly.
  "$HAVE_FFMPEG" || {
    echo "  ffmpeg and ffprobe are required for the render tests" >&2
    return 1
  }
}

test_clip_renders() {
  "$HAVE_FFMPEG" || return 1
  local root rec out p before after log
  root=$(_root render1)
  rec=$(_real_ticket "$root" CRE-12 5) || return 1
  log="$WORK/render1-pipeline.log"
  printf 'x|META|record|info|on\nx|META|outcome|info|completed: ok\n' >"$log"
  before=$(cd "$rec" && sha256sum ./*.png manifest.jsonl "$log")
  out=$(REPOS_ROOT="$root" RECORD_ALLOWED=local TAP_LOG="$log" LOG_FILE="$log" bash "$STITCH" clip CRE-12) || return 1
  after=$(cd "$rec" && sha256sum ./*.png manifest.jsonl "$log")
  [ "$out" = "$(realpath "$rec")/CRE-12-verify.mp4" ] && [ -s "$out" ] || return 1
  p=$(_probe "$out")
  [ "${p%,*}" = "h264,1280,800" ] && _dur_ok "$p" 7.5 || {
    echo "  probe: $p" >&2
    return 1
  }
  # Inputs and the pipeline log untouched; no temp files left beside them.
  [ "$before" = "$after" ] &&
    [ "$(find "$rec" -mindepth 1 | wc -l)" -eq 7 ] || return 1
  # Re-running replaces only the output.
  out=$(REPOS_ROOT="$root" RECORD_ALLOWED=local bash "$STITCH" clip CRE-12) || return 1
  [ "$(find "$rec" -mindepth 1 | wc -l)" -eq 7 ]
}

test_video_renders_mixed_sizes() {
  "$HAVE_FFMPEG" || return 1
  local root rec out p rgb
  root=$(_root render2)
  rec=$(_real_ticket "$root" CRE-12 2) || return 1
  _png "$rec/board-7-human-approved.png" 400x900 blue || return 1
  _entry "$rec" "2026-01-01T00:00:01.500Z" board - board-7-human-approved.png - ok
  out=$(cd "$WORK" && REPOS_ROOT="$root" RECORD_ALLOWED=local bash "$STITCH" video CRE-12) || return 1
  [ "$out" = "./recording-CRE-12.mp4" ] && [ -s "$WORK/recording-CRE-12.mp4" ] || return 1
  p=$(_probe "$WORK/recording-CRE-12.mp4")
  # title 2 + app 1.5 + board 2 + app 1.5
  [ "${p%,*}" = "h264,1280,800" ] && _dur_ok "$p" 7 || {
    echo "  probe: $p" >&2
    return 1
  }
  # The narrower board frame is really in the video (centre pixel at 4.5 s is
  # blue), padded, not dropped.
  rgb=$(ffmpeg -nostdin -loglevel error -i "$WORK/recording-CRE-12.mp4" \
    -vf "select='gte(t,4.5)',crop=2:2:639:399" -frames:v 1 -f rawvideo -pix_fmt rgb24 - |
    od -An -tu1 -N3 | tr -s ' ')
  read -r r g b <<<"$rgb"
  [ "$b" -gt 200 ] && [ "$r" -lt 60 ] || {
    echo "  centre pixel at 4.5s: $rgb" >&2
    return 1
  }
}

test_video_out_flag_and_multi_default_name() {
  "$HAVE_FFMPEG" || return 1
  local root out
  root=$(_root render3)
  _real_ticket "$root" CRE-12 1 >/dev/null || return 1
  _real_ticket "$root" CRE-13 1 >/dev/null || return 1
  mkdir -p "$WORK/out dir"
  out=$(REPOS_ROOT="$root" RECORD_ALLOWED=local bash "$STITCH" video --out "$WORK/out dir/demo.mp4" CRE-12 CRE-13) || return 1
  [ "$out" = "$WORK/out dir/demo.mp4" ] && _dur_ok "$(_probe "$out")" 7 || return 1
  mkdir -p "$WORK/cwd3"
  out=$(cd "$WORK/cwd3" && REPOS_ROOT="$root" RECORD_ALLOWED=local bash "$STITCH" video CRE-12 CRE-13) || return 1
  [ "$out" = "./recording-CRE-12-plus1.mp4" ] && [ -s "$WORK/cwd3/recording-CRE-12-plus1.mp4" ]
}

test_render_plan_file() {
  "$HAVE_FFMPEG" || return 1
  local root out
  root=$(_root render4)
  _real_ticket "$root" CRE-12 2 >/dev/null || return 1
  REPOS_ROOT="$root" RECORD_ALLOWED=local bash "$STITCH" plan clip CRE-12 >"$WORK/render4.plan" || return 1
  bash "$STITCH" render "$WORK/render4.plan" "$WORK/render4.mp4" || return 1
  _dur_ok "$(_probe "$WORK/render4.mp4")" 3
}

test_empty_plan_writes_nothing() {
  local root rec rc=0 out
  root=$(_root empty1)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 - local skipped
  out=$(REPOS_ROOT="$root" RECORD_ALLOWED=local bash "$STITCH" clip CRE-12 2>/dev/null) || rc=$?
  [ "$rc" -eq 3 ] && [ -z "$out" ] && [ ! -e "$rec/CRE-12-verify.mp4" ] || return 1
  rc=0
  out=$(cd "$WORK" && REPOS_ROOT="$root" RECORD_ALLOWED=local bash "$STITCH" video --out "$WORK/empty1.mp4" CRE-12 2>/dev/null) || rc=$?
  [ "$rc" -eq 3 ] && [ -z "$out" ] && [ ! -e "$WORK/empty1.mp4" ] || return 1
  rc=0
  echo "ffconcat version 1.0" >"$WORK/empty1.plan"
  bash "$STITCH" render "$WORK/empty1.plan" "$WORK/empty1b.mp4" 2>/dev/null || rc=$?
  [ "$rc" -eq 3 ] && [ ! -e "$WORK/empty1b.mp4" ]
}

test_no_ffmpeg_writes_nothing() {
  local root rec rc=0 out
  root=$(_root noff1)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  out=$(REPOS_ROOT="$root" RECORD_ALLOWED=local PATH="$NOFF_BIN" bash "$STITCH" clip CRE-12 2>"$WORK/noff1.err") || rc=$?
  [ "$rc" -eq 4 ] && [ -z "$out" ] && [ ! -e "$rec/CRE-12-verify.mp4" ] &&
    grep -q 'ffmpeg is not installed' "$WORK/noff1.err" || return 1
  # The planner still works without ffmpeg.
  out=$(REPOS_ROOT="$root" RECORD_ALLOWED=local PATH="$NOFF_BIN" bash "$STITCH" plan clip CRE-12) || return 1
  [ "$(_files <<<"$out")" = "verify-a1-001.png" ]
}

test_failed_ffmpeg_keeps_old_output() {
  local root rec rc=0 out
  root=$(_root ffail1)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  echo "old video" >"$rec/CRE-12-verify.mp4"
  out=$(REPOS_ROOT="$root" RECORD_ALLOWED=local PATH="$TRIP_BIN:$REAL_PATH" TMPDIR="$WORK/ffail1-tmp" \
    bash -c 'mkdir -p "$TMPDIR" && bash "$0" clip CRE-12' "$STITCH" 2>/dev/null) || rc=$?
  [ "$rc" -eq 5 ] && [ -z "$out" ] &&
    [ "$(cat "$rec/CRE-12-verify.mp4")" = "old video" ] &&
    [ -z "$(ls -A "$WORK/ffail1-tmp")" ]
}

test_render_refuses_foreign_files() {
  local root rec rc=0
  root=$(_root foreign1)
  rec=$(_ticket "$root" CRE-12 "Total")
  echo secret >"$root/secret.png"
  echo x >"$rec/notes.png"
  for f in "$root/secret.png" "$rec/notes.png" "$rec/../verify-a1-001.png"; do
    rc=0
    printf "ffconcat version 1.0\nfile '%s'\nduration 1.5\n" "$f" >"$WORK/foreign1.plan"
    PATH="$TRIP_BIN:$REAL_PATH" bash "$STITCH" render "$WORK/foreign1.plan" "$WORK/foreign1.mp4" 2>/dev/null || rc=$?
    [ "$rc" -eq 3 ] && [ ! -e "$WORK/foreign1.mp4" ] || return 1
  done
  rc=0
  printf "ffconcat version 1.0\noption safe 0\nfile '%s'\n" "$rec/x" >"$WORK/foreign1.plan"
  PATH="$TRIP_BIN:$REAL_PATH" bash "$STITCH" render "$WORK/foreign1.plan" "$WORK/foreign1.mp4" 2>/dev/null || rc=$?
  [ "$rc" -eq 3 ] && [ ! -e "$WORK/foreign1.mp4" ]
}

test_usage_errors() {
  local rc=0
  bash "$STITCH" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || return 1
  rc=0
  bash "$STITCH" video --out 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || return 1
  rc=0
  bash "$STITCH" plan video --order sideways CRE-12 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || return 1
  rc=0
  bash "$STITCH" clip 'CRE-12/..' 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ]
}

test_sourcing_sets_no_options() {
  local before after
  before=$(bash -c 'echo "$-"; shopt -po')
  after=$(bash -c 'source "$1"; echo "$-"; shopt -po' _ "$STITCH")
  [ "$before" = "$after" ]
}

# ── render: overlay and --anim (record-stitch-overlay) ───────────────────────

test_overlay_formatting() {
  # shellcheck disable=SC1090
  (
    source "$STITCH"
    [ "$(_rs_fmt_num 4376752)" = "4.38M" ] &&
      [ "$(_rs_fmt_num 23244)" = "23.2K" ] &&
      [ "$(_rs_fmt_num 999)" = "999" ] &&
      [ "$(_rs_fmt_num 0)" = "0" ] &&
      [ "$(_rs_fmt_num 1000)" = "1.00K" ] &&
      [ "$(_rs_fmt_num 999999)" = "1.00M" ] &&
      [ "$(_rs_fmt_num 123456789012)" = "123B" ] &&
      [ "$(_rs_fmt_time 4325)" = "01:12:05" ] &&
      [ "$(_rs_fmt_time 0)" = "00:00:00" ] &&
      [ "$(_rs_fmt_time 360061)" = "100:01:01" ]
  )
}

# _ov_ticket <root> <TID> <frames> — real frames plus a pipeline log with one
# agent open over all of them; prints the recordings dir.
_ov_ticket() {
  local rec
  rec=$(_real_ticket "$1" "$2" "$3") || return 1
  _log "$1/logs" "$2" "2025-12-31T23:00:00Z|META|autonomy|info|auto" \
    "2025-12-31T23:50:00Z|IMPLEMENT|implement|waiting|Agent launched — i" \
    "2025-12-31T23:55:00Z|META|tokens|info|IMPLEMENT:84/23244/4353424" \
    "2026-01-01T01:00:00Z|IMPLEMENT|implement|done|ok"
  printf '%s\n' "$rec"
}

# _rgb_at <video> <t> <x> <y> — the top-left pixel of the 2×2 block there,
# as rgb24 hex (a 1×1 crop does not survive yuv420p).
_rgb_at() {
  ffmpeg -nostdin -loglevel error -ss "$2" -i "$1" -vf "crop=2:2:$3:$4" \
    -frames:v 1 -f rawvideo -pix_fmt rgb24 - 2>/dev/null | od -An -tx1 | tr -d ' \n' | cut -c1-6
}

# _not_red <hex rgb> — clearly not the red test frame (false on no pixel).
_not_red() {
  [[ "$1" =~ ^[0-9a-f]{6}$ ]] || return 1
  local r=$((16#${1:0:2})) g=$((16#${1:2:2}))
  [ "$r" -lt 160 ] || [ "$g" -gt 90 ]
}

test_overlay_clip_renders() {
  "$HAVE_FFMPEG" || return 1
  local root rec out p
  root=$(_root ovr1)
  rec=$(_ov_ticket "$root" CRE-12 5) || return 1
  out=$(REPOS_ROOT="$root" RECORD_ALLOWED=local FLEET_PIPELINE_LOG_DIR="$root/logs" \
    bash "$STITCH" clip CRE-12) || return 1
  p=$(_probe "$out")
  [ "${p%,*}" = "h264,1280,800" ] && _dur_ok "$p" 7.5 || {
    echo "  probe: $p" >&2
    return 1
  }
  # The text box sits at the top right; the frame is red everywhere else.
  local corner centre
  corner=$(_rgb_at "$out" 1 1250 30)
  centre=$(_rgb_at "$out" 1 640 400)
  [[ "$centre" =~ ^[0-9a-f]{6}$ ]] && _not_red "$corner" && ! _not_red "$centre"
}

test_overlay_malformed_refused() {
  local root rec rc=0
  root=$(_root ovr2)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  printf "ffconcat version 1.0\nfile '%s'\n#overlay 12 x 3 1 normal\nduration 1.5\n" \
    "$(realpath "$rec")/verify-a1-001.png" >"$WORK/ovr2.plan"
  bash "$STITCH" render "$WORK/ovr2.plan" "$WORK/ovr2.mp4" 2>/dev/null || rc=$?
  [ "$rc" -eq 3 ] && [ ! -e "$WORK/ovr2.mp4" ] || return 1
  rc=0
  printf "ffconcat version 1.0\nfile '%s'\n#overlay 1 2 3 1 sleepy\nduration 1.5\n" \
    "$(realpath "$rec")/verify-a1-001.png" >"$WORK/ovr2.plan"
  bash "$STITCH" render "$WORK/ovr2.plan" "$WORK/ovr2.mp4" 2>/dev/null || rc=$?
  [ "$rc" -eq 3 ] && [ ! -e "$WORK/ovr2.mp4" ]
}

test_overlay_without_drawtext() {
  "$HAVE_FFMPEG" || return 1
  local root out err bin="$WORK/nodt-bin"
  mkdir -p "$bin"
  cat >"$bin/ffmpeg" <<EOF
#!/usr/bin/env bash
case "\$*" in *drawtext*) exit 1 ;; esac
exec "$(command -v ffmpeg)" "\$@"
EOF
  chmod +x "$bin/ffmpeg"
  root=$(_root ovr3)
  _ov_ticket "$root" CRE-12 3 >/dev/null || return 1
  out=$(REPOS_ROOT="$root" RECORD_ALLOWED=local FLEET_PIPELINE_LOG_DIR="$root/logs" \
    PATH="$bin:$REAL_PATH" bash "$STITCH" clip CRE-12 2>"$WORK/ovr3.err") || return 1
  err=$(cat "$WORK/ovr3.err")
  [ -s "$out" ] &&
    [ "$(grep -c 'drawtext unavailable; overlay skipped' <<<"$err")" -eq 1 ]
}

test_anim_video_renders() {
  "$HAVE_FFMPEG" || return 1
  local root out p
  root=$(_root ovr4)
  _ov_ticket "$root" CRE-12 4 >/dev/null || return 1
  out=$(cd "$WORK" && REPOS_ROOT="$root" RECORD_ALLOWED=local FLEET_PIPELINE_LOG_DIR="$root/logs" \
    bash "$STITCH" video --anim --out "$WORK/ovr4.mp4" CRE-12) || return 1
  p=$(_probe "$WORK/ovr4.mp4")
  # title 2 + 4 × 1.5
  [ "${p%,*}" = "h264,1280,800" ] && _dur_ok "$p" 8 || {
    echo "  probe: $p" >&2
    return 1
  }
  # Somewhere in the 192×192 corner at the bottom left the sprite is drawn
  # over the red frame.
  local x y hit=false
  for x in 60 100 140 180; do
    for y in 620 660 700 740; do
      _not_red "$(_rgb_at "$WORK/ovr4.mp4" 3 "$x" "$y")" && hit=true
    done
  done
  "$hit"
}

test_anim_missing_sprite() {
  local root rec rc=0 copy="$WORK/libcopy" err
  cp -r "$LIB_DIR" "$copy"
  rm -f "$copy/record-assets/coder-idle-03.png"
  root=$(_root ovr5)
  rec=$(_ticket "$root" CRE-12 "Total")
  _entry "$rec" "2026-01-01T00:00:01.000Z" app 1 verify-a1-001.png local ok
  REPOS_ROOT="$root" RECORD_ALLOWED=local bash "$copy/record-stitch.sh" video --anim \
    --out "$WORK/ovr5.mp4" CRE-12 >/dev/null 2>"$WORK/ovr5.err" || rc=$?
  err=$(cat "$WORK/ovr5.err")
  rm -rf "$copy"
  [ "$rc" -eq 3 ] && [ ! -e "$WORK/ovr5.mp4" ] && grep -q 'coder-idle-03.png' <<<"$err"
}

test_no_anim_draws_no_sprite() {
  "$HAVE_FFMPEG" || return 1
  local root bin="$WORK/argv-bin"
  mkdir -p "$bin"
  cat >"$bin/ffmpeg" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$WORK/argv.log"
exec "$(command -v ffmpeg)" "\$@"
EOF
  chmod +x "$bin/ffmpeg"
  root=$(_root ovr6)
  _ov_ticket "$root" CRE-12 2 >/dev/null || return 1
  REPOS_ROOT="$root" RECORD_ALLOWED=local FLEET_PIPELINE_LOG_DIR="$root/logs" \
    PATH="$bin:$REAL_PATH" bash "$STITCH" video --out "$WORK/ovr6.mp4" CRE-12 >/dev/null || return 1
  [ -s "$WORK/argv.log" ] && ! grep -q 'coder-' "$WORK/argv.log"
}

# ── the skill ─────────────────────────────────────────────────────────────────

test_skill_text() {
  grep -q '^name: ticket-record-stitch$' "$SKILL_MD" &&
    grep -q 'bash ~/.claude/skills/lib/record-stitch.sh video' "$SKILL_MD" &&
    grep -q 'bash ~/.claude/skills/lib/record-stitch.sh clip' "$SKILL_MD" &&
    ! grep -q 'ticket-preamble.sh' "$SKILL_MD" &&
    ! grep -q 'skill-preamble' "$SKILL_MD" &&
    ! grep -q 'CLAUDE_PLUGIN_ROOT' "$SKILL_MD"
}

test_skill_exit_table_matches_script() {
  local code
  for code in 2 3 4 5; do
    grep -qE "^\| $code \|" "$SKILL_MD" || return 1
    grep -qE "^#   $code  " "$STITCH" || return 1
  done
}

for t in \
  test_clip_latest_attempt \
  test_clip_paths_are_absolute_and_real \
  test_failed_and_skipped_left_out \
  test_env_rechecked \
  test_env_uat_needs_synthetic_now \
  test_nothing_allowed_plans_nothing \
  test_allowed_read_from_claude_md \
  test_video_order_and_durations \
  test_video_drops_earlier_verify_attempts \
  test_latest_attempt_with_no_frames_is_empty \
  test_rerun_is_byte_identical \
  test_traversal_refused \
  test_name_whitelist \
  test_symlink_refused \
  test_symlinked_recordings_dir_refused \
  test_bad_id_refused \
  test_torn_line_tolerated \
  test_nothing_globbed \
  test_missing_ticket_and_manifest \
  test_no_repos_root \
  test_multi_ticket_order \
  test_title_is_one_plain_line \
  test_planner_never_runs_ffmpeg \
  test_overlay_elapsed \
  test_overlay_tokens_summed \
  test_overlay_malformed_tokens_skipped \
  test_overlay_no_log_matches_no_overlay \
  test_overlay_title_card_has_none \
  test_overlay_deterministic_read_only \
  test_overlay_one_agent \
  test_overlay_parallel_tickets \
  test_overlay_unclosed_and_retry \
  test_overlay_tiers \
  test_overlay_bad_threshold \
  test_overlay_option_errors \
  test_ffmpeg_present \
  test_clip_renders \
  test_video_renders_mixed_sizes \
  test_video_out_flag_and_multi_default_name \
  test_render_plan_file \
  test_empty_plan_writes_nothing \
  test_no_ffmpeg_writes_nothing \
  test_failed_ffmpeg_keeps_old_output \
  test_render_refuses_foreign_files \
  test_usage_errors \
  test_sourcing_sets_no_options \
  test_overlay_formatting \
  test_overlay_clip_renders \
  test_overlay_malformed_refused \
  test_overlay_without_drawtext \
  test_anim_video_renders \
  test_anim_missing_sprite \
  test_no_anim_draws_no_sprite \
  test_skill_text \
  test_skill_exit_table_matches_script; do
  _run "$t" "$t"
done

echo ""
echo "test-record-stitch.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
