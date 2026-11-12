#!/usr/bin/env bash
# test-log-dir-readers.sh — the ticket-auto-pipeline readers that resolve the
# per-ticket state dir through lib/log-dir.sh (state-root-anchor, review
# ARCH-5, task 2.3). The writers are covered by test-log-dir.sh.
#
# Every case builds a fresh mktemp -d tree:
#   $ROOT          = REPOS_ROOT, anchor $ROOT/.ticket-auto/log-dir -> $ROOT/state
#   $ROOT/state    = the anchored per-ticket dir (holds the fixture logs)
#   $ROOT/away/sub = the cwd the reader is started from (no logs/ there)
# A reader that still used its old cwd-relative default would read or create
# $ROOT/away/sub/logs instead.
#
# Usage: bash test-log-dir-readers.sh
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
DETECT_SH="$PLUGIN_DIR/skills/ticket-detect-resume/detect-resume.sh"
export CLAUDE_SKILLS_LIB="$LIB_DIR"

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

unset FLEET_PIPELINE_LOG_DIR STATE_ROOT_STRICT STATE_ROOT_LOG REPOS_ROOT \
  FLEET_GENERATION FLEET_STATE_DIR FLEET_WORKER_PID LOG_FILE TAP_LOG HB_LOG_FILE \
  LOG_DIR CLAUDE_CODE_SESSION_ID _TLD_LEGACY_WARNED

TMPS=()
cleanup() {
  local d
  for d in "${TMPS[@]}"; do rm -rf "$d"; done
}
trap cleanup EXIT

# _anchored -> sets ROOT, STATE, AWAY (anchor written, AWAY empty)
_anchored() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/test-log-dir-readers.XXXXXX")
  ROOT=$(cd "$ROOT" && pwd -P)
  TMPS+=("$ROOT")
  STATE="$ROOT/state"
  AWAY="$ROOT/away/sub"
  mkdir -p "$STATE" "$AWAY" "$ROOT/.ticket-auto"
  printf '%s\n' "$STATE" >"$ROOT/.ticket-auto/log-dir"
}

_field() { grep "^  $2:" <<<"$1" | sed -E "s/^  $2: *//"; }

# ── log-dir.sh: the caller's own legacy default ─────────────────────────────

if declare -f ticket_log_dir_or_legacy >/dev/null; then
  _anchored
  rm -f "$ROOT/.ticket-auto/log-dir"
  out=$(REPOS_ROOT="$ROOT" FLEET_PIPELINE_LOG_DIR=rel ticket_log_dir_or_legacy "/legacy/logs" 2>"$ROOT/err") || out="rc=$?"
  if [ "$out" = "/legacy/logs" ] && grep -q 'using /legacy/logs (legacy)' "$ROOT/err"; then
    pass "or_legacy LEGACY: unresolved -> the caller's legacy value, named in the warning"
  else fail "or_legacy LEGACY unresolved" "out=$out err=$(cat "$ROOT/err")"; fi
  out=$(REPOS_ROOT="$ROOT" FLEET_PIPELINE_LOG_DIR=rel ticket_log_dir_or_legacy 2>/dev/null) || out="rc=$?"
  if [ "$out" = "rel" ]; then
    pass "or_legacy without LEGACY keeps \${FLEET_PIPELINE_LOG_DIR:-./logs}"
  else fail "or_legacy default legacy" "out=$out"; fi
  printf '%s\n' "$STATE" >"$ROOT/.ticket-auto/log-dir"
  out=$(REPOS_ROOT="$ROOT" ticket_log_dir_or_legacy "/legacy/logs" 2>"$ROOT/err") || out="rc=$?"
  if [ "$out" = "$STATE" ] && [ ! -s "$ROOT/err" ]; then
    pass "or_legacy LEGACY: the anchor still wins"
  else fail "or_legacy LEGACY anchored" "out=$out"; fi
else
  fail "or_legacy LEGACY" "ticket_log_dir_or_legacy missing"
fi

# ── detect-resume.sh (crash-recovery checkpoint reader) ─────────────────────

_anchored
printf '%s\n' \
  "2026-07-05T10:00:00Z|META|schema|info|1" \
  "2026-07-05T10:00:01Z|VERIFY|verify|waiting|Agent launched" \
  "2026-07-05T10:00:02Z|VERIFY|verify|fail|reproduction failed" >"$STATE/T-1-pipeline.log"
out=$(cd "$AWAY" && REPOS_ROOT="$ROOT" bash "$DETECT_SH" T-1 2>/dev/null) || true
if [ "$(_field "$out" VERIFY_ATTEMPTS)" = "1" ] && [ ! -e "$AWAY/logs" ]; then
  pass "detect-resume: foreign cwd + anchor reads the anchored pipeline log"
else fail "detect-resume anchored" "VERIFY_ATTEMPTS=$(_field "$out" VERIFY_ATTEMPTS) logs-in-cwd=$([ -e "$AWAY/logs" ] && echo yes || echo no)"; fi

# No anchor: today's $PWD/logs, even with a relative FLEET_PIPELINE_LOG_DIR.
_anchored
rm -f "$ROOT/.ticket-auto/log-dir"
mkdir -p "$AWAY/logs"
cp /dev/null "$AWAY/logs/T-2-pipeline.log"
printf '%s\n' \
  "2026-07-05T10:00:00Z|META|schema|info|1" \
  "2026-07-05T10:00:02Z|VERIFY|verify|fail|reproduction failed" >"$AWAY/logs/T-2-pipeline.log"
out=$(cd "$AWAY" && REPOS_ROOT="$ROOT" FLEET_PIPELINE_LOG_DIR=elsewhere bash "$DETECT_SH" T-2 2>/dev/null) || true
if [ "$(_field "$out" VERIFY_ATTEMPTS)" = "1" ]; then
  pass "detect-resume: no anchor -> \$PWD/logs as before"
else fail "detect-resume legacy" "VERIFY_ATTEMPTS=$(_field "$out" VERIFY_ATTEMPTS)"; fi

# Strict + unresolved: refuse with rc 13 rather than read a cwd-relative log.
_anchored
rm -f "$ROOT/.ticket-auto/log-dir"
rc=0
(cd "$AWAY" && REPOS_ROOT="$ROOT" STATE_ROOT_STRICT=true bash "$DETECT_SH" T-3 >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 13 ] && [ ! -e "$AWAY/logs" ]; then
  pass "detect-resume: strict + unresolved -> exit 13, nothing created"
else fail "detect-resume strict" "rc=$rc"; fi

# ── operator CLIs: a person runs these from any directory ──────────────────

# adversarial-override.sh: log found in the anchored dir -> exit 5 (no live
# BLOCK to override), not 3 (log not found).
_anchored
printf '2026-07-05T10:00:00Z|META|schema|info|1\n' >"$STATE/T-4-pipeline.log"
rc=0
(cd "$AWAY" && REPOS_ROOT="$ROOT" bash "$LIB_DIR/adversarial-override.sh" T-4 --reason "test" >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 5 ]; then
  pass "adversarial-override: finds the anchored pipeline log from a foreign cwd"
else fail "adversarial-override anchored" "rc=$rc (3 = log not found)"; fi

# verify-attempts-reset.sh: records the reset beside the anchored log.
_anchored
printf '2026-07-05T10:00:00Z|META|schema|info|1\n' >"$STATE/T-5-pipeline.log"
rc=0
(cd "$AWAY" && REPOS_ROOT="$ROOT" bash "$LIB_DIR/verify-attempts-reset.sh" T-5 env fixed >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && grep -q '^reset|' "$STATE/T-5-pipeline.log.verify-ctl" 2>/dev/null &&
  [ ! -e "$AWAY/logs" ]; then
  pass "verify-attempts-reset: writes the control file beside the anchored log"
else fail "verify-attempts-reset anchored" "rc=$rc"; fi
_anchored
rm -f "$ROOT/.ticket-auto/log-dir"
rc=0
(cd "$AWAY" && REPOS_ROOT="$ROOT" STATE_ROOT_STRICT=true bash "$LIB_DIR/verify-attempts-reset.sh" T-5 env fixed >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 13 ]; then
  pass "verify-attempts-reset: strict + unresolved -> exit 13"
else fail "verify-attempts-reset strict" "rc=$rc"; fi

# manifest-backfill.sh: with no LOG-DIR argument it scans the anchored dir.
_anchored
rc=0
err=$(cd "$AWAY" && REPOS_ROOT="$ROOT" bash "$LIB_DIR/manifest-backfill.sh" --dry-run 2>&1 >/dev/null) || rc=$?
if [ "$rc" -eq 0 ] && [[ "$err" != *"no such log directory"* ]]; then
  pass "manifest-backfill: defaults to the anchored dir"
else fail "manifest-backfill anchored" "rc=$rc err=$err"; fi

# pipeline-postmortem.sh: with no LOG_FILE it appends to the anchored log.
_anchored
printf '2026-07-05T10:00:00Z|META|schema|info|1\n' >"$STATE/T-6-pipeline.log"
(cd "$AWAY" && REPOS_ROOT="$ROOT" POSTMORTEM_ENABLED=true POSTMORTEM_FILE_ISSUES=false \
  POSTMORTEM_STATE_DIR="$ROOT/pm-state" bash "$LIB_DIR/pipeline-postmortem.sh" T-6 --exit-code 1 >/dev/null 2>&1) || true
if grep -q '|META|postmortem|info|' "$STATE/T-6-pipeline.log" && [ ! -e "$AWAY/logs" ]; then
  pass "pipeline-postmortem: reads and appends to the anchored log"
else fail "pipeline-postmortem anchored"; fi

# retro.sh: discovery mode (no positional log) scans the anchored dir.
_anchored
printf '%s\n' "2026-07-05T10:00:00Z|META|schema|info|1" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|fail|boom" >"$STATE/T-7-pipeline.log"
_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
export -f _iso_now
out=$(cd "$AWAY" && REPOS_ROOT="$ROOT" CURSOR_FILE="$ROOT/cursor.json" \
  PLANNER_INITIATIVES_DIR="$ROOT/no-planner" \
  bash "$PLUGIN_DIR/skills/ticket-retro/retro.sh" --window 30 --force 2>/dev/null) || true
if [[ "$out" == *"T-7"* ]]; then
  pass "retro: discovery mode finds the anchored pipeline logs"
else fail "retro anchored" "out=${out:0:200}"; fi

# trajectory.sh: traj_generate with no LOG_DIR reads the anchored logs and
# writes its default output beside them.
_anchored
printf '%s\n' "2026-07-05T10:00:00Z|META|schema|info|1" \
  "2026-07-05T10:00:01Z|APPRAISE|appraise|done|ok" >"$STATE/T-8-pipeline.log"
rc=0
(cd "$AWAY" && export REPOS_ROOT="$ROOT" && source "$LIB_DIR/trajectory.sh" && traj_generate T-8 >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && [ -s "$STATE/T-8-trajectory.jsonl" ] && [ ! -e "$AWAY/logs" ]; then
  pass "trajectory: reads the anchored logs, writes beside them"
else fail "trajectory anchored" "rc=$rc"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
