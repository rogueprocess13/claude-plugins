#!/usr/bin/env bash
# planner-completed.sh — deterministic renderer for the Completed phase's
# artifacts/COMPLETED.md (DET-PL-4). Everything in the summary is a fact the
# state log, the epic manifest or fleet-features.sh already holds, so no agent
# writes it by hand.
#
# Sourceable (planner_completed_render) or runnable:
#   planner-completed.sh <INIT>
# Exit 0: file written (tmp + mv); prints COMPLETED_EPIC= and COMPLETED_TICKETS=.
# Exit 1: no EPIC_ID in the state log, or the log is unreadable — nothing written.
#
# FLEET_AUTO_DISPATCH is read through fleet-features.sh --json --no-env
# --workspace $REPOS_ROOT (the workspace files fleetd itself starts from), never
# from this process's environment. Script: FLEET_FEATURES_SH, else the sibling
# checkout's fleet-controller, else the installed plugin cache.

_PLANNER_COMPLETED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -f planner_state_log >/dev/null 2>&1 ||
  source "${_PLANNER_COMPLETED_DIR}/planner-state.sh"

# _planner_completed_dispatch → "<value>\t<source>", or "unknown\tfleet-features.sh not found".
_planner_completed_dispatch() {
  local ff="${FLEET_FEATURES_SH:-${_PLANNER_COMPLETED_DIR}/../../fleet-controller/lib/fleet-features.sh}"
  local out
  if [ ! -f "$ff" ] && [ -z "${FLEET_FEATURES_SH:-}" ]; then
    declare -f planner_cache_find >/dev/null 2>&1 ||
      source "${_PLANNER_COMPLETED_DIR}/planner-plugin-cache.sh" 2>/dev/null
    ff=$(planner_cache_find fleet-controller lib/fleet-features.sh 2>/dev/null) || ff=""
  fi
  if [ -f "$ff" ] && out=$(bash "$ff" --json --no-env --workspace "$REPOS_ROOT" 2>/dev/null) &&
    out=$(jq -r '.flags[] | select(.name == "FLEET_AUTO_DISPATCH") | "\(.value)\t\(.source)"' <<<"$out" 2>/dev/null) &&
    [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    printf 'unknown\tfleet-features.sh not found\n'
  fi
}

planner_completed_render() {
  local init="$1" log dir epic
  log=$(planner_state_log "$init" 2>/dev/null) || return 1
  [ -f "$log" ] || {
    echo "planner-completed: no state log for ${init}" >&2
    return 1
  }
  dir=$(dirname "$log")
  epic=$(grep -E '^[^|]*\|EpicGen\|[^|]*\|done\|EPIC_ID=[^|]*$' "$log" | tail -1 | sed 's/^.*|EPIC_ID=//')
  [ -n "$epic" ] || {
    echo "planner-completed: no EPIC_ID in ${log} — cannot summarize" >&2
    return 1
  }

  local idea tickets manifest counts n_created=0 n_skipped=0 n_failed=0 total
  idea=$(grep '^[^|]*|META|idea|start|' "$log" | head -1 | cut -d'|' -f5-)
  # Ticket IDs: TicketGen's Created lines in creation order, then any epic
  # manifest child they miss (an idempotent skip logs no ID).
  tickets=$(grep '^[^|]*|META|ticketgen|step|Created ' "$log" | cut -d'|' -f5- | sed 's/^Created \([^:]*\):.*/\1/')
  manifest="${REPOS_ROOT}/.ticket-auto/initiatives/${epic}/epic/manifest.json"
  if [ -f "$manifest" ]; then
    tickets=$(printf '%s\n%s\n' "$tickets" "$(jq -r '.children[]? // empty' "$manifest" 2>/dev/null)" |
      awk 'NF && !seen[$0]++')
  fi
  counts=$(grep '^[^|]*|META|ticketgen|done|' "$log" | tail -1 | cut -d'|' -f5-)
  if [ -n "$counts" ]; then
    read -r n_created n_skipped n_failed < <(awk '{ print $1+0, $4+0, $7+0 }' <<<"$counts")
  else
    n_created=$(grep -c . <<<"$tickets" || true)
  fi
  total=$((n_created + n_skipped))

  local dispatch dval dsrc dwarn=""
  dispatch=$(_planner_completed_dispatch)
  dval=${dispatch%%$'\t'*}
  dsrc=${dispatch#*$'\t'}
  [ "$dval" = "true" ] ||
    dwarn="WARNING: FLEET_AUTO_DISPATCH is not true — initiative will NOT be auto-dispatched. Set FLEET_AUTO_DISPATCH=true or manually dispatch tickets."

  local tmp="${dir}/artifacts/COMPLETED.md.tmp.$$"
  mkdir -p "${dir}/artifacts"
  {
    printf '# Completion summary — %s\n\n## Initiative\n- **ID:** %s\n- **Idea:** %s\n\n' "$init" "$init" "$idea"
    printf '## Tickets Created\n%s tickets (%s created, %s skipped as already existing, %s failed)\n' \
      "$total" "$n_created" "$n_skipped" "$n_failed"
    [ -z "$tickets" ] || sed 's/^/- /' <<<"$tickets"
    printf '\n## Epic\n- **Linear ID:** %s\n\n## Execution Status\n' "$epic"
    printf -- '- **FLEET_AUTO_DISPATCH:** %s (source: %s)\n' "$dval" "$dsrc"
    [ -z "$dwarn" ] || printf -- '- %s\n' "$dwarn"
    printf '\n## Phase Timeline\n| Phase | Start | End |\n|---|---|---|\n'
    local -a seq
    planner_phase_sequence seq
    awk -F'|' -v phases="${seq[*]}" '
      { if ($4 == "start" && !($2 in s)) s[$2] = $1
        if ($4 == "done" || $4 == "skip") e[$2] = $1 }
      END { n = split(phases, p, " ")
        for (i = 1; i <= n; i++) if ((p[i] in s) || (p[i] in e))
          printf "| %s | %s | %s |\n", p[i], (p[i] in s ? s[p[i]] : "-"), (p[i] in e ? e[p[i]] : "-") }' "$log"
    printf '\n## Warnings\n'
    {
      [ "$n_failed" -eq 0 ] || printf -- '- %s ticket(s) failed validation and were skipped (see META|ticketgen|warn)\n' "$n_failed"
      [ -z "$dwarn" ] || printf -- '- %s\n' "$dwarn"
      awk -F'|' '$2 == "META" {
        m = $5; for (i = 6; i <= NF; i++) m = m "|" $i
        if ($3 == "crosscheck" && $4 == "accepted") print "- Crosscheck accepted by operator: " m
        else if ($3 == "refinement-testdata" && $4 == "warn") print "- Refinement test-data advisory (did not block): " m
        else if ($3 == "ticketgen" && $4 == "warn") print "- TicketGen: " m }' "$log"
    } >"${tmp}.w"
    if [ -s "${tmp}.w" ]; then cat "${tmp}.w"; else echo "None."; fi
    rm -f "${tmp}.w"
    printf '\nState log: %s\n' "$log"
  } >"$tmp" && mv -f "$tmp" "${dir}/artifacts/COMPLETED.md" || {
    rm -f "$tmp" "${tmp}.w"
    return 1
  }
  echo "COMPLETED_EPIC=${epic}"
  echo "COMPLETED_TICKETS=${total}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -eq 1 ] || {
    echo "Usage: planner-completed.sh <INIT>" >&2
    exit 2
  }
  planner_completed_render "$1"
fi
