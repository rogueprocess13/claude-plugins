#!/usr/bin/env bash
# test-seed-run.sh — lib/seed-run.sh and its two callers (GitHub #621): a
# seeder descendant that leaves the process group with setsid is found by
# the environ-marker sweep and killed, after a timeout and after a normal
# exit; seed-precheck logs a warn line for it; seed-apply's make targets get
# the same timeout and sweep.
#
# No case depends on scheduling luck: every stray runs "$STRAY <ready-file>"
# and writes that file only once its own /proc environ shows the marker, and
# each seeder waits for it before it exits, so "the command ended while the
# stray was still starting" never happens by accident. The one case that
# needs a stray the marker scan cannot see yet (the follow-up race) builds
# it on purpose. "Nothing left" checks poll pgrep for up to 10s. The EXIT
# trap kills any survivor, so a failing case never leaks into make test.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TMP=$(mktemp -d)
STRAY="$TMP/stray.sh"
WAIT="$TMP/wait-ready.sh"
_cleanup() {
  pkill -KILL -f "$TMP/" 2>/dev/null
  rm -rf "$TMP"
}
trap _cleanup EXIT

_expect() {
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $1 — want [$2] got [$3]"
    FAIL=$((FAIL + 1))
  fi
}
_left() { pgrep -f "$STRAY" 2>/dev/null | grep -c .; }
# _none_left — 0 once no stray is left, polling up to 10s; else the count,
# after killing the survivors so a later case reports on itself only.
_none_left() {
  local i n
  for i in $(seq 1 100); do
    [ "$(_left)" = 0 ] && break
    sleep 0.1
  done
  n=$(_left)
  [ "$n" = 0 ] || pkill -KILL -f "$STRAY" 2>/dev/null
  echo "$n"
}
# _ready <file>... — ok once every file exists (up to 10s), else the missing.
_ready() {
  local i f miss
  for i in $(seq 1 100); do
    miss=""
    for f in "$@"; do [ -s "$f" ] || miss="$miss ${f##*/}"; done
    [ -z "$miss" ] && break
    sleep 0.1
  done
  echo "${miss:-ok}"
}

if [ ! -d /proc/self ] || ! command -v setsid >/dev/null 2>&1; then
  echo "SKIP: needs /proc and setsid(1)"
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# stray.sh <ready-file> — writes its pid to <ready-file> once its own environ
# carries the marker, then loops forever.
cat >"$STRAY" <<'EOF'
#!/usr/bin/env bash
want="TICKET_SEED_RUN_ID=${TICKET_SEED_RUN_ID:-}"
for _ in $(seq 1 200); do
  tr '\0' '\n' <"/proc/$$/environ" | grep -qxF -- "$want" && break
  sleep 0.05
done
echo $$ >"$1.tmp" && mv "$1.tmp" "$1"
while :; do sleep 1; done
EOF
# wait-ready.sh <file> — returns once <file> exists (bounded, 10s).
cat >"$WAIT" <<'EOF'
#!/usr/bin/env bash
for _ in $(seq 1 200); do
  [ -s "$1" ] && exit 0
  sleep 0.05
done
exit 1
EOF
chmod +x "$STRAY" "$WAIT"
export SEED_RUN_SWEEP_GRACE_SECS=1

# ── seed_run itself ──────────────────────────────────────────────────────────
(
  source "$LIB_DIR/seed-run.sh"
  start=$(date +%s)
  rc=0
  seed_run --timeout 5 --grace 1 -- bash -c '
    setsid "$0" "$1" & "$2" "$1"; "$0" "$3"' "$STRAY" "$TMP/r1" "$WAIT" "$TMP/r1b" 2>/dev/null || rc=$?
  echo "rc=$rc surv=$SEED_RUN_SURVIVORS elapsed=$(($(date +%s) - start))"
) >"$TMP/out1"
. "$TMP/out1" 2>/dev/null || true
_expect "timeout -> rc 124" 124 "$rc"
_expect "timeout: the setsid stray had started" ok "$(_ready "$TMP/r1")"
[ "${surv:-0}" -ge 1 ] && e=ok || e="$surv"
_expect "timeout: the setsid stray is found by the sweep" ok "$e"
[ "$elapsed" -lt 30 ] && e=ok || e="${elapsed}s"
_expect "timeout returns promptly" ok "$e"
_expect "timeout: nothing left (group + setsid stray)" 0 "$(_none_left)"

(
  source "$LIB_DIR/seed-run.sh"
  rc=0
  seed_run -- bash -c 'setsid "$0" "$1" & "$2" "$1"; exit 3' "$STRAY" "$TMP/r2" "$WAIT" 2>/dev/null || rc=$?
  echo "rc=$rc surv=$SEED_RUN_SURVIVORS"
) >"$TMP/out2"
. "$TMP/out2"
_expect "normal exit keeps the command's rc" 3 "$rc"
_expect "normal exit: the setsid stray had started" ok "$(_ready "$TMP/r2")"
[ "${surv:-0}" -ge 1 ] && e=ok || e="$surv"
_expect "normal exit: the setsid stray is found" ok "$e"
_expect "normal exit: nothing left" 0 "$(_none_left)"

# The follow-up race: when the command exits, its stray cannot be matched by
# the marker yet. Mid-execve a process reads an empty environ; this stray
# stays in that state for 0.6s on purpose (env -i), then execs into a marked
# stray. A single scan at exit misses it; the settle loop must not.
(
  source "$LIB_DIR/seed-run.sh"
  rc=0
  SEED_RUN_SWEEP_SETTLE_SECS=5 seed_run -- bash -c '
    setsid env -i /bin/sh -c "sleep 0.6; exec env TICKET_SEED_RUN_ID=\$0 \"\$1\" \"\$2\"" \
      "$TICKET_SEED_RUN_ID" "$0" "$1" &
    sleep 0.2' "$STRAY" "$TMP/r-late" 2>/dev/null || rc=$?
  echo "rc=$rc surv=$SEED_RUN_SURVIVORS"
) >"$TMP/out-late"
. "$TMP/out-late"
_expect "late marker: rc 0" 0 "$rc"
[ "${surv:-0}" -ge 1 ] && e=ok || e="$surv"
_expect "late marker: a stray with no readable marker at exit is still found" ok "$e"
_expect "late marker: nothing left" 0 "$(_none_left)"

# An unrelated process of ours with an empty environ looks like a stray
# mid-exec. It must never be killed, and it may not hold the sweep past its
# settle bound.
env -i "$(command -v sleep)" 60 &
bystander=$!
(
  source "$LIB_DIR/seed-run.sh"
  start=$(date +%s%N)
  SEED_RUN_SWEEP_SETTLE_SECS=1 seed_run -- true
  echo "rc=$? surv=$SEED_RUN_SURVIVORS ms=$((($(date +%s%N) - start) / 1000000))"
) >"$TMP/out-by"
. "$TMP/out-by"
_expect "bystander: clean run, no survivors" "0 0" "$rc $surv"
kill -0 "$bystander" 2>/dev/null && e=ok || e=killed
_expect "bystander: an empty-environ process that is not marked is left alone" ok "$e"
[ "$ms" -lt 10000 ] && e=ok || e="${ms}ms"
_expect "bystander: the sweep still ends at its bound" ok "$e"
kill "$bystander" 2>/dev/null
wait "$bystander" 2>/dev/null

(
  source "$LIB_DIR/seed-run.sh"
  rc=0
  trap 'echo mine' TERM
  seed_run --cwd "$TMP" -- bash -c 'pwd >"$0/cwd"; [ -n "$TICKET_SEED_RUN_ID" ]' "$TMP" || rc=$?
  echo "rc=$rc surv=$SEED_RUN_SURVIVORS"
  echo "marker_in_caller=${TICKET_SEED_RUN_ID:-none}"
  echo "trap_kept=$(trap -p TERM | grep -c "echo mine")"
) >"$TMP/out3" 2>/dev/null
. "$TMP/out3"
_expect "clean run: rc 0 and the child saw the marker" 0 "$rc"
_expect "clean run: no survivors" 0 "$surv"
_expect "clean run: ran in --cwd" "$TMP" "$(cat "$TMP/cwd")"
_expect "the marker never leaks into the caller" none "$marker_in_caller"
_expect "the caller's TERM trap is restored" 1 "$trap_kept"

(
  source "$LIB_DIR/seed-run.sh"
  seed_run --timeout x -- true
  echo "rc=$?"
) >"$TMP/out4" 2>/dev/null
. "$TMP/out4"
_expect "bad --timeout -> rc 2" 2 "$rc"

# The caller killed mid-run takes the group and the setsid stray with it.
(
  source "$LIB_DIR/seed-run.sh"
  seed_run -- bash -c 'setsid "$0" "$1" & "$0" "$2"' "$STRAY" "$TMP/r3" "$TMP/r3b"
) >/dev/null 2>&1 &
runner=$!
_expect "the strays started under the runner" ok "$(_ready "$TMP/r3" "$TMP/r3b")"
kill -TERM "$runner" 2>/dev/null
wait "$runner" 2>/dev/null
_expect "TERM to the caller kills the group and the setsid stray" 0 "$(_none_left)"

# ── seed-precheck: warn line, nothing left ──────────────────────────────────
WIKI="$TMP/wiki"
SEED="$WIKI/api/_tools/seed"
mkdir -p "$SEED" "$TMP/wt"
cat >"$SEED/seed.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for f in ./*.sh; do case "$f" in ./seed.sh) ;; *) source "$f" ;; esac; done
"scenario_$1"
EOF
printf 'scenario_daemon() { setsid "%s" "%s" & "%s" "%s"; sleep 300; }\n' \
  "$STRAY" "$TMP/r4" "$WAIT" "$TMP/r4" >"$SEED/d.sh"
git -C "$WIKI" init -q -b main
git -C "$WIKI" add -A
git -C "$WIKI" -c user.email=t@t.test -c user.name=t commit -q -m "feat(T-201): seed.sh daemon"
printf 'WIKI_ROOT: %s\n' "$WIKI" >"$TMP/CLAUDE.md"
PLOG="$TMP/pre-pipeline.log"
out=$(cd "$TMP/wt" && SEED_APPLY_TIMEOUT_SECS=5 bash "$LIB_DIR/seed-precheck.sh" T-201 "$TMP/wt" \
  --claude-md "$TMP/CLAUDE.md" --log-file "$PLOG" 2>/dev/null)
_expect "precheck: setsid seeder still reported as a timeout" \
  "daemon run 1: timed out after 5s" "$(eval "$out" && echo "$SEED_PRECHECK_MSG")"
_expect "precheck: the setsid stray had started" ok "$(_ready "$TMP/r4")"
_expect "precheck: warn line names the survivor count" 1 \
  "$(grep -c '|VERIFY|seed-precheck|warn|[1-9][0-9]* processes survived daemon run 1 (killed)$' "$PLOG")"
_expect "precheck: nothing left after the timeout" 0 "$(_none_left)"

# ── seed-apply: timeout on a hung make target, sweep after a passing one ────
(
  export REPOS_ROOT="$TMP/repos" LOG_FILE="$TMP/logs/CON-1-pipeline.log"
  mkdir -p "$REPOS_ROOT" "$(dirname "$LOG_FILE")" "$TMP/sa-wt" "$TMP/planner/TD-1"
  source "$LIB_DIR/seed-apply.sh"
  get_ticket_manifest_field() { echo '["TD-1"]'; }
  ticket_pipeline_merge_state() { echo merged; }
  resolve_planner_dir() {
    echo "$TMP/planner/$1"
    [ -d "$TMP/planner/$1" ]
  }
  printf '%s\n' "seed-hang: ; @setsid $STRAY $TMP/r5 & $WAIT $TMP/r5; sleep 300" \
    "seed-ok: ; @setsid $STRAY $TMP/r6 & $WAIT $TMP/r6" >"$TMP/sa-wt/Makefile"

  printf 'Seed command: `make seed-hang`\n' >"$TMP/planner/TD-1/body.md"
  start=$(date +%s)
  rc=0
  SEED_APPLY_TIMEOUT_SECS=5 seed_apply CON-1 "$TMP/sa-wt" 2>/dev/null || rc=$?
  echo "hang_rc=$rc hang_elapsed=$(($(date +%s) - start))"
  echo "hang_status=$SEED_APPLY_STATUS"
  echo "hang_fail=$(grep -c '|VERIFY|seed-apply|fail|TD-1 seed command exited 124: make seed-hang$' "$LOG_FILE")"
  echo "hang_warn=$(grep -c '|VERIFY|seed-apply|warn|[1-9][0-9]* processes survived TD-1 seed command (killed)$' "$LOG_FILE")"

  printf 'Seed command: `make seed-ok`\n' >"$TMP/planner/TD-1/body.md"
  : >"$LOG_FILE"
  rc=0
  seed_apply CON-1 "$TMP/sa-wt" 2>/dev/null || rc=$?
  echo "ok_rc=$rc ok_status=$SEED_APPLY_STATUS"
  echo "ok_warn=$(grep -c '|VERIFY|seed-apply|warn|[1-9][0-9]* processes survived TD-1 seed command (killed)$' "$LOG_FILE")"
) >"$TMP/out5"
. "$TMP/out5"
_expect "seed-apply: hung make target -> rc 1" 1 "$hang_rc"
_expect "seed-apply: fail status" fail "$hang_status"
_expect "seed-apply: timeout logged in the existing fail format (exited 124)" 1 "$hang_fail"
_expect "seed-apply: the strays had started" ok "$(_ready "$TMP/r5" "$TMP/r6")"
_expect "seed-apply: setsid survivor logged as warn" 1 "$hang_warn"
[ "$hang_elapsed" -lt 30 ] && e=ok || e="${hang_elapsed}s"
_expect "seed-apply: timeout kills make promptly" ok "$e"
_expect "seed-apply: passing target keeps rc 0 / done" "0 done" "$ok_rc $ok_status"
_expect "seed-apply: stray of a passing target is swept and logged" 1 "$ok_warn"
_expect "seed-apply: nothing left" 0 "$(_none_left)"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
