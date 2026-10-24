#!/usr/bin/env bash
# planner-consensus-gate.sh — Consensus `Readiness: blocked` halts the run
# before Crosscheck (DET-PL-11).
#
# The Consensus prompt tells the agent: "If a blocker finding cannot be
# resolved, mark readiness as `blocked` ... Do not force through a broken
# plan." Nothing read that field, so a Consensus run that wrote `blocked` and
# then `Consensus|resolve|done` went straight on to Crosscheck and, with
# --create, into Linear. This file is the bash that reads it.
#
# Functions:
#   planner_consensus_readiness <INIT>   prints the normalized value
#                                        (ready-for-spec | needs-further-discovery |
#                                        blocked); rc 0 found, 1 field absent or
#                                        not one of the three, 2 no consensus.md
#   planner_consensus_gate <INIT>        rc 3 readiness is `blocked` (halt),
#                                        rc 0 anything else (proceed — see below).
#                                        Holds no state and writes nothing.
#   planner_consensus_halt_report <INIT> <STATE_DIR>
#                                        the halt prose (stdout), quoting the
#                                        Readiness section's own explanation
#
# Product decision: only an explicit `blocked` halts. `needs-further-discovery`
# and a missing/unparseable field proceed exactly as before this gate existed,
# so no initiative planned under an older prompt changes behaviour. The gate
# releases when a person edits consensus.md's Readiness (after fixing the
# plan) or re-runs Consensus; it is re-evaluated on every dispatch at
# Crosscheck, so it needs no state of its own.
#
# Parse rules: fenced lines (``` / ~~~) are ignored. The first of these wins:
#   - a label line: optional list marker / blockquote, then `Readiness`
#     (optionally bold), then `:`, a dash or other punctuation — the value is the rest of the line
#     (`**Readiness:** blocked`, `- **Readiness** — blocked — needs X`);
#   - a `#`..`####` heading `Readiness` — the value is the first non-blank line
#     before the next heading.
# The value is lowercased, stripped of `*`, `_` and backticks, and its leading
# words matched against the closed set, with spaces or hyphens between words.
#
# Written without regex intervals, so mawk runs it. Sourceable library; no
# set -euo pipefail at file scope (repo convention for this directory).

_PLANNER_CONSENSUS_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f planner_initiative_dir >/dev/null 2>&1 ||
  source "${_PLANNER_CONSENSUS_GATE_DIR}/planner-state.sh"

# _planner_consensus_readiness_raw <file> — the raw value text, or nothing.
_planner_consensus_readiness_raw() {
  LC_ALL=C awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    { sub(/\r$/, "") }
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    want_next {
      if ($0 ~ /^#/) { exit }
      if ($0 ~ /^[ \t]*$/) next
      print trim($0); exit
    }
    {
      line = $0
      low = tolower(line)
      if (low ~ /^#+[ \t]*\**readiness\**[ \t]*:?[ \t]*$/) { want_next = 1; next }
      # label form: [>|-|*|+ ] [**]Readiness[**] then : or a dash
      tmp = low
      sub(/^[ \t>]*/, "", tmp)
      sub(/^[-*+][ \t]+/, "", tmp)
      gsub(/\*/, "", tmp)
      if (tmp ~ /^readiness[ \t]*[^a-z0-9 \t]/) {
        sub(/^readiness[ \t]*/, "", tmp)
        sub(/^[^a-z0-9`]+/, "", tmp)
        print trim(tmp); exit
      }
    }
  ' "$1"
}

planner_consensus_readiness() {
  local init="$1" dir file raw norm
  dir=$(planner_initiative_dir "$init") || return 2
  file="${dir}/artifacts/consensus.md"
  [ -r "$file" ] || return 2
  raw=$(_planner_consensus_readiness_raw "$file")
  # Lowercase, drop markdown, and turn hyphens/punctuation into single spaces,
  # so "Ready-for-spec", "`blocked`." and "needs further discovery" all match.
  norm=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '*_`' |
    tr -s ' \t.,;:()-' ' ' | sed 's/^ //')
  case "$norm" in
  blocked | "blocked "*)
    echo "blocked"
    ;;
  "ready for spec" | "ready for spec "*)
    echo "ready-for-spec"
    ;;
  "needs further discovery" | "needs further discovery "*)
    echo "needs-further-discovery"
    ;;
  *)
    return 1
    ;;
  esac
}

planner_consensus_gate() {
  local value
  value=$(planner_consensus_readiness "$1") || return 0
  [ "$value" = "blocked" ] && return 3
  return 0
}

# planner_consensus_halt_report <INIT> <STATE_DIR>
planner_consensus_halt_report() {
  local init="$1" state_dir="$2" file explanation
  file="${state_dir}/artifacts/consensus.md"
  explanation=$(_planner_consensus_readiness_raw "$file" 2>/dev/null)
  echo "Consensus marked this plan Readiness: blocked — the run stops before Crosscheck."
  echo ""
  echo "Consensus could not resolve a blocking review finding. Its own explanation:"
  echo "  ${explanation:-(see consensus.md ## Readiness)}"
  echo ""
  echo "Fix the plan (proposal.md / specs), then change consensus.md's Readiness to"
  echo "ready-for-spec, or re-run Consensus. Nothing was created in Linear."
  echo ""
  echo "Artifacts:  ${state_dir}/artifacts/"
  echo "Consensus:  ${file}"
  echo "Resume:     /ticket-planner resume ${init}"
}
