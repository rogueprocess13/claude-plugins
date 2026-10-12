#!/usr/bin/env bash
# planner-crosscheck-repo-ref.sh — Discovery-pinned repo ref resolution for
# Crosscheck (issue #217).
#
# Crosscheck's citation linter resolves `path:line` citations against
# whatever branch REPOS_ROOT happens to be checked out to *right now* — not
# the tree Discovery actually explored. On a shared REPOS_ROOT checkout that
# moves between Discovery and Crosscheck (someone switches branches, another
# initiative's pipeline lands commits), two files can genuinely differ
# between the ref Discovery explored and the ref Crosscheck checks against,
# producing CITATION_UNRESOLVED / CITATION_LINE_OUT_OF_RANGE findings
# indistinguishable from a hallucinated citation. Confirmed live on VS-2 and
# VS-3, worked around both times with a throwaway `git worktree`.
#
# The fix has two halves:
#   1. Discovery records the ref it explored to the state log, per repo:
#        META|discovery|repo-ref|<repo>@<branch-or-ref>@<sha>
#      <repo> is the repo's path relative to REPOS_ROOT (e.g.
#      `microservices/debt-collection`). Older initiatives recorded only the
#      bare directory name; planner_crosscheck_repo_dir resolves both (#500).
#      (written directly by the Discovery phase prompt — see
#      planner-phase-prompts.sh — since Discovery is an LLM-reasoning phase,
#      not this deterministic library.)
#   2. Crosscheck reads those entries back (this file) and, for any repo
#      whose live REPOS_ROOT checkout no longer matches the pinned sha,
#      creates an isolated `git worktree` alongside the live repo — never
#      touching it — and excludes the live (now-wrong-branch) copy from
#      citation resolution so it never shadows the worktree.
#
# Hard rule: this library — and everything upstream of it in the planner —
# never runs `git checkout`, `git switch`, or `git reset` against a live
# REPOS_ROOT checkout. It only reads from one, or creates a worktree beside
# it. See ticket-planner SKILL.md's "Crosscheck" section.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_REPO_REF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f planner_state_log >/dev/null 2>&1; then
  [ -f "${_PLANNER_CROSSCHECK_REPO_REF_LIB_DIR}/planner-state.sh" ] &&
    source "${_PLANNER_CROSSCHECK_REPO_REF_LIB_DIR}/planner-state.sh"
fi

# Read back the most recent repo-ref Discovery recorded for each repo.
# Usage: planner_crosscheck_repo_refs <initiative_id>
# Output (stdout): one "<repo> <ref> <sha>" line per recorded repo name,
# last-write-wins per name, in the order each name was last written (so a
# caller deduplicating further keeps last-write-wins). Nothing if Discovery
# never recorded a repo-ref (older initiatives, or a repo Discovery didn't
# touch).
planner_crosscheck_repo_refs() {
  local initiative_id="$1"
  local log
  log=$(planner_state_log "$initiative_id")
  [ -f "$log" ] || return 0

  declare -A _pcrr_seen=() _pcrr_seq=()
  local phase step status msg repo rest n=0

  while IFS='|' read -r _ts phase step status msg; do
    [ "$phase" = "META" ] || continue
    [ "$step" = "discovery" ] || continue
    [ "$status" = "repo-ref" ] || continue
    [ -z "$msg" ] && continue

    repo="${msg%%@*}"
    rest="${msg#*@}"
    [ -z "$repo" ] && continue
    [ "$rest" = "$msg" ] && continue # no '@' at all — malformed, skip

    n=$((n + 1))
    _pcrr_seen["$repo"]="$rest"
    _pcrr_seq["$repo"]="$n"
  done <"$log"

  local key val ref sha
  while IFS=' ' read -r _n key; do
    [ -n "$key" ] || continue
    val="${_pcrr_seen[$key]}"
    ref="${val%%@*}"
    sha="${val#*@}"
    [ "$sha" = "$val" ] && sha="" # no sha half recorded
    echo "${key} ${ref} ${sha}"
  done < <(for key in "${!_pcrr_seen[@]}"; do
    echo "${_pcrr_seq[$key]} ${key}"
  done | sort -n)
}

# Resolve the live checkout directory for a repo Discovery recorded (#500).
# <repo> is either a path relative to <repos_root> (`microservices/foo`, what
# Discovery records now) or a bare directory name (`foo`, what older
# initiatives recorded).
#   - A relative path (contains `/`) is used as-is and nothing else: if it is
#     no longer a git checkout, it resolves to nothing rather than to some
#     other same-named repo elsewhere.
#   - A bare name is tried at <repos_root>/<name> first, then <repos_root> is
#     searched (depth PLANNER_REPO_SEARCH_DEPTH, default 3; a symlinked
#     <repos_root> is followed) for a git checkout with that name. Exactly
#     one match is used; zero or several resolve to nothing — never a guess
#     between two same-named repos.
# Crosscheck worktrees (`*-crosscheck-*`, and anything under one) and the
# planner's own directories are never candidates.
#
# Usage: planner_crosscheck_repo_dir <repos_root> <repo>
# Output (stdout): live repo directory (<repos_root>/<relative path>), or
# empty if unresolved.
planner_crosscheck_repo_dir() {
  local repos_root="${1%/}" repo="$2"
  [ -n "$repos_root" ] && [ -n "$repo" ] || return 0
  repo="${repo%/}"
  repo="${repo#./}"
  case "/${repo}/" in
  */../* | //*) return 0 ;; # never escape REPOS_ROOT
  esac

  if [ -e "${repos_root}/${repo}/.git" ]; then
    echo "${repos_root}/${repo}"
    return 0
  fi
  case "$repo" in
  */*) return 0 ;; # a stale relative path never falls back to a name search
  esac

  # Escape find -name glob metacharacters so the name matches literally.
  local pattern
  pattern=$(printf '%s' "$repo" | sed 's/[][*?\\]/\\&/g')

  local depth="${PLANNER_REPO_SEARCH_DEPTH:-3}" cand
  local -a matches=()
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    [ -e "${cand}/.git" ] && matches+=("$cand")
  done < <(find -H "$repos_root" -mindepth 1 -maxdepth "$depth" \
    \( -name .git -o -name .ticket-auto -o -name .claude -o -name node_modules \
    -o -name .venv -o -name '*-crosscheck-*' \) -prune \
    -o -type d -name "$pattern" -print 2>/dev/null)

  [ "${#matches[@]}" -eq 1 ] && echo "${matches[0]}"
  return 0
}

# Discovery's repo-refs, resolved to live checkouts and deduplicated on the
# resolved directory (last write wins), so an initiative whose older run
# recorded `gateway@…` and newer run `microservices/gateway@…` yields one
# entry, not two worktrees.
# Usage: planner_crosscheck_repo_refs_resolved <initiative_id> <repos_root>
# Output (stdout): one "<live_dir> <repo> <ref> <sha>" line, fields separated
# by \037 (unit separator — a non-whitespace IFS keeps an empty field), one line
# per repo; <live_dir> is empty for a repo that does not resolve.
planner_crosscheck_repo_refs_resolved() {
  local initiative_id="$1" repos_root="$2"
  local repo ref sha dir key
  local -a order=()
  declare -A _pcrrr_line=()

  while read -r repo ref sha; do
    [ -z "$repo" ] && continue
    dir=$(planner_crosscheck_repo_dir "$repos_root" "$repo")
    key="${dir:-unresolved:${repo}}"
    [ -n "${_pcrrr_line[$key]+x}" ] || order+=("$key")
    _pcrrr_line["$key"]=$(printf '%s\037%s\037%s\037%s' "$dir" "$repo" "$ref" "$sha")
  done < <(planner_crosscheck_repo_refs "$initiative_id")

  for key in "${order[@]}"; do
    printf '%s\n' "${_pcrrr_line[$key]}"
  done
}

# Ensure a tree matching <repo>@<sha> is resolvable under <repos_root>,
# without ever mutating the live checkout (resolved by
# planner_crosscheck_repo_dir, so nested layouts like
# <repos_root>/microservices/<repo> work — #500). If the live checkout's
# current HEAD already matches <sha>, does nothing. Otherwise creates (or
# reuses) an isolated detached worktree alongside the live repo, in the same
# parent directory.
# Best-effort: any failure (not a git repo, sha unresolvable, worktree
# creation fails) is silent and non-fatal — Crosscheck falls back to
# resolving against the live checkout rather than blocking the run over
# infrastructure trouble.
#
# Usage: planner_crosscheck_repo_ref_ensure <repos_root> <repo> <ref> <sha> [live_dir]
#   [live_dir] — an already-resolved live checkout (skips the lookup).
# Output (stdout): the live repo dir's path relative to <repos_root>, if it
# should be excluded from citation resolution in favor of the worktree.
# Empty otherwise.
planner_crosscheck_repo_ref_ensure() {
  local repos_root="${1%/}" repo="$2" ref="$3" sha="$4" live_dir="${5:-}"

  [ -n "$sha" ] || return 0
  [ -n "$live_dir" ] || live_dir=$(planner_crosscheck_repo_dir "$repos_root" "$repo")
  [ -n "$live_dir" ] || return 0

  local live_sha
  live_sha=$(git -C "$live_dir" rev-parse HEAD 2>/dev/null)
  [ -n "$live_sha" ] || return 0
  [ "$live_sha" = "$sha" ] && return 0

  # git worktree add resolves the sha itself — no need to fetch/verify it
  # exists first, the exit code already tells us.
  local safe_ref short_sha worktree_dir
  safe_ref=$(printf '%s' "$ref" | tr -c 'A-Za-z0-9_.' '-')
  short_sha="${sha:0:12}"
  worktree_dir="${live_dir}-crosscheck-${safe_ref}-${short_sha}"

  if [ ! -d "$worktree_dir" ]; then
    git -C "$live_dir" worktree add --detach "$worktree_dir" "$sha" \
      >/dev/null 2>&1 || return 0
  fi
  [ -d "$worktree_dir" ] || return 0

  echo "${live_dir#"${repos_root}"/}"
}

# Apply every repo-ref Discovery recorded for one initiative: for each repo
# whose live checkout no longer matches, ensure an isolated worktree exists
# and collect the live dir's path relative to <repos_root> so the caller can
# exclude exactly that directory (anchored, not by name) from resolution.
#
# Usage: planner_crosscheck_repo_ref_setup <initiative_id> <repos_root>
# Output (stdout): one relative path per line to exclude from citation
# resolution (may be empty — the common case, when the live checkout already
# matches or Discovery recorded no repo-ref).
planner_crosscheck_repo_ref_setup() {
  local initiative_id="$1" repos_root="$2"
  local dir repo ref sha excl

  while IFS=$'\037' read -r dir repo ref sha; do
    [ -n "$dir" ] || continue
    excl=$(planner_crosscheck_repo_ref_ensure "$repos_root" "$repo" "$ref" "$sha" "$dir")
    [ -n "$excl" ] && printf '%s\n' "$excl"
  done < <(planner_crosscheck_repo_refs_resolved "$initiative_id" "$repos_root")
  return 0
}
