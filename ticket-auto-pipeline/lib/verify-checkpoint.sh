#!/usr/bin/env bash
# verify-checkpoint.sh — attempt-scoped VERIFY checkpoint reader (review
# finding DET-RV-16). One implementation, two callers: detect-resume.sh (its
# VERIFY_FROM / VERIFY_CHECKPOINT fields) and ticket-verify itself (which
# criteria it may skip on a resume). fleetd mirrors it in
# phase_dispatch.last_verify_checkpoint / last_verify_criterion, with a
# parity test against detect-resume.sh.
#
# The current attempt is everything after the last `VERIFY|verify|done|` or
# `VERIFY|verify|fail|` terminal line. An attempt that reached a terminal is
# over: the next attempt runs against re-implemented code and must re-check
# every criterion. A crashed attempt has no terminal, so its own progress is
# kept — but note detect-resume.sh turns a stale open bracket into a
# synthesized `verify|fail` (zombie), which ends that attempt too.
#
# Functions (sourceable; no set -e leak):
#   verify_attempt_lines <LOG>      — lines of the current attempt
#   verify_checkpoint_criterion <LOG> — highest N of
#       `VERIFY|checkpoint|done|criterion-N-pass` in the current attempt, or
#       nothing. Always returns 0.
# CLI: verify-checkpoint.sh <LOG> — prints the criterion (or an empty line).

verify_attempt_lines() {
  local log="$1" ln
  [ -f "$log" ] || return 0
  ln=$(grep -nE '^[^|]*\|VERIFY\|verify\|(done|fail)\|' "$log" 2>/dev/null | tail -1 | cut -d: -f1) || ln=""
  awk -v n="${ln:-0}" 'NR>n' "$log" 2>/dev/null || true
}

verify_checkpoint_criterion() {
  verify_attempt_lines "$1" |
    grep -oE '^[^|]*\|VERIFY\|checkpoint\|done\|criterion-[0-9]+-pass' |
    sed -E 's/.*criterion-([0-9]+)-pass$/\1/' | sort -n | tail -1 || true
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -ne 1 ]; then
    echo "Usage: verify-checkpoint.sh <LOG_FILE>" >&2
    exit 2
  fi
  printf '%s\n' "$(verify_checkpoint_criterion "$1")"
fi
