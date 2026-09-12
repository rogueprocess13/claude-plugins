#!/usr/bin/env bash
# planner-adr-gate.sh — the halt bridge for a blocking ADR gate verdict
# (adr-governance-gate, adr-gate-invocation spec § Planner invocation without
# hold infrastructure).
#
# The planner has no human-hold infrastructure the way ticket-auto-pipeline
# does, so a blocking verdict (CREATED_PROPOSED/SUPERSEDE_REQUIRED/CONFLICT)
# from the Architecture phase (lib/planner-phase-prompts.sh § 4.5) cannot be
# parked the same way — it halts the dispatch loop instead, in the same
# manner an existing blocking phase finding already does (Crosscheck's
# `META|crosscheck|fail|<CODE>` halt in planner-crosscheck.sh). This file is
# that bridge: it reads back the `META|adr-gate|fail|<VERDICT> ADR_ID=<id>`
# marker the phase prompt instructs the agent to write, scoped to the most
# recent attempt of the given phase (mirrors
# planner_crosscheck_findings_summary's "since the last start marker"
# scoping) so a resolved-and-resumed initiative never re-reports a stale
# block.
#
# Sourceable library — no set -euo pipefail (repo convention for this dir).

# Usage: planner_adr_gate_blocked <initiative_id> <phase> <step>
# Prints "<VERDICT>\t<ADR_ID>" on a hit. Exit 0 blocked, 1 not blocked (or no
# log / no start marker for this phase-step yet).
planner_adr_gate_blocked() {
  local initiative_id="$1" phase="$2" step="$3"
  local log
  log=$(planner_state_log "$initiative_id")
  [ -f "$log" ] || return 1

  local start_line
  start_line=$(grep -n "|${phase}|${step}|start|" "$log" | tail -1 | cut -d: -f1)
  [ -z "$start_line" ] && return 1

  local line ts p s status msg
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    IFS='|' read -r ts p s status msg <<<"$line"
    [ "$p" = "META" ] || continue
    [ "$s" = "adr-gate" ] || continue
    [ "$status" = "fail" ] || continue

    local verdict adr_id
    verdict=$(echo "$msg" | awk '{print $1}')
    adr_id=$(echo "$msg" | grep -oE 'ADR_ID=[A-Za-z0-9-]*' | cut -d= -f2)
    printf '%s\t%s\n' "$verdict" "$adr_id"
    return 0
  done < <(tail -n "+${start_line}" "$log")

  return 1
}
