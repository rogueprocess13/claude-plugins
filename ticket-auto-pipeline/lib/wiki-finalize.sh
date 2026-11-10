#!/usr/bin/env bash
# wiki-finalize.sh — wiki-maintenance Steps 4 and 4.5 in one call
# (skill-deterministic-extraction 6a): refresh the WIKI_ROOT lock, run the
# Accepted-ADR immutability gate, make the scoped commit, release the lock,
# then run the whole-store integrity pass.
#
# Usage:
#   wiki-finalize.sh --wiki-root R --ticket T --message M [--log-file F]
#
# R may be empty: an empty or non-git R is the "not configured" skip, never a
# commit in the current directory (`git -C ""` is not an error).
#
# Order, and the log lines it writes (MAINTENANCE phase, via plog.sh; F or
# the caller's LOG_FILE/TAP_LOG):
#   1. not configured  -> wiki-commit|skip|WIKI_ROOT not configured or not a git repo
#   2. `wiki-lock.sh acquire` (refreshes the lock's age). Not 0 -> another run
#      broke the lock as stale: wiki-commit|skip|WIKI_ROOT lock not re-acquired
#      (rc N) — commit skipped, and go to the release.
#   3. adr-check.sh: ACCEPTED_ADR_MODIFIED -> wiki-commit|fail|… commit
#      refused, lock released, exit 1 (no integrity pass). Any other
#      violation -> adr-check|warn, commit goes ahead.
#   4. `wiki-lock.sh commit`: 0 ok; 6 nothing of this run's; 5 lock not held
#      -> wiki-commit|fail; anything else -> wiki-commit|fail|git commit failed.
#   5. `wiki-lock.sh release` (stdout shown), when R is a directory.
#   6. wiki-verify.sh when R is a directory: rc 2 -> wiki-verify|fail, other
#      non-zero -> wiki-verify|warn|<N> violations found. Never fails the run.
#
# The lock is released on every exit path: an EXIT trap is installed before
# the acquire and releases quietly unless the normal release already ran.
# wiki-lock.sh release is identity-safe (it never releases another ticket's
# lock), so the trap cannot break someone else's.
#
# Exit codes: 0 done (including skips and warnings), 1 Accepted ADR modified,
# 2 usage.
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_WF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_wf_usage() {
  sed -n '7,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

_WF_ROOT="" _WF_TID="" _WF_MSG="" _WF_LOG="" _wf_root_set=0
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || _wf_usage
  case "$1" in
  --wiki-root)
    _WF_ROOT="$2"
    _wf_root_set=1
    ;;
  --ticket) _WF_TID="$2" ;;
  --message) _WF_MSG="$2" ;;
  --log-file) _WF_LOG="$2" ;;
  *) _wf_usage ;;
  esac
  shift 2
done
[ "$_wf_root_set" = 1 ] && [ -n "$_WF_TID" ] && [ -n "$_WF_MSG" ] || _wf_usage

_wf_plog() {
  if [ -n "$_WF_LOG" ]; then
    bash "$_WF_DIR/plog.sh" --log-file "$_WF_LOG" MAINTENANCE "$@"
  else
    bash "$_WF_DIR/plog.sh" MAINTENANCE "$@"
  fi
}

_wlock="$_WF_DIR/wiki-lock.sh"
_wf_released=0
_wf_release() {
  bash "$_wlock" release --wiki-root "$_WF_ROOT" --ticket "$_WF_TID"
  _wf_released=1
}
_wf_trap() {
  if [ "$_wf_released" = 0 ] && [ -n "$_WF_ROOT" ] && [ -d "$_WF_ROOT" ]; then
    bash "$_wlock" release --wiki-root "$_WF_ROOT" --ticket "$_WF_TID" >/dev/null 2>&1 || true
  fi
}
trap _wf_trap EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

if [ -z "$_WF_ROOT" ] || [ ! -d "$_WF_ROOT/.git" ]; then
  echo "WARNING: WIKI_ROOT not configured or not a git repo — skipping wiki commit" >&2
  _wf_plog wiki-commit skip "WIKI_ROOT not configured or not a git repo"
else
  _acq_rc=0
  bash "$_wlock" acquire --wiki-root "$_WF_ROOT" --ticket "$_WF_TID" --log-file "${_WF_LOG:-${TAP_LOG:-}}" >/dev/null || _acq_rc=$?
  if [ "$_acq_rc" -ne 0 ]; then
    echo "WARNING: WIKI_ROOT lock not re-acquired by $_WF_TID (rc $_acq_rc) — skipping wiki commit" >&2
    _wf_plog wiki-commit skip "WIKI_ROOT lock not re-acquired (rc $_acq_rc) — commit skipped"
  else
    # adr-governance-gate: run before staging — adr-check.sh's immutability
    # check diffs the working-tree body against the last COMMITTED revision.
    _adr_check_rc=0
    _adr_check_out=$(bash "$_WF_DIR/adr-check.sh" --wiki-root "$_WF_ROOT" 2>&1) || _adr_check_rc=$?
    if [ "$_adr_check_rc" -ne 0 ] && grep -q 'ACCEPTED_ADR_MODIFIED' <<<"$_adr_check_out"; then
      echo "ERROR: adr-check.sh found a modification to an Accepted ADR — refusing to commit WIKI_ROOT." >&2
      echo "Accepted ADRs are immutable in meaning (docs/adr-schema.md). Revert the edit and draft a superseding ADR instead." >&2
      _wf_plog wiki-commit fail "ACCEPTED_ADR_MODIFIED — commit refused"
      bash "$_wlock" release --wiki-root "$_WF_ROOT" --ticket "$_WF_TID" >/dev/null
      _wf_released=1
      exit 1
    elif [ "$_adr_check_rc" -ne 0 ]; then
      _wf_plog adr-check warn "violations found — see command output"
    fi

    # Scoped commit, never `git add -A`: only paths new or changed since this
    # run acquired the lock. Refuses (rc 5) unless the ticket owns the lock.
    _wcommit_rc=0
    bash "$_wlock" commit --wiki-root "$_WF_ROOT" --ticket "$_WF_TID" --message "$_WF_MSG" || _wcommit_rc=$?
    case "$_wcommit_rc" in
    0) ;;
    6) echo "Nothing of this run's to commit in WIKI_ROOT — skipping commit." ;;
    5)
      echo "WARNING: WIKI_ROOT lock no longer held by $_WF_TID — commit refused" >&2
      _wf_plog wiki-commit fail "WIKI_ROOT lock not held — commit refused"
      ;;
    *) _wf_plog wiki-commit fail "git commit failed (rc $_wcommit_rc)" ;;
    esac
  fi
fi
if [ -n "$_WF_ROOT" ] && [ -d "$_WF_ROOT" ]; then
  _wf_release
fi

# Step 4.5 — whole-store integrity pass, non-blocking.
if [ -n "$_WF_ROOT" ] && [ -d "$_WF_ROOT" ]; then
  _wiki_verify_rc=0
  _wiki_verify_out=$(bash "$_WF_DIR/wiki-verify.sh" --wiki-root "$_WF_ROOT" 2>&1) || _wiki_verify_rc=$?
  _wiki_verify_count=$(grep -oE 'violations=[0-9]+' <<<"$_wiki_verify_out" | tail -1 | cut -d= -f2)
  if [ "$_wiki_verify_rc" -eq 2 ]; then
    _wf_plog wiki-verify fail "setup error — see command output"
  elif [ "$_wiki_verify_rc" -ne 0 ]; then
    _wf_plog wiki-verify warn "${_wiki_verify_count:-?} violations found — see command output"
  fi
  [ -z "$_wiki_verify_out" ] || printf '%s\n' "$_wiki_verify_out"
fi
exit 0
