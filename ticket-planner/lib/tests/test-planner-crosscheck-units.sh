#!/usr/bin/env bash
# test-planner-crosscheck-units.sh — units judged per blocking Crosscheck check
# (planner-halt-recall, M3 part a).
#
# Covers: the units field helpers; a normal run reports units=N on the phase
# result line; a zero-unit input reports UNTESTED and still passes (UNTESTED
# never halts); a blocking run keeps its verdict and gets the same trailing
# field; and the counting changes no family's output or return code.
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-units.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-crosscheck.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"
unset PLANNER_CROSSCHECK_UNITS_FILE

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
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
contains() {
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "'$3' not in '$2'" ;; esac
}

# The value one check got in a units field.
unit_of() {
  local pair
  local IFS=,
  for pair in ${1#units=}; do
    [ "${pair%%:*}" = "$2" ] && printf '%s\n' "${pair#*:}"
  done
}

echo "=== planner-crosscheck units tests ==="

# ── Helpers ──────────────────────────────────────────────────────────────────

echo "--- helpers ---"

n_checks=$(wc -w <<<"$PLANNER_CROSSCHECK_UNIT_CHECKS" | tr -d ' ')
for c in RESOLUTION_NOT_PROPAGATED PRECEDENT_NOT_FOUND FORWARD_REF_UNFULFILLED CONTRACT_MISMATCH CONTRACT_CONSUMERS_UNNOTIFIED BYPASS_PATH_UNADDRESSED SIGNALS_UNIFORM AC_STATUS_UNCOVERED; do
  if _planner_crosscheck_is_warn_code "$c"; then
    fail "prose code $c is blocking" "listed in PLANNER_CROSSCHECK_WARN_CODES"
  else
    pass "prose code $c is blocking"
  fi
done
for c in resolution precedent forward-ref contract-mismatch contract-consumers bypass signals ac-coverage; do
  contains "prose check $c is counted" " $PLANNER_CROSSCHECK_UNIT_CHECKS " " $c "
done

field=$(planner_crosscheck_units_field "${TMPDIR}/no-such-file")
check "no units file: every check UNTESTED" "$(planner_crosscheck_units_untested "$field" | wc -w | tr -d ' ')" "$n_checks"
case "$field" in units=*) pass "field starts with units=" ;; *) fail "field starts with units=" "$field" ;; esac
case "$field" in *" "*) fail "field is one token" "$field" ;; *) pass "field is one token" ;; esac

PLANNER_CROSSCHECK_UNITS_FILE="${TMPDIR}/u1"
planner_crosscheck_units_add citation
planner_crosscheck_units_add citation 4
planner_crosscheck_units_add resolution 0
planner_crosscheck_units_add signals junk
field=$(planner_crosscheck_units_field "$PLANNER_CROSSCHECK_UNITS_FILE")
check "add sums counts" "$(unit_of "$field" citation)" "5"
check "a count of 0 is UNTESTED" "$(unit_of "$field" resolution)" "UNTESTED"
check "a non-numeric count is ignored" "$(unit_of "$field" signals)" "UNTESTED"
contains "untested list names resolution" " $(planner_crosscheck_units_untested "$field") " " resolution "
unset PLANNER_CROSSCHECK_UNITS_FILE

planner_crosscheck_units_add citation 9
if [ ! -e "${TMPDIR}/u2" ] && [ "$?" -eq 0 ]; then
  pass "add without PLANNER_CROSSCHECK_UNITS_FILE is a no-op"
else
  fail "add without PLANNER_CROSSCHECK_UNITS_FILE is a no-op" "file written"
fi

# ── Fixture initiative ───────────────────────────────────────────────────────

new_init() {
  local id="$1"
  planner_state_init "$id" "units test idea" >/dev/null
  mkdir -p "$(planner_initiative_dir "$id")/artifacts/specs"
  planner_state_write "$id" "Specify" "synthesize" "done" "ok"
}

spec() {
  cat >"$(planner_initiative_dir "$1")/artifacts/specs/$2.md"
}

# ── Zero-unit input: UNTESTED, still a pass ──────────────────────────────────

echo "--- zero-unit input ---"

INIT0="INIT-1700000000-0001"
new_init "$INIT0"
planner_specify_result_write "$INIT0" >/dev/null
out=$(planner_crosscheck_run "$INIT0" 2>&1)
rc=$?
check "empty initiative: run still passes (UNTESTED never halts)" "$rc" "0"
log0=$(planner_state_log "$INIT0")
done_line=$(grep '|Crosscheck|check|done|' "$log0" | tail -1)
contains "done line keeps its existing message" "$done_line" "|Crosscheck|check|done|clean (0 warn, 0 accepted) units="
field="${done_line##* }"
check "empty initiative: resolution UNTESTED" "$(unit_of "$field" resolution)" "UNTESTED"
check "empty initiative: signals UNTESTED" "$(unit_of "$field" signals)" "UNTESTED"
check "empty initiative: carve-scope UNTESTED (record holds no spec)" "$(unit_of "$field" carve-scope)" "UNTESTED"
contains "stdout carries the same field" "$out" "$field"
check "no META|crosscheck line added for UNTESTED" "$(grep -c '|META|crosscheck|' "$log0")" "0"
check "position advances past Crosscheck" "$(planner_position_derive "$INIT0")" "EpicGen"
check "units_latest reads one row per check" "$(planner_crosscheck_units_latest "$INIT0" | wc -l | tr -d ' ')" "$n_checks"

# ── Normal run: units=N ──────────────────────────────────────────────────────

echo "--- normal run ---"

INIT1="INIT-1700000000-0002"
new_init "$INIT1"
spec "$INIT1" vs-a <<'EOF'
# vs-a

## Description

Sets `status` to classified on the confirm path.

## Proposed Behaviour

The endpoint returns 404 when the record is missing.

## Acceptance Criteria

- [ ] A missing record returns 404.

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|---|---|---|---|---|---|
| A missing record returns 404 | reader | none | none | 404 | yes |

## Labels

blocked-by:vs-b

## Signals

```json
{"services_identified": 1, "symbols_resolved": 2, "prior_art_found": true, "TargetSymbols": ""}
```
EOF
spec "$INIT1" vs-b <<'EOF'
# vs-b

## Description

Also sets `status` to classified on the split path.

## Signals

```json
{"services_identified": 2, "symbols_resolved": 5, "prior_art_found": false, "TargetSymbols": ""}
```
EOF
cat >"$(planner_initiative_dir "$INIT1")/artifacts/consensus.md" <<'EOF'
## Findings Addressed

1. Parent terminal state must be consistent across both split paths.
   Disposition: Accepted.
   Both split paths flip the parent document to `status`. Applies to vs-a and vs-b.
EOF
planner_specify_result_write "$INIT1" >/dev/null
planner_crosscheck_run "$INIT1" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || grep "|META|crosscheck|" "$(planner_state_log "$INIT1")"
check "normal run passes" "$rc" "0"
field=$(planner_crosscheck_units_latest "$INIT1" | awk -F'\t' '{printf "%s%s:%s", (NR > 1 ? "," : "units="), $1, $2}')
check "resolution judged the one block naming both specs" "$(unit_of "$field" resolution)" "1"
check "carve-scope judged both recorded specs" "$(unit_of "$field" carve-scope)" "2"
check "signals judged both Signals blocks" "$(unit_of "$field" signals)" "2"
check "deps-dangling judged the one blocked-by token" "$(unit_of "$field" deps-dangling)" "1"
check "ac-coverage judged the one stated status code" "$(unit_of "$field" ac-coverage)" "1"
check "precedent judged nothing" "$(unit_of "$field" precedent)" "UNTESTED"

# ── Blocking run: verdict unchanged, field appended ──────────────────────────

echo "--- blocking run ---"

INIT2="INIT-1700000000-0003"
new_init "$INIT2"
spec "$INIT2" vs-c <<'EOF'
# vs-c

## Description

Flips `status` to classified.
EOF
spec "$INIT2" vs-d <<'EOF'
# vs-d

## Description

Flips out of needs_review to ready — no mention of the field being set.
EOF
cat >"$(planner_initiative_dir "$INIT2")/artifacts/consensus.md" <<'EOF'
## Findings Addressed

1. Parent terminal state must be consistent across both split paths.
   Disposition: Accepted.
   Both split paths flip the parent document to `status`. Applies to vs-c and vs-d.
EOF
planner_specify_result_write "$INIT2" >/dev/null
planner_crosscheck_run "$INIT2" >/dev/null 2>&1
rc=$?
check "asymmetric resolution still blocks" "$rc" "1"
log2=$(planner_state_log "$INIT2")
fail_line=$(grep '|Crosscheck|check|fail|' "$log2" | tail -1)
contains "fail line keeps its existing message" "$fail_line" "|Crosscheck|check|fail|1 blocking finding(s), 0 warn, 0 accepted — see META crosscheck entries units="
check "fail line resolution units" "$(unit_of "${fail_line##* }" resolution)" "1"
check "finding line unchanged" "$(grep -c '|META|crosscheck|fail|RESOLUTION_NOT_PROPAGATED has-it=\[vs-c\] missing-it=\[vs-d\]' "$log2")" "1"
check "findings summary unchanged" "$(planner_crosscheck_findings_summary "$INIT2" | tail -1)" "TOTAL: 1 blocking, 0 warn, 0 accepted"
check "stop describer still reports the Crosscheck stop" "$(grep '|Crosscheck|check|' "$log2" | tail -1 | cut -d'|' -f4)" "fail"

# ── Counting changes no family's output or return code ───────────────────────

echo "--- families unchanged by counting ---"

for INIT in "$INIT1" "$INIT2"; do
  for fam in planner_crosscheck_citations planner_crosscheck_propagation planner_crosscheck_bypass \
    planner_crosscheck_contracts planner_crosscheck_signals planner_crosscheck_deps planner_crosscheck_testdata \
    planner_crosscheck_cited_artifacts planner_crosscheck_testdata_tripwires planner_crosscheck_ac_coverage \
    planner_crosscheck_body planner_crosscheck_params planner_crosscheck_ownership planner_crosscheck_panel; do
    off=$("$fam" "$INIT" 2>/dev/null)
    off_rc=$?
    on=$(PLANNER_CROSSCHECK_UNITS_FILE="${TMPDIR}/u-fam" "$fam" "$INIT" 2>/dev/null)
    on_rc=$?
    if [ "$off" = "$on" ] && [ "$off_rc" = "$on_rc" ]; then
      pass "$fam ($INIT): same output and rc with counting on"
    else
      fail "$fam ($INIT): same output and rc with counting on" "rc $off_rc vs $on_rc"
    fi
  done
done

f=$(planner_initiative_dir "$INIT1")/artifacts/specs/vs-a.md
check "_planner_crosscheck_ac_coverage_one without --units is unchanged" \
  "$(_planner_crosscheck_ac_coverage_one "$f" | grep -c '^#units')" "0"
check "_planner_crosscheck_ac_coverage_one --units adds one #units line" \
  "$(_planner_crosscheck_ac_coverage_one "$f" --units | tail -1)" "#units	1"

# ── Old log without a units field ────────────────────────────────────────────

echo "--- pre-units log ---"

INIT3="INIT-1700000000-0004"
new_init "$INIT3"
planner_state_write "$INIT3" "Crosscheck" "check" "done" "clean (0 warn, 0 accepted)"
if planner_crosscheck_units_latest "$INIT3" >/dev/null; then
  fail "units_latest on a pre-units log returns 1" "returned 0"
else
  pass "units_latest on a pre-units log returns 1"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
