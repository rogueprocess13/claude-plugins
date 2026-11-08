#!/usr/bin/env bash
# test-seed-run.sh — lib/seed-run.sh and its two callers (GitHub #621): a
# seeder descendant that leaves the process group with setsid is found by
# the environ-marker sweep and killed, after a timeout and after a normal
# exit; seed-precheck logs a warn line for it; seed-apply's make targets get
# the same timeout and sweep. Every stray this file starts runs
# "$TMP/stray.sh", so the EXIT trap can kill any survivor and each case can
# assert with pgrep that nothing is left.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TMP=$(mktemp -d)
STRAY="$TMP/stray.sh"
_cleanup() {
  pkill -KILL -f "$STRAY" 2>/dev/null
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

if [ ! -d /proc/self ] || ! command -v setsid >/dev/null 2>&1; then
  echo "SKIP: needs /proc and setsid(1)"
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' >"$STRAY"
chmod +x "$STRAY"
export SEED_RUN_SWEEP_GRACE_SECS=1

# ── seed_run itself ──────────────────────────────────────────────────────────
(
  source "$LIB_DIR/seed-run.sh"
  start=$(date +%s)
  rc=0
  seed_run --timeout 1 --grace 1 -- bash -c 'setsid "$0" & "$0"' "$STRAY" 2>/dev/null || rc=$?
  echo "rc=$rc surv=$SEED_RUN_SURVIVORS elapsed=$(($(date +%s) - start))"
) >"$TMP/out1"
. "$TMP/out1" 2>/dev/null || true
_expect "timeout -> rc 124" 124 "$rc"
[ "${surv:-0}" -ge 1 ] && e=ok || e="$surv"
_expect "timeout: the setsid stray is found by the sweep" ok "$e"
[ "$elapsed" -lt 15 ] && e=ok || e="${elapsed}s"
_expect "timeout returns promptly" ok "$e"
_expect "timeout: nothing left (group + setsid stray)" 0 "$(_left)"

(
  source "$LIB_DIR/seed-run.sh"
  rc=0
  seed_run -- bash -c 'setsid "$0" & exit 3' "$STRAY" 2>/dev/null || rc=$?
  echo "rc=$rc surv=$SEED_RUN_SURVIVORS"
) >"$TMP/out2"
. "$TMP/out2"
_expect "normal exit keeps the command's rc" 3 "$rc"
[ "${surv:-0}" -ge 1 ] && e=ok || e="$surv"
_expect "normal exit: the setsid stray is found" ok "$e"
_expect "normal exit: nothing left" 0 "$(_left)"

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
  seed_run -- bash -c 'setsid "$0" & "$0"' "$STRAY"
) >/dev/null 2>&1 &
runner=$!
for _ in $(seq 1 50); do
  [ "$(_left)" -ge 2 ] && break
  sleep 0.1
done
[ "$(_left)" -ge 2 ] && e=ok || e="$(_left)"
_expect "the strays started under the runner" ok "$e"
kill -TERM "$runner" 2>/dev/null
wait "$runner" 2>/dev/null
_expect "TERM to the caller kills the group and the setsid stray" 0 "$(_left)"

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
printf 'scenario_daemon() { setsid "%s" & sleep 300; }\n' "$STRAY" >"$SEED/d.sh"
git -C "$WIKI" init -q -b main
git -C "$WIKI" add -A
git -C "$WIKI" -c user.email=t@t.test -c user.name=t commit -q -m "feat(T-201): seed.sh daemon"
printf 'WIKI_ROOT: %s\n' "$WIKI" >"$TMP/CLAUDE.md"
PLOG="$TMP/pre-pipeline.log"
out=$(cd "$TMP/wt" && SEED_APPLY_TIMEOUT_SECS=1 bash "$LIB_DIR/seed-precheck.sh" T-201 "$TMP/wt" \
  --claude-md "$TMP/CLAUDE.md" --log-file "$PLOG" 2>/dev/null)
_expect "precheck: setsid seeder still reported as a timeout" \
  "daemon run 1: timed out after 1s" "$(eval "$out" && echo "$SEED_PRECHECK_MSG")"
_expect "precheck: warn line names the survivor count" 1 \
  "$(grep -c '|VERIFY|seed-precheck|warn|[1-9][0-9]* processes survived daemon run 1 (killed)$' "$PLOG")"
_expect "precheck: nothing left after the timeout" 0 "$(_left)"

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
  printf '%s\n' "seed-hang: ; @setsid $STRAY & sleep 300" \
    "seed-ok: ; @setsid $STRAY & true" >"$TMP/sa-wt/Makefile"

  printf 'Seed command: `make seed-hang`\n' >"$TMP/planner/TD-1/body.md"
  start=$(date +%s)
  rc=0
  SEED_APPLY_TIMEOUT_SECS=1 seed_apply CON-1 "$TMP/sa-wt" 2>/dev/null || rc=$?
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
_expect "seed-apply: setsid survivor logged as warn" 1 "$hang_warn"
[ "$hang_elapsed" -lt 15 ] && e=ok || e="${hang_elapsed}s"
_expect "seed-apply: timeout kills make promptly" ok "$e"
_expect "seed-apply: passing target keeps rc 0 / done" "0 done" "$ok_rc $ok_status"
_expect "seed-apply: stray of a passing target is swept and logged" 1 "$ok_warn"
_expect "seed-apply: nothing left" 0 "$(_left)"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
