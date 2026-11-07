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
#   planner_refinement_scan <INIT> [--only <TID[,TID...]>]
#     Runs the deterministic check for every child of the epic (strict:
#     DOR_STRICT_TEST_DATA=true DOR_STRICT_VPLAN=true, scoped to the call),
#     caching each
#     verdict on the ticket manifest and writing planner/dor-result.json.
#     Unless PLANNER_REFINEMENT_DRIFT_CHECK=false, first reads each child's
#     Linear description and classifies it against the baseline
#     (body-baseline.sh): adopt rewrites body.md, rebaseline writes the
#     baseline, conflict/local-ahead add BODY_DRIFT and
#     PLANNER_REFINEMENT_DRIFT_MAX_FAILS (default 3) consecutive failed reads
#     add BODY_UNVERIFIED — both to the cached missing only, never to
#     dor-result.json. Migrates an unchanged dor-semantic-v2 verdict in place
#     (dor_semantic_migrate_v2) before deciding. Prints one ticket id per
#     line for every ticket that needs a semantic pass (design.md Decision
#     6's staleness rule). --only restricts it to the named children
#     (Refinement after Completed). Exit 1 when the epic id cannot be
#     resolved.
#
#   planner_refinement_prompt <INIT> <TID> scan|audit
#     Prints the dor-semantic-agent prompt for one ticket/stage. A scan of a
#     stale verdict that recorded its changed sections passes them as
#     --changed-sections (planner-refinement-convergence D4).
#
#   planner_refinement_apply <INIT> <TID>
#     Parses both result files via dor-semantic-parse.sh and applies them via
#     dor_semantic_apply, with DOR_SEMANTIC_MAX_ROUNDS
#     (${PLANNER_REFINEMENT_MAX_ROUNDS:-2}), DOR_SEMANTIC_DRIFT_DEMOTE=true and
#     DOR_SEMANTIC_ROUND_RESET_SHARE as call prefixes. Non-zero when either
#     result is invalid. After a successful apply it writes, each once per
#     ticket per body hash: the META|refinement-round|done trend line, a
#     META|refinement|warn|policy override line when the stored policy was
#     overridden, one META|refinement-testdata|warn line per verified
#     advisory TEST_DATA_GAP finding and, only when
#     PLANNER_REFINEMENT_AUDIT_DEMOTE=true, the META|refinement-dispute lines
#     of dor_audit_demote. None of those writes changes the exit code.
#
#   planner_refinement_unavailable <INIT> <TID>
#     Records SEMANTIC_UNAVAILABLE for a ticket whose two evaluator attempts
#     both failed. ready.lineage (the round history) is left untouched.
#
#   planner_refinement_converge <INIT> <TID[,TID...]> [<by>]
#     Operator converge (design D10). Spawns nothing. For each named child
#     with a current, non-stale semantic verdict, makes every blocking
#     non-structural finding advisory (demoted "converge", converged_by
#     <by>) and logs META|refinement-converge|done|<TID> demoted=<n> by=<by>.
#     A child with no, a stale or an outdated verdict is refused, left
#     unchanged and named on stdout. Exit 0; 1 when the epic is unresolved.
#
#   planner_refinement_converge_args_validate <converge-flag> <only> <by>
#     SKILL.md step 2a: --converge needs --only; --only/--by need --converge;
#     --only must be a comma-separated ticket-id list. Exit 1 with a message.
#
#   planner_semantic_demote <semantic-json> <demoted> <by> [<ids>] [<demote-reason>]
#     The demotion rewrite converge uses, shared with the draft readiness
#     gate's end-of-loop convergence (round-limit + demote_reason).
#
#   planner_refinement_converge_consume <INIT>
#     Runs the persisted one-shot `converge` config key, then clears it.
#     Nothing when the key is unset.
#
#   planner_refinement_after_completed_pending <INIT>
#     Exit 0 when the initiative is finished (planner_position_derive empty),
#     not legacy, and refresh-bodies or converge is set — Refinement re-runs for the
#     affected children only (design D6/D10).
#
#   planner_refinement_after_completed_finish <INIT>
#     Writes the META|refinement-after-completed|done line that closes such
#     a run (never a phase line, so the position is unchanged).
#
#   planner_refinement_gate <INIT>
#     Stamps the epic manifest dispatch=true once every child has a verdict
#     (design.md Decision 2), and writes the phase's terminal log line: exit
#     0 + Refinement|gate|done when every child is ready, exit 1 +
#     META|refinement-gate|fail otherwise (no retry-budget consumption —
#     design.md Decision 7).
#
#   planner_refinement_report <INIT>
#     Prints the halt report: per not-ready ticket, its round, deterministic
#     codes, semantic findings (blocking new / carried, structural drift,
#     unverified, advisory), a "Demoted (does not block)" list with each
#     reason (round-limit, drift, converge, audit dispute), missed/disputed
#     codes with the exact waive command, and the --refresh-bodies note
#     (design.md Decision 8), then an "## Advisory test-data findings"
#     section when any child carries one and a "## Demoted findings on ready
#     tickets" section when a ready child carries a demotion.
#
#   planner_refinement_advisory_summary <INIT>
#     Prints one "Advisory (does not block) <TID> TEST_DATA_GAP: ..." line per
#     verified advisory TEST_DATA_GAP finding on any child, ready or not
#     (dor-semantic-test-data-gap), then one "Advisory (does not block) <TID>
#     <CODE> (demoted: <reason>)..." line per demotion on a ready child;
#     nothing when there are none.
#
#   planner_refinement_refresh_bodies <INIT>
#     Takes Linear's text (body.md + baseline) for every child whose
#     body-drift class is not clean, ready and waived ones included; waivers
#     are kept. Read-only towards Linear. Prints each child the next scan
#     must re-evaluate, one per line.
#
#   planner_ticketgen_record_baseline <INIT> <TID> create|skip
#     TicketGen's body baseline (design D6): after a create, reads the
#     description back once and writes the baseline; on an idempotent skip,
#     writes it only when none exists and Linear's text equals body.md.
#     Always exit 0 — a failed read-back never fails TicketGen.

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
  epic_id=$(grep -E '^[^|]*\|EpicGen\|[^|]*\|done\|EPIC_ID=[^|]*$' "$log_file" 2>/dev/null | tail -1 | sed 's/^[^|]*|[^|]*|[^|]*|[^|]*|EPIC_ID=//')
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
  grep -qE '^[^|]*\|TicketGen\|dispatch-gate\|done\|' "$log_file" 2>/dev/null
}

# ── Body drift (planner-refinement-convergence D6) ───────────────────────
#
# Per-ticket files beside body.md in planner/:
#   linear-baseline.sha  body-baseline.sh's baseline (Linear's own text)
#   linear-read-fails    consecutive failed Linear reads (absent = 0)
#   body-drift           the class (conflict | local-ahead) behind a
#                        BODY_DRIFT — read by the halt report; kept across a
#                        failed read so the code is not dropped blind

# Sources ticket-auto-pipeline's body-baseline.sh through the same
# three-level resolver as the other deps — the one hash and classifier, no
# copy here. Exit 1 (with a reason on stderr) when it cannot be found.
_planner_refinement_source_baseline() {
  declare -f body_baseline_classify >/dev/null 2>&1 && return 0
  local f
  f=$(_planner_refinement_resolve "body-baseline.sh") || {
    echo "planner-refinement: body-baseline.sh not found (install ticket-auto-pipeline) — body drift not checked" >&2
    return 1
  }
  # shellcheck source=/dev/null
  source "$f"
  declare -f body_baseline_classify >/dev/null 2>&1
}

# _planner_refinement_linear_desc <TID>
# Prints the ticket's Linear description. Exit 1 on any failed read: no
# reader, a transport/GraphQL failure, no issue, or an empty description
# (a planned ticket's description is never legitimately empty).
_planner_refinement_linear_desc() {
  declare -f planner_linear_get_issue >/dev/null 2>&1 || return 1
  local resp
  resp=$(planner_linear_get_issue "$1" 2>/dev/null) || return 1
  echo "$resp" | jq -e '(.data.issue.description // "") | type == "string" and length > 0' >/dev/null 2>&1 || return 1
  echo "$resp" | jq -r '.data.issue.description'
}

# _planner_refinement_max_fails — PLANNER_REFINEMENT_DRIFT_MAX_FAILS, a
# positive integer, default 3.
_planner_refinement_max_fails() {
  local n="${PLANNER_REFINEMENT_DRIFT_MAX_FAILS:-3}"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=3
  echo "$n"
}

# _planner_refinement_drift_classify <INIT> <TID> <pdir> <read_rc> <desc>
# Acts on one child's Linear read and prints the BODY_* codes to add to the
# cached `missing`, as a JSON array:
#   read failed    counter + 1; BODY_UNVERIFIED at the limit; a recorded
#                  BODY_DRIFT (body-drift marker) is kept
#   adopt          body.md and baseline ← Linear, META|refinement|step line
#   rebaseline     baseline only
#   conflict,
#   local-ahead    BODY_DRIFT (marker written)
#   clean          nothing
# Any successful read resets the counter.
_planner_refinement_drift_classify() {
  local initiative_id="$1" tid="$2" pdir="$3" read_rc="$4" desc="$5"
  local fails_file="${pdir}/linear-read-fails" marker="${pdir}/body-drift"
  local -a codes=()

  if [ "$read_rc" -ne 0 ]; then
    local n max
    n=$(cat "$fails_file" 2>/dev/null) || n=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    n=$((n + 1))
    max=$(_planner_refinement_max_fails)
    printf '%s\n' "$n" >"$fails_file" 2>/dev/null
    if [ "$n" -ge "$max" ]; then
      codes+=("BODY_UNVERIFIED")
      planner_state_write "$initiative_id" "META" "refinement" "warn" "${tid}: Linear read failed (${n}/${max}) — BODY_UNVERIFIED"
    else
      planner_state_write "$initiative_id" "META" "refinement" "warn" "${tid}: Linear read failed (${n}/${max}) — body drift not checked"
    fi
    [ -f "$marker" ] && codes+=("BODY_DRIFT")
  else
    rm -f "$fails_file" 2>/dev/null
    local cls="" rc=0
    cls=$(body_baseline_classify "$pdir" "$desc") || rc=$?
    case "$cls" in
    adopt)
      local old8 new8
      old8=$(body_baseline_read "$pdir" 2>/dev/null | cut -c1-8)
      new8=$(body_baseline_hash "$desc" 2>/dev/null | cut -c1-8)
      printf '%s' "$desc" >"${pdir}/body.md"
      body_baseline_write "$pdir" "$desc" 2>/dev/null
      rm -f "$marker" 2>/dev/null
      planner_state_write "$initiative_id" "META" "refinement" "step" "${tid} body adopted from Linear [${old8}→${new8}]"
      ;;
    rebaseline)
      body_baseline_write "$pdir" "$desc" 2>/dev/null
      rm -f "$marker" 2>/dev/null
      ;;
    conflict | local-ahead)
      printf '%s\n' "$cls" >"$marker" 2>/dev/null
      codes+=("BODY_DRIFT")
      ;;
    clean)
      rm -f "$marker" 2>/dev/null
      ;;
    *)
      # No body.md (rc 2) or no hash tool (rc 1): nothing to compare.
      [ "$rc" -ne 0 ] && [ -f "$marker" ] && codes+=("BODY_DRIFT")
      ;;
    esac
  fi

  if [ "${#codes[@]}" -eq 0 ]; then
    echo '[]'
  else
    printf '%s\n' "${codes[@]}" | jq -R . | jq -sc 'unique'
  fi
}

# ── Deterministic scan (design.md Decision 5) ────────────────────────────

# planner_refinement_scan <INIT>
# Runs the deterministic check against every child's local body.md, caching
# the verdict and printing the tickets that need a semantic pass.
planner_refinement_scan() {
  local initiative_id="$1" only=""
  if [ "${2:-}" = "--only" ]; then
    only="${3:-}"
  fi
  _planner_refinement_source_deps || return 1

  local epic_id
  epic_id=$(planner_epic_id "$initiative_id") || return 1

  local children
  children=$(get_epic_manifest_field "$epic_id" children 2>/dev/null)
  [ -n "$children" ] || children='[]'

  local repos_root="${REPOS_ROOT:-}"
  local -a needs_pass=()
  local tid

  # Draft carry-over lib, sourced in this shell (functions defined in a
  # command substitution would not survive it).
  if [ -d "${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts/draft-readiness" ] &&
    ! declare -f planner_draft_carryover_ticket >/dev/null 2>&1; then
    # shellcheck source=planner-draft-carryover.sh
    source "${_PLANNER_REFINEMENT_LIB_DIR}/planner-draft-carryover.sh"
  fi
  local draft_map
  draft_map=$(_planner_refinement_draft_map "$initiative_id")

  for tid in $(echo "$children" | jq -r '.[]' 2>/dev/null); do
    if [ -n "$only" ]; then
      case ",${only}," in *",${tid},"*) ;; *) continue ;; esac
    fi
    local type
    type=$(get_ticket_manifest_field "$tid" type 2>/dev/null)
    [ -n "$type" ] || type="feature"

    local pdir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/tickets/${tid}/planner"
    local body_file="${pdir}/body.md"
    mkdir -p "$pdir" 2>/dev/null

    # Body drift (planner-refinement-convergence D6): one Linear read per
    # child per run, unless switched off or no reader/baseline lib exists.
    local drift_on="false" desc="" desc_rc=1
    if [ "${PLANNER_REFINEMENT_DRIFT_CHECK:-true}" != "false" ] &&
      declare -f planner_linear_get_issue >/dev/null 2>&1 &&
      _planner_refinement_source_baseline; then
      drift_on="true"
      desc=$(_planner_refinement_linear_desc "$tid") && desc_rc=0 || desc_rc=1
    fi

    if [ ! -s "$body_file" ]; then
      if [ "$drift_on" != "true" ] && declare -f planner_linear_get_issue >/dev/null 2>&1; then
        desc=$(planner_linear_get_issue "$tid" 2>/dev/null | jq -r '.data.issue.description // ""' 2>/dev/null)
        [ -n "$desc" ] && desc_rc=0
      fi
      if [ "$desc_rc" -eq 0 ] && [ -n "$desc" ]; then
        printf '%s' "$desc" >"$body_file"
      else
        [ "$drift_on" = "true" ] && _planner_refinement_drift_classify "$initiative_id" "$tid" "$pdir" "1" "" >/dev/null
        set_ticket_readiness "$tid" "not-ready" '["BODY_UNAVAILABLE"]' '[]' >/dev/null 2>&1
        planner_state_write "$initiative_id" "META" "refinement" "fail" "${tid}: no local body.md and could not fetch description from Linear"
        continue
      fi
    fi

    local body_codes='[]'
    if [ "$drift_on" = "true" ]; then
      body_codes=$(_planner_refinement_drift_classify "$initiative_id" "$tid" "$pdir" "$desc_rc" "$desc")
      [ -n "$body_codes" ] || body_codes='[]'
    fi

    # Refinement scans strictly (planner-test-data-derivation, design
    # Decision 11): the test-data and Verification Plan codes are hard here,
    # so a planned ticket the planner itself produced halts on them instead
    # of reaching ticket-auto with an advisory. The prefix scopes both flags
    # to this one call — bash restores the caller's values (or unsets them)
    # when the function returns, so nothing leaks into the planner's env.
    local check_rc=0
    DOR_STRICT_TEST_DATA=true DOR_STRICT_VPLAN=true \
      check_ticket_ready "$tid" --body "$body_file" --type "$type" --no-fetch >/dev/null 2>&1 || check_rc=$?
    local hash="${DOR_BODY_HASH:-}"

    case "${DOR_STATUS:-unavailable}" in
    ready | not-ready)
      # check_profile records the strict prefix above, so a dispatch-time
      # recompute (ensure_ticket_readiness) re-applies it instead of the
      # host's defaults; the section/unit hashes drive section-scoped
      # staleness (planner-refinement-convergence D4/D9).
      # dor-result.json is the deterministic check's own output, written
      # before the BODY_* codes are appended: the audit never judges them
      # (design D6).
      jq -nc --argjson missing "${DOR_MISSING:-[]}" --argjson advisory "${DOR_ADVISORY:-[]}" \
        --arg status "$DOR_STATUS" \
        '{missing: $missing, advisory: $advisory, status: $status}' >"${pdir}/dor-result.json" 2>/dev/null
      local cached_missing cached_status="$DOR_STATUS"
      cached_missing=$(jq -nc --argjson m "${DOR_MISSING:-[]}" --argjson b "$body_codes" '$m + $b | unique' 2>/dev/null) ||
        cached_missing="${DOR_MISSING:-[]}"
      [ "$body_codes" = "[]" ] || cached_status="not-ready"
      local extras legacy_extras write_rc=0
      extras=$(jq -nc --argjson score "${DOR_SCORE:-null}" --argjson dims "${DOR_DIMENSIONS:-null}" \
        --argjson gaps "${DOR_GAPS:-null}" --arg hash "$hash" \
        --argjson sec "${DOR_SECTION_HASHES:-null}" --argjson units "${DOR_UNIT_HASHES:-null}" \
        '{score: $score, dimensions: $dims, gaps: $gaps, check_profile: "planner-strict"}
         + (if $hash != "" then {body_hash: $hash} else {} end)
         + (if $sec != null then {section_hashes: $sec} else {} end)
         + (if $units != null then {unit_hashes: $units} else {} end)' 2>/dev/null)
      set_ticket_readiness "$tid" "$cached_status" "$cached_missing" "${DOR_ADVISORY:-[]}" "$extras" >/dev/null 2>&1 || write_rc=$?
      if [ "$write_rc" -eq 3 ]; then
        # An older resolved manifest-write.sh rejects the new extras keys —
        # fall back to the four it knows rather than leave no verdict.
        legacy_extras=$(echo "$extras" | jq -c '{score, dimensions, gaps} + (if has("body_hash") then {body_hash} else {} end)' 2>/dev/null)
        set_ticket_readiness "$tid" "$cached_status" "$cached_missing" "${DOR_ADVISORY:-[]}" "$legacy_extras" >/dev/null 2>&1
      fi
      ;;
    *)
      set_ticket_readiness "$tid" "not-ready" '["BODY_UNAVAILABLE"]' '[]' >/dev/null 2>&1
      planner_state_write "$initiative_id" "META" "refinement" "fail" "${tid}: readiness check unavailable"
      continue
      ;;
    esac

    # An unchanged dor-semantic-v2 verdict is migrated in place (design D8)
    # rather than listed — the evaluator comparison below would otherwise
    # send every v2 ticket of the epic back to the agent. rc 2 (nothing to
    # migrate) is the common case.
    if declare -f dor_semantic_migrate_v2 >/dev/null 2>&1; then
      dor_semantic_migrate_v2 "$tid" "$body_file" >/dev/null 2>&1 || true
    fi

    # Draft readiness carry-over (planner-draft-readiness D13): a ticket with
    # no semantic verdict imports its spec's draft verdict, or is seeded for a
    # draft-passed scan. planner-draft-carryover.sh.
    local ready_after needs="false" sem_hash sem_eval
    ready_after=$(get_ticket_manifest_field "$tid" ready 2>/dev/null)
    if ! echo "$ready_after" | jq -e '.semantic' >/dev/null 2>&1; then
      _planner_refinement_draft_carry "$initiative_id" "$tid" "$pdir" "$draft_map" >/dev/null
      ready_after=$(get_ticket_manifest_field "$tid" ready 2>/dev/null)
    fi
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

    if [ "$needs" = "true" ]; then
      needs_pass+=("$tid")
    fi
  done

  [ -n "$draft_map" ] && rm -f "$draft_map"
  local t
  for t in "${needs_pass[@]}"; do echo "$t"; done
}

# _planner_refinement_draft_map <INIT>
# Writes the draft→real token map to a temp file and prints its path, or
# nothing when carry-over is off or the initiative has no draft directory
# (the gate never ran: old path).
_planner_refinement_draft_map() {
  local init="$1" f
  [ "${PLANNER_DRAFT_VERDICT_IMPORT:-true}" != "false" ] || return 0
  [ "${PLANNER_REFINEMENT_SEMANTIC:-true}" != "false" ] || return 0
  [ -d "${REPOS_ROOT:-}/.ticket-auto/initiatives/${init}/artifacts/draft-readiness" ] || return 0
  declare -f planner_draft_carryover_ticket >/dev/null 2>&1 || return 0
  f=$(mktemp "${TMPDIR:-/tmp}/planner-draft-map.XXXXXX") || return 0
  planner_draft_readiness_token_map "$init" >"$f" 2>/dev/null || {
    rm -f "$f"
    return 0
  }
  echo "$f"
}

# _planner_refinement_draft_carry <INIT> <TID> <pdir> <map-file|"">
# Prints import | draft-passed | none. With no map, clears a stale
# draft-passed marker and takes the old path.
_planner_refinement_draft_carry() {
  local init="$1" tid="$2" pdir="$3" map="$4"
  if [ -z "$map" ] || ! declare -f planner_draft_carryover_ticket >/dev/null 2>&1; then
    rm -f "${pdir}/draft-passed" 2>/dev/null
    echo none
    return 0
  fi
  planner_draft_carryover_ticket "$init" "$tid" "$pdir" "$map"
}

# ── Semantic pass (design.md Decision 6) ─────────────────────────────────

# planner_refinement_prompt <INIT> <TID> scan|audit
planner_refinement_prompt() {
  local initiative_id="$1" tid="$2" kind="$3"
  _planner_refinement_source_deps || return 1

  local pdir="${REPOS_ROOT:-}/.ticket-auto/initiatives/${initiative_id}/tickets/${tid}/planner"
  local body_file="${pdir}/body.md"

  if [ "$kind" = "scan" ]; then
    # A stale verdict that recorded which sections changed gets a scoped
    # rescan (planner-refinement-convergence D4).
    local changed=""
    changed=$(get_ticket_manifest_field "$tid" ready 2>/dev/null |
      jq -r '(.semantic.changed_sections // []) | join("|")' 2>/dev/null) || changed=""
    if [ -n "$changed" ]; then
      dor_semantic_prompt scan --changed-sections "$changed" "$tid" "$body_file" "${pdir}/semantic-scan-result.txt"
    else
      dor_semantic_prompt scan "$tid" "$body_file" "${pdir}/semantic-scan-result.txt"
    fi
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

  # Convergence policy (planner-refinement-convergence D1/D3), scoped to
  # this one call: bash restores the caller's values (or unsets them) when
  # dor_semantic_apply returns, so nothing leaks into the planner's env.
  # A ticket seeded by the draft carry-over (planner/draft-passed, D13) is
  # judged once with the draft-passed policy: no reset, non-structural
  # findings and new structural ones on unchanged units advisory.
  local apply_rc=0 prior_passed="false"
  if [ -f "${pdir}/draft-passed" ] && [ "${PLANNER_DRAFT_VERDICT_IMPORT:-true}" != "false" ]; then
    prior_passed="true"
  fi
  DOR_SEMANTIC_MAX_ROUNDS="${PLANNER_REFINEMENT_MAX_ROUNDS:-2}" \
    DOR_SEMANTIC_DRIFT_DEMOTE=true \
    DOR_SEMANTIC_ROUND_RESET_SHARE="${DOR_SEMANTIC_ROUND_RESET_SHARE:-0.5}" \
    DOR_SEMANTIC_PRIOR_PASSED="$prior_passed" \
    dor_semantic_apply "$tid" "$body_file" "$scan_json" "$audit_json" || apply_rc=$?
  if [ "$apply_rc" -eq 0 ]; then
    rm -f "${pdir}/draft-passed" 2>/dev/null
    if [ "${PLANNER_REFINEMENT_AUDIT_DEMOTE:-false}" = "true" ]; then
      _planner_refinement_audit_demote "$initiative_id" "$tid" "$body_file" || true
    fi
    _planner_refinement_note_round "$initiative_id" "$tid" || true
    _planner_refinement_note_testdata "$initiative_id" "$tid" || true
  fi
  return "$apply_rc"
}

# _planner_refinement_hash8 <TID> — first 8 hex of ready.lineage.body_hash
# (falling back to ready.semantic.body_hash). Empty when neither exists.
_planner_refinement_hash8() {
  local h
  h=$(get_ticket_manifest_field "$1" ready 2>/dev/null |
    jq -r '.lineage.body_hash // .semantic.body_hash // ""' 2>/dev/null) || h=""
  h="${h#sha256:}"
  echo "${h:0:8}"
}

# _planner_refinement_logged <INIT> <log-prefix> <TID> <hash8> [<needle>]
# Exit 0 when the state log already holds a line starting with
# <log-prefix> (e.g. "|META|refinement-round|done|") for <TID> and
# [<hash8>] (and containing <needle>, when given) — the dedupe every
# once-per-ticket-per-body line uses.
_planner_refinement_logged() {
  local initiative_id="$1" prefix="$2" tid="$3" hash8="$4" needle="${5:-}"
  local log_file
  log_file=$(planner_state_log "$initiative_id" 2>/dev/null) || return 1
  [ -f "$log_file" ] || return 1
  grep -F "$prefix" "$log_file" 2>/dev/null |
    grep -F "${prefix}${tid} " 2>/dev/null |
    grep -F "${needle}" 2>/dev/null |
    grep -qF "[${hash8}]" 2>/dev/null
}

# _planner_refinement_note_round <INIT> <TID>
# Writes, once per ticket per body hash (design D3):
#   META|refinement-round|done|<TID> round=<n> new=<a> carried=<b> drift=<c> resolved=<d> unverified=<u> reset=<0|1> [<hash8>]
# from ready.lineage, plus a META|refinement|warn|policy override line when
# the stored policy snapshot records an overridden structural or
# audit-demotable list (D2/D5). Never fails the caller.
_planner_refinement_note_round() {
  local initiative_id="$1" tid="$2"
  local ready_json
  ready_json=$(get_ticket_manifest_field "$tid" ready 2>/dev/null) || ready_json=""
  echo "$ready_json" | jq -e '.lineage.round != null' >/dev/null 2>&1 || return 0

  local hash8 trend
  hash8=$(_planner_refinement_hash8 "$tid")
  trend=$(echo "$ready_json" | jq -r '.lineage
    | "round=\(.round) new=\(.counts.new // 0) carried=\(.counts.carried // 0) drift=\(.counts.drift // 0) resolved=\(.counts.resolved // 0) unverified=\(.counts.unverified // 0) reset=\(if .reset == true or .reset == 1 then 1 else 0 end)"' 2>/dev/null) || trend=""
  if [ -n "$trend" ] &&
    ! _planner_refinement_logged "$initiative_id" "|META|refinement-round|done|" "$tid" "$hash8"; then
    planner_state_write "$initiative_id" "META" "refinement-round" "done" "${tid} ${trend} [${hash8}]" 2>/dev/null || true
  fi

  local override
  override=$(echo "$ready_json" | jq -r '.lineage.policy // {}
    | [ (if .overridden == true then "structural=" + ((.structural // []) | join(",")) else empty end),
        (if .audit_demotable_overridden == true then "audit_demotable=" + ((.audit_demotable // []) | join(",")) else empty end) ]
    | join(" ")' 2>/dev/null) || override=""
  if [ -n "$override" ] &&
    ! _planner_refinement_logged "$initiative_id" "|META|refinement|warn|policy override " "$tid" "$hash8"; then
    # The prefix check above needs "<prefix><TID> " — keep the TID first.
    planner_state_write "$initiative_id" "META" "refinement" "warn" \
      "policy override ${tid} ${override} [${hash8}]" 2>/dev/null || true
  fi
  return 0
}

# _planner_refinement_audit_demote <INIT> <TID> <body-file>
# Shipped dark (design D5): only called under
# PLANNER_REFINEMENT_AUDIT_DEMOTE=true. Runs dor_audit_demote and logs
#   META|refinement-dispute|done|<TID> <CODE> demoted by audit dispute [<hash8>]
# per demoted code (once per ticket, code and body hash), or one
#   META|refinement-dispute|warn|<TID> ... [<hash8>]
# when the blanket-dispute cap refused it (rc 4) or the call failed. Never
# fails the caller.
_planner_refinement_audit_demote() {
  local initiative_id="$1" tid="$2" body_file="$3"
  declare -f dor_audit_demote >/dev/null 2>&1 || return 0

  local out rc=0 hash8 code
  out=$(dor_audit_demote "$tid" "$body_file" 2>/dev/null) || rc=$?
  hash8=$(_planner_refinement_hash8 "$tid")

  case "$rc" in
  0)
    while IFS= read -r code; do
      [ -n "$code" ] || continue
      _planner_refinement_logged "$initiative_id" "|META|refinement-dispute|done|" "$tid" "$hash8" " ${code} " && continue
      planner_state_write "$initiative_id" "META" "refinement-dispute" "done" \
        "${tid} ${code} demoted by audit dispute [${hash8}]" 2>/dev/null || true
    done <<<"$out"
    ;;
  4)
    _planner_refinement_logged "$initiative_id" "|META|refinement-dispute|warn|" "$tid" "$hash8" && return 0
    planner_state_write "$initiative_id" "META" "refinement-dispute" "warn" \
      "${tid} blanket dispute refused — more than ${DOR_AUDIT_DEMOTE_MAX:-2} codes qualified, nothing demoted [${hash8}]" 2>/dev/null || true
    ;;
  *)
    planner_state_write "$initiative_id" "META" "refinement-dispute" "warn" \
      "${tid} audit demotion failed rc=${rc} [${hash8}]" 2>/dev/null || true
    ;;
  esac
  return 0
}

# _planner_refinement_testdata_findings <TID>
# Prints one compact JSON object per stored finding that is a verified,
# advisory TEST_DATA_GAP (dor-semantic-test-data-gap). Nothing when the
# ticket has no manifest, no semantic verdict or no such finding. Exit 0.
_planner_refinement_testdata_findings() {
  local tid="$1" ready_json
  ready_json=$(get_ticket_manifest_field "$tid" ready 2>/dev/null) || ready_json=""
  [ -n "$ready_json" ] || return 0
  echo "$ready_json" | jq -c '
    (.semantic.findings // [])[]
    | select(.code == "TEST_DATA_GAP" and .severity == "advisory" and .verified == true)
  ' 2>/dev/null || true
  return 0
}

# _planner_refinement_note_testdata <INIT> <TID>
# Records each verified advisory TEST_DATA_GAP finding on the ticket as
#   META|refinement-testdata|warn|<TID> TEST_DATA_GAP: "<quote>" — <detail> [<hash8>]
# where <hash8> is the first 8 hex characters of the stored semantic
# body_hash. Deduped per ticket per body hash: when the log already holds a
# refinement-testdata warn line for this ticket and hash8, nothing is written,
# so a resume does not repeat it and an edited body records anew. The check
# runs once, before any write, so a ticket with two findings records both.
# planner_state_write strips |/CR/LF from the message, so the dedupe matches
# on the ticket id and the bracketed hash only. Never fails the caller —
# advisory visibility must not change Refinement's own outcome.
_planner_refinement_note_testdata() {
  local initiative_id="$1" tid="$2"
  local findings
  findings=$(_planner_refinement_testdata_findings "$tid") || findings=""
  [ -n "$findings" ] || return 0

  local body_hash hash8
  body_hash=$(get_ticket_manifest_field "$tid" ready 2>/dev/null | jq -r '.semantic.body_hash // ""' 2>/dev/null) || body_hash=""
  hash8="${body_hash#sha256:}"
  hash8="${hash8:0:8}"

  local log_file
  log_file=$(planner_state_log "$initiative_id" 2>/dev/null) || log_file=""
  if [ -n "$log_file" ] && [ -f "$log_file" ]; then
    if grep -F '|META|refinement-testdata|warn|' "$log_file" 2>/dev/null |
      grep -F "${tid} TEST_DATA_GAP" 2>/dev/null |
      grep -qF "[${hash8}]" 2>/dev/null; then
      return 0
    fi
  fi

  local finding quote detail
  while IFS= read -r finding; do
    [ -n "$finding" ] || continue
    quote=$(echo "$finding" | jq -r '.quote // ""' 2>/dev/null) || quote=""
    detail=$(echo "$finding" | jq -r '.detail // ""' 2>/dev/null) || detail=""
    planner_state_write "$initiative_id" "META" "refinement-testdata" "warn" \
      "${tid} TEST_DATA_GAP: \"${quote}\" — ${detail} [${hash8}]" 2>/dev/null || true
  done <<<"$findings"
  return 0
}

# planner_refinement_advisory_summary <INIT>
# Prints one line per verified advisory TEST_DATA_GAP finding currently stored
# on any child of the initiative's epic, ready or not:
#   Advisory (does not block) <TID> TEST_DATA_GAP: "<quote>" — <detail>
# then one line per demotion on a ready child (planner-refinement-
# convergence): a demoted semantic finding
#   Advisory (does not block) <TID> <CODE> (demoted: <reason>[, by <op>]): "<quote>" — <detail>
# or an audit-demoted deterministic code
#   Advisory (does not block) <TID> <CODE> (demoted: audit dispute): <reason>
# Reads the manifests (current verdicts), not the state log. Prints nothing
# when there are none or the epic cannot be resolved. Always exit 0.
planner_refinement_advisory_summary() {
  local initiative_id="$1"
  _planner_refinement_testdata_summary "$initiative_id"
  _planner_refinement_demoted_summary "$initiative_id"
  _planner_refinement_missed_summary "$initiative_id"
  return 0
}

# _planner_refinement_missed_summary <INIT> — one line per audit MISSED entry
# (`ready.semantic.missed`, a gap the audit says the scan missed) on every
# child: `Advisory (does not block) <TID> MISSED <CODE>: <reason>`, with
# `Security` before MISSED when it matches the draft gate's security rule
# (planner_draft_security_def). Stored by every semantic apply and carried
# by a draft import, but read by nothing else, so it is never silent.
_planner_refinement_missed_summary() {
  local initiative_id="$1"
  (
    if ! declare -f planner_draft_security_def >/dev/null 2>&1 &&
      [ -f "${_PLANNER_REFINEMENT_LIB_DIR}/planner-draft-revise.sh" ]; then
      # shellcheck source=planner-draft-revise.sh
      source "${_PLANNER_REFINEMENT_LIB_DIR}/planner-draft-revise.sh" >/dev/null 2>&1
    fi
    local def='def pdr_security: false;' tid
    declare -f planner_draft_security_def >/dev/null 2>&1 && def=$(planner_draft_security_def)
    for tid in $(_planner_refinement_children "$initiative_id"); do
      get_ticket_manifest_field "$tid" ready 2>/dev/null | jq -r --arg t "$tid" "${def}"'
        (.semantic.missed // [])[] | select(type == "object")
        | {code: (.code // "" | tostring), detail: (.reason // "" | tostring)}
        | select(.detail != "")
        | "Advisory (does not block) \($t) \(if pdr_security then "Security " else "" end)MISSED \(.code | gsub("[[:cntrl:]]"; " ")): \(.detail | gsub("[[:cntrl:]]"; " ") | .[0:500])"' 2>/dev/null || true
    done
  )
  return 0
}

# _planner_refinement_children <INIT> — the epic's children, one per line.
# Nothing (exit 0) when the deps or the epic cannot be resolved.
_planner_refinement_children() {
  local initiative_id="$1"
  _planner_refinement_source_deps 2>/dev/null || return 0
  local epic_id children
  epic_id=$(planner_epic_id "$initiative_id" 2>/dev/null) || return 0
  children=$(get_epic_manifest_field "$epic_id" children 2>/dev/null) || children=""
  [ -n "$children" ] || children='[]'
  echo "$children" | jq -r '.[]' 2>/dev/null || true
  return 0
}

# _planner_refinement_testdata_summary <INIT> — the TEST_DATA_GAP lines of
# planner_refinement_advisory_summary (byte-identical to before
# planner-refinement-convergence).
_planner_refinement_testdata_summary() {
  local initiative_id="$1"
  local tid findings finding quote detail
  for tid in $(_planner_refinement_children "$initiative_id"); do
    findings=$(_planner_refinement_testdata_findings "$tid") || findings=""
    [ -n "$findings" ] || continue
    while IFS= read -r finding; do
      [ -n "$finding" ] || continue
      quote=$(echo "$finding" | jq -r '.quote // ""' 2>/dev/null) || quote=""
      detail=$(echo "$finding" | jq -r '.detail // ""' 2>/dev/null) || detail=""
      echo "Advisory (does not block) ${tid} TEST_DATA_GAP: \"${quote}\" — ${detail}"
    done <<<"$findings"
  done
  return 0
}

# _planner_refinement_demoted_summary <INIT> — the demotion lines of
# planner_refinement_advisory_summary, ready children only.
_planner_refinement_demoted_summary() {
  local initiative_id="$1"
  local tid
  for tid in $(_planner_refinement_children "$initiative_id"); do
    get_ticket_manifest_field "$tid" ready 2>/dev/null | jq -r --arg t "$tid" '
      select(.status == "ready")
      | ((.semantic.findings // [])[] | select((.demoted // null) != null)
          | "Advisory (does not block) \($t) \(.code) (demoted: \(.demoted)"
            + (if (.converged_by // "") != "" then ", by \(.converged_by)" else "" end)
            + "): \"\(.quote)\"" + (if (.detail // "") != "" then " — \(.detail)" else "" end)),
        ((.demoted // {}) | to_entries[]
          | "Advisory (does not block) \($t) \(.key) (demoted: audit dispute): \(.value.reason // "")")' 2>/dev/null || true
  done
  return 0
}

# planner_refinement_unavailable <INIT> <TID>
# A fresh {unavailable:true} verdict through set_ticket_semantic, which never
# touches ready.lineage — the ticket keeps its round history (design D9).
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

# ── Operator converge (planner-refinement-convergence D10) ───────────────

# planner_refinement_converge_args_validate <converge-flag> <only> <by>
# The argument rules for `resume --converge --only <TIDs> [--by <name>]`,
# checked once in SKILL.md step 2a before anything is persisted.
planner_refinement_converge_args_validate() {
  local converge="$1" only="$2" by="$3"
  if [ "$converge" = "true" ] && [ -z "$only" ]; then
    echo "ERROR: --converge requires --only <TID[,TID...]> — there is no epic-wide converge" >&2
    return 1
  fi
  if [ "$converge" != "true" ] && { [ -n "$only" ] || [ -n "$by" ]; }; then
    echo "ERROR: --only and --by are only valid with --converge" >&2
    return 1
  fi
  if [ -n "$only" ] && [[ ! "$only" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+(,[A-Za-z][A-Za-z0-9]*-[0-9]+)*$ ]]; then
    echo "ERROR: --only takes a comma-separated list of ticket ids (e.g. PRO-12,PRO-13), got '${only}'" >&2
    return 1
  fi
  return 0
}

# planner_refinement_converge <INIT> <TID[,TID...]> [<by>]
# Rewrites the stored verdict of each named child, without any scan: every
# blocking finding whose code is not structural (the effective
# DOR_SEMANTIC_STRUCTURAL_CODES list) becomes advisory with demoted
# "converge" and converged_by <by>. Unverified findings, structural findings,
# deterministic codes and the bash-owned SEMANTIC_* codes are untouched, so
# they keep blocking. A child with no verdict, an unavailable or stale one,
# one for a different body (body.md edited since) or a different evaluator
# is refused: nothing is written for it, it is named on stdout as needing a
# scan, and a META|refinement-converge|skip line records why.
planner_refinement_converge() {
  local initiative_id="$1" tids="$2" by="${3:-}"
  [ -n "$by" ] || by="${USER:-operator}"
  _planner_refinement_source_deps || return 1

  local epic_id
  epic_id=$(planner_epic_id "$initiative_id") || {
    echo "planner-refinement: no EpicGen EPIC_ID found for ${initiative_id} — converge cannot resolve children" >&2
    return 1
  }
  local children
  children=$(get_epic_manifest_field "$epic_id" children 2>/dev/null)
  [ -n "$children" ] || children='[]'

  local structural
  structural=$(_dor_semantic_structural_codes | jq -R . | jq -sc 'map(select(. != ""))')

  local -a list=()
  IFS=',' read -ra list <<<"$tids"
  local tid
  for tid in "${list[@]}"; do
    tid="${tid//[[:space:]]/}"
    [ -n "$tid" ] || continue

    local reason=""
    if ! echo "$children" | jq -e --arg t "$tid" 'index($t) != null' >/dev/null 2>&1; then
      reason="not a child of epic ${epic_id}"
    fi

    local ready_json="" body_file cur_hash=""
    body_file="${REPOS_ROOT:-}/.ticket-auto/initiatives/${initiative_id}/tickets/${tid}/planner/body.md"
    if [ -z "$reason" ]; then
      ready_json=$(get_ticket_manifest_field "$tid" ready 2>/dev/null) || ready_json=""
      [ -f "$body_file" ] && cur_hash=$(_dor_body_hash "$(cat "$body_file")" 2>/dev/null)
      reason=$(echo "$ready_json" | jq -r --arg h "$cur_hash" --arg e "${DOR_SEMANTIC_EVALUATOR:-}" '
        if (.semantic // null) == null then "no semantic verdict — it needs a scan first"
        elif .semantic.unavailable == true then "the semantic verdict is unavailable — it needs a scan first"
        elif (.semantic.stale // false) or (((.missing // []) | index("SEMANTIC_STALE")) != null)
          then "the semantic verdict is stale — it needs a scan first"
        elif .semantic.body_hash != $h then "body.md changed since the verdict — it needs a scan first"
        elif .semantic.evaluator != $e then "the verdict is from another evaluator — it needs a scan first"
        else "" end' 2>/dev/null) || reason="no readiness verdict — it needs a scan first"
      [ -n "$ready_json" ] && [ "$ready_json" != "null" ] || reason="no readiness verdict — it needs a scan first"
    fi

    if [ -n "$reason" ]; then
      echo "refused ${tid}: ${reason}"
      planner_state_write "$initiative_id" "META" "refinement-converge" "skip" "${tid} refused — ${reason}" 2>/dev/null || true
      continue
    fi

    local new_sem n
    new_sem=$(planner_semantic_demote "$(echo "$ready_json" | jq -c '.semantic')" converge "$by") || {
      echo "refused ${tid}: could not rewrite the verdict"
      continue
    }
    n=$(echo "$ready_json" | jq --argjson s "$structural" '
      [(.semantic.findings // [])[]
        | select(.severity == "blocking" and .verified != false and ((.code as $c | $s | index($c)) == null))]
      | length')
    if ! set_ticket_semantic "$tid" "$new_sem" >/dev/null 2>&1; then
      echo "refused ${tid}: the manifest write failed"
      continue
    fi
    planner_state_write "$initiative_id" "META" "refinement-converge" "done" "${tid} demoted=${n} by=${by}" 2>/dev/null || true
    echo "converged ${tid} demoted=${n} by=${by}"
  done
  return 0
}

# planner_semantic_demote <semantic-json> <demoted> <by> [<ids>] [<demote-reason>]
# The one demotion rewrite, shared by converge (demoted "converge",
# converged_by <by>) and the draft gate's end-of-loop convergence
# (planner-draft-readiness D11: demoted "round-limit", demoted_by <by>).
# Every blocking, verified finding whose code is not structural (the
# effective DOR_SEMANTIC_STRUCTURAL_CODES list) becomes advisory; with <ids>
# (comma-separated finding ids) only those. <demote-reason> adds a
# `demote_reason` field: a plain string for every demoted finding, or a JSON
# object mapping finding id → reason class. Unverified findings, structural
# findings and the bash-owned SEMANTIC_* codes keep blocking. Prints the new
# semantic object; rc 1 on bad input.
planner_semantic_demote() {
  local sem="$1" demoted="$2" by="${3:-}" ids="${4:-}" reason="${5:-}"
  _planner_refinement_source_deps || return 1
  [ -n "$demoted" ] || {
    echo "planner-refinement: planner_semantic_demote needs a demoted value" >&2
    return 1
  }
  local structural ids_json='null' reason_json='null'
  structural=$(_dor_semantic_structural_codes | jq -R . | jq -sc 'map(select(. != ""))')
  [ -n "$ids" ] && ids_json=$(printf '%s' "$ids" | tr ',' '\n' | tr -d '[:space:]' | jq -R . | jq -sc 'map(select(. != ""))')
  if [ -n "$reason" ]; then
    if [ "${reason:0:1}" = "{" ]; then
      reason_json=$(printf '%s' "$reason" | jq -c 'if type == "object" then . else error("not an object") end') || return 1
    else
      reason_json=$(jq -nc --arg r "$reason" '$r')
    fi
  fi
  echo "$sem" | jq -c --argjson s "$structural" --arg d "$demoted" --arg by "$by" \
    --argjson ids "$ids_json" --argjson rs "$reason_json" '
    if type != "object" then error("semantic must be an object") else . end
    | .findings = [(.findings // [])[]
        | if .severity == "blocking" and .verified != false and ((.code as $c | $s | index($c)) == null)
             and ($ids == null or ((.id as $i | $ids | index($i)) != null))
          then . + (if $d == "converge" then {severity: "advisory", demoted: $d, converged_by: $by}
                    else {severity: "advisory", demoted: $d, demoted_by: $by} end)
                 + (if $rs == null then {}
                    elif ($rs | type) == "string" then {demote_reason: $rs}
                    elif $rs[.id] != null then {demote_reason: $rs[.id]}
                    else {} end)
          else . end]'
}

# planner_refinement_converge_consume <INIT>
# Runs the one-shot `converge` config key ("<TID,TID...> <operator>",
# written by SKILL.md step 2b) and clears it, like refresh-bodies.
planner_refinement_converge_consume() {
  local initiative_id="$1" value tids by=""
  value=$(planner_config_get "$initiative_id" "converge" 2>/dev/null) || value=""
  [ -n "$value" ] || return 0
  tids="${value%% *}"
  if [ "$value" != "$tids" ]; then
    by="${value#* }"
  fi
  planner_refinement_converge "$initiative_id" "$tids" "$by"
  planner_config_set "$initiative_id" "converge" "none"
  return 0
}

# ── Refinement after Completed (design D6/D10) ───────────────────────────

# planner_refinement_after_completed_pending <INIT>
planner_refinement_after_completed_pending() {
  local initiative_id="$1"
  [ -f "$(planner_state_log "$initiative_id" 2>/dev/null)" ] || return 1
  [ -z "$(planner_position_derive "$initiative_id" 2>/dev/null)" ] || return 1
  # A legacy initiative has no body.md or verdicts, and step 1b's legacy
  # branch writes phase lines — never re-run it after Completed.
  if planner_refinement_legacy "$initiative_id"; then
    return 1
  fi
  if [ "$(planner_config_get "$initiative_id" "refresh-bodies" 2>/dev/null)" = "true" ]; then
    return 0
  fi
  planner_config_is_set "$initiative_id" "converge" 2>/dev/null
}

# planner_refinement_after_completed_finish <INIT>
# Closes a Refinement re-run on a finished initiative with one META line —
# no Refinement|gate line, no epic re-stamp, so planner_position_derive
# still returns the empty string. Prints the same summary.
planner_refinement_after_completed_finish() {
  local initiative_id="$1"
  _planner_refinement_source_deps || return 1
  local epic_id children total=0 not_ready=0 tid status
  epic_id=$(planner_epic_id "$initiative_id") || return 1
  children=$(get_epic_manifest_field "$epic_id" children 2>/dev/null)
  [ -n "$children" ] || children='[]'
  for tid in $(echo "$children" | jq -r '.[]' 2>/dev/null); do
    total=$((total + 1))
    status=$(get_ticket_manifest_field "$tid" ready 2>/dev/null | jq -r '.status // "unavailable"' 2>/dev/null)
    [ "$status" = "ready" ] || not_ready=$((not_ready + 1))
  done
  local msg="${not_ready} of ${total} not ready after re-running Refinement on a Completed initiative"
  planner_state_write "$initiative_id" "META" "refinement-after-completed" "done" "$msg" 2>/dev/null || true
  echo "$msg"
  return 0
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

    # Round (planner-refinement-convergence D1) — only once a lineage exists.
    local round_line
    round_line=$(echo "$ready_json" | jq -r '
      .lineage // null | select(. != null and .round != null)
      | "Round: \(.round)"
        + (if .reset == true or .reset == 1 then " (reset after a rewrite)" else "" end)
        + (if (.policy.max_rounds // null) != null
           then " — non-structural findings stop blocking after round \(.policy.max_rounds)" else "" end)' 2>/dev/null) || round_line=""
    if [ -n "$round_line" ]; then
      echo "$round_line"
    fi

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

    # BODY_DRIFT / BODY_UNVERIFIED are never waivable (design D6): the way
    # out is the refresh, so that is the only release offered.
    local pdir_r="${REPOS_ROOT:-}/.ticket-auto/initiatives/${initiative_id}/tickets/${tid}/planner"
    case " $(echo "$missing" | tr '\n' ' ') " in
    *" BODY_DRIFT "*)
      local drift_cls
      drift_cls=$(head -1 "${pdir_r}/body-drift" 2>/dev/null) || drift_cls=""
      [ -n "$drift_cls" ] || drift_cls="conflict"
      if [ "$drift_cls" = "local-ahead" ]; then
        echo "${tid} body drift (local-ahead): body.md was edited but the Linear description was not — ticket-auto would build text Refinement never evaluated."
        echo "  Copy the local edit into Linear first if it should stay, then take Linear's text: /ticket-planner resume ${initiative_id} --refresh-bodies (not waivable)"
      else
        echo "${tid} body drift (conflict): the Linear description and body.md both changed since the last baseline."
        echo "  Take Linear's text: /ticket-planner resume ${initiative_id} --refresh-bodies (not waivable)"
      fi
      ;;
    esac
    case " $(echo "$missing" | tr '\n' ' ') " in
    *" BODY_UNVERIFIED "*)
      echo "${tid} body unverified: the Linear description could not be read on $(cat "${pdir_r}/linear-read-fails" 2>/dev/null || echo "$(_planner_refinement_max_fails)") consecutive runs, so body drift was not checked."
      echo "  Once Linear is reachable, resume re-checks it, or take Linear's text: /ticket-planner resume ${initiative_id} --refresh-bodies (not waivable)"
      ;;
    esac

    # Findings grouped by lineage and demotion (planner-refinement-
    # convergence D3/D10). Rendered in jq: one line per finding, the
    # demoted ones (plus ready.demoted audit demotions) collected under
    # "Demoted (does not block):".
    local finding_lines demoted_lines
    finding_lines=$(echo "$ready_json" | jq -r '
      def text: "\(.code): \"\(.quote)\"" + (if (.detail // "") != "" then " — \(.detail)" else "" end);
      (.semantic.findings // [])[] | select((.demoted // null) == null)
      | if .verified == false then "Unverified finding \(text)"
        elif .severity == "blocking" then
          (if .lineage == "drift" then "Structural drift (blocks) \(text)"
           elif .lineage == "carried" then "Blocking (carried since round \(.first_round // "?")) \(text)"
           else "Blocking (new) \(text)" end)
        else "Advisory finding \(text)" end' 2>/dev/null) || finding_lines=""
    demoted_lines=$(echo "$ready_json" | jq -r '
      def text: "\"\(.quote)\"" + (if (.detail // "") != "" then " — \(.detail)" else "" end);
      ((.semantic.findings // [])[] | select((.demoted // null) != null)
        | "  - \(.code) (\(.demoted)" + (if (.converged_by // "") != "" then ", by \(.converged_by)" else "" end) + "): \(text)"),
      ((.demoted // {}) | to_entries[] | "  - \(.key) (audit dispute): \(.value.reason // "")")' 2>/dev/null) || demoted_lines=""
    if [ -n "$finding_lines" ]; then
      echo "$finding_lines"
    fi
    if [ -n "$demoted_lines" ]; then
      echo "Demoted (does not block):"
      echo "$demoted_lines"
    fi
    local structural_json
    structural_json=$(_dor_semantic_structural_codes | jq -R . | jq -sc 'map(select(. != ""))' 2>/dev/null) || structural_json='[]'
    if echo "$ready_json" | jq -e --argjson s "$structural_json" '[(.semantic.findings // [])[]
        | select(.severity == "blocking" and .verified != false and ((.code as $c | $s | index($c)) == null))]
        | length > 0' >/dev/null 2>&1; then
      echo "Converge (no rescan): /ticket-planner resume ${initiative_id} --converge --only ${tid} — structural findings keep blocking"
    fi

    local n i
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
    local demoted_keys
    demoted_keys=$(echo "$ready_json" | jq -r '.demoted // {} | keys | join(" ")' 2>/dev/null) || demoted_keys=""
    n=$(echo "$audit_json" | jq 'length' 2>/dev/null) || n=0
    for ((i = 0; i < n; i++)); do
      local acode averdict areason
      acode=$(echo "$audit_json" | jq -r ".[$i].code")
      averdict=$(echo "$audit_json" | jq -r ".[$i].verdict")
      [ "$averdict" = "disputed" ] || continue
      # An audit-demoted code no longer blocks — it is listed under Demoted,
      # never offered as something to waive (design D5).
      case " $demoted_keys " in *" $acode "*) continue ;; esac
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
    if [ "${PLANNER_REFINEMENT_DRIFT_CHECK:-true}" = "false" ]; then
      echo "An edit made in Linear is only evaluated after /ticket-planner resume ${initiative_id} --refresh-bodies."
    else
      echo "A Linear edit is adopted on the next resume when body.md is unchanged; to take Linear's text over a local edit: /ticket-planner resume ${initiative_id} --refresh-bodies."
    fi
  fi

  # Advisory findings never put a child in the not-ready loop above, so a
  # ready child's TEST_DATA_GAP would otherwise go unreported
  # (dor-semantic-test-data-gap).
  local advisory_summary
  advisory_summary=$(_planner_refinement_testdata_summary "$initiative_id") || advisory_summary=""
  if [ -n "$advisory_summary" ]; then
    echo ""
    echo "## Advisory test-data findings"
    echo "$advisory_summary"
  fi

  # Demotions on ready children (not-ready ones list theirs above).
  local demoted_summary
  demoted_summary=$(_planner_refinement_demoted_summary "$initiative_id") || demoted_summary=""
  if [ -n "$demoted_summary" ]; then
    echo ""
    echo "## Demoted findings on ready tickets"
    echo "$demoted_summary"
  fi
}

# ── Refresh (design.md Decision 9) ────────────────────────────────────────

# planner_refinement_refresh_bodies <INIT>
# "Take Linear for every child" (planner-refinement-convergence D6): checks
# every child, ready and waived ones included, and for each one whose class
# is not `clean` writes body.md (unless it already equals Linear's text) and
# the baseline from its current Linear description. A `clean` child is not
# touched. Waivers are never touched — the manifest is not written here.
# Prints, one per line, each child the next scan must re-evaluate: every
# non-clean child, plus a clean one still carrying BODY_DRIFT or
# BODY_UNVERIFIED (step 1b uses this as the affected set after Completed).
# A child whose Linear read fails is skipped. Read-only towards Linear.
planner_refinement_refresh_bodies() {
  local initiative_id="$1"
  _planner_refinement_source_deps || return 1

  local epic_id
  epic_id=$(planner_epic_id "$initiative_id") || return 1

  local children
  children=$(get_epic_manifest_field "$epic_id" children 2>/dev/null)
  [ -n "$children" ] || children='[]'

  local repos_root="${REPOS_ROOT:-}" have_baseline="false" tid
  _planner_refinement_source_baseline && have_baseline="true"

  for tid in $(echo "$children" | jq -r '.[]' 2>/dev/null); do
    local desc
    desc=$(_planner_refinement_linear_desc "$tid") || continue

    local pdir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/tickets/${tid}/planner"
    mkdir -p "$pdir" 2>/dev/null

    if [ "$have_baseline" != "true" ]; then
      # No baseline lib: fall back to a plain text comparison.
      if [ "$(cat "${pdir}/body.md" 2>/dev/null)" != "$desc" ]; then
        printf '%s' "$desc" >"${pdir}/body.md"
        echo "$tid"
      fi
      continue
    fi

    rm -f "${pdir}/linear-read-fails" 2>/dev/null
    local cls="" held="false"
    cls=$(body_baseline_classify "$pdir" "$desc" 2>/dev/null) || cls="missing"
    if get_ticket_manifest_field "$tid" ready 2>/dev/null |
      jq -e '(.missing // []) | any(. == "BODY_DRIFT" or . == "BODY_UNVERIFIED")' >/dev/null 2>&1; then
      held="true"
    fi

    case "$cls" in
    clean)
      [ "$held" = "true" ] && echo "$tid"
      continue
      ;;
    rebaseline) ;;
    *) printf '%s' "$desc" >"${pdir}/body.md" ;;
    esac
    body_baseline_write "$pdir" "$desc" 2>/dev/null
    rm -f "${pdir}/body-drift" 2>/dev/null
    echo "$tid"
  done
}

# ── TicketGen baseline (planner-refinement-convergence D6) ────────────────

# planner_ticketgen_record_baseline <INIT> <TID> create|skip
# Called by the TicketGen script after it persisted planner/body.md.
#   create  read the description back once; write the baseline from it. When
#           Linear stored a different rendering than the composed body,
#           body.md takes Linear's text (it is what ticket-auto will read,
#           and the baseline describes it), with a META|ticketgen|warn line.
#   skip    write the baseline only when none exists and the normalised
#           Linear text equals body.md; otherwise leave it to Refinement,
#           which classifies the ticket.
# A failed read-back (or a missing body-baseline.sh) writes nothing and
# prints a warning on stderr. Always exit 0.
planner_ticketgen_record_baseline() {
  local initiative_id="$1" tid="$2" mode="${3:-create}"
  local pdir
  pdir="$(planner_initiative_dir "$initiative_id" 2>/dev/null)/tickets/${tid}/planner"
  [ -f "${pdir}/body.md" ] || return 0
  _planner_refinement_source_baseline 2>/dev/null || {
    echo "WARNING: body-baseline.sh not found — no body baseline for ${tid}" >&2
    return 0
  }

  local desc
  desc=$(_planner_refinement_linear_desc "$tid") || {
    echo "WARNING: could not read back ${tid}'s description — no body baseline; Refinement classifies it" >&2
    return 0
  }

  local l m
  l=$(body_baseline_hash "$desc" 2>/dev/null) || return 0
  m=$(body_baseline_hash "$(cat "${pdir}/body.md" 2>/dev/null)" 2>/dev/null) || return 0

  case "$mode" in
  skip)
    body_baseline_read "$pdir" >/dev/null 2>&1 && return 0
    [ "$l" = "$m" ] || return 0
    body_baseline_write "$pdir" "$desc" 2>/dev/null || true
    ;;
  *)
    if [ "$l" != "$m" ]; then
      printf '%s' "$desc" >"${pdir}/body.md" 2>/dev/null || return 0
      planner_state_write "$initiative_id" "META" "ticketgen" "warn" \
        "${tid} Linear stored a different rendering of the description — body.md now holds Linear's text [${m:0:8}→${l:0:8}]" 2>/dev/null || true
    fi
    body_baseline_write "$pdir" "$desc" 2>/dev/null || true
    ;;
  esac
  return 0
}

# ── Spawn-list driver (planner-draft-readiness S2b, task 4.1) ────────────
# SKILL.md step 1b used to carry this as ~90 lines of inline bash. It now
# runs the shared spawn-list loop (SKILL.md step 1d) over these functions,
# the same loop the draft readiness gate uses.

# The semantic-pass list: one ticket id per line, written by prepare,
# shrunk by apply as each ticket gets a verdict.
_planner_refinement_pass_file() {
  echo "${REPOS_ROOT:-}/.ticket-auto/initiatives/${1}/refinement-pass"
}

# planner_refinement_prepare <INIT>
# Everything step 1b did before the agent spawns: the legacy skip (writes
# its two lines, rc 2), the one-shot --refresh-bodies, the deterministic
# scan (on a Completed initiative — REFINEMENT_AFTER_COMPLETED=true in the
# caller's shell — only the refreshed children, or none), the one-shot
# --converge (its output printed verbatim), then the semantic-pass list
# (empty under PLANNER_REFINEMENT_SEMANTIC=false). Every listed ticket's
# result files and attempt counter are cleared, so a stale result from an
# earlier run is never applied. rc 0 = run the spawn loop, then the gate.
planner_refinement_prepare() {
  local init="$1" refreshed="" pass tid
  if planner_refinement_legacy "$init"; then
    # Planned before this phase shipped: its log already carries
    # TicketGen|dispatch-gate|done (design.md Decision 10).
    planner_state_write "$init" "META" "refinement" "skip" "legacy — TicketGen|dispatch-gate|done already recorded"
    planner_state_write "$init" "Refinement" "gate" "skip" "legacy initiative — Refinement not evaluated"
    return 2
  fi
  if [ "$(planner_config_get "$init" "refresh-bodies")" = "true" ]; then
    refreshed=$(planner_refinement_refresh_bodies "$init" | paste -sd, -)
    planner_config_set "$init" "refresh-bodies" "none"
  fi
  local -a needs=()
  if [ "${REFINEMENT_AFTER_COMPLETED:-}" != "true" ]; then
    mapfile -t needs < <(planner_refinement_scan "$init")
  elif [ -n "$refreshed" ]; then
    mapfile -t needs < <(planner_refinement_scan "$init" --only "$refreshed")
  fi
  planner_refinement_converge_consume "$init"
  pass=$(_planner_refinement_pass_file "$init")
  mkdir -p "$(dirname "$pass")" && : >"$pass" || return 1
  # A spawn list left by a crashed run belongs to that run: applying it
  # would count every listed ticket as a failed attempt.
  rm -f "${pass}.pending"
  [ "${PLANNER_REFINEMENT_SEMANTIC:-true}" != "false" ] || return 0
  for tid in "${needs[@]}"; do
    [ -n "$tid" ] || continue
    local pdir="${REPOS_ROOT:-}/.ticket-auto/initiatives/${init}/tickets/${tid}/planner"
    rm -f "${pdir}/semantic-scan-result.txt" "${pdir}/semantic-audit-result.txt" "${pdir}/semantic-attempts"
    echo "$tid" >>"$pass"
  done
  return 0
}

# planner_refinement_next <INIT>
# Applies results already on disk, then prints the next spawn list — one
# "<TID>\t<scan|audit>\tticket-auto-pipeline:dor-semantic-agent\t<prompt-file>\t<result-file>"
# line per agent, for at most PLANNER_REFINEMENT_PARALLEL (default 4)
# tickets: a scan when the ticket has no scan result, else its audit (built
# only after the scan returned — the scan is blind by construction, design
# Decision 6). `done 0` when the pass list is empty.
planner_refinement_next() {
  local init="$1" pass tid pdir max n=0 out=""
  # The spawn list is stdout's only content: anything apply prints goes to
  # stderr (dor_semantic_apply reports `round=… demoted=…` on stdout).
  planner_refinement_apply_pending "$init" >&2 || return 1
  pass=$(_planner_refinement_pass_file "$init")
  max="${PLANNER_REFINEMENT_PARALLEL:-4}"
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=4
  if [ -s "$pass" ]; then
    while IFS= read -r tid; do
      [ -n "$tid" ] || continue
      [ "$n" -lt "$max" ] || break
      n=$((n + 1))
      pdir="${REPOS_ROOT:-}/.ticket-auto/initiatives/${init}/tickets/${tid}/planner"
      if [ ! -s "${pdir}/semantic-scan-result.txt" ]; then
        planner_refinement_prompt "$init" "$tid" scan >"${pdir}/semantic-scan-prompt.txt" || return 1
        out+="${tid}"$'\t'"scan"$'\t'"ticket-auto-pipeline:dor-semantic-agent"$'\t'"${pdir}/semantic-scan-prompt.txt"$'\t'"${pdir}/semantic-scan-result.txt"$'\n'
      else
        planner_refinement_prompt "$init" "$tid" audit >"${pdir}/semantic-audit-prompt.txt" || return 1
        out+="${tid}"$'\t'"audit"$'\t'"ticket-auto-pipeline:dor-semantic-agent"$'\t'"${pdir}/semantic-audit-prompt.txt"$'\t'"${pdir}/semantic-audit-result.txt"$'\n'
      fi
    done <"$pass"
  fi
  if [ -z "$out" ]; then
    rm -f "${pass}.pending"
    echo "done 0"
    return 0
  fi
  printf '%s' "$out" >"${pass}.pending"
  printf '%s' "$out"
}

# planner_refinement_apply_pending <INIT>
# For every ticket of the last spawn list: a missing result file is a
# failed attempt; a ticket whose audit returned goes through
# planner_refinement_apply. A failed attempt clears both result files (the
# next list re-spawns the scan); the second one calls
# planner_refinement_unavailable — one retry, as before. A ticket with a
# verdict leaves the pass list.
planner_refinement_apply_pending() {
  local init="$1" pass tid kind agent pf rf pdir n
  pass=$(_planner_refinement_pass_file "$init")
  [ -f "${pass}.pending" ] || return 0
  local -A seen=() failed=()
  local -a order=()
  while IFS=$'\t' read -r tid kind agent pf rf; do
    [ -n "$tid" ] || continue
    [ -n "${seen[$tid]:-}" ] || order+=("$tid")
    seen[$tid]="$kind"
    [ -s "$rf" ] || failed[$tid]=1
  done <"${pass}.pending"
  rm -f "${pass}.pending"
  for tid in "${order[@]}"; do
    pdir="${REPOS_ROOT:-}/.ticket-auto/initiatives/${init}/tickets/${tid}/planner"
    if [ -z "${failed[$tid]:-}" ]; then
      [ "${seen[$tid]}" = "audit" ] || continue
      if planner_refinement_apply "$init" "$tid" >&2; then
        _planner_refinement_pass_drop "$pass" "$tid"
        continue
      fi
    fi
    n=$(($(cat "${pdir}/semantic-attempts" 2>/dev/null || echo 0) + 1))
    echo "$n" >"${pdir}/semantic-attempts"
    rm -f "${pdir}/semantic-scan-result.txt" "${pdir}/semantic-audit-result.txt"
    if [ "$n" -ge 2 ]; then
      planner_refinement_unavailable "$init" "$tid" >&2
      _planner_refinement_pass_drop "$pass" "$tid"
    fi
  done
  return 0
}

_planner_refinement_pass_drop() {
  local pass="$1" tid="$2"
  grep -vxF "$tid" "$pass" >"${pass}.tmp" 2>/dev/null
  mv -f "${pass}.tmp" "$pass"
}
