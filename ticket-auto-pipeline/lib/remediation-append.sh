#!/usr/bin/env bash
# remediation-append.sh — persist a failed verify's REMEDIATION_BRIEF section
# to the ticket's plan artifact (ticket-verify Step 7c5,
# skill-deterministic-extraction 4).
#
# Usage:
#   remediation-append.sh <TICKET-ID> --section FILE [--root R]
#
# FILE holds the section body the agent wrote from the Step 7c5 template
# (everything between the `## Verification #N` heading and the closing
# marker). It is appended byte for byte:
#
#   <plan>
#   (blank line)
#   ## Verification #<N>
#   (blank line)
#   <FILE, verbatim; a newline is added only if FILE lacks a final one>
#   (blank line)
#   <!-- /REMEDIATION_BRIEF -->
#
# N = the plan's existing `^## Verification #` count + 1. The plan comes from
# `ticket-dir.sh plan <TICKET-ID> --root R` (R defaults to "."). The new plan
# is written to a sibling temp file and renamed over the old one, so a partial
# write is never visible.
#
# Prints PLAN=<path> and N=<n> on success.
# Exit codes:
#   0  appended
#   3  no single plan artifact (none, or several change dirs match): nothing
#      written; prints the "No plan artifact found" report line
#   1  write or rename failed: META|gate-stop|fail|REMEDIATION_BRIEF_TRUNCATED
#      written through plog.sh, the temp file removed, the plan untouched
#   2  usage, or the section file is missing or empty
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_RA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_ra_usage() {
  echo "usage: remediation-append.sh <TICKET-ID> --section FILE [--root R]" >&2
}

_ra_retro_hint() {
  # Agent-improvement hint for ticket-retro, to CLAUDE_LOG_FILE (a no-op when
  # that is unset). Never the pipeline log.
  if ! declare -f cl_write >/dev/null 2>&1 && [ -f "$_RA_DIR/heartbeat.sh" ]; then
    # shellcheck source=/dev/null
    source "$_RA_DIR/heartbeat.sh" 2>/dev/null || true
  fi
  if declare -f cl_write >/dev/null 2>&1; then
    cl_write RETRO hint info "$1" 2>/dev/null || true
  fi
}

remediation_append_main() {
  local tid="" section="" root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --section | --root)
      [ $# -ge 2 ] || {
        _ra_usage
        return 2
      }
      if [ "$1" = --section ]; then section="$2"; else root="$2"; fi
      shift 2
      ;;
    -*)
      _ra_usage
      return 2
      ;;
    *)
      [ -z "$tid" ] || {
        _ra_usage
        return 2
      }
      tid="$1"
      shift
      ;;
    esac
  done
  [ -n "$tid" ] && [ -n "$section" ] || {
    _ra_usage
    return 2
  }
  [ -s "$section" ] || {
    echo "remediation-append.sh: section file '$section' is missing or empty" >&2
    return 2
  }

  local plan="" plan_out
  plan_out=$(bash "$_RA_DIR/ticket-dir.sh" plan "$tid" --root "$root" 2>/dev/null) && plan=$(sed -n 's/^PLAN_PATH=//p' <<<"$plan_out")
  if [ -z "$plan" ] || [ ! -f "$plan" ]; then
    echo "No plan artifact found for REMEDIATION_BRIEF — brief emitted to chat and notes.md only."
    return 3
  fi

  local n tmp="${plan}.tmp"
  n=$(grep -c '^## Verification #' "$plan" 2>/dev/null || true)
  n=$((${n:-0} + 1))

  if ! {
    cat "$plan" &&
      printf '\n## Verification #%s\n\n' "$n" &&
      cat "$section" &&
      { [ -z "$(tail -c1 "$section")" ] || printf '\n'; } &&
      printf '\n<!-- /REMEDIATION_BRIEF -->\n'
  } >"$tmp" 2>/dev/null; then
    bash "$_RA_DIR/plog.sh" META gate-stop fail "REMEDIATION_BRIEF_TRUNCATED — write failed: $plan"
    _ra_retro_hint "REMEDIATION_BRIEF write failed — plan path: $plan, TMP: $tmp. Check filesystem permissions and free space"
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$plan" 2>/dev/null || {
    bash "$_RA_DIR/plog.sh" META gate-stop fail "REMEDIATION_BRIEF_TRUNCATED — rename failed: $plan"
    _ra_retro_hint "REMEDIATION_BRIEF atomic rename failed — plan path: $plan, TMP: $tmp. Check filesystem permissions and cross-device rename restrictions"
    rm -f "$tmp"
    return 1
  }
  echo "PLAN=$plan"
  echo "N=$n"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  remediation_append_main "$@"
  exit $?
fi
