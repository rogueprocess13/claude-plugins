#!/usr/bin/env bash
# plan-append-review.sh — ticket-pr-iterate Steps 3–4: number the next
# `## PR Review #N` section of the plan artifact and append it atomically
# (skill-deterministic-extraction 2).
#
# Usage:
#   plan-append-review.sh next   <TID> [--ticket-dir D] [--root R] [--log-file F]
#   plan-append-review.sh append <TID> --n N --section FILE
#                                [--ticket-dir D] [--root R] [--log-file F]
#
# The plan artifact is whatever `ticket-dir.sh plan` resolves (the one
# plan-artifact resolver: simple-fix.md, or the openspec change's tasks.md).
#
# next   prints PLAN_MODE=, PLAN_PATH=, ARTIFACT=<basename>, N=<existing
#        `## PR Review #` sections + 1>. Exit 4 when N > 3 (the iteration
#        guard; the stop message goes to stdout). The resolver's own exits pass
#        through: 2 several change dirs match, 12 no plan artifact.
# append writes the agent-authored FILE (it must open with `## PR Review #N`)
#        to the end of the artifact via a same-directory temp file and `mv`, so
#        a crash never leaves a truncated plan. If the artifact already holds a
#        `## PR Review #N` heading (a resumed run), nothing is written. Then it
#        verifies the heading is present and logs one line:
#          PR-REVIEW|iterate-plan|done|<ARTIFACT> updated, iteration #N
#          PR-REVIEW|iterate-plan|fail|PR Review #N section missing after write — <PLAN_PATH>
#        Exit 0 done, 1 the section is missing after the write (stop: a
#        truncated write would make ticket-implement skip every gap), 3 FILE
#        does not open with the expected heading.
# Exit 2 also covers usage errors.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_PAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PAR_MAX=3

_par_usage() {
  echo "Usage: plan-append-review.sh next <TID> [--ticket-dir D] [--root R] [--log-file F]" >&2
  echo "       plan-append-review.sh append <TID> --n N --section FILE [--ticket-dir D] [--root R] [--log-file F]" >&2
  exit 2
}

_par_cmd="${1:-}"
case "$_par_cmd" in next | append) shift ;; *) _par_usage ;; esac

_par_tid="" _par_tdir="" _par_root="." _par_n="" _par_section=""
_par_log="${LOG_FILE:-${TAP_LOG:-}}"
while [ $# -gt 0 ]; do
  case "$1" in
  --ticket-dir | --root | --log-file | --n | --section)
    [ $# -ge 2 ] || _par_usage
    case "$1" in
    --ticket-dir) _par_tdir="$2" ;;
    --root) _par_root="$2" ;;
    --log-file) case "$2" in "" | "{"*"}") ;; *) _par_log="$2" ;; esac ;;
    --n) _par_n="$2" ;;
    --section) _par_section="$2" ;;
    esac
    shift 2
    ;;
  -*) _par_usage ;;
  *)
    [ -z "$_par_tid" ] || _par_usage
    _par_tid="$1"
    shift
    ;;
  esac
done
[ -n "$_par_tid" ] || _par_usage

_par_args=("$_par_tid" --root "$_par_root")
[ -z "$_par_tdir" ] || _par_args+=(--ticket-dir "$_par_tdir")
_par_rc=0
_par_out=$(bash "$_PAR_DIR/ticket-dir.sh" plan "${_par_args[@]}") || _par_rc=$?
[ "$_par_rc" -eq 0 ] || exit "$_par_rc"
PLAN_MODE=$(sed -n 's/^PLAN_MODE=//p' <<<"$_par_out" | head -1)
PLAN_PATH=$(sed -n 's/^PLAN_PATH=//p' <<<"$_par_out" | head -1)
[ -n "$PLAN_PATH" ] && [ -f "$PLAN_PATH" ] || exit 12
ARTIFACT=$(basename "$PLAN_PATH")

_par_count() { grep -c "^## PR Review #$1" "$PLAN_PATH" 2>/dev/null || true; }

if [ "$_par_cmd" = next ]; then
  _par_next=$(($(_par_count '') + 1))
  echo "PLAN_MODE=$PLAN_MODE"
  echo "PLAN_PATH=$PLAN_PATH"
  echo "ARTIFACT=$ARTIFACT"
  echo "N=$_par_next"
  if [ "$_par_next" -gt "$_PAR_MAX" ]; then
    echo "${_par_tid} has reached ${_PAR_MAX} PR review iterations. Manual intervention recommended — the plan may need a full re-appraisal."
    exit 4
  fi
  exit 0
fi

# append
[[ "$_par_n" =~ ^[0-9]+$ ]] && [ -n "$_par_section" ] || _par_usage
[ -r "$_par_section" ] || {
  echo "plan-append-review: cannot read $_par_section" >&2
  exit 2
}
_par_first=$(grep -m1 '[^[:space:]]' "$_par_section" || true)
if ! [[ "$_par_first" =~ ^"## PR Review #${_par_n}"([^0-9]|$) ]]; then
  echo "plan-append-review: $_par_section must open with '## PR Review #${_par_n}' (found: ${_par_first:-nothing})" >&2
  exit 3
fi

_par_has_n() { grep -qE "^## PR Review #${_par_n}([^0-9]|$)" "$PLAN_PATH" 2>/dev/null; }

if ! _par_has_n; then
  _par_tmp=$(mktemp "$(dirname "$PLAN_PATH")/.${ARTIFACT}.XXXXXX")
  trap 'rm -f "$_par_tmp"' EXIT
  cp -p "$PLAN_PATH" "$_par_tmp"
  # Separate from the previous content by exactly one blank line.
  if [ -s "$_par_tmp" ]; then
    [ -z "$(tail -c1 "$_par_tmp")" ] || printf '\n' >>"$_par_tmp"
    [ -z "$(tail -n1 "$_par_tmp")" ] || printf '\n' >>"$_par_tmp"
  fi
  cat "$_par_section" >>"$_par_tmp"
  [ -z "$(tail -c1 "$_par_tmp")" ] || printf '\n' >>"$_par_tmp"
  mv -f "$_par_tmp" "$PLAN_PATH"
  trap - EXIT
fi

_par_plog() {
  if [ -n "$_par_log" ]; then
    bash "$_PAR_DIR/plog.sh" --log-file "$_par_log" PR-REVIEW iterate-plan "$@" || true
  else
    bash "$_PAR_DIR/plog.sh" PR-REVIEW iterate-plan "$@" || true
  fi
}

if _par_has_n; then
  _par_plog done "${ARTIFACT} updated, iteration #${_par_n}"
  echo "ARTIFACT=$ARTIFACT"
  echo "N=$_par_n"
  exit 0
fi
_par_plog fail "PR Review #${_par_n} section missing after write — ${PLAN_PATH}"
exit 1
