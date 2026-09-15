#!/usr/bin/env bash
# openspec-tracking-check.sh — deterministic durability guard for openspec plan
# artifacts (issue #363, OPENSPEC_ARTIFACTS_UNTRACKED).
#
# openspec/changes/{change-name}/ is the plan of record for a complex ticket —
# proposal, design.md, tasks.md, and spec deltas. The tickets repo (the
# workspace whose basename the shared preamble Guard requires to be
# "tickets") is the pipeline's canonical durable home for these directories:
# both ticket-appraise-exec and ticket-implement resolve `openspec/changes/*/`
# relative to that same CWD. Durability was previously assumed, never
# enforced — a ticket workspace repo whose root .gitignore blanket-ignores
# `openspec/` (a pattern that predates this requirement, often copied from a
# code-repo template where the pipeline never writes openspec artifacts at
# all) silently swallows every change dir `git add` would otherwise pick up,
# and nothing downstream ever notices.
#
# Deliberately scoped to the tickets repo only — never the code repos a
# ticket touches. If a code repo's own `openspec/` ignore is deliberate (its
# own unrelated openspec dogfooding, if any), that is not this script's
# concern; it never runs `git` inside anything but the tickets repo CWD.
#
# Three subcommands:
#   commit  — idempotent `git add -f` + commit of one change dir. Called by
#             ticket-appraise-exec immediately after the artifact is written.
#             Always runs against CWD — callers must invoke it from the
#             tickets repo (no --root; it is meant to run right after the
#             artifact is written, before any worktree cd happens).
#   assert  — read-only tracked/untracked check for one ticket's change dir.
#             Called by ticket-implement's close-out to warn (never gate-stop)
#             when the artifact that drove the implementation was never
#             persisted. Accepts --root <path> so a caller does not have to
#             trust ambient CWD after an earlier step `cd`'d into a code
#             worktree — pass the tickets repo path explicitly.
#   audit   — one-off sweep of every openspec/changes/*/ dir under a tickets
#             repo (--root <path>, default CWD), for detecting pre-existing
#             untracked artifacts.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_OTC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_OTC_LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
if [ -f "$_OTC_LIB_DIR/heartbeat.sh" ]; then
  source "$_OTC_LIB_DIR/heartbeat.sh"
elif [ -f "$_OTC_SCRIPT_DIR/heartbeat.sh" ]; then
  source "$_OTC_SCRIPT_DIR/heartbeat.sh"
fi

usage() {
  cat >&2 <<'EOF'
Usage: openspec-tracking-check.sh commit <change-dir> <TICKET-ID>
       openspec-tracking-check.sh assert <TICKET-ID> [--expect] [--root <path>]
       openspec-tracking-check.sh audit [--root <path>]

commit always runs `git` against the current working directory — always the
tickets repo (the shared preamble Guard already requires this). assert and
audit accept --root so a caller need not trust ambient CWD (e.g. after a
prior step `cd`'d into a code worktree). Never point any subcommand at a
code repo.

commit <change-dir> <TICKET-ID>
  Force-adds and commits <change-dir> if it has anything untracked or
  modified relative to HEAD. Idempotent: a no-op when the dir is already
  tracked and unchanged. Refuses any <change-dir> not under openspec/changes/
  (defensive path guard — this subcommand force-adds past .gitignore).
  Exit 0 committed or no-op, 2 usage/git error.

assert <TICKET-ID> [--expect] [--root <path>]
  Locates the openspec change dir for TICKET-ID under <path>/openspec/changes/
  (default --root: current directory; case-insensitive match on the
  directory name, same convention as ticket-dir.sh) and reports its tracking
  status: tracked, partial (some files untracked, or a tracked file has an
  uncommitted modification — unstaged or staged), untracked, gitignored, or
  missing. Without a match: status `not-applicable` (exit 0) unless --expect
  is given, in which case a missing or empty change dir is status `missing`
  (exit 1) — pass --expect when the ticket's notes.md declares
  COMPLEXITY=complex, so a deleted-on-disk change dir is caught, not
  silently treated as "nothing to check".

audit [--root <path>]
  Scans <path>/openspec/changes/*/ (default: current directory) and reports
  one OPENSPEC_TRACK line per change dir plus an OPENSPEC_TRACK_SUMMARY line.

Emits KEY=value lines. Exit: 0 clean, 1 issue(s) found (untracked/missing),
2 usage or git error.
EOF
  exit 2
}

# ── Status classification ──────────────────────────────────────────────────

# Classifies a single change dir's git tracking state. Echoes one of:
#   tracked     — every file in the dir is tracked, staged clean, and matches
#                 HEAD (no unstaged or staged-but-uncommitted modifications)
#   partial     — some files tracked, some untracked, OR a tracked file has
#                 an unstaged/staged modification not yet committed
#   untracked   — dir exists, nothing in it is tracked, and it is not ignored
#   gitignored  — dir exists, nothing in it is tracked, and it IS ignored —
#                 the exact failure mode named in issue #363
#   missing     — dir does not exist on disk at all
_dir_status() {
  local dir="$1"
  [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ] || {
    echo "missing"
    return
  }

  local tracked_count untracked_count ignored_count modified
  tracked_count=$(git ls-files -- "$dir" 2>/dev/null | wc -l | tr -d ' ')
  untracked_count=$(git status --porcelain --ignored -- "$dir" 2>/dev/null | grep -c '^??' || true)
  untracked_count="${untracked_count:-0}"
  ignored_count=$(git status --porcelain --ignored -- "$dir" 2>/dev/null | grep -c '^!!' || true)
  ignored_count="${ignored_count:-0}"

  # A tracked file with an uncommitted modification (unstaged OR staged) is
  # not durable — its last-committed content is stale relative to disk, the
  # exact "regenerated content / commit reverted between exec and implement"
  # scenario Step 5.5 exists to catch. `git status --porcelain` above only
  # ever reports `??`/`!!` prefixes for genuinely untracked/ignored paths —
  # a tracked-but-modified file shows as ` M`/`M ` there, which neither
  # counter catches, so it needs its own check.
  modified=0
  git diff --quiet -- "$dir" 2>/dev/null || modified=1
  if [ "$modified" -eq 0 ]; then
    git diff --cached --quiet -- "$dir" 2>/dev/null || modified=1
  fi

  if [ "$tracked_count" -gt 0 ] && [ "$untracked_count" -eq 0 ] && [ "$modified" -eq 0 ]; then
    echo "tracked"
  elif [ "$tracked_count" -gt 0 ]; then
    echo "partial"
  elif [ "$ignored_count" -gt 0 ]; then
    echo "gitignored"
  else
    echo "untracked"
  fi
}

# ── commit ────────────────────────────────────────────────────────────────

_cmd_commit() {
  local dir="$1" ticket_id="$2"

  [ -n "$dir" ] && [ -n "$ticket_id" ] || usage
  # Defensive path guard: only ever force-add something under
  # openspec/changes/ — never an arbitrary caller-supplied path. Matches a
  # leading "openspec/changes/" whether or not $dir carries a trailing slash
  # or a "./" prefix.
  case "${dir#./}" in
  openspec/changes/*) ;;
  *)
    echo "ERROR: refusing to commit a path outside openspec/changes/: $dir" >&2
    return 2
    ;;
  esac
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "ERROR: not inside a git repo: $(pwd)" >&2
    return 2
  }
  if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "ERROR: change dir not found or empty: $dir" >&2
    return 2
  fi

  # Force-add: openspec/ may be blanket-gitignored in the tickets repo by a
  # convention that predates this durability requirement. The tickets repo
  # is the designated durable home for these artifacts regardless of that
  # ignore rule — see file header.
  git add -f -- "$dir"

  if git diff --cached --quiet -- "$dir"; then
    echo "OPENSPEC_COMMIT_STATUS=noop"
    hb_gate "openspec-tracking" "ok" "already tracked, nothing to commit" \
      "{\"ticket\":\"$ticket_id\",\"dir\":\"$dir\"}" 2>/dev/null || true
    return 0
  fi

  git commit -q -m "docs(${ticket_id}): commit openspec change for durability" -- "$dir"
  echo "OPENSPEC_COMMIT_STATUS=committed"
  hb_gate "openspec-tracking" "ok" "committed openspec change" \
    "{\"ticket\":\"$ticket_id\",\"dir\":\"$dir\"}" 2>/dev/null || true
  return 0
}

# ── assert ────────────────────────────────────────────────────────────────

_find_change_dir() {
  local ticket_id="$1" ticket_lower
  ticket_lower=$(echo "$ticket_id" | tr '[:upper:]' '[:lower:]')
  ls -d openspec/changes/*/ 2>/dev/null | grep -i "$ticket_lower" | head -1 || true
}

_cmd_assert() {
  local ticket_id="" expect="" root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --expect)
      expect="--expect"
      shift
      ;;
    --root)
      root="${2:-.}"
      shift 2
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      usage
      ;;
    *)
      if [ -z "$ticket_id" ]; then
        ticket_id="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage
      fi
      ;;
    esac
  done
  [ -n "$ticket_id" ] || usage

  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "ERROR: not inside a git repo: $root" >&2
    return 2
  }

  # Every git call below must run with CWD == $root (relative pathspecs like
  # "openspec/changes/*/" and the dir _find_change_dir/_dir_status resolve
  # are relative to it) — a caller's ambient CWD is never trusted, only
  # $root. Default "." preserves old behavior (CWD is the tickets repo).
  local change_dir status
  change_dir=$(cd "$root" && _find_change_dir "$ticket_id")

  if [ -z "$change_dir" ]; then
    if [ "$expect" = "--expect" ]; then
      echo "OPENSPEC_TRACK_STATUS=missing"
      echo "TICKET_ID=$ticket_id"
      hb_gate "openspec-tracking" "warn" "expected openspec change dir not found" \
        "{\"ticket\":\"$ticket_id\"}" 2>/dev/null || true
      return 1
    fi
    echo "OPENSPEC_TRACK_STATUS=not-applicable"
    echo "TICKET_ID=$ticket_id"
    return 0
  fi

  status=$(cd "$root" && _dir_status "$change_dir")
  echo "OPENSPEC_TRACK_STATUS=$status"
  echo "TICKET_ID=$ticket_id"
  if [ "$root" = "." ]; then
    echo "CHANGE_DIR=${change_dir}"
  else
    echo "CHANGE_DIR=${root%/}/${change_dir}"
  fi

  case "$status" in
  tracked)
    return 0
    ;;
  *)
    hb_gate "openspec-tracking" "warn" "openspec change dir is $status" \
      "{\"ticket\":\"$ticket_id\",\"dir\":\"$change_dir\",\"status\":\"$status\"}" 2>/dev/null || true
    return 1
    ;;
  esac
}

# ── audit ─────────────────────────────────────────────────────────────────

_cmd_audit() {
  local root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --root)
      root="${2:-.}"
      shift 2
      ;;
    *)
      echo "Unknown flag: $1" >&2
      usage
      ;;
    esac
  done

  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "ERROR: not inside a git repo: $root" >&2
    return 2
  }

  local issues=0 total=0 change_dir status
  # Process substitution (not a pipe) so counters set in the loop body
  # survive in this shell rather than a subshell.
  while IFS= read -r change_dir; do
    [ -n "$change_dir" ] || continue
    total=$((total + 1))
    status=$(cd "$root" && _dir_status "$change_dir")
    [ "$status" = "tracked" ] || issues=$((issues + 1))
    echo "OPENSPEC_TRACK|${root%/}/${change_dir}|$status"
  done < <(cd "$root" && ls -d openspec/changes/*/ 2>/dev/null || true)

  echo "OPENSPEC_TRACK_SUMMARY|total=$total|issues=$issues"

  [ "$issues" -eq 0 ]
}

# ── Main dispatch (only when executed directly, not when sourced for testing) ─

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  SUBCOMMAND="${1:-}"
  [ -n "$SUBCOMMAND" ] && shift || true

  case "$SUBCOMMAND" in
  commit)
    _cmd_commit "$@"
    exit $?
    ;;
  assert)
    _cmd_assert "$@"
    exit $?
    ;;
  audit)
    _cmd_audit "$@"
    exit $?
    ;;
  --help | -h | "")
    usage
    ;;
  *)
    echo "Unknown subcommand: $SUBCOMMAND" >&2
    usage
    ;;
  esac
fi
