#!/usr/bin/env bash
# test-verify-mode.sh — unit tests for lib/verify-mode.sh
# (skill-deterministic-extraction 4).
#
# fixtures/verify-mode/<case>.out were produced by running the pre-extraction
# ticket-verify SKILL.md Step 1e block (main @ eacacbf) over the workspaces
# the _case_* functions below build — never by verify-mode.sh. Timestamps are
# masked to TS. One fixture moved on purpose since: live_na_full_stack is
# live-backend now that the bold "**Test User:** N/A" form matches (decision 3
# of skill-deterministic-extraction, readiness + mode unification).
# The gate profile cases (verify_mode_gate_profile) carry their expected
# profile inline: it is the verify classification mapped to a prerequisite
# profile, not a parity fixture.
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
# name|expected profile (old verify_mode_gate_class answer, for the record)
VM_GATE_CASES="g_browser|browser g_build|build-only g_make|api-only g_api|api-only g_infra|api-only g_infra_feature|api-only g_user_only|browser g_nav_set|build-only g_ui_word_nav|browser"

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
# Both the bold form "**Test User:** N/A" and "**Test User**: N/A" match
# (the old regex missed the first one; fixed in decision 3).
_case_live_na_plain() { printf '**Test User**: N/A\nEnvironment: full stack running locally\n' >"$TD/context.md"; }
_case_browser_beats_build() { printf 'Update pom.xml, then login and check the dashboard.\n' >"$TD/notes.md"; }
_case_live_beats_build() { printf 'pom.xml gains resilience4j; circuit breaker opens on downstream failure.\n' >"$TD/notes.md"; }
_case_no_signals() { printf 'Refactor the repository class.\n' >"$TD/notes.md"; }
_case_no_files() { :; }

# Gate cases: text, has_nav_path, has_test_user. Old gate answers (for the
# record): g_make build-only, g_infra infra-only, g_infra_feature browser,
# g_nav_set browser — each now follows what verify itself would run.
_gcase() { # name -> sets GT (text), GN, GU
  GN=0 GU=0
  case "$1" in
  g_browser) GT='Open the page and click Save.' ;;
  g_build) GT='Run mvn clean compile; BUILD SUCCESS.' ;;
  g_make) GT='Run make seed-demo and confirm it succeeds.' ;;
  g_api) GT='POST /api/x returns 201.' ;;
  g_infra)
    GT='Check Eureka at localhost:8761 lists the service.'
    GU=1
    ;;
  g_infra_feature)
    GT='Check eureka, then /admin/ settings.'
    GU=1
    ;;
  g_user_only)
    GT='Log in at localhost:4200 and check things.'
    GU=1
    ;;
  g_nav_set)
    GT='mvn clean install'
    GN=1
    ;;
  g_ui_word_nav)
    GT='Refactor the repository class.'
    GN=1
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

echo "=== verify-mode.sh: gate-check Check 2.6 profile ==="
# shellcheck source=/dev/null
source "$VM"
for spec in $VM_GATE_CASES; do
  c="${spec%%|*}" want="${spec#*|}"
  _gcase "$c"
  got=$(verify_mode_gate_profile "$GT" "$GN" "$GU")
  [ "$got" = "$want" ] && _ok "gate $c ($got)" || _ko "gate $c: want $want got $got"
done
got=$(verify_mode_gate_profile "" 0 0)
[ "$got" = "api-only" ] && _ok "gate: no text, no signal -> api-only" || _ko "gate empty: $got"

echo "=== verify_mode_text ==="
_ws_new
printf 'PLAN\n' >"$WS/plan.md"
printf 'CTX\n' >"$TD/context.md"
printf 'DESC\n' >"$WS/d.txt"
got=$(verify_mode_text "$WS/plan.md" "$TD" "$WS/d.txt")
[ "$got" = "$(printf 'PLAN\nCTX\nDESC')" ] && _ok "plan, then context.md, then description" || _ko "verify_mode_text: $got"
got=$(verify_mode_text "$WS/missing.md" "$TD")
[ "$got" = "$(printf 'CTX\n')" ] && _ok "missing plan: context.md only" || _ko "verify_mode_text missing plan: [$got]"
_ws_rm

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

echo "=== gate-check.sh scores through verify-readiness.sh (no second classifier) ==="
gc="$VM_LIB_DIR/gate-check.sh"
if grep -q 'verify_readiness_score' "$gc" && ! grep -q '_build_signals=' "$gc" && ! grep -q 'grep -ciP' "$gc" && ! grep -q 'verify_mode_gate_class' "$gc"; then
  _ok "gate-check.sh classifies and scores through verify-readiness.sh only"
else
  _ko "gate-check.sh carries its own classification or probe regexes"
fi

echo ""
echo "verify-mode: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
