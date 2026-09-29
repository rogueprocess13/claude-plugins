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

# backfill_ticket_fields <TID> <TYPE> <INITIATIVE> <BLOCKED_BY_JSON> <FLAGS_JSON>
# tracker-planner-and-fallback-cutover (2.1): one-shot seed of type/
# initiative/blocked_by/flags from the tracker's live labels — the last
# time any of the four is ever read. Partial update onto whatever manifest
# ensure_ticket_manifest already made addressable; never recreates the
# manifest (write_ticket_manifest would, discarding a stage/approved value
# a prior step of the same backfill run — or ordinary pipeline operation —
# already wrote). TYPE/INITIATIVE are left untouched when empty, so a live
# ticket with no matching type label or no INIT-* label doesn't overwrite
# an existing (possibly correct) value with nothing; BLOCKED_BY_JSON and
# FLAGS_JSON are always written, including empty, since an empty array IS
# the live answer ("no blockers/flags right now"), not a missing one.
# No-op (exit 1) if no manifest exists yet.
backfill_ticket_fields() {
  local tid="$1" type="$2" init="$3" blocked_by="${4:-[]}" flags="${5:-[]}"
  local manifest_path
  manifest_path=$(get_ticket_manifest_path "$tid" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  if ! echo "$blocked_by" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "manifest-write: blocked_by must be a JSON array, got '$blocked_by'" >&2
    return 3
  fi
  if ! echo "$flags" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "manifest-write: flags must be a JSON array, got '$flags'" >&2
    return 3
  fi

  local content
  content=$(jq -c \
    --arg type "$type" --arg init "$init" \
    --argjson blocked_by "$blocked_by" --argjson flags "$(echo "$flags" | jq -c 'sort')" \
    '(if $type != "" then .type = $type else . end)
     | (if $init != "" then .initiative = $init else . end)
     | .blocked_by = $blocked_by
     | .flags = $flags' \
    "$manifest_path") || return 1
  _manifest_atomic_write "$manifest_path" "$content"
}

# backfill_epic_manifest <EPIC> <BRANCH> <UAT_POLICY> <MERGE_POLICY> <CHILDREN_JSON>
# tracker-planner-and-fallback-cutover (2.1): one-shot seed of an epic
# manifest — including the `dispatch` stamp — from the tracker's live
# `state:execution` label and Branch Directive, for an epic planned before
# the manifest era ever wrote one. Thin wrapper composing write_epic_manifest
# (creates/refreshes branch/uat_policy/merge_policy/children) with
# stamp_epic_dispatch (one-way false→true, mirroring the label's semantics
# exactly) — no new manifest shape, just the two existing writers called
# together for the caller's convenience. BRANCH may be empty (an epic with
# no directive still needs its `dispatch`/`children` stamped for D-11/D-18
# to enumerate it; D-12 already treats an empty `branch` field as "no
# directive, skip" — same as the live path's description grep did).
backfill_epic_manifest() {
  local epic="$1" branch="$2" uat_policy="$3" merge_policy="$4" children="${5:-[]}"
  write_epic_manifest "$epic" "$branch" "$uat_policy" "$merge_policy" "$children" || return 1
  stamp_epic_dispatch "$epic"
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

# set_ticket_transition <TID> <STAGE> <FLAGS_JSON> <PENDING_JSON>
# The transition executor's one write (tracker-flow-projection-cutover):
# `stage`, `flags` (sorted), `rev` (current + 1) and `pending_event` land in
# a single atomic write so no reader ever observes a stage that does not
# match its flags. FLAGS_JSON must be a JSON array of strings. PENDING_JSON
# is either a JSON object (the event about to be emitted) or an empty string
# to clear `pending_event`. No-op (exit 1) if no manifest exists yet —
# callers call ensure_ticket_manifest first.
set_ticket_transition() {
  local tid="$1" stage="$2" flags="$3" pending="${4:-}"
  # An empty stage means "leave stage as it currently is" — a trigger
  # declaring to:null on a ticket that has never had a stage set at all
  # (e.g. needs-info hand-applied to an ad-hoc ticket before appraise-start
  # ever ran) must not be forced to invent one. rev/flags/pending_event
  # still advance; only the stage field is conditionally skipped.
  if ! echo "$flags" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "manifest-write: flags must be a JSON array, got '$flags'" >&2
    return 3
  fi
  if [ -n "$pending" ] && ! echo "$pending" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "manifest-write: pending_event must be a JSON object, got '$pending'" >&2
    return 3
  fi

  local manifest_path
  manifest_path=$(get_ticket_manifest_path "$tid" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  local current_rev next_rev
  current_rev=$(get_ticket_manifest_field "$tid" rev 2>/dev/null)
  [[ "$current_rev" =~ ^[0-9]+$ ]] || current_rev=0
  next_rev=$((current_rev + 1))

  local stage_filter='.'
  [ -n "$stage" ] && stage_filter='.stage = $s'

  local content
  if [ -n "$pending" ]; then
    content=$(jq -c --arg s "$stage" --argjson flags "$(echo "$flags" | jq -c 'sort')" \
      --argjson rev "$next_rev" --argjson pending "$pending" \
      "$stage_filter"' | .flags = $flags | .rev = $rev | .pending_event = $pending' \
      "$manifest_path") || return 1
  else
    content=$(jq -c --arg s "$stage" --argjson flags "$(echo "$flags" | jq -c 'sort')" \
      --argjson rev "$next_rev" \
      "$stage_filter"' | .flags = $flags | .rev = $rev | del(.pending_event)' \
      "$manifest_path") || return 1
  fi
  _manifest_atomic_write "$manifest_path" "$content"
}

# clear_pending_event <TID>
# Single atomic write removing `pending_event` once its emission has
# returned (tracker-flow-projection-cutover). No-op (exit 1) if no manifest
# exists yet.
clear_pending_event() {
  local tid="$1"
  local manifest_path
  manifest_path=$(get_ticket_manifest_path "$tid" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  local content
  content=$(jq -c 'del(.pending_event)' "$manifest_path") || return 1
  _manifest_atomic_write "$manifest_path" "$content"
}

# set_epic_transition <EPIC> <STAGE> <FLAGS_JSON> <PENDING_JSON>
# Epic-manifest equivalent of set_ticket_transition.
set_epic_transition() {
  local epic="$1" stage="$2" flags="$3" pending="${4:-}"
  # See set_ticket_transition's identical comment — an empty stage means
  # "leave stage as it currently is".
  if ! echo "$flags" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "manifest-write: flags must be a JSON array, got '$flags'" >&2
    return 3
  fi
  if [ -n "$pending" ] && ! echo "$pending" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "manifest-write: pending_event must be a JSON object, got '$pending'" >&2
    return 3
  fi

  local manifest_path
  manifest_path=$(get_epic_manifest_path "$epic" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  local current_rev next_rev
  current_rev=$(get_epic_manifest_field "$epic" rev 2>/dev/null)
  [[ "$current_rev" =~ ^[0-9]+$ ]] || current_rev=0
  next_rev=$((current_rev + 1))

  local stage_filter='.'
  [ -n "$stage" ] && stage_filter='.stage = $s'

  local content
  if [ -n "$pending" ]; then
    content=$(jq -c --arg s "$stage" --argjson flags "$(echo "$flags" | jq -c 'sort')" \
      --argjson rev "$next_rev" --argjson pending "$pending" \
      "$stage_filter"' | .flags = $flags | .rev = $rev | .pending_event = $pending' \
      "$manifest_path") || return 1
  else
    content=$(jq -c --arg s "$stage" --argjson flags "$(echo "$flags" | jq -c 'sort')" \
      --argjson rev "$next_rev" \
      "$stage_filter"' | .flags = $flags | .rev = $rev | del(.pending_event)' \
      "$manifest_path") || return 1
  fi
  _manifest_atomic_write "$manifest_path" "$content"
}

# clear_epic_pending_event <EPIC>
clear_epic_pending_event() {
  local epic="$1"
  local manifest_path
  manifest_path=$(get_epic_manifest_path "$epic" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  local content
  content=$(jq -c 'del(.pending_event)' "$manifest_path") || return 1
  _manifest_atomic_write "$manifest_path" "$content"
}

# ── Readiness lock (blocking flock, FD 200) ─────────────────────────────────
# Serializes set_ticket_readiness/waive_ticket_readiness_code's
# read-modify-write on a per-ticket `{manifest_path}.lock` file
# (dor-readiness-gate-foundation). FD 200 is deliberately distinct from
# every flock FD already in use in this codebase (events.sh FD 7,
# board-cursor.sh/run-summary.sh FD 8, adr-store.sh/corrections-parse.sh/
# guidance-store.sh/verify-lock.sh/flow.sh FD 9) because flow.sh holds FD 9
# open for its own ticket-flow lock for its entire process lifetime, not
# transiently like the other FD-9 users above — reusing 9 here would
# silently steal and then close flow.sh's own lock the instant either
# readiness writer runs inside the same sourced shell.
_manifest_readiness_lock() {
  local lock_file="$1"
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
  exec 200>"$lock_file" || {
    echo "manifest-write: failed to open lock file ${lock_file}" >&2
    return 1
  }
  if ! flock -w "${MANIFEST_LOCK_TIMEOUT_SECS:-15}" 200; then
    echo "manifest-write: lock timeout acquiring readiness lock (${lock_file})" >&2
    exec 200>&-
    return 1
  fi
}

# _manifest_readiness_unlock — releases the lock acquired by
# _manifest_readiness_lock.
_manifest_readiness_unlock() {
  exec 200>&- 2>/dev/null || true
}

# set_ticket_readiness <TID> <status|ready|not-ready> <missing_json> <advisory_json>
# Writes a freshly computed readiness verdict (ticket-local-manifest spec).
# Deliberately takes no `waived` argument: it always reads the manifest's
# current `ready.waived` (defaulting to `{}` if absent), writes it back
# verbatim alongside the fresh `missing`/`advisory`/`checked_at`, and
# recomputes `status` itself as `ready` iff every code in the new `missing`
# list is a key of that *preserved* `waived` map — the caller's own `status`
# argument is validated but never trusted, since it was computed with no
# knowledge of any waiver. It is structurally impossible for a re-scan to
# clear a waiver because this function never receives one (design.md
# Decision 2, revised 2026-09-27 — the original draft's single `[waived_json]`
# parameter let a re-scan silently clobber an operator's waiver). Serializes
# under the readiness lock with waive_ticket_readiness_code so the two
# writers cannot lose one another's update. No-op (exit 1) if no manifest
# exists yet — callers call ensure_ticket_manifest first.
set_ticket_readiness() {
  local tid="$1" status="$2" missing="${3:-[]}" advisory="${4:-[]}"
  case "$status" in
  ready | not-ready) ;;
  *)
    echo "manifest-write: invalid readiness status '$status' (expected ready|not-ready)" >&2
    return 3
    ;;
  esac
  if ! echo "$missing" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "manifest-write: missing must be a JSON array, got '$missing'" >&2
    return 3
  fi
  if ! echo "$advisory" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "manifest-write: advisory must be a JSON array, got '$advisory'" >&2
    return 3
  fi

  local manifest_path
  manifest_path=$(get_ticket_manifest_path "$tid" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  _manifest_readiness_lock "${manifest_path}.lock" || return 1

  local waived
  waived=$(jq -c '.ready.waived // {}' "$manifest_path" 2>/dev/null) || waived='{}'
  [ -n "$waived" ] || waived='{}'

  local content write_rc
  content=$(jq -c \
    --argjson missing "$missing" --argjson advisory "$advisory" --argjson waived "$waived" \
    --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.ready = {
       status: (if ($missing - ($waived | keys)) == [] then "ready" else "not-ready" end),
       checked_at: $checked_at, missing: $missing, advisory: $advisory, waived: $waived
     }' \
    "$manifest_path") || {
    _manifest_readiness_unlock
    return 1
  }
  _manifest_atomic_write "$manifest_path" "$content"
  write_rc=$?
  _manifest_readiness_unlock
  return "$write_rc"
}

# waive_ticket_readiness_code <TID> <CODE> <by> <reason>
# The only writer that adds to `ready.waived`. Merges one waiver in and
# recomputes `status` from the manifest's own current `ready.missing` against
# the updated waiver set — never touches `missing`, `advisory`, or any other
# code's waiver. Serializes under the same readiness lock as
# set_ticket_readiness. No-op (exit 1) if no manifest exists yet.
waive_ticket_readiness_code() {
  local tid="$1" code="$2" by="$3" reason="${4:-}"
  [ -n "$code" ] || {
    echo "manifest-write: code must be non-empty" >&2
    return 3
  }
  [ -n "$by" ] || {
    echo "manifest-write: by must be non-empty" >&2
    return 3
  }

  local manifest_path
  manifest_path=$(get_ticket_manifest_path "$tid" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  _manifest_readiness_lock "${manifest_path}.lock" || return 1

  local content write_rc
  content=$(jq -c \
    --arg code "$code" --arg by "$by" --arg reason "$reason" \
    '.ready.waived = ((.ready.waived // {}) + {($code): {by: $by, reason: $reason}})
     | .ready.status = (if (((.ready.missing // []) - (.ready.waived | keys)) == []) then "ready" else "not-ready" end)' \
    "$manifest_path") || {
    _manifest_readiness_unlock
    return 1
  }
  _manifest_atomic_write "$manifest_path" "$content"
  write_rc=$?
  _manifest_readiness_unlock
  return "$write_rc"
}

# add_ticket_blocked_by <TID> <BLOCKER>
# Appends BLOCKER to the ticket manifest's blocked_by[] if not already
# present. Idempotent. Modelled on add_epic_manifest_child. No-op (exit 1)
# if no manifest exists yet.
add_ticket_blocked_by() {
  local tid="$1" blocker="$2"
  [[ "$blocker" =~ $_MANIFEST_ID_RE ]] || return 3

  local manifest_path
  manifest_path=$(get_ticket_manifest_path "$tid" 2>/dev/null) || return 1
  [ -f "$manifest_path" ] || return 1

  local content
  content=$(jq -c --arg blocker "$blocker" \
    '.blocked_by = ((.blocked_by // []) + [$blocker] | unique)' \
    "$manifest_path") || return 1

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
