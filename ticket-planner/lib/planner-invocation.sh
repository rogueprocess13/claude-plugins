#!/usr/bin/env bash
# planner-invocation.sh — the ticket-planner's invocation flags
# (skill-deterministic-extraction 1; was inline bash in SKILL.md steps 2a/2b).
#
# planner_flags_parse <mode> [args...]
#   Parses the plan/resume flags into plain shell variables in the caller's
#   shell (never exported: #144 — the dispatch loop crosses a process boundary
#   between phases, so an export never reaches a later phase). Env vars are the
#   defaults for their flags, read once, here. Validates every combination and
#   --until before anything is persisted. rc 0 parsed, 1 rejected (message on
#   stderr). Unknown arguments (the initiative id, the idea) are ignored.
#
# planner_flags_persist <initiative_id>
#   Writes the parsed flags to the state log (step 2b): --answers first, then
#   the --create authorization, then every config key. Run it once the
#   initiative id exists and planner_state_init has run, before anything is
#   dispatched. rc 0, or the rc of a rejected --answers file / DRAFT_NOT_READY
#   accept.
#
# The loop reads positional parameters only in their braced form ("${1}"):
# this file is a script, so the skill loader's bare-$N substitution (#455)
# cannot reach it, but the habit is kept.
#
# Sourceable library — no set -euo pipefail. Needs planner-state.sh and
# planner-router.sh (SKILL.md step 1 sources both).

_PLANNER_INVOCATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_planner_invocation_source() {
  local name="$1" file="$2"
  declare -f "$name" >/dev/null 2>&1 && return 0
  # shellcheck source=/dev/null
  source "${_PLANNER_INVOCATION_LIB_DIR}/${file}"
}

# _planner_invocation_accept_instance <code> <arg> — run a per-instance
# code's parse function (PLANNER_CROSSCHECK_INSTANCE_CODES) on one --accept
# value: `<token>\t<record text>` on stdout, or rc 1 with the reason on stderr.
_planner_invocation_accept_instance() {
  local code="$1" arg="$2" fn
  planner_crosscheck_instance_load "$code" || return 1
  fn=$(planner_crosscheck_instance_field "$code" parse)
  if [ -z "$fn" ] || ! declare -f "$fn" >/dev/null 2>&1; then
    echo "ERROR: --accept ${code}: no accept parser is defined for this code" >&2
    return 1
  fi
  "$fn" "$arg"
}

planner_flags_parse() {
  local mode="${1:-}"
  shift || true

  SHARED_BRANCH_FLAG=""
  NO_SHARED_BRANCH_FLAG=""
  CREATE_FLAG=""
  UNTIL_PHASE=""
  TEAM_REF=""
  PROJECT_REF=""
  NO_PROJECT_FLAG=""
  MILESTONE_REF=""
  ACCEPT_FLAGS=()
  REFRESH_BODIES_FLAG=""
  CONVERGE_FLAG=""
  CONVERGE_ONLY=""
  CONVERGE_BY=""
  ANSWERS_FILE=""
  NO_TESTS_RULE_FLAG=""

  # Env vars are the defaults for the corresponding flags, read once, here.
  UNTIL_PHASE="${PLANNER_UNTIL:-}"
  if [ "${PLANNER_REVIEW_HOLD:-false}" = "true" ]; then UNTIL_PHASE="${UNTIL_PHASE:-Review}"; fi
  TEAM_REF="${LINEAR_TEAM_ID:-}"
  PROJECT_REF="${LINEAR_PROJECT:-}"
  MILESTONE_REF="${LINEAR_PROJECT_MILESTONE:-}"
  case "${PLANNER_NO_TESTS_RULE:-}" in true | false) NO_TESTS_RULE_FLAG="${PLANNER_NO_TESTS_RULE}" ;; esac
  UAT_POLICY_REF="${PLANNER_UAT_POLICY:-}"
  BASE_BRANCH_REF="${PLANNER_BASE_BRANCH:-}"

  while [ "$#" -gt 0 ]; do
    case "${1}" in
    --shared-branch) SHARED_BRANCH_FLAG=true ;;
    --no-shared-branch) NO_SHARED_BRANCH_FLAG=true ;;
    --create) CREATE_FLAG=true ;;
    --dry-run) ;; # redundant: stopping before the first Linear write is the default
    --until)
      shift
      UNTIL_PHASE="${1:-}"
      ;;
    --until=*) UNTIL_PHASE="${1#*=}" ;;
    --accept)
      shift
      ACCEPT_FLAGS+=("${1:-}")
      ;;
    --accept=*) ACCEPT_FLAGS+=("${1#*=}") ;;
    --team)
      shift
      TEAM_REF="${1:-}"
      ;;
    --team=*) TEAM_REF="${1#*=}" ;;
    --project)
      shift
      PROJECT_REF="${1:-}"
      ;;
    --project=*) PROJECT_REF="${1#*=}" ;;
    --no-project) NO_PROJECT_FLAG=true ;;
    --milestone)
      shift
      MILESTONE_REF="${1:-}"
      ;;
    --milestone=*) MILESTONE_REF="${1#*=}" ;;
    --refresh-bodies) REFRESH_BODIES_FLAG=true ;;
    --converge) CONVERGE_FLAG=true ;;
    --only)
      shift
      CONVERGE_ONLY="${1:-}"
      ;;
    --only=*) CONVERGE_ONLY="${1#*=}" ;;
    --by)
      shift
      CONVERGE_BY="${1:-}"
      ;;
    --by=*) CONVERGE_BY="${1#*=}" ;;
    --no-tests-rule) NO_TESTS_RULE_FLAG=true ;;
    --no-tests-rule=*) NO_TESTS_RULE_FLAG="${1#*=}" ;;
    --answers)
      shift
      ANSWERS_FILE="${1:-}"
      ;;
    --answers=*) ANSWERS_FILE="${1#*=}" ;;
    --base-branch)
      shift
      BASE_BRANCH_REF="${1:-}"
      ;;
    --base-branch=*) BASE_BRANCH_REF="${1#*=}" ;;
    esac
    shift || true
  done

  case "$NO_TESTS_RULE_FLAG" in
  "" | true | false) ;;
  *)
    echo "ERROR: --no-tests-rule takes true or false, got '${NO_TESTS_RULE_FLAG}'" >&2
    return 1
    ;;
  esac

  case "$UAT_POLICY_REF" in
  "" | per-ticket | epic) ;;
  *)
    echo "ERROR: PLANNER_UAT_POLICY takes per-ticket or epic, got '${UAT_POLICY_REF}'" >&2
    return 1
    ;;
  esac
  _planner_invocation_source planner_directive_config_check planner-crosscheck-repo-ref.sh || return 1
  planner_directive_config_check "$BASE_BRANCH_REF" || return 1

  # Reject both branch flags together
  if [ "$SHARED_BRANCH_FLAG" = "true" ] && [ "$NO_SHARED_BRANCH_FLAG" = "true" ]; then
    echo "ERROR: --shared-branch and --no-shared-branch are mutually exclusive" >&2
    return 1
  fi

  # Same for the project flags. --no-project is an opt-out, not an override: an
  # invocation that says both has not decided, and Epic Gen must not guess which
  # half was meant.
  if [ -n "$PROJECT_REF" ] && [ "$NO_PROJECT_FLAG" = "true" ]; then
    echo "ERROR: --project and --no-project are mutually exclusive" >&2
    return 1
  fi

  # --create is a deliberate, separate gesture made after reading the artifacts.
  # A single command that both plans and creates is the footgun this design removes.
  if [ "$CREATE_FLAG" = "true" ] && [ "$mode" = "plan" ]; then
    echo "ERROR: --create is not valid for 'plan'. Plan first, read the artifacts, then:" >&2
    echo "       /ticket-planner resume <INIT_ID> --create" >&2
    return 1
  fi

  # --accept, like --create, is only meaningful after Crosscheck has reported the
  # finding it accepts. Rejected in 'plan' for the same reason --create is (#222).
  if [ "${#ACCEPT_FLAGS[@]}" -gt 0 ] && [ "$mode" = "plan" ]; then
    echo "ERROR: --accept is not valid for 'plan'. Accept a finding only after Crosscheck reports it:" >&2
    echo "       /ticket-planner resume <INIT_ID> --accept CODE:\"reason\"" >&2
    return 1
  fi

  # --refresh-bodies, same restriction — it re-reads not-ready tickets Refinement
  # has already held, so it is meaningless before TicketGen has run (planner-
  # refinement-phase).
  if [ "$REFRESH_BODIES_FLAG" = "true" ] && [ "$mode" = "plan" ]; then
    echo "ERROR: --refresh-bodies is not valid for 'plan'. It re-evaluates tickets Refinement already held:" >&2
    echo "       /ticket-planner resume <INIT_ID> --refresh-bodies" >&2
    return 1
  fi

  # --converge --only <TIDs> [--by <name>] (planner-refinement-convergence D10):
  # a resume-only, one-shot operator action. --only is mandatory (there is no
  # epic-wide converge), and a bad combination is rejected here, before
  # anything is persisted.
  if [ "$CONVERGE_FLAG" = "true" ] && [ "$mode" = "plan" ]; then
    echo "ERROR: --converge is not valid for 'plan'. It releases tickets Refinement already held:" >&2
    echo "       /ticket-planner resume <INIT_ID> --converge --only <TID[,TID...]> [--by <name>]" >&2
    return 1
  fi
  _planner_invocation_source planner_refinement_converge_args_validate planner-refinement.sh || return 1
  planner_refinement_converge_args_validate "$CONVERGE_FLAG" "$CONVERGE_ONLY" "$CONVERGE_BY" || return 1
  if [ "$CONVERGE_FLAG" = "true" ] && [ -z "$CONVERGE_BY" ]; then CONVERGE_BY="${USER:-operator}"; fi

  # --answers answers the questions a stopped run is asking (planner-headless-
  # questions), so like --create it only means something on 'resume'.
  if [ -n "$ANSWERS_FILE" ] && [ "$mode" = "plan" ]; then
    echo "ERROR: --answers is not valid for 'plan'. Answer a stopped run's questions on resume:" >&2
    echo "       /ticket-planner resume <INIT_ID> --answers <file>" >&2
    return 1
  fi
  if [ -n "$ANSWERS_FILE" ] && [ ! -f "$ANSWERS_FILE" ]; then
    echo "ERROR: --answers file not found: ${ANSWERS_FILE}" >&2
    return 1
  fi

  # Validate every --accept CODE:"reason" pair up front — CODE must look like a
  # real Crosscheck code (upper-snake-case, same shape _planner_crosscheck_emit_finding
  # requires) and reason must be non-empty. Split on the first ':' only, so a reason
  # containing ':' (a URL, a doc anchor) is preserved intact.
  local _accept_arg _accept_code _accept_reason
  for _accept_arg in "${ACCEPT_FLAGS[@]}"; do
    [ -z "$_accept_arg" ] && continue
    # Per-instance codes (PLANNER_CROSSCHECK_INSTANCE_CODES, e.g. PARAM_LITERAL
    # per literal, planner-specify-parameters D7) go to the code's own parse
    # function, which also refuses the code-wide form, so a new instance
    # always blocks.
    _planner_invocation_source planner_crosscheck_instance_field planner-crosscheck.sh || return 1
    _accept_code="${_accept_arg%%:*}"
    _accept_code="${_accept_code%%@*}"
    if planner_crosscheck_is_instance_code "$_accept_code"; then
      _planner_invocation_accept_instance "$_accept_code" "$_accept_arg" >/dev/null || return 1
      continue
    fi
    case "$_accept_arg" in
    *:*)
      _accept_code="${_accept_arg%%:*}"
      _accept_reason="${_accept_arg#*:}"
      ;;
    *)
      echo "ERROR: --accept requires CODE:\"reason\" (got '${_accept_arg}')" >&2
      return 1
      ;;
    esac
    if [[ ! "$_accept_code" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      echo "ERROR: --accept code '${_accept_code}' is not a valid Crosscheck code (expected upper-snake-case, e.g. CARVE_SCOPE_LOST)" >&2
      return 1
    fi
    if [ -z "$_accept_reason" ]; then
      echo "ERROR: --accept requires a non-empty reason: CODE:\"reason\"" >&2
      return 1
    fi
  done

  # --until against the canonical sequence (prints the valid phases, or the
  # current position, itself). INITIATIVE_ID is the caller's, when known.
  if [ -n "$UNTIL_PHASE" ]; then
    planner_until_validate "$UNTIL_PHASE" "${INITIATIVE_ID:-}" || return 1
  fi
  return 0
}

planner_flags_persist() {
  local initiative_id="$1" rc

  # --answers first (planner-headless-questions): it is validated against the
  # round the run is stopped on *now*, before any other flag of this invocation
  # changes that stop. A rejected file (stale round, unknown id, wrong role)
  # stops here with nothing written; rc 0 covers both "applied" and "this
  # exact file was already applied".
  if [ -n "${ANSWERS_FILE:-}" ]; then
    _planner_invocation_source planner_answers_apply planner-answers.sh || return 1
    rc=0
    planner_answers_apply "$initiative_id" "$ANSWERS_FILE" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
  fi

  # Authorization first — it is the entry that must survive a crash.
  if [ "${CREATE_FLAG:-}" = "true" ]; then
    planner_authorize_create "$initiative_id" "operator passed --create"
    # --create with no new --until clears a stop point an earlier invocation set,
    # so `plan --until Crosscheck` does not keep stopping the authorized run.
    planner_stop_after_set "$initiative_id" "${UNTIL_PHASE:-}"
  elif [ -n "${UNTIL_PHASE:-}" ]; then
    planner_stop_after_set "$initiative_id" "$UNTIL_PHASE"
  fi

  if [ -n "${TEAM_REF:-}" ]; then planner_config_set "$initiative_id" "linear-team" "$TEAM_REF"; fi
  if [ -n "${PROJECT_REF:-}" ]; then planner_config_set "$initiative_id" "linear-project" "$PROJECT_REF"; fi
  if [ "${NO_PROJECT_FLAG:-}" = "true" ]; then planner_config_set "$initiative_id" "no-project" "true"; fi
  if [ -n "${MILESTONE_REF:-}" ]; then planner_config_set "$initiative_id" "linear-milestone" "$MILESTONE_REF"; fi

  if [ "${SHARED_BRANCH_FLAG:-}" = "true" ]; then
    planner_config_set "$initiative_id" "branch-override" "shared"
  elif [ "${NO_SHARED_BRANCH_FLAG:-}" = "true" ]; then
    planner_config_set "$initiative_id" "branch-override" "no-shared"
  fi

  # Branch Directive config (UAT, base, merge, sync): Epic Gen reads the keys back.
  if [ -n "${UAT_POLICY_REF:-}" ]; then planner_config_set "$initiative_id" "uat-policy" "$UAT_POLICY_REF"; fi
  _planner_invocation_source planner_directive_config_persist planner-crosscheck-repo-ref.sh || return 1
  planner_directive_config_persist "$initiative_id" "${BASE_BRANCH_REF:-}"

  # --refresh-bodies: one-shot, not sticky — step 1b clears it after Refinement uses it.
  if [ "${REFRESH_BODIES_FLAG:-}" = "true" ]; then planner_config_set "$initiative_id" "refresh-bodies" "true"; fi

  # --converge (planner-refinement-convergence D10): one-shot too, stored as
  # "<TID,TID...> <operator>" and consumed (then cleared) by step 1b.
  if [ "${CONVERGE_FLAG:-}" = "true" ]; then
    planner_config_set "$initiative_id" "converge" "${CONVERGE_ONLY:-} ${CONVERGE_BY:-}"
  fi

  # No-tests rule (#503): the flag wins, else detected once from REPOS_ROOT CLAUDE.md files.
  _planner_invocation_source planner_testdata_no_tests_rule_persist planner-crosscheck-testdata.sh || return 1
  planner_testdata_no_tests_rule_persist "$initiative_id" "${NO_TESTS_RULE_FLAG:-}"

  # --accept CODE:"reason" (#222): recorded via planner_crosscheck_accept_set, not
  # planner_config_set — a set of accepted codes, not a single last-write-wins value.
  local _accept_arg
  if [ "${#ACCEPT_FLAGS[@]}" -gt 0 ]; then
    _planner_invocation_source planner_crosscheck_accept_set planner-crosscheck.sh || return 1
    for _accept_arg in "${ACCEPT_FLAGS[@]}"; do
      [ -z "$_accept_arg" ] && continue
      local _code="${_accept_arg%%:*}" _pl
      _code="${_code%%@*}"
      if planner_crosscheck_is_instance_code "$_code"; then
        # Recorded as `<token> <record text>` from the code's parse function
        # (PARAM_LITERAL: PARAM_LITERAL@<slug>=<canonical> <literal>): the
        # instance token Crosscheck matches each finding against.
        _pl=$(_planner_invocation_accept_instance "$_code" "$_accept_arg") || return 1
        planner_crosscheck_accept_set "$initiative_id" "${_pl%%$'\t'*}" "${_pl#*$'\t'}"
        continue
      fi
      if [ "${_accept_arg%%:*}" = "DRAFT_NOT_READY" ]; then
        # Own branch: bound to the drafts' hashes now, never a Crosscheck accept.
        _planner_invocation_source planner_draft_readiness_accept planner-draft-readiness-gate.sh || return 1
        planner_draft_readiness_accept "$initiative_id" "${_accept_arg#*:}" || return 1
        continue
      fi
      planner_crosscheck_accept_set "$initiative_id" "${_accept_arg%%:*}" "${_accept_arg#*:}"
    done
  fi
  return 0
}
