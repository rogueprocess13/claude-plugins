#!/usr/bin/env bash
# planner-crosscheck-goldfish.sh — the Crosscheck goldfish family
# (planner-goldfish-review, design D10).
#
# Consensus answers every goldfish blocker and major finding under its own
# heading in consensus.md:
#
#   ## Goldfish Findings Addressed
#   Goldfish review: ran — 3 finding(s), proposal <sha12>, see goldfish/review-goldfish.md
#   ### G1 — major — <title> — accepted
#   ### G2 — blocker — <title> — rejected (… covered in spec <slug>)
#   Minor/nit G3, G4: deferred
#
# This family checks that bookkeeping, and only warns:
#   GOLDFISH_UNADDRESSED (PLANNER_CROSSCHECK_WARN_CODES) — at most one per run,
#   naming each id in the latest `done` line's `bm=` list that has no
#   `### G<n> … — <disposition>` heading in that section, and `status line
#   missing` when the section has no line beginning `Goldfish review:`.
#
# A disposition is the first word of a ` — `-separated segment after the id:
# accepted, rejected, deferred or clarified. Minor and nit findings are never
# checked. Headings outside the section and fenced lines do not count.
#
# Silent when the state log has no terminal goldfish line (legacy initiatives,
# a flag-off run before PR B, every halt golden). After a NOT_RUN or disabled
# run only the status line is checked. The family never emits a blocking code:
# it judges an agent's bookkeeping, not the plan.
#
# Usage:
#   planner_crosscheck_goldfish <initiative_id>
#     stdout: `planner-crosscheck-goldfish: GOLDFISH_UNADDRESSED <message>`
#     or nothing. Always returns 0.
#
# Awk runs under LC_ALL=C with values through ENVIRON only;
# PLANNER_GOLDFISH_AWK overrides the binary (tests).
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_GOLDFISH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f planner_state_log >/dev/null 2>&1 ||
  source "${_PLANNER_CROSSCHECK_GOLDFISH_DIR}/planner-state.sh"

_PLANNER_XCG_PREFIX="planner-crosscheck-goldfish:"

# _planner_xcg_section <consensus.md> — prints `status` when the section has a
# `Goldfish review:` line, and `disp <id>` per dispositioned heading.
_planner_xcg_section() {
  # shellcheck disable=SC2016  # awk program, not shell
  LC_ALL=C "${PLANNER_GOLDFISH_AWK:-awk}" '
    BEGIN { sep = " \342\200\224 " }
    { sub(/\r$/, "") }
    /^(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^## / { s = $0; sub(/[ \t]+$/, "", s); insec = (s == "## Goldfish Findings Addressed"); next }
    !insec { next }
    /^Goldfish review:/ { print "status"; next }
    /^### G[0-9]/ {
      h = substr($0, 5)
      i = index(h, sep)
      if (i == 0) next
      id = substr(h, 1, i - 1)
      if (id !~ /^G[0-9]+$/) next
      rest = substr(h, i + length(sep))
      while (rest != "") {
        j = index(rest, sep)
        if (j == 0) { seg = rest; rest = "" } else { seg = substr(rest, 1, j - 1); rest = substr(rest, j + length(sep)) }
        sub(/^[ \t*_]+/, "", seg)
        w = seg; sub(/[^A-Za-z].*$/, "", w); w = tolower(w)
        if (w == "accepted" || w == "rejected" || w == "deferred" || w == "clarified") { print "disp " id; break }
      }
    }
  ' "$1" 2>/dev/null
}

planner_crosscheck_goldfish() {
  local init="$1" log last status msg bm consensus sec id missing="" parts=""
  log=$(planner_state_log "$init" 2>/dev/null) || return 0
  [ -f "$log" ] || return 0
  last=$(grep -E '^[^|]*\|META\|goldfish\|(done|fail|skip)\|' "$log" 2>/dev/null | tail -1)
  [ -n "$last" ] || return 0
  status=$(printf '%s' "$last" | cut -d'|' -f4)
  msg=$(printf '%s' "$last" | cut -d'|' -f5-)

  consensus="$(dirname "$log")/artifacts/consensus.md"
  sec=""
  [ -f "$consensus" ] && sec=$(_planner_xcg_section "$consensus")

  if [ "$status" = "done" ]; then
    bm=$(printf '%s\n' "$msg" | tr ' ' '\n' | sed -n 's/^bm=//p' | head -1)
    if [ -n "$bm" ] && [ "$bm" != "-" ]; then
      for id in $(printf '%s' "$bm" | tr ',' ' '); do
        case "$id" in G[0-9]*) ;; *) continue ;; esac
        grep -qxF "disp ${id}" <<<"$sec" && continue
        missing="${missing:+${missing}, }${id}"
      done
    fi
  fi
  [ -n "$missing" ] && parts="no disposition for ${missing}"
  if ! grep -qx "status" <<<"$sec"; then
    parts="${parts:+${parts}; }status line missing"
  fi
  [ -n "$parts" ] || return 0
  printf '%s GOLDFISH_UNADDRESSED consensus.md ## Goldfish Findings Addressed: %s\n' \
    "$_PLANNER_XCG_PREFIX" "$(printf '%s' "$parts" | tr -d '|\r\n')"
  return 0
}
