#!/usr/bin/env bash
# planner-crosscheck-units.sh — how many units each blocking Crosscheck check
# actually judged (planner-halt-recall, M3 part a).
#
# A pass that judged nothing is not a pass. Rehearsal iterations 11, 12 and 15
# "passed" RESOLUTION_NOT_PROPAGATED with zero consensus blocks to judge, and
# the F94 precondition held unseen from iteration 08 to 16. So every blocking
# check counts the units it judged (citations resolved, precedent identifiers
# searched, consensus blocks compared, ...) and Crosscheck reports the counts.
# A check that judged 0 units is reported UNTESTED.
#
# UNTESTED is a measurement, never a halt: nothing reads it to decide pass or
# block. Every pass/block decision is unchanged.
#
# How a count travels: planner_crosscheck_run sets PLANNER_CROSSCHECK_UNITS_FILE
# (a temp file, dynamically scoped `local`, never exported) before it runs the
# families. A check calls planner_crosscheck_units_add <check> [n] for each
# unit it judges; with the variable unset (a family run on its own, a test,
# Specify's self-lint) the call does nothing. The families run in process
# substitutions, so a shell variable would not survive; the file does.
#
# Where the counts land: one field appended at the END of the phase's existing
# result line, in state.log and on stdout/stderr, so no existing field moves:
#
#   {ts}|Crosscheck|check|done|clean (2 warn, 0 accepted) units=citation:14,precedent:UNTESTED,...
#   {ts}|Crosscheck|check|fail|3 blocking finding(s), 0 warn, 0 accepted — see ... units=...
#
# The field is one whitespace-free token: `units=` then `<check>:<n|UNTESTED>`
# pairs joined by commas, in PLANNER_CROSSCHECK_UNIT_CHECKS order.
#
# Sourceable library — no set -euo pipefail.

# Every blocking check, in run order. A check is blocking when it can emit a
# code that is not in PLANNER_CROSSCHECK_WARN_CODES. The unit each one counts:
#   citation            a path:line citation token resolved (prose + TargetSymbols)
#   precedent           a precedent identifier searched for (PRECEDENT_NOT_FOUND)
#   resolution          an accepted consensus block naming 2+ specs where 2+ of
#                       them had terms compared (RESOLUTION_NOT_PROPAGATED)
#   forward-ref         a (spec line, target spec) pair whose promised terms
#                       were looked up (FORWARD_REF_UNFULFILLED)
#   carve-scope         a spec slug in the Specify record (CARVE_SCOPE_LOST)
#   bypass              a guard paragraph whose quoted terms were swept for
#                       writers (BYPASS_PATH_UNADDRESSED)
#   contract-mismatch   a pair of blocks, one per initiative, whose shape terms
#                       were compared for a borrowed structure (CONTRACT_MISMATCH)
#   contract-consumers  a retired structure whose consumers were searched
#                       (CONTRACT_CONSUMERS_UNNOTIFIED)
#   signals             a spec with a Signals JSON block (SIGNALS_UNIFORM)
#   deps-dangling       a blocked-by token resolved (DANGLING_BLOCKED_BY)
#   deps-cycle          a node of the dependency graph (DEPENDENCY_CYCLE)
#   testdata-source     a test-data need judged for its Source (TEST_DATA_UNOWNED)
#   cited-artifacts     a ## Cited Artifacts entry in discovery.md (CITED_ARTIFACT_*)
#   testdata-tripwires  a non-synthesized spec checked for Verification Notes
#                       rows and implied data (VERIFICATION_NOTES_MISSING,
#                       TEST_DATA_IMPLIED)
#   ac-coverage         a status code stated as a response (AC_STATUS_UNCOVERED)
#   body                a spec checked against the ticket-body-v2 contract
#                       (VERIFY_MODE_INVALID, EDGE_CASES_MISSING)
#   params              a unit literal judged against ## Parameters (PARAM_LITERAL)
#   ownership           a spec whose ## Writes / ## Reads were judged (OWN_*)
#   ac-precondition     a code: precondition row checked against the schema
#                       (AC_PRECONDITION_UNREACHABLE)
#   panel               a review panel seat whose results were judged
#                       (PANEL_STOP_SKIPPED)
# Not counted: the warn-only checks (codespan, goldfish, contract_undefined,
# discovery_gap) and the two step-failure codes TEST_DATA_SYNTH_FAILED and
# OWN_EDGES_FAILED, which report a step that could not run, not a judgement.
PLANNER_CROSSCHECK_UNIT_CHECKS="citation precedent resolution forward-ref carve-scope bypass contract-mismatch contract-consumers signals deps-dangling deps-cycle testdata-source cited-artifacts testdata-tripwires ac-coverage body params ownership ac-precondition panel"

# Count <n> (default 1) judged units for <check>. A no-op unless
# PLANNER_CROSSCHECK_UNITS_FILE is set. Always returns 0.
# Usage: planner_crosscheck_units_add <check> [<n>]
planner_crosscheck_units_add() {
  [ -n "${PLANNER_CROSSCHECK_UNITS_FILE:-}" ] || return 0
  local n="${2:-1}"
  case "$n" in '' | *[!0-9]*) return 0 ;; esac
  printf '%s\t%s\n' "$1" "$n" >>"$PLANNER_CROSSCHECK_UNITS_FILE" 2>/dev/null || true
  return 0
}

# The units field for a units file: `units=<check>:<n|UNTESTED>,...` over
# PLANNER_CROSSCHECK_UNIT_CHECKS. A check with no record, or a total of 0, is
# UNTESTED. A missing file makes every check UNTESTED.
# Usage: planner_crosscheck_units_field <units_file>
planner_crosscheck_units_field() {
  local file="$1"
  local -A sum=()
  local check n out=""
  if [ -f "$file" ]; then
    while IFS=$'\t' read -r check n; do
      [ -n "$check" ] || continue
      case "$n" in '' | *[!0-9]*) continue ;; esac
      sum[$check]=$((${sum[$check]:-0} + n))
    done <"$file"
  fi
  for check in $PLANNER_CROSSCHECK_UNIT_CHECKS; do
    n="${sum[$check]:-0}"
    [ "$n" -gt 0 ] || n=UNTESTED
    out+="${out:+,}${check}:${n}"
  done
  printf 'units=%s\n' "$out"
}

# The checks a units field reports UNTESTED, space-separated (empty when none).
# Usage: planner_crosscheck_units_untested <units_field>
planner_crosscheck_units_untested() {
  local field="${1#units=}" pair out=""
  local IFS=,
  for pair in $field; do
    [ "${pair#*:}" = UNTESTED ] && out+="${out:+ }${pair%%:*}"
  done
  printf '%s\n' "$out"
}

# The units of the latest Crosscheck attempt, read from state.log: one
# `<check>\t<n|UNTESTED>` line per check, from the last
# `Crosscheck|check|done` or `|fail` line's trailing units= field. Prints
# nothing (rc 1) when there is no such line or it carries no units field (a
# run from before planner-halt-recall).
# Usage: planner_crosscheck_units_latest <initiative_id>
planner_crosscheck_units_latest() {
  local log line field pair
  log=$(planner_state_log "$1" 2>/dev/null) || return 1
  [ -f "$log" ] || return 1
  line=$(grep -E '^[^|]*\|Crosscheck\|check\|(done|fail)\|' "$log" | tail -1)
  field="${line##* }"
  case "$field" in units=*) ;; *) return 1 ;; esac
  field="${field#units=}"
  local IFS=,
  for pair in $field; do
    printf '%s\t%s\n' "${pair%%:*}" "${pair#*:}"
  done
}
