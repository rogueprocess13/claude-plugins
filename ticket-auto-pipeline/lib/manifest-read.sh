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
# tracker-planner-and-fallback-cutover (task 3.12): the
# TICKET_LOCAL_MANIFEST_DISABLE kill switch this function used to centralize
# is retired — design D3: with no live fallbacks left anywhere in the
# codebase, the flag could no longer restore the pre-migration read path, it
# could only make every manifest read return nothing while every caller has
# no alternative. Every read function in this file (and manifest-write.sh,
# which sources it) still resolves REPOS_ROOT through this one function.
_manifest_repos_root() {
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

# _manifest_canonical_epic <repos_root> <EPIC>
# Prints the real directory name behind initiatives/<EPIC>/epic — <EPIC>
# itself unless an operator symlink (#524 workaround) points elsewhere
# under initiatives/. Falls back to <EPIC> when it cannot be resolved.
_manifest_canonical_epic() {
  local repos_root="$1" epic="$2" base real
  base=$(cd "$repos_root/.ticket-auto/initiatives" 2>/dev/null && pwd -P) || base=""
  real=$(cd "$repos_root/.ticket-auto/initiatives/$epic/epic" 2>/dev/null && pwd -P) || real=""
  real="${real%/epic}"
  if [ -n "$base" ] && [ "${real%/*}" = "$base" ] && [[ "${real##*/}" =~ $_MANIFEST_ID_RE ]]; then
    echo "${real##*/}"
  else
    echo "$epic"
  fi
}

# resolve_ticket_epic <TID> [candidate...]
# Prints the epic id (the directory name under initiatives/ that holds
# epic/manifest.json) a ticket belongs to. GitHub #524: no single id a
# caller holds is reliably that directory name — the tracker's parent UUID
# never is, and a planner child's `initiative` (INIT-<n>) has no epic/ of
# its own because EpicGen writes the epic manifest under the epic's
# identifier. Resolution order, first hit wins:
#   1. each non-empty <candidate> (e.g. parent identifier, parent UUID) that
#      has an epic manifest;
#   2. the ticket manifest's `initiative`, when it is itself an epic;
#   3. the epic whose manifest lists <TID> in children[] — the relation
#      TicketGen's add_epic_manifest_child records. Real directories are
#      scanned (find does not follow symlinks), so operator workaround
#      symlinks never shadow the real epic id.
# Exit 0 → id printed; 1 → no epic found; 3 → REPOS_ROOT unset / bad TID.
resolve_ticket_epic() {
  local tid="$1"
  shift
  local repos_root
  repos_root=$(_manifest_repos_root) || return 3
  [[ "$tid" =~ $_MANIFEST_ID_RE ]] || return 3

  local cand
  for cand in "$@"; do
    [ -n "$cand" ] || continue
    if epic_manifest_exists "$cand" 2>/dev/null; then
      _manifest_canonical_epic "$repos_root" "$cand"
      return 0
    fi
  done

  local init
  init=$(get_ticket_manifest_field "$tid" initiative 2>/dev/null) || init=""
  case "$init" in "" | null | _adhoc) ;; *)
    if epic_manifest_exists "$init" 2>/dev/null; then
      _manifest_canonical_epic "$repos_root" "$init"
      return 0
    fi
    ;;
  esac

  local base="$repos_root/.ticket-auto/initiatives" m epic
  [ -d "$base" ] || return 1
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    epic="${m#"$base"/}"
    epic="${epic%%/*}"
    case "$epic" in _*) continue ;; esac
    [[ "$epic" =~ $_MANIFEST_ID_RE ]] || continue
    if jq -e --arg t "$tid" '(.children // []) | index($t) != null' "$m" >/dev/null 2>&1; then
      echo "$epic"
      return 0
    fi
  done < <(find "$base" -mindepth 3 -maxdepth 3 -type f -path '*/epic/manifest.json' 2>/dev/null | sort)
  return 1
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

# _mr_field5 — join pipe-delimited fields 5..NF (JSON/messages contain `|`).
_mr_field5() {
  awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}'
}

# ticket_pipeline_pr_ref <LOG_FILE>
# Prints "<lineno>\t<pr_num>\t<repo>" for the most recent PR this ticket's
# pipeline log names, or nothing when the log names no PR at all. The latest
# `META|pr-created` (ticket-verify / epic-branch.sh, JSON {pr,url,repo}) wins;
# `PR-REVIEW|checkout-pr|done|<n>` (ticket-pr-review) is the fallback when no
# pr-created line exists — the same precedence run-summary.sh uses for the
# `run` event's `pr`, so this names the PR merge-poll.sh actually polls.
# Reads the WHOLE log, not just the last run's
# window: a resumed run that never re-entered VERIFY/PR-REVIEW still owns the
# PR an earlier run of the same ticket opened. Always returns 0.
ticket_pipeline_pr_ref() {
  local log_file="$1"
  [ -f "$log_file" ] || return 0

  local created_line checkout_line
  created_line=$(grep -n '|META|pr-created|info|' "$log_file" 2>/dev/null | tail -1) || created_line=""
  checkout_line=$(grep -n '|PR-REVIEW|checkout-pr|done|' "$log_file" 2>/dev/null | tail -1) || checkout_line=""

  local c_ln="" c_pr="" c_repo="" k_ln="" k_pr="" c_json=""
  if [ -n "$created_line" ]; then
    c_ln="${created_line%%:*}"
    c_json=$(printf '%s\n' "${created_line#*:}" | _mr_field5) || c_json=""
    c_pr=$(printf '%s' "$c_json" | jq -r '(.pr // empty) | tostring' 2>/dev/null | grep -oE '^[0-9]+$') || c_pr=""
    c_repo=$(printf '%s' "$c_json" | jq -r '.repo // empty' 2>/dev/null) || c_repo=""
    [ -n "$c_pr" ] || c_ln=""
  fi
  if [ -n "$checkout_line" ]; then
    k_ln="${checkout_line%%:*}"
    k_pr=$(printf '%s\n' "${checkout_line#*:}" | _mr_field5 | grep -oE '[0-9]+' | head -1) || k_pr=""
    [ -n "$k_pr" ] || k_ln=""
  fi

  if [ -n "$c_ln" ]; then
    printf '%s\t%s\t%s\n' "$c_ln" "$c_pr" "$c_repo"
  elif [ -n "$k_ln" ]; then
    printf '%s\t%s\t\n' "$k_ln" "$k_pr"
  fi
  return 0
}

# ticket_pipeline_merge_state <TID> [workspace]
# The single merge-aware terminal check (GitHub #412). Prints one state word
# and returns 0 when TID counts as finished for anything that waits on it
# (blocked-by resolution, epic integration readiness), 1 otherwise:
#
#   not-complete       rc 1  no pipeline log, or its last outcome is not
#                            `completed:*` (held:/stopped:/dead-letter, or no
#                            outcome yet — "blocker with no pipeline log yet
#                            is unsatisfied", ticket-local-manifest spec)
#   no-pr              rc 0  completed, and the log names no PR at all (a
#                            no-code ticket) — unchanged from before #412
#   merged             rc 0  completed, and its PR is merged
#   open               rc 1  completed, but its PR is still open. A run that
#                            leaves the merge to a human (manual autonomy, an
#                            epic Merge Policy) writes `completed: STEP_6`
#                            exactly like one that merged.
#   closed             rc 1  completed, but its PR was closed unmerged
#   merged-other-base  rc 1  merged, but into a branch other than the `base=`
#                            the ticket's own `META|branch-context` recorded
#   unknown            rc 1  completed with a PR whose merge state cannot be
#                            determined — fail safe: never release on missing
#                            evidence (CLAUDE.md "Tracker read failure policy")
#
# Merge evidence, strongest first:
#   1. `merge` events for this tid + PR number in `{workspace}/runs.jsonl`,
#      written by lib/merge-poll.sh (the one merge-truth implementation) from
#      pipeline-finalize.sh's one-shot post-outcome sweep and from fleetd's
#      periodic sweep — which keeps re-polling an open PR, so a human merge is
#      recorded here with no new pipeline run. A `merged` observation wins
#      outright (a merge cannot be undone); otherwise the latest `open` or
#      `closed` observation decides. `stale`/`unknown`/`unknown-repo` carry no
#      state and fall through. Malformed lines are skipped, never fatal.
#   2. The pipeline log's own record of a merge AFTER the PR reference: a
#      `PR-REVIEW|merge-decision|done|merged` line (ticket-pr-review's direct
#      merge) or a human's `META|manual-merge` / `META|pr-merged` annotation.
#      Consulted only when gh observed nothing decisive — an `open`
#      observation, always taken after the run ended, outranks the log.
#
# Under an epic directive the PR's base IS the epic branch (branch-resolve.sh:
# BASE_BRANCH = the directive's Branch), so `merged` here means merged into
# that branch — exactly what a sibling, or the epic's integration PR, needs.
# The base check compares the merge event's `base` against the log's recorded
# `base=`; either side absent (evidence predating the field) skips the check.
ticket_pipeline_merge_state() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local log_file="$workspace/${tid}-pipeline.log"

  if [ ! -f "$log_file" ]; then
    echo "not-complete"
    return 1
  fi

  local last_outcome
  last_outcome=$(grep '|META|outcome|info|' "$log_file" 2>/dev/null | tail -1 | _mr_field5) || last_outcome=""
  case "$last_outcome" in
  "completed:"*) ;;
  *)
    echo "not-complete"
    return 1
    ;;
  esac

  local pr_ref
  pr_ref=$(ticket_pipeline_pr_ref "$log_file") || pr_ref=""
  if [ -z "$pr_ref" ]; then
    echo "no-pr"
    return 0
  fi

  local pr_ln pr_num
  pr_ln=$(printf '%s\n' "$pr_ref" | cut -f1)
  pr_num=$(printf '%s\n' "$pr_ref" | cut -f2)

  # ── 1. merge-poll observations in runs.jsonl ─────────────────────────────
  local runs_file="$workspace/runs.jsonl" gh_line="" gh_state="" gh_base=""
  if [ -f "$runs_file" ]; then
    gh_line=$(jq -rRs --arg tid "$tid" --arg pr "$pr_num" '
      [split("\n")[] | fromjson? | objects
        | select(.kind == "merge" and .tid == $tid and ((.pr // "") | tostring) == $pr)
        | select(.state == "merged" or .state == "open" or .state == "closed")]
      | (map(select(.state == "merged")) | last) as $m
      | if $m != null then "merged\t\($m.base // "")"
        elif length > 0 then "\(last.state)\t"
        else empty end
    ' "$runs_file" 2>/dev/null) || gh_line=""
    gh_state=$(printf '%s\n' "$gh_line" | cut -f1)
    gh_base=$(printf '%s\n' "$gh_line" | cut -f2)
  fi

  case "$gh_state" in
  merged)
    local want_base
    want_base=$(grep '|META|branch-context|info|' "$log_file" 2>/dev/null | tail -1 | _mr_field5 |
      tr ';' '\n' | sed -n 's/^base=//p' | head -1) || want_base=""
    if [ -n "$gh_base" ] && [ -n "$want_base" ] && [ "$gh_base" != "$want_base" ]; then
      echo "merged-other-base"
      return 1
    fi
    echo "merged"
    return 0
    ;;
  open | closed)
    echo "$gh_state"
    return 1
    ;;
  esac

  # ── 2. the pipeline's own merge record, after the PR reference ──────────
  if tail -n "+$((pr_ln + 1))" "$log_file" 2>/dev/null |
    grep -qE '\|PR-REVIEW\|merge-decision\|done\|merged|\|META\|(manual-merge|pr-merged)\|'; then
    echo "merged"
    return 0
  fi

  echo "unknown"
  return 1
}

# ticket_pipeline_terminal_done <TID> [workspace]
# True when TID is genuinely finished for anything that waits on it — the
# single shared check behind ticket-auto-pipeline's epic_branch_children_done
# and fleet-controller's blocked-by resolution (fleet-dispatch.sh,
# detect_blocked_by). Never a live tracker fetch. A thin wrapper over
# ticket_pipeline_merge_state above: a `completed:*` outcome alone used to be
# enough, which released dependents while a PR a human still had to merge sat
# open (GitHub #412). A caller that wants to say WHY a blocker is not done
# calls ticket_pipeline_merge_state directly for the state word.
ticket_pipeline_terminal_done() {
  ticket_pipeline_merge_state "$@" >/dev/null
}

# ticket_is_ready <TID>
# Pure cache read of the manifest's `ready.status` — never triggers a live
# computation (dor-readiness-gate-foundation). A consumer that must not
# permanently treat a never-scanned ticket as blocked uses
# ensure_ticket_readiness (lib/dor-check.sh) instead.
# Exit 0 ready; 1 not ready (field absent, or any other value, manifest
# exists); 2 no manifest at all (distinct from 1, per ticket-local-manifest
# spec); 3 usage error (invalid ticket ID, REPOS_ROOT unset, or malformed
# manifest JSON) — propagated from get_ticket_manifest_field's own 2/3.
# Every command substitution below is guarded with `|| rc=$?` per the set -e
# bare-assignment trap (gate-check.sh and flow.sh both set errexit).
ticket_is_ready() {
  local tid="$1"
  local ready_json rc=0
  ready_json=$(get_ticket_manifest_field "$tid" ready) || rc=$?
  case "$rc" in
  0) ;;
  1) return 2 ;; # no manifest at all
  *) return 3 ;; # malformed JSON (2) or invalid id/REPOS_ROOT unset (3)
  esac

  [ -n "$ready_json" ] || return 1

  local status
  status=$(echo "$ready_json" | jq -r '.status // empty' 2>/dev/null) || status=""
  [ "$status" = "ready" ]
}

# ticket_is_planned <TID>
# Exit 0 iff the manifest's `initiative` names a real initiative rather
# than the reserved `_adhoc` value ensure_ticket_manifest writes for a
# ticket with no planner-assigned initiative. `ensure_ticket_manifest`
# writes `_adhoc` only to the initiative index, not to the manifest's own
# `initiative` field — that field is left as JSON `null` for an ad-hoc
# ticket, and get_ticket_manifest_field's `tostring` renders JSON null as
# the literal string "null", not empty — so both "null" and "_adhoc" (in
# case a caller ever writes the reserved value directly into the field) are
# treated as not-planned, alongside a genuinely absent/empty field.
# Exit 1 not planned; propagates get_ticket_manifest_field's 1/2/3 for no
# manifest / malformed JSON / usage error.
ticket_is_planned() {
  local tid="$1"
  local init rc=0
  init=$(get_ticket_manifest_field "$tid" initiative) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  case "$init" in
  "" | "null" | "_adhoc") return 1 ;;
  *) return 0 ;;
  esac
}

# ticket_dispatch_blocked_by_flags <TID>
# Exit 0 iff the manifest's `flags` array contains `needs-info`. Always a
# live read against the manifest's current `flags` — never satisfied from
# the cached `ready` object — so clearing the flag un-gates a ticket
# immediately regardless of readiness-cache staleness. Exit 1 flag absent;
# propagates get_ticket_manifest_field's 1/2/3 for no manifest / malformed
# JSON / usage error.
ticket_dispatch_blocked_by_flags() {
  local tid="$1"
  local flags_json rc=0
  flags_json=$(get_ticket_manifest_field "$tid" flags) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  [ -n "$flags_json" ] || return 1
  echo "$flags_json" | jq -e 'type == "array" and (index("needs-info") != null)' \
    >/dev/null 2>&1
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
  echo '{"type":"bug","initiative":"INIT-1","blocked_by":[],"dispatch":false,"stage":"Ready","flags":["needs-info"],"rev":3,"pending_event":{"event":"appraise-complete","data":{}}}' \
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

  [ "$(get_ticket_manifest_field TEST-1 flags)" = '["needs-info"]' ] && echo "✓ flags field read" || echo "✗ flags field read"
  [ "$(get_ticket_manifest_field TEST-1 rev)" = "3" ] && echo "✓ rev field read" || echo "✗ rev field read"
  [ "$(get_ticket_manifest_field TEST-1 pending_event)" = '{"event":"appraise-complete","data":{}}' ] && echo "✓ pending_event field read" || echo "✗ pending_event field read"

  echo 'not json' >"$tmp/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"
  get_ticket_manifest_field TEST-1 type >/dev/null 2>&1
  [ "$?" = "2" ] && echo "✓ malformed JSON is exit 2" || echo "✗ malformed JSON should be exit 2"

  rm -rf "$tmp"
  echo "Self-tests complete — run test-manifest-read.sh for full coverage."
  exit 0
fi
