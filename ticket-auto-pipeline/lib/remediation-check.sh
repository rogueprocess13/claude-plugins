#!/usr/bin/env bash
# remediation-check.sh — ticket-implement's rework detection (Step 2.5 and the
# resume load condition) and the REMEDIATION_BRIEF integrity check
# (references/rework.md), skill-deterministic-extraction 5.
#
# Usage:
#   remediation-check.sh status <TICKET-ID> --ticket-dir D [--root R]
#   remediation-check.sh integrity <TICKET-ID> --plan P
#
# status prints, eval-safe:
#   PLAN=<plan artifact, ticket-dir.sh plan; empty when none>
#   FAIL_COUNT=<`### … — Verification FAIL` entries in D/notes.md>
#   SECTION_COUNT=<`## Verification #` sections in PLAN>
#   REWORK=true|false        FAIL_COUNT > SECTION_COUNT (a rework entry)
#   REWORK_OPEN=true|false   notes.md's last `— verification re-run #` entry
#                            comes after its last `— committed` entry (the
#                            resume condition for a skipped Step 2.5)
# integrity checks that the last `## Verification #` section of P ends with
# `<!-- /REMEDIATION_BRIEF -->` (its last non-blank line before the next
# `## ` heading). When it does not — no section at all included — it writes
# META|gate-stop|fail|REMEDIATION_BRIEF_TRUNCATED — marker missing in: P
# through plog.sh and exits 1.
#
# Exit codes: 0 ok, 1 integrity failed, 2 usage.
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_RC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_rc_usage() {
  sed -n '8,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  return 2
}

_rc_status() {
  local tid="$1" td="" root="."
  shift
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || return 2
    case "$1" in
    --ticket-dir) td="$2" ;;
    --root) root="${2:-.}" ;;
    *) return 2 ;;
    esac
    shift 2
  done
  [ -n "$td" ] || return 2
  local plan="" out fails=0 sections=0 rework=false open
  if out=$(bash "$_RC_DIR/ticket-dir.sh" plan "$tid" --root "$root" --ticket-dir "$td" 2>/dev/null); then
    plan=$(eval "$out" && printf '%s' "$PLAN_PATH")
  fi
  fails=$(grep -c '^### .* — Verification FAIL' "$td/notes.md" 2>/dev/null) || fails=0
  if [ -n "$plan" ]; then
    sections=$(grep -c '^## Verification #' "$plan" 2>/dev/null) || sections=0
  fi
  [ "$fails" -gt "$sections" ] && rework=true
  open=$(awk '/^### .* — verification re-run #/{r=NR} /^### .* — committed/{c=NR} END{print (r>c)?"true":"false"}' "$td/notes.md" 2>/dev/null) || open=false
  printf 'PLAN=%q\n' "$plan"
  echo "FAIL_COUNT=$fails"
  echo "SECTION_COUNT=$sections"
  echo "REWORK=$rework"
  echo "REWORK_OPEN=${open:-false}"
}

_rc_integrity() {
  local plan=""
  [ "${2:-}" = --plan ] && [ $# -eq 3 ] || return 2
  plan="$3"
  local last tail=""
  last=$(grep -n '^## Verification #' "$plan" 2>/dev/null | tail -1 | cut -d: -f1)
  if [ -n "$last" ]; then
    tail=$(awk -v s="$last" 'NR>s && /^## / {exit} NR>s && NF' "$plan" | tail -1)
  fi
  if [ "$tail" = "<!-- /REMEDIATION_BRIEF -->" ]; then
    echo "REMEDIATION_BRIEF=intact"
    return 0
  fi
  echo "REMEDIATION_BRIEF=truncated"
  bash "$_RC_DIR/plog.sh" META gate-stop fail "REMEDIATION_BRIEF_TRUNCATED — marker missing in: $plan" || true
  return 1
}

remediation_check_main() {
  local cmd="${1:-}" tid="${2:-}" rc=0
  case "$cmd" in
  status | integrity) ;;
  *)
    _rc_usage
    return 2
    ;;
  esac
  [ -n "$tid" ] && [ "${tid#-}" = "$tid" ] || {
    _rc_usage
    return 2
  }
  shift
  if [ "$cmd" = status ]; then _rc_status "$@" || rc=$?; else _rc_integrity "$@" || rc=$?; fi
  [ "$rc" = 2 ] && _rc_usage
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  remediation_check_main "$@"
  exit $?
fi
