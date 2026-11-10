#!/usr/bin/env bash
# test-verify-mode.sh — unit tests for lib/verify-mode.sh
# (skill-deterministic-extraction 4).
#
# fixtures/verify-mode/<case>.out were produced by running the pre-extraction
# ticket-verify SKILL.md Step 1e block (main @ eacacbf) over the workspaces
# the _case_* functions below build — never by verify-mode.sh. Timestamps are
# masked to TS. fixtures/verify-mode/gate-<case>.out were produced the same
# way from gate-check.sh Check 2.6's classification block at eacacbf.
#
# Usage: bash test-verify-mode.sh
# With VERIFY_MODE_TEST_LIB_ONLY=1 the file only defines its helpers.
set -eo pipefail

VM_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_LIB_DIR="$(cd "$VM_TEST_DIR/.." && pwd)"
VM="$VM_LIB_DIR/verify-mode.sh"
VM_FX="$VM_TEST_DIR/fixtures/verify-mode"
TID="T-1"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION TICKETS_ROOT

VM_CASES="browser build_simple_fix live_keyword live_na_full_stack live_na_plain browser_beats_build live_beats_build no_signals no_files"
VM_GATE_CASES="g_browser g_build g_make g_api g_infra g_infra_feature g_user_only g_nav_set g_dir"

_ws_new() {
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/logs" "$WS/home" "$WS/tickets/$TID--fix-thing"
  mkdir -m 700 "$WS/scratch"
  export HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch" CLAUDE_SKILLS_LIB="$VM_LIB_DIR"
  export TICKETS_ROOT="$WS/tickets"
  TD="$WS/tickets/$TID--fix-thing"
  export TAP_LOG="$WS/logs/$TID-pipeline.log"
  : >"$TAP_LOG"
}
_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }
_mask() { sed -e "s|$WS|\$WS|g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g'; }

_case_browser() { printf '## Plan\nClick the Save button on the handover page.\n' >"$TD/notes.md"; }
_case_build_simple_fix() {
  printf '# Simple fix\nRun mvn clean install; expect BUILD SUCCESS.\n' >"$TD/simple-fix.md"
  printf 'notes mention nothing\n' >"$TD/notes.md"
}
_case_live_keyword() { printf 'Service must register with Eureka on startup.\n' >"$TD/context.md"; }
_case_live_na_full_stack() { printf '**Test User:** N/A\nEnvironment: full stack running locally\n' >"$TD/context.md"; }
# The bold form "**Test User:** N/A" never matches the old regex (it expects
# the stars before the colon, and at least one star); "**Test User**: N/A" does. Pinned as-is.
_case_live_na_plain() { printf '**Test User**: N/A\nEnvironment: full stack running locally\n' >"$TD/context.md"; }
_case_browser_beats_build() { printf 'Update pom.xml, then login and check the dashboard.\n' >"$TD/notes.md"; }
_case_live_beats_build() { printf 'pom.xml gains resilience4j; circuit breaker opens on downstream failure.\n' >"$TD/notes.md"; }
_case_no_signals() { printf 'Refactor the repository class.\n' >"$TD/notes.md"; }
_case_no_files() { :; }

# Gate cases: artifact text, has_nav_path, has_test_user.
_gcase() { # name -> sets GA (artifact path), GN, GU
  GA="$WS/artifact.md"
  GN=0 GU=0
  case "$1" in
  g_browser) printf 'Open the page and click Save.\n' >"$GA" ;;
  g_build) printf 'Run mvn clean compile; BUILD SUCCESS.\n' >"$GA" ;;
  g_make) printf 'Run make seed-demo and confirm it succeeds.\n' >"$GA" ;;
  g_api) printf 'POST /api/x returns 201.\n' >"$GA" ;;
  g_infra)
    printf 'Check Eureka at localhost:8761 lists the service.\n' >"$GA"
    GU=1
    ;;
  g_infra_feature)
    printf 'Check eureka, then /admin/ settings.\n' >"$GA"
    GU=1
    ;;
  g_user_only)
    printf 'Log in at localhost:4200 and check things.\n' >"$GA"
    GU=1
    ;;
  g_nav_set)
    printf 'mvn clean install\n' >"$GA"
    GN=1
    ;;
  g_dir)
    GA="$WS/change-dir"
    mkdir -p "$GA"
    ;;
  esac
}

_new_out() { # case -> stdout + masked log of the script
  "_case_$1"
  bash "$VM" "$TID" --ticket-dir "$TD" --root "$TICKETS_ROOT"
  _mask <"$TAP_LOG"
}

[ "${VERIFY_MODE_TEST_LIB_ONLY:-0}" = 1 ] && return 0

PASS=0 FAIL=0
_ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
_ko() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

echo "=== verify-mode.sh: ticket-verify Step 1e parity ==="
for c in $VM_CASES; do
  _ws_new
  got=$(_new_out "$c" | _mask)
  want=$(cat "$VM_FX/$c.out")
  if [ "$got" = "$want" ]; then _ok "$c"; else
    _ko "$c"
    diff <(echo "$want") <(echo "$got") | sed 's/^/    /' || true
  fi
  _ws_rm
done

echo "=== verify-mode.sh: gate-check Check 2.6 class parity ==="
# shellcheck source=/dev/null
source "$VM"
for c in $VM_GATE_CASES; do
  _ws_new
  _gcase "$c"
  got=$(verify_mode_gate_class "$GA" "$GN" "$GU")
  want=$(cat "$VM_FX/gate-$c.out")
  [ "$got" = "$want" ] && _ok "gate $c ($got)" || _ko "gate $c: want $want got $got"
  _ws_rm
done

echo "=== CLI ==="
_ws_new
_case_live_keyword
out=$(bash "$VM" "$TID" --ticket-dir "$TD" --no-log)
[ "$out" = "VERIFY_MODE=live-backend" ] && [ ! -s "$TAP_LOG" ] && _ok "--no-log prints the mode, writes nothing" || _ko "--no-log: $out"
printf 'Click the login button.\n' >"$WS/desc.txt"
out=$(bash "$VM" "$TID" --ticket-dir "$TD" --no-log --description-file "$WS/desc.txt")
[ "$out" = "VERIFY_MODE=browser" ] && _ok "--description-file text counts as a signal" || _ko "--description-file: $out"
rc=0
bash "$VM" "$TID" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && _ok "missing --ticket-dir -> exit 2" || _ko "missing --ticket-dir rc=$rc"
rc=0
bash "$VM" "$TID" --ticket-dir >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && _ok "--ticket-dir without value -> exit 2" || _ko "--ticket-dir no value rc=$rc"
_ws_rm

echo "=== gate-check.sh calls verify-mode.sh (no second classifier) ==="
gc="$VM_LIB_DIR/gate-check.sh"
if grep -q 'verify_mode_gate_class' "$gc" && ! grep -q '_build_signals=' "$gc" && ! grep -q '_infra_named_signals=' "$gc"; then
  _ok "gate-check.sh classifies through verify_mode_gate_class only"
else
  _ko "gate-check.sh carries its own classification regexes"
fi

echo ""
echo "verify-mode: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
