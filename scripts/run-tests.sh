#!/usr/bin/env bash
# run-tests.sh — run the Makefile's test commands in parallel.
#
# The Makefile stays the one list of test commands: this script asks make for
# the recipes of the given targets (`make -n`), so a new test still needs only
# its Makefile line, and check-test-registration.sh still guards that list.
# Each command runs in its own process with stdin from /dev/null and its
# output in its own log file, so parallel output never interleaves and a test
# that reads stdin cannot swallow the command list.
#
# Usage: run-tests.sh TARGET...
#   TEST_JOBS     parallel jobs (default: nproc)
#   TEST_TIMEOUT  per-command timeout in seconds (default: 1800)
#   TEST_LOG_DIR  where per-command logs go (default: a new mktemp dir)
#   TEST_MAKEFILE makefile to read targets from (default: the repo Makefile)
#   TEST_SLOW_FIRST  slow-first list (default: scripts/test-slow-first.txt)
#
# Commands listed in scripts/test-slow-first.txt start first, in that order,
# so the longest tests are not left for the end of the run. A stale entry in
# that file is ignored; it only changes order, never what runs.
#
# Exit codes: 0 all passed, 1 at least one failed or timed out, 2 usage or
# no commands found.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: run-tests.sh TARGET..." >&2
  exit 2
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
JOBS="${TEST_JOBS:-$(nproc 2>/dev/null || echo 2)}"
TIMEOUT="${TEST_TIMEOUT:-1800}"
LOG_DIR="${TEST_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/run-tests.XXXXXX")}"
mkdir -p "$LOG_DIR"
SLOW_FIRST="${TEST_SLOW_FIRST:-$ROOT/scripts/test-slow-first.txt}"
MAKEFILE="${TEST_MAKEFILE:-$ROOT/Makefile}"

# Recipe lines for the targets, with backslash continuations joined. Only
# lines that run a test are kept: echo banners and comments are dropped.
CMDS="$LOG_DIR/cmds.txt"
make -s -n --no-print-directory -f "$MAKEFILE" "$@" |
  awk '{ if (sub(/\\$/, "")) { buf = buf $0; next } print buf $0; buf = "" }' |
  grep -E '(^|[[:space:]])(bash|python3 -m pytest)[[:space:]]' |
  grep -vE '^[[:space:]]*(echo|#)' >"$CMDS.raw" || true

if [ ! -s "$CMDS.raw" ]; then
  echo "run-tests.sh: no test commands found for: $*" >&2
  exit 2
fi

# Slow-first ordering: a command whose text contains a listed path moves to
# the front, in the order of the list. Everything else keeps Makefile order.
python3 - "$CMDS.raw" "$SLOW_FIRST" >"$CMDS" <<'PY'
import sys
cmds = [l.rstrip("\n") for l in open(sys.argv[1]) if l.strip()]
try:
    slow = [l.strip() for l in open(sys.argv[2]) if l.strip() and not l.startswith("#")]
except FileNotFoundError:
    slow = []
first, used = [], set()
for path in slow:
    for i, c in enumerate(cmds):
        if i not in used and path in c.split():
            first.append(c)
            used.add(i)
rest = [c for i, c in enumerate(cmds) if i not in used]
print("\n".join(first + rest))
PY

TOTAL=$(wc -l <"$CMDS")
RESULTS="$LOG_DIR/results.tsv"
: >"$RESULTS"
echo "=== run-tests: $TOTAL commands, $JOBS parallel, logs in $LOG_DIR ==="

# One worker per command: run it, record "secs<TAB>rc<TAB>index<TAB>cmd", and
# print a one-line progress mark (short writes, so lines do not interleave).
export LOG_DIR TIMEOUT RESULTS
run_one() {
  local i="$1" cmd="$2" s e rc
  s=$(date +%s%N)
  rc=0
  timeout --kill-after=30 "$TIMEOUT" bash -c "$cmd" </dev/null >"$LOG_DIR/test-$i.log" 2>&1 || rc=$?
  e=$(date +%s%N)
  local secs=$(((e - s) / 1000000000))
  printf '%s\t%s\t%s\t%s\n' "$secs" "$rc" "$i" "$cmd" >>"$RESULTS"
  if [ "$rc" -eq 0 ]; then
    printf 'ok   %4ss  %s\n' "$secs" "$cmd"
  elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    printf 'TIMEOUT %ss  %s\n' "$secs" "$cmd"
  else
    printf 'FAIL %4ss  rc=%s  %s\n' "$secs" "$rc" "$cmd"
  fi
}
export -f run_one

START=$(date +%s)
# NUL-separated "index, command" pairs. Built in bash, not awk: mawk ends a
# printf format string at an embedded \0.
n=0
while IFS= read -r c; do
  n=$((n + 1))
  printf '%s\0%s\0' "$n" "$c"
done <"$CMDS" |
  xargs -0 -n 2 -P "$JOBS" bash -c 'run_one "$1" "$2"' _ || true
WALL=$(($(date +%s) - START))

DONE=$(wc -l <"$RESULTS")
FAILED=$(awk -F'\t' '$2 != 0' "$RESULTS" | wc -l)

if [ "$FAILED" -gt 0 ]; then
  echo
  echo "=== failing test output ==="
  awk -F'\t' '$2 != 0 { print $3 "\t" $4 }' "$RESULTS" | sort -n |
    while IFS=$'\t' read -r i cmd; do
      echo "--- $cmd ---"
      cat "$LOG_DIR/test-$i.log"
      echo
    done
fi

echo
echo "=== slowest 10 ==="
sort -t$'\t' -k1,1 -rn "$RESULTS" | awk -F'\t' 'NR <= 10 { printf "%5ss  %s\n", $1, $4 }'
SUM=$(awk -F'\t' '{ s += $1 } END { print s + 0 }' "$RESULTS")
echo
echo "=== run-tests: $DONE/$TOTAL ran, $FAILED failed, wall ${WALL}s (serial sum ${SUM}s) ==="

if [ "$DONE" -ne "$TOTAL" ]; then
  echo "run-tests.sh: only $DONE of $TOTAL commands reported a result" >&2
  exit 1
fi
[ "$FAILED" -eq 0 ]
