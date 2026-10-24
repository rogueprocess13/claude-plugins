#!/usr/bin/env bash
# test-plog.sh — lib/plog.sh, the CLI skills use to write one pipeline-log
# line through heartbeat.sh's `_plog` (skill-glue-collapse, design D1/D2).
#
# Covers:
#   1. Grammar: the line equals what `_plog` writes and what the legacy inline
#      `echo "$(date -u ...)|P|s|st|msg" >> "$LOG_FILE"` wrote (timestamp masked).
#   2. META pseudo-phase line.
#   3. LOG_FILE unset / empty: exit 0, nothing created — also under `set -e`.
#   4. A `set -e` caller survives the call as its last statement.
#   5. Missing parent directory is created.
#   6. `|`, CR and LF in MSG are sanitised to spaces: one 5-field line.
#   7. --log-file PATH overrides LOG_FILE; --log-file "" is a no-op.
#   8. MSG is optional (empty 5th field).
#   9. Usage errors exit 2 and write nothing.
#  10. Unwritable target exits 1.
#
# Run: bash ticket-auto-pipeline/lib/tests/test-plog.sh

set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PLOG="${LIB_DIR}/plog.sh"

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}
expect() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
mask() { sed -E "s/${ISO_RE}/ISO/" "$1"; }

# ── 1. Grammar equals _plog and the legacy echo ──────────────────────────────
LOG_FILE="$TMP/t1.log" bash "$PLOG" APPRAISE complexity-sweep start "Scoring"
(
  # shellcheck source=../heartbeat.sh
  source "$LIB_DIR/heartbeat.sh"
  _plog "$TMP/t1-ref.log" APPRAISE complexity-sweep start "Scoring"
)
LOG_FILE="$TMP/t1-legacy.log"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|complexity-sweep|start|Scoring" >>"$LOG_FILE"
unset LOG_FILE
expect "1a: exactly one line" "1" "$(wc -l <"$TMP/t1.log" | tr -d ' ')"
if grep -qE "${ISO_RE}\|APPRAISE\|complexity-sweep\|start\|Scoring$" "$TMP/t1.log"; then
  pass "1b: ISO|PHASE|STEP|STATUS|MSG grammar"
else
  fail "1b: grammar" "$(cat "$TMP/t1.log")"
fi
expect "1c: equals _plog (timestamp masked)" "$(mask "$TMP/t1-ref.log")" "$(mask "$TMP/t1.log")"
expect "1d: equals legacy inline echo (timestamp masked)" "$(mask "$TMP/t1-legacy.log")" "$(mask "$TMP/t1.log")"

# ── 2. META line ─────────────────────────────────────────────────────────────
LOG_FILE="$TMP/t2.log" bash "$PLOG" META persona-select info "base=analyzer;spec=none;debug=none"
expect "2: META line" "ISO|META|persona-select|info|base=analyzer;spec=none;debug=none" "$(mask "$TMP/t2.log")"

# ── 3. LOG_FILE unset / empty ────────────────────────────────────────────────
rc=0
(
  set -e
  unset LOG_FILE
  cd "$TMP"
  bash "$PLOG" GATE gate-check "done" ok
) || rc=$?
expect "3a: unset LOG_FILE exits 0 under set -e" "0" "$rc"
rc=0
LOG_FILE="" bash "$PLOG" GATE gate-check "done" ok || rc=$?
expect "3b: empty LOG_FILE exits 0" "0" "$rc"
expect "3c: nothing created" "" "$(find "$TMP" -maxdepth 1 -newer "$TMP/t2.log" -type f)"

# ── 4. set -e caller, plog as last statement ────────────────────────────────
rc=0
out=$(bash -c 'set -euo pipefail; LOG_FILE="" bash "$1" IMPLEMENT x done ok; echo after' _ "$PLOG") || rc=$?
expect "4a: set -e caller continues (empty LOG_FILE)" "0:after" "${rc}:${out}"
rc=0
out=$(bash -c 'set -euo pipefail; LOG_FILE="$2" bash "$1" IMPLEMENT x done ok; echo after' _ "$PLOG" "$TMP/t4.log") || rc=$?
expect "4b: set -e caller continues (real LOG_FILE)" "0:after" "${rc}:${out}"

# ── 5. Parent directory creation ─────────────────────────────────────────────
LOG_FILE="$TMP/new/dir/T-1-pipeline.log" bash "$PLOG" EXEC artifact "done" ok
expect "5: parent dir created and line appended" "ISO|EXEC|artifact|done|ok" "$(mask "$TMP/new/dir/T-1-pipeline.log" 2>/dev/null || true)"

# ── 6. Sanitisation ──────────────────────────────────────────────────────────
LOG_FILE="$TMP/t6.log" bash "$PLOG" GATE x fail "a|b"
LOG_FILE="$TMP/t6.log" bash "$PLOG" GATE y fail "$(printf 'line1\r\nline2')"
expect "6a: two calls, two lines" "2" "$(wc -l <"$TMP/t6.log" | tr -d ' ')"
expect "6b: every line has 5 fields" "5 5" "$(awk -F'|' '{printf "%s%s", (NR>1?" ":""), NF}' "$TMP/t6.log")"
expect "6c: pipe becomes space" "a b" "$(sed -n 1p "$TMP/t6.log" | cut -d'|' -f5)"
expect "6d: CR/LF become spaces" "line1  line2" "$(sed -n 2p "$TMP/t6.log" | cut -d'|' -f5)"

# ── 7. --log-file ────────────────────────────────────────────────────────────
LOG_FILE="$TMP/t7-env.log" bash "$PLOG" --log-file "$TMP/t7-flag.log" VERIFY v "done" ok
expect "7a: --log-file wins over LOG_FILE" "ISO|VERIFY|v|done|ok" "$(mask "$TMP/t7-flag.log")"
if [ ! -e "$TMP/t7-env.log" ]; then pass "7b: LOG_FILE untouched"; else fail "7b: LOG_FILE untouched" "file written"; fi
rc=0
bash "$PLOG" --log-file "" VERIFY v "done" ok || rc=$?
expect "7c: --log-file \"\" is a no-op exit 0" "0" "$rc"

# ── 8. MSG optional ──────────────────────────────────────────────────────────
LOG_FILE="$TMP/t8.log" bash "$PLOG" MAINTENANCE m start
expect "8: empty message field" "ISO|MAINTENANCE|m|start|" "$(mask "$TMP/t8.log")"

# ── 9. Usage ─────────────────────────────────────────────────────────────────
rc=0
LOG_FILE="$TMP/t9.log" bash "$PLOG" GATE x 2>/dev/null || rc=$?
expect "9a: two args exit 2" "2" "$rc"
rc=0
bash "$PLOG" --log-file 2>/dev/null || rc=$?
expect "9b: --log-file without value exit 2" "2" "$rc"
if [ ! -e "$TMP/t9.log" ]; then pass "9c: usage error writes nothing"; else fail "9c: usage error writes nothing" "file written"; fi

# ── 10. Unwritable target ────────────────────────────────────────────────────
mkdir -p "$TMP/t10.log"
rc=0
LOG_FILE="$TMP/t10.log" bash "$PLOG" GATE x fail y 2>/dev/null || rc=$?
expect "10: unwritable target exits 1" "1" "$rc"

echo ""
echo "plog: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
