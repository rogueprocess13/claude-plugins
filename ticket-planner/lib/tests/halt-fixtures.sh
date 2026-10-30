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
HALT_FIXTURE_REASONS="create-gate-stop:CREATE_GATE create-gate-dispatch:CREATE_GATE crosscheck:CROSSCHECK_BLOCKED crosscheck-testdata:CROSSCHECK_BLOCKED adr-gate:ADR_GATE project-gate:PROJECT_GATE refinement:REFINEMENT_HALT refinement-body-drift:REFINEMENT_HALT refinement-demoted:REFINEMENT_HALT until:UNTIL_STOP specify-decision:SPECIFY_DECISION consensus-blocked:CONSENSUS_BLOCKED"

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
  crosscheck-testdata)
    # planner-test-data-derivation: two specs whose every Verification Notes
    # row says Test data none while a criterion implies data. Added after the
    # describer's testdata questions; the other goldens predate it.
    _halt_done "$init" Appraisal Discovery Architecture Specify Review Consensus
    _halt_testdata_artifacts "$init"
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
  refinement | refinement-body-drift | refinement-demoted)
    _halt_done "$init" Appraisal Discovery Architecture Specify Review Consensus Crosscheck
    planner_authorize_create "$init" "operator passed --create"
    planner_stop_after_set "$init" ""
    planner_state_write "$init" "EpicGen" "create" "start" "fixture"
    planner_state_write "$init" "EpicGen" "create" "done" "EPIC_ID=PRO-100"
    planner_state_write "$init" "TicketGen" "verify" "start" "fixture"
    planner_state_write "$init" "TicketGen" "verify" "done" "2 tickets verified."
    _halt_refinement_manifests "$init"
    # planner-refinement-convergence D6/D5 halts, added after the other
    # goldens; they predate them.
    [ "$name" = refinement-body-drift ] && _halt_refinement_body_drift "$init"
    [ "$name" = refinement-demoted ] && _halt_refinement_demoted "$init"
    ;;
  until)
    _halt_done "$init" Appraisal Discovery Architecture Specify Review
    planner_stop_after_set "$init" "Review"
    ;;
  specify-decision)
    # planner-specify-waiting-on-human: Specify done with one open business
    # decision (O1) beside a sourced outcome (O2). Added after the other
    # goldens; they predate it.
    _halt_done "$init" Appraisal Discovery Architecture Specify
    cat >"$(planner_initiative_dir "$init")/artifacts/proposal.md" <<'PROPOSAL'
# Proposal

## Business Outcomes

### O1
**Who:** Not specified
**Need:** Not specified
**Outcome:** NEEDS_HUMAN_DECISION — which role signs off the exported invoices?

### O2
**Who:** Finance user
**Need:** Export invoices for the month-end close
**Outcome:** Finance users export invoices without asking support.

## Out of Scope

None.
PROPOSAL
    ;;
  consensus-blocked)
    # DET-PL-11: Consensus finished but marked the plan Readiness: blocked.
    # Added after the other goldens; they predate it.
    _halt_done "$init" Appraisal Discovery Architecture Specify Review Consensus
    cat >"$(planner_initiative_dir "$init")/artifacts/consensus.md" <<'CONSENSUS'
# Consensus

## Findings Addressed
- R1 (blocker): export bypasses tenant scoping — rejected, no safe design found yet.

## Readiness
blocked — R1 needs a tenant-scoping decision from the data owner before specs can be cut.
CONSENSUS
    ;;
  *)
    echo "halt-fixtures: unknown fixture '${name}'" >&2
    return 1
    ;;
  esac
}

# _halt_testdata_spec <slug> <criterion> — a spec with one all-`none` row.
_halt_testdata_spec() {
  cat <<SPEC
# $1

## Description

Fixture spec for the implied-test-data question.

## Acceptance Criteria

- [ ] $2

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| $2 | finance user | none | — | as stated | yes |
SPEC
}

# Discovery inventory, an empty consensus.md and two implying specs.
_halt_testdata_artifacts() {
  local art
  art="$(planner_initiative_dir "$1")/artifacts"
  mkdir -p "${art}/specs"
  cat >"${art}/discovery.md" <<'DISCOVERY'
# Discovery

## Cited Artifacts

None.

## Test Data Inventory

| Entity | States/variants | Roles | Volume | Source | Load via | Privacy |
|--------|-----------------|-------|--------|--------|----------|---------|
| invoice | draft, overdue | finance user | 5 | generate | sql | synthetic |
| audit entry | any | admin | 3 | generate | sql | synthetic |
DISCOVERY
  printf '# Consensus\n\n## Open Questions\n\nNone.\n' >"${art}/consensus.md"
  _halt_testdata_spec audit-log "The audit page lists 3 audit entries" >"${art}/specs/audit-log.md"
  _halt_testdata_spec invoice-list "The list shows 5 overdue invoices" >"${art}/specs/invoice-list.md"
}

# One ready child, one not-ready child (missing intent only). Refinement
# scans with DOR_STRICT_TEST_DATA/DOR_STRICT_VPLAN on (planner-test-data-
# derivation 6.5), so both bodies are dor fixture 22 (sourced test data and a
# Verification Plan, as TicketGen writes them); PRO-102 has its why/outcome
# sections (Background / Motivation, Proposed Behaviour) cut out.
_halt_refinement_manifests() {
  local init="$1" dor_fixtures pair tid fixture pdir
  dor_fixtures="${_HALT_LIB_DIR}/../../ticket-auto-pipeline/lib/tests/fixtures/dor"
  source "${_HALT_LIB_DIR}/planner-refinement.sh"
  _planner_refinement_source_deps || return 1
  write_epic_manifest "PRO-100" "" "per-ticket" "" '[]' >/dev/null
  for pair in "PRO-101:ready" "PRO-102:no-intent"; do
    tid="${pair%%:*}"
    fixture="${pair#*:}"
    write_ticket_manifest "$tid" "$init" "feature" '[]' >/dev/null
    add_epic_manifest_child "PRO-100" "$tid" >/dev/null
    pdir="${REPOS_ROOT}/.ticket-auto/initiatives/${init}/tickets/${tid}/planner"
    mkdir -p "$pdir"
    if [ "$fixture" = ready ]; then
      cp "${dor_fixtures}/22-sourced-contract.md" "${pdir}/body.md"
    else
      awk '/^## /{skip=($0=="## Background / Motivation" || $0=="## Proposed Behaviour")} !skip' \
        "${dor_fixtures}/22-sourced-contract.md" >"${pdir}/body.md"
    fi
  done
}

# Body drift (planner-refinement-convergence D6): PRO-101's Linear text and
# body.md both changed since the baseline (a conflict); PRO-102 is clean
# against Linear and still misses its intent. halt_fixture_run stubs
# planner_linear_get_issue over ${REPOS_ROOT}/linear/<TID>.md.
_halt_refinement_body_drift() {
  local init="$1" tid pdir
  _planner_refinement_source_baseline || return 1
  mkdir -p "${REPOS_ROOT}/linear"
  for tid in PRO-101 PRO-102; do
    pdir="${REPOS_ROOT}/.ticket-auto/initiatives/${init}/tickets/${tid}/planner"
    cp "${pdir}/body.md" "${REPOS_ROOT}/linear/${tid}.md"
    body_baseline_write "$pdir" "$(cat "${pdir}/body.md")"
  done
  pdir="${REPOS_ROOT}/.ticket-auto/initiatives/${init}/tickets/PRO-101/planner"
  sed -i 's/^Validate bulk client uploads before import\.$/Validate bulk client uploads before any import./' "${REPOS_ROOT}/linear/PRO-101.md"
  sed -i 's/^Validate bulk client uploads before import\.$/Validate client uploads before import./' "${pdir}/body.md"
}

# An audit-demoted code (planner-refinement-convergence D5): PRO-102 also
# lacks its Navigation Path, and the audit's dispute of NAV_PATH_MISSING was
# demoted for this body hash, so only INTENT_MISSING still blocks.
_halt_refinement_demoted() {
  local init="$1" pdir hash
  pdir="${REPOS_ROOT}/.ticket-auto/initiatives/${init}/tickets/PRO-102/planner"
  awk '/^## /{skip=($0=="## Navigation Path")} !skip' "${pdir}/body.md" >"${pdir}/body.md.tmp" &&
    mv "${pdir}/body.md.tmp" "${pdir}/body.md"
  planner_refinement_scan "$init" >/dev/null
  hash=$(get_ticket_manifest_field "PRO-102" ready | jq -r '.body_hash')
  set_ticket_demotions "PRO-102" "$(jq -nc --arg h "$hash" '{NAV_PATH_MISSING: {by: "dor-semantic-audit",
    reason: "the Scope table names the upload page", quote: "Clients > Upload", body_hash: $h,
    evaluator: "dor-semantic-v3"}}')" >/dev/null
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
    crosscheck | crosscheck-testdata)
      # SKILL.md step 1a. planner_crosscheck_run is stubbed after sourcing:
      # the check families need real artifacts and a repo, and the halt's
      # output depends only on what the run recorded.
      source "${CLAUDE_PLUGIN_ROOT}/lib/planner-crosscheck.sh"
      if [ "$name" = "crosscheck-testdata" ]; then
        planner_crosscheck_run() {
          # Only the test-data tripwires run for real — over the fixture specs.
          local init="$1" line
          planner_state_write "$init" "Crosscheck" "check" "start" "running citation + propagation + bypass + contracts + signals + deps checks"
          while IFS= read -r line; do
            [ -n "$line" ] && _planner_crosscheck_emit_finding "$init" "$line"
          done < <(planner_crosscheck_testdata_tripwires "$init")
          planner_state_write "$init" "Crosscheck" "check" "fail" "2 blocking finding(s), 0 warn, 0 accepted — see META|crosscheck entries"
          return 1
        }
      else
        planner_crosscheck_run() {
          local init="$1"
          planner_state_write "$init" "Crosscheck" "check" "start" "running citation + propagation + bypass + contracts + signals + deps checks"
          _planner_crosscheck_emit_finding "$init" "planner-crosscheck-propagation: CARVE_SCOPE_LOST ticket count changed 4 -> 3 after Specify; audit scope by hand"
          _planner_crosscheck_emit_finding "$init" "planner-crosscheck-citations: CITATION_UNRESOLVED specs/export-csv.md: src/billing/export.py:42 does not resolve"
          _planner_crosscheck_emit_finding "$init" "planner-crosscheck-contracts: CONTRACT_UNDEFINED specs/export-csv.md: ExportRow gains fields with no names"
          planner_state_write "$init" "Crosscheck" "check" "fail" "2 blocking finding(s), 1 warn, 0 accepted — see META|crosscheck entries"
          return 1
        }
      fi
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
    refinement | refinement-body-drift | refinement-demoted)
      # SKILL.md step 1b, deterministic-only (no semantic agent spawns).
      PLANNER_REFINEMENT_SEMANTIC=false
      source "${CLAUDE_PLUGIN_ROOT}/lib/planner-refinement.sh"
      if [ "$name" = refinement-body-drift ]; then
        # Stands in for planner-linear-api.sh's reader (SKILL.md sources it).
        planner_linear_get_issue() {
          [ -f "${REPOS_ROOT}/linear/${1}.md" ] || return 1
          jq -nc --rawfile d "${REPOS_ROOT}/linear/${1}.md" '{data: {issue: {description: $d}}}'
        }
      fi
      _rf_rc=0
      planner_refinement_prepare "$INITIATIVE_ID" || _rf_rc=$?
      if [ "$_rf_rc" -ne 2 ]; then
        # Step 1e: the pass list is empty (semantic off), so NEXT is done at once.
        [ "$(planner_refinement_next "$INITIATIVE_ID")" = "done 0" ] || exit 1
        if planner_refinement_gate "$INITIATIVE_ID"; then
          planner_refinement_advisory_summary "$INITIATIVE_ID"
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
    specify-decision)
      # SKILL.md step 1c, when the loop is about to dispatch Review.
      PHASE="Review"
      source "${CLAUDE_PLUGIN_ROOT}/lib/planner-specify-decisions.sh"
      if [ "$PHASE" = "Review" ]; then
        _sd_rc=0
        planner_specify_gate "$INITIATIVE_ID" || _sd_rc=$?
        case "$_sd_rc" in
        0) ;;
        3)
          planner_specify_halt_report "$INITIATIVE_ID" "$STATE_DIR"
          exit 0
          ;;
        *)
          echo "ERROR: Specify decision gate could not read proposal.md" >&2
          exit 1
          ;;
        esac
      fi
      ;;
    consensus-blocked)
      # SKILL.md step 1a0, when the loop is about to run Crosscheck.
      PHASE="Crosscheck"
      source "${CLAUDE_PLUGIN_ROOT}/lib/planner-consensus-gate.sh"
      if [ "$PHASE" = "Crosscheck" ]; then
        _cg_rc=0
        planner_consensus_gate "$INITIATIVE_ID" || _cg_rc=$?
        if [ "$_cg_rc" -eq 3 ]; then
          planner_consensus_halt_report "$INITIATIVE_ID" "$STATE_DIR"
          exit 0
        fi
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
