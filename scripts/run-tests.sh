#!/usr/bin/env bash
# run-tests.sh — run the Makefile's test commands in parallel.
#
# The Makefile stays the one list of test commands: this script asks make for
# the recipes of the given targets (`make -n`), so a new test still needs only
# its Makefile line, and check-test-registration.sh still guards that list.
# Each command runs in its own process with stdin from /dev/null and its
# output in its own log file, so parallel output never interleaves and a test
# that reads stdin cannot swallow the command list. CLAUDE_CODE_SESSION_ID is
# removed from each command's environment, so a run inside a Claude Code
# session behaves like CI.
#
# Usage: run-tests.sh [--shard K/N] [--only LIST] [--list] TARGET...
#   --shard K/N   run only shard K of N (1-based); also TEST_SHARD=K/N
#   --only LIST   run only the commands whose test file (the path after
#                 `bash` or `python3 -m pytest`, relative to the repo root)
#                 is under a LIST entry ending in "/" or equals a LIST
#                 entry. LIST is space- or comma-separated; `all` keeps
#                 everything, `none` keeps nothing. Also TEST_ONLY.
#                 scripts/select-tests.sh prints it for a PR. The filter
#                 runs before the shard split, so shards balance the subset,
#                 and an empty selection exits 0.
#   --list        print the commands this run would start, in start order,
#                 and exit without running them
#   TEST_JOBS     parallel jobs (default: nproc)
#   TEST_TIMEOUT  per-command timeout in seconds (default: 1800)
#   TEST_LOG_DIR  where per-command logs go (default: a new mktemp dir)
#   TEST_MAKEFILE makefile to read targets from (default: the repo Makefile)
#   TEST_DURATIONS  durations file (default: scripts/test-durations.tsv)
#
# scripts/test-durations.tsv ("<command><TAB><seconds>", with the repo root
# written as {ROOT}) is the one source of measured test times. It drives two
# things:
#   - Order. Commands start longest first, so the slowest tests are not left
#     for the end of the run.
#   - The shard split. Each command is weighted by its time in the file; a
#     command missing from the file gets the file's median. Commands go to N
#     shards by longest-processing-time-first greedy balancing: the heaviest
#     command first, each to the shard with the smallest load so far, ties to
#     the lower shard number and then to Makefile order. The split depends
#     only on the command list and the file, so all shards of one CI run
#     compute the same split and shards 1..N together run every command once.
# A stale or missing entry changes only order and balance, never what runs.
# Refresh the file with `make test-durations`.
#
# Exit codes: 0 all passed, 1 at least one failed or timed out, 2 usage or
# no commands found.
set -euo pipefail

usage() {
  echo "usage: run-tests.sh [--shard K/N] [--only LIST] [--list] TARGET..." >&2
  exit 2
}

SHARD="${TEST_SHARD:-}"
ONLY="${TEST_ONLY:-all}"
LIST=0
TARGETS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
  --shard)
    [ "$#" -ge 2 ] || usage
    SHARD="$2"
    shift 2
    ;;
  --shard=*)
    SHARD="${1#--shard=}"
    shift
    ;;
  --only)
    [ "$#" -ge 2 ] || usage
    ONLY="$2"
    shift 2
    ;;
  --only=*)
    ONLY="${1#--only=}"
    shift
    ;;
  --list)
    LIST=1
    shift
    ;;
  -*) usage ;;
  *)
    TARGETS+=("$1")
    shift
    ;;
  esac
done
[ "${#TARGETS[@]}" -gt 0 ] || usage

SHARD_K=1
SHARD_N=1
if [ -n "$SHARD" ]; then
  if ! [[ "$SHARD" =~ ^([1-9][0-9]{0,2})/([1-9][0-9]{0,2})$ ]] ||
    [ "${BASH_REMATCH[1]}" -gt "${BASH_REMATCH[2]}" ]; then
    echo "run-tests.sh: --shard wants K/N with 1 <= K <= N, got '$SHARD'" >&2
    exit 2
  fi
  SHARD_K=${BASH_REMATCH[1]}
  SHARD_N=${BASH_REMATCH[2]}
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
JOBS="${TEST_JOBS:-$(nproc 2>/dev/null || echo 2)}"
TIMEOUT="${TEST_TIMEOUT:-1800}"
LOG_DIR="${TEST_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/run-tests.XXXXXX")}"
mkdir -p "$LOG_DIR"
DURATIONS="${TEST_DURATIONS:-$ROOT/scripts/test-durations.tsv}"
MAKEFILE="${TEST_MAKEFILE:-$ROOT/Makefile}"

# Recipe lines for the targets, with backslash continuations joined. Only
# lines that run a test are kept: echo banners and comments are dropped.
CMDS="$LOG_DIR/cmds.txt"
make -s -n --no-print-directory -f "$MAKEFILE" "${TARGETS[@]}" |
  awk '{ if (sub(/\\$/, "")) { buf = buf $0; next } print buf $0; buf = "" }' |
  grep -E '(^|[[:space:]])(bash|python3 -m pytest)[[:space:]]' |
  grep -vE '^[[:space:]]*(echo|#)' >"$CMDS.raw" || true

if [ ! -s "$CMDS.raw" ]; then
  echo "run-tests.sh: no test commands found for: ${TARGETS[*]}" >&2
  exit 2
fi

# The --only filter (see the header). Under --list, whose stdout is the
# command list, banners go to stderr.
say() { if [ "$LIST" -eq 1 ]; then echo "$1" >&2; else echo "$1"; fi; }
if [ "$ONLY" != all ]; then
  ALL_N=$(wc -l <"$CMDS.raw")
  python3 - "$CMDS.raw" "$ROOT" "$ONLY" >"$CMDS.only" <<'PY'
import re, sys
root, spec = sys.argv[2], sys.argv[3]
want = [p for p in re.split(r"[\s,]+", spec) if p and p != "none"]
test_path = re.compile(r"(?:^|\s)(?:bash|python3 -m pytest)\s+(\S+)")
for line in open(sys.argv[1]):
    cmd = line.rstrip("\n")
    m = test_path.search(cmd)
    if not m:
        continue
    path = m.group(1)
    if path.startswith(root + "/"):
        path = path[len(root) + 1:]
    while path.startswith("./"):
        path = path[2:]
    if any(path == w or (w.endswith("/") and path.startswith(w)) for w in want):
        print(cmd)
PY
  mv "$CMDS.only" "$CMDS.raw"
  say "=== run-tests: --only '$ONLY' keeps $(wc -l <"$CMDS.raw") of $ALL_N commands ==="
  if [ ! -s "$CMDS.raw" ]; then
    say "=== run-tests: no test command selected, nothing to run ==="
    exit 0
  fi
fi

# Start order and shard split from the durations file (see the header).
# stdout: this shard's commands in start order. stderr: one
# "shard:commands:predicted-seconds" field per shard.
python3 - "$CMDS.raw" "$DURATIONS" "$ROOT" "$SHARD_K" "$SHARD_N" >"$CMDS" 2>"$LOG_DIR/shards.txt" <<'PY'
import statistics, sys
cmds = [l.rstrip("\n") for l in open(sys.argv[1]) if l.strip()]
root, k, n = sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
known = {}
try:
    for line in open(sys.argv[2]):
        if not line.strip() or line.startswith("#"):
            continue
        key, _, secs = line.rstrip("\n").rpartition("\t")
        try:
            known[key] = round(float(secs) * 10)  # integer tenths: exact sums
        except ValueError:
            pass
except FileNotFoundError:
    pass
default = round(statistics.median(known.values())) if known else 10
weights = [known.get(c.replace(root, "{ROOT}"), default) for c in cmds]
order = sorted(range(len(cmds)), key=lambda i: (-weights[i], i))
loads, shard_of = [0] * n, [0] * len(cmds)
for i in order:
    s = min(range(n), key=lambda j: (loads[j], j))
    shard_of[i] = s
    loads[s] += weights[i]
print("\n".join(cmds[i] for i in order if shard_of[i] == k - 1))
counts = [shard_of.count(j) for j in range(n)]
print(" ".join(f"{j + 1}:{counts[j]}:{loads[j] / 10:.1f}" for j in range(n)), file=sys.stderr)
PY

# An empty shard (more shards than commands) leaves one blank line.
sed -i '/^$/d' "$CMDS"
TOTAL=$(wc -l <"$CMDS")
if [ -n "$SHARD" ]; then
  SHARD_MSG="=== run-tests: shard $SHARD_K/$SHARD_N runs $TOTAL of $(wc -l <"$CMDS.raw") commands; predicted shard:commands:seconds $(cat "$LOG_DIR/shards.txt") ==="
  if [ "$LIST" -eq 1 ]; then echo "$SHARD_MSG" >&2; else echo "$SHARD_MSG"; fi
fi
if [ "$LIST" -eq 1 ]; then
  cat "$CMDS"
  exit 0
fi
RESULTS="$LOG_DIR/results.tsv"
: >"$RESULTS"
echo "=== run-tests: $TOTAL commands, $JOBS parallel, logs in $LOG_DIR ==="
if [ "$TOTAL" -eq 0 ]; then
  echo "=== run-tests: 0/0 ran, 0 failed (empty shard) ==="
  exit 0
fi

# One worker per command: run it, record "secs<TAB>rc<TAB>index<TAB>cmd", and
# print a one-line progress mark (short writes, so lines do not interleave).
# secs has one decimal, so short tests still weigh something in the
# durations file.
export LOG_DIR TIMEOUT RESULTS
run_one() {
  local i="$1" cmd="$2" s e rc
  s=$(date +%s%N)
  rc=0
  # No test inherits the developer's Claude Code session (#645): with it,
  # grill-me/planner telemetry registers scratch dirs in the real per-user
  # session marker. CI has no session id either; tests that need one set it.
  timeout --kill-after=30 "$TIMEOUT" env -u CLAUDE_CODE_SESSION_ID bash -c "$cmd" </dev/null >"$LOG_DIR/test-$i.log" 2>&1 || rc=$?
  e=$(date +%s%N)
  local ms=$(((e - s) / 1000000))
  local secs="$((ms / 1000)).$(((ms % 1000) / 100))"
  printf '%s\t%s\t%s\t%s\n' "$secs" "$rc" "$i" "$cmd" >>"$RESULTS"
  if [ "$rc" -eq 0 ]; then
    printf 'ok   %5ss  %s\n' "$secs" "$cmd"
  elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    printf 'TIMEOUT %ss  %s\n' "$secs" "$cmd"
  else
    printf 'FAIL %5ss  rc=%s  %s\n' "$secs" "$rc" "$cmd"
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
sort -t$'\t' -k1,1 -rn "$RESULTS" | awk -F'\t' 'NR <= 10 { printf "%6ss  %s\n", $1, $4 }'
SUM=$(awk -F'\t' '{ s += $1 } END { printf "%d", s }' "$RESULTS")
echo
echo "=== run-tests: $DONE/$TOTAL ran, $FAILED failed, wall ${WALL}s (serial sum ${SUM}s) ==="

if [ "$DONE" -ne "$TOTAL" ]; then
  echo "run-tests.sh: only $DONE of $TOTAL commands reported a result" >&2
  exit 1
fi
[ "$FAILED" -eq 0 ]
