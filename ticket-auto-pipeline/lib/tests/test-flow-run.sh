#!/usr/bin/env bash
# test-flow-run.sh — lib/flow-run.sh, the one shell entry point for firing a
# ticket-flow trigger (review findings DET-IP-1 / DET-RV-20), plus a guard that
# no skill/agent/preamble markdown goes back to the broken pattern
#
#   /ticket-flow {TICKET-ID} <trigger>      <- a slash command, not a shell command
#   _rc=$?                                  <- so this rc is meaningless
#
# Covers:
#   1. Happy path: rc 0, args reach flow.sh, no log line, FLOW_RC=0.
#   2. Every documented exit code is propagated unchanged (1 3 8 9 10 11 42 + an
#      unlisted one), with the documented log line / heartbeat for each.
#   3. flow.sh not found → 127 + META|flow-error line.
#   4. Arguments with spaces, quotes, `|` and `=` reach flow.sh verbatim.
#   5. --log-file: consumed (never forwarded), exported to flow.sh as LOG_FILE,
#      empty value falls back to $LOG_FILE, no log at all → no write.
#   6. Resolution order: FLOW_RUN_FLOW_SH > ~/.claude/skills/ticket-flow > cache
#      (version order via tap_cache_find, 0.62.7 beats 0.9.4).
#   7. Guard: no `/ticket-flow …` slash call followed by `$?` inside a fenced
#      block; every flow-run.sh call for a verdict-gated trigger branches on 11.
#
# Run: bash ticket-auto-pipeline/lib/tests/test-flow-run.sh

set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PLUGIN_ROOT="$(cd "${LIB_DIR}/.." && pwd)"
FLOW_RUN="${LIB_DIR}/flow-run.sh"

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

# Isolated HOME with no flow.sh anywhere; HB_LOG_FILE unset unless a test sets it.
export HOME="${TMP}/home"
mkdir -p "$HOME"
unset LOG_FILE HB_LOG_FILE FLOW_RUN_FLOW_SH

# Stub flow.sh: writes each argv element on its own line, plus the LOG_FILE it
# saw, then exits with $STUB_RC.
STUB="${TMP}/stub/flow.sh"
mkdir -p "$(dirname "$STUB")"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
: >"$STUB_ARGS"
for a in "$@"; do printf '%s\n' "$a" >>"$STUB_ARGS"; done
printf '%s\n' "${LOG_FILE:-<unset>}" >"$STUB_ENV"
echo "stub flow.sh ran"
exit "${STUB_RC:-0}"
EOF
export STUB_ARGS="${TMP}/args" STUB_ENV="${TMP}/env"

run_wrapper() {
  # run_wrapper <rc> <args...> — sets OUT and RC
  local want_rc="$1"
  shift
  RC=0
  OUT=$(STUB_RC="$want_rc" FLOW_RUN_FLOW_SH="$STUB" bash "$FLOW_RUN" "$@" 2>"${TMP}/stderr") || RC=$?
}

# ── 1. Happy path ────────────────────────────────────────────────────────────
echo "--- 1: happy path ---"
LOG="${TMP}/happy.log"
: >"$LOG"
run_wrapper 0 --log-file "$LOG" TEST-1 appraise-start --data complexity=simple
expect "1: rc 0" 0 "$RC"
expect "1: args forwarded" "TEST-1|appraise-start|--data|complexity=simple" "$(paste -sd'|' "$STUB_ARGS")"
expect "1: no log line on success" 0 "$(wc -l <"$LOG" | tr -d ' ')"
echo "$OUT" | grep -qx 'FLOW_RC=0' && pass "1: FLOW_RC=0 printed" || fail "1: FLOW_RC=0 printed" "$OUT"
echo "$OUT" | grep -qx 'FLOW_GATE_BLOCKED=false' && pass "1: FLOW_GATE_BLOCKED=false" || fail "1: FLOW_GATE_BLOCKED=false" "$OUT"
echo "$OUT" | grep -qx 'FLOW_TRIGGER=appraise-start' && pass "1: FLOW_TRIGGER printed" || fail "1: FLOW_TRIGGER printed" "$OUT"
echo "$OUT" | grep -q 'stub flow.sh ran' && pass "1: flow.sh stdout passed through" || fail "1: flow.sh stdout passed through" "$OUT"

# ── 2. Exit codes propagated ─────────────────────────────────────────────────
echo "--- 2: exit codes ---"
for code in 1 3 8 9 10 42 5; do
  LOG="${TMP}/rc${code}.log"
  : >"$LOG"
  run_wrapper "$code" --log-file "$LOG" TEST-1 needs-info
  expect "2: rc ${code} propagated" "$code" "$RC"
  n=$(grep -c "|META|flow-error|fail|exit ${code}: needs-info\$" "$LOG" || true)
  expect "2: rc ${code} writes exactly one META|flow-error line" 1 "$n"
  grep -q 'gate-stop' "$LOG" && fail "2: rc ${code} no gate-stop line" "$(cat "$LOG")" || pass "2: rc ${code} no gate-stop line"
done

LOG="${TMP}/rc11.log"
: >"$LOG"
run_wrapper 11 --log-file "$LOG" TEST-1 uat-pass
expect "2: rc 11 propagated" 11 "$RC"
expect "2: rc 11 writes one VERDICT_GATE_BLOCKED gate-stop" 1 \
  "$(grep -c '|META|gate-stop|fail|VERDICT_GATE_BLOCKED — uat-pass refused, see flow.sh stderr$' "$LOG" || true)"
expect "2: rc 11 writes no flow-error line" 0 "$(grep -c 'flow-error' "$LOG" || true)"
echo "$OUT" | grep -qx 'FLOW_GATE_BLOCKED=true' && pass "2: rc 11 FLOW_GATE_BLOCKED=true" || fail "2: rc 11 FLOW_GATE_BLOCKED=true" "$OUT"
echo "$OUT" | grep -qx 'FLOW_RC=11' && pass "2: rc 11 FLOW_RC=11" || fail "2: rc 11 FLOW_RC=11" "$OUT"

# Heartbeats: hb-wrap.sh is a no-op without HB_LOG_FILE; with it, 11 → gate and
# a generic failure → retry with an error_type.
HBL="${TMP}/hb.log"
: >"$HBL"
RC=0
STUB_RC=11 HB_LOG_FILE="$HBL" FLOW_RUN_FLOW_SH="$STUB" bash "$FLOW_RUN" TEST-1 uat-pass >/dev/null 2>&1 || RC=$?
expect "2: rc 11 with heartbeat still 11" 11 "$RC"
grep -q '|gate|verdict-gate|fail|' "$HBL" && pass "2: rc 11 heartbeat gate verdict-gate fail" || fail "2: rc 11 heartbeat gate" "$(cat "$HBL")"
: >"$HBL"
STUB_RC=9 HB_LOG_FILE="$HBL" FLOW_RUN_FLOW_SH="$STUB" bash "$FLOW_RUN" TEST-1 uat-pass >/dev/null 2>&1 || true
grep -q '|retry|flow-sh|fail|.*"error_type":"fence"' "$HBL" && pass "2: rc 9 heartbeat retry error_type=fence" || fail "2: rc 9 heartbeat" "$(cat "$HBL")"

# ── 3. flow.sh not found ─────────────────────────────────────────────────────
echo "--- 3: flow.sh not found ---"
LOG="${TMP}/nf.log"
: >"$LOG"
RC=0
OUT=$(bash "$FLOW_RUN" --log-file "$LOG" TEST-1 needs-info 2>/dev/null) || RC=$?
expect "3: rc 127" 127 "$RC"
expect "3: META|flow-error not-found line" 1 "$(grep -c '|META|flow-error|fail|flow.sh not found: needs-info$' "$LOG" || true)"
echo "$OUT" | grep -qx 'FLOW_RC=127' && pass "3: FLOW_RC=127" || fail "3: FLOW_RC=127" "$OUT"
RC=0
FLOW_RUN_FLOW_SH="${TMP}/does-not-exist.sh" bash "$FLOW_RUN" TEST-1 needs-info >/dev/null 2>&1 || RC=$?
expect "3: dangling FLOW_RUN_FLOW_SH with nothing else → 127" 127 "$RC"

# Usage errors never reach flow.sh.
RC=0
FLOW_RUN_FLOW_SH="$STUB" bash "$FLOW_RUN" TEST-1 >/dev/null 2>&1 || RC=$?
expect "3: missing trigger → usage exit 1" 1 "$RC"

# ── 4. Arguments with spaces / quotes ────────────────────────────────────────
echo "--- 4: argument passthrough ---"
reason='human said "ship it" | it'"'"'s fine = ok'
run_wrapper 0 TEST-1 uat-pass --override "$reason" --provenance policy --data "outcome=Rough edges"
expect "4: arg count" 8 "$(wc -l <"$STUB_ARGS" | tr -d ' ')"
expect "4: --override value verbatim" "$reason" "$(sed -n 4p "$STUB_ARGS")"
expect "4: --data value with space verbatim" "outcome=Rough edges" "$(sed -n 8p "$STUB_ARGS")"

# A trigger containing | or " cannot break the log line grammar.
LOG="${TMP}/pipe.log"
: >"$LOG"
run_wrapper 3 --log-file "$LOG" TEST-1 'bad|trig"ger'
expect "4: hostile trigger rc" 3 "$RC"
expect "4: hostile trigger log line stays 5 fields" 5 "$(awk -F'|' '{print NF}' "$LOG")"

# ── 5. --log-file handling ───────────────────────────────────────────────────
echo "--- 5: --log-file ---"
LOG="${TMP}/lf.log"
: >"$LOG"
run_wrapper 0 TEST-1 needs-info --log-file "$LOG"
grep -q -- '--log-file' "$STUB_ARGS" && fail "5: --log-file not forwarded" "$(cat "$STUB_ARGS")" || pass "5: --log-file not forwarded"
expect "5: LOG_FILE exported to flow.sh" "$LOG" "$(cat "$STUB_ENV")"

ENVLOG="${TMP}/envlog.log"
: >"$ENVLOG"
RC=0
LOG_FILE="$ENVLOG" STUB_RC=8 FLOW_RUN_FLOW_SH="$STUB" bash "$FLOW_RUN" --log-file "" TEST-1 needs-info >/dev/null 2>&1 || RC=$?
expect "5: empty --log-file falls back to \$LOG_FILE" 1 "$(grep -c 'flow-error|fail|exit 8' "$ENVLOG" || true)"
(cd "$TMP" && LOG_FILE="$ENVLOG" STUB_RC=8 FLOW_RUN_FLOW_SH="$STUB" bash "$FLOW_RUN" --log-file "{LOG_FILE}" TEST-1 needs-info >/dev/null 2>&1) || true
expect "5: unsubstituted {LOG_FILE} placeholder falls back to \$LOG_FILE" 2 "$(grep -c 'flow-error|fail|exit 8' "$ENVLOG" || true)"
[ -e "${TMP}/{LOG_FILE}" ] && fail "5: no file literally named {LOG_FILE}" "created" || pass "5: no file literally named {LOG_FILE}"

RC=0
(cd "$TMP" && STUB_RC=3 FLOW_RUN_FLOW_SH="$STUB" bash "$FLOW_RUN" TEST-1 needs-info >/dev/null 2>&1) || RC=$?
expect "5: no log file → still propagates rc" 3 "$RC"
expect "5: no log file → flow.sh sees LOG_FILE unset" "<unset>" "$(cat "$STUB_ENV")"

# ── 6. Resolution order ──────────────────────────────────────────────────────
echo "--- 6: resolution order ---"
mkstub() {
  # mkstub <path> <tag> — a flow.sh that echoes TAG=<tag>
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\necho TAG=%s\n' "$2" >"$1"
}
CACHE="${HOME}/.claude/plugins/cache/willard-pro-claude-plugins/ticket-auto-pipeline"
mkstub "${CACHE}/0.9.4/skills/ticket-flow/flow.sh" cache-0.9.4
mkstub "${CACHE}/0.62.7/skills/ticket-flow/flow.sh" cache-0.62.7
got=$(bash "$FLOW_RUN" TEST-1 needs-info 2>/dev/null | sed -n 's/^TAG=//p')
expect "6: cache picks 0.62.7 over 0.9.4" cache-0.62.7 "$got"
mkstub "${HOME}/.claude/skills/ticket-flow/flow.sh" home
got=$(bash "$FLOW_RUN" TEST-1 needs-info 2>/dev/null | sed -n 's/^TAG=//p')
expect "6: ~/.claude/skills copy beats the cache" home "$got"
mkstub "${TMP}/override/flow.sh" override
got=$(FLOW_RUN_FLOW_SH="${TMP}/override/flow.sh" bash "$FLOW_RUN" TEST-1 needs-info 2>/dev/null | sed -n 's/^TAG=//p')
expect "6: FLOW_RUN_FLOW_SH beats everything" override "$got"

# ── 7. Guard: no slash-command-with-$? and exit 11 handled at gated sites ─────
echo "--- 7: call-site guard ---"
GUARD_FILES=$(find "${PLUGIN_ROOT}/skills" "${PLUGIN_ROOT}/agents" "${PLUGIN_ROOT}/lib" "${PLUGIN_ROOT}/docs" \
  -path '*/tests' -prune -o -type f -name '*.md' -print | sort)

# 7a. Inside a ``` fence, a line that starts with `/ticket-flow ` followed
# within 3 lines by `$?`.
slash_hits=$(echo "$GUARD_FILES" | xargs awk '
  FNR == 1 { fence = 0; pend = 0 }
  /^[[:space:]]*```/ { fence = !fence; pend = 0; next }
  fence && /^[[:space:]]*\/ticket-flow[[:space:]]/ { pend = 3; at = FNR; next }
  fence && pend > 0 { if ($0 ~ /\$\?/) print FILENAME ":" at; pend-- }
' || true)
if [ -z "$slash_hits" ]; then
  pass "7a: no /ticket-flow slash call read through \$? in a fenced block"
else
  fail "7a: /ticket-flow slash call read through \$?" "$(echo "$slash_hits" | sed "s|${PLUGIN_ROOT}/||" | tr '\n' ' ')"
fi

# 7b. Every flow-run.sh call naming a verdict-gated trigger (or a variable
# trigger, which may resolve to one) must branch on exit 11 within 12 lines.
GATED=$(jq -r '.triggers | to_entries[] | select(.value.verdict_gate == true) | .key' \
  "${PLUGIN_ROOT}/skills/ticket-flow/workflow.json" | paste -sd'|')
[ -n "$GATED" ] || fail "7b: workflow.json lists verdict-gated triggers" "none found"
gate_hits=$(echo "$GUARD_FILES" | xargs awk -v gated="$GATED" '
  FNR == 1 { fence = 0; want = 0 }
  /^[[:space:]]*```/ { fence = !fence; if (want) { print FILENAME ":" at; want = 0 }; next }
  fence && /flow-run\.sh/ && !/^[[:space:]]*#/ {
    if (want) print FILENAME ":" at
    n = split($0, w, /[[:space:]]+/); trig = ""
    for (i = 1; i <= n; i++) if (w[i] ~ /^\{TICKET[-_]ID\}$|^"?\$\{?TICKET[-_]ID\}?"?$/) { trig = w[i + 1]; break }
    gsub(/"/, "", trig)
    want = (trig ~ "^(" gated ")$" || trig ~ /^\$/) ? 1 : 0
    at = FNR; left = 12; next
  }
  want { if ($0 ~ /-eq 11/) want = 0; else if (--left == 0) { print FILENAME ":" at; want = 0 } }
' || true)
if [ -z "$gate_hits" ]; then
  pass "7b: every gated flow-run.sh call site branches on exit 11"
else
  fail "7b: gated flow-run.sh call without an exit-11 branch" "$(echo "$gate_hits" | sed "s|${PLUGIN_ROOT}/||" | tr '\n' ' ')"
fi

# 7c. At least the known call sites use the wrapper (catches the guard going
# vacuous if the call-site syntax drifts).
n_calls=$(echo "$GUARD_FILES" | xargs grep -h 'flow-run\.sh' | grep -cv '^[[:space:]]*#' || true)
[ "$n_calls" -ge 12 ] && pass "7c: ${n_calls} flow-run.sh references in skill/agent/lib markdown" ||
  fail "7c: flow-run.sh call sites" "only ${n_calls} found"

echo ""
echo "flow-run: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
