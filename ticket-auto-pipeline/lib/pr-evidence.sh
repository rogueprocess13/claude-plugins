#!/usr/bin/env bash
# pr-evidence.sh — the one writer of `META|pr-created` (GitHub #525).
#
# record_pr_created [--new] <LOG_FILE> <TID> <PR_URL> [--epic]
#   Appends `META|pr-created|info|{"pr":N,"url":...,"repo":"owner/name"}` for
#   one PR. Skipped when the current run's window (lines after the last
#   `META|run-id`, or the whole log on a pre-run-id log) already records the
#   same PR. `--new` means the caller just created the PR: it also emits the
#   `pr-opened{pr}` outbox event, idempotency-keyed on the PR so a retry is a
#   no-op. `--epic` tags the record `"epic":true` (epic integration PRs).
#   Exit 0 written or already recorded, 1 the URL is not a GitHub PR URL, 2 usage.
#
# pr_evidence_backfill <LOG_FILE> <TID>
#   Deterministic safety net, run by pipeline-finalize.sh before
#   `META|outcome`. Does nothing when the current run's window already holds
#   any `pr-created` record. Otherwise it collects candidate PRs the log names
#   — GitHub PR URLs on VERIFY / PR-REVIEW lines, and the bare numbers on the
#   latest `PR-REVIEW|checkout-pr|done|` line — and records one ONLY when it
#   can verify it: the repo is the origin of one of the ticket's worktrees
#   (`$REPOS_ROOT/.ticket-auto/worktrees/{TID}/*`), `gh pr view` succeeds,
#   and the PR's headRefName is the ticket branch from `META|branch-context`.
#   Agents write free text on those lines (links to related or upstream PRs);
#   an unverified URL marked as this ticket's PR would let merge-poll see the
#   wrong PR merged and release blocked-by dependents early. A candidate it
#   cannot verify gets a `META|pr-evidence|warn|` line instead, never a
#   marker. Records carry `"backfill":true` and emit no outbox event; any
#   reader prefers a non-backfill record when one exists. Always returns 0.
#
# Why this file exists: ticket-verify opened PRs through a bash block in its
# SKILL.md. The agent ran its own version of that block, logged
# `VERIFY|pr-open|done|<url>` and never wrote `pr-created`. The run event
# then had `repo: null`, merge-poll wrote `unknown-repo` once, and every
# blocked-by dependent stayed held after a human merged the PR.
#
# Sourceable library. -u and -e intentionally omitted (repo convention: shell
# snapshots inject ZSH_VERSION; sourcing must not change the caller's flags).

_PE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_PE_URL_RE='https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+'

# _pe_parse_url <url> → "<num>\t<owner/repo>\t<canonical url>", rc 1 if not a PR URL.
_pe_parse_url() {
  local url
  url=$(printf '%s' "${1:-}" | grep -oE "$_PE_URL_RE" | head -1) || url=""
  [ -n "$url" ] || return 1
  local num repo
  num="${url##*/}"
  repo=$(printf '%s' "$url" | sed -E 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#')
  printf '%s\t%s\t%s\n' "$num" "$repo" "$url"
}

# _pe_window <log> — lines of the current run (after the last META|run-id).
_pe_window() {
  local log="$1" start
  start=$(grep -n '|META|run-id|info|' "$log" 2>/dev/null | tail -1 | cut -d: -f1) || start=""
  if [ -n "$start" ]; then
    tail -n "+$start" "$log" 2>/dev/null
  else
    cat "$log" 2>/dev/null
  fi
}

# _pe_recorded <text> <num> <repo> — rc 0 when a pr-created line in <text>
# already names this PR. An empty repo matches any record for that number.
_pe_recorded() {
  local text="$1" num="$2" repo="$3"
  grep '|META|pr-created|info|' <<<"$text" 2>/dev/null |
    awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}' |
    jq -e -R --arg n "$num" --arg r "$repo" -s '
      [split("\n")[] | fromjson? | objects
        | select(.backfill != true)
        | select(((.pr // "") | tostring) == $n)
        | select($r == "" or .repo == $r)] | length > 0' >/dev/null 2>&1
}

_pe_append() {
  local log="$1" json="$2"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|pr-created|info|${json}" >>"$log"
}

record_pr_created() {
  local is_new=false is_epic=false
  while [ $# -gt 0 ]; do
    case "$1" in
    --new) is_new=true ;;
    --epic) is_epic=true ;;
    *) break ;;
    esac
    shift
  done
  local log="${1:-}" tid="${2:-}" url_in="${3:-}"
  [ "${4:-}" = "--epic" ] && is_epic=true
  if [ -z "$log" ] || [ -z "$tid" ]; then
    echo "record_pr_created: usage: record_pr_created [--new] <LOG_FILE> <TID> <PR_URL> [--epic]" >&2
    return 2
  fi

  local parsed num repo url
  parsed=$(_pe_parse_url "$url_in") || {
    echo "record_pr_created: not a GitHub PR URL: ${url_in}" >&2
    return 1
  }
  num=$(cut -f1 <<<"$parsed")
  repo=$(cut -f2 <<<"$parsed")
  url=$(cut -f3 <<<"$parsed")

  if ! _pe_recorded "$(_pe_window "$log")" "$num" "$repo"; then
    local json
    json=$(jq -nc --argjson pr "$num" --arg url "$url" --arg repo "$repo" --argjson epic "$is_epic" \
      '{pr: $pr, url: $url, repo: $repo} + (if $epic then {epic: true} else {} end)') || return 1
    _pe_append "$log" "$json"
  fi

  if $is_new; then
    declare -f emit_event >/dev/null 2>&1 || source "$_PE_LIB_DIR/events.sh" 2>/dev/null || true
    if declare -f emit_event >/dev/null 2>&1; then
      emit_event --idem "${tid}:pr-opened:${repo}#${num}" "$tid" pr-opened \
        "$(jq -nc --argjson pr "$num" '{pr: $pr}')" >/dev/null 2>&1 || true
    fi
  fi
  echo "pr-created: ${repo}#${num}"
  return 0
}

# _pe_origin_slug <git dir> → owner/repo of its origin remote (GitHub only).
_pe_origin_slug() {
  local remote
  remote=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  printf '%s\n' "$remote" |
    sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p' |
    sed -E 's#\.git$##' | grep -E '^[^/]+/[^/]+$'
}

_pe_warn() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|pr-evidence|warn|$2" >>"$1"
}

# _pe_verify <target> <branch> → prints the PR url when gh confirms the PR's
# head is <branch>. <target> is a PR URL, or "<num> --repo <slug>".
_pe_verify() {
  local branch="$1" resp head url
  shift
  resp=$(timeout 20 gh pr view "$@" --json headRefName,url 2>/dev/null) || return 1
  head=$(jq -r '.headRefName // empty' <<<"$resp" 2>/dev/null) || return 1
  url=$(jq -r '.url // empty' <<<"$resp" 2>/dev/null) || return 1
  [ -n "$head" ] && [ "$head" = "$branch" ] && [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

pr_evidence_backfill() {
  local log="${1:-}" tid="${2:-}"
  [ -f "$log" ] && [ -n "$tid" ] || return 0

  # 1. Never beside an existing record of this run (real or backfilled).
  _pe_window "$log" | grep -q '|META|pr-created|info|' && return 0

  # 2. Candidates.
  local urls checkout nums
  urls=$(grep -E '^[^|]*\|(VERIFY|PR-REVIEW)\|' "$log" 2>/dev/null | grep -oE "$_PE_URL_RE" | awk '!seen[$0]++') || urls=""
  checkout=$(grep '|PR-REVIEW|checkout-pr|done|' "$log" 2>/dev/null | tail -1 |
    awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}') || checkout=""
  nums=$(grep -oE '[0-9]+' <<<"$checkout" | awk '!seen[$0]++') || nums=""
  [ -n "$urls$nums" ] || return 0

  # 3. Verification context — missing any part means nothing is verifiable.
  local branch slugs="" wt slug
  branch=$(grep '|META|branch-context|info|' "$log" 2>/dev/null | tail -1 |
    awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}' |
    tr ';' '\n' | sed -n 's/^ticket=//p' | head -1) || branch=""
  if [ -n "${REPOS_ROOT:-}" ]; then
    for wt in "$REPOS_ROOT/.ticket-auto/worktrees/$tid"/*/; do
      [ -d "$wt" ] || continue
      slug=$(_pe_origin_slug "$wt") || continue
      slugs="$slugs $slug"
    done
  fi
  local reason=""
  if [ -z "$branch" ]; then
    reason="no ticket branch in META|branch-context"
  elif [ -z "${REPOS_ROOT:-}" ]; then
    reason="REPOS_ROOT unset"
  elif [ -z "${slugs// /}" ]; then
    reason="no ticket worktrees with a GitHub origin"
  elif ! command -v gh >/dev/null 2>&1; then
    reason="gh not available"
  fi
  if [ -n "$reason" ]; then
    _pe_warn "$log" "backfill unverifiable (${reason}); PR(s) named in log not recorded: $(echo $urls $nums)"
    return 0
  fi

  # 4. Verify each candidate; record only confirmed PRs.
  local recorded=" " rejected="" u parsed num repo url
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    parsed=$(_pe_parse_url "$u") || continue
    num=$(cut -f1 <<<"$parsed")
    repo=$(cut -f2 <<<"$parsed")
    case " $slugs " in
    *" $repo "*) ;;
    *)
      rejected="$rejected $u(repo-not-a-ticket-worktree)"
      continue
      ;;
    esac
    if url=$(_pe_verify "$branch" "$u"); then
      _pe_append "$log" "$(jq -nc --argjson pr "$num" --arg url "$url" --arg repo "$repo" \
        '{pr: $pr, url: $url, repo: $repo, backfill: true}')"
      recorded="$recorded${repo}#${num} "
    else
      rejected="$rejected $u(head-not-ticket-branch-or-gh-failed)"
    fi
  done <<<"$urls"

  local n found
  for n in $nums; do
    case "$recorded" in *"#${n} "*) continue ;; esac
    found=""
    for slug in $slugs; do
      if url=$(_pe_verify "$branch" "$n" --repo "$slug"); then
        _pe_append "$log" "$(jq -nc --argjson pr "$n" --arg url "$url" --arg repo "$slug" \
          '{pr: $pr, url: $url, repo: $repo, backfill: true}')"
        recorded="$recorded${slug}#${n} "
        found=1
        break
      fi
    done
    [ -n "$found" ] || rejected="$rejected #${n}(unverified)"
  done

  [ -z "$rejected" ] || _pe_warn "$log" "backfill skipped unverified PR(s):${rejected}"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -eo pipefail
  case "${1:-}" in
  record)
    shift
    record_pr_created "$@"
    ;;
  backfill)
    shift
    pr_evidence_backfill "$@"
    ;;
  *)
    echo "usage: pr-evidence.sh record [--new] <LOG_FILE> <TID> <PR_URL> [--epic] | backfill <LOG_FILE> <TID>" >&2
    exit 2
    ;;
  esac
fi
