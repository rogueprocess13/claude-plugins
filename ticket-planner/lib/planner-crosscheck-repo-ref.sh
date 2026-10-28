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

# ── Base branch (planner-base-branch-config, rehearsal F13) ──────────────────

# A base-branch name safe to interpolate into a prompt as a literal and into
# a Branch Directive: git ref characters only, no leading '-', no '..'.
# Usage: planner_base_branch_name_valid <name>
planner_base_branch_name_valid() {
  local name="$1"
  [ -n "$name" ] || return 1
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 1
  case "$name" in *..* | */ | *.lock) return 1 ;; esac
  return 0
}

# Does <branch> exist in <dir>, locally or on origin?
_planner_base_branch_exists() {
  local dir="$1" branch="$2"
  git -C "$dir" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null ||
    git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null
}

# One repo's base: develop, then origin/HEAD's target, then main, then master.
# Usage: _planner_base_branch_detect <dir>
# Output: the branch, or empty.
_planner_base_branch_detect() {
  local dir="$1" head
  if _planner_base_branch_exists "$dir" develop; then
    echo develop
    return 0
  fi
  head=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  head="${head#origin/}"
  if [ -n "$head" ] && [ "$head" != HEAD ] && planner_base_branch_name_valid "$head"; then
    echo "$head"
    return 0
  fi
  local b
  for b in main master; do
    if _planner_base_branch_exists "$dir" "$b"; then
      echo "$b"
      return 0
    fi
  done
  return 0
}

# Resolve the Branch Directive's base branch for an initiative.
#
# An explicit `base-branch` config key (--base-branch / PLANNER_BASE_BRANCH,
# persisted at argument parsing) must exist in every repo Discovery pinned.
# Without one, each pinned repo is detected (_planner_base_branch_detect); one
# shared answer is persisted as `base-branch` with a
# META|base-branch-source|done|detected:<repo>=<branch>,... line, so a retry
# reuses it. No repo-ref lines at all: `develop`, the historical default.
#
# Failures write META|base-branch-source|fail|<CODE> <detail> and print the
# same line to stderr:
#   BASE_BRANCH_AMBIGUOUS   pinned repos resolve to different branches
#   BASE_BRANCH_UNRESOLVED  a pinned repo resolves to nothing, has no live
#                           checkout, or lacks the explicit base
#   BASE_BRANCH_INVALID     the explicit base is not a usable branch name
#
# Usage: planner_base_branch_resolve <initiative_id>
# Output (stdout): the branch. rc 0 on success, 1 on failure.
planner_base_branch_resolve() {
  local initiative_id="$1"
  local explicit repos_root="${REPOS_ROOT:-}"
  explicit=$(planner_config_get "$initiative_id" "base-branch" 2>/dev/null)

  local dir repo _ref _sha branch
  local -a pairs=() missing=() found=()
  declare -A _pbbr_seen=()

  if [ -n "$explicit" ] && ! planner_base_branch_name_valid "$explicit"; then
    _planner_base_branch_fail "$initiative_id" BASE_BRANCH_INVALID \
      "base-branch '${explicit}' is not a valid branch name — rerun with --base-branch <name>"
    return 1
  fi

  if [ -n "$repos_root" ]; then
    while IFS=$'\037' read -r dir repo _ref _sha; do
      [ -n "$repo" ] || continue
      if [ -z "$dir" ]; then
        missing+=("${repo}=no-checkout")
        continue
      fi
      if [ -n "$explicit" ]; then
        _planner_base_branch_exists "$dir" "$explicit" || missing+=("${repo}=no-${explicit}")
        continue
      fi
      branch=$(_planner_base_branch_detect "$dir")
      if [ -z "$branch" ]; then
        missing+=("${repo}=none")
        continue
      fi
      pairs+=("${repo}=${branch}")
      if [ -z "${_pbbr_seen[$branch]+x}" ]; then
        _pbbr_seen["$branch"]=1
        found+=("$branch")
      fi
    done < <(planner_crosscheck_repo_refs_resolved "$initiative_id" "$repos_root")
  fi

  local IFS=,
  if [ "${#missing[@]}" -gt 0 ]; then
    _planner_base_branch_fail "$initiative_id" BASE_BRANCH_UNRESOLVED \
      "no base branch for ${missing[*]}${pairs:+ (others: ${pairs[*]})} — rerun with --base-branch <name>"
    return 1
  fi
  if [ "${#found[@]}" -gt 1 ]; then
    _planner_base_branch_fail "$initiative_id" BASE_BRANCH_AMBIGUOUS \
      "pinned repos disagree on the base branch (${pairs[*]}) — rerun with --base-branch <name>"
    return 1
  fi
  unset IFS

  if [ -n "$explicit" ]; then
    echo "$explicit"
    return 0
  fi
  if [ "${#found[@]}" -eq 0 ]; then
    planner_state_write "$initiative_id" "META" "base-branch-source" "done" "default" >/dev/null 2>&1 || true
    echo develop
    return 0
  fi
  local IFS=,
  planner_config_set "$initiative_id" "base-branch" "${found[0]}" >/dev/null 2>&1 || true
  planner_state_write "$initiative_id" "META" "base-branch-source" "done" \
    "detected:${pairs[*]}" >/dev/null 2>&1 || true
  echo "${found[0]}"
}

_planner_base_branch_fail() {
  local initiative_id="$1" code="$2" detail="$3"
  echo "${code}: ${detail}" >&2
  planner_state_write "$initiative_id" "META" "base-branch-source" "fail" "${code} ${detail}" >/dev/null 2>&1 || true
}

# Argument-parsing half (SKILL.md). Both run in the shell that parsed the
# flags and are the only readers of PLANNER_MERGE_POLICY / PLANNER_SYNC_POLICY:
# later phases read the config keys, never the environment.
#
# Usage: planner_directive_config_check <base_branch_ref>
# rc 1 (message on stderr) on an invalid base name or merge/sync enum.
planner_directive_config_check() {
  local base="$1"
  if [ -n "$base" ] && ! planner_base_branch_name_valid "$base"; then
    echo "ERROR: --base-branch '${base}' is not a valid branch name" >&2
    return 1
  fi
  case "${PLANNER_MERGE_POLICY:-}" in
  "" | manual | on-all-children-done) ;;
  *)
    echo "ERROR: PLANNER_MERGE_POLICY takes manual or on-all-children-done, got '${PLANNER_MERGE_POLICY}'" >&2
    return 1
    ;;
  esac
  case "${PLANNER_SYNC_POLICY:-}" in
  "" | rebase-on-base-change | none) ;;
  *)
    echo "ERROR: PLANNER_SYNC_POLICY takes rebase-on-base-change or none, got '${PLANNER_SYNC_POLICY}'" >&2
    return 1
    ;;
  esac
}

# Usage: planner_directive_config_persist <initiative_id> <base_branch_ref>
# Persists each non-empty value as its config key. Call after the check.
# Sync policy `none` is stored as `no-sync`: planner_config_get reads `none`
# as the clear marker, so it would come back empty and silently become the
# default. Epic Gen maps it back (planner_prompt_epicgen).
planner_directive_config_persist() {
  local initiative_id="$1" base="$2" sync="${PLANNER_SYNC_POLICY:-}"
  [ "$sync" = "none" ] && sync="no-sync"
  [ -n "$base" ] && planner_config_set "$initiative_id" "base-branch" "$base"
  [ -n "${PLANNER_MERGE_POLICY:-}" ] && planner_config_set "$initiative_id" "merge-policy" "$PLANNER_MERGE_POLICY"
  [ -n "$sync" ] && planner_config_set "$initiative_id" "sync-policy" "$sync"
  return 0
}
