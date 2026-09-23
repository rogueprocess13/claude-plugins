#!/usr/bin/env bash
# linear.sh — the one production board driver (tracker-event-board-pusher,
# Phase B2 of the tracker-decoupling programme, Track B).
#
# ── Driver CLI contract (shared by every board driver script) ──────────────
# Usage: <driver>.sh apply <TID> <EVENT> <SEQ> <JSON_DATA>
#
# Exit codes:
#   0  handled — including an explicit no-op. A driver with no column or
#      mapping for the given event treats it as a no-op, not an error.
#   nonzero  retryable failure. The caller (pusher.py / outbox-drain.sh)
#      does NOT advance the cursor past this entry and retries it next
#      cycle.
#
# SEQ is passed as its own argument, not only embedded in JSON_DATA, so a
# driver that needs to dedup a replayed dispatch (idempotent-dispatch
# requirement — see tracker-board-driver-contract's spec) always has it
# available without parsing the event's own payload shape.
#
# Every driver resolves its own file paths via BASH_SOURCE, NEVER the
# invoker's $PWD: fleetd's `subprocess.run` inherits the daemon's own cwd,
# while outbox-drain.sh runs from the router's cwd — a driver that located
# workflow.json relative to $PWD would silently behave differently
# depending on which runner called it (design.md Decision 3).
#
# Every driver's `apply` must be safe to invoke twice for the same
# (TID, EVENT, SEQ, JSON_DATA) without a second distinct external effect —
# required because the cursor mechanism can re-dispatch an entry after a
# crash between dispatch and cursor persistence.
# ─────────────────────────────────────────────────────────────────────────
#
# This driver's mapping is sourced from workflow.json's
# board_drivers.linear.events object, not hardcoded here, so it is
# inspectable and versioned alongside the event vocabulary it maps
# (tracker-board-driver-contract spec). Real mappings landed in
# tracker-flow-projection-cutover (Change 2 of the tracker-decoupling
# authority-flip programme) — see linear-board-projection spec.
#
# Failure classification (D6): a transport failure (get_issue/get_team
# unreachable, update_issue non-JSON/retry-exhausted) is transient — exit
# non-zero, the caller holds the cursor and retries. An identifier this
# driver cannot resolve against the team's own states/labels — the only
# permanent-failure case this driver can actually distinguish, since
# update_issue's own return shape does not surface GraphQL-level errors to
# its callers — is recorded via META|board-projection|fail and exits 0, so
# one unprojectable event cannot block every later event for this ticket.
#
# -u intentionally omitted — see events.sh's identical note.
set -eo pipefail

_LD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$_LD_LIB_DIR/heartbeat.sh"
source "$_LD_LIB_DIR/linear-api.sh"

# Same monorepo -> installed skill -> plugin-cache fallback chain events.sh
# uses for workflow.json resolution — anchored at this script's own
# location via BASH_SOURCE, never $PWD.
_linear_driver_resolve_workflow_json() {
  local _cand
  for _cand in \
    "$_LD_LIB_DIR/../skills/ticket-flow/workflow.json" \
    "$HOME/.claude/skills/ticket-flow/workflow.json"; do
    [ -f "$_cand" ] && {
      echo "$_cand"
      return 0
    }
  done
  local _found
  _found=$(find "$HOME/.claude/plugins/cache" -name workflow.json \
    -path "*/ticket-flow/*" 2>/dev/null | sort | tail -1)
  if [ -n "$_found" ] && [ -f "$_found" ]; then
    echo "$_found"
    return 0
  fi
  return 1
}

_linear_driver_pipeline_log() {
  echo "${FLEET_PIPELINE_LOG_DIR:-./logs}/${1}-pipeline.log"
}

# Records a permanent (non-retryable) projection failure and returns —
# callers still `return 0` afterward, since a permanent failure advances the
# cursor rather than holding it.
_linear_driver_permanent_fail() {
  local tid="$1" event="$2" seq="$3" reason="$4"
  local safe_reason="${reason//|/ }"
  _plog "$(_linear_driver_pipeline_log "$tid")" "META" "board-projection" "fail" \
    "event=${event} seq=${seq} reason=${safe_reason}" 2>/dev/null || true
  echo "linear.sh apply: permanent failure — ${tid}/${event} (seq ${seq}): ${reason}" >&2
}

_linear_driver_team_cache_file() {
  echo "${FLEET_PIPELINE_LOG_DIR:-./logs}/.linear-team-${1}.json"
}

# Fetches (or reuses a fresh cached copy of) a team's states+labels
# (linear-board-projection spec: "Board metadata is cached rather than
# refetched per event"). TTL default 900s (15min), overridable via
# LINEAR_DRIVER_TEAM_CACHE_TTL_SECS.
_linear_driver_team_json() {
  local team_id="$1"
  local cache_file
  cache_file=$(_linear_driver_team_cache_file "$team_id")
  local ttl="${LINEAR_DRIVER_TEAM_CACHE_TTL_SECS:-900}"

  if [ -f "$cache_file" ]; then
    local mtime now
    mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ -n "$mtime" ] && [ $((now - mtime)) -lt "$ttl" ]; then
      local cached
      cached=$(cat "$cache_file" 2>/dev/null)
      if echo "$cached" | jq -e . >/dev/null 2>&1; then
        echo "$cached"
        return 0
      fi
    fi
  fi

  local fresh rc=0
  fresh=$(get_team "$team_id") || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$fresh" ] || return 1

  local dir tmp
  dir=$(dirname "$cache_file")
  mkdir -p "$dir" 2>/dev/null || true
  tmp="${cache_file}.tmp.$$"
  printf '%s' "$fresh" >"$tmp" 2>/dev/null && mv -f "$tmp" "$cache_file" 2>/dev/null
  echo "$fresh"
}

_linear_driver_apply() {
  local tid="$1" event="$2" seq="$3" data="${4:-}"
  # Not "${4:-{}}" — bash's default-value parsing does not brace-match
  # arbitrary content, so a literal "{}" inside the ${VAR:-word} form leaks
  # a stray trailing "}" onto every caller-supplied value, not just the
  # fallback case (same bug class events.sh's emit_event documents and
  # works around). Assign the default separately instead.
  [ -z "$data" ] && data="{}"

  if [ -z "$tid" ] || [ -z "$event" ] || [ -z "$seq" ]; then
    echo "linear.sh apply: TID, EVENT and SEQ are required" >&2
    return 2
  fi

  local wf
  wf=$(_linear_driver_resolve_workflow_json) || {
    echo "linear.sh apply: workflow.json not found" >&2
    return 1
  }

  local mapping
  mapping=$(jq -c --arg e "$event" '.board_drivers.linear.events[$e] // null' "$wf" 2>/dev/null) || mapping="null"

  if [ "$mapping" = "null" ]; then
    echo "linear.sh apply: no-op — event '${event}' (seq ${seq}, tid ${tid}) has no board_drivers.linear.events mapping" >&2
    return 0
  fi

  check_api_key || {
    echo "linear.sh apply: no Linear API key configured — transient" >&2
    return 1
  }

  local issue_json rc=0
  issue_json=$(get_issue "$tid") || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$issue_json" ]; then
    echo "linear.sh apply: get_issue failed for ${tid} — transient" >&2
    return 1
  fi

  local team_id
  team_id=$(echo "$issue_json" | jq -r '.team.id // empty')
  if [ -z "$team_id" ]; then
    echo "linear.sh apply: issue ${tid} has no team.id — transient" >&2
    return 1
  fi

  local team_json
  team_json=$(_linear_driver_team_json "$team_id") || {
    echo "linear.sh apply: get_team failed for ${tid}'s team ${team_id} — transient" >&2
    return 1
  }

  # ── Resolve the desired column ────────────────────────────────────────
  local column_spec column=""
  column_spec=$(echo "$mapping" | jq -c '.column // empty')
  if [ -n "$column_spec" ] && [ "$column_spec" != "null" ]; then
    if echo "$column_spec" | jq -e 'type == "object"' >/dev/null 2>&1; then
      local field_name field_val
      field_name=$(echo "$column_spec" | jq -r '.from_data')
      field_val=$(echo "$data" | jq -r --arg f "$field_name" '.[$f] // false')
      if [ "$field_val" = "true" ]; then
        column=$(echo "$column_spec" | jq -r '."true"')
      else
        column=$(echo "$column_spec" | jq -r '."false"')
      fi
    else
      column=$(echo "$column_spec" | jq -r '.')
    fi
  fi

  local new_state_id="" current_state_id
  current_state_id=$(echo "$issue_json" | jq -r '.state.id // empty')
  if [ -n "$column" ]; then
    new_state_id=$(echo "$team_json" | jq -r --arg n "$column" \
      '.states[] | select(.name == $n) | .id' | head -1)
    if [ -z "$new_state_id" ]; then
      _linear_driver_permanent_fail "$tid" "$event" "$seq" "unknown state '${column}' for team ${team_id}"
      return 0
    fi
  fi

  # ── Resolve the desired label set ───────────────────────────────────────
  # Keep every current label outside projected_labels untouched; add/remove
  # only the projected labels this event's entry names (linear-board-
  # projection spec: "writes desired state and preserves labels it does not
  # own", case-insensitive matching).
  local projected_labels add_names
  projected_labels=$(jq -c '.board_drivers.linear.projected_labels // []' "$wf")
  add_names=$(echo "$mapping" | jq -c '.add // []')

  local kept_ids
  kept_ids=$(echo "$issue_json" | jq -c --argjson proj "$projected_labels" \
    '[.labels.nodes[] | select(((.name | ascii_downcase) as $n
      | ($proj | map(ascii_downcase) | index($n))) == null) | .id]')

  local add_ids="[]" missing_label=""
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    local lid
    lid=$(echo "$team_json" | jq -r --arg n "$name" \
      '.labels[] | select(.name | ascii_downcase == ($n | ascii_downcase)) | .id' | head -1)
    if [ -z "$lid" ]; then
      missing_label="$name"
      break
    fi
    add_ids=$(echo "$add_ids" | jq -c --arg i "$lid" '. + [$i]')
  done < <(echo "$add_names" | jq -r '.[]? // empty')

  if [ -n "$missing_label" ]; then
    _linear_driver_permanent_fail "$tid" "$event" "$seq" "unknown label '${missing_label}' for team ${team_id}"
    return 0
  fi

  local desired_label_ids current_label_ids_sorted
  desired_label_ids=$(jq -cn --argjson k "$kept_ids" --argjson a "$add_ids" '($k + $a) | unique | sort')
  current_label_ids_sorted=$(echo "$issue_json" | jq -c '[.labels.nodes[].id] | sort')

  # ── Resolve the assignee projection ─────────────────────────────────────
  local assignee_id="" assignee_changed=false
  if [ "$(echo "$mapping" | jq -r '.assignee // empty')" = "me" ]; then
    local me_id
    me_id=$(get_me 2>/dev/null | jq -r '.id // empty') || true
    if [ -n "$me_id" ]; then
      assignee_id="$me_id"
      local current_assignee
      current_assignee=$(echo "$issue_json" | jq -r '.assignee.id // empty')
      [ "$me_id" != "$current_assignee" ] && assignee_changed=true
    fi
  fi

  # ── Decline to write when nothing would change ──────────────────────────
  local state_changed=false labels_changed=false
  [ -n "$new_state_id" ] && [ "$new_state_id" != "$current_state_id" ] && state_changed=true
  [ "$desired_label_ids" != "$current_label_ids_sorted" ] && labels_changed=true

  if ! $state_changed && ! $labels_changed && ! $assignee_changed; then
    echo "linear.sh apply: no-op — ${tid}/${event} (seq ${seq}) already matches desired state" >&2
    return 0
  fi

  local result update_rc=0
  result=$(update_issue "$tid" "${new_state_id:-}" "$desired_label_ids" "${assignee_id:-}" 2>&1) || update_rc=$?
  if ! echo "$result" | jq empty 2>/dev/null; then
    echo "linear.sh apply: non-JSON response from update_issue for ${tid}/${event} — transient" >&2
    return 1
  fi
  local success
  success=$(echo "$result" | jq -r '.success // false')
  if [ "$success" != "true" ] || [ "$update_rc" -ne 0 ]; then
    # update_issue's own return shape discards GraphQL-level errors (it
    # extracts only .data.issueUpdate), so a rejected-input failure is not
    # distinguishable here from a transport failure — the safe direction is
    # to treat it as transient (hold and retry) rather than silently
    # dropping a mutation this driver cannot actually classify as
    # permanent. FLEET_BOARD_MAX_ATTEMPTS's dead-letter is the backstop for
    # a failure that is genuinely permanent but misclassified here.
    echo "linear.sh apply: update_issue failed for ${tid}/${event} — transient" >&2
    return 1
  fi

  return 0
}

# ── CLI entrypoint ───────────────────────────────────────────────────────
case "${1:-}" in
apply)
  shift
  _linear_driver_apply "$@"
  ;;
*)
  echo "Usage: linear.sh apply <TID> <EVENT> <SEQ> <JSON_DATA>" >&2
  exit 1
  ;;
esac
