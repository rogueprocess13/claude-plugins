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
} >"$TMP/Makefile"
echo "$TMP/t/test-slow.sh" >"$TMP/slow-first.txt"

run() {
  MARK_DIR="$TMP/marks" TEST_MAKEFILE="$TMP/Makefile" TEST_SLOW_FIRST="$TMP/slow-first.txt" \
    TEST_LOG_DIR="$TMP/logs-$1" bash "$RUNNER" "${@:2}" >"$TMP/out-$1.txt" 2>&1
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

echo "=== slow-first list moves a command to the front ==="
first=$(head -1 "$TMP/logs-good/cmds.txt")
[[ "$first" == *test-slow.sh ]] && ok "listed slow test runs first" || bad "first command was: $first"
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
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
