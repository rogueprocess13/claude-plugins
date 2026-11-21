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
# GitHub #761: fixtures/verify-mode/shape/<shape>_<case>.md are reduced,
# anonymised copies of the text verify classified for tickets that have no
# page (an in-memory store, two HTTP APIs, one added markdown file) and for
# two real browser tickets. Every one classified browser before the fix.
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

echo "=== GitHub #761: ticket shape (verify_mode_shape) ==="
# file|shape|ticket-verify path|gate profile
for spec in \
  "api_in_memory_store|api-only|live-backend|api-only" \
  "api_articles|api-only|live-backend|api-only" \
  "api_normalise_accounts|api-only|live-backend|api-only" \
  "diff_add_docs_file|diff-only|build-only|diff-only" \
  "browser_sign_in_pages|browser|browser|browser" \
  "browser_mixed_api_rows|browser|browser|browser"; do
  IFS='|' read -r c want_shape want_mode want_gate <<<"$spec"
  text=$(cat "$VM_FX/shape/$c.md")
  got="$(verify_mode_shape "$text")|$(verify_mode_classify "$text")|$(verify_mode_gate_profile "$text" 0 0)"
  [ "$got" = "$want_shape|$want_mode|$want_gate" ] && _ok "shape $c ($got)" || _ko "shape $c: want $want_shape|$want_mode|$want_gate got $got"
done

# text|expected shape. A negated browser word, a path, a slug or "open the
# PR" is not a browser signal: with nothing else the text has no signal at
# all, so the default (browser) applies with a browser count of 0.
_shape_is() { # label, text, want shape
  local got
  got=$(verify_mode_shape "$2")
  [ "$got" = "$3" ] && _ok "$1 -> $3" || _ko "$1: want $3 got $got"
}
_browser_count_is() { # label, text, want count
  local got
  read -r got _ <<<"$(_verify_mode_signals "$2")"
  [ "$got" = "$3" ] && _ok "$1: browser signals = $3" || _ko "$1: browser signals want $3 got $got"
}
_browser_count_is '"No screen"' 'Navigation Path: No screen' 0
_browser_count_is '"no login"' 'The developer needs no login.' 0
_browser_count_is '"no ... login"' 'This check needs no browser or login.' 0
_browser_count_is '"without a browser"' 'Runs without a browser.' 0
_browser_count_is '"open the PR"' 'Commit, push and open the PR against develop.' 0
_browser_count_is '"opens a port"' 'server.js is the only file that opens a port.' 0
_browser_count_is 'login in a path' 'Send the body to `POST /api/users/login`, see src/pages/login.js.' 0
_browser_count_is 'login in a branch slug' 'Base branch epic/init-1-sign-up-login-and-articles.' 0
_browser_count_is 'the readiness section Mode line' '**Mode:** browser (verify: browser)' 0
_browser_count_is 'a real login' 'Open the login page and click Save.' 1
_browser_count_is '"no error on the screen" keeps its screen' 'Click Save. There is no error on the screen.' 1
_shape_is '"No screen" alone' 'Navigation Path: No screen' api-only
_shape_is '"No screen, API only" with login prose' 'No screen, API only. Login returns 401 for a wrong password.' api-only
_shape_is 'heading form: ## Navigation Path / No screen.' "$(printf '## Navigation Path\n\nNo screen. Send the request by hand.\n')" api-only
_shape_is 'heading form: ## Test User / None' "$(printf '## Test User\n\nNone. A developer runs the unit tests.\n')" api-only
_shape_is 'Test User: None + npm test' 'Test User: None. Run npm test in backend/.' api-only
_shape_is 'curl' 'Run curl -s localhost:3000/health and expect 200.' api-only
_shape_is 'HTTP verb and path' 'GET /api/articles returns 200.' api-only
_shape_is 'supertest' 'Each check is a supertest request.' api-only
_shape_is 'git-only' 'Git-only: the new file is the whole change.' diff-only
_shape_is 'docs-only with a browser word' 'Docs-only. Describe the login screen in the guide.' diff-only
_shape_is 'no UI + no code' 'One new markdown file. No code, no tests, no UI.' diff-only
_shape_is 'no UI + mvn stays build-only' 'No UI or API surface. Run mvn -N install; BUILD SUCCESS.' build-only
_shape_is 'eureka stays live-backend' 'No UI. Service must register with Eureka on startup.' live-backend
_shape_is '"no UI changes" is not a declaration' 'No UI changes expected; click the Save button to confirm.' browser
_shape_is '"the API only through" is not a declaration' 'The browser reaches the API only through the proxy; click Save.' browser
_shape_is 'no screen on one row, a click on another' "$(printf 'Row 1: No screen, API only.\nRow 2: click the Edit button.\n')" browser
_shape_is 'no signal at all stays browser' 'Refactor the repository class.' browser
_shape_is 'browser + curl stays browser' 'Click Save, then curl the health endpoint.' browser

echo "=== GitHub #761: an explicit Verify mode field overrides the heuristics ==="
_shape_is 'bold field beats browser words' "$(printf '**Verify mode:** api-only\nClick the login button.\n')" api-only
_shape_is 'plain field' "$(printf 'Verify mode: diff-only\nClick the login button.\n')" diff-only
_shape_is 'colon outside the bold' "$(printf '**Verify Mode**: build-only\nNo screen, API only.\n')" build-only
_shape_is 'field browser beats "API only"' "$(printf '**Verify mode:** browser\nNo screen. API only.\n')" browser
_shape_is 'heading form' "$(printf '## Verify Mode\n\nlive-backend\n\nClick Save.\n')" live-backend
_shape_is 'unknown value falls back to the heuristics' "$(printf '**Verify mode:** headless\nClick Save.\n')" browser
got=$(verify_mode_classify "$(printf '**Verify mode:** api-only\nClick the login button.\n')")
[ "$got" = "live-backend" ] && _ok "field api-only runs the live-backend path" || _ko "field api-only path: $got"
got=$(verify_mode_classify "$(printf '**Verify mode:** diff-only\nClick the login button.\n')")
[ "$got" = "build-only" ] && _ok "field diff-only runs the build-only path" || _ko "field diff-only path: $got"
got=$(verify_mode_gate_profile "$(printf '**Verify mode:** browser\nRefactor the class.\n')" 0 0)
[ "$got" = "browser" ] && _ok "gate: field browser -> browser profile" || _ko "gate field browser: $got"
got=$(verify_mode_gate_profile 'This check needs no login.' 0 1)
[ "$got" = "browser" ] && _ok "gate: no signal, plan names a test user -> browser (unchanged)" || _ko "gate no signal + user: $got"

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
cp "$VM_FX/shape/diff_add_docs_file.md" "$TD/simple-fix.md"
rm -f "$TD/context.md"
out=$(bash "$VM" "$TID" --ticket-dir "$TD" --root "$TICKETS_ROOT")
[ "$out" = "$(printf 'VERIFY_MODE=build-only\nVERIFY_SHAPE=diff-only')" ] && _ok "diff-only prints the mode, then the shape" || _ko "diff-only stdout: $out"
line=$(tail -1 "$TAP_LOG")
[[ "$line" == *"|VERIFY|load-context|done|Context loaded, shape=diff-only, mode=build-only" ]] && _ok "the log line carries the shape before mode=" || _ko "diff-only log line: $line"
# ticket-verify Step 1f reads the mode back from this line on a resume.
got=$(grep '|VERIFY|load-context|done|' "$TAP_LOG" 2>/dev/null | tail -1 | sed -n 's/.*mode=//p')
[ "$got" = "build-only" ] && _ok "a --from-step resume still reads mode=build-only" || _ko "resume mode: $got"
rc=0
bash "$VM" "$TID" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && _ok "missing --ticket-dir -> exit 2" || _ko "missing --ticket-dir rc=$rc"
rc=0
bash "$VM" "$TID" --ticket-dir >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && _ok "--ticket-dir without value -> exit 2" || _ko "--ticket-dir no value rc=$rc"
_ws_rm

echo "=== all-[unit] criteria route to build-only (GitHub #773, VERIFY_AC_TAGS) ==="
# _unit_body <verify-mode-line-or-empty> <criterion>... — context.md with the
# given criteria under ## Acceptance Criteria.
_unit_body() {
  local vm="$1" c
  shift
  {
    printf '# Fix thing\n\nClick the Save button on the invoice page.\n\n'
    [ -n "$vm" ] && printf '## Verify Mode\n\n**Verify mode:** %s — reason\n\n' "$vm"
    printf '## Acceptance Criteria\n\n'
    for c in "$@"; do printf -- '- [ ] %s\n' "$c"; done
  } >"$TD/context.md"
}
_ws_new
_unit_body "" "[unit] totals reject an empty invoice" "[unit] totals round half up"
out=$(VERIFY_AC_TAGS=true bash "$VM" "$TID" --ticket-dir "$TD" --root "$TICKETS_ROOT" --env local)
[ "$out" = "$(printf 'VERIFY_MODE=build-only\nVERIFY_MODE_OVERRIDE=all-unit')" ] &&
  _ok "classified browser, all [unit], flag on, local -> build-only" || _ko "override stdout: $out"
line=$(grep '|META|verify-mode-override|' "$TAP_LOG" | tail -1)
[[ "$line" == *"|META|verify-mode-override|info|classified shape=browser (mode=browser) overridden to mode=build-only: all 2 criteria are [unit], VERIFY_AC_TAGS=true, env=local" ]] &&
  _ok "one META line names the classified shape and the override" || _ko "override META line: $line"
[ "$(grep -c '|META|verify-mode-override|' "$TAP_LOG")" = 1 ] && _ok "exactly one override line" || _ko "override line count"
got=$(grep '|VERIFY|load-context|done|' "$TAP_LOG" 2>/dev/null | tail -1 | sed -n 's/.*mode=//p')
[ "$got" = "build-only" ] && _ok "a --from-step resume reads mode=build-only" || _ko "override resume mode: $got"
[ "$(tail -1 "$TAP_LOG" | cut -d'|' -f2-3)" = "VERIFY|load-context" ] && _ok "load-context stays the last line" || _ko "last line: $(tail -1 "$TAP_LOG")"

: >"$TAP_LOG"
_unit_body "live-backend" "[unit] the retry policy is three attempts"
out=$(VERIFY_AC_TAGS=true bash "$VM" "$TID" --ticket-dir "$TD" --root "$TICKETS_ROOT" --env local)
line=$(grep '|META|verify-mode-override|' "$TAP_LOG" | tail -1)
[ "$out" = "$(printf 'VERIFY_MODE=build-only\nVERIFY_MODE_OVERRIDE=all-unit')" ] &&
  [[ "$line" == *"|declared shape=live-backend (mode=live-backend) overridden to mode=build-only: all 1 criteria"* ]] &&
  _ok "declared live-backend, all [unit] -> build-only, logged as declared" || _ko "declared override: $out / $line"

_unit_body "api-only" "[unit] the handler returns 422 on a bad body"
out=$(VERIFY_AC_TAGS=true bash "$VM" "$TID" --ticket-dir "$TD" --root "$TICKETS_ROOT" --env local --no-log)
[ "$out" = "$(printf 'VERIFY_MODE=build-only\nVERIFY_MODE_OVERRIDE=all-unit')" ] &&
  _ok "declared api-only (live-backend path) is overridden too, no VERIFY_SHAPE" || _ko "api-only override: $out"

# Unchanged cases: byte-for-byte the output without the flag.
_unit_body "" "[unit] totals reject an empty invoice" "[unit] totals round half up"
want=$(bash "$VM" "$TID" --ticket-dir "$TD" --no-log)
[ "$want" = "VERIFY_MODE=browser" ] && _ok "flag unset: browser as before" || _ko "flag unset: $want"
out=$(VERIFY_AC_TAGS=false bash "$VM" "$TID" --ticket-dir "$TD" --env local --no-log)
[ "$out" = "$want" ] && _ok "flag false -> unchanged" || _ko "flag false: $out"
out=$(VERIFY_AC_TAGS=true bash "$VM" "$TID" --ticket-dir "$TD" --env uat --no-log)
[ "$out" = "$want" ] && _ok "--env uat -> unchanged" || _ko "env uat: $out"
out=$(VERIFY_AC_TAGS=true bash "$VM" "$TID" --ticket-dir "$TD" --no-log)
[ "$out" = "$want" ] && _ok "no --env -> unchanged (local must be stated)" || _ko "no env: $out"
_unit_body "" "[unit] totals reject an empty invoice" "[live] the invoice page shows the total"
out=$(VERIFY_AC_TAGS=true bash "$VM" "$TID" --ticket-dir "$TD" --env local --no-log)
[ "$out" = "$want" ] && _ok "one [live] criterion -> unchanged" || _ko "mixed live: $out"
_unit_body "" "[unit] totals reject an empty invoice" "the invoice page shows the total"
out=$(VERIFY_AC_TAGS=true bash "$VM" "$TID" --ticket-dir "$TD" --env local --no-log)
[ "$out" = "$want" ] && _ok "one untagged criterion -> unchanged" || _ko "mixed untagged: $out"
_unit_body ""
out=$(VERIFY_AC_TAGS=true bash "$VM" "$TID" --ticket-dir "$TD" --env local --no-log)
[ "$out" = "$want" ] && _ok "no criteria -> unchanged" || _ko "no criteria: $out"
_unit_body "diff-only" "[unit] the README names the flag"
out=$(VERIFY_AC_TAGS=true bash "$VM" "$TID" --ticket-dir "$TD" --env local --no-log)
[ "$out" = "$(printf 'VERIFY_MODE=build-only\nVERIFY_SHAPE=diff-only')" ] && _ok "already build-only (diff-only) -> unchanged" || _ko "diff-only: $out"
: >"$TAP_LOG"
_unit_body "" "[unit] totals reject an empty invoice" "[live] the invoice page shows the total"
VERIFY_AC_TAGS=true bash "$VM" "$TID" --ticket-dir "$TD" --root "$TICKETS_ROOT" --env local >/dev/null
! grep -q 'verify-mode-override' "$TAP_LOG" && _ok "no override line when nothing is overridden" || _ko "stray override line"
rc=0
bash "$VM" "$TID" --ticket-dir "$TD" --env >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && _ok "--env without value -> exit 2" || _ko "--env no value rc=$rc"
# The override reads the body the [unit] proof reads (Step 1i), so it never
# fires when that gate would stay off.
_unit_body "" "[unit] totals reject an empty invoice"
got=$(VERIFY_AC_TAGS=true bash "$VM_LIB_DIR/verify-ac-tags.sh" gate "$TD" --env local | head -1)
[ "$got" = "AC_TAGS=on" ] && _ok "whenever it fires, verify-ac-tags.sh gate is on too" || _ko "ac-tags gate: $got"
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
