#!/usr/bin/env bash
# planner-refinement.sh — the Refinement phase (planner-refinement-phase).
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling) and does NOT set the global SCRIPT_DIR (see
# _planner_refinement_source_deps below).
#
# Refinement sits between TicketGen and Completed. Like Crosscheck, it has no
# phase prompt and is driven by the planner skill's dispatch loop as bash
# (SKILL.md step 1b), not by an Agent spawn. It runs the deterministic DoR
# check (ticket-auto-pipeline's dor-check.sh) and, unless
# PLANNER_REFINEMENT_SEMANTIC=false, two dor-semantic-agent spawns (scan then
# audit) per ticket that needs a pass, against each ticket's local body.md.
#
# See openspec/changes/planner-refinement-phase/design.md for the full
# decision record (D1-D11) this file implements.
#
# Public API:
#   planner_epic_id <INIT>
#     Prints the epic's Linear ID from the last EpicGen ...EPIC_ID=... state
#     log line. Exit 1, nothing printed, when absent.
#
#   planner_refinement_legacy <INIT>
#     Exit 0 when the state log carries the pre-change
#     TicketGen|dispatch-gate|done line (initiative planned before this
#     change shipped).
#
#   planner_refinement_scan <INIT>
#     Runs the deterministic check for every child of the epic, caching each
#     verdict on the ticket manifest and writing planner/dor-result.json.
#     Prints one ticket id per line for every ticket that needs a semantic
#     pass (design.md Decision 6's staleness rule). Exit 1 when the epic id
#     cannot be resolved.
#
#   planner_refinement_prompt <INIT> <TID> scan|audit
#     Prints the dor-semantic-agent prompt for one ticket/stage.
#
#   planner_refinement_apply <INIT> <TID>
#     Parses both result files via dor-semantic-parse.sh and applies them via
#     dor_semantic_apply. Non-zero when either result is invalid.
#
#   planner_refinement_unavailable <INIT> <TID>
#     Records SEMANTIC_UNAVAILABLE for a ticket whose two evaluator attempts
#     both failed.
#
#   planner_refinement_gate <INIT>
#     Stamps the epic manifest dispatch=true once every child has a verdict
#     (design.md Decision 2), and writes the phase's terminal log line: exit
#     0 + Refinement|gate|done when every child is ready, exit 1 +
#     META|refinement-gate|fail otherwise (no retry-budget consumption —
#     design.md Decision 7).
#
#   planner_refinement_report <INIT>
#     Prints the halt report: per not-ready ticket, its deterministic codes,
#     semantic findings, missed/disputed codes with the exact waive command,
#     and the --refresh-bodies note (design.md Decision 8).
#
#   planner_refinement_refresh_bodies <INIT>
#     Overwrites body.md of every not-ready child from Linear (read-only).

_PLANNER_REFINEMENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Version-aware plugin-cache lookup (planner_cache_find) — issue #454.
# shellcheck source=planner-plugin-cache.sh
source "${_PLANNER_REFINEMENT_LIB_DIR}/planner-plugin-cache.sh"

# ── Dependency resolution ────────────────────────────────────────────────
#
# Three-level fallback, same pattern as planner-ticket-validate.sh /
# branch-directive-gen.sh: plugin cache -> ~/.claude/skills/lib -> sibling
# ticket-auto-pipeline/lib checkout. No bundled copy — the dependency on
# ticket-auto-pipeline's dor-check.sh/dor-semantic.sh/manifest-write.sh is
# deliberate, to avoid schema drift (design.md's Dependencies section).
_planner_refinement_resolve() {
  local name="$1" found

  found=$(planner_cache_find ticket-auto-pipeline "lib/${name}")
  if [ -n "$found" ] && [ -f "$found" ]; then
    echo "$found"
    return 0
  fi

  found="${HOME}/.claude/skills/lib/${name}"
  if [ -f "$found" ]; then
    echo "$found"
    return 0
  fi

  found="${_PLANNER_REFINEMENT_LIB_DIR}/../../ticket-auto-pipeline/lib/${name}"
  if [ -f "$found" ]; then
    echo "$found"
    return 0
  fi

  echo ""
  return 1
}

# Sources dor-check.sh, dor-semantic.sh and manifest-write.sh (which sources
# manifest-read.sh itself). Declare-guarded — a caller that already loaded
# these pays nothing for a second parse.
#
# dor-check.sh's own declare-guard chain first-sources
# planned-ticket-body-check.sh, which unconditionally sets the GLOBAL
# SCRIPT_DIR, which in turn (declare-guarded) sources planner-artifacts.sh
# (also sets SCRIPT_DIR) and planned-ticket-check.sh (its own private var,
# harmless). None of that is this file's business — the caller's own
# SCRIPT_DIR (if any) is saved before sourcing and restored after (design.md
# Decision 5 / spec "Sourcing ticket-auto-pipeline libraries does not leak
# state").
_planner_refinement_source_deps() {
  if declare -f check_ticket_ready >/dev/null 2>&1 &&
    declare -f dor_semantic_prompt >/dev/null 2>&1 &&
    declare -f set_ticket_readiness >/dev/null 2>&1; then
    return 0
  fi

  local dor_check dor_semantic manifest_write
  dor_check=$(_planner_refinement_resolve "dor-check.sh") || {
    echo "planner-refinement: dor-check.sh not found (install ticket-auto-pipeline)" >&2
    return 1
  }
  dor_semantic=$(_planner_refinement_resolve "dor-semantic.sh") || {
    echo "planner-refinement: dor-semantic.sh not found (install ticket-auto-pipeline)" >&2
    return 1
  }
  manifest_write=$(_planner_refinement_resolve "manifest-write.sh") || {
    echo "planner-refinement: manifest-write.sh not found (install ticket-auto-pipeline)" >&2
    return 1
  }

  local _had_script_dir=0 _saved_script_dir=""
  if [ "${SCRIPT_DIR+set}" = "set" ]; then
    _had_script_dir=1
    _saved_script_dir="$SCRIPT_DIR"
  fi

  # shellcheck source=/dev/null
  source "$manifest_write"
  # shellcheck source=/dev/null
  source "$dor_check"
  # shellcheck source=/dev/null
  source "$dor_semantic"

  if [ "$_had_script_dir" -eq 1 ]; then
    SCRIPT_DIR="$_saved_script_dir"
  else
    unset SCRIPT_DIR
  fi

  if ! declare -f check_ticket_ready >/dev/null 2>&1; then
    echo "planner-refinement: ${dor_check} sourced but did not define check_ticket_ready" >&2
    return 1
  fi
  if ! declare -f dor_semantic_prompt >/dev/null 2>&1; then
    echo "planner-refinement: ${dor_semantic} sourced but did not define dor_semantic_prompt" >&2
    return 1
  fi
  return 0
}

# ── Epic resolution (design.md Decision 4) ───────────────────────────────

# planner_epic_id <INIT>
# TicketGen's own EPIC_ID lookup, extracted so both it and Refinement share
# one implementation.
planner_epic_id() {
  local initiative_id="$1"
  local log_file
  log_file=$(planner_state_log "$initiative_id" 2>/dev/null) || return 1
  [ -f "$log_file" ] || return 1

  local epic_id
  epic_id=$(grep '|EpicGen|.*|done|EPIC_ID=' "$log_file" 2>/dev/null | tail -1 | sed 's/.*EPIC_ID=//')
  [ -n "$epic_id" ] || return 1
  echo "$epic_id"
}

# ── Legacy pass-through (design.md Decision 10) ──────────────────────────

# planner_refinement_legacy <INIT>
# Exit 0 when the log already carries the pre-change TicketGen terminal line
# — that initiative has no body.md and its epic may already be dispatching.
planner_refinement_legacy() {
  local initiative_id="$1"
  local log_file
  log_file=$(planner_state_log "$initiative_id" 2>/dev/null) || return 1
  [ -f "$log_file" ] || return 1
  grep -q '|TicketGen|dispatch-gate|done|' "$log_file" 2>/dev/null
}

# ── Deterministic scan (design.md Decision 5) ────────────────────────────

# planner_refinement_scan <INIT>
# Runs the deterministic check against every child's local body.md, caching
# the verdict and printing the tickets that need a semantic pass.
planner_refinement_scan() {
  local initiative_id="$1"
  _planner_refinement_source_deps || return 1

  local epic_id
  epic_id=$(planner_epic_id "$initiative_id") || return 1

  local children
  children=$(get_epic_manifest_field "$epic_id" children 2>/dev/null)
  [ -n "$children" ] || children='[]'

  local repos_root="${REPOS_ROOT:-}"
  local -a needs_pass=()
  local tid

  for tid in $(echo "$children" | jq -r '.[]' 2>/dev/null); do
    local type
    type=$(get_ticket_manifest_field "$tid" type 2>/dev/null)
    [ -n "$type" ] || type="feature"

    local pdir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/tickets/${tid}/planner"
    local body_file="${pdir}/body.md"
    mkdir -p "$pdir" 2>/dev/null

    if [ ! -s "$body_file" ]; then
      local desc=""
      if declare -f planner_linear_get_issue >/dev/null 2>&1; then
        desc=$(planner_linear_get_issue "$tid" 2>/dev/null | jq -r '.data.issue.description // ""' 2>/dev/null)
      fi
      if [ -n "$desc" ]; then
        printf '%s' "$desc" >"$body_file"
      else
        set_ticket_readiness "$tid" "not-ready" '["BODY_UNAVAILABLE"]' '[]' >/dev/null 2>&1
        planner_state_write "$initiative_id" "META" "refinement" "fail" "${tid}: no local body.md and could not fetch description from Linear"
        continue
      fi
    fi

    local check_rc=0
    check_ticket_ready "$tid" --body "$body_file" --type "$type" --no-fetch >/dev/null 2>&1 || check_rc=$?
    local hash="${DOR_BODY_HASH:-}"

    case "${DOR_STATUS:-unavailable}" in
    ready | not-ready)
      local extras
      extras=$(jq -nc --argjson score "${DOR_SCORE:-null}" --argjson dims "${DOR_DIMENSIONS:-null}" \
        --argjson gaps "${DOR_GAPS:-null}" --arg hash "$hash" \
        '{score: $score, dimensions: $dims, gaps: $gaps} + (if $hash != "" then {body_hash: $hash} else {} end)' 2>/dev/null)
      set_ticket_readiness "$tid" "$DOR_STATUS" "${DOR_MISSING:-[]}" "${DOR_ADVISORY:-[]}" "$extras" >/dev/null 2>&1
      jq -nc --argjson missing "${DOR_MISSING:-[]}" --argjson advisory "${DOR_ADVISORY:-[]}" \
        --arg status "$DOR_STATUS" \
        '{missing: $missing, advisory: $advisory, status: $status}' >"${pdir}/dor-result.json" 2>/dev/null
      ;;
    *)
      set_ticket_readiness "$tid" "not-ready" '["BODY_UNAVAILABLE"]' '[]' >/dev/null 2>&1
      planner_state_write "$initiative_id" "META" "refinement" "fail" "${tid}: readiness check unavailable"
      continue
      ;;
    esac

    local ready_after needs="false" sem_hash sem_eval
    ready_after=$(get_ticket_manifest_field "$tid" ready 2>/dev/null)
    if ! echo "$ready_after" | jq -e '.semantic' >/dev/null 2>&1; then
      needs="true"
    else
      sem_hash=$(echo "$ready_after" | jq -r '.semantic.body_hash // ""' 2>/dev/null)
      sem_eval=$(echo "$ready_after" | jq -r '.semantic.evaluator // ""' 2>/dev/null)
      [ "$sem_hash" = "$hash" ] || needs="true"
      [ "$sem_eval" = "${DOR_SEMANTIC_EVALUATOR:-}" ] || needs="true"
    fi
    if echo "$ready_after" | jq -e '(.missing // []) | index("SEMANTIC_STALE") != null' >/dev/null 2>&1; then
      needs="true"
    fi

    [ "$needs" = "true" ] && needs_pass+=("$tid")
  done

  local t
  for t in "${needs_pass[@]}"; do echo "$t"; done
}

# ── Semantic pass (design.md Decision 6) ─────────────────────────────────

# planner_refinement_prompt <INIT> <TID> scan|audit
planner_refinement_prompt() {
  local initiative_id="$1" tid="$2" kind="$3"
  _planner_refinement_source_deps || return 1

  local pdir="${REPOS_ROOT:-}/.ticket-auto/initiatives/${initiative_id}/tickets/${tid}/planner"
  local body_file="${pdir}/body.md"

  if [ "$kind" = "scan" ]; then
    dor_semantic_prompt scan "$tid" "$body_file" "${pdir}/semantic-scan-result.txt"
  else
    dor_semantic_prompt audit "$tid" "$body_file" "${pdir}/semantic-audit-result.txt" "${pdir}/dor-result.json"
  fi
}

# planner_refinement_apply <INIT> <TID>
# Parses both result files and applies them via dor_semantic_apply. Returns
# non-zero when either result fails to parse — the caller (SKILL.md step 1b)
# re-spawns once, then calls planner_refinement_unavailable on a second
# failure.
planner_refinement_apply() {
  local initiative_id="$1" tid="$2"
  _planner_refinement_source_deps || return 1

  local parse_script
  parse_script=$(_planner_refinement_resolve "dor-semantic-parse.sh") || {
    echo "planner-refinement: dor-semantic-parse.sh not found (install ticket-auto-pipeline)" >&2
    return 1
  }

  local pdir="${REPOS_ROOT:-}/.ticket-auto/initiatives/${initiative_id}/tickets/${tid}/planner"
  local body_file="${pdir}/body.md"
  local scan_file="${pdir}/semantic-scan-result.txt"
  local audit_file="${pdir}/semantic-audit-result.txt"
  local det_file="${pdir}/dor-result.json"

  local scan_json audit_json scan_rc=0 audit_rc=0
  scan_json=$(bash "$parse_script" --kind scan --result-file "$scan_file" 2>/dev/null) || scan_rc=$?
  audit_json=$(bash "$parse_script" --kind audit --result-file "$audit_file" --det-result "$det_file" 2>/dev/null) || audit_rc=$?

  if [ "$scan_rc" -ne 0 ] || [ "$audit_rc" -ne 0 ]; then
    return 1
  fi

  dor_semantic_apply "$tid" "$body_file" "$scan_json" "$audit_json"
}

# planner_refinement_unavailable <INIT> <TID>
planner_refinement_unavailable() {
  local initiative_id="$1" tid="$2"
  _planner_refinement_source_deps || return 1

  local sem_json
  sem_json=$(jq -nc --arg evaluator "${DOR_SEMANTIC_EVALUATOR:-dor-semantic-v1}" \
    --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{evaluator: $evaluator, checked_at: $checked_at, unavailable: true,
      findings: [], gaps: {}, audit: [], missed: []}')
  set_ticket_semantic "$tid" "$sem_json"
}

# ── Gate + halt report (design.md Decisions 2, 7, 8) ─────────────────────

# planner_refinement_gate <INIT>
# Stamps the epic once every child has a verdict; writes the phase terminal
# line. Exit 0 (Refinement|gate|done) only when every child is also ready.
planner_refinement_gate() {
  local initiative_id="$1"
  _planner_refinement_source_deps || return 1

  local epic_id
  if ! epic_id=$(planner_epic_id "$initiative_id"); then
    planner_state_write "$initiative_id" "META" "refinement-gate" "fail" "no EpicGen EPIC_ID found in state log"
    return 1
  fi

  local children
  children=$(get_epic_manifest_field "$epic_id" children 2>/dev/null)
  [ -n "$children" ] || children='[]'

  local semantic_enabled="${PLANNER_REFINEMENT_SEMANTIC:-true}"
  local total=0 not_ready=0 no_verdict=0 tid ready_json status has_semantic

  for tid in $(echo "$children" | jq -r '.[]' 2>/dev/null); do
    total=$((total + 1))
    ready_json=$(get_ticket_manifest_field "$tid" ready 2>/dev/null)
    if [ -z "$ready_json" ] || [ "$ready_json" = "null" ]; then
      no_verdict=$((no_verdict + 1))
      not_ready=$((not_ready + 1))
      continue
    fi

    status=$(echo "$ready_json" | jq -r '.status // "unavailable"' 2>/dev/null)
    [ "$status" = "ready" ] || not_ready=$((not_ready + 1))

    if [ "$semantic_enabled" != "false" ]; then
      has_semantic=$(echo "$ready_json" | jq -r 'if has("semantic") and (.semantic != null) then "true" else "false" end' 2>/dev/null)
      [ "$has_semantic" = "true" ] || no_verdict=$((no_verdict + 1))
    fi
  done

  if [ "$total" -gt 0 ] && [ "$no_verdict" -eq 0 ]; then
    stamp_epic_dispatch "$epic_id"
  fi

  if [ "$not_ready" -eq 0 ] && [ "$no_verdict" -eq 0 ]; then
    planner_state_write "$initiative_id" "Refinement" "gate" "done" "${total} tickets ready, epic ${epic_id} stamped dispatch=true"
    return 0
  fi

  planner_state_write "$initiative_id" "META" "refinement-gate" "fail" "${not_ready} of ${total} not ready"
  return 1
}

# planner_refinement_report <INIT>
# The halt report — printed verbatim by the dispatch loop, like Crosscheck's
# findings report.
planner_refinement_report() {
  local initiative_id="$1"
  _planner_refinement_source_deps || return 1

  local epic_id
  if ! epic_id=$(planner_epic_id "$initiative_id"); then
    echo "ERROR: no EpicGen EPIC_ID found in state log for ${initiative_id} — Refinement cannot resolve children."
    return 0
  fi

  local children
  children=$(get_epic_manifest_field "$epic_id" children 2>/dev/null)
  [ -n "$children" ] || children='[]'

  local tid any_not_ready=0

  for tid in $(echo "$children" | jq -r '.[]' 2>/dev/null); do
    local ready_json status
    ready_json=$(get_ticket_manifest_field "$tid" ready 2>/dev/null)
    status=$(echo "$ready_json" | jq -r '.status // "unavailable"' 2>/dev/null)
    [ "$status" = "ready" ] && continue
    any_not_ready=1

    echo ""
    echo "## ${tid}"

    local waived_keys missing
    waived_keys=$(echo "$ready_json" | jq -r '.waived // {} | keys | join(" ")' 2>/dev/null)
    missing=$(echo "$ready_json" | jq -r '.missing // [] | .[]' 2>/dev/null)

    local -a hard_codes=()
    local code
    while IFS= read -r code; do
      [ -z "$code" ] && continue
      case " $waived_keys " in *" $code "*) continue ;; esac
      case "$code" in
      SEMANTIC_UNAVAILABLE | SEMANTIC_UNVERIFIED | SEMANTIC_STALE) ;;
      SEMANTIC_*) ;;
      *) hard_codes+=("$code") ;;
      esac
    done <<<"$missing"

    if [ "${#hard_codes[@]}" -gt 0 ]; then
      echo "Deterministic codes: ${hard_codes[*]}"
    fi

    local findings_json n i
    findings_json=$(echo "$ready_json" | jq -c '.semantic.findings // []' 2>/dev/null)
    n=$(echo "$findings_json" | jq 'length' 2>/dev/null) || n=0
    for ((i = 0; i < n; i++)); do
      local fcode fquote fdetail fsev
      fcode=$(echo "$findings_json" | jq -r ".[$i].code")
      fquote=$(echo "$findings_json" | jq -r ".[$i].quote")
      fdetail=$(echo "$findings_json" | jq -r ".[$i].detail // \"\"")
      fsev=$(echo "$findings_json" | jq -r ".[$i].severity")
      if [ -n "$fdetail" ]; then
        echo "Semantic finding [${fsev}] ${fcode}: \"${fquote}\" — ${fdetail}"
      else
        echo "Semantic finding [${fsev}] ${fcode}: \"${fquote}\""
      fi
    done

    local missed_json
    missed_json=$(echo "$ready_json" | jq -c '.semantic.missed // []' 2>/dev/null)
    n=$(echo "$missed_json" | jq 'length' 2>/dev/null) || n=0
    for ((i = 0; i < n; i++)); do
      local mcode mreason
      mcode=$(echo "$missed_json" | jq -r ".[$i].code")
      mreason=$(echo "$missed_json" | jq -r ".[$i].reason")
      echo "Evaluator believes missed: ${mcode} — ${mreason}"
    done

    local audit_json
    audit_json=$(echo "$ready_json" | jq -c '.semantic.audit // []' 2>/dev/null)
    n=$(echo "$audit_json" | jq 'length' 2>/dev/null) || n=0
    for ((i = 0; i < n; i++)); do
      local acode averdict areason
      acode=$(echo "$audit_json" | jq -r ".[$i].code")
      averdict=$(echo "$audit_json" | jq -r ".[$i].verdict")
      [ "$averdict" = "disputed" ] || continue
      areason=$(echo "$audit_json" | jq -r ".[$i].reason // \"\"")
      echo "Disputed: ${acode} — ${areason}"
      echo "  Release: dor-check.sh --waive ${tid} ${acode} \"${areason}\""
    done

    case " $missing " in
    *" SEMANTIC_UNAVAILABLE "*)
      echo "The semantic evaluator did not return a usable result after two attempts — resume retries it."
      ;;
    esac
    case " $missing " in
    *" SEMANTIC_UNVERIFIED "*)
      echo "One or more semantic findings' quoted evidence did not verify against the body — resume retries it."
      ;;
    esac
  done

  if [ "$any_not_ready" -eq 1 ]; then
    echo ""
    echo "An edit made in Linear is only evaluated after /ticket-planner resume ${initiative_id} --refresh-bodies."
  fi
}

# ── Refresh (design.md Decision 9) ────────────────────────────────────────

# planner_refinement_refresh_bodies <INIT>
# Overwrites body.md of every not-ready child from its current Linear
# description. Read-only — never writes to Linear.
planner_refinement_refresh_bodies() {
  local initiative_id="$1"
  _planner_refinement_source_deps || return 1

  local epic_id
  epic_id=$(planner_epic_id "$initiative_id") || return 1

  local children
  children=$(get_epic_manifest_field "$epic_id" children 2>/dev/null)
  [ -n "$children" ] || children='[]'

  local repos_root="${REPOS_ROOT:-}"
  local tid

  for tid in $(echo "$children" | jq -r '.[]' 2>/dev/null); do
    local status
    status=$(get_ticket_manifest_field "$tid" ready 2>/dev/null | jq -r '.status // "unavailable"' 2>/dev/null)
    [ "$status" = "ready" ] && continue

    if ! declare -f planner_linear_get_issue >/dev/null 2>&1; then
      continue
    fi

    local desc
    desc=$(planner_linear_get_issue "$tid" 2>/dev/null | jq -r '.data.issue.description // ""' 2>/dev/null)
    [ -n "$desc" ] || continue

    local pdir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/tickets/${tid}/planner"
    mkdir -p "$pdir" 2>/dev/null
    printf '%s' "$desc" >"${pdir}/body.md"
  done
}
