#!/usr/bin/env bash
# halt-fixtures.sh — fixture initiatives for every planner halt, plus each
# halt's own bash block from skills/ticket-planner/SKILL.md, run verbatim
# (planner-headless-questions task 1.1).
#
# Two consumers:
#   - capture-halt-goldens.sh records each halt's stdout/stderr/exit code
#     into fixtures/halt-goldens/ (captured on main before the stop describer
#     existed);
#   - test-planner-stop-describe.sh re-runs every halt against those goldens
#     (the halts must not change) and checks the stop describer names the
#     same reason the real halt did.
#
# Sourceable only. The caller sets REPOS_ROOT to an empty scratch directory
# and HOME to a scratch home, so the cross-plugin resolvers find this
# checkout's ticket-auto-pipeline rather than whatever version is installed
# — the goldens must not depend on the machine they were captured on.
#
# The SKILL.md blocks below are copied, not sourced: SKILL.md is markdown an
# agent executes, not a script. If a halt block in SKILL.md changes, copy the
# change here too — the golden diff is what notices when the two disagree.

_HALT_FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HALT_LIB_DIR="${_HALT_FIXTURES_DIR}/.."

# Every halt the stop describer must recognise, with the reason it must name.
HALT_FIXTURE_REASONS="create-gate-stop:CREATE_GATE create-gate-dispatch:CREATE_GATE crosscheck:CROSSCHECK_BLOCKED adr-gate:ADR_GATE project-gate:PROJECT_GATE refinement:REFINEMENT_HALT until:UNTIL_STOP"

# _halt_done <init> <phase...> — mark phases done, in order.
_halt_done() {
  local init="$1" phase
  shift
  for phase in "$@"; do
    planner_state_write "$init" "$phase" "run" "start" "fixture"
    planner_state_write "$init" "$phase" "run" "done" "fixture"
  done
}

# halt_fixture_init <name> <init_id> — build the state the halt fires on.
halt_fixture_init() {
  local name="$1" init="$2"
  planner_state_init "$init" "Add CSV export to the billing dashboard" >/dev/null

  case "$name" in
  create-gate-stop | create-gate-dispatch)
    _halt_done "$init" Appraisal Discovery Architecture Specify Review Consensus Crosscheck
    ;;
  crosscheck)
    _halt_done "$init" Appraisal Discovery Architecture Specify Review Consensus
    # Crosscheck's own findings are written by halt_fixture_run's stub of
    # planner_crosscheck_run, exactly as the real run records them.
    ;;
  adr-gate)
    _halt_done "$init" Appraisal Discovery
    planner_state_write "$init" "Architecture" "design" "start" "fixture"
    planner_state_write "$init" "META" "adr-gate" "fail" "CREATED_PROPOSED ADR_ID=ADR-0007"
    planner_state_write "$init" "Architecture" "design" "fail" "parked on ADR gate: CREATED_PROPOSED ADR-0007"
    ;;
  project-gate)
    _halt_done "$init" Appraisal Discovery Architecture Specify Review Consensus Crosscheck
    planner_authorize_create "$init" "operator passed --create"
    planner_stop_after_set "$init" ""
    planner_state_write "$init" "EpicGen" "create" "start" "fixture"
    cat >"$(planner_initiative_dir "$init")/artifacts/appraisal.md" <<'APPRAISAL'
# Appraisal

## Affected Services
- Ledgerly — billing dashboard

## Type
feature
APPRAISAL
    ;;
  refinement)
    _halt_done "$init" Appraisal Discovery Architecture Specify Review Consensus Crosscheck
    planner_authorize_create "$init" "operator passed --create"
    planner_stop_after_set "$init" ""
    planner_state_write "$init" "EpicGen" "create" "start" "fixture"
    planner_state_write "$init" "EpicGen" "create" "done" "EPIC_ID=PRO-100"
    planner_state_write "$init" "TicketGen" "verify" "start" "fixture"
    planner_state_write "$init" "TicketGen" "verify" "done" "2 tickets verified."
    _halt_refinement_manifests "$init"
    ;;
  until)
    _halt_done "$init" Appraisal Discovery Architecture Specify Review
    planner_stop_after_set "$init" "Review"
    ;;
  *)
    echo "halt-fixtures: unknown fixture '${name}'" >&2
    return 1
    ;;
  esac
}

# One ready child, one not-ready child (missing intent + vague ACs).
_halt_refinement_manifests() {
  local init="$1" dor_fixtures pair tid fixture pdir
  dor_fixtures="${_HALT_LIB_DIR}/../../ticket-auto-pipeline/lib/tests/fixtures/dor"
  source "${_HALT_LIB_DIR}/planner-refinement.sh"
  _planner_refinement_source_deps || return 1
  write_epic_manifest "PRO-100" "" "per-ticket" "" '[]' >/dev/null
  for pair in "PRO-101:01-excellent" "PRO-102:03-missing-intent"; do
    tid="${pair%%:*}"
    fixture="${pair#*:}"
    write_ticket_manifest "$tid" "$init" "feature" '[]' >/dev/null
    add_epic_manifest_child "PRO-100" "$tid" >/dev/null
    pdir="${REPOS_ROOT}/.ticket-auto/initiatives/${init}/tickets/${tid}/planner"
    mkdir -p "$pdir"
    cp "${dor_fixtures}/${fixture}.md" "${pdir}/body.md"
  done
}

# halt_fixture_run <name> <init_id> <out_dir>
# Runs the halt's SKILL.md block in a subshell and writes out_dir/<name>.out,
# .err and .rc, with the scratch REPOS_ROOT replaced by <REPOS_ROOT>.
halt_fixture_run() {
  local name="$1" INITIATIVE_ID="$2" out_dir="$3"
  local STATE_DIR rc
  STATE_DIR=$(planner_initiative_dir "$INITIATIVE_ID")
  mkdir -p "$out_dir"

  (
    set +e
    case "$name" in
    create-gate-stop)
      # SKILL.md step 6, after a `plan` run's Crosscheck completes.
      PHASE="Crosscheck"
      if planner_should_stop_after "$INITIATIVE_ID" "$PHASE"; then
        echo "Stopped after ${PHASE} — $(planner_stop_reason "$INITIATIVE_ID")"
        echo "Artifacts:  ${STATE_DIR}/artifacts/"
        echo "Specs:      ${STATE_DIR}/artifacts/specs/"
        echo "State log:  $(planner_state_log "$INITIATIVE_ID")"
        if planner_create_authorized "$INITIATIVE_ID"; then
          echo "Continue:   /ticket-planner resume ${INITIATIVE_ID}"
        else
          echo "To create:  /ticket-planner resume ${INITIATIVE_ID} --create"
        fi
        exit 0
      fi
      ;;
    create-gate-dispatch)
      # SKILL.md step 1, a plain `resume` reaching EpicGen.
      PHASE="EpicGen"
      if ! planner_create_gate_check "$INITIATIVE_ID" "$PHASE"; then
        echo "Planning complete — nothing was created in Linear."
        echo "Artifacts:  ${STATE_DIR}/artifacts/"
        echo "Specs:      ${STATE_DIR}/artifacts/specs/"
        echo "State log:  $(planner_state_log "$INITIATIVE_ID")"
        echo "To create:  /ticket-planner resume ${INITIATIVE_ID} --create"
        exit 0
      fi
      ;;
    crosscheck)
      # SKILL.md step 1a. planner_crosscheck_run is stubbed after sourcing:
      # the check families need real artifacts and a repo, and the halt's
      # output depends only on what the run recorded.
      source "${CLAUDE_PLUGIN_ROOT}/lib/planner-crosscheck.sh"
      planner_crosscheck_run() {
        local init="$1"
        planner_state_write "$init" "Crosscheck" "check" "start" "running citation + propagation + bypass + contracts + signals + deps checks"
        _planner_crosscheck_emit_finding "$init" "planner-crosscheck-propagation: CARVE_SCOPE_LOST ticket count changed 4 -> 3 after Specify; audit scope by hand"
        _planner_crosscheck_emit_finding "$init" "planner-crosscheck-citations: CITATION_UNRESOLVED specs/export-csv.md: src/billing/export.py:42 does not resolve"
        _planner_crosscheck_emit_finding "$init" "planner-crosscheck-contracts: CONTRACT_UNDEFINED specs/export-csv.md: ExportRow gains fields with no names"
        planner_state_write "$init" "Crosscheck" "check" "fail" "2 blocking finding(s), 1 warn, 0 accepted — see META|crosscheck entries"
        return 1
      }
      if ! planner_crosscheck_run "$INITIATIVE_ID"; then
        echo "Crosscheck found blocking findings — fix the cited artifacts and resume."
        echo ""
        planner_crosscheck_findings_report "$INITIATIVE_ID"
        echo ""
        echo "Raw log:    grep 'META|crosscheck|fail' $(planner_state_log "$INITIATIVE_ID")"
        echo "Artifacts:  ${STATE_DIR}/artifacts/"
        echo "Resume:     /ticket-planner resume ${INITIATIVE_ID}"
        exit 0
      fi
      ;;
    adr-gate)
      # SKILL.md step 4a.
      source "${CLAUDE_PLUGIN_ROOT}/lib/planner-adr-gate.sh"
      if _adr_hit=$(planner_adr_gate_blocked "$INITIATIVE_ID" "Architecture" "design"); then
        _adr_verdict=$(echo "$_adr_hit" | cut -f1)
        _adr_id=$(echo "$_adr_hit" | cut -f2)
        echo "Architecture parked on the ADR gate: ${_adr_verdict} (${_adr_id})"
        echo ""
        echo "architecture.md was still written — the working design is unaffected. What's"
        echo "missing is ratification: a human accepts ${_adr_id} (or resolves the conflict,"
        echo "for a CONFLICT verdict) out of band, then this phase resumes and re-classifies."
        echo ""
        echo "Artifacts:  ${STATE_DIR}/artifacts/"
        echo "Raw log:    grep 'META|adr-gate|fail' $(planner_state_log "$INITIATIVE_ID")"
        echo "Resume:     /ticket-planner resume ${INITIATIVE_ID}"
        exit 0
      fi
      ;;
    project-gate)
      # The Epic Gen prompt's project gate (planner-phase-prompts.sh). The
      # one network call is stubbed, as test-planner-project-gate.sh does.
      source "${CLAUDE_PLUGIN_ROOT}/lib/planner-project-gate.sh"
      planner_linear_list_team_projects() { echo '[{"id":"p1","name":"Ledgerly"},{"id":"p2","name":"Atlas"}]'; }
      TEAM_ID="c33944ff-9aee-408e-b98e-00dbaa98ae02"
      if ! planner_project_gate_check "$INITIATIVE_ID" "$TEAM_ID"; then
        exit 5
      fi
      ;;
    refinement)
      # SKILL.md step 1b, deterministic-only (no semantic agent spawns).
      PLANNER_REFINEMENT_SEMANTIC=false
      source "${CLAUDE_PLUGIN_ROOT}/lib/planner-refinement.sh"
      if planner_refinement_legacy "$INITIATIVE_ID"; then
        planner_state_write "$INITIATIVE_ID" "META" "refinement" "skip" "legacy — TicketGen|dispatch-gate|done already recorded"
        planner_state_write "$INITIATIVE_ID" "Refinement" "gate" "skip" "legacy initiative — Refinement not evaluated"
      else
        NEEDS_PASS=()
        while IFS= read -r _tid; do
          [ -n "$_tid" ] && NEEDS_PASS+=("$_tid")
        done < <(planner_refinement_scan "$INITIATIVE_ID")
        if planner_refinement_gate "$INITIATIVE_ID"; then
          :
        else
          echo "Refinement halted — one or more tickets are not ready."
          echo ""
          planner_refinement_report "$INITIATIVE_ID"
          echo ""
          echo "Artifacts:  ${STATE_DIR}/artifacts/"
          echo "Resume:     /ticket-planner resume ${INITIATIVE_ID}"
          exit 0
        fi
      fi
      ;;
    until)
      # SKILL.md step 6, after the --until phase completes.
      PHASE="Review"
      if planner_should_stop_after "$INITIATIVE_ID" "$PHASE"; then
        echo "Stopped after ${PHASE} — $(planner_stop_reason "$INITIATIVE_ID")"
        echo "Artifacts:  ${STATE_DIR}/artifacts/"
        echo "Specs:      ${STATE_DIR}/artifacts/specs/"
        echo "State log:  $(planner_state_log "$INITIATIVE_ID")"
        if planner_create_authorized "$INITIATIVE_ID"; then
          echo "Continue:   /ticket-planner resume ${INITIATIVE_ID}"
        else
          echo "To create:  /ticket-planner resume ${INITIATIVE_ID} --create"
        fi
        exit 0
      fi
      ;;
    esac
    # No halt fired — the fixture is wrong. Make that visible in the golden.
    echo "NO_HALT"
    exit 99
  ) >"${out_dir}/${name}.out.raw" 2>"${out_dir}/${name}.err.raw" && rc=0 || rc=$?

  local f
  for f in out err; do
    sed "s|${REPOS_ROOT}|<REPOS_ROOT>|g" "${out_dir}/${name}.${f}.raw" >"${out_dir}/${name}.${f}"
    rm -f "${out_dir}/${name}.${f}.raw"
  done
  echo "$rc" >"${out_dir}/${name}.rc"
}
