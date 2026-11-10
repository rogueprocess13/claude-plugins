#!/usr/bin/env bash
# appraise-exec-coherence.sh — ticket-appraise-exec Step 3.4, the
# complexity-coherence gate (skill-deterministic-extraction 5).
#
# Usage (from the tickets repo root, the skill's CWD):
#   appraise-exec-coherence.sh <TICKET-ID> <TICKET_DIR>
#
# Checks that the complexity declared in notes.md (get_complexity) matches the
# artifact on disk:
#   - several openspec change dirs match the ticket  → mismatch
#   - no **Score:** under ## Complexity              → mismatch
#   - simple and no simple-fix.md                    → mismatch
#   - complex and no openspec change dir / tasks.md  → mismatch
# A mismatch writes
#   META|gate-stop|fail|COMPLEXITY_ARTIFACT_MISMATCH — declared=<c> artifact=<a>
# through plog.sh, where <a> is simple-fix, openspec, ambiguous or none (the
# artifact actually found). On a complex match the change dir is committed to
# the tickets repo (openspec-tracking-check.sh commit, issue #363) and
# META|gate-warn|info|OPENSPEC_ARTIFACT_COMMIT — rc=<rc> dir=<dir> (warn on a
# failed commit) is
# written; a failed commit never halts.
#
# The coherence-check and artifact-persisted heartbeats (hb-wrap.sh gate) are
# written here too.
#
# Prints COMPLEXITY=, ARTIFACT=, CHANGE_DIR= and, for a complex match,
# COMMIT_RC= (after the commit subcommand's own OPENSPEC_COMMIT_STATUS line).
# Exit codes:
#   0  coherent (simple or complex; the commit result never changes this)
#   1  mismatch: the gate-stop line is written; the skill stops non-zero
#   2  usage
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_AEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

aec_main() {
  local tid="${1:-}" td="${2:-}"
  if [ -z "$tid" ] || [ -z "$td" ] || [ $# -ne 2 ]; then
    echo "usage: appraise-exec-coherence.sh <TICKET-ID> <TICKET_DIR>" >&2
    return 2
  fi

  local complexity simple_fix change_dir change_rc=0 tasks artifact reason=""
  complexity=$(bash -c 'source "$1/notes-parse.sh"; get_complexity "$2"' _ "$_AEC_DIR" "$td" 2>/dev/null) || complexity=""
  if [ -f "$td/simple-fix.md" ]; then simple_fix="$td/simple-fix.md"; else simple_fix=""; fi
  change_dir=$(bash "$_AEC_DIR/ticket-dir.sh" change-dir "$tid" . 2>/dev/null) || change_rc=$?
  [ "$change_rc" -eq 0 ] || change_dir=""
  tasks="${change_dir}tasks.md"

  if [ -n "$simple_fix" ]; then
    artifact="simple-fix"
  elif [ "$change_rc" -eq 2 ]; then
    artifact="ambiguous"
  elif [ -n "$change_dir" ]; then
    artifact="openspec"
  else
    artifact="none"
  fi

  if [ "$change_rc" -eq 2 ]; then
    reason="several openspec change dirs match $tid"
  elif [ -z "$complexity" ]; then
    reason="notes.md missing **Score:** under ## Complexity"
  elif [ "$complexity" = simple ] && [ -z "$simple_fix" ] && [ -n "$change_dir" ]; then
    reason="declared simple but found openspec artifact (not simple-fix.md)"
  elif [ "$complexity" = simple ] && [ -z "$simple_fix" ]; then
    reason="declared simple but no simple-fix.md found"
  elif [ "$complexity" = complex ] && { [ -z "$change_dir" ] || [ ! -f "$tasks" ]; }; then
    reason="declared complex but no openspec tasks.md found"
  fi

  echo "COMPLEXITY=$complexity"
  echo "ARTIFACT=$artifact"
  echo "CHANGE_DIR=$change_dir"

  local hb_art="$artifact"
  [ "$complexity" = complex ] && [ -z "$reason" ] && hb_art="openspec"
  [ "$complexity" = simple ] && [ -z "$reason" ] && hb_art="simple-fix"

  if [ -n "$reason" ]; then
    echo "COHERENCE=mismatch ($reason)"
    bash "$_AEC_DIR/plog.sh" META gate-stop fail "COMPLEXITY_ARTIFACT_MISMATCH — declared=$complexity artifact=$artifact" || true
    bash "$_AEC_DIR/hb-wrap.sh" gate "coherence-check" "fail" "complexity-artifact mismatch" \
      "{\"declared\":\"$complexity\",\"artifact\":\"$artifact\"}" 2>/dev/null || true
    return 1
  fi

  bash "$_AEC_DIR/hb-wrap.sh" gate "coherence-check" "ok" "complexity-artifact match" \
    "{\"declared\":\"$complexity\",\"artifact\":\"$hb_art\"}" 2>/dev/null || true
  [ "$complexity" = complex ] || return 0

  local commit_rc=0 commit_out status
  commit_out=$(bash "$_AEC_DIR/openspec-tracking-check.sh" commit "$change_dir" "$tid") || commit_rc=$?
  [ -z "$commit_out" ] || echo "$commit_out"
  echo "COMMIT_RC=$commit_rc"
  local level=warn
  [ "$commit_rc" -eq 0 ] && level=info
  bash "$_AEC_DIR/plog.sh" META gate-warn "$level" "OPENSPEC_ARTIFACT_COMMIT — rc=$commit_rc dir=$change_dir" || true
  case "$commit_out" in
  *OPENSPEC_COMMIT_STATUS=noop*) status=noop ;;
  *OPENSPEC_COMMIT_STATUS=committed*) status=committed ;;
  *) status=commit-failed ;;
  esac
  local hb_status=ok
  [ "$commit_rc" -eq 0 ] || hb_status=warn
  bash "$_AEC_DIR/hb-wrap.sh" gate "artifact-persisted" "$hb_status" "$status" \
    "{\"dir\":\"$change_dir\",\"rc\":\"$commit_rc\"}" 2>/dev/null || true
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  aec_main "$@"
  exit $?
fi
