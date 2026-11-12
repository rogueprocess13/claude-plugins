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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
