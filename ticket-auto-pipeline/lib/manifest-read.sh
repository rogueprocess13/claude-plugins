#!/usr/bin/env bash
# manifest-read.sh — shared local-manifest read helpers (Track B Phase B3a,
# tracker-local-facts-read-migration). Sourceable bash library. Does NOT set
# -euo pipefail (caller controls error handling).
#
# Every call site migrated by this change reads ticket/epic classification
# and routing state through get_ticket_manifest_field/get_epic_manifest_field
# instead of independently parsing manifest.json — see
# specs/ticket-local-manifest "A single shared library backs every manifest
# read".
#
# Layout (written by manifest-write.sh, ticket-planner-side):
#   $REPOS_ROOT/.ticket-auto/initiatives/{INIT}/tickets/{TID}/planner/manifest.json
#   $REPOS_ROOT/.ticket-auto/initiatives/{EPIC}/epic/manifest.json
#   $REPOS_ROOT/.ticket-auto/initiatives/_index/{TID}.initiative   (one line: INIT id)
#
# Note: an epic IS an initiative in this codebase (fleet-dispatch.sh and
# friends already treat initiative_id/epic identifier interchangeably), so
# the epic manifest lives directly under initiatives/{EPIC}/, not behind a
# second index.
#
# Exit codes (get_ticket_manifest_field / get_epic_manifest_field):
#   0 — read succeeded (field value printed; empty output for an absent
#       field is a normal, valid outcome — see ticket-local-manifest spec's
#       "fields are overwritten, not appended" — absence is not an error)
#   1 — no manifest file for this ticket/epic (distinct from field-absent —
#       ticket-local-manifest spec's "missing manifest is reported, not
#       silently treated as not planned")
#   2 — manifest file exists but failed to parse as JSON (malformed)
#   3 — REPOS_ROOT unset, or an invalid ticket/epic/initiative ID shape
#
# Callers that need to distinguish "no manifest" from "field absent" must
# check the exit code — never assume empty output means "not planned".

# Leading `_` is allowed (and only meaningful) on an initiative name — the
# reserved `_adhoc` initiative (tracker-approval-by-script) must pass this
# same check every ordinary ticket/epic/initiative ID does.
_MANIFEST_ID_RE='^_?[A-Za-z0-9][-A-Za-z0-9]*$'

# _manifest_repos_root — prints REPOS_ROOT or returns 3
#
# tracker-local-facts-read-migration (task 9.1): TICKET_LOCAL_MANIFEST_DISABLE
# kill switch, centralized here rather than at every call site. Every read
# function in this file (and manifest-write.sh, which sources it) resolves
# REPOS_ROOT through this one function, so failing closed here uniformly
# makes every migrated caller behave exactly as it does for "REPOS_ROOT
# unset" — which every one of them already treats as "no manifest, fall
# back to the pre-migration live path" rather than an error. One flag,
# every site, no per-site changes.
_manifest_repos_root() {
  [ "${TICKET_LOCAL_MANIFEST_DISABLE:-false}" = "true" ] && return 3
  local repos_root="${REPOS_ROOT:-}"
  [ -n "$repos_root" ] || return 3
  echo "$repos_root"
}

# _manifest_initiative_for_ticket <TID>
# Looks up {INIT} for a ticket from the local initiative index.
# Exit 0 → prints INIT, 1 → no index entry, 3 → REPOS_ROOT unset.
#
# An initiative name beginning with `_` (e.g. the reserved `_adhoc`
# initiative ensure_ticket_manifest in manifest-write.sh creates for a
# ticket with no planner-assigned initiative) needs no special-casing
# here — it resolves through the exact same path lookup as any other
# initiative name. The underscore prefix only matters to enumerators that
# walk `initiatives/*` looking for dispatchable work; every such enumerator
# skips underscore-prefixed directories (tracker-approval-by-script).
_manifest_initiative_for_ticket() {
  local tid="$1"
  local repos_root
  repos_root=$(_manifest_repos_root) || return 3

  local idx="$repos_root/.ticket-auto/initiatives/_index/${tid}.initiative"
  [ -f "$idx" ] || return 1

  local init
  init=$(head -1 "$idx" 2>/dev/null | tr -d '[:space:]')
  [ -n "$init" ] || return 1
  echo "$init"
}

# _manifest_read_field <manifest_path> <field>
# Shared jq read: distinguishes absent field (exit 0, empty output) from
# malformed JSON (exit 2). `has($f)` is used rather than `//` so an explicit
# `false` value is never coerced into "absent" (jq's `//` treats `false` and
# `null` as falsy, which would silently corrupt a `dispatch: false` read).
_manifest_read_field() {
  local manifest_path="$1" field="$2"

  if ! jq -e . "$manifest_path" >/dev/null 2>&1; then
    echo "manifest-read: malformed JSON in $manifest_path" >&2
    return 2
  fi

  jq -r --arg f "$field" 'if has($f) then (.[$f] | tostring) else empty end' "$manifest_path"
  return 0
}

# get_ticket_manifest_field <TID> <field>
get_ticket_manifest_field() {
  local tid="$1" field="$2"
  local repos_root
  repos_root=$(_manifest_repos_root) || return 3

  if ! [[ "$tid" =~ $_MANIFEST_ID_RE ]]; then
    echo "manifest-read: invalid ticket ID '$tid'" >&2
    return 3
  fi

  local init init_rc=0
  init=$(_manifest_initiative_for_ticket "$tid") || init_rc=$?
  [ "$init_rc" -eq 0 ] || return "$init_rc"

  if ! [[ "$init" =~ $_MANIFEST_ID_RE ]]; then
    echo "manifest-read: invalid initiative value '$init' for $tid" >&2
    return 3
  fi

  local manifest_path="$repos_root/.ticket-auto/initiatives/$init/tickets/$tid/planner/manifest.json"
  [ -f "$manifest_path" ] || return 1

  _manifest_read_field "$manifest_path" "$field"
}

# get_epic_manifest_field <EPIC> <field>
get_epic_manifest_field() {
  local epic="$1" field="$2"
  local repos_root
  repos_root=$(_manifest_repos_root) || return 3

  if ! [[ "$epic" =~ $_MANIFEST_ID_RE ]]; then
    echo "manifest-read: invalid epic ID '$epic'" >&2
    return 3
  fi

  local manifest_path="$repos_root/.ticket-auto/initiatives/$epic/epic/manifest.json"
  [ -f "$manifest_path" ] || return 1

  _manifest_read_field "$manifest_path" "$field"
}

# ticket_manifest_exists <TID> — exit 0 if a ticket manifest file exists.
ticket_manifest_exists() {
  local tid="$1"
  local repos_root
  repos_root=$(_manifest_repos_root) || return 3
  [[ "$tid" =~ $_MANIFEST_ID_RE ]] || return 3

  local init
  init=$(_manifest_initiative_for_ticket "$tid") || return $?
  [[ "$init" =~ $_MANIFEST_ID_RE ]] || return 3

  [ -f "$repos_root/.ticket-auto/initiatives/$init/tickets/$tid/planner/manifest.json" ]
}

# epic_manifest_exists <EPIC> — exit 0 if an epic manifest file exists.
epic_manifest_exists() {
  local epic="$1"
  local repos_root
  repos_root=$(_manifest_repos_root) || return 3
  [[ "$epic" =~ $_MANIFEST_ID_RE ]] || return 3

  [ -f "$repos_root/.ticket-auto/initiatives/$epic/epic/manifest.json" ]
}

# get_ticket_manifest_path <TID> — prints the ticket manifest path whether
# or not it exists yet (for writers). Exit 1 if no initiative index entry.
get_ticket_manifest_path() {
  local tid="$1"
  local repos_root
  repos_root=$(_manifest_repos_root) || return 3
  [[ "$tid" =~ $_MANIFEST_ID_RE ]] || return 3

  local init
  init=$(_manifest_initiative_for_ticket "$tid") || return $?
  [[ "$init" =~ $_MANIFEST_ID_RE ]] || return 3

  echo "$repos_root/.ticket-auto/initiatives/$init/tickets/$tid/planner/manifest.json"
}

# get_epic_manifest_path <EPIC> — prints the epic manifest path whether or
# not it exists yet (for writers).
get_epic_manifest_path() {
  local epic="$1"
  local repos_root
  repos_root=$(_manifest_repos_root) || return 3
  [[ "$epic" =~ $_MANIFEST_ID_RE ]] || return 3

  echo "$repos_root/.ticket-auto/initiatives/$epic/epic/manifest.json"
}

# ticket_pipeline_terminal_done <TID> [workspace]
# True when TID's own pipeline log shows a genuinely completed ("Done")
# terminal outcome — never a live tracker fetch. Mirrors pipeline-
# finalize.sh's "completed: STEP_6" outcome message, the only outcome shape
# that means the ticket actually reached Done (held:/stopped:/dead-letter
# are all non-Done terminals or non-terminal holds). No pipeline log at all
# (not yet started) is treated as unsatisfied, per ticket-local-manifest
# spec's "blocker with no pipeline log yet is unsatisfied". The single
# shared implementation of this check — ticket-auto-pipeline's
# epic_branch_children_done and fleet-controller's detect_blocked_by/
# detect_initiative_dispatch (tracker-local-facts-read-migration) all call
# this rather than re-deriving "is it Done" independently.
ticket_pipeline_terminal_done() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local log_file="$workspace/${tid}-pipeline.log"
  [ -f "$log_file" ] || return 1

  local last_outcome
  last_outcome=$(grep '|META|outcome|info|' "$log_file" 2>/dev/null | tail -1 |
    awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}')
  [ -n "$last_outcome" ] || return 1

  case "$last_outcome" in
  "completed:"*) return 0 ;;
  *) return 1 ;;
  esac
}

# ── Self-test mode ────────────────────────────────────────────────────────

if [ "${1:-}" = "--self-test" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "Running self-tests..."
  tmp=$(mktemp -d)
  export REPOS_ROOT="$tmp"

  mkdir -p "$tmp/.ticket-auto/initiatives/_index"
  mkdir -p "$tmp/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner"
  mkdir -p "$tmp/.ticket-auto/initiatives/INIT-1/epic"
  echo "INIT-1" >"$tmp/.ticket-auto/initiatives/_index/TEST-1.initiative"
  echo '{"type":"bug","initiative":"INIT-1","blocked_by":[],"dispatch":false}' \
    >"$tmp/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"
  echo '{"branch":"epic/init-1","uat_policy":"epic","merge_policy":"manual","children":["TEST-1"]}' \
    >"$tmp/.ticket-auto/initiatives/INIT-1/epic/manifest.json"

  [ "$(get_ticket_manifest_field TEST-1 type)" = "bug" ] && echo "✓ ticket field read" || echo "✗ ticket field read"
  [ "$(get_ticket_manifest_field TEST-1 dispatch)" = "false" ] && echo "✓ explicit false preserved" || echo "✗ explicit false lost"
  get_ticket_manifest_field TEST-1 outcome_label >/dev/null
  [ "$?" = "0" ] && echo "✓ absent field is exit 0" || echo "✗ absent field should be exit 0"
  get_ticket_manifest_field NOPE-1 type >/dev/null 2>&1
  [ "$?" = "1" ] && echo "✓ missing manifest is exit 1" || echo "✗ missing manifest should be exit 1"
  [ "$(get_epic_manifest_field INIT-1 branch)" = "epic/init-1" ] && echo "✓ epic field read" || echo "✗ epic field read"

  echo 'not json' >"$tmp/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"
  get_ticket_manifest_field TEST-1 type >/dev/null 2>&1
  [ "$?" = "2" ] && echo "✓ malformed JSON is exit 2" || echo "✗ malformed JSON should be exit 2"

  rm -rf "$tmp"
  echo "Self-tests complete — run test-manifest-read.sh for full coverage."
  exit 0
fi
