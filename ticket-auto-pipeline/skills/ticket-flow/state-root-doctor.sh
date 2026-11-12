#!/usr/bin/env bash
# state-root-doctor.sh — read-only check for split per-ticket state
# (state-root-anchor, review ARCH-5).
#
# Usage: state-root-doctor.sh [--repos-root DIR]
#
# REPOS_ROOT is --repos-root, else $REPOS_ROOT, else the REPOS_ROOT field of
# ./CLAUDE.md. Prints, one per line:
#   REPOS_ROOT: <dir>
#   ANCHOR_FILE: <dir>/.ticket-auto/log-dir
#   ANCHOR: <value> | (none) | (invalid)
#   RESOLVED: <dir> | (unresolved)        what lib/log-dir.sh resolves now
# then scans REPOS_ROOT (skipping .git and node_modules) for *-outbox.jsonl
# and *-pipeline.log files:
#   resolved:   STRAY: <file>   for every one outside the resolved dir
#   unresolved: STATE_DIR: <dir> for every directory holding any (the
#               pre-upgrade run: one dir is the one to anchor; two or more is
#               a split)
#   SUMMARY: strays=<n> | state_dirs=<n>
#
# Never writes, moves or anchors anything. Strays are re-projected by hand
# (design Open Question 4); to anchor, run env-check.sh --anchor-log-dir.
#
# Exit codes: 0 no strays (unresolved: at most one state dir), 1 strays
# found (unresolved: two or more state dirs), 2 usage / no REPOS_ROOT.
set -eo pipefail

_SRD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Plugin layout (skills/ticket-flow -> lib), else the synced
# ~/.claude/skills/ticket-flow copy's ~/.claude/skills/lib.
_SRD_LIB_DIR="$_SRD_DIR/../../lib"
[ -f "$_SRD_LIB_DIR/log-dir.sh" ] || _SRD_LIB_DIR="$_SRD_DIR/../lib"
[ -f "$_SRD_LIB_DIR/log-dir.sh" ] || _SRD_LIB_DIR="$HOME/.claude/skills/lib"
source "$_SRD_LIB_DIR/log-dir.sh"
source "$_SRD_LIB_DIR/claude-md-field.sh"

rr=""
while [ $# -gt 0 ]; do
  case "$1" in
  --repos-root)
    [ $# -ge 2 ] || {
      echo "state-root-doctor.sh: --repos-root needs a directory" >&2
      exit 2
    }
    rr="$2"
    shift 2
    ;;
  --repos-root=*)
    rr="${1#*=}"
    shift
    ;;
  -h | --help)
    sed -n '2,25p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "state-root-doctor.sh: unknown argument: $1" >&2
    exit 2
    ;;
  esac
done
if [ -z "$rr" ]; then
  rr="${REPOS_ROOT:-}"
fi
if [ -z "$rr" ] && [ -f ./CLAUDE.md ]; then
  rr=$(claude_md_field ./CLAUDE.md REPOS_ROOT 2>/dev/null) || rr=""
fi
if [ -z "$rr" ] || [ ! -d "$rr" ]; then
  echo "state-root-doctor.sh: REPOS_ROOT is not set or not a directory (use --repos-root DIR)" >&2
  exit 2
fi
rr=$(cd "$rr" && pwd -P)
export REPOS_ROOT="$rr"

anchor_file="$rr/.ticket-auto/log-dir"
if anchor=$(_tld_anchor_read "$anchor_file"); then
  :
elif [ -e "$anchor_file" ]; then
  anchor="(invalid)"
else
  anchor="(none)"
fi
resolved=""
resolved=$(ticket_log_dir 2>/dev/null) || resolved=""

echo "REPOS_ROOT: $rr"
echo "ANCHOR_FILE: $anchor_file"
echo "ANCHOR: $anchor"
echo "RESOLVED: ${resolved:-(unresolved)}"

resolved_phys=""
if [ -n "$resolved" ]; then
  resolved_phys=$(cd "$resolved" 2>/dev/null && pwd -P) || resolved_phys=$(realpath -m -- "$resolved")
fi

strays=0
declare -A state_dirs=()
while IFS= read -r -d '' f; do
  d=$(cd "$(dirname "$f")" 2>/dev/null && pwd -P) || continue
  if [ -n "$resolved_phys" ]; then
    if [ "$d" != "$resolved_phys" ]; then
      echo "STRAY: $f"
      strays=$((strays + 1))
    fi
  else
    state_dirs["$d"]=1
  fi
done < <(find "$rr" \( -name .git -o -name node_modules \) -prune -o \
  -type f \( -name '*-outbox.jsonl' -o -name '*-pipeline.log' \) -print0 2>/dev/null | sort -z)

if [ -n "$resolved_phys" ]; then
  echo "SUMMARY: strays=$strays"
  [ "$strays" -eq 0 ] || exit 1
  exit 0
fi

n=${#state_dirs[@]}
if [ "$n" -gt 0 ]; then
  printf '%s\n' "${!state_dirs[@]}" | sort | sed 's/^/STATE_DIR: /'
fi
echo "SUMMARY: state_dirs=$n"
if [ "$n" -eq 1 ]; then
  echo "NOTE: not anchored; to anchor: env-check.sh --anchor-log-dir ${!state_dirs[*]}"
fi
[ "$n" -le 1 ] || exit 1
exit 0
