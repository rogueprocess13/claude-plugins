#!/usr/bin/env bash
# test-planner-crosscheck-params.sh — the Crosscheck parameter family
# (planner-specify-parameters, tasks 6.1–6.3): planner-crosscheck-params.sh.
#
# One case per spec scenario:
#   - legacy silence;
#   - a missing registry or an invalid table gives PARAM_TABLE_INVALID;
#   - an open row gives PARAM_UNDECIDED;
#   - a strong literal in an AC and in an Expected cell gives PARAM_LITERAL;
#   - canonical matches, glued and hyphenated forms;
#   - labels, counts, codes, dates and 100% are not flagged;
#   - numbered Verification Notes lines are not checked;
#   - a fixed row covers only the specs that cite its key;
#   - synth-marked specs and INDEX.md are skipped;
#   - mawk runs the family (and gawk agrees, when installed);
#   - the family runs inside planner_crosscheck_run and blocks it;
#   - per-literal accept: an accepted literal is written `accepted`, a new
#     one `fail`, and every finding carries its own accept command.
#
# Argument parsing of the per-literal accept is in test-planner-invocation.sh.
#
# Every case is guarded on the functions it needs, so on a checkout without
# the lib this file prints FAIL lines and a non-zero summary, never an
# unbound-function abort.
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-params.sh

# No errexit: planner_crosscheck_run counts finding return codes (1, 3) with
# `rc=$?`, which errexit would turn into an exit of its read loop.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "$REPOS_ROOT"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck.sh"
source "${LIB_DIR}/planner-specify-params.sh"
if [ -f "${LIB_DIR}/planner-crosscheck-params.sh" ]; then
  source "${LIB_DIR}/planner-crosscheck-params.sh"
fi

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
need() {
  local name="$1" fn
  shift
  for fn in "$@"; do
    if ! declare -f "$fn" >/dev/null; then
      fail "$name" "$fn missing"
      return 1
    fi
  done
  return 0
}
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi
}
contains() {
  case "$2" in
  *"$3"*) pass "$1" ;;
  *) fail "$1" "missing [$3] in [$2]" ;;
  esac
}

N=0
# fresh [legacy] — a new initiative, a contract one unless "legacy" is given.
fresh() {
  N=$((N + 1))
  INIT="INIT-1700000000-$((7000 + N))"
  planner_state_init "$INIT" "billing export" >/dev/null
  IDIR=$(planner_initiative_dir "$INIT")
  PROP="${IDIR}/artifacts/proposal.md"
  SPECS="${IDIR}/artifacts/specs"
  mkdir -p "$SPECS"
  [ "${1:-}" = legacy ] || planner_params_contract_mark "$INIT"
}

HDR='| Name | Key | Kind | Default | Value | Source |
|------|-----|------|---------|-------|--------|'

# registry <rows...> — proposal.md with a ## Parameters table of the rows.
registry() {
  {
    printf '# Proposal\n\n## Business Outcomes\n\nNone.\n\n## Parameters\n\n%s\n' "$HDR"
    local r
    for r in "$@"; do printf '%s\n' "$r"; done
    printf '\n## Scope\n\nBilling.\n'
  } >"$PROP"
}
no_params() { printf '# Proposal\n\n## Parameters\n\nNone.\n' >"$PROP"; }

# spec <slug> <ac-lines> [<vn-block>] [<extra>] — a spec with those ACs.
spec() {
  {
    printf '# %s\n\n## Technical Context\n\n%s\n\n## Acceptance Criteria\n\n%s\n' "$1" "${4:-none}" "$2"
    [ -z "${3:-}" ] || printf '\n## Verification Notes\n\n%s\n' "$3"
    printf '\n## Labels\n\nnone\n'
  } >"${SPECS}/$1.md"
}

# run — the family's stdout.
run() { planner_crosscheck_params "$INIT" 2>/dev/null || true; }
# codes — the codes the family printed, space-separated.
codes() { run | sed 's/^planner-crosscheck-params: //' | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//'; }
# lits — the literals of PARAM_LITERAL findings, `;`-separated.
lits() { run | grep ' PARAM_LITERAL ' | sed 's/^[^"]*"\([^"]*\)".*/\1/' | paste -sd';' -; }

ROW_IDLE='| Idle timeout | `auth.session_idle` | duration | 30 minutes | 30 minutes | default |'
ROW_DAY='| Link lifetime | `export.link_ttl` | duration | 24 hours | 24 hours | default |'

# ── Legacy and table ──────────────────────────────────────────────────────────

echo "=== legacy and table ==="

name="legacy initiative is silent"
if need "$name" planner_crosscheck_params; then
  fresh legacy
  spec export-link '- [ ] The link expires after 30 minutes'
  out=$(planner_crosscheck_params "$INIT" 2>&1)
  rc=$?
  check "$name" "${rc}:${out}" "0:"
fi

name="missing registry gives PARAM_TABLE_INVALID"
if need "$name" planner_crosscheck_params; then
  fresh
  printf '# Proposal\n\n## Scope\n\nx\n' >"$PROP"
  spec plain '- [ ] It works'
  out=$(run)
  check "$name" "$(codes)" "PARAM_TABLE_INVALID"
  contains "$name: says the section is missing" "$out" "no ## Parameters section"
  rc=0
  planner_crosscheck_params "$INIT" >/dev/null 2>&1 || rc=$?
  check "$name: rc 1" "$rc" "1"
fi

name="invalid row gives PARAM_TABLE_INVALID with its line"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_IDLE" '| Odd | `x.odd` | other | — | 5 | default |'
  spec plain '- [ ] It works'
  check "$name" "$(codes)" "PARAM_TABLE_INVALID"
  contains "$name: line and reason" "$(run)" "proposal.md:12 "
fi

name="None. is a valid empty registry"
if need "$name" planner_crosscheck_params; then
  fresh
  no_params
  spec plain '- [ ] It works'
  check "$name" "$(codes)" ""
fi

name="open row gives PARAM_UNDECIDED"
if need "$name" planner_crosscheck_params; then
  fresh
  registry '| Invoice rounding | `billing.total_rounding` | rounding | — | NEEDS_HUMAN_DECISION — per line or total? | — |'
  spec plain '- [ ] It works'
  check "$name" "$(codes)" "PARAM_UNDECIDED"
  contains "$name: names the key" "$(run)" '`billing.total_rounding`'
fi

# ── Literals ──────────────────────────────────────────────────────────────────

echo "=== literals ==="

name="invented timeout in an AC blocks, with spec, line and literal"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_IDLE"
  spec export-link '- [ ] The export link expires after 15 minutes'
  out=$(run)
  check "$name" "$(codes)" "PARAM_LITERAL"
  contains "$name: locus" "$out" 'PARAM_LITERAL specs/export-link.md:9 "15 minutes"'
fi

name="literal in an Expected cell blocks; other columns do not"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_IDLE"
  spec export-link '- [ ] It works' '| # | Role | Steps | Test data | Expected |
|---|------|-------|-----------|----------|
| 1 | user | wait 45 minutes | 2 GB file | link gone after 20 minutes |'
  check "$name" "$(lits)" "20 minutes"
  contains "$name: says Expected" "$(run)" "Expected"
fi

name="declared literal is covered"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_IDLE"
  spec idle '- [ ] The session ends after 30 minutes idle' '| # | Role | Expected |
|---|---|---|
| 1 | user | signed out after 30 min |'
  check "$name" "$(codes)" ""
fi

name="canonical forms match"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_DAY"
  spec export-link $'- [ ] Valid within 1 day\n- [ ] Valid for 86400 seconds\n- [ ] Opens a 24h window'
  check "$name" "$(codes)" ""
fi

name="glued and hyphenated forms are caught"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_IDLE"
  spec retention $'- [ ] Keeps a 30-day window\n- [ ] It retries after 10s\n- [ ] Logs are kept for 30d'
  check "$name" "$(lits)" "30-day;10s;30d"
fi

name="labels, counts, codes, dates and 100% do not count"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_IDLE"
  spec quiet $'- [ ] 10h. Shows 3 connections\n- [ ] Returns 404 for an unknown id\n- [ ] Progress reaches 100%\n- [ ] The file is named invoices-2026-09-30.csv'
  check "$name" "$(codes)" ""
fi

name="numbered Verification Notes lines are not checked"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_IDLE"
  spec legacy-notes '- [ ] It works' '1. User: open the link. Expected: gone after 15 minutes.'
  check "$name" "$(codes)" ""
fi

name="literals outside ACs and Expected are not checked"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_IDLE"
  spec ctx '- [ ] It works' '' 'The provider closes after 10 seconds.'
  check "$name" "$(codes)" ""
fi

name="fixed row covers only the specs that cite it"
if need "$name" planner_crosscheck_params; then
  fresh
  printf 'Provider notes: the provider closes the connection after 10 seconds of silence.\n' >"${IDIR}/artifacts/discovery.md"
  registry '| Provider timeout | `payments.provider_timeout` | fixed | — | 10 seconds | discovery:"the provider closes the connection after 10 seconds" |'
  spec spec-a '- [ ] Gives up after 10 sec' '' 'Uses `payments.provider_timeout`.'
  spec spec-b '- [ ] Gives up after 10 sec'
  out=$(run)
  check "$name" "$(codes)" "PARAM_LITERAL"
  contains "$name: spec B reported" "$out" "specs/spec-b.md:"
fi

name="open and invalid rows never cover"
if need "$name" planner_crosscheck_params; then
  fresh
  registry '| Fee | `billing.fee` | policy | 2% | 2% | default |'
  spec fee '- [ ] Charges a 2% fee'
  check "$name" "$(codes)" "PARAM_UNDECIDED PARAM_LITERAL"
fi

name="synth-marked specs and INDEX.md are skipped"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_IDLE"
  printf '%s\n# td\n\n## Acceptance Criteria\n\n- [ ] Seeded within 15 minutes\n' "$PLANNER_TESTDATA_SYNTH_MARKER" >"${SPECS}/td-test-data.md"
  printf '# Index\n\n## Acceptance Criteria\n\n- [ ] 15 minutes\n' >"${SPECS}/INDEX.md"
  check "$name" "$(codes)" ""
fi

name="fenced and code-span literals are not checked"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_IDLE"
  spec fenced $'- [ ] Config `ttl: 15 minutes` is read\n\n```\nsleep 15 minutes\n```'
  check "$name" "$(codes)" ""
fi

name="every finding message carries its accept command"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_IDLE"
  spec export-link $'- [ ] Expires after 15 minutes\n- [ ] Retries 3 times, 2 attempts apart'
  out=$(run | grep ' PARAM_LITERAL ')
  n=$(grep -c . <<<"$out")
  m=$(grep -c "resume ${INIT} --accept PARAM_LITERAL@export-link:\"[^\"]*\"\$" <<<"$out")
  check "$name" "$m" "$n"
  contains "$name: the describer's grep finds it" "$(grep -o 'PARAM_LITERAL@[A-Za-z0-9_-]*:"[^"]*"' <<<"$out" | head -1)" 'PARAM_LITERAL@export-link:"15 minutes"'
fi

# ── mawk ──────────────────────────────────────────────────────────────────────

echo "=== interpreters ==="

name="mawk runs the family"
if need "$name" planner_crosscheck_params; then
  if command -v mawk >/dev/null 2>&1; then
    fresh
    registry "$ROW_IDLE"
    spec export-link $'- [ ] Expires after 15 minutes\n- [ ] Idle for 30 minutes' '| # | Expected |
|---|---|
| 1 | gone after 2 hours |'
    m=$(PLANNER_PARAMS_AWK=mawk planner_crosscheck_params "$INIT" 2>&1 || true)
    check "$name" "$(grep -o '"[^"]*" ([a-z]*:[0-9]*)' <<<"$m" | paste -sd';' -)" '"15 minutes" (time:900000);"2 hours" (time:7200000)'
    if command -v gawk >/dev/null 2>&1; then
      g=$(PLANNER_PARAMS_AWK=gawk planner_crosscheck_params "$INIT" 2>&1 || true)
      check "gawk agrees with mawk" "$g" "$m"
    else
      echo "  SKIP gawk agrees with mawk (gawk not installed)"
    fi
  else
    echo "  SKIP mawk runs the family (mawk not installed)"
  fi
fi

# ── Crosscheck run and per-literal accept ─────────────────────────────────────

echo "=== crosscheck run ==="

name="missing registry blocks planner_crosscheck_run"
if need "$name" planner_crosscheck_params; then
  fresh
  printf '# Proposal\n\n## Scope\n\nx\n' >"$PROP"
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  log=$(planner_state_log "$INIT")
  check "$name: rc" "$rc" "1"
  contains "$name: fail line" "$(grep '|META|crosscheck|fail|' "$log")" "|META|crosscheck|fail|PARAM_TABLE_INVALID "
fi

name="legacy initiative adds nothing to planner_crosscheck_run"
if need "$name" planner_crosscheck_params; then
  fresh legacy
  printf '# Proposal\n\n## Scope\n\nx\n' >"$PROP"
  spec export-link '- [ ] Expires after 15 minutes'
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  check "$name" "$(grep -c 'PARAM_' "$(planner_state_log "$INIT")" || true)" "0"
fi

name="accepted literal is accepted, a new literal still fails"
if need "$name" planner_crosscheck_params planner_crosscheck_params_accept_parse; then
  fresh
  registry "$ROW_IDLE"
  spec export-link $'- [ ] Expires after 15 minutes\n- [ ] Warns after 20 minutes'
  spec other '- [ ] Expires after 15 minutes'
  parsed=$(planner_crosscheck_params_accept_parse 'PARAM_LITERAL@export-link:"15 minutes"')
  planner_crosscheck_accept_set "$INIT" "$(cut -f1 <<<"$parsed")" "$(cut -f2 <<<"$parsed")"
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  log=$(planner_state_log "$INIT")
  start=$(grep -n '|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  run_lines=$(tail -n "+$((start + 1))" "$log")
  check "$name: still blocks" "$rc" "1"
  contains "$name: 15 minutes accepted" "$run_lines" '|META|crosscheck|accepted|PARAM_LITERAL@export-link=time:900000 specs/export-link.md:9 "15 minutes"'
  contains "$name: 20 minutes fails" "$run_lines" '|META|crosscheck|fail|PARAM_LITERAL specs/export-link.md:10 "20 minutes"'
  contains "$name: same literal in another spec fails" "$run_lines" '|META|crosscheck|fail|PARAM_LITERAL specs/other.md:9 "15 minutes"'
  check "$name: the accepted line never reads as a code-wide accept" \
    "$(grep '|META|crosscheck|accepted|' "$log" | cut -d'|' -f5- | awk '$1 == "PARAM_LITERAL"' | wc -l | tr -d ' ')" "0"
  if [ -f "${LIB_DIR}/planner-stop-describe.sh" ]; then
    source "${LIB_DIR}/planner-stop-describe.sh"
    check "$name: the describer still counts the two unaccepted literals" \
      "$(_planner_stop_crosscheck_codes "$INIT" | awk -F'\t' '$1 == "PARAM_LITERAL" {print $2}')" "2"
  fi
fi

name="a hand-written code-wide accept does not silence PARAM_LITERAL"
if need "$name" planner_crosscheck_params; then
  fresh
  registry "$ROW_IDLE"
  spec export-link '- [ ] Expires after 15 minutes'
  planner_crosscheck_accept_set "$INIT" PARAM_LITERAL "all fine"
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  contains "$name" "$(grep '|META|crosscheck|fail|' "$(planner_state_log "$INIT")")" "fail|PARAM_LITERAL specs/export-link.md:9"
fi

echo "=== accept parse ==="

name="per-literal accept parses to instance and literal"
if need "$name" planner_crosscheck_params_accept_parse; then
  check "$name" "$(planner_crosscheck_params_accept_parse 'PARAM_LITERAL@export-link:"15  minutes"')" \
    "PARAM_LITERAL@export-link=time:900000	15 minutes"
  check "$name: unquoted" "$(planner_crosscheck_params_accept_parse 'PARAM_LITERAL@a_b-1:24h')" \
    "PARAM_LITERAL@a_b-1=time:86400000	24h"
fi

name="per-literal accept refuses text that is not one literal"
if need "$name" planner_crosscheck_params_accept_parse; then
  for bad in 'PARAM_LITERAL@x:"about half an hour"' 'PARAM_LITERAL@x:"5 minutes or 10 minutes"' \
    'PARAM_LITERAL@:"5 minutes"' 'PARAM_LITERAL@a.b:"5 minutes"' 'PARAM_LITERAL@x:""'; do
    rc=0
    planner_crosscheck_params_accept_parse "$bad" >/dev/null 2>&1 || rc=$?
    check "$name: $bad" "$rc" "1"
  done
fi

echo "=== fix hints ==="
for code in PARAM_TABLE_INVALID PARAM_UNDECIDED PARAM_LITERAL; do
  h=$(planner_crosscheck_fix_hint "$code")
  case "$h" in
  "no canned hint"*) fail "fix hint for $code" "$h" ;;
  *) pass "fix hint for $code" ;;
  esac
done

echo ""
echo "=== planner crosscheck params: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
