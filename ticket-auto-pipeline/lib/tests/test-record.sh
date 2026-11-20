#!/usr/bin/env bash
# test-record.sh — tests for lib/record.sh and the preamble's recording flag
# (openspec change ticket-auto-record, PR 1).
#
# Covers the ticket-run-recording scenarios that do not need the VERIFY
# reference (that is PR 2), the router-preamble-manual-mode RECORD scenarios
# and the "recorder missing from FLEET_BOARD_DRIVERS" warning. Linear is
# never called: preflight is skipped and branch resolution is stubbed, as in
# test-ticket-preamble.sh.
# -u (nounset) intentionally omitted — see test-detect-resume.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RECORD_SH="$LIB_DIR/record.sh"

TICKET_TMP_DIR=$(mktemp -d)
export TICKET_TMP_DIR
WORK=$(mktemp -d)
trap 'rm -rf "$TICKET_TMP_DIR" "$WORK"' EXIT

# Never let an operator's settings reach the code under test.
unset REPOS_ROOT FLEET_PIPELINE_LOG_DIR TAP_LOG LOG_FILE LOCAL_URL UAT_URL \
  RECORD_ALLOWED RECORD_UAT_SYNTHETIC RECORD_BOARD_URL RECORD_DISABLE \
  TICKET_RECORD FLEET_BOARD_DRIVERS TICKET_AUTONOMY

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

_field() {
  echo "$1" | grep "^  ${2}:" | sed -E "s/^  ${2}: *//"
}

# ── record_enabled / record_allowed_parse ─────────────────────────────────────

_lib() { (source "$RECORD_SH" && "$@"); }

test_enabled_reads_the_line() {
  local log="$WORK/en.log"
  printf 'x|META|schema|info|1\nx|META|record|info|on\n' >"$log"
  _lib record_enabled "$log"
}

test_enabled_off_switch() {
  local log="$WORK/en2.log"
  printf 'x|META|record|info|on\n' >"$log"
  ! RECORD_DISABLE=true _lib record_enabled "$log"
}

test_enabled_no_line_no_record() {
  local log="$WORK/en3.log"
  printf 'x|META|schema|info|1\n' >"$log"
  ! _lib record_enabled "$log" && ! _lib record_enabled "$WORK/missing.log"
}

test_cli_enabled() {
  local log="$WORK/en4.log"
  printf 'x|META|record|info|on\n' >"$log"
  bash "$RECORD_SH" enabled "$log"
}

test_allowed_parse_trims_and_folds() {
  [ "$(_lib record_allowed_parse " Local , UAT,local" true | tr '\n' ,)" = "local,uat," ]
}

test_allowed_unknown_name_invalidates() {
  [ -z "$(_lib record_allowed_parse "local, staging" true)" ]
}

test_allowed_empty_is_invalid() {
  [ -z "$(_lib record_allowed_parse "" true)" ] && [ -z "$(_lib record_allowed_parse " , " true)" ]
}

test_uat_needs_synthetic() {
  local err
  err=$(_lib record_allowed_parse "uat,local" "" 2>&1 >/dev/null)
  [ "$(_lib record_allowed_parse "uat,local" "" 2>/dev/null)" = "local" ] &&
    grep -q RECORD_UAT_SYNTHETIC <<<"$err" &&
    ! RECORD_ALLOWED=uat _lib record_env_allowed uat 2>/dev/null &&
    RECORD_ALLOWED=uat RECORD_UAT_SYNTHETIC=true _lib record_env_allowed uat
}

test_field_env_then_claude_md() {
  local root="$WORK/fieldroot"
  mkdir -p "$root"
  printf 'RECORD_ALLOWED = local\nRECORD_BOARD_URL: `https://linear.app/x/view/y`\n' >"$root/CLAUDE.md"
  [ "$(REPOS_ROOT=$root _lib record_field RECORD_ALLOWED)" = "local" ] &&
    [ "$(REPOS_ROOT=$root RECORD_ALLOWED=uat _lib record_field RECORD_ALLOWED)" = "uat" ] &&
    [ "$(REPOS_ROOT=$root _lib record_field RECORD_BOARD_URL)" = "https://linear.app/x/view/y" ]
}

test_url_env_maps_origins() {
  export LOCAL_URL=http://localhost:4200/app UAT_URL=https://uat.example.com:443
  local a b c d
  a=$(_lib record_url_env http://LOCALHOST:4200/x)
  b=$(_lib record_url_env https://uat.example.com/y?z=1)
  c=$(_lib record_url_env https://example.org/x)
  d=$(_lib record_url_env http://localhost:4201/x)
  unset LOCAL_URL UAT_URL
  [ "$a" = local ] && [ "$b" = uat ] && [ -z "$c" ] && [ -z "$d" ]
}

# ── record.sh append ──────────────────────────────────────────────────────────

# A workspace with one ticket dir and a pipeline log; prints its root.
_ws() {
  local root
  root=$(mktemp -d "$WORK/ws.XXXXXX")
  mkdir -p "$root/CRE-12--demo-ticket" "$root/logs"
  printf 'x|META|schema|info|1\n' >"$root/logs/CRE-12-pipeline.log"
  echo "$root"
}

# _append ROOT URL [STEP] — one append with a fresh source file.
_append() {
  local root="$1" url="$2" step="${3:-step}" src
  src=$(mktemp "$root/src.XXXXXX")
  printf 'PNGDATA' >"$src"
  REPOS_ROOT="$root" TAP_LOG="$root/logs/CRE-12-pipeline.log" \
    LOCAL_URL=http://localhost:4200 UAT_URL=https://uat.example.com \
    RECORD_ALLOWED="${ALLOWED:-local}" \
    bash "$RECORD_SH" append --tid CRE-12 --phase verify --step "$step" --src "$src" --url "$url"
}

_rec() { echo "$1/CRE-12--demo-ticket/artifacts/recordings"; }

test_local_page_recorded() {
  local root out1 out2 rec
  root=$(_ws)
  out1=$(_append "$root" http://localhost:4200/a "first")
  out2=$(_append "$root" http://localhost:4200/b "second")
  rec=$(_rec "$root")
  [ "$out1" = "ok verify-a1-001.png" ] && [ "$out2" = "ok verify-a1-002.png" ] &&
    [ -f "$rec/verify-a1-001.png" ] && [ -f "$rec/verify-a1-002.png" ] &&
    [ "$(jq -s 'map(select(.source=="app" and .status=="ok" and .env=="local")) | length' "$rec/manifest.jsonl")" = 2 ] &&
    [ "$(jq -s '.[0] | keys | sort | join(",")' -r "$rec/manifest.jsonl")" = \
      "attempt,column,env,event,file,phase,reason,seq,source,status,step,tid,ts" ] &&
    [ "$(jq -rs '.[1].step' "$rec/manifest.jsonl")" = "second" ]
}

test_uat_page_not_recorded() {
  local root out rec
  root=$(_ws)
  out=$(_append "$root" https://uat.example.com/a)
  rec=$(_rec "$root")
  [ "$out" = "skipped env-not-recordable" ] &&
    [ -z "$(find "$rec" -name '*.png')" ] &&
    [ "$(wc -l <"$rec/manifest.jsonl")" -eq 1 ] &&
    jq -e '.status=="skipped" and .reason=="env-not-recordable" and .file==null' "$rec/manifest.jsonl" >/dev/null &&
    [ -z "$(find "$root" -maxdepth 1 -name 'src.*')" ] # source discarded
}

test_uat_recorded_when_allowed_and_synthetic() {
  local root out
  root=$(_ws)
  out=$(ALLOWED=uat RECORD_UAT_SYNTHETIC=true _append "$root" https://uat.example.com/a)
  [ "$out" = "ok verify-a1-001.png" ] &&
    jq -e '.env=="uat"' "$(_rec "$root")/manifest.jsonl" >/dev/null
}

test_unknown_origin_not_recorded() {
  local root out rec
  root=$(_ws)
  out=$(_append "$root" https://example.org/x)
  rec=$(_rec "$root")
  [ "$out" = "skipped env-not-recordable" ] && [ -z "$(find "$rec" -name '*.png')" ] &&
    jq -e '.status=="skipped" and .env==null' "$rec/manifest.jsonl" >/dev/null
}

test_retry_frames_separated() {
  local root out
  root=$(_ws)
  _append "$root" http://localhost:4200/a >/dev/null
  printf 'x|VERIFY|verify|waiting|spawn\nx|VERIFY|verify|fail|criterion 2\nx|IMPLEMENT|implement|done|fix\n' \
    >>"$root/logs/CRE-12-pipeline.log"
  out=$(_append "$root" http://localhost:4200/a)
  [ "$out" = "ok verify-a2-001.png" ] &&
    [ "$(jq -s '.[1].attempt' "$(_rec "$root")/manifest.jsonl")" = 2 ]
}

# A crash close the orchestrator recorded does not end the attempt, and an
# operator reset never makes attempt numbers go backwards.
test_attempt_ignores_resets() {
  local root log out
  root=$(_ws)
  log="$root/logs/CRE-12-pipeline.log"
  printf 'x|VERIFY|verify|fail|a\nx|IMPLEMENT|implement|done|fix\n' >>"$log"
  printf 'reset|%s|x|operator\n' "$(wc -l <"$log")" >"$log.verify-ctl"
  out=$(_append "$root" http://localhost:4200/a)
  [ "$out" = "ok verify-a2-001.png" ]
}

test_failed_append_leaves_log_alone() {
  local root log before out rc=0
  root=$(_ws)
  log="$root/logs/CRE-12-pipeline.log"
  printf 'x|META|record|info|on\n' >>"$log"
  before=$(wc -l <"$log")
  out=$(REPOS_ROOT="$root" TAP_LOG="$log" LOCAL_URL=http://localhost:4200 RECORD_ALLOWED=local \
    bash "$RECORD_SH" append --tid CRE-12 --phase verify --step s --src "$root/nope.png" \
    --url http://localhost:4200/) || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "fail src-missing" ] &&
    [ "$(wc -l <"$log")" -eq "$before" ] &&
    [ "$(grep -c '|META|record' "$log")" -eq 1 ] &&
    jq -e '.status=="fail" and .reason=="src-missing"' "$(_rec "$root")/manifest.jsonl" >/dev/null
}

test_argument_errors_exit_2() {
  local rc1=0 rc2=0 rc3=0 rc4=0
  bash "$RECORD_SH" append --tid CRE-12 --phase verify 2>/dev/null || rc1=$?
  bash "$RECORD_SH" append --tid ../x --phase verify --step s --src a --url b 2>/dev/null || rc2=$?
  bash "$RECORD_SH" append --tid CRE-12 --phase ../v --step s --src a --url b 2>/dev/null || rc3=$?
  bash "$RECORD_SH" append --bogus 2>/dev/null || rc4=$?
  [ "$rc1" -eq 2 ] && [ "$rc2" -eq 2 ] && [ "$rc3" -eq 2 ] && [ "$rc4" -eq 2 ]
}

test_no_workspace_is_not_an_error() {
  local rc=0 out
  out=$(REPOS_ROOT="$WORK/nowhere" bash "$RECORD_SH" append --tid CRE-99 --phase verify \
    --step s --src /dev/null --url http://localhost/) || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "fail no-ticket-dir" ]
}

test_concurrent_appends() {
  local root rec i
  root=$(_ws)
  for i in $(seq 1 20); do
    _append "$root" http://localhost:4200/c "step $i" >/dev/null &
  done
  wait
  rec=$(_rec "$root")
  [ "$(wc -l <"$rec/manifest.jsonl")" -eq 20 ] &&
    [ "$(jq -c . "$rec/manifest.jsonl" 2>/dev/null | wc -l)" -eq 20 ] &&
    [ "$(find "$rec" -name 'verify-a1-*.png' | wc -l)" -eq 20 ] &&
    [ -f "$rec/verify-a1-020.png" ] &&
    [ "$(jq -r .file "$rec/manifest.jsonl" | sort -u | wc -l)" -eq 20 ]
}

# A crash mid-write leaves a torn last line: the next entry still lands on a
# line of its own, and a tolerant reader gets every whole entry.
test_torn_line_tolerated() {
  local root rec
  root=$(_ws)
  _append "$root" http://localhost:4200/a >/dev/null
  rec=$(_rec "$root")
  printf '{"ts":"2026-01-01T00:00:00Z","tid":"CRE-12","sour' >>"$rec/manifest.jsonl"
  _append "$root" http://localhost:4200/b >/dev/null
  [ "$(jq -cR 'fromjson? // empty' "$rec/manifest.jsonl" | wc -l)" -eq 2 ] &&
    [ "$(tail -1 "$rec/manifest.jsonl" | jq -r .file)" = "verify-a1-002.png" ]
}

test_append_entry_rejects_non_json() {
  local dir="$WORK/entries"
  _lib record_append_entry "$dir" 'not json' 2>/dev/null
  _lib record_append_entry "$dir" '{"a":1}'
  [ "$(wc -l <"$dir/manifest.jsonl")" -eq 1 ] && [ -f "$dir/.manifest.lock" ]
}

# ── Preamble: --record, RECORD=, TICKET_RECORD ────────────────────────────────

_sandbox_new() {
  _SANDBOX="$(mktemp -d "$WORK/sb.XXXXXX")"
  mkdir -p "$_SANDBOX/lib" "$_SANDBOX/logs"
  cp "$LIB_DIR"/*.sh "$_SANDBOX/lib/"
  cat >"$_SANDBOX/lib/branch-resolve.sh" <<'STUB'
#!/usr/bin/env bash
resolve_branch_context() {
  cat <<'BLOCK'
BRANCH_CONTEXT_RESULT:
  TICKET_BRANCH: feat/rec-1
  BASE_BRANCH: develop
  INTEGRATION_BRANCH: develop
  BRANCH_SOURCE: default
  UAT_POLICY: per-ticket
  MERGE_POLICY:
BLOCK
}
STUB
}

# _pre ARGS... — runs the preamble in the sandbox; stdout block, stderr to
# $_SANDBOX/err.
_pre() {
  (cd "$_SANDBOX" && bash "$_SANDBOX/lib/ticket-preamble.sh" \
    PROJECT_DIR="$_SANDBOX" SKIP_PREFLIGHT=true "$@" 2>"$_SANDBOX/err")
}

_log() { echo "$_SANDBOX/logs/${1}-pipeline.log"; }

test_flag_writes_the_record_once() {
  _sandbox_new
  local out1 out2
  out1=$(RECORD_ALLOWED=local _pre TICKET_ARG="REC-1 --record")
  out2=$(RECORD_ALLOWED=local _pre TICKET_ARG="REC-1 --record")
  [ "$(grep -c '|META|record|info|on$' "$(_log REC-1)")" -eq 1 ] &&
    [ "$(_field "$out1" RECORD)" = "true" ] && [ "$(_field "$out2" RECORD)" = "true" ]
}

test_flag_stripped_and_reported() {
  _sandbox_new
  printf 'RECORD_ALLOWED = local\n' >"$_SANDBOX/CLAUDE.md"
  local out
  out=$(_pre TICKET_ARG="REC-2 --record --auto")
  [ "$(_field "$out" TICKET_ID)" = "REC-2" ] && [ "$(_field "$out" RECORD)" = "true" ] &&
    [ "$(_field "$out" AUTONOMY)" = "auto" ]
}

test_resume_without_flag_keeps_recording() {
  _sandbox_new
  RECORD_ALLOWED=local _pre TICKET_ARG="REC-3 --record" >/dev/null
  local out
  out=$(_pre TICKET_ARG="REC-3")
  [ "$(_field "$out" RECORD)" = "true" ] &&
    [ "$(grep -c '|META|record|' "$(_log REC-3)")" -eq 1 ]
}

test_disable_reports_false() {
  _sandbox_new
  RECORD_ALLOWED=local _pre TICKET_ARG="REC-4 --record" >/dev/null
  local out
  out=$(RECORD_DISABLE=true _pre TICKET_ARG="REC-4")
  [ "$(_field "$out" RECORD)" = "false" ]
}

test_no_flag_no_record() {
  _sandbox_new
  local out
  out=$(RECORD_ALLOWED=local _pre TICKET_ID=REC-5)
  [ "$(_field "$out" RECORD)" = "false" ] && ! grep -q '|META|record|' "$(_log REC-5)"
}

test_explicit_flag_refused_without_field() {
  _sandbox_new
  local rc=0 out
  out=$(_pre TICKET_ARG="REC-6 --record") || rc=$?
  [ "$rc" -eq 1 ] && grep -q RECORD_ALLOWED "$_SANDBOX/err" &&
    ! grep -q TICKET_PREAMBLE_RESULT <<<"$out" &&
    [ ! -e "$(_log REC-6)" ] && [ ! -e "$_SANDBOX/logs/REC-6-heartbeat.log" ]
}

test_unknown_name_refused() {
  _sandbox_new
  local rc=0
  RECORD_ALLOWED="local, staging" _pre TICKET_ARG="REC-7 --record" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] && [ ! -e "$(_log REC-7)" ]
}

test_explicit_record_key_accepted() {
  _sandbox_new
  local rc=0 out
  out=$(RECORD_ALLOWED=local _pre TICKET_ID=REC-8 RECORD=true) || rc=$?
  [ "$rc" -eq 0 ] && [ "$(_field "$out" RECORD)" = "true" ]
}

# An explicit RECORD=false wins over the fleet-wide default.
test_explicit_record_false_wins_over_env() {
  _sandbox_new
  local out
  out=$(TICKET_RECORD=true RECORD_ALLOWED=local _pre TICKET_ID=REC-9 RECORD=false)
  [ "$(_field "$out" RECORD)" = "false" ] && ! grep -q '|META|record|' "$(_log REC-9)"
}

test_env_fallback_only_warns() {
  _sandbox_new
  local rc=0 out
  out=$(TICKET_RECORD=true _pre TICKET_ID=REC-10) || rc=$?
  [ "$rc" -eq 0 ] && grep -q 'warning.*RECORD_ALLOWED' "$_SANDBOX/err" &&
    ! grep -q '|META|record|' "$(_log REC-10)" && [ "$(_field "$out" RECORD)" = "false" ]
}

test_env_fallback_turns_on() {
  _sandbox_new
  local out
  out=$(TICKET_RECORD=true RECORD_ALLOWED=local _pre TICKET_ID=REC-11)
  [ "$(_field "$out" RECORD)" = "true" ] && grep -q '|META|record|info|on$' "$(_log REC-11)"
}

test_env_file_carries_record_fields() {
  _sandbox_new
  printf 'RECORD_ALLOWED = local\nRECORD_BOARD_URL = https://linear.app/t/view/demo\n' >"$_SANDBOX/CLAUDE.md"
  _pre TICKET_ID=REC-12 >/dev/null
  local env="$TICKET_TMP_DIR/ticket-auto-REC-12-env.sh"
  grep -qx 'export RECORD_ALLOWED="local"' "$env" &&
    grep -qx 'export RECORD_BOARD_URL="https://linear.app/t/view/demo"' "$env" &&
    grep -qx 'export RECORD_UAT_SYNTHETIC=""' "$env"
}

# The router's resume block rewrites the env file without naming these
# fields; they must come through from the sourced file, not be blanked.
test_spawn_write_env_inherits_record_fields() {
  local env
  (
    source "$LIB_DIR/spawn-helper.sh" >/dev/null 2>&1
    RECORD_ALLOWED=local RECORD_BOARD_URL=https://linear.app/t/view/x \
      spawn_write_env TICKET_ID=REC-13 >/dev/null
  )
  env="$TICKET_TMP_DIR/ticket-auto-REC-13-env.sh"
  grep -qx 'export RECORD_ALLOWED="local"' "$env" &&
    grep -qx 'export RECORD_BOARD_URL="https://linear.app/t/view/x"' "$env"
}

test_warns_when_recorder_missing() {
  _sandbox_new
  RECORD_ALLOWED=local _pre TICKET_ARG="REC-14 --record" >/dev/null
  grep -q 'recorder after linear' "$_SANDBOX/err" || return 1
  RECORD_ALLOWED=local FLEET_BOARD_DRIVERS="recorder,linear" _pre TICKET_ID=REC-14 >/dev/null
  grep -q 'recorder after linear' "$_SANDBOX/err" || return 1
  RECORD_ALLOWED=local FLEET_BOARD_DRIVERS="linear, recorder" _pre TICKET_ID=REC-14 >/dev/null
  ! grep -q 'recorder after linear' "$_SANDBOX/err"
}

test_no_warning_when_not_recording() {
  _sandbox_new
  _pre TICKET_ID=REC-15 >/dev/null
  ! grep -q 'recorder' "$_SANDBOX/err"
}

test_parse_arg_prints_record() {
  local out
  out=$(source "$LIB_DIR/ticket-preamble.sh" && ticket_preamble_parse_arg "CRE-1 --record")
  grep -qx 'RECORD=true' <<<"$out" && grep -qx 'TICKET_ID=CRE-1' <<<"$out" &&
    grep -qx 'RECORD=' <<<"$(source "$LIB_DIR/ticket-preamble.sh" && ticket_preamble_parse_arg "CRE-1")"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  _run "$t" "$t"
done

echo ""
echo "test-record.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
