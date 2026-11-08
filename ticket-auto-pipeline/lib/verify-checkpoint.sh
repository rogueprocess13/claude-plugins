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
#           starts `zombie-detected:` or `operator-stopped:` is discounted —
#           but only when detect-resume.sh recorded that exact line number in
#           the control file (below);
#         * an operator reset (verify-attempts-reset.sh) zeroes the count;
#           only attempts after the reset point count.
#       Prints an integer. Always returns 0.
#   verify_latest_verdict <LOG>     — `done`, `fail` or `none`: the status of
#       the last real `VERIFY|verify|done|`/`fail|` line, recorded synthetic
#       terminals skipped. Always returns 0.
#   verify_last_verdict_line <LOG>  — line number of that line, or nothing.
#   verify_ctl_record_synthetic <LOG> <LINE> — orchestrator-only: records that
#       <LINE> is a synthetic close this process wrote.
#
# Trust boundary. Phase agents append to the pipeline log directly, so no log
# line can authorise a reset or a discount: an agent could otherwise append a
# `META|verify-attempts-reset` or a fake `fail|zombie-detected:` close and
# escape the attempt cap. Both live in a control file beside the log,
# `<LOG>.verify-ctl` (`reset|<log line count>|<iso>|<reason>` and
# `synthetic|<line>`), written only by verify-attempts-reset.sh (which refuses
# agent context) and by detect-resume.sh. A `META|verify-attempts-reset` line
# in the log is an audit record only and is ignored here. At most
# VERIFY_RESET_MAX (default 2) resets are ever honoured, in file order.
# CLI: verify-checkpoint.sh <LOG> — prints the criterion (or an empty line).
#      verify-checkpoint.sh attempts <LOG> | latest <LOG>

# Message prefixes of the synthetic `VERIFY|verify|fail|` lines detect-resume.sh
# writes when it closes an abandoned bracket. Kept in one place: the zombie
# writer and both readers below use these exact strings.
VERIFY_SYNTHETIC_FAIL_RE='^(zombie-detected|operator-stopped):'

# _verify_ctl_file <LOG> — the control file path, or /dev/null when absent
# (so the two-file awk below always has a first input).
_verify_ctl_file() {
  if [ -f "$1.verify-ctl" ]; then
    printf '%s' "$1.verify-ctl"
  else
    printf '/dev/null'
  fi
}

_verify_reset_max() {
  local m="${VERIFY_RESET_MAX:-2}"
  case "$m" in '' | *[!0-9]*) m=2 ;; esac
  printf '%s' "$m"
}

# Shared awk preamble: reads the control file (first input) into
# reset_ln (the effective reset point, from at most rmax resets) and synth[].
# shellcheck disable=SC2016
_VERIFY_CTL_AWK='
  FILENAME == ctlf {
    if ($1 == "reset" && $2 ~ /^[0-9]+$/ && nres < rmax) { nres++; if ($2 + 0 > reset_ln) reset_ln = $2 + 0 }
    else if ($1 == "synthetic" && $2 ~ /^[0-9]+$/) synth[$2 + 0] = 1
    next
  }
  function is_synthetic(   msg) {
    msg = $5; sub(/^[ \t]+/, "", msg)
    return ($4 == "fail" && (FNR in synth) && msg ~ synthre)
  }
'

verify_attempt_count() {
  local log="$1" ctl
  [ -f "$log" ] || {
    echo 0
    return 0
  }
  ctl=$(_verify_ctl_file "$log")
  awk -F'|' -v ctlf="$ctl" -v synthre="$VERIFY_SYNTHETIC_FAIL_RE" -v rmax="$(_verify_reset_max)" "$_VERIFY_CTL_AWK"'
    ($2 == "VERIFY" && $3 == "verify" && $4 == "waiting") ||
    ($2 == "IMPLEMENT" && $3 == "implement" && ($4 == "waiting" || $4 == "done")) {
      counted = 0
    }
    $2 == "VERIFY" && $3 == "verify" && $4 == "fail" && !is_synthetic() {
      if (!counted) { n++; counted = 1 }
    }
    FNR == reset_ln { n = 0; counted = 0 }
    END { print n + 0 }
  ' "$ctl" "$log" 2>/dev/null || echo 0
  return 0
}

verify_last_verdict_line() {
  local log="$1" ctl
  [ -f "$log" ] || return 0
  ctl=$(_verify_ctl_file "$log")
  awk -F'|' -v ctlf="$ctl" -v synthre="$VERIFY_SYNTHETIC_FAIL_RE" -v rmax="$(_verify_reset_max)" "$_VERIFY_CTL_AWK"'
    $2 == "VERIFY" && $3 == "verify" && ($4 == "done" || $4 == "fail") && !is_synthetic() { ln = FNR }
    END { if (ln) print ln }
  ' "$ctl" "$log" 2>/dev/null || true
  return 0
}

verify_latest_verdict() {
  local log="$1" ln v=""
  ln=$(verify_last_verdict_line "$log")
  if [ -n "$ln" ]; then
    v=$(sed -n "${ln}p" "$log" 2>/dev/null | awk -F'|' '{print $4}') || v=""
  fi
  echo "${v:-none}"
  return 0
}

verify_ctl_record_synthetic() {
  local log="$1" line="$2"
  case "$line" in '' | *[!0-9]*) return 0 ;; esac
  [ -n "$log" ] || return 0
  printf 'synthetic|%s\n' "$line" >>"$log.verify-ctl" 2>/dev/null || true
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
