#!/usr/bin/env bash
# planner-crosscheck.sh — Crosscheck phase orchestrator (issue #178).
#
# Crosscheck is the phase between Consensus and EpicGen: the last artifact-only
# phase, and the first point where any script compares the artifacts against
# each other and against the live repo rather than validating one file in
# isolation. It is deterministic bash, not an agent — nothing here reasons
# about content, it runs the existing linters and records what they found.
#
# Wires in the check families that exist today:
#   - planner-crosscheck-citations.sh   (#172 — citation + precedent grep)
#   - planner-crosscheck-propagation.sh (#173 — cross-ticket propagation)
#   - planner-crosscheck-bypass.sh      (#174 — bypass sweep + discovery gap)
#   - planner-crosscheck-contracts.sh   (#175 — cross-initiative contract shape)
#   - planner-crosscheck-signals.sh     (#220 — uniform per-ticket Signals blocks)
#   - planner-crosscheck-deps.sh        (#221 — dangling blocked-by references)
#   - planner-crosscheck-testdata.sh    (#503/#504 — unowned test data, cited
#                                        external artifacts never raised/answered;
#                                        planner-test-data-derivation tripwires)
#   - planner-crosscheck-ac-coverage.sh (rehearsal F16 — uncovered status codes)
#   - planner-crosscheck-params.sh      (planner-specify-parameters — undeclared
#                                        unit literals against ## Parameters)
#   - planner-crosscheck-ownership.sh   (planner-crosscheck-ownership — the
#                                        ## Writes / ## Reads tables judged
#                                        against each other)
#
# Before every family, the test-data synthesis sub-step
# (planner-testdata-synth.sh, planner-test-data-derivation) writes the TD
# specs, artifacts/testdata-synth.json and the INDEX.md block, so every
# family validates the synthesized state. Then, for a spec-ownership-v1
# initiative, the edges step (planner_ownership_edges_write) writes
# artifacts/ownership-edges.json, so the deps family's cycle check sees those
# edges too. See planner_crosscheck_run.
#
# Adding a check later means adding one more call in planner_crosscheck_run
# and, if it can emit a non-blocking finding, adding its codes to
# PLANNER_CROSSCHECK_WARN_CODES below.
#
# Every finding is written to state.log as its own line, in the format #176
# specifies:
#
#   {ISO8601}|META|crosscheck|fail|{CODE} {message}
#
# `META|<step>|fail` with the code as the first whitespace-delimited token of
# the message is exactly the shape ticket-retro's failure-histogram parser
# already reads (see #177) — no retro-side change needed once it is pointed
# at planner state logs.
#
# The phase's own progress marker is a normal Crosscheck|check|{start,done,
# fail} triplet, so planner_position_derive, planner_phase_fail_count and the
# rest of the state machine handle it exactly like every other phase — no
# special-casing needed there. What IS special-cased is the dispatch loop in
# SKILL.md: Crosscheck has no agent prompt (see planner_prompt_for_phase),
# so the loop calls planner_crosscheck_run directly instead of spawning an
# Agent, and treats a nonzero return as an immediate stop (not a retry) —
# retrying a deterministic check against unchanged artifacts cannot produce a
# different answer; only editing the artifacts and resuming can.
#
# A genuine-and-expected blocking finding (e.g. a documented ticket-count
# rescope already recorded in consensus.md, not a checker bug) is the one
# case retrying a deterministic check *can* legitimately change the outcome
# for — not by re-running the same linter, but by the operator recording an
# explicit override first. `resume <ID> --accept CODE:"reason"` (#222) writes
# META|crosscheck|accepted|<CODE> <reason> to state.log via
# planner_crosscheck_accept_set (SKILL.md step 2b, before the loop reaches
# Crosscheck again); _planner_crosscheck_emit_finding checks that record and
# treats a matching code as non-blocking on every subsequent run, recording
# each still-occurring instance as its own META|crosscheck|accepted entry so
# the audit trail — and the Completed phase's COMPLETED.md Warnings section,
# which reads the whole log — shows *why* it was allowed through, distinct
# from an automated pass.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_planner_crosscheck_source_if_missing() {
  local name="$1" path="$2"
  if ! declare -f "$name" >/dev/null 2>&1; then
    [ -f "$path" ] && source "$path"
  fi
}

_planner_crosscheck_source_if_missing "planner_crosscheck_citations" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-citations.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_propagation" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-propagation.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_bypass" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-bypass.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_contracts" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-contracts.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_signals" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-signals.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_deps" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-deps.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_testdata" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-testdata.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_ac_coverage" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-ac-coverage.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_params" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-params.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_ownership" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-ownership.sh"
_planner_crosscheck_source_if_missing "planner_testdata_synthesize" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-testdata-synth.sh"
_planner_crosscheck_source_if_missing "planner_state_write" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-state.sh"

# Codes that must NOT halt the run — logged as META|crosscheck|warn|info
# instead of META|crosscheck|fail|<code> (#176 AC4). Every code the
# citation/propagation families emit (CITATION_UNRESOLVED,
# CITATION_LINE_OUT_OF_RANGE, CITATION_SYMBOL_MISMATCH, PRECEDENT_NOT_FOUND,
# RESOLUTION_NOT_PROPAGATED, FORWARD_REF_UNFULFILLED, CARVE_SCOPE_LOST),
# #174's BYPASS_PATH_UNADDRESSED, #175's CONTRACT_MISMATCH /
# CONTRACT_CONSUMERS_UNNOTIFIED, #220's SIGNALS_UNIFORM, #221's
# DANGLING_BLOCKED_BY (and DEPENDENCY_CYCLE, planner-test-data-derivation), #503's TEST_DATA_UNOWNED and #504's
# CITED_ARTIFACT_MALFORMED / CITED_ARTIFACT_UNRAISED / CITED_ARTIFACT_UNRESOLVED /
# CITED_ARTIFACT_SOURCE_MISMATCH / CITED_ARTIFACT_UNREFERENCED block EpicGen per
# #176's table, as does AC_STATUS_UNCOVERED (planner-ac-coverage-and-epic-uat).
# TEST_DATA_UNSOURCED_LEGACY (a spec in an initiative that predates the Source
# contract) and CITED_ARTIFACTS_SECTION_MISSING are warn-level.
# DISCOVERY_GAP_UNRESOLVED and CONTRACT_UNDEFINED are warn-level: a declared
# exploration gap or an ambiguous upstream shape is a prompt for human
# judgment, not by itself proof of a defect.
# planner-test-data-derivation: TEST_DATA_INVENTORY_MISSING (no epic-wide
# inventory), TEST_DATA_IMPLIED_WEAK (weak-tier implied data, or a strong
# match in a legacy initiative) and VERIFICATION_NOTES_MISSING_LEGACY are
# warn-level; VERIFICATION_NOTES_MISSING and TEST_DATA_IMPLIED block, as does
# TEST_DATA_SYNTH_FAILED (the synthesis sub-step could not write its specs).
# planner-crosscheck-ownership: OWN_NEAR_MATCH, OWN_UNDECLARED_REF,
# OWN_EXTERNAL_UNANCHORED and OWN_EDGES_DIVERGED are tripwires, warn-level.
PLANNER_CROSSCHECK_WARN_CODES="DISCOVERY_GAP_UNRESOLVED CONTRACT_UNDEFINED TEST_DATA_UNSOURCED_LEGACY CITED_ARTIFACTS_SECTION_MISSING TEST_DATA_INVENTORY_MISSING TEST_DATA_IMPLIED_WEAK VERIFICATION_NOTES_MISSING_LEGACY OWN_NEAR_MATCH OWN_UNDECLARED_REF OWN_EXTERNAL_UNANCHORED OWN_EDGES_DIVERGED"

# Per-instance codes (planner-crosscheck-ownership D10). A listed code is
# accepted one instance at a time and never code-wide: emit matches each
# finding's instance token against `accepted|<token> …` records and ignores a
# bare `accepted|<CODE>` record; `--accept` sends `<CODE>@…` (and the refused
# code-wide form) to the code's parse function; the stop describer never asks
# a `flag:accept:<CODE>` question for it. One space-separated entry per code,
# fields separated by `:`
#
#   <CODE>:<instance_fn>:<parse_fn>:<note_fn>:<lib>:<detail_fn>
#
#   instance_fn <message>  the instance token of one finding message (the
#                          text after the code), or nothing
#   parse_fn <arg>         <arg> is the whole --accept value; prints
#                          `<token>\t<record text>`, or rc 1 with the reason
#                          on stderr (the code-wide form included)
#   note_fn <INIT> <count> the describer's note question for the code
#                          (planner-stop-describe.sh), or empty for none;
#                          codes sharing a note get it once
#   lib                    the lib/ file defining instance_fn, parse_fn and
#                          detail_fn, sourced on demand (empty: already defined)
#   detail_fn <message>    optional: the text a wildcard accept records ahead
#                          of the reason (PARAM_LITERAL: the literal), so its
#                          record is `<token> <detail> — <reason>`
#
# Wildcard accept: `--accept <CODE>@*:"<reason>"` is valid for every listed
# code. At persist time it records one `accepted|<token> …` line per distinct
# instance in the latest Crosscheck attempt's `fail|<CODE>` lines
# (planner_crosscheck_instance_accept_all); it never writes `<CODE>@*`, so an
# instance first seen in a later run still fails.
#
# The four ownership codes share one instance function, one parse function
# and one note (`ownership-findings`, asked once for all four).
PLANNER_CROSSCHECK_INSTANCE_CODES="PARAM_LITERAL:planner_crosscheck_params_instance:planner_crosscheck_params_accept_parse:_planner_stop_param_literals_question:planner-crosscheck-params.sh:planner_crosscheck_params_literal"
PLANNER_CROSSCHECK_INSTANCE_CODES+=" OWN_MULTI_WRITER:planner_crosscheck_ownership_instance:planner_crosscheck_ownership_accept_parse:_planner_stop_ownership_question:planner-crosscheck-ownership.sh:"
PLANNER_CROSSCHECK_INSTANCE_CODES+=" OWN_NO_WRITER:planner_crosscheck_ownership_instance:planner_crosscheck_ownership_accept_parse:_planner_stop_ownership_question:planner-crosscheck-ownership.sh:"
PLANNER_CROSSCHECK_INSTANCE_CODES+=" OWN_MULTI_FIRE:planner_crosscheck_ownership_instance:planner_crosscheck_ownership_accept_parse:_planner_stop_ownership_question:planner-crosscheck-ownership.sh:"
PLANNER_CROSSCHECK_INSTANCE_CODES+=" OWN_TRIGGER_UNOWNED:planner_crosscheck_ownership_instance:planner_crosscheck_ownership_accept_parse:_planner_stop_ownership_question:planner-crosscheck-ownership.sh:"

# Usage: planner_crosscheck_instance_field <code> <instance|parse|note|lib|detail>
# Prints the field of <code>'s entry (possibly empty); rc 1 when <code> is
# not a per-instance code or the field name is unknown.
planner_crosscheck_instance_field() {
  local code="$1" want="$2" entry rest i p n l d
  for entry in $PLANNER_CROSSCHECK_INSTANCE_CODES; do
    [ "${entry%%:*}" = "$code" ] || continue
    rest="${entry#*:}"
    IFS=: read -r i p n l d <<<"$rest"
    case "$want" in
    instance) printf '%s\n' "$i" ;;
    parse) printf '%s\n' "$p" ;;
    note) printf '%s\n' "$n" ;;
    lib) printf '%s\n' "$l" ;;
    detail) printf '%s\n' "$d" ;;
    *) return 1 ;;
    esac
    return 0
  done
  return 1
}

# Usage: planner_crosscheck_is_instance_code <code>
planner_crosscheck_is_instance_code() {
  planner_crosscheck_instance_field "$1" lib >/dev/null
}

# Source <code>'s lib into the current shell when its parse function is not
# defined yet. Usage: planner_crosscheck_instance_load <code>
planner_crosscheck_instance_load() {
  local lib fn
  lib=$(planner_crosscheck_instance_field "$1" lib) || return 1
  [ -n "$lib" ] || return 0
  fn=$(planner_crosscheck_instance_field "$1" parse)
  [ -n "$fn" ] && declare -f "$fn" >/dev/null 2>&1 && return 0
  # shellcheck source=/dev/null
  source "${_PLANNER_CROSSCHECK_LIB_DIR}/${lib}"
}

# Wildcard accept (planner-crosscheck-ownership D10): record one accept per
# distinct instance of <code> in the latest Crosscheck attempt (every line
# after the last `Crosscheck|check|start`), as `<token> <reason>`, or
# `<token> <detail> — <reason>` when the code has a detail function. An
# instance already accepted is not recorded again. Never writes `<code>@*`.
# Usage: planner_crosscheck_instance_accept_all <initiative_id> <code> <reason>
# rc 1 (reason on stderr) when the latest attempt has no <code> finding.
planner_crosscheck_instance_accept_all() {
  local initiative_id="$1" code="$2" reason="$3"
  local log start instance_fn detail_fn msg token detail found=0 seen=" "
  planner_crosscheck_instance_load "$code" || return 1
  instance_fn=$(planner_crosscheck_instance_field "$code" instance)
  detail_fn=$(planner_crosscheck_instance_field "$code" detail)
  log=$(planner_state_log "$initiative_id") || return 1
  start=""
  [ -f "$log" ] && start=$(grep -n '^[^|]*|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  if [ -n "$start" ] && [ -n "$instance_fn" ] && declare -f "$instance_fn" >/dev/null 2>&1; then
    while IFS= read -r msg; do
      msg="${msg#"$code" }"
      token=$("$instance_fn" "$msg")
      [ -n "$token" ] || continue
      found=1
      case "$seen" in *" ${token} "*) continue ;; esac
      seen="${seen}${token} "
      _planner_crosscheck_code_accepted "$initiative_id" "$token" && continue
      detail=""
      [ -n "$detail_fn" ] && declare -f "$detail_fn" >/dev/null 2>&1 && detail=$("$detail_fn" "$msg")
      if [ -n "$detail" ]; then
        planner_crosscheck_accept_set "$initiative_id" "$token" "${detail} — ${reason}"
      else
        planner_crosscheck_accept_set "$initiative_id" "$token" "$reason"
      fi
    done < <(tail -n "+$((start + 1))" "$log" | grep "^[^|]*|META|crosscheck|fail|${code} " | cut -d'|' -f5-)
  fi
  if [ "$found" -eq 0 ]; then
    echo "ERROR: --accept ${code}@*: no ${code} finding in the latest Crosscheck attempt" >&2
    return 1
  fi
  return 0
}

# Is <code> a warn-level code?
# Usage: _planner_crosscheck_is_warn_code <code>
_planner_crosscheck_is_warn_code() {
  case " ${PLANNER_CROSSCHECK_WARN_CODES} " in
  *" $1 "*) return 0 ;;
  *) return 1 ;;
  esac
}

# Codes the operator has explicitly accepted as genuine-and-expected for this
# initiative via `resume <ID> --accept CODE:"reason"` (#222) — e.g. a
# documented ticket-count rescope already recorded in consensus.md, not a
# checker bug. Persisted as META|crosscheck|accepted|<CODE> <reason> the
# moment the flag is parsed, before the dispatch loop reaches Crosscheck
# again (SKILL.md step 2b) — same disk-backed pattern as --create and
# --until, and the same governing principle from #144: nothing survives the
# dispatch loop's process boundary except what is written to the state log.
# A code accepted once stays accepted for the life of the initiative; there
# is no un-accept.
#
# Usage: planner_crosscheck_accept_set <initiative_id> <code> <reason>
planner_crosscheck_accept_set() {
  local initiative_id="$1" code="$2" reason="$3"
  planner_state_write "$initiative_id" "META" "crosscheck" "accepted" "${code} ${reason}"
}

# Usage: _planner_crosscheck_accepted_codes <initiative_id>
# Output (stdout): every accepted code, one per line, deduplicated.
_planner_crosscheck_accepted_codes() {
  local initiative_id="$1" log
  log=$(planner_state_log "$initiative_id")
  [ -f "$log" ] || return 0

  local line phase step status msg code
  while IFS='|' read -r _ts phase step status msg; do
    [ "$phase" = "META" ] || continue
    [ "$step" = "crosscheck" ] || continue
    [ "$status" = "accepted" ] || continue
    code=$(echo "$msg" | awk '{print $1}')
    [ -n "$code" ] && echo "$code"
  done <"$log" | sort -u
}

# Is <code> accepted for <initiative_id>?
# Usage: _planner_crosscheck_code_accepted <initiative_id> <code>
_planner_crosscheck_code_accepted() {
  local initiative_id="$1" code="$2" accepted
  accepted=$(_planner_crosscheck_accepted_codes "$initiative_id" | tr '\n' ' ')
  case " ${accepted}" in
  *" ${code} "*) return 0 ;;
  *) return 1 ;;
  esac
}

# Parse one finding line from a check family's stdout and write it to
# state.log in #176's format. The check families print:
#   planner-crosscheck-<family>: <CODE> <rest of message...>
# but also print non-finding summary lines in the same "prefix: text" shape
# (e.g. "planner-crosscheck-citations: 3 passed, 2 failed out of 5 files") —
# a real code is always upper-snake-case, which no summary line's first word
# is, so that's the discriminator.
# Usage: _planner_crosscheck_emit_finding <initiative_id> <finding_line>
# Returns: 0 if the finding was blocking, 1 if warn, 2 if not a finding line,
# 3 if the code was operator-accepted (#222).
_planner_crosscheck_emit_finding() {
  local initiative_id="$1" finding_line="$2"
  local body code message

  case "$finding_line" in
  *": "*) body="${finding_line#*: }" ;;
  *) return 2 ;;
  esac

  code=$(echo "$body" | awk '{print $1}')
  [[ "$code" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 2
  message="${body#"$code" }"

  # Per-instance codes (PLANNER_CROSSCHECK_INSTANCE_CODES; PARAM_LITERAL,
  # planner-specify-parameters D7) are accepted one instance at a time. A
  # matching instance record (e.g. `PARAM_LITERAL@<slug>=<canonical>`) makes
  # this one finding `accepted`, written with the instance token first so no
  # reader takes it for a code-wide accept; a bare `<CODE>` accept is ignored.
  if planner_crosscheck_is_instance_code "$code"; then
    local instance="" instance_fn
    instance_fn=$(planner_crosscheck_instance_field "$code" instance)
    [ -n "$instance_fn" ] && declare -f "$instance_fn" >/dev/null 2>&1 &&
      instance=$("$instance_fn" "$message")
    if [ -n "$instance" ] && _planner_crosscheck_code_accepted "$initiative_id" "$instance"; then
      planner_state_write "$initiative_id" "META" "crosscheck" "accepted" "${instance} ${message}"
      return 3
    fi
    planner_state_write "$initiative_id" "META" "crosscheck" "fail" "${code} ${message}"
    return 0
  fi

  if _planner_crosscheck_is_warn_code "$code"; then
    planner_state_write "$initiative_id" "META" "crosscheck" "warn" "info ${code} ${message}"
    return 1
  fi

  if _planner_crosscheck_code_accepted "$initiative_id" "$code"; then
    planner_state_write "$initiative_id" "META" "crosscheck" "accepted" "${code} ${message}"
    return 3
  fi

  planner_state_write "$initiative_id" "META" "crosscheck" "fail" "${code} ${message}"
  return 0
}

# Run one check family, emitting a state-log event for every finding line it
# printed to stdout.
# Usage: _planner_crosscheck_run_family <initiative_id> <check_fn> [<check_fn_args...>]
# Output (stdout): "<blocking_count> <warn_count> <accepted_count>"
_planner_crosscheck_run_family() {
  local initiative_id="$1"
  shift
  local blocking=0 warn=0 accepted=0
  local line rc

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    _planner_crosscheck_emit_finding "$initiative_id" "$line"
    rc=$?
    case "$rc" in
    0) blocking=$((blocking + 1)) ;;
    1) warn=$((warn + 1)) ;;
    3) accepted=$((accepted + 1)) ;;
    esac
  done < <("$@" 2>/dev/null)

  echo "$blocking $warn $accepted"
}

# Run the full Crosscheck phase for an initiative: both wired check families,
# emitting findings and the phase's own progress markers.
#
# Usage: planner_crosscheck_run <initiative_id>
# Returns: 0 if clean (or warn-only), 1 if any blocking finding was reported.
planner_crosscheck_run() {
  local initiative_id="$1"
  local total_blocking=0 total_warn=0 total_accepted=0
  local b w a

  # A state write that cannot resolve the initiative's log (REPOS_ROOT unset,
  # #459) must stop the phase, not run every check against nothing.
  if ! planner_state_write "$initiative_id" "Crosscheck" "check" "start" "running testdata-synth + citation + propagation + bypass + contracts + signals + deps + testdata checks"; then
    echo "planner-crosscheck: cannot write the state log — aborting Crosscheck" >&2
    return 1
  fi

  # Test-data synthesis (planner-test-data-derivation) runs first, before
  # every check family, so the families validate the synthesized state.
  # Ordering decision: it sits AFTER the `Crosscheck|check|start` marker, not
  # before it. Every reader that scopes "the latest Crosscheck attempt"
  # (planner_crosscheck_findings_summary / _report, stop-describe's code and
  # question scans) starts at that marker, so a TEST_DATA_SYNTH_FAILED
  # finding must land after it to be seen. The sub-step's own lines are
  # `Crosscheck|testdata-synth|start` / `|done` — never `fail`, which
  # planner_phase_fail_count would count as a second Crosscheck failure in
  # the same attempt; a failure leaves the start line unclosed and records
  # the finding. planner_position_derive skips `testdata-synth` lines, so a
  # crash after `testdata-synth|done` resumes Crosscheck instead of reading
  # that done line as the phase's.
  local synth_out synth_err synth_rc tds needs line
  synth_err=$(mktemp) || synth_err=/dev/null
  planner_state_write "$initiative_id" "Crosscheck" "testdata-synth" "start" "synthesizing test-data specs for unowned needs"
  synth_rc=0
  synth_out=$(planner_testdata_synthesize "$initiative_id" 2>"$synth_err") || synth_rc=$?
  if [ "$synth_rc" -eq 0 ]; then
    tds=$(grep -c . <<<"$synth_out")
    needs=$(awk -F'\037' '{ s += $3 } END { print s + 0 }' <<<"$synth_out")
    planner_state_write "$initiative_id" "Crosscheck" "testdata-synth" "done" "${tds} TD spec(s), ${needs} need(s)"
  else
    b=0 w=0 a=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      line="${line#planner-testdata-synth: }"
      line="${line#TD_SLUG_COLLISION }"
      _planner_crosscheck_emit_finding "$initiative_id" "planner-testdata-synth: TEST_DATA_SYNTH_FAILED ${line}"
      case $? in 0) b=$((b + 1)) ;; 1) w=$((w + 1)) ;; 3) a=$((a + 1)) ;; esac
    done <"$synth_err"
    if [ $((b + w + a)) -eq 0 ]; then
      _planner_crosscheck_emit_finding "$initiative_id" "planner-testdata-synth: TEST_DATA_SYNTH_FAILED synthesis exited ${synth_rc} with no message — see artifacts/testdata-synth.json and specs/"
      case $? in 0) b=1 ;; 3) a=1 ;; esac
    fi
    total_blocking=$((total_blocking + b))
    total_warn=$((total_warn + w))
    total_accepted=$((total_accepted + a))
  fi
  [ "$synth_err" = /dev/null ] || rm -f "$synth_err"

  # Ownership edges (planner-crosscheck-ownership D6/D7): right after
  # synthesis and before every family, so the deps family's DEPENDENCY_CYCLE
  # check reads artifacts/ownership-edges.json with the rest of the graph.
  # Gated on the spec-ownership-v1 marker: a legacy initiative gets no line
  # and no file. `META|ownership-edges` is not a `Crosscheck|<step>` line, so
  # planner_position_derive needs no skip for it. A divergence warning
  # (OWN_EDGES_DIVERGED) goes through the normal finding path; a read or
  # write failure is the blocking OWN_EDGES_FAILED and writes no done line.
  if planner_ownership_contract_initiative "$initiative_id" 2>/dev/null; then
    local own_out own_err own_rc own_msg
    own_err=$(mktemp) || own_err=/dev/null
    own_rc=0
    own_out=$(planner_ownership_edges_write "$initiative_id" 2>"$own_err") || own_rc=$?
    b=0 w=0 a=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      _planner_crosscheck_emit_finding "$initiative_id" "$line"
      case $? in 0) b=$((b + 1)) ;; 1) w=$((w + 1)) ;; 3) a=$((a + 1)) ;; esac
    done <<<"$own_out"
    if [ "$own_rc" -eq 0 ]; then
      planner_state_write "$initiative_id" "META" "ownership-edges" "done" "$(planner_ownership_edges_count "$initiative_id") edge(s)"
    else
      own_msg=$(head -1 "$own_err" 2>/dev/null)
      own_msg="${own_msg#planner-spec-ownership: }"
      _planner_crosscheck_emit_finding "$initiative_id" "planner-ownership-edges: OWN_EDGES_FAILED ${own_msg:-the edges step exited ${own_rc} with no message — see artifacts/ownership-edges.json}"
      case $? in 0) b=$((b + 1)) ;; 3) a=$((a + 1)) ;; esac
    fi
    total_blocking=$((total_blocking + b))
    total_warn=$((total_warn + w))
    total_accepted=$((total_accepted + a))
    [ "$own_err" = /dev/null ] || rm -f "$own_err"
  fi

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_citations "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_propagation "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_bypass "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_contracts "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_signals "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_deps "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_testdata "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_cited_artifacts "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_testdata_tripwires "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_ac_coverage "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_params "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  # Ownership family (planner-crosscheck-ownership): silent without the
  # spec-ownership-v1 marker.
  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_ownership "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  if [ "$total_blocking" -gt 0 ]; then
    planner_state_write "$initiative_id" "Crosscheck" "check" "fail" \
      "${total_blocking} blocking finding(s), ${total_warn} warn, ${total_accepted} accepted — see META|crosscheck entries"
    echo "planner-crosscheck: ${total_blocking} blocking finding(s), ${total_warn} warn, ${total_accepted} accepted" >&2
    return 1
  fi

  planner_state_write "$initiative_id" "Crosscheck" "check" "done" \
    "clean (${total_warn} warn, ${total_accepted} accepted)"
  echo "planner-crosscheck: clean (${total_warn} warn, ${total_accepted} accepted)"
  return 0
}

# Summarize recorded Crosscheck findings for status reporting (#176 AC5).
# Scoped to the most recent Crosscheck attempt only (everything at or after
# the last "Crosscheck|check|start" marker) — resume re-runs the phase after
# the operator edits artifacts, and a fixed finding from an earlier attempt
# must not keep reporting as outstanding forever just because state.log is
# append-only. Reads directly from state.log; does not re-run the checks.
#
# Usage: planner_crosscheck_findings_summary <initiative_id>
# Output (stdout): one "<count> <blocking|warn|accepted> <CODE>" line per
# distinct code, sorted by count descending, followed by a "TOTAL: <n>
# blocking, <n> warn, <n> accepted" line. No output at all if Crosscheck has
# not run yet, or its most recent run recorded no findings.
planner_crosscheck_findings_summary() {
  local initiative_id="$1"
  local log
  log=$(planner_state_log "$initiative_id")
  [ -f "$log" ] || return 0

  local start_line
  start_line=$(grep -n '|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  [ -z "$start_line" ] && return 0

  local blocking_total=0 warn_total=0 accepted_total=0
  declare -A _cc_counts=()
  declare -A _cc_kind=()
  local line phase step status msg code

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    IFS='|' read -r _ts phase step status msg <<<"$line"
    [ "$phase" = "META" ] || continue
    [ "$step" = "crosscheck" ] || continue

    case "$status" in
    fail)
      code=$(echo "$msg" | awk '{print $1}')
      [ -z "$code" ] && continue
      _cc_counts["$code"]=$((${_cc_counts["$code"]:-0} + 1))
      _cc_kind["$code"]="blocking"
      blocking_total=$((blocking_total + 1))
      ;;
    warn)
      # Warn findings are written as "info <CODE> <message>" — see
      # _planner_crosscheck_emit_finding.
      code=$(echo "$msg" | awk '{print $2}')
      [ -z "$code" ] && continue
      _cc_counts["$code"]=$((${_cc_counts["$code"]:-0} + 1))
      _cc_kind["$code"]="warn"
      warn_total=$((warn_total + 1))
      ;;
    accepted)
      # Operator-accepted findings (#222) are written as "<CODE> <message>",
      # same shape as `fail` — see _planner_crosscheck_emit_finding and
      # planner_crosscheck_accept_set.
      code=$(echo "$msg" | awk '{print $1}')
      [ -z "$code" ] && continue
      _cc_counts["$code"]=$((${_cc_counts["$code"]:-0} + 1))
      _cc_kind["$code"]="accepted"
      accepted_total=$((accepted_total + 1))
      ;;
    esac
  done < <(tail -n "+$((start_line + 1))" "$log")

  if [ "$blocking_total" -eq 0 ] && [ "$warn_total" -eq 0 ] && [ "$accepted_total" -eq 0 ]; then
    return 0
  fi

  for code in "${!_cc_counts[@]}"; do
    echo "${_cc_counts[$code]} ${_cc_kind[$code]} ${code}"
  done | sort -rn

  echo "TOTAL: ${blocking_total} blocking, ${warn_total} warn, ${accepted_total} accepted"
}

# ── Grouped finding report (#233) ───────────────────────────────────────────
#
# planner_crosscheck_findings_summary above answers "how many, of what code".
# That is the right shape for `status`, and the wrong shape for the thing an
# operator actually does after a blocking run: open one artifact at a time and
# fix every finding in it. Doing that from the raw log means re-reading
# `META|crosscheck|fail|CODE message` lines and re-deriving, per line, which
# file and which token they point at. planner_crosscheck_findings_report
# renders the same recorded data grouped file → code, with the offending
# citation/token kept inline and a canned one-line fix hint per code, so
# remediation cost tracks distinct defect classes rather than raw finding
# count.
#
# Presentation only. It re-reads the state log and never re-runs a check, so
# it cannot disagree with what Crosscheck actually recorded.

# Codes whose findings are inherently about a set of artifacts rather than one
# — grouping them under whichever filename happens to appear first in the
# message would point the operator at an arbitrary member of the set.
PLANNER_CROSSCHECK_CROSS_FILE_CODES="RESOLUTION_NOT_PROPAGATED CARVE_SCOPE_LOST SIGNALS_UNIFORM TEST_DATA_UNOWNED TEST_DATA_UNSOURCED_LEGACY OWN_MULTI_WRITER OWN_MULTI_FIRE"

# One-line remediation hint per finding code. Deliberately canned and code-
# scoped: it says what shape the fix takes, not what the specific fix is —
# the message already carries the specifics.
# Usage: planner_crosscheck_fix_hint <code>
planner_crosscheck_fix_hint() {
  case "$1" in
  CITATION_UNRESOLVED)
    echo "path does not resolve under REPOS_ROOT — check for an annotation on the path side of \`Name:path\` (move it to the Name side), a stale path, or a file that needs a \`(new)\` marker; a file that exists only on a ref Discovery did not pin (the message names the ref) means re-pin Discovery on the ref it read"
    ;;
  CITATION_LINE_OUT_OF_RANGE)
    echo "the file resolved but the cited line is past its end — re-read the file and cite a real line, or drop the line number"
    ;;
  CITATION_SYMBOL_MISMATCH)
    echo "the named symbol is not within ${PLANNER_CROSSCHECK_SYMBOL_PROXIMITY:-40} lines of the cited line — cite the line the symbol is defined on, or fix the symbol name"
    ;;
  PRECEDENT_NOT_FOUND)
    echo "the identifier claimed as prior art has zero matches under REPOS_ROOT — quote an identifier that exists, or drop the precedent claim"
    ;;
  RESOLUTION_NOT_PROPAGATED)
    echo "a Consensus resolution reached some specs and not others — copy the resolved wording into the missing-it specs"
    ;;
  FORWARD_REF_UNFULFILLED)
    echo "the referenced spec never delivers the promised terms — add them there, or drop the forward reference"
    ;;
  AC_STATUS_UNCOVERED)
    echo "the spec states this status code as a response but no acceptance criterion checks it — add an AC (and its Verification Notes row) for that response; never delete the behaviour sentence to clear this"
    ;;
  PARAM_TABLE_INVALID)
    echo "proposal.md ## Parameters is missing or malformed — write the table (Name | Key | Kind | Default | Value | Source) right after ## Business Outcomes, or None., and fix the named row"
    ;;
  PARAM_UNDECIDED)
    echo "a ## Parameters row is still open — answer it through the SPECIFY_DECISION round (resume --answers), or source its Value with a quote the artifact really holds"
    ;;
  PARAM_LITERAL | PARAM_LITERAL@*)
    echo "the spec states a unit value no decided ## Parameters row declares — declare it as a row (and name its key in backticks in ## Technical Context), or change the spec to the declared value; accept one genuine literal with the per-literal --accept the message prints"
    ;;
  OWN_TABLE_INVALID)
    echo "a spec's ## Writes or ## Reads section is missing or malformed — write each as None. or one table (Writes: columns Key and Op, Reads: columns Key and Source) right under the heading, and fix the named rows; an effect is caused with a trigger row in ## Writes, never read"
    ;;
  OWN_MULTI_WRITER | OWN_MULTI_WRITER@*)
    echo "two specs claim the same key in conflicting ways — give the key one owner and have the others read it, or narrow each transition so they leave different states (append never conflicts); accept a genuine overlap with the per-key --accept the message prints"
    ;;
  OWN_NO_WRITER | OWN_NO_WRITER@*)
    echo "a spec reads a key no other spec writes — add the write to the spec that owns it, or anchor the read: code:<path> where it already exists, framework:<name> when the platform provides it, external:<name> when an outside system does; accept a known gap with the per-read --accept the message prints"
    ;;
  OWN_MULTI_FIRE | OWN_MULTI_FIRE@*)
    echo "more than one spec owns the same side effect — keep one fire row (that spec's ACs carry delivery and idempotency) and make the others trigger"
    ;;
  OWN_TRIGGER_UNOWNED | OWN_TRIGGER_UNOWNED@*)
    echo "a spec triggers a side effect no spec owns — add a fire row to the spec that delivers the effect, or remove the trigger"
    ;;
  OWN_EDGES_FAILED)
    echo "Crosscheck could not write artifacts/ownership-edges.json — check the artifacts directory is writable, then resume"
    ;;
  CARVE_SCOPE_LOST)
    echo "the spec-file count no longer matches the ticket count Specify declared — record the rescope in consensus.md, or restore the missing spec"
    ;;
  BYPASS_PATH_UNADDRESSED)
    echo "a live code path matching this ticket's terms is covered by no spec — extend the spec's scope, or record the path as out of scope"
    ;;
  DISCOVERY_GAP_UNRESOLVED)
    echo "a gap Discovery declared is neither answered nor listed in proposal.md Out of Scope — resolve it, or scope it out explicitly"
    ;;
  CONTRACT_UNDEFINED)
    echo "new fields are declared without canonical names — name the structure's fields explicitly in the spec"
    ;;
  CONTRACT_MISMATCH)
    echo "two specs describe the same borrowed structure differently — align the two shapes, or rename one of them"
    ;;
  CONTRACT_CONSUMERS_UNNOTIFIED)
    echo "a structure retired here is still referenced by a consumer spec — update the consumer, or keep the field"
    ;;
  SIGNALS_UNIFORM)
    echo "these specs share a Signals block — Signals must reflect each spec's own discovery, so regenerate the duplicates"
    ;;
  DANGLING_BLOCKED_BY)
    echo "the blocked-by target matches no sibling spec (or is an ambiguous prefix) — use the exact spec slug, or an existing Linear issue ID"
    ;;
  DEPENDENCY_CYCLE)
    echo "these specs block each other in a cycle (## Labels blocked-by plus the test-data synthesis edges in artifacts/testdata-synth.json and the ownership edges in artifacts/ownership-edges.json), so TicketGen can create none of them — remove one blocked-by from a Labels line, or change the ## Writes / ## Reads rows that give an ownership edge (a verified code: read gives none); a TD spec never blocks on its own consumer"
    ;;
  TEST_DATA_UNOWNED)
    echo "these Verification Notes needs have no owner and Crosscheck's test-data synthesis could not take them — give each a valid Source: generate (synthesis then writes and owns the TD spec; do not hand-write a test-data pack), exists:<where>, external:<who>, or seeded-by:<slug> naming a spec with ## Test Data Provided — see docs/test-data-source.md"
    ;;
  TEST_DATA_SYNTH_FAILED)
    echo "test-data synthesis could not write its TD specs — usually a hand-written spec already holds a TD slug (<slug>-test-data or <prefix>-test-data-pack): rename or remove it, or point the needs it covers at it with Source seeded-by:<slug>, then resume"
    ;;
  CITED_ARTIFACT_UNRAISED)
    echo "Discovery could not retrieve this cited artifact and Consensus never asked about it — add the line from planner_cited_artifacts_questions to consensus.md ## Open Questions"
    ;;
  CITED_ARTIFACT_UNRESOLVED)
    echo "the operator has not answered where this cited artifact comes from — set its Answer: in consensus.md (exists:<where>, external:<who>, or generate) and make the matching specs' Source agree, or --accept the code"
    ;;
  CITED_ARTIFACT_SOURCE_MISMATCH)
    echo "a spec's Source for this cited artifact disagrees with the operator's answer in consensus.md — set the spec's Source to the answer (an answer of generate keeps Source: generate; Crosscheck's test-data synthesis then writes the TD spec that seeds it)"
    ;;
  CITED_ARTIFACT_UNREFERENCED)
    echo "no spec need cites this NOT FOUND artifact by its exact backticked name — quote it in the Test data of every need that uses it (a paraphrase is not checked), or --accept the code if no spec needs it"
    ;;
  CITED_ARTIFACT_MALFORMED)
    echo "a discovery.md ## Cited Artifacts item has no readable FOUND / NOT FOUND status — rewrite it as \`<name>\` — FOUND: <where> or \`<name>\` — NOT FOUND (searched: …)"
    ;;
  CITED_ARTIFACTS_SECTION_MISSING)
    echo "discovery.md has no ## Cited Artifacts section — add one (None. when nothing is cited) so unretrievable artifacts reach the operator"
    ;;
  TEST_DATA_UNSOURCED_LEGACY)
    echo "these specs predate the Source field — add Source: to their Verification Notes when convenient; not blocking for an initiative created before the contract"
    ;;
  TEST_DATA_INVENTORY_MISSING)
    echo "discovery.md has no ## Test Data Inventory — add the table (Entity / States/variants / Roles / Volume / Source / Load via / Privacy), or None. when no test needs data to exist first"
    ;;
  VERIFICATION_NOTES_MISSING)
    echo "this spec has acceptance criteria but no Verification Notes rows — add the table, one row per criterion, Test data derived from its Given/When (none only when nothing must exist first)"
    ;;
  VERIFICATION_NOTES_MISSING_LEGACY)
    echo "this spec has no Verification Notes rows — add the table when convenient; not blocking for an initiative created before the contract"
    ;;
  TEST_DATA_IMPLIED)
    echo "every Verification Notes row says none but a criterion implies data — derive the need with a Source, or answer the spec's TESTDATA_CONFIRM line in consensus.md (none, generate: <what>, exists:<where>, external:<who>)"
    ;;
  TEST_DATA_IMPLIED_WEAK)
    echo "a criterion may imply test data (weak match) while every row says none — check it; answer TESTDATA_CONFIRM: none in consensus.md to silence it"
    ;;
  *)
    echo "no canned hint for this code — read the finding message"
    ;;
  esac
}

# Shorten an artifact path for display: everything under the initiative's
# artifacts directory is shown relative to it (specs/vs-1.md), anything else
# is left alone.
# Usage: _planner_crosscheck_report_path <path>
_planner_crosscheck_report_path() {
  case "$1" in
  */artifacts/*) echo "${1##*/artifacts/}" ;;
  *) echo "$1" ;;
  esac
}

# Truncate a detail line so one long finding cannot swamp the report.
# Usage: _planner_crosscheck_report_trunc <text>
_planner_crosscheck_report_trunc() {
  local text="$1" width="${PLANNER_CROSSCHECK_REPORT_WIDTH:-160}"
  if [ "${#text}" -gt "$width" ]; then
    printf '%s...\n' "${text:0:width}"
  else
    printf '%s\n' "$text"
  fi
}

# Derive which artifact a finding is about, and the detail worth showing next
# to it, from the finding message with its code already stripped.
#
# The check families print two shapes. Most lead with the artifact locus —
# `<spec_file>:<line> → <token> (...)`, which is where citations, precedents,
# forward refs and discovery gaps put it. The rest name the artifact somewhere
# inside prose ("retired in vs-2.md without notifying ..."), where the first
# `.md`-suffixed token is always the file the fix belongs in. Anything with
# neither is reported ungrouped rather than guessed at.
#
# Fields are separated by \x1e (record separator) rather than a tab: the line
# number is empty for findings that name a file but no line, and a tab is an
# IFS-whitespace character, so `IFS=$'\t' read` would collapse the empty field
# and shift the detail into it.
#
# Usage: _planner_crosscheck_finding_locus <code> <message_body>
# Output (stdout): "<file><RS><line><RS><detail>"
_planner_crosscheck_finding_locus() {
  local code="$1" body="$2"
  local file="" line="" detail="$body" first tok

  case " ${PLANNER_CROSSCHECK_CROSS_FILE_CODES} " in
  *" ${code} "*)
    printf '%s\036%s\036%s\n' "(cross-file)" "" "$detail"
    return 0
    ;;
  esac

  first="${body%% *}"
  if [[ "$first" =~ ^(.+):([0-9]+)$ ]]; then
    file="${BASH_REMATCH[1]}"
    line="${BASH_REMATCH[2]}"
    detail="${body#"$first"}"
    detail="${detail# }"
    detail="${detail#→ }"
  else
    for tok in $body; do
      tok="${tok%,}"
      tok="${tok%)}"
      tok="${tok%:}"
      case "$tok" in
      *.md)
        file="$tok"
        break
        ;;
      esac
    done
  fi

  [ -n "$file" ] || file="(no file)"
  printf '%s\036%s\036%s\n' "$(_planner_crosscheck_report_path "$file")" "$line" "$detail"
}

# Render recorded Crosscheck findings grouped by artifact, then by code (#233).
# Scoped to the most recent Crosscheck attempt, exactly like
# planner_crosscheck_findings_summary — a finding fixed by an earlier resume
# must not reappear in the remediation list.
#
# Fields are peeled one at a time rather than with `IFS='|' read` because a
# finding message may legitimately contain a pipe (CONTRACT_MISMATCH separates
# its two quoted snippets with " | "), and splitting on every pipe would drop
# everything after the first one.
#
# Usage: planner_crosscheck_findings_report <initiative_id>
# Output (stdout): a header, one block per artifact, and a trailing TOTAL
# line. No output at all if Crosscheck has not run yet, or its most recent
# run recorded no findings.
planner_crosscheck_findings_report() {
  local initiative_id="$1"
  local log
  log=$(planner_state_log "$initiative_id")
  [ -f "$log" ] || return 0

  local start_line
  start_line=$(grep -n '|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  [ -z "$start_line" ] && return 0

  declare -A _ccr_blocking=()
  declare -A _ccr_warn=()
  declare -A _ccr_accepted=()
  declare -A _ccr_details=()
  declare -A _ccr_files=()
  declare -A _ccr_codes=()
  local blocking_total=0 warn_total=0 accepted_total=0
  local line rest phase step status msg code body kind key file lnum detail

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
    *"|"*"|"*"|"*"|"*) ;;
    *) continue ;;
    esac

    rest="${line#*|}"
    phase="${rest%%|*}"
    rest="${rest#*|}"
    step="${rest%%|*}"
    rest="${rest#*|}"
    status="${rest%%|*}"
    msg="${rest#*|}"

    [ "$phase" = "META" ] || continue
    [ "$step" = "crosscheck" ] || continue

    case "$status" in
    fail)
      kind="blocking"
      body="$msg"
      ;;
    accepted)
      kind="accepted"
      body="$msg"
      ;;
    warn)
      # Warn findings are written as "info <CODE> <message>" — see
      # _planner_crosscheck_emit_finding.
      kind="warn"
      body="${msg#info }"
      ;;
    *) continue ;;
    esac

    code="${body%% *}"
    [ -n "$code" ] || continue
    body="${body#"$code"}"
    body="${body# }"

    IFS=$'\x1e' read -r file lnum detail < <(_planner_crosscheck_finding_locus "$code" "$body")
    key="${file}"$'\x1f'"${code}"
    _ccr_files["$file"]=1
    _ccr_codes["$code"]=1
    _ccr_details["$key"]="${_ccr_details["$key"]:-}${lnum}"$'\x1e'"${detail}"$'\n'

    case "$kind" in
    blocking)
      _ccr_blocking["$key"]=$((${_ccr_blocking["$key"]:-0} + 1))
      blocking_total=$((blocking_total + 1))
      ;;
    warn)
      _ccr_warn["$key"]=$((${_ccr_warn["$key"]:-0} + 1))
      warn_total=$((warn_total + 1))
      ;;
    accepted)
      _ccr_accepted["$key"]=$((${_ccr_accepted["$key"]:-0} + 1))
      accepted_total=$((accepted_total + 1))
      ;;
    esac
  done < <(tail -n "+$((start_line + 1))" "$log")

  if [ "$blocking_total" -eq 0 ] && [ "$warn_total" -eq 0 ] && [ "$accepted_total" -eq 0 ]; then
    return 0
  fi

  echo "Crosscheck findings — ${initiative_id} (most recent attempt)"

  # Real artifacts first, alphabetically; the two pseudo-groups last, because
  # they are the findings with no single file to open.
  local -a ordered=()
  mapfile -t ordered < <(
    for file in "${!_ccr_files[@]}"; do
      case "$file" in
      "(cross-file)" | "(no file)") continue ;;
      esac
      printf '%s\n' "$file"
    done | LC_ALL=C sort
  )
  for file in "(cross-file)" "(no file)"; do
    [ -n "${_ccr_files["$file"]:-}" ] && ordered+=("$file")
  done

  local -a codes=() parts=()
  local label
  for file in "${ordered[@]}"; do
    echo ""
    echo "$file"

    mapfile -t codes < <(
      for key in "${!_ccr_details[@]}"; do
        [ "${key%%$'\x1f'*}" = "$file" ] || continue
        printf '%s\n' "${key#*$'\x1f'}"
      done | LC_ALL=C sort
    )

    for code in "${codes[@]}"; do
      key="${file}"$'\x1f'"${code}"
      parts=()
      [ "${_ccr_blocking["$key"]:-0}" -gt 0 ] && parts+=("${_ccr_blocking["$key"]} blocking")
      [ "${_ccr_warn["$key"]:-0}" -gt 0 ] && parts+=("${_ccr_warn["$key"]} warn")
      [ "${_ccr_accepted["$key"]:-0}" -gt 0 ] && parts+=("${_ccr_accepted["$key"]} accepted")
      label=$(
        IFS=,
        echo "${parts[*]}"
      )
      label="${label//,/, }"
      echo "  ${code} — ${label}"
      echo "    fix: $(planner_crosscheck_fix_hint "$code")"

      while IFS=$'\x1e' read -r lnum detail; do
        [ -z "${lnum}${detail}" ] && continue
        if [ -n "$lnum" ]; then
          _planner_crosscheck_report_trunc "    L${lnum}  ${detail}"
        else
          _planner_crosscheck_report_trunc "    ${detail}"
        fi
      done <<<"${_ccr_details["$key"]}"
    done
  done

  echo ""
  echo "TOTAL: ${blocking_total} blocking, ${warn_total} warn, ${accepted_total} accepted across ${#ordered[@]} artifact group(s), ${#_ccr_codes[@]} code(s)"
  return 0
}
