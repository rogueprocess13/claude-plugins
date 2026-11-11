#!/usr/bin/env bash
# halt-fixtures.sh — fixture initiatives for every planner halt, plus a run of
# each halt (planner-headless-questions task 1.1). The halts themselves live in
# planner_dispatch_gate (planner-router.sh) and planner_refinement_prepare/
# planner_refinement_finish (planner-refinement.sh), called here exactly as SKILL.md calls them
# (skill-deterministic-extraction 1 — they were copied SKILL.md blocks before).
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
# The goldens were captured from the SKILL.md blocks themselves, before the
# extraction; they are never regenerated from the functions.

_HALT_FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HALT_LIB_DIR="${_HALT_FIXTURES_DIR}/.."

# Every halt the stop describer must recognise, with the reason it must name.
HALT_FIXTURE_REASONS="create-gate-stop:CREATE_GATE create-gate-dispatch:CREATE_GATE crosscheck:CROSSCHECK_BLOCKED crosscheck-testdata:CROSSCHECK_BLOCKED adr-gate:ADR_GATE project-gate:PROJECT_GATE refinement:REFINEMENT_HALT refinement-body-drift:REFINEMENT_HALT refinement-demoted:REFINEMENT_HALT until:UNTIL_STOP specify-decision:SPECIFY_DECISION consensus-blocked:CONSENSUS_BLOCKED specify-param:SPECIFY_DECISION specify-param-crosscheck:SPECIFY_DECISION"

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
  specify-param | specify-param-crosscheck)
    # planner-specify-parameters: a contract initiative (the marker Specify
    # start writes) with one open outcome and open parameter rows — at Review
    # (the first stop), or after Consensus (the second stop, before
    # Crosscheck). Added after the other goldens; they predate it.
    planner_state_write "$init" META contract start specify-parameters-v1
    _halt_done "$init" Appraisal Discovery Architecture Specify
    [ "$name" = specify-param-crosscheck ] && _halt_done "$init" Review Consensus
    _halt_param_proposal "$init"
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

# A proposal with one open outcome, a must-ask row with no source, a tuning
# row the keyword table promotes, and a closed tuning row; one spec names a key.
_halt_param_proposal() {
  local art
  art="$(planner_initiative_dir "$1")/artifacts"
  mkdir -p "${art}/specs"
  cat >"${art}/proposal.md" <<'PROPOSAL'
# Proposal

## Business Outcomes

### O1
**Outcome:** NEEDS_HUMAN_DECISION — which role signs off the exported invoices?

## Parameters

| Name | Key | Kind | Default | Value | Source |
|------|-----|------|---------|-------|--------|
| Invoice rounding | `billing.total_rounding` | rounding | half-up, 2 decimal places | NEEDS_HUMAN_DECISION — round each line, or only the invoice total? | — |
| Idle session timeout | `auth.session_idle_minutes` | duration | 30 minutes | 30 minutes | default |
| Payment retry delay | `payments.retry_delay` | duration | 5 minutes | 5 minutes | default |

## Out of Scope

None.
PROPOSAL
  printf '# Invoice total\n\n## Technical Context\n\nRounds per `billing.total_rounding`.\n' >"${art}/specs/invoice-total.md"
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
# Runs the halt (its SKILL.md call) in a subshell and writes out_dir/<name>.out,
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
      planner_dispatch_gate stop "$INITIATIVE_ID" Crosscheck "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
      ;;
    create-gate-dispatch)
      # SKILL.md step 1, a plain `resume` reaching EpicGen.
      planner_dispatch_gate pre "$INITIATIVE_ID" EpicGen "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
      ;;
    crosscheck | crosscheck-testdata)
      # SKILL.md step 1a. planner_crosscheck_run is stubbed after sourcing:
      # the check families need real artifacts and a repo, and the halt's
      # output depends only on what the run recorded. The gate sources the
      # lib only when the function is missing, so the stub stands.
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
      planner_dispatch_gate crosscheck "$INITIATIVE_ID" Crosscheck "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
      ;;
    adr-gate)
      # SKILL.md step 4a.
      planner_dispatch_gate adr "$INITIATIVE_ID" Architecture "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
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
        planner_refinement_finish "$INITIATIVE_ID" "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
      fi
      ;;
    until)
      # SKILL.md step 6, after the --until phase completes.
      planner_dispatch_gate stop "$INITIATIVE_ID" Review "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
      ;;
    specify-decision)
      # SKILL.md step 1 (pre gate, see 1c), when the loop is about to dispatch Review.
      planner_dispatch_gate pre "$INITIATIVE_ID" Review "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
      ;;
    specify-param)
      planner_dispatch_gate pre "$INITIATIVE_ID" Review "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
      ;;
    specify-param-crosscheck)
      planner_dispatch_gate pre "$INITIATIVE_ID" Crosscheck "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
      ;;
    consensus-blocked)
      # SKILL.md step 1 (pre gate), when the loop is about to run Crosscheck.
      planner_dispatch_gate pre "$INITIATIVE_ID" Crosscheck "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
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
