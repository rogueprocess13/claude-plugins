#!/usr/bin/env bash
# planner-crosscheck-ac-coverage.sh — Uncovered response status code detector.
#
# Part of the Crosscheck check family (planner-ac-coverage-and-epic-uat, F16).
# Dispatch rehearsal iter 01 halted 6/6 tickets at Refinement on behaviour the
# ticket text states but no acceptance criterion checks — most of it added by
# Consensus, which edits prose without adding ACs. The deterministic DoR check
# passed every one of them, and Refinement runs after the Linear writes.
#
# This check catches the narrowest, surest kind of that gap before EpicGen: a
# response status code the behaviour section or Technical Context states
# ("Any other unexpected error returns 500 `{...}`") that no line under
# `## Acceptance Criteria` names. It does not judge condition coverage ("an
# expired token returns 401" when another AC already names 401) — that needs
# an LLM, and Refinement's semantic pass is that judge.
#
# Sections read: Proposed Behaviour, Proposed Changes, Desired Behaviour,
# Expected Behaviour and Technical Context, fenced blocks blanked.
#
# A status code is a standalone word of exactly three digits from 100 to 599
# once wrapping punctuation is stripped, so `Jake-Pass-123`, port 3000 and
# cost 10 never count. It counts only as a response:
#   - one of return/returns/respond/responds/→ precedes it in the same
#     sentence, with at most two filler words between (with, status, http,
#     a, an, the, code) — so "returns at most 100 articles" does not count;
#   - or the next word starts with a backtick (a backticked body).
# `on` is deliberately not a response verb: frontend specs say "on 401, clear
# the token" and their ACs are UI-worded, so widening it would flag every
# handled code in a frontend spec.
#
# Covered when any AC line holds the code as a standalone word. Known
# weakness: "does not return 500 for valid input" covers 500 too. This is a
# cheap early catch, not proof of coverage.
#
# Code: AC_STATUS_UNCOVERED (blocking), one finding per spec and code.
# Synth-marked TD specs are skipped.
#
# Usage:
#   planner_crosscheck_ac_coverage <initiative_id>
#     Returns: 0 if clean, 1 if any finding was reported.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_AC_COVERAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f _planner_crosscheck_contracts_defenced >/dev/null 2>&1; then
  # shellcheck source=planner-crosscheck-contracts.sh
  source "${_PLANNER_CROSSCHECK_AC_COVERAGE_LIB_DIR}/planner-crosscheck-contracts.sh"
fi

# Uncovered codes of one spec, one "<code>\t<excerpt>" line each, in order of
# first appearance. Pure over the file.
# Usage: _planner_crosscheck_ac_coverage_one <spec_file>
_planner_crosscheck_ac_coverage_one() {
  _planner_crosscheck_contracts_defenced "$1" | tr -d '\r' | awk '
    function strip(w) {
      sub(/^[(`"\047*]+/, "", w)
      sub(/[)`"\047*,.;:!?]+$/, "", w)
      return w
    }
    function is_code(w) {
      return w ~ /^[1-5][0-9][0-9]$/
    }
    function filler(w) {
      return w == "with" || w == "status" || w == "http" || w == "a" || w == "an" || w == "the" || w == "code"
    }
    function verb(w) {
      return w == "return" || w == "returns" || w == "respond" || w == "responds" || w == "→"
    }
    /^## / {
      h = $0
      sub(/^## +/, "", h)
      sub(/[ \t]+$/, "", h)
      sect = (h == "Proposed Behaviour" || h == "Proposed Changes" || h == "Desired Behaviour" || h == "Expected Behaviour" || h == "Technical Context") ? "beh" : (h == "Acceptance Criteria" ? "ac" : "")
      next
    }
    sect == "ac" {
      n = split($0, w, /[ \t]+/)
      for (i = 1; i <= n; i++) { c = strip(w[i]); if (is_code(c)) covered[c] = 1 }
      next
    }
    sect == "beh" {
      n = split($0, w, /[ \t]+/)
      start = 1
      for (i = 1; i <= n; i++) {
        c = strip(w[i])
        if (is_code(c)) {
          resp = (i < n && substr(w[i + 1], 1, 1) == "`")
          for (j = i - 1; !resp && j >= start && j >= i - 3; j--) {
            lw = tolower(strip(w[j]))
            if (verb(lw)) { resp = 1; break }
            if (!filler(lw)) break
          }
          if (resp && !(c in seen)) {
            seen[c] = 1
            order[++k] = c
            ex = ""
            for (e = start; e <= n; e++) {
              if (e == start && w[e] ~ /^([-*]|[0-9]+\.)$/) continue
              ex = ex (ex == "" ? "" : " ") w[e]
              if (e >= i && w[e] ~ /[.!?]$/) break
            }
            gsub(/[|\t]/, " ", ex)
            if (length(ex) > 160) ex = substr(ex, 1, 157) "..."
            excerpt[c] = ex
          }
        }
        if (w[i] ~ /[.!?]$/) start = i + 1
      }
    }
    END {
      for (i = 1; i <= k; i++) if (!(order[i] in covered)) printf "%s\t%s\n", order[i], excerpt[order[i]]
    }
  '
}

# Usage: planner_crosscheck_ac_coverage <initiative_id>
planner_crosscheck_ac_coverage() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-}"
  [ -n "$repos_root" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  local specs_dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts/specs"
  [ -d "$specs_dir" ] || return 0

  local spec_file base code excerpt found=0
  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    base="$(basename "$spec_file")"
    [ "$base" = "INDEX.md" ] && continue
    grep -qF -- "${PLANNER_TESTDATA_SYNTH_MARKER:-<!-- planner:testdata-synth v1 -->}" "$spec_file" 2>/dev/null && continue
    while IFS=$'\t' read -r code excerpt; do
      [ -n "$code" ] || continue
      echo "planner-crosscheck-ac-coverage: AC_STATUS_UNCOVERED ${base} status ${code} is stated as a response but no acceptance criterion checks it — \"${excerpt}\""
      found=1
    done < <(_planner_crosscheck_ac_coverage_one "$spec_file")
  done
  [ "$found" -eq 0 ]
}
