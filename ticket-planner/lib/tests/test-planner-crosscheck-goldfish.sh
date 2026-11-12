#!/usr/bin/env bash
# test-planner-crosscheck-goldfish.sh — the Crosscheck goldfish family
# (planner-goldfish-review, task 3.1): planner-crosscheck-goldfish.sh.
#
#   - no goldfish line: no output, also through planner_crosscheck_run;
#   - bm=G1,G2 with only G1 dispositioned: one warning naming G2;
#   - undispositioned minor or nit findings: nothing;
#   - a batched `Minor/nit …: deferred` line is accepted;
#   - a missing status line: `status line missing`;
#   - NOT_RUN or disabled with the status line: nothing;
#   - a heading outside the section, or a fenced one, does not count;
#   - an unknown disposition word does not count;
#   - `rejected (… covered in spec <slug>)` counts;
#   - messages free of `|`, CR, LF; never a `fail` line; mawk (and gawk) agree;
#   - registration: warn code, fix hint, wired after the AC precondition family.
#
# Every case is guarded on the function it needs.
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-goldfish.sh

# No errexit: planner_crosscheck_run counts finding return codes with `rc=$?`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "$REPOS_ROOT"
unset PLANNER_GOLDFISH_AWK

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck.sh"
[ -f "${LIB_DIR}/planner-crosscheck-goldfish.sh" ] && source "${LIB_DIR}/planner-crosscheck-goldfish.sh"

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
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi
}
G=planner_crosscheck_goldfish
have() { declare -f "$G" >/dev/null || {
  fail "$1" "$G missing"
  return 1
}; }

N=0
SHA=abcdef012345
STATUS_RAN="Goldfish review: ran — 3 finding(s), proposal ${SHA}, see goldfish/review-goldfish.md"
# init_with <goldfish-status> <goldfish-message> — a fresh initiative with one
# goldfish line ("" for none); consensus.md comes from stdin.
init_with() {
  N=$((N + 1))
  INIT="INIT-xcg-${N}"
  planner_state_init "$INIT" "an idea" >/dev/null 2>&1
  SD="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
  mkdir -p "${SD}/artifacts"
  [ -n "$1" ] && planner_state_write "$INIT" META goldfish "$1" "$2" >/dev/null 2>&1
  cat >"${SD}/artifacts/consensus.md"
}
W="planner-crosscheck-goldfish: GOLDFISH_UNADDRESSED consensus.md ## Goldfish Findings Addressed:"

echo "=== planner-crosscheck-goldfish (3.1) ==="

name="no goldfish line gives no output"
if have "$name"; then
  init_with "" "" <<<"# Consensus"
  check "$name" "$($G "$INIT")" ""
  planner_crosscheck_run "$INIT" >/dev/null 2>&1
  check "$name: no GOLDFISH line through planner_crosscheck_run" "$(grep -c GOLDFISH "${SD}/state.log")" "0"
fi

name="bm=G1,G2 with only G1 dispositioned names G2"
if have "$name"; then
  init_with done "${SHA} findings=4 bm=G1,G2" <<EOF
# Consensus

## Goldfish Findings Addressed
${STATUS_RAN}
### G1 — major — Retry limit — accepted
Minor/nit G3, G4: deferred

## Next
EOF
  out=$($G "$INIT")
  check "$name" "$out" "${W} no disposition for G2"
  case "$out" in *"|"* | *$'\r'*) fail "$name: no | or CR" "[$out]" ;; *) pass "$name: no | or CR" ;; esac
  check "$name: one line" "$(printf '%s\n' "$out" | wc -l)" "1"
fi

name="all blocker/major dispositioned, minors not: nothing"
if have "$name"; then
  init_with done "${SHA} findings=3 bm=G1,G2" <<EOF
## Goldfish Findings Addressed
${STATUS_RAN}
### G1 — major — Retry limit — accepted
### G2 — blocker — Rollback — rejected (not needed, covered in spec pause-api)
EOF
  check "$name" "$($G "$INIT")" ""
fi

name="clarified and deferred count"
if have "$name"; then
  init_with done "${SHA} findings=2 bm=G1,G5" <<EOF
## Goldfish Findings Addressed
${STATUS_RAN}
### G1 — major — Retry limit — **clarified** (added to proposal § Scope)
### G5 — major — Metrics — deferred
EOF
  check "$name" "$($G "$INIT")" ""
fi

name="a missing status line"
if have "$name"; then
  init_with done "${SHA} findings=1 bm=G1" <<EOF
## Goldfish Findings Addressed
### G1 — major — Retry limit — accepted
EOF
  check "$name" "$($G "$INIT")" "${W} status line missing"
fi

name="no section at all: both parts"
if have "$name"; then
  init_with done "${SHA} findings=1 bm=G1" <<<"# Consensus"
  check "$name" "$($G "$INIT")" "${W} no disposition for G1; status line missing"
fi

name="NOT_RUN with the status line: nothing"
if have "$name"; then
  init_with fail "${SHA} NOT_RUN no-result" <<EOF
## Goldfish Findings Addressed
Goldfish review: NOT RUN — no-result. Its findings are unknown, not zero.
EOF
  check "$name" "$($G "$INIT")" ""
fi

name="disabled with the status line: nothing"
if have "$name"; then
  init_with skip "${SHA} DISABLED" <<EOF
## Goldfish Findings Addressed
Goldfish review: disabled
EOF
  check "$name" "$($G "$INIT")" ""
fi

name="disabled without the status line warns"
if have "$name"; then
  init_with skip "${SHA} DISABLED" <<<"# Consensus"
  check "$name" "$($G "$INIT")" "${W} status line missing"
fi

name="a heading outside the section does not count"
if have "$name"; then
  init_with done "${SHA} findings=1 bm=G1" <<EOF
## Review Findings Addressed
### G1 — major — Retry limit — accepted

## Goldfish Findings Addressed
${STATUS_RAN}
EOF
  check "$name" "$($G "$INIT")" "${W} no disposition for G1"
fi

name="a fenced heading does not count"
if have "$name"; then
  init_with done "${SHA} findings=1 bm=G1" <<EOF
## Goldfish Findings Addressed
${STATUS_RAN}
\`\`\`
### G1 — major — Retry limit — accepted
\`\`\`
EOF
  check "$name" "$($G "$INIT")" "${W} no disposition for G1"
fi

name="an unknown disposition word does not count"
if have "$name"; then
  init_with done "${SHA} findings=1 bm=G1" <<EOF
## Goldfish Findings Addressed
${STATUS_RAN}
### G1 — major — Retry limit — ignored
EOF
  check "$name" "$($G "$INIT")" "${W} no disposition for G1"
fi

name="the latest done line is the one judged"
if have "$name"; then
  init_with done "000000000000 findings=1 bm=G9" <<EOF
## Goldfish Findings Addressed
${STATUS_RAN}
### G1 — major — Retry limit — accepted
EOF
  planner_state_write "$INIT" META goldfish done "${SHA} findings=1 bm=G1" >/dev/null 2>&1
  check "$name" "$($G "$INIT")" ""
fi

name="CRLF consensus.md is read"
if have "$name"; then
  init_with done "${SHA} findings=1 bm=G1" < <(printf '## Goldfish Findings Addressed\r\n%s\r\n### G1 — major — Retry — rejected (covered in spec a)\r\n' "$STATUS_RAN")
  check "$name" "$($G "$INIT")" ""
fi

name="through planner_crosscheck_run: warn, never fail"
if have "$name"; then
  init_with done "${SHA} findings=2 bm=G1,G2" <<EOF
## Goldfish Findings Addressed
### G1 — major — Retry limit — accepted
EOF
  planner_crosscheck_run "$INIT" >/dev/null 2>&1
  check "$name: one warn line" "$(grep -c '|META|crosscheck|warn|info GOLDFISH_UNADDRESSED ' "${SD}/state.log")" "1"
  check "$name: no fail line" "$(grep -c '|META|crosscheck|fail|GOLDFISH' "${SD}/state.log")" "0"
fi

name="mawk runs the family"
if have "$name"; then
  init_with done "${SHA} findings=2 bm=G1,G2" <<EOF
## Goldfish Findings Addressed
${STATUS_RAN}
### G1 — major — Retry limit — accepted
EOF
  if command -v mawk >/dev/null 2>&1; then
    m=$(PLANNER_GOLDFISH_AWK=mawk $G "$INIT")
    check "$name" "$m" "${W} no disposition for G2"
    if command -v gawk >/dev/null 2>&1; then
      check "gawk agrees with mawk" "$(PLANNER_GOLDFISH_AWK=gawk $G "$INIT")" "$m"
    else
      echo "  SKIP gawk agrees with mawk (gawk not installed)"
    fi
  else
    echo "  SKIP $name (mawk not installed)"
  fi
fi

echo "=== registration ==="
case " ${PLANNER_CROSSCHECK_WARN_CODES} " in
*" GOLDFISH_UNADDRESSED "*) pass "GOLDFISH_UNADDRESSED is a warn code" ;;
*) fail "GOLDFISH_UNADDRESSED is a warn code" "not listed" ;;
esac
hint=$(planner_crosscheck_fix_hint GOLDFISH_UNADDRESSED)
case "$hint" in
"no canned hint"*) fail "GOLDFISH_UNADDRESSED has a fix hint" "$hint" ;;
*) pass "GOLDFISH_UNADDRESSED has a fix hint" ;;
esac
acpre_line=$(grep -n 'planner_crosscheck_ac_precondition "\$initiative_id"' "${LIB_DIR}/planner-crosscheck.sh" | head -1 | cut -d: -f1)
gf_line=$(grep -n 'planner_crosscheck_goldfish "\$initiative_id"' "${LIB_DIR}/planner-crosscheck.sh" | head -1 | cut -d: -f1)
if [ -n "$gf_line" ] && [ -n "$acpre_line" ] && [ "$gf_line" -gt "$acpre_line" ]; then
  pass "the family runs after the AC precondition family"
else fail "the family runs after the AC precondition family" "acpre=${acpre_line:-?} goldfish=${gf_line:-?}"; fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
