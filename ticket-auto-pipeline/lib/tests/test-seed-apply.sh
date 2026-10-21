#!/usr/bin/env bash
# test-seed-apply.sh — unit tests for lib/seed-apply.sh
# (planner-test-data-derivation, tasks 6.1/8.4). Covers done/skip/fail, the
# merged-only rule, body-field parsing, the strict `make <target>` command
# shape (injection attempts rejected, never executed), local-body-only reads
# (no tracker call) and the CLI entry.
# Usage: bash test-seed-apply.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
export REPOS_ROOT="$TMP_ROOT/repos"
mkdir -p "$REPOS_ROOT"

source "$LIB_DIR/seed-apply.sh"

# ── Stubs (defined after sourcing, so the library's own sourcing of
# manifest-read.sh / planner-artifacts.sh cannot replace them) ────────────
# STUB_BLOCKED[<tid>]  — the manifest's blocked_by JSON (absent = no manifest)
# STUB_MERGE[<tid>]    — ticket_pipeline_merge_state's word
# Bodies live at $TMP_ROOT/planner/<tid>/body.md.
declare -A STUB_BLOCKED=()
declare -A STUB_MERGE=()
get_ticket_manifest_field() {
  [ "$2" = "blocked_by" ] || return 0
  [ -n "${STUB_BLOCKED[$1]+x}" ] || return 1
  echo "${STUB_BLOCKED[$1]}"
}
ticket_pipeline_merge_state() {
  local s="${STUB_MERGE[$1]:-not-complete}"
  echo "$s"
  case "$s" in merged | no-pr) return 0 ;; *) return 1 ;; esac
}
resolve_planner_dir() {
  local d="$TMP_ROOT/planner/$1"
  echo "$d"
  [ -d "$d" ]
}
# A tracker read must never happen: any get_issue call touches a sentinel.
GET_ISSUE_SENTINEL="$TMP_ROOT/get-issue-called"
get_issue() {
  touch "$GET_ISSUE_SENTINEL"
  echo '{"description":"Seed command: make seed-from-tracker"}'
}

PASS=0
FAIL=0
_pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_fail() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}

WT="$TMP_ROOT/worktree"
mkdir -p "$WT"
export LOG_FILE="$TMP_ROOT/logs/CON-1-pipeline.log"
mkdir -p "$(dirname "$LOG_FILE")"

_body() {
  mkdir -p "$TMP_ROOT/planner/$1"
  printf '%s\n' "$2" >"$TMP_ROOT/planner/$1/body.md"
}
_reset() {
  STUB_BLOCKED=()
  STUB_MERGE=()
  rm -rf "$TMP_ROOT/planner" "$WT" "$TMP_ROOT/pwned"
  mkdir -p "$WT/sub"
  # Recipes write marker files so a test can see which targets ran.
  printf '%s\n' \
    'seed-x: ; @echo seeded > seed.out' \
    'verify-seed-x: ; @grep -q seeded seed.out && touch verified.out' \
    'seed-fail: ; @exit 2' \
    'verify-fail: ; @false' \
    'verify-ran: ; @touch verify-ran' \
    'seed: ; @touch seed-target-ran' \
    'seed-tracker: ; @touch should-not-run' >"$WT/Makefile"
  printf '%s\n' 'seed-sub: ; @touch sub-ran' >"$WT/sub/Makefile"
  : >"$LOG_FILE"
}
_lastlog() { tail -1 "$LOG_FILE"; }

# ── seed_apply_field parsing ─────────────────────────────────────────────
f_body='## Test Data Provided
- `td-1-1` — five invoices

```
Seed command: not-this-one
```

- **Seed command:** `make seed-inv`
Verify command: make verify-seed-inv
Seed command: make second'
[ "$(seed_apply_field "$f_body" "Seed command")" = "make seed-inv" ] &&
  _pass "field: first non-fenced Seed command, bold label and backticks tolerated" ||
  _fail "field: got '$(seed_apply_field "$f_body" "Seed command")'"
[ "$(seed_apply_field "$f_body" "Verify command")" = "make verify-seed-inv" ] &&
  _pass "field: plain Verify command line" ||
  _fail "field verify: got '$(seed_apply_field "$f_body" "Verify command")'"
[ -z "$(seed_apply_field "no commands here" "Seed command")" ] &&
  _pass "field: absent label yields empty" ||
  _fail "field: absent label should be empty"

# ── done: merged blocker, seed + verify run in the worktree ──────────────
_reset
STUB_BLOCKED["CON-1"]='["TD-1","FEAT-2"]'
STUB_MERGE["TD-1"]=merged
STUB_MERGE["FEAT-2"]=merged
_body TD-1 'Seed command: `make seed-x`
Verify command: `make verify-seed-x`'
_body FEAT-2 '## Summary
A feature blocker with no seed.'
rc=0
seed_apply CON-1 "$WT" || rc=$?
[ "$rc" = "0" ] && [ "$SEED_APPLY_STATUS" = "done" ] && [ "$SEED_APPLY_COUNT" = "1" ] &&
  [ -f "$WT/seed.out" ] && [ -f "$WT/verified.out" ] &&
  _pass "done: merged TD blocker's seed then verify ran in the worktree" ||
  _fail "done: rc=$rc status=$SEED_APPLY_STATUS count=$SEED_APPLY_COUNT files=$(ls "$WT")"
grep -q '|VERIFY|seed-apply|start|2 blockers$' "$LOG_FILE" &&
  _lastlog | grep -q '|VERIFY|seed-apply|done|1 seeds applied: TD-1$' &&
  _pass "done: start and done lines written in pipeline-log format" ||
  _fail "done: log was: $(cat "$LOG_FILE")"
[ "$(pwd)" != "$WT" ] && _pass "done: caller's working directory unchanged" ||
  _fail "done: cwd moved into the worktree"

# ── skip: no blockers / no manifest / no Seed command ────────────────────
_reset
rc=0
seed_apply ADHOC-1 "$WT" || rc=$?
[ "$rc" = "0" ] && [ "$SEED_APPLY_STATUS" = "skip" ] &&
  _lastlog | grep -q '|VERIFY|seed-apply|skip|no test-data blockers with a Seed command$' &&
  _pass "skip: a ticket with no manifest has no blockers" ||
  _fail "skip (no manifest): rc=$rc status=$SEED_APPLY_STATUS log=$(_lastlog)"

_reset
STUB_BLOCKED["CON-1"]='["FEAT-2"]'
STUB_MERGE["FEAT-2"]=merged
_body FEAT-2 'no seed here'
rc=0
seed_apply CON-1 "$WT" || rc=$?
[ "$rc" = "0" ] && [ "$SEED_APPLY_STATUS" = "skip" ] && [ "$SEED_APPLY_COUNT" = "0" ] &&
  _pass "skip: blockers without a Seed command" ||
  _fail "skip (no seed): rc=$rc status=$SEED_APPLY_STATUS"

# ── merged-only: open and no-pr blockers are not applied, and are named ──
_reset
STUB_BLOCKED["CON-1"]='["TD-1","TD-3"]'
STUB_MERGE["TD-1"]=open
STUB_MERGE["TD-3"]=no-pr
_body TD-1 'Seed command: make seed-tracker'
_body TD-3 'Seed command: make seed-tracker'
rc=0
seed_apply CON-1 "$WT" || rc=$?
[ "$rc" = "0" ] && [ "$SEED_APPLY_STATUS" = "skip" ] &&
  [ ! -e "$WT/should-not-run" ] &&
  _lastlog | grep -q 'not merged: TD-1=open TD-3=no-pr' &&
  _pass "merged-only: open and no-pr TD blockers skipped and named in the log" ||
  _fail "merged-only: rc=$rc status=$SEED_APPLY_STATUS log=$(_lastlog)"

# ── fail: seed command exits non-zero, verify never runs ─────────────────
_reset
STUB_BLOCKED["CON-1"]='["TD-1"]'
STUB_MERGE["TD-1"]=merged
_body TD-1 'Seed command: make seed-fail
Verify command: make verify-ran'
rc=0
seed_apply CON-1 "$WT" 2>/dev/null || rc=$?
[ "$rc" = "1" ] && [ "$SEED_APPLY_STATUS" = "fail" ] && [ ! -e "$WT/verify-ran" ] &&
  _lastlog | grep -q '|VERIFY|seed-apply|fail|TD-1 seed command exited 2: make seed-fail$' &&
  _pass "fail: seed exit 2 → rc 1, fail line names blocker and command, verify skipped" ||
  _fail "fail (seed): rc=$rc status=$SEED_APPLY_STATUS log=$(_lastlog)"

# ── fail: verify command exits non-zero ──────────────────────────────────
_reset
STUB_BLOCKED["CON-1"]='["TD-1"]'
STUB_MERGE["TD-1"]=merged
_body TD-1 'Seed command: make seed-x
Verify command: `make verify-fail`'
rc=0
seed_apply CON-1 "$WT" 2>/dev/null || rc=$?
[ "$rc" = "1" ] && _lastlog | grep -q '|fail|TD-1 verify command exited 2: make verify-fail$' &&
  _pass "fail: verify command failure → rc 1" ||
  _fail "fail (verify): rc=$rc log=$(_lastlog)"

# ── command shape: only `make [-C relpath] <target>` ever runs ───────────
# Each injection attempt names a sentinel; none may be created, nothing
# else may run, and the fail line names the rejection.
_reject_case() { # <label> <Seed|Verify> <body>
  _reset
  STUB_BLOCKED["CON-1"]='["TD-1"]'
  STUB_MERGE["TD-1"]=merged
  _body TD-1 "$3"
  local rc=0
  seed_apply CON-1 "$WT" 2>/dev/null || rc=$?
  if [ "$rc" = "1" ] && [ "$SEED_APPLY_STATUS" = "fail" ] &&
    [ ! -e "$TMP_ROOT/pwned" ] && [ ! -e "$WT/pwned" ] && [ -d "$TMP_ROOT/x" ] &&
    [ ! -e "$WT/seed-target-ran" ] && [ ! -e "$WT/seed.out" ] &&
    _lastlog | grep -qF "|VERIFY|seed-apply|fail|TD-1 rejected $2 command: not 'make <target>'"; then
    _pass "reject: $1"
  else
    _fail "reject: $1 — rc=$rc status=$SEED_APPLY_STATUS log=$(_lastlog) wt=$(ls "$WT")"
  fi
}
mkdir -p "$TMP_ROOT/x"
_reject_case "'make seed; rm -rf x' (chained command)" Seed \
  "Seed command: make seed; touch $TMP_ROOT/pwned; rm -rf $TMP_ROOT/x"
_reject_case "'\$(touch pwned)' (command substitution)" Seed \
  "Seed command: \$(touch $TMP_ROOT/pwned)"
_reject_case "'make \$(touch pwned)' (substitution as the target)" Seed \
  "Seed command: make \$(touch $TMP_ROOT/pwned)"
_reject_case "'bash evil.sh' (not make)" Seed 'Seed command: bash evil.sh'
_reject_case "'make -C ../x seed' (parent dir)" Seed 'Seed command: make -C ../x seed'
_reject_case "'make -C /tmp seed' (absolute dir)" Seed 'Seed command: make -C /tmp seed'
_reject_case "'make -j8 seed' (extra flag)" Seed 'Seed command: make -j8 seed'
_reject_case "'make SHELL=/bin/sh seed' (variable override)" Seed 'Seed command: make SHELL=/bin/sh seed'
_reject_case "bad Verify command rejects before the seed runs" Verify \
  "Seed command: make seed
Verify command: make verify; touch $TMP_ROOT/pwned"

_reset
STUB_BLOCKED["CON-1"]='["TD-1"]'
STUB_MERGE["TD-1"]=merged
_body TD-1 'Seed command: `make -C sub seed-sub`'
rc=0
seed_apply CON-1 "$WT" 2>/dev/null || rc=$?
[ "$rc" = "0" ] && [ "$SEED_APPLY_COUNT" = "1" ] && [ -f "$WT/sub/sub-ran" ] &&
  _pass "accept: 'make -C sub seed-sub' runs in the worktree subdirectory" ||
  _fail "make -C: rc=$rc count=$SEED_APPLY_COUNT log=$(_lastlog)"

# ── body comes from the local body.md only; the tracker is never read ────
_reset
rm -f "$GET_ISSUE_SENTINEL"
STUB_BLOCKED["CON-1"]='["TD-9"]'
STUB_MERGE["TD-9"]=merged
rc=0
seed_apply CON-1 "$WT" 2>/dev/null || rc=$?
[ "$rc" = "0" ] && [ "$SEED_APPLY_STATUS" = "skip" ] && [ ! -e "$GET_ISSUE_SENTINEL" ] &&
  [ ! -e "$WT/should-not-run" ] &&
  _lastlog | grep -q '(no local body: TD-9)$' &&
  _pass "no tracker read: blocker with no local body.md is skipped and named, get_issue never called" ||
  _fail "no tracker read: rc=$rc status=$SEED_APPLY_STATUS sentinel=$([ -e "$GET_ISSUE_SENTINEL" ] && echo touched) log=$(_lastlog)"

# ── usage errors ─────────────────────────────────────────────────────────
rc=0
seed_apply CON-1 "$TMP_ROOT/missing" 2>/dev/null || rc=$?
[ "$rc" = "2" ] && _pass "usage: missing worktree → rc 2" || _fail "usage: rc=$rc"

_reset
get_ticket_manifest_field() { return 2; }
rc=0
seed_apply CON-1 "$WT" 2>/dev/null || rc=$?
[ "$rc" = "2" ] && _lastlog | grep -q '|fail|cannot read the manifest of CON-1' &&
  _pass "usage: malformed manifest is a failure, never 'no blockers'" ||
  _fail "malformed manifest: rc=$rc log=$(_lastlog)"

# ── CLI entry ────────────────────────────────────────────────────────────
cli_out=$(LOG_FILE="" bash "$LIB_DIR/seed-apply.sh" 2>&1) && cli_rc=0 || cli_rc=$?
[ "$cli_rc" = "2" ] && echo "$cli_out" | grep -q "Usage: seed-apply.sh" &&
  _pass "CLI: no args → usage, rc 2" || _fail "CLI usage: rc=$cli_rc out=$cli_out"
cli_out=$(LOG_FILE="" bash "$LIB_DIR/seed-apply.sh" CLI-1 "$WT" 2>/dev/null) && cli_rc=0 || cli_rc=$?
[ "$cli_rc" = "0" ] && echo "$cli_out" | grep -q "^SEED_APPLY_STATUS=skip$" &&
  _pass "CLI: ticket with no manifest → skip, rc 0" || _fail "CLI run: rc=$cli_rc out=$cli_out"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
