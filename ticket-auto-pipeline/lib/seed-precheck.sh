#!/usr/bin/env bash
# seed-precheck.sh — ticket-verify Step 1.6d: run the seeder scenarios this
# ticket changed, twice each, before any acceptance criterion (GitHub #601).
#
# Why: a ticket's own seeder scenario used to run first inside the VERIFY
# criteria, after ~25 minutes of other checks, where a plain contract bug or
# a clean-DB timing race then cost a re-implement and a second full VERIFY.
# Step 1.6d runs inside VERIFY's locked section, on its clean baseline
# (env-start.sh + seed-apply.sh), so the failure arrives first.
#
# Trust model (same as seed-apply.sh): nothing a tracker user can edit is
# ever executed or parsed into a command.
#   - Scenario names come ONLY from the seed tool's own git history: the
#     commits whose message names this ticket id (any ref), restricted to the
#     seed directory, and only `scenario_<name>()` functions those commits add
#     or change. Never from context.md, the tracker description, comments or
#     the plan artifact — a scenario a blocker or an AC merely mentions is not
#     this ticket's.
#   - Each name must match ^[A-Za-z0-9]([A-Za-z0-9_]{0,62}[A-Za-z0-9])?$
#     (no trailing `.`/`-`, no flags) and be defined as `scenario_<name>` in
#     the checked-out seed directory. `baseline` is the reset step, never a
#     scenario.
#   - The run is an argv list: `bash <seed-dir>/seed.sh <name>`, no `bash -c`,
#     no eval, under `timeout` (SEED_APPLY_TIMEOUT_SECS, default 900), from
#     the verify worktree.
#
# Usage:
#   seed-precheck.sh <TID> <worktree> [--seed-dir D] [--claude-md F]
#                    [--log-file L] [--release-on-fail]
#   --seed-dir  default: $WIKI_ROOT (env, else the CLAUDE.md WIKI_ROOT field,
#               --claude-md default ./CLAUDE.md) + /api/_tools/seed
#   --release-on-fail  release the verify lock (lib/verify-lock.sh) when a
#               run fails, before returning
#
# Output (eval-safe, %q values):
#   SEED_PRECHECK_STATUS=pass|fail|skip|unavailable
#   SEED_PRECHECK_SCENARIOS=<names>   SEED_PRECHECK_MSG=<one line>
# --log-file writes VERIFY|seed-precheck|start, then done|<names> x2,
# skip|<reason> (skip and unavailable) or fail|<name> run <n>: <reason>.
#
# Exit: 0 pass/skip, 1 fail, 3 unavailable (no seed dir / not a git repo /
# a changed scenario is not defined in the checked-out seed dir), 2 usage.

_SP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SP_NAME_RE='^[A-Za-z0-9]([A-Za-z0-9_]{0,62}[A-Za-z0-9])?$'

_sp_usage() {
  echo "usage: seed-precheck.sh <TID> <worktree> [--seed-dir D] [--claude-md F] [--log-file L] [--release-on-fail]" >&2
  exit 2
}

tid="${1:-}" wt="${2:-}"
[ -n "$tid" ] && [ -n "$wt" ] || _sp_usage
[[ "$tid" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || _sp_usage
[ -d "$wt" ] || _sp_usage
shift 2
seed_dir="" claude_md="./CLAUDE.md" log_file="" release=false
while [ "$#" -gt 0 ]; do
  case "$1" in
  --seed-dir | --claude-md | --log-file)
    [ "$#" -ge 2 ] || _sp_usage
    case "$1" in
    --seed-dir) seed_dir="$2" ;;
    --claude-md) claude_md="$2" ;;
    --log-file) log_file="$2" ;;
    esac
    shift 2
    ;;
  --release-on-fail)
    release=true
    shift
    ;;
  *) _sp_usage ;;
  esac
done

_sp_log() {
  [ -n "$log_file" ] || return 0
  bash "$_SP_LIB/plog.sh" --log-file "$log_file" VERIFY seed-precheck "$1" "$2" || true
}

_sp_out() {
  printf 'SEED_PRECHECK_STATUS=%q\nSEED_PRECHECK_SCENARIOS=%q\nSEED_PRECHECK_MSG=%q\n' "$1" "$2" "$3"
}

if [ -z "$seed_dir" ]; then
  wiki="${WIKI_ROOT:-}"
  if [ -z "$wiki" ] && [ -f "$claude_md" ]; then
    # shellcheck source=claude-md-field.sh
    source "$_SP_LIB/claude-md-field.sh"
    wiki=$(claude_md_field "$claude_md" WIKI_ROOT 2>/dev/null) || wiki=""
  fi
  [ -n "$wiki" ] && seed_dir="$wiki/api/_tools/seed"
fi

if [ -z "$seed_dir" ] || [ ! -f "$seed_dir/seed.sh" ]; then
  msg="no seed tool (seed.sh) at '${seed_dir:-<WIKI_ROOT unset>}'"
  _sp_log skip "unavailable: $msg"
  _sp_out unavailable "" "$msg"
  exit 3
fi
if ! git -C "$seed_dir" rev-parse --git-dir >/dev/null 2>&1; then
  msg="seed dir $seed_dir is not in a git repository; cannot tell which scenarios this ticket changed"
  _sp_log skip "unavailable: $msg"
  _sp_out unavailable "" "$msg"
  exit 3
fi

# This ticket's commits (any ref) that touch the seed directory, then the
# scenario functions they add or change: an added/removed definition line,
# or a hunk whose function context is a scenario.
tid_re="(^|[^A-Za-z0-9-])${tid}([^0-9]|\$)"
names=$(
  git -C "$seed_dir" log --all -E --grep="$tid_re" --format=%H -- . 2>/dev/null |
    while read -r c; do
      git -C "$seed_dir" show --format= --unified=0 "$c" -- . 2>/dev/null
    done |
    sed -nE 's/^[+-][[:space:]]*scenario_([A-Za-z0-9_]+)[[:space:]]*\(\).*/\1/p; s/^@@ .* @@[[:space:]]*scenario_([A-Za-z0-9_]+)[[:space:]]*\(\).*/\1/p' |
    sort -u
)

runnable=() missing=()
while IFS= read -r n; do
  [ -n "$n" ] || continue
  [ "$n" = baseline ] && continue
  [[ "$n" =~ $_SP_NAME_RE ]] || continue
  if grep -qE "^[[:space:]]*scenario_${n}[[:space:]]*\(\)" "$seed_dir"/*.sh 2>/dev/null; then
    runnable+=("$n")
  else
    missing+=("$n")
  fi
done <<<"$names"

if [ "${#missing[@]}" -gt 0 ]; then
  msg="scenario(s) ${missing[*]} changed by ${tid} are not defined in the checked-out seed dir $seed_dir"
  _sp_log skip "unavailable: $msg"
  _sp_out unavailable "${missing[*]}" "$msg"
  exit 3
fi
if [ "${#runnable[@]}" -eq 0 ]; then
  _sp_log skip "no seeder scenario changed by ${tid}"
  _sp_out skip "" "no seeder scenario changed by ${tid}"
  exit 0
fi

secs="${SEED_APPLY_TIMEOUT_SECS:-900}"
case "$secs" in '' | *[!0-9]*) secs=900 ;; esac
_sp_log start "${runnable[*]} x2 (timeout ${secs}s per run)"
for n in "${runnable[@]}"; do
  for run in 1 2; do
    rc=0
    if [ "$secs" != 0 ] && command -v timeout >/dev/null 2>&1; then
      (cd "$wt" && timeout -k 10 "$secs" bash -- "$seed_dir/seed.sh" "$n") >&2 || rc=$?
    else
      (cd "$wt" && bash -- "$seed_dir/seed.sh" "$n") >&2 || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        why="timed out after ${secs}s"
      else
        why="exited $rc"
      fi
      msg="$n run $run: $why"
      _sp_log fail "$msg"
      if [ "$release" = true ]; then
        # shellcheck source=verify-lock.sh
        source "$_SP_LIB/verify-lock.sh" 2>/dev/null && verify_lock_release >/dev/null 2>&1
      fi
      _sp_out fail "${runnable[*]}" "$msg"
      exit 1
    fi
  done
done

_sp_log done "${runnable[*]} x2"
_sp_out pass "${runnable[*]}" "${runnable[*]} ran twice"
exit 0
