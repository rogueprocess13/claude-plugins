#!/usr/bin/env bash
# test-log-dir.sh — lib/log-dir.sh and the per-ticket state writers that use it
# (state-root-anchor, review ARCH-5).
#
# Part 1: the resolver, against the shared case table
#         fixtures/log-dir-cases.tsv (also read by fleetd's test_log_dir.py).
# Part 2: the write-once anchor (ticket_log_dir_anchor_write), incl. a race.
# Part 3: strict / legacy modes (ticket_log_dir_or_legacy).
# Part 4: the writers — emit_event, board-cursor.sh, outbox-drain.sh,
#         board-cursor-fastforward.sh, config.sh and flow.sh — run from a
#         directory other than the project dir.
# Part 5: the stray note (META|state-root-stray|warn, once per tid and path).
#
# Every case runs in a fresh mktemp -d tree; nothing is written elsewhere.
# Usage: bash test-log-dir.sh
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
CASES="$TEST_DIR/fixtures/log-dir-cases.tsv"
FLOW_SH="$PLUGIN_DIR/skills/ticket-flow/flow.sh"
DRAIN_SH="$PLUGIN_DIR/skills/ticket-flow/outbox-drain.sh"
FF_SH="$PLUGIN_DIR/skills/ticket-flow/board-cursor-fastforward.sh"

source "$LIB_DIR/log-dir.sh" 2>/dev/null || true

PASS=0
FAIL=0
pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1${2:+ — $2}"
  FAIL=$((FAIL + 1))
}

# Scrub the variables the resolver reads, so the caller's shell never leaks in.
unset FLEET_PIPELINE_LOG_DIR STATE_ROOT_STRICT STATE_ROOT_LOG REPOS_ROOT \
  FLEET_GENERATION FLEET_STATE_DIR FLEET_WORKER_PID LOG_FILE TAP_LOG

_tmp() { mktemp -d "${TMPDIR:-/tmp}/test-log-dir.XXXXXX"; }
_tree() { (cd "$1" && find . | LC_ALL=C sort); }

# ── Part 1: shared case table ───────────────────────────────────────────────

_case_value() { # <raw> <root> -> substituted value
  local v="${1//@ROOT@/$2}"
  printf '%s' "$v"
}

_write_anchor() { # <root> <raw anchor field>
  local root="$1" raw="$2" file="$1/.ticket-auto/log-dir"
  [ "$raw" = "-" ] && return 0
  mkdir -p "$root/.ticket-auto"
  if [ "$raw" = "<empty>" ]; then
    : >"$file"
    return 0
  fi
  local nl=$'\n'
  if [[ "$raw" == "<nonl>"* ]]; then
    raw="${raw#<nonl>}"
    nl=""
  fi
  raw=$(_case_value "$raw" "$root")
  printf '%s%s' "${raw//\\n/$'\n'}" "$nl" >"$file"
}

if [ ! -f "$CASES" ]; then
  fail "case table" "$CASES missing"
else
  rows=0
  while IFS=$'\t' read -r id rr env anchor expect legacy; do
    [ -n "$id" ] || continue
    [[ "$id" == \#* ]] && continue
    rows=$((rows + 1))
    if ! declare -f ticket_log_dir >/dev/null; then
      fail "case $id" "ticket_log_dir missing"
      continue
    fi
    root=$(_tmp)
    _write_anchor "$root" "$anchor"
    want=$(_case_value "$expect" "$root")
    want_legacy=$(_case_value "$legacy" "$root")
    before=$(_tree "$root")
    scratch=$(_tmp)
    got=$(
      cd "$scratch"
      unset REPOS_ROOT FLEET_PIPELINE_LOG_DIR
      [ "$rr" = "set" ] && export REPOS_ROOT="$root"
      case "$env" in
      -) ;;
      "<empty>") export FLEET_PIPELINE_LOG_DIR="" ;;
      *) export FLEET_PIPELINE_LOG_DIR="$(_case_value "$env" "$root")" ;;
      esac
      out=$(ticket_log_dir) || out=UNRESOLVED
      printf '%s' "$out"
    )
    got_legacy=$(
      cd "$scratch"
      unset REPOS_ROOT FLEET_PIPELINE_LOG_DIR STATE_ROOT_STRICT
      [ "$rr" = "set" ] && export REPOS_ROOT="$root"
      case "$env" in
      -) ;;
      "<empty>") export FLEET_PIPELINE_LOG_DIR="" ;;
      *) export FLEET_PIPELINE_LOG_DIR="$(_case_value "$env" "$root")" ;;
      esac
      ticket_log_dir_or_legacy 2>/dev/null || echo "rc=$?"
    )
    after=$(_tree "$root")
    if [ "$got" != "$want" ]; then
      fail "case $id" "resolve: want '$want' got '$got'"
    elif [ "$got_legacy" != "$want_legacy" ]; then
      fail "case $id" "legacy: want '$want_legacy' got '$got_legacy'"
    elif [ "$before" != "$after" ] || [ -n "$(ls -A "$scratch")" ]; then
      fail "case $id" "resolving created files"
    else
      pass "case $id"
    fi
    rm -rf "$root" "$scratch"
  done <"$CASES"
  if [ "$rows" -ge 10 ]; then pass "case table has $rows rows"; else fail "case table rows" "$rows"; fi
fi

# STATE_ROOT_LOG=1 names the winning step on stderr.
if declare -f ticket_log_dir >/dev/null; then
  root=$(_tmp)
  err=$(REPOS_ROOT="$root" STATE_ROOT_LOG=1 FLEET_PIPELINE_LOG_DIR="$root/x" ticket_log_dir 2>&1 >/dev/null)
  if [[ "$err" == *"env"* ]]; then pass "STATE_ROOT_LOG names the step"; else fail "STATE_ROOT_LOG" "$err"; fi
  err=$(REPOS_ROOT="$root" ticket_log_dir 2>&1 >/dev/null) || true
  if [ -z "$err" ]; then pass "resolver is silent without STATE_ROOT_LOG"; else fail "resolver silent" "$err"; fi
  rm -rf "$root"
else
  fail "STATE_ROOT_LOG" "ticket_log_dir missing"
fi

# ── Part 2: write-once anchor ───────────────────────────────────────────────

for t in absent present relative no_repos_root race; do
  if ! declare -f ticket_log_dir_anchor_write >/dev/null; then
    fail "anchor_write $t" "ticket_log_dir_anchor_write missing"
    continue
  fi
  root=$(_tmp)
  anchor="$root/.ticket-auto/log-dir"
  case "$t" in
  absent)
    out=$(REPOS_ROOT="$root" ticket_log_dir_anchor_write "$root/logs") || out="rc=$?"
    if [ "$out" = "$root/logs" ] && [ "$(cat "$anchor")" = "$root/logs" ] &&
      [ -z "$(find "$root/.ticket-auto" -name 'log-dir.tmp.*')" ]; then
      pass "anchor_write: absent -> written"
    else fail "anchor_write: absent" "out=$out"; fi
    ;;
  present)
    REPOS_ROOT="$root" ticket_log_dir_anchor_write "$root/first" >/dev/null
    out=$(REPOS_ROOT="$root" ticket_log_dir_anchor_write "$root/second") || out="rc=$?"
    if [ "$out" = "$root/first" ] && [ "$(cat "$anchor")" = "$root/first" ]; then
      pass "anchor_write: present -> first value kept and printed"
    else fail "anchor_write: present" "out=$out anchor=$(cat "$anchor")"; fi
    ;;
  relative)
    rc=0
    REPOS_ROOT="$root" ticket_log_dir_anchor_write "logs" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 2 ] && [ ! -e "$anchor" ]; then
      pass "anchor_write: relative path refused (rc 2), nothing written"
    else fail "anchor_write: relative" "rc=$rc"; fi
    ;;
  no_repos_root)
    rc=0
    (unset REPOS_ROOT && ticket_log_dir_anchor_write "$root/logs" >/dev/null 2>&1) || rc=$?
    if [ "$rc" -eq 2 ]; then pass "anchor_write: REPOS_ROOT unset refused (rc 2)"; else fail "anchor_write: no REPOS_ROOT" "rc=$rc"; fi
    ;;
  race)
    outs="$root/outs"
    mkdir -p "$outs"
    pids=()
    for i in $(seq 1 12); do
      (REPOS_ROOT="$root" ticket_log_dir_anchor_write "$root/w$i" >"$outs/$i" 2>/dev/null) &
      pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || true; done
    value=$(cat "$anchor" 2>/dev/null || true)
    distinct=$(sort -u "$outs"/* | wc -l | tr -d ' ')
    lines=$(wc -l <"$anchor" | tr -d ' ')
    if [[ "$value" == "$root"/w* ]] && [ "$lines" -eq 1 ] && [ "$distinct" -eq 1 ] &&
      [ "$(sort -u "$outs"/*)" = "$value" ] &&
      [ -z "$(find "$root/.ticket-auto" -name 'log-dir.tmp.*')" ]; then
      pass "anchor_write: 12-writer race -> one value, every writer reports it"
    else fail "anchor_write: race" "value=$value lines=$lines distinct=$distinct"; fi
    ;;
  esac
  rm -rf "$root"
done

# ── Part 3: strict and legacy modes ─────────────────────────────────────────

if declare -f ticket_log_dir_or_legacy >/dev/null; then
  root=$(_tmp)
  rc=0
  out=$(cd "$root" && REPOS_ROOT="$root" STATE_ROOT_STRICT=true ticket_log_dir_or_legacy 2>"$root/err") || rc=$?
  err=$(cat "$root/err")
  rm -f "$root/err"
  if [ "$rc" -eq 13 ] && [ -z "$out" ] &&
    [[ "$err" == *"log dir unresolvable: set FLEET_PIPELINE_LOG_DIR (absolute) or run /ticket-env-check"* ]] &&
    [ -z "$(ls -A "$root")" ]; then
    pass "strict + unresolved -> rc 13, D5 message, nothing printed or created"
  else fail "strict + unresolved" "rc=$rc out=$out err=$err"; fi
  out=$(cd "$root" && REPOS_ROOT="$root" ticket_log_dir_or_legacy 2>"$root/err") || out="rc=$?"
  err=$(cat "$root/err")
  if [ "$out" = "./logs" ] && [[ "$err" == *"log dir not anchored; using ./logs (legacy)"* ]]; then
    pass "legacy + unresolved -> warning + ./logs"
  else fail "legacy + unresolved" "out=$out err=$err"; fi
  out=$(REPOS_ROOT="$root" STATE_ROOT_STRICT=true FLEET_PIPELINE_LOG_DIR="$root/abs" ticket_log_dir_or_legacy 2>"$root/err") || out="rc=$?"
  if [ "$out" = "$root/abs" ] && [ ! -s "$root/err" ]; then
    pass "strict + resolved -> the dir, no message"
  else fail "strict + resolved" "out=$out"; fi
  rm -rf "$root"
else
  fail "strict/legacy" "ticket_log_dir_or_legacy missing"
fi

# ── Part 4: writers from a foreign cwd ──────────────────────────────────────
# Layout: $root = REPOS_ROOT, anchor -> $root/logs, cwd = $root/repo-a/src.

_anchored_tree() {
  local root="$1"
  mkdir -p "$root/.ticket-auto" "$root/repo-a/src"
  printf '%s\n' "$root/logs" >"$root/.ticket-auto/log-dir"
}

_seed_manifest() { # <repos_root> <tid>
  mkdir -p "$1/.ticket-auto/initiatives/_index" "$1/.ticket-auto/initiatives/INIT-1/tickets/$2/planner"
  echo INIT-1 >"$1/.ticket-auto/initiatives/_index/$2.initiative"
  echo '{"type":"bug","initiative":"INIT-1","blocked_by":[],"dispatch":false,"stage":"Todo"}' \
    >"$1/.ticket-auto/initiatives/INIT-1/tickets/$2/planner/manifest.json"
}

_flow() { # <repos_root> <cwd> <tid> [VAR=val ...]   (flow.sh appraise-start)
  local rr="$1" cwd="$2" tid="$3"
  shift 3
  (cd "$cwd" && env -u FLEET_PIPELINE_LOG_DIR -u TICKET_FLOW_LOCK_DIR -u LOG_FILE -u TAP_LOG \
    FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none CLAUDE_SKILLS_LIB="$LIB_DIR" \
    REPOS_ROOT="$rr" "$@" bash "$FLOW_SH" "$tid" appraise-start)
}

# 4.1 emit_event: outbox, lock and origin sidecar land in the anchored dir.
root=$(_tmp)
_anchored_tree "$root"
rc=0
(
  cd "$root/repo-a/src"
  export REPOS_ROOT="$root"
  source "$LIB_DIR/events.sh"
  emit_event "LD-1" gate-held '{"reason":"x"}'
) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ -s "$root/logs/LD-1-outbox.jsonl" ] && [ -f "$root/logs/.LD-1-outbox.lock" ] &&
  [ -f "$root/logs/.LD-1-outbox-origin.json" ] && [ ! -e "$root/repo-a/src/logs" ]; then
  pass "emit_event from a subdirectory writes outbox, lock and sidecar to the anchored dir"
else fail "emit_event foreign cwd" "rc=$rc $(cd "$root" && find . -path ./.ticket-auto -prune -o -print | tr '\n' ' ')"; fi
rm -rf "$root"

# 4.2 emit_event strict + unresolved: rc 13, no file.
root=$(_tmp)
mkdir -p "$root/cwd"
rc=0
(
  cd "$root/cwd"
  export REPOS_ROOT="$root" STATE_ROOT_STRICT=true
  source "$LIB_DIR/events.sh"
  emit_event "LD-2" gate-held '{"reason":"x"}'
) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 13 ] && [ -z "$(ls -A "$root/cwd")" ] && [ "$(_tree "$root")" = "$(printf '.\n./cwd')" ]; then
  pass "emit_event strict + unresolved -> rc 13, no file"
else fail "emit_event strict" "rc=$rc $(_tree "$root" | tr '\n' ' ')"; fi
rm -rf "$root"

# 4.3 emit_event legacy + unresolved: warning and ./logs (today's behaviour).
root=$(_tmp)
mkdir -p "$root/cwd"
rc=0
err=$(
  cd "$root/cwd"
  export REPOS_ROOT="$root"
  source "$LIB_DIR/events.sh"
  emit_event "LD-3" gate-held '{"reason":"x"}' 2>&1 >/dev/null
) || rc=$?
if [ "$rc" -eq 0 ] && [ -s "$root/cwd/logs/LD-3-outbox.jsonl" ] && [[ "$err" == *"log dir not anchored"* ]]; then
  pass "emit_event legacy + unresolved -> warning + ./logs"
else fail "emit_event legacy" "rc=$rc err=$err"; fi
rm -rf "$root"

# 4.4 board-cursor.sh CLI from a subdirectory reads and writes the anchored dir.
root=$(_tmp)
_anchored_tree "$root"
mkdir -p "$root/logs"
printf '{"seq":1}\n{"seq":2}\n' >"$root/logs/LD-4-outbox.jsonl"
printf '{"tid":"LD-4","origin_seq":0,"kind":"new"}\n' >"$root/logs/.LD-4-outbox-origin.json"
rc=0
start=$(cd "$root/repo-a/src" && env -u FLEET_PIPELINE_LOG_DIR REPOS_ROOT="$root" bash "$LIB_DIR/board-cursor.sh" get LD-4 b1 2>/dev/null) || rc=$?
(cd "$root/repo-a/src" && env -u FLEET_PIPELINE_LOG_DIR REPOS_ROOT="$root" bash "$LIB_DIR/board-cursor.sh" advance LD-4 b1 2 2>/dev/null) || rc=$?
if [ "$rc" -eq 0 ] && [ "$start" = "0" ] && [ "$(jq -r .seq "$root/logs/.LD-4-cursor-b1.json" 2>/dev/null)" = "2" ] &&
  [ ! -e "$root/repo-a/src/logs" ]; then
  pass "board-cursor.sh from a subdirectory uses the anchored dir (sidecar start, cursor write)"
else fail "board-cursor foreign cwd" "rc=$rc start=$start"; fi
rm -rf "$root"

# 4.5 board-cursor.sh strict + unresolved: exit 13, no file.
root=$(_tmp)
mkdir -p "$root/cwd"
rc=0
(cd "$root/cwd" && env -u FLEET_PIPELINE_LOG_DIR REPOS_ROOT="$root" STATE_ROOT_STRICT=true \
  bash "$LIB_DIR/board-cursor.sh" advance LD-5 b1 3 >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 13 ] && [ "$(_tree "$root")" = "$(printf '.\n./cwd')" ]; then
  pass "board-cursor.sh strict + unresolved -> exit 13, no file"
else fail "board-cursor strict" "rc=$rc $(_tree "$root" | tr '\n' ' ')"; fi
rm -rf "$root"

# 4.6 outbox-drain.sh from a subdirectory drains the anchored outbox.
root=$(_tmp)
_anchored_tree "$root"
mkdir -p "$root/logs" "$root/drivers"
printf '#!/usr/bin/env bash\nexit 0\n' >"$root/drivers/okdrv.sh"
printf '{"seq":1,"event":"gate-held","data":{}}\n' >"$root/logs/LD-6-outbox.jsonl"
printf '{"tid":"LD-6","origin_seq":0,"kind":"new"}\n' >"$root/logs/.LD-6-outbox-origin.json"
rc=0
(cd "$root/repo-a/src" && env -u FLEET_PIPELINE_LOG_DIR REPOS_ROOT="$root" FLEET_BOARD_DRIVERS=okdrv \
  OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE="$root/drivers" bash "$DRAIN_SH" LD-6 >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && [ "$(jq -r .seq "$root/logs/.LD-6-cursor-okdrv.json" 2>/dev/null)" = "1" ] &&
  [ ! -e "$root/repo-a/src/logs" ]; then
  pass "outbox-drain.sh from a subdirectory drains the anchored outbox"
else fail "outbox-drain foreign cwd" "rc=$rc"; fi
rm -rf "$root"

# 4.7 outbox-drain.sh strict + unresolved: exit 13.
root=$(_tmp)
mkdir -p "$root/cwd"
rc=0
(cd "$root/cwd" && env -u FLEET_PIPELINE_LOG_DIR REPOS_ROOT="$root" STATE_ROOT_STRICT=true \
  bash "$DRAIN_SH" LD-7 >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 13 ] && [ "$(_tree "$root")" = "$(printf '.\n./cwd')" ]; then
  pass "outbox-drain.sh strict + unresolved -> exit 13, no file"
else fail "outbox-drain strict" "rc=$rc"; fi
rm -rf "$root"

# 4.8 board-cursor-fastforward.sh from a subdirectory sweeps the anchored dir.
root=$(_tmp)
_anchored_tree "$root"
mkdir -p "$root/logs"
printf '{"seq":1}\n{"seq":4}\n' >"$root/logs/LD-8-outbox.jsonl"
printf '{"tid":"LD-8","origin_seq":0,"kind":"new"}\n' >"$root/logs/.LD-8-outbox-origin.json"
rc=0
out=$(cd "$root/repo-a/src" && env -u FLEET_PIPELINE_LOG_DIR REPOS_ROOT="$root" FLEET_BOARD_DRIVERS=b1 \
  bash "$FF_SH" 2>/dev/null) || rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"SUMMARY tickets=1 "* ]] &&
  [ "$(jq -r .seq "$root/logs/.LD-8-cursor-b1.json" 2>/dev/null)" = "4" ]; then
  pass "board-cursor-fastforward.sh from a subdirectory sweeps the anchored dir"
else fail "fastforward foreign cwd" "rc=$rc out=$out"; fi
rm -rf "$root"

# 4.9 config.sh exports the resolved dir, or leaves the variable unset.
root=$(_tmp)
_anchored_tree "$root"
got=$(cd "$root/repo-a/src" && env -u FLEET_PIPELINE_LOG_DIR REPOS_ROOT="$root" \
  bash -c 'source "$1"; bash -c "printf %s \"\${FLEET_PIPELINE_LOG_DIR-<unset>}\""' _ "$LIB_DIR/config.sh" 2>/dev/null)
if [ "$got" = "$root/logs" ]; then
  pass "config.sh exports the anchored dir"
else fail "config.sh anchored" "got=$got"; fi
rm -f "$root/.ticket-auto/log-dir"
got=$(cd "$root/repo-a/src" && env -u FLEET_PIPELINE_LOG_DIR REPOS_ROOT="$root" \
  bash -c 'source "$1"; printf %s "${FLEET_PIPELINE_LOG_DIR-<unset>}"' _ "$LIB_DIR/config.sh" 2>/dev/null)
if [ "$got" = "<unset>" ]; then
  pass "config.sh leaves FLEET_PIPELINE_LOG_DIR unset when nothing resolves"
else fail "config.sh unresolved" "got=$got"; fi
rm -rf "$root"

# 4.10 flow.sh from a subdirectory: outbox in the anchored dir, no ./logs.
root=$(_tmp)
_anchored_tree "$root"
_seed_manifest "$root" LD-10
rc=0
_flow "$root" "$root/repo-a/src" LD-10 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ "$(jq -r .event "$root/logs/LD-10-outbox.jsonl" 2>/dev/null)" = "appraise-started" ] &&
  [ ! -e "$root/repo-a/src/logs" ]; then
  pass "flow.sh from a subdirectory writes the outbox to the anchored dir"
else fail "flow.sh foreign cwd" "rc=$rc $(cd "$root" && find . -name '*outbox*' | tr '\n' ' ')"; fi
rm -rf "$root"

# 4.11 flow.sh strict + unresolved: exit 13; no manifest, outbox or lock change.
root=$(_tmp)
mkdir -p "$root/repo-a/src"
_seed_manifest "$root" LD-11
before=$(_tree "$root")
mbefore=$(cat "$root/.ticket-auto/initiatives/INIT-1/tickets/LD-11/planner/manifest.json")
rc=0
err=$(_flow "$root" "$root/repo-a/src" LD-11 STATE_ROOT_STRICT=true 2>&1 >/dev/null) || rc=$?
after=$(_tree "$root")
mafter=$(cat "$root/.ticket-auto/initiatives/INIT-1/tickets/LD-11/planner/manifest.json")
if [ "$rc" -eq 13 ] && [ "$before" = "$after" ] && [ "$mbefore" = "$mafter" ] &&
  [[ "$err" == *"log dir unresolvable"* ]]; then
  pass "flow.sh strict + unresolved -> exit 13, no file created or changed"
else fail "flow.sh strict" "rc=$rc err=$err new=$(diff <(echo "$before") <(echo "$after") | tr '\n' ' ')"; fi
rm -rf "$root"

# 4.12 flow.sh legacy + unresolved: warning + ./logs.
root=$(_tmp)
mkdir -p "$root/repo-a/src"
_seed_manifest "$root" LD-12
rc=0
err=$(_flow "$root" "$root/repo-a/src" LD-12 2>&1 >/dev/null) || rc=$?
if [ "$rc" -eq 0 ] && [ -s "$root/repo-a/src/logs/LD-12-outbox.jsonl" ] &&
  [[ "$err" == *"log dir not anchored; using ./logs (legacy)"* ]]; then
  pass "flow.sh legacy + unresolved -> warning + ./logs"
else fail "flow.sh legacy" "rc=$rc err=$err"; fi
rm -rf "$root"

# ── Part 5: stray note ──────────────────────────────────────────────────────

root=$(_tmp)
_anchored_tree "$root"
_seed_manifest "$root" LD-20
mkdir -p "$root/repo-a/src/logs"
printf '{"seq":1,"event":"gate-held"}\n' >"$root/repo-a/src/logs/LD-20-outbox.jsonl"
stray_before=$(cat "$root/repo-a/src/logs/LD-20-outbox.jsonl")
_flow "$root" "$root/repo-a/src" LD-20 >/dev/null 2>&1 || true
(cd "$root/repo-a/src" && env -u FLEET_PIPELINE_LOG_DIR -u TICKET_FLOW_LOCK_DIR FLEET_FENCE_ENFORCE=false \
  FLEET_BOARD_DRIVERS=none CLAUDE_SKILLS_LIB="$LIB_DIR" REPOS_ROOT="$root" \
  bash "$FLOW_SH" LD-20 needs-info >/dev/null 2>&1) || true
log="$root/logs/LD-20-pipeline.log"
n=$(grep -c '|META|state-root-stray|warn|path=' "$log" 2>/dev/null || true)
want_path="$(cd "$root/repo-a/src/logs" && pwd -P)/LD-20-outbox.jsonl"
if [ "${n:-0}" -eq 1 ] && grep -qF "|META|state-root-stray|warn|path=${want_path}" "$log" &&
  grep -qxF "$want_path" "$root/logs/.LD-20-stray-noted" 2>/dev/null &&
  [ "$(cat "$root/repo-a/src/logs/LD-20-outbox.jsonl")" = "$stray_before" ]; then
  pass "stray outbox noted exactly once over two flow.sh runs; stray untouched"
else fail "stray note once" "count=${n:-0} log=$(cat "$log" 2>/dev/null | tr '\n' ' ')"; fi
rm -rf "$root"

# No stray note when ./logs is the anchored dir itself.
root=$(_tmp)
_anchored_tree "$root"
mkdir -p "$root/logs"
printf '{"seq":1,"event":"gate-held"}\n' >"$root/logs/LD-21-outbox.jsonl"
(
  cd "$root"
  export REPOS_ROOT="$root"
  source "$LIB_DIR/events.sh"
  emit_event "LD-21" gate-held '{"reason":"x"}'
) >/dev/null 2>&1 || true
if ! grep -q 'state-root-stray' "$root/logs/LD-21-pipeline.log" 2>/dev/null && [ ! -e "$root/logs/.LD-21-stray-noted" ]; then
  pass "no stray note when ./logs is the anchored dir"
else fail "no stray note in anchored dir"; fi
rm -rf "$root"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
