#!/usr/bin/env bash
# Tests for scripts/run-tests.sh — the parallel `make test` runner.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RUNNER="$ROOT/scripts/run-tests.sh"
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

# Fixture tests: each writes a marker so ordering and env can be checked.
mkdir -p "$TMP/t"
cat >"$TMP/t/test-pass.sh" <<'EOF'
echo "pass ran"; date +%s%N >"$MARK_DIR/pass"
EOF
cat >"$TMP/t/test-fail.sh" <<'EOF'
echo "detail line from the failing test"; exit 3
EOF
cat >"$TMP/t/test-env.sh" <<'EOF'
[ "${FIXTURE_VAR:-}" = "joined" ] || { echo "FIXTURE_VAR missing"; exit 1; }
EOF
cat >"$TMP/t/test-stdin.sh" <<'EOF'
# Reads stdin: must get EOF from /dev/null, not the runner's command list.
cat >/dev/null; echo "stdin drained"
EOF
cat >"$TMP/t/test-slow.sh" <<'EOF'
date +%s%N >"$MARK_DIR/slow"; sleep 1
EOF
cat >"$TMP/t/test-nosession.sh" <<'EOF'
[ -z "${CLAUDE_CODE_SESSION_ID+x}" ] || { echo "inherited session id: $CLAUDE_CODE_SESSION_ID"; exit 1; }
EOF
cat >"$TMP/t/test-ownsession.sh" <<'EOF'
[ "${CLAUDE_CODE_SESSION_ID:-}" = "own" ] || { echo "own session id lost: ${CLAUDE_CODE_SESSION_ID:-}"; exit 1; }
EOF
cat >"$TMP/t/test-hang.sh" <<'EOF'
sleep 30
EOF

# Fixture Makefile: banners, a comment, a backslash continuation carrying an
# env var, and tests spread over two targets.
{
  printf 'good:\n'
  printf '\t@echo "=== good ==="\n'
  printf '\t# a comment line\n'
  printf '\tbash %s/t/test-pass.sh\n' "$TMP"
  printf '\tFIXTURE_VAR=joined \\\n'
  printf '\tbash %s/t/test-env.sh\n' "$TMP"
  printf '\tbash %s/t/test-stdin.sh\n' "$TMP"
  printf '\tbash %s/t/test-slow.sh\n' "$TMP"
  printf 'bad:\n'
  printf '\tbash %s/t/test-fail.sh\n' "$TMP"
  printf 'hang:\n'
  printf '\tbash %s/t/test-hang.sh\n' "$TMP"
  printf 'many:\n'
  for _ in $(seq 1 200); do printf '\tbash %s/t/test-pass.sh\n' "$TMP"; done
  printf 'session:\n'
  printf '\tbash %s/t/test-nosession.sh\n' "$TMP"
  printf '\tCLAUDE_CODE_SESSION_ID=own bash %s/t/test-ownsession.sh\n' "$TMP"
  printf 'empty:\n'
  printf '\t@echo nothing here\n'
  # 13 distinct commands for the shard invariants: c01..c12 have a time in
  # the fixture durations file, unknown has none.
  printf 'shardset:\n'
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do printf '\tbash %s/t/test-pass.sh c%s\n' "$TMP" "$i"; done
  printf '\tbash %s/t/test-pass.sh unknown\n' "$TMP"
  # Three known times (1, 2, 3s; median 2) and one unknown command.
  printf 'weights:\n'
  printf '\tbash %s/t/test-pass.sh w1\n' "$TMP"
  printf '\tbash %s/t/test-pass.sh w2\n' "$TMP"
  printf '\tbash %s/t/test-pass.sh w3\n' "$TMP"
  printf '\tbash %s/t/test-pass.sh wunknown\n' "$TMP"
} >"$TMP/Makefile"
{
  echo "# fixture durations"
  printf 'bash %s/t/test-slow.sh\t5.0\n' "$TMP"
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    printf 'bash %s/t/test-pass.sh c%s\t%s.5\n' "$TMP" "$i" "$((10#$i * 3 % 7))"
  done
} >"$TMP/durations.tsv"
{
  printf 'bash %s/t/test-pass.sh w1\t1.0\n' "$TMP"
  printf 'bash %s/t/test-pass.sh w2\t2.0\n' "$TMP"
  printf 'bash %s/t/test-pass.sh w3\t3.0\n' "$TMP"
} >"$TMP/weights.tsv"

run() {
  MARK_DIR="$TMP/marks" TEST_MAKEFILE="$TMP/Makefile" TEST_DURATIONS="${DUR:-$TMP/durations.tsv}" \
    TEST_LOG_DIR="$TMP/logs-$1" bash "$RUNNER" "${@:2}" >"$TMP/out-$1.txt" 2>&1
}
# --list output only (stdout), the shard banner goes to $TMP/err-<name>.txt.
list() {
  local name="$1"
  shift
  MARK_DIR="$TMP/marks" TEST_MAKEFILE="$TMP/Makefile" TEST_DURATIONS="${DUR:-$TMP/durations.tsv}" \
    TEST_LOG_DIR="$TMP/logs-$name" bash "$RUNNER" --list "$@" 2>"$TMP/err-$name.txt"
}
mkdir -p "$TMP/marks"
export MARK_DIR="$TMP/marks"

echo "=== all passing targets exit 0, env from a continuation line survives ==="
TEST_JOBS=1 run good good
rc=$?
[ "$rc" -eq 0 ] && ok "good target exits 0" || bad "good target exit $rc: $(cat "$TMP/out-good.txt")"
grep -q "4/4 ran, 0 failed" "$TMP/out-good.txt" && ok "4 commands found, comment and banner skipped" ||
  bad "summary wrong: $(tail -3 "$TMP/out-good.txt")"
grep -q "ok .*test-env.sh" "$TMP/out-good.txt" && ok "continuation env var reached the test" ||
  bad "env test did not pass"
grep -q "ok .*test-stdin.sh" "$TMP/out-good.txt" && ok "stdin-reading test does not hang or eat the list" ||
  bad "stdin test did not pass"

echo "=== the durations file moves the slowest command to the front ==="
first=$(head -1 "$TMP/logs-good/cmds.txt")
[[ "$first" == *test-slow.sh ]] && ok "longest-measured test runs first" || bad "first command was: $first"
s=$(cat "$TMP/marks/slow") p=$(cat "$TMP/marks/pass")
[ "$s" -lt "$p" ] && ok "slow test started before Makefile-earlier pass test (TEST_JOBS=1)" ||
  bad "slow=$s pass=$p"

echo "=== a failure exits 1 and prints that test's full output ==="
TEST_JOBS=4 run bad good bad
rc=$?
[ "$rc" -eq 1 ] && ok "failing run exits 1" || bad "failing run exit $rc"
grep -q "FAIL .*rc=3 .*test-fail.sh" "$TMP/out-bad.txt" && ok "FAIL line names the test and rc" ||
  bad "no FAIL line"
grep -q "detail line from the failing test" "$TMP/out-bad.txt" && ok "failing test's log is printed" ||
  bad "failing log not printed"
grep -q "5/5 ran, 1 failed" "$TMP/out-bad.txt" && ok "other tests still ran" || bad "$(tail -2 "$TMP/out-bad.txt")"

echo "=== a test over TEST_TIMEOUT is reported and fails the run ==="
TEST_TIMEOUT=1 run hang hang
rc=$?
[ "$rc" -eq 1 ] && ok "timeout exits 1" || bad "timeout exit $rc"
grep -q "TIMEOUT .*test-hang.sh" "$TMP/out-hang.txt" && ok "TIMEOUT line printed" || bad "no TIMEOUT line"

echo "=== a large run finishes its summary (no SIGPIPE from the slowest-10 list) ==="
TEST_JOBS=8 run many many
rc=$?
[ "$rc" -eq 0 ] && ok "200-command run exits 0" || bad "200-command run exit $rc"
grep -q "200/200 ran, 0 failed" "$TMP/out-many.txt" && ok "summary line printed" ||
  bad "no summary: $(tail -2 "$TMP/out-many.txt")"

echo "=== a Claude Code session id is not inherited by test commands (#645) ==="
CLAUDE_CODE_SESSION_ID=developer-session run session session
rc=$?
[ "$rc" -eq 0 ] && ok "session id removed, a command's own id kept" ||
  bad "session target exit $rc: $(cat "$TMP/out-session.txt")"
grep -q "2/2 ran, 0 failed" "$TMP/out-session.txt" && ok "both session commands ran" ||
  bad "$(tail -2 "$TMP/out-session.txt")"

echo "=== a target with no test commands is a usage error ==="
run empty empty
rc=$?
[ "$rc" -eq 2 ] && ok "no commands exits 2" || bad "empty exit $rc"
bash "$RUNNER" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "no targets exits 2" || bad "no-arg exit $rc"

echo "=== the real Makefile yields every registered test command ==="
n=$(make -s -n --no-print-directory -C "$ROOT" test-lib test-fleetd test-planner test-flow test-kc test-grill test-planner-intent-gate |
  awk '{ if (sub(/\\$/, "")) { buf = buf $0; next } print buf $0; buf = "" }' |
  grep -E '(^|[[:space:]])(bash|python3 -m pytest)[[:space:]]' | grep -vcE '^[[:space:]]*(echo|#)')
[ "$n" -gt 200 ] && ok "real Makefile parses to $n commands" || bad "only $n commands from the real Makefile"

echo "=== shards 1..N together run every command exactly once (N = 1..6) ==="
full=$(list full shardset | sort)
[ "$(wc -l <<<"$full")" -eq 13 ] && ok "fixture has 13 commands" || bad "fixture list: $full"
for N in 1 2 3 4 5 6; do
  : >"$TMP/union-$N.txt"
  for K in $(seq 1 "$N"); do
    list "u$N-$K" --shard "$K/$N" shardset >>"$TMP/union-$N.txt"
  done
  union=$(sort "$TMP/union-$N.txt")
  dups=$(uniq -d <<<"$union")
  if [ "$union" = "$full" ] && [ -z "$dups" ]; then
    ok "N=$N: union equals the full list, no command in two shards"
  else
    bad "N=$N: union differs or has duplicates: $dups"
  fi
done

echo "=== the split is deterministic ==="
a=$(list det1 --shard 3/4 shardset)
b=$(list det2 --shard 3/4 shardset)
c=$(TEST_SHARD=3/4 list det3 shardset)
[ "$a" = "$b" ] && [ "$(cat "$TMP/err-det1.txt")" = "$(cat "$TMP/err-det2.txt")" ] &&
  ok "same shard, same commands and predicted loads" || bad "two runs differ: [$a] vs [$b]"
[ "$a" = "$c" ] && ok "TEST_SHARD=3/4 equals --shard 3/4" || bad "TEST_SHARD gave [$c]"
tac "$TMP/durations.tsv" >"$TMP/durations-rev.tsv"
d=$(DUR="$TMP/durations-rev.tsv" list det4 --shard 3/4 shardset)
[ "$a" = "$d" ] && ok "line order in the durations file does not matter" || bad "reordered file gave [$d]"

echo "=== a command missing from the durations file gets the median weight ==="
DUR="$TMP/weights.tsv" list w1 --shard 1/1 weights >/dev/null
grep -q "1:4:8.0" "$TMP/err-w1.txt" && ok "1+2+3 known + 2 (median) for the unknown = 8.0" ||
  bad "loads: $(cat "$TMP/err-w1.txt")"
DUR="$TMP/weights.tsv" list w2 --shard 1/2 weights >/dev/null
grep -q "1:2:4.0 2:2:4.0" "$TMP/err-w2.txt" && ok "LPT split 3+1 / 2+2" ||
  bad "loads: $(cat "$TMP/err-w2.txt")"
nofile=$(DUR="$TMP/no-such-file.tsv" list w3 --shard 1/1 weights)
[ "$(wc -l <<<"$nofile")" -eq 4 ] && ok "a missing durations file still runs every command" ||
  bad "missing file listed: $nofile"

echo "=== --shard with bad input exits 2 ==="
for bad_shard in 0/4 5/4 1/0 x 4 1/4/2 -1/4 a/b " 1/4" 1000/1000; do
  MARK_DIR="$TMP/marks" TEST_MAKEFILE="$TMP/Makefile" bash "$RUNNER" --shard "$bad_shard" shardset >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] && ok "--shard '$bad_shard' exits 2" || bad "--shard '$bad_shard' exit $rc"
done
TEST_SHARD=9/3 TEST_MAKEFILE="$TMP/Makefile" bash "$RUNNER" shardset >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "TEST_SHARD=9/3 exits 2" || bad "TEST_SHARD=9/3 exit $rc"
TEST_MAKEFILE="$TMP/Makefile" bash "$RUNNER" shardset --shard >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "--shard with no value exits 2" || bad "--shard with no value exit $rc"
TEST_MAKEFILE="$TMP/Makefile" bash "$RUNNER" --bogus shardset >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "unknown option exits 2" || bad "unknown option exit $rc"

echo "=== a sharded run runs only its shard, and an empty shard passes ==="
TEST_JOBS=4 run shard2 --shard 2/3 shardset
rc=$?
want=$(list want2 --shard 2/3 shardset | wc -l)
[ "$rc" -eq 0 ] && grep -q "$want/$want ran, 0 failed" "$TMP/out-shard2.txt" &&
  ok "shard 2/3 ran its $want commands" || bad "shard run: $(tail -3 "$TMP/out-shard2.txt")"
grep -q "shard 2/3 runs $want of 13 commands" "$TMP/out-shard2.txt" && ok "shard banner names the split" ||
  bad "no shard banner: $(head -2 "$TMP/out-shard2.txt")"
run empty-shard --shard 5/5 weights
rc=$?
[ "$rc" -eq 0 ] && grep -q "0/0 ran" "$TMP/out-empty-shard.txt" && ok "shard with no commands exits 0" ||
  bad "empty shard exit $rc: $(tail -2 "$TMP/out-empty-shard.txt")"

echo "=== --only keeps the commands under its entries, before the shard split ==="
only_env=$(list only1 --only "$TMP/t/test-env.sh" good)
[ "$only_env" = "FIXTURE_VAR=joined bash $TMP/t/test-env.sh" ] &&
  ok "--only FILE keeps that command, env prefix included" || bad "--only FILE gave [$only_env]"
[ "$(list only2 --only "$TMP/t/test-env.sh,$TMP/t/test-slow.sh" good | wc -l)" -eq 2 ] &&
  ok "--only takes a comma-separated list" || bad "comma list did not keep 2"
[ "$(list only3 --only "$TMP/t/" good | wc -l)" -eq 4 ] &&
  ok "--only DIR/ keeps every command under it" || bad "dir prefix did not keep all 4"
[ "$(TEST_ONLY="$TMP/t/test-slow.sh" list only4 good)" = "bash $TMP/t/test-slow.sh" ] &&
  ok "TEST_ONLY equals --only" || bad "TEST_ONLY ignored"
[ "$(list only5 --only all good | wc -l)" -eq 4 ] && ok "--only all keeps everything" || bad "--only all dropped commands"
[ "$(list only6 --only "$TMP/t/test-pas" good | wc -l)" -eq 0 ] &&
  ok "an entry without a trailing / matches whole paths only" || bad "partial path matched"
: >"$TMP/only-union.txt"
for K in 1 2 3 4; do list "only-s$K" --only "$TMP/t/test-slow.sh" --shard "$K/4" good >>"$TMP/only-union.txt"; done
[ "$(cat "$TMP/only-union.txt")" = "bash $TMP/t/test-slow.sh" ] &&
  ok "1 selected command over 4 shards: one shard runs it, three are empty" ||
  bad "subset shards gave [$(cat "$TMP/only-union.txt")]"
grep -q "keeps 1 of 4 commands" "$TMP/err-only-s1.txt" && ok "--only banner goes to stderr under --list" ||
  bad "no --only banner: $(cat "$TMP/err-only-s1.txt")"
run only-none --only none good
rc=$?
[ "$rc" -eq 0 ] && grep -q "nothing to run" "$TMP/out-only-none.txt" && [ ! -e "$TMP/logs-only-none/results.tsv" ] &&
  ok "--only none runs nothing and exits 0" || bad "--only none exit $rc: $(cat "$TMP/out-only-none.txt")"
TEST_JOBS=2 run only-shard --only "$TMP/t/test-slow.sh" --shard 3/4 good
rc=$?
[ "$rc" -eq 0 ] && grep -q "0/0 ran" "$TMP/out-only-shard.txt" && ok "an empty shard of a subset exits 0" ||
  bad "empty subset shard exit $rc: $(tail -2 "$TMP/out-only-shard.txt")"
TEST_MAKEFILE="$TMP/Makefile" bash "$RUNNER" good --only >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "--only with no value exits 2" || bad "--only with no value exit $rc"

echo "=== shard loads on the real Makefile are balanced ==="
read -r -a targets <<<"$(make -s --no-print-directory -C "$ROOT" print-test-targets)"
real_all=$(TEST_LOG_DIR="$TMP/real" bash "$RUNNER" --list "${targets[@]}" 2>/dev/null | sort)
: >"$TMP/real-union.txt"
for K in 1 2 3 4; do
  TEST_LOG_DIR="$TMP/real" bash "$RUNNER" --list --shard "$K/4" "${targets[@]}" >>"$TMP/real-union.txt" 2>"$TMP/real-err.txt"
done
[ "$(sort "$TMP/real-union.txt")" = "$real_all" ] && ok "real Makefile: 4 shards cover all $(wc -l <<<"$real_all") commands once" ||
  bad "real Makefile: shard union differs from the full list"
loads=$(grep -oE '([0-9]+:[0-9]+:[0-9.]+ ?)+' "$TMP/real-err.txt")
echo "  predicted shard:commands:seconds  $loads"
spread=$(python3 -c '
import sys
s = [float(f.split(":")[2]) for f in sys.argv[1].split()]
print(f"{max(s) / min(s):.3f}")' "$loads")
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= 1.10 else 1)' "$spread" &&
  ok "heaviest shard is ${spread}x the lightest (limit 1.10)" || bad "shard spread ${spread}x over 1.10"
durations_missing=$(
  python3 - "$ROOT" "$TMP/real-union.txt" <<'PY'
import sys
root = sys.argv[1]
known = {l.rstrip("\n").rpartition("\t")[0] for l in open(f"{root}/scripts/test-durations.tsv") if not l.startswith("#")}
print(sum(1 for c in open(sys.argv[2]) if c.rstrip("\n").replace(root, "{ROOT}") not in known))
PY
)
echo "  commands without a measured time (weighted by the median): $durations_missing"

echo "=== update-test-durations.sh ==="
UPD="$ROOT/scripts/update-test-durations.sh"
{
  printf '1.2\t0\t1\tbash a.sh\n'
  printf '30.0\t124\t2\tbash hang.sh\n'
  printf '4.5\t0\t3\tFOO="%s/lib" bash b.sh\n' "$ROOT"
  printf '0.3\t1\t4\tbash a.sh\n'
} >"$TMP/r1.tsv"
printf '2.0\t0\t1\tbash a.sh\n' >"$TMP/r2.tsv"
bash "$UPD" --out "$TMP/dur-out.tsv" "$TMP/r1.tsv" "$TMP/r2.tsv" >/dev/null
rc=$?
body=$(grep -v '^#' "$TMP/dur-out.tsv")
want=$(printf 'FOO="{ROOT}/lib" bash b.sh\t4.5\nbash a.sh\t2.0')
[ "$rc" -eq 0 ] && [ "$body" = "$want" ] &&
  ok "root written as {ROOT}, timeout dropped, max kept, slowest first" || bad "got rc=$rc: $body"
bash "$UPD" --out "$TMP/dur-none.tsv" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "no results file exits 2" || bad "no results file exit $rc"
printf '30.0\t124\t2\tbash hang.sh\n' >"$TMP/r3.tsv"
bash "$UPD" --out "$TMP/dur-none.tsv" "$TMP/r3.tsv" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$TMP/dur-none.tsv" ] && ok "no usable line exits 2 and writes nothing" ||
  bad "no usable line exit $rc"
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
