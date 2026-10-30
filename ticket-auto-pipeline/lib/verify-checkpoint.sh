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
#   verify_attempt_count <LOG>      — failed VERIFY attempts (#573, #572), the
#       one count behind detect-resume.sh's VERIFY_ATTEMPTS and
#       verify-retry-decide.sh. Rules:
#         * attempts, not lines: several `VERIFY|verify|fail|` lines inside one
#           attempt (the agent's own terminal line plus the router's
#           spawn_agent_post line) count once. An attempt boundary is a
#           `VERIFY|verify|waiting|` bracket open or an
#           `IMPLEMENT|implement|waiting|`/`done|` line (the re-implement that
#           sits between two verify attempts);
#         * synthetic terminals are not verdicts: a fail line whose message
#           starts `zombie-detected:` or `operator-stopped:` (written by
#           detect-resume.sh for a bracket left open with no live worker)
#           never counts;
#         * `META|verify-attempts-reset|...` (operator escape hatch, see
#           pipeline-log-format.md) zeroes the count; only attempts after the
#           last reset count.
#       Prints an integer. Always returns 0.
#   verify_latest_verdict <LOG>     — `done`, `fail` or `none`: the status of
#       the last real `VERIFY|verify|done|`/`fail|` line, synthetic terminals
#       skipped. Always returns 0.
# CLI: verify-checkpoint.sh <LOG> — prints the criterion (or an empty line).
#      verify-checkpoint.sh attempts <LOG> | latest <LOG>

# Message prefixes of the synthetic `VERIFY|verify|fail|` lines detect-resume.sh
# writes when it closes an abandoned bracket. Kept in one place: the zombie
# writer and both readers below use these exact strings.
VERIFY_SYNTHETIC_FAIL_RE='^(zombie-detected|operator-stopped):'

verify_attempt_count() {
  local log="$1"
  [ -f "$log" ] || {
    echo 0
    return 0
  }
  awk -F'|' -v synth="$VERIFY_SYNTHETIC_FAIL_RE" '
    $2 == "META" && $3 == "verify-attempts-reset" { n = 0; counted = 0; next }
    ($2 == "VERIFY" && $3 == "verify" && $4 == "waiting") ||
    ($2 == "IMPLEMENT" && $3 == "implement" && ($4 == "waiting" || $4 == "done")) {
      counted = 0; next
    }
    $2 == "VERIFY" && $3 == "verify" && $4 == "fail" {
      msg = $5
      sub(/^[ \t]+/, "", msg)
      if (msg ~ synth) next
      if (!counted) { n++; counted = 1 }
    }
    END { print n + 0 }
  ' "$log" 2>/dev/null || echo 0
  return 0
}

verify_latest_verdict() {
  local log="$1" v=""
  if [ -f "$log" ]; then
    v=$(awk -F'|' -v synth="$VERIFY_SYNTHETIC_FAIL_RE" '
      $2 == "VERIFY" && $3 == "verify" && ($4 == "done" || $4 == "fail") {
        msg = $5
        sub(/^[ \t]+/, "", msg)
        if ($4 == "fail" && msg ~ synth) next
        last = $4
      }
      END { print last }
    ' "$log" 2>/dev/null) || v=""
  fi
  echo "${v:-none}"
  return 0
}

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
  case "${1:-}:$#" in
  attempts:2)
    verify_attempt_count "$2"
    ;;
  latest:2)
    verify_latest_verdict "$2"
    ;;
  *:1)
    printf '%s\n' "$(verify_checkpoint_criterion "$1")"
    ;;
  *)
    echo "Usage: verify-checkpoint.sh <LOG_FILE> | attempts <LOG_FILE> | latest <LOG_FILE>" >&2
    exit 2
    ;;
  esac
fi
