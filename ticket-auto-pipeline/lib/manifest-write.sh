#!/usr/bin/env bash
# manifest-write.sh — shared local-manifest write helpers (Track B Phase B3a,
# tracker-local-facts-read-migration). Sourceable bash library. Does NOT set
# -euo pipefail (caller controls error handling).
#
# Writers only — see manifest-read.sh for the read contract every migrated
# call site uses. This file is the only place manifest.json / epic
# manifest.json / the initiative index are ever created or mutated, mirroring
# manifest-read.sh's "one read implementation" discipline on the write side.
#
# Manifests are a current-state snapshot, not an event log: fields are
# overwritten in place on refresh, never appended (ticket-local-manifest
# spec). All writes are atomic (write to .tmp, then mv) to avoid a reader
# ever observing a partially-written file.
#
# Note: the per-ticket planner artifact directory
# (`tickets/{TID}/planner/`) is NOT pre-created by ticket-planner today —
# confirmed by direct inspection: body.md/exploration.md are never written
# anywhere, and proposal.md exists only at the initiative level, not
# per-ticket (see design.md's context section, which assumed otherwise).
# write_ticket_manifest therefore creates the directory itself rather than
# assuming planner-artifacts.sh's resolve_planner_dir already found one.

_MANIFEST_WRITE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_MANIFEST_WRITE_LIB_DIR/manifest-read.sh"

# _manifest_atomic_write <path> <content>
# Writes content to <path> via a same-directory .tmp file + mv, so a
# concurrent reader never observes a truncated/partial file.
_manifest_atomic_write() {
  local path="$1" content="$2"
  local dir
  dir=$(dirname "$path")
  mkdir -p "$dir" || return 1
  local tmp="$dir/.$(basename "$path").tmp.$$"
  printf '%s\n' "$content" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$path"
}

# write_initiative_index <TID> <INIT>
# Writes/updates the {TID}.initiative index entry. Idempotent.
write_initiative_index() {
  local tid="$1" init="$2"
  local repos_root
  repos_root=$(_manifest_repos_root) || return 3
  [[ "$tid" =~ $_MANIFEST_ID_RE ]] || {
    echo "manifest-write: invalid ticket ID '$tid'" >&2
    return 3
  }
  [[ "$init" =~ $_MANIFEST_ID_RE ]] || {
    echo "manifest-write: invalid initiative '$init'" >&2
    return 3
  }

  _manifest_atomic_write "$repos_root/.ticket-auto/initiatives/_index/${tid}.initiative" "$init"
}

# write_ticket_manifest <TID> <INIT> <TYPE> [blocked_by_json_array]
# Writes the ticket manifest at planning time. `dispatch` starts false,
# `outcome_label` starts absent (per ticket-local-manifest spec). Also
# writes the initiative index entry in the same operation (spec: "Index
# entry is written at the same time as the manifest").
write_ticket_manifest() {
  local tid="$1" init="$2" type="$3" blocked_by="${4:-[]}"
  local repos_root
  repos_root=$(_manifest_repos_root) || return 3
  [[ "$tid" =~ $_MANIFEST_ID_RE ]] || {
    echo "manifest-write: invalid ticket ID '$tid'" >&2
    return 3
  }
  [[ "$init" =~ $_MANIFEST_ID_RE ]] || {
    echo "manifest-write: invalid initiative '$init'" >&2
    return 3
  }

  if ! echo "$blocked_by" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "manifest-write: blocked_by must be a JSON array, got '$blocked_by'" >&2
    return 3
  fi

  write_initiative_index "$tid" "$init" || return 1

  local manifest_path="$repos_root/.ticket-auto/initiatives/$init/tickets/$tid/planner/manifest.json"
  local content
  content=$(jq -nc \
    --arg type "$type" --arg init "$init" --argjson blocked_by "$blocked_by" \
    '{type: $type, initiative: $init, blocked_by: $blocked_by, dispatch: false}') || return 1

  _manifest_atomic_write "$manifest_path" "$content"
}

# write_epic_manifest <EPIC> <BRANCH> <UAT_POLICY> <MERGE_POLICY> [children_json_array]
# Writes the epic manifest at epic-creation time (or on drift-refresh from
# ensure_epic_branch). `children` defaults to empty — Ticket Gen appends to
# it as children are created via add_epic_manifest_child.
write_epic_manifest() {
  local epic="$1" branch="$2" uat_policy="$3" merge_policy="$4" children="${5:-}"
  local repos_root
  repos_root=$(_manifest_repos_root) || return 3
  [[ "$epic" =~ $_MANIFEST_ID_RE ]] || {
    echo "manifest-write: invalid epic ID '$epic'" >&2
    return 3
  }

  # Preserve existing children[] on refresh unless explicitly overridden —
  # ensure_epic_branch's drift-refresh (task 2.3) rewrites branch/uat/merge
  # without truncating a children list Ticket Gen has been appending to.
  if [ -z "$children" ]; then
    children=$(get_epic_manifest_field "$epic" children 2>/dev/null)
    [ -n "$children" ] || children='[]'
  fi

  if ! echo "$children" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "manifest-write: children must be a JSON array, got '$children'" >&2
    return 3
  fi

  local manifest_path="$repos_root/.ticket-auto/initiatives/$epic/epic/manifest.json"
  local content
  content=$(jq -nc \
    --arg branch "$branch" --arg uat "$uat_policy" --arg merge "$merge_policy" \
    --argjson children "$children" \
    '{branch: $branch, uat_policy: $uat, merge_policy: $merge, children: $children}') || return 1

  _manifest_atomic_write "$manifest_path" "$content"
}

# add_epic_manifest_child <EPIC> <CHILD_TID>
# Appends CHILD_TID to the epic manifest's children[] if not already present.
# Idempotent. No-op (exit 1) if the epic manifest doesn't exist yet.
add_epic_manifest_child() {
  local epic="$1" child="$2"
  local repos_root
  repos_root=$(_manifest_repos_root) || return 3
  [[ "$epic" =~ $_MANIFEST_ID_RE ]] || return 3
  [[ "$child" =~ $_MANIFEST_ID_RE ]] || return 3

  local manifest_path="$repos_root/.ticket-auto/initiatives/$epic/epic/manifest.json"
  [ -f "$manifest_path" ] || return 1

  local content
  content=$(jq -c --arg child "$child" \
    '.children = ((.children // []) + [$child] | unique)' \
    "$manifest_path") || return 1

  _manifest_atomic_write "$manifest_path" "$content"
}

# stamp_ticket_dispatch <TID>
# One-way false→true stamp (ticket-local-manifest spec: "dispatch does not
# revert"). No-op if already true or if no manifest exists yet (the missing-
# manifest fallback in callers handles that case via live fetch instead).
stamp_ticket_dispatch() {
  local tid="$1"
  local manifest_path
  manifest_path=$(get_ticket_manifest_path "$tid" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  local current
  current=$(get_ticket_manifest_field "$tid" dispatch 2>/dev/null)
  [ "$current" = "true" ] && return 0

  local content
  content=$(jq -c '.dispatch = true' "$manifest_path") || return 1
  _manifest_atomic_write "$manifest_path" "$content"
}

# stamp_epic_dispatch <EPIC>
# One-way false→true stamp on the epic manifest, mirroring the
# `state:execution` label's semantics exactly. No-op if already true or no
# manifest exists yet.
stamp_epic_dispatch() {
  local epic="$1"
  local manifest_path
  manifest_path=$(get_epic_manifest_path "$epic" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  local current
  current=$(get_epic_manifest_field "$epic" dispatch 2>/dev/null)
  [ "$current" = "true" ] && return 0

  local content
  content=$(jq -c '.dispatch = true' "$manifest_path") || return 1
  _manifest_atomic_write "$manifest_path" "$content"
}

# write_ticket_outcome_label <TID> <Smooth|Rough|Hard>
# Mirrors the Smooth/Rough/Hard tracker label locally (ticket-local-manifest
# spec: "outcome_label mirrors the Smooth/Rough/Hard classification
# locally"). No-op (exit 1) if no manifest exists yet.
write_ticket_outcome_label() {
  local tid="$1" outcome="$2"
  case "$outcome" in
  Smooth | Rough | Hard) ;;
  *)
    echo "manifest-write: invalid outcome_label '$outcome' (expected Smooth|Rough|Hard)" >&2
    return 3
    ;;
  esac

  local manifest_path
  manifest_path=$(get_ticket_manifest_path "$tid" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  local content
  content=$(jq -c --arg o "$outcome" '.outcome_label = $o' "$manifest_path") || return 1
  _manifest_atomic_write "$manifest_path" "$content"
}

# ensure_ticket_manifest <TID>
# Makes TID manifest-addressable before any manifest write (tracker-
# approval-by-script). A ticket created outside the planner has no
# initiative index entry, so get_ticket_manifest_path/every write helper
# would otherwise no-op on it forever. Resolves the existing initiative via
# _manifest_initiative_for_ticket; when absent, writes the reserved
# `_adhoc` initiative index entry instead (initiative names beginning with
# `_` are skipped by every initiative/epic enumerator — see
# _manifest_initiative_for_ticket's doc comment). When no manifest file
# exists yet at the resolved path, creates a minimal one
# ({"type":null,"initiative":null,"blocked_by":[],"dispatch":false}).
# Idempotent — a second call makes no change. Returns 0 on success,
# non-zero only on a genuine write failure.
ensure_ticket_manifest() {
  local tid="$1"
  [[ "$tid" =~ $_MANIFEST_ID_RE ]] || {
    echo "manifest-write: invalid ticket ID '$tid'" >&2
    return 3
  }

  local init init_rc=0
  init=$(_manifest_initiative_for_ticket "$tid") || init_rc=$?
  if [ "$init_rc" -eq 3 ]; then
    return 3
  elif [ "$init_rc" -ne 0 ] || [ -z "$init" ]; then
    write_initiative_index "$tid" "_adhoc" || return 1
    init="_adhoc"
  fi

  local manifest_path
  manifest_path=$(get_ticket_manifest_path "$tid") || return 1
  [ -f "$manifest_path" ] && return 0

  _manifest_atomic_write "$manifest_path" \
    '{"type":null,"initiative":null,"blocked_by":[],"dispatch":false}'
}

# set_ticket_stage <TID> <STAGE>
# Writes the manifest's `stage` field — the destination of the most recent
# transition that declared one (tracker-approval-by-script). Single
# _manifest_atomic_write, same shape as write_ticket_outcome_label. No-op
# (exit 1) if no manifest exists yet — callers write via flow.sh, which
# calls ensure_ticket_manifest first.
set_ticket_stage() {
  local tid="$1" stage="$2"
  [ -n "$stage" ] || {
    echo "manifest-write: stage must be non-empty" >&2
    return 3
  }

  local manifest_path
  manifest_path=$(get_ticket_manifest_path "$tid" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  local content
  content=$(jq -c --arg s "$stage" '.stage = $s' "$manifest_path") || return 1
  _manifest_atomic_write "$manifest_path" "$content"
}

# set_epic_stage <EPIC_ID> <STAGE>
# Same as set_ticket_stage but for the epic manifest.
set_epic_stage() {
  local epic="$1" stage="$2"
  [ -n "$stage" ] || {
    echo "manifest-write: stage must be non-empty" >&2
    return 3
  }

  local manifest_path
  manifest_path=$(get_epic_manifest_path "$epic" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  local content
  content=$(jq -c --arg s "$stage" '.stage = $s' "$manifest_path") || return 1
  _manifest_atomic_write "$manifest_path" "$content"
}

# set_ticket_approval <TID> <true|false> [provenance]
# Writes approved/approval_provenance to the manifest — the authoritative
# approval decision fact as of tracker-approval-by-script (superseding B4's
# "informational only" stance, whose premise no longer holds once a script
# is the sole approval actuator; see ticket-local-manifest spec). Setting
# approved=true requires a provenance of human|policy. Setting
# approved=false clears both fields (removed, not just falsed) so a stale
# provenance value never survives a clear (re-claim/ticket-reject's
# clear-on-removal path). No-op (exit 1) if no manifest exists yet — callers
# call ensure_ticket_manifest first.
set_ticket_approval() {
  local tid="$1" approved="$2" provenance="${3:-}"
  case "$approved" in
  true | false) ;;
  *)
    echo "manifest-write: invalid approved value '$approved' (expected true|false)" >&2
    return 3
    ;;
  esac

  local manifest_path
  manifest_path=$(get_ticket_manifest_path "$tid" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  local content
  if [ "$approved" = "true" ]; then
    case "$provenance" in
    human | policy) ;;
    *)
      echo "manifest-write: invalid provenance '$provenance' (expected human|policy)" >&2
      return 3
      ;;
    esac
    content=$(jq -c --arg p "$provenance" '.approved = true | .approval_provenance = $p' "$manifest_path") || return 1
  else
    content=$(jq -c 'del(.approved, .approval_provenance)' "$manifest_path") || return 1
  fi
  _manifest_atomic_write "$manifest_path" "$content"
}

# ── Self-test mode ────────────────────────────────────────────────────────

if [ "${1:-}" = "--self-test" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "Running self-tests..."
  tmp=$(mktemp -d)
  export REPOS_ROOT="$tmp"

  write_ticket_manifest "TEST-1" "INIT-1" "bug" '["TEST-0"]'
  [ "$(get_ticket_manifest_field TEST-1 type)" = "bug" ] && echo "✓ write_ticket_manifest" || echo "✗ write_ticket_manifest"
  [ -f "$tmp/.ticket-auto/initiatives/_index/TEST-1.initiative" ] && echo "✓ initiative index written" || echo "✗ initiative index missing"

  write_epic_manifest "INIT-1" "epic/init-1" "epic" "manual" '[]'
  [ "$(get_epic_manifest_field INIT-1 branch)" = "epic/init-1" ] && echo "✓ write_epic_manifest" || echo "✗ write_epic_manifest"

  add_epic_manifest_child "INIT-1" "TEST-1"
  add_epic_manifest_child "INIT-1" "TEST-1"
  children=$(get_epic_manifest_field INIT-1 children)
  [ "$(echo "$children" | jq 'length')" = "1" ] && echo "✓ add_epic_manifest_child idempotent" || echo "✗ add_epic_manifest_child should be idempotent"

  stamp_ticket_dispatch "TEST-1"
  [ "$(get_ticket_manifest_field TEST-1 dispatch)" = "true" ] && echo "✓ stamp_ticket_dispatch" || echo "✗ stamp_ticket_dispatch"

  write_ticket_outcome_label "TEST-1" "Smooth"
  [ "$(get_ticket_manifest_field TEST-1 outcome_label)" = "Smooth" ] && echo "✓ write_ticket_outcome_label" || echo "✗ write_ticket_outcome_label"

  write_ticket_outcome_label "TEST-1" "Bogus" 2>/dev/null
  [ "$?" = "3" ] && echo "✓ invalid outcome_label rejected" || echo "✗ invalid outcome_label should be rejected"

  set_ticket_approval "TEST-1" "true" "human"
  [ "$(get_ticket_manifest_field TEST-1 approved)" = "true" ] && [ "$(get_ticket_manifest_field TEST-1 approval_provenance)" = "human" ] && echo "✓ set_ticket_approval true" || echo "✗ set_ticket_approval true"

  set_ticket_approval "TEST-1" "false"
  approved_after_clear=$(get_ticket_manifest_field TEST-1 approved)
  [ -z "$approved_after_clear" ] && echo "✓ set_ticket_approval clear" || echo "✗ set_ticket_approval clear should remove field"

  set_ticket_stage "TEST-1" "Ready"
  [ "$(get_ticket_manifest_field TEST-1 stage)" = "Ready" ] && echo "✓ set_ticket_stage" || echo "✗ set_ticket_stage"

  set_epic_stage "INIT-1" "Review"
  [ "$(get_epic_manifest_field INIT-1 stage)" = "Review" ] && echo "✓ set_epic_stage" || echo "✗ set_epic_stage"

  ensure_ticket_manifest "TEST-1"
  [ "$(get_ticket_manifest_field TEST-1 type)" = "bug" ] && echo "✓ ensure_ticket_manifest is a no-op on an existing manifest" || echo "✗ ensure_ticket_manifest should not touch an existing manifest"

  ensure_ticket_manifest "ADHOC-1"
  [ "$(get_ticket_manifest_field ADHOC-1 dispatch)" = "false" ] && echo "✓ ensure_ticket_manifest creates an ad-hoc manifest" || echo "✗ ensure_ticket_manifest should create an ad-hoc manifest"
  [ "$(cat "$tmp/.ticket-auto/initiatives/_index/ADHOC-1.initiative")" = "_adhoc" ] && echo "✓ ensure_ticket_manifest reserves _adhoc initiative" || echo "✗ ensure_ticket_manifest should reserve _adhoc initiative"

  ensure_ticket_manifest "ADHOC-1"
  [ "$(get_ticket_manifest_field ADHOC-1 dispatch)" = "false" ] && echo "✓ ensure_ticket_manifest is idempotent on an ad-hoc ticket" || echo "✗ ensure_ticket_manifest should be idempotent"

  rm -rf "$tmp"
  echo "Self-tests complete — run test-manifest-write.sh for full coverage."
  exit 0
fi
