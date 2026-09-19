#!/usr/bin/env bash
# merge-poll.sh — the single merge-truth implementation for the pipeline
# (Branch B of the Commercial Evidence MVP, next.md Step 1 / design.md).
#
# Sourceable (for pipeline-finalize.sh's one-shot post-outcome sweep) and
# runnable as a CLI (for fleet-controller's periodic sweep, Branch C).
#
# -u (nounset) intentionally omitted, matching run-identity.sh/run-summary.sh.
set -eo pipefail

_MP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f runs_append >/dev/null 2>&1; then
  [ -f "$_MP_LIB_DIR/run-summary.sh" ] && source "$_MP_LIB_DIR/run-summary.sh"
fi
# events.sh backs the pr-merged dual-write below
# (tracker-event-vocabulary-and-emitter).
if ! declare -f emit_event >/dev/null 2>&1; then
  [ -f "$_MP_LIB_DIR/events.sh" ] && source "$_MP_LIB_DIR/events.sh"
fi

MERGE_POLL_MIN_INTERVAL_SECS="${MERGE_POLL_MIN_INTERVAL_SECS:-600}"
MERGE_POLL_MAX_AGE_DAYS="${MERGE_POLL_MAX_AGE_DAYS:-14}"

# ── merge_poll_candidates ─────────────────────────────────────────────────────
# Usage: merge_poll_candidates RUNS_FILE
# Prints a JSON array on stdout: one entry per tid whose latest `run` event
# has a non-null pr and no later terminal merge event
# (merged|closed|stale|unknown-repo). Each entry:
#   {tid, pr: {pr,url,repo}, run_ended_at, last_merge_observed_at}
# `pr.repo` may itself be null/unresolvable — that is a downstream
# unknown-repo case handled by the sweep, not excluded here (a repo-less
# candidate must still surface so it can be reported once, not silently
# skipped forever).
# Order in the file is used as the chronology proxy — runs.jsonl is
# append-only, so file position is monotonic with observation time.
merge_poll_candidates() {
  local runs_file="$1"
  [ -f "$runs_file" ] || return 0

  jq -sc '
    to_entries
    | map(.value + {_idx: .key})
    | group_by(.tid)
    | map(
        . as $events
        | ($events | map(select(.kind == "run")) | sort_by(._idx) | last) as $run
        | if ($run == null) or ($run.pr == null) then empty else
          ($events | map(select(.kind == "merge")) | sort_by(._idx)) as $merges
          | ($merges | map(select(._idx > $run._idx))) as $later
          | if ($later | map(select(.state == "merged" or .state == "closed" or .state == "stale" or .state == "unknown-repo")) | length) > 0 then empty else
            ($later | sort_by(._idx) | last) as $last_merge
            | {
                tid: $run.tid,
                pr: $run.pr,
                run_ended_at: ($run.ended_at // null),
                last_merge_observed_at: ($last_merge.observed_at // null)
              }
          end
        end
      )
  ' <"$runs_file" 2>/dev/null || echo "[]"
}

# ── merge_poll_one ────────────────────────────────────────────────────────────
# Usage: merge_poll_one TID PR_NUM REPO
# Prints one `merge` event JSON object on stdout, or nothing on gh failure
# (non-zero exit, timeout, or malformed JSON) — the caller must not append
# on empty output, leaving the candidate eligible for the next sweep.
merge_poll_one() {
  local tid="$1" pr_num="$2" repo="$3"
  [ -n "$tid" ] && [ -n "$pr_num" ] && [ -n "$repo" ] || return 1

  local resp
  resp=$(timeout 20 gh pr view "$pr_num" --repo "$repo" --json state,mergedAt,mergeCommit 2>/dev/null) || return 1
  echo "$resp" | jq -e . >/dev/null 2>&1 || return 1

  local gh_state norm_state merged_at merge_sha
  gh_state=$(echo "$resp" | jq -r '.state // empty' 2>/dev/null) || true
  case "$gh_state" in
  MERGED) norm_state="merged" ;;
  CLOSED) norm_state="closed" ;;
  OPEN) norm_state="open" ;;
  *) norm_state="unknown" ;;
  esac
  merged_at=$(echo "$resp" | jq -r '.mergedAt // empty' 2>/dev/null) || true
  merge_sha=$(echo "$resp" | jq -r '.mergeCommit.oid // empty' 2>/dev/null) || true

  jq -nc \
    --arg tid "$tid" --argjson pr "$pr_num" --arg repo "$repo" --arg state "$norm_state" \
    --arg merged_at "${merged_at:-}" --arg merge_sha "${merge_sha:-}" \
    '{
      kind: "merge", tid: $tid, pr: $pr, repo: $repo, state: $state,
      merged_at: (if $merged_at == "" then null else $merged_at end),
      merge_sha: (if $merge_sha == "" then null else $merge_sha end),
      observed_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }' 2>/dev/null
}

# ── merge_poll_sweep ──────────────────────────────────────────────────────────
# Usage: merge_poll_sweep RUNS_FILE [TID]
# One pass over merge_poll_candidates: skips recently-polled candidates
# (< MERGE_POLL_MIN_INTERVAL_SECS since their last merge event), emits
# state:"stale" for candidates whose run ended more than
# MERGE_POLL_MAX_AGE_DAYS ago, emits state:"unknown-repo" once for a
# candidate with no resolvable repo, and otherwise calls merge_poll_one and
# appends its event. Always exits 0 — every step is fail-soft.
merge_poll_sweep() {
  local runs_file="$1" only_tid="${2:-}"
  [ -n "$runs_file" ] && [ -f "$runs_file" ] || return 0

  local candidates
  candidates=$(merge_poll_candidates "$runs_file") || return 0
  [ -n "$candidates" ] && [ "$candidates" != "[]" ] || return 0

  local now_epoch max_age_secs
  now_epoch=$(date +%s)
  max_age_secs=$((MERGE_POLL_MAX_AGE_DAYS * 86400))

  local cand
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    local c_tid c_pr_num c_pr_repo c_ended c_last_merge_ts
    c_tid=$(jq -r '.tid // empty' <<<"$cand" 2>/dev/null) || true
    [ -n "$only_tid" ] && [ "$c_tid" != "$only_tid" ] && continue
    c_pr_num=$(jq -r '.pr.pr // empty' <<<"$cand" 2>/dev/null) || true
    c_pr_repo=$(jq -r '.pr.repo // empty' <<<"$cand" 2>/dev/null) || true
    c_ended=$(jq -r '.run_ended_at // empty' <<<"$cand" 2>/dev/null) || true
    c_last_merge_ts=$(jq -r '.last_merge_observed_at // empty' <<<"$cand" 2>/dev/null) || true

    if [ -z "$c_pr_repo" ]; then
      local unknown_ev
      unknown_ev=$(jq -nc --arg tid "$c_tid" --argjson pr "${c_pr_num:-null}" \
        '{kind:"merge",tid:$tid,pr:$pr,repo:null,state:"unknown-repo",merged_at:null,merge_sha:null,observed_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}')
      runs_append "$runs_file" "$unknown_ev"
      continue
    fi

    if [ -n "$c_last_merge_ts" ]; then
      local last_epoch
      last_epoch=$(date -d "$c_last_merge_ts" +%s 2>/dev/null || echo 0)
      if [ "$last_epoch" -gt 0 ] 2>/dev/null && [ $((now_epoch - last_epoch)) -lt "$MERGE_POLL_MIN_INTERVAL_SECS" ]; then
        continue
      fi
    fi

    if [ -n "$c_ended" ]; then
      local ended_epoch
      ended_epoch=$(date -d "$c_ended" +%s 2>/dev/null || echo 0)
      if [ "$ended_epoch" -gt 0 ] 2>/dev/null && [ $((now_epoch - ended_epoch)) -gt "$max_age_secs" ]; then
        local stale_ev
        stale_ev=$(jq -nc --arg tid "$c_tid" --argjson pr "${c_pr_num:-null}" --arg repo "$c_pr_repo" \
          '{kind:"merge",tid:$tid,pr:$pr,repo:$repo,state:"stale",merged_at:null,merge_sha:null,observed_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}')
        runs_append "$runs_file" "$stale_ev"
        continue
      fi
    fi

    local merge_event
    merge_event=$(merge_poll_one "$c_tid" "$c_pr_num" "$c_pr_repo") || continue
    [ -n "$merge_event" ] || continue
    runs_append "$runs_file" "$merge_event"

    # Dual-write (tracker-event-vocabulary-and-emitter): pr-merged{pr,sha}.
    # Source of truth is this exact runs.jsonl merge event — pr/sha are read
    # straight out of it, never independently reconstructed — and this site
    # runs strictly after META|outcome, since merge_poll_candidates only
    # ever surfaces a tid whose own `run` event (itself written post-outcome
    # by pipeline-finalize.sh) already exists.
    if [ "$(jq -r '.state // empty' <<<"$merge_event" 2>/dev/null)" = "merged" ] &&
      declare -f emit_event >/dev/null 2>&1; then
      local _pm_pr _pm_sha
      _pm_pr=$(jq -r '.pr // empty' <<<"$merge_event" 2>/dev/null)
      _pm_sha=$(jq -r '.merge_sha // empty' <<<"$merge_event" 2>/dev/null)
      # FLEET_PIPELINE_LOG_DIR is overridden to this call only, to the
      # directory RUNS_FILE actually lives in — a caller invoking this sweep
      # (fleetd's periodic sweep, the CLI entrypoint) may not have that env
      # var set to match, and every outbox writer for a ticket must resolve
      # the identical directory.
      FLEET_PIPELINE_LOG_DIR="$(dirname "$runs_file")" \
        emit_event "$c_tid" pr-merged \
        "$(jq -nc --argjson pr "${_pm_pr:-null}" --arg sha "${_pm_sha:-}" \
          '{pr: $pr, sha: (if $sha == "" then null else $sha end)}')" 2>/dev/null || true
    fi
  done < <(jq -c '.[]' <<<"$candidates" 2>/dev/null || true)

  return 0
}

# ── CLI entrypoint ────────────────────────────────────────────────────────────
# Usage: merge-poll.sh [--tid TID] RUNS_FILE

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _MP_TID=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --tid)
      _MP_TID="$2"
      shift 2
      ;;
    *)
      _MP_RUNS_FILE="$1"
      shift
      ;;
    esac
  done

  if [ -z "${_MP_RUNS_FILE:-}" ]; then
    echo "Usage: merge-poll.sh [--tid TID] RUNS_FILE" >&2
    exit 1
  fi

  merge_poll_sweep "$_MP_RUNS_FILE" "$_MP_TID"
fi
