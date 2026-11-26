#!/usr/bin/env bash
# regression-ack.sh — the one way to acknowledge a ticket's Regression Risk
# (GitHub #771). An operator script: a person runs it in a terminal.
#
# Usage: regression-ack.sh <TICKET_ID> [--note "<why>"] [--notes <notes.md>]
#
# It prints every recorded version of the risk that no person has
# acknowledged yet, each with its risk id, then asks on the terminal for the
# id of the last one shown to be typed back. Only a matching answer records
# an acknowledgement, for every version shown.
#
# An acknowledgement appends, in the ticket's local manifest:
#   regression_acks += {risk, provenance: "human", by, at[, note]}
# and writes one `gate-released` outbox event per risk ({provenance: "human",
# gate: "regression-risk", risk}). It never edits notes.md and writes no
# pipeline-log line (nothing follows a run's outcome line); the gate
# (lib/regression-risk.sh check) logs the acknowledgement, with who and when,
# on the next ticket-implement run. With nothing left to acknowledge it is a
# no-op and asks nothing. `by` is TICKET_ACK_BY, else `git config user.name`,
# else $USER.
#
# Who may run it. Two checks, both refused with exit 4:
#   1. CLAUDE_CODE_SESSION_ID, FLEET_WORKER_PID or FLEET_GENERATION is set
#      (an agent session or a fleetd worker).
#   2. There is no controlling terminal: /dev/tty cannot be opened for
#      reading and writing. The prompt is written to and the answer read
#      from /dev/tty, never stdin, so a pipe or a here-string cannot answer.
#      A Claude Code Bash call and a fleetd worker have no terminal.
# There is no flag and no variable that skips either check.
#
# What is shown is what is acknowledged. The text is an agent's, so three
# rules hold for every version before a byte of it reaches the terminal:
#   - Source. The version notes.md has now is read from notes.md, never from
#     the manifest copy. An earlier version is read from the manifest.
#   - Identity. The text about to be shown is hashed with the gate's own
#     function and must give exactly the risk id it is shown under. A
#     manifest entry whose text does not hash to its id is refused.
#   - Plain text. The text must be valid UTF-8 with no control or invisible
#     character (regression_risk_plain). The section as it stands is refused
#     outright when it is not; nothing of it is printed. An earlier version
#     recorded as not plain has no stored text: it is named, its text is
#     said to be withheld, and nothing an agent wrote is printed for it.
# Nothing is cleaned up and then shown. Any check that cannot run (a missing
# tool, a manifest that does not parse) is a refusal.
#
# What this guarantees: an unattended agent run, and an agent that only
# unsets the variables, cannot acknowledge. What it does not: an agent that
# allocates its own pseudo-terminal (script, expect, python pty) and types
# the id can, and so can anything that writes the manifest file directly.
# And a person who tells an agent to do either has delegated the decision.
# The control raises the bar and makes a bypass a deliberate, visible act;
# it is not a sandbox.
#
# REPOS_ROOT comes from the environment, else the ticket's env file, else
# ./CLAUDE.md. When ./CLAUDE.md declares one and the root came from
# elsewhere, the two must agree, and the ticket's manifest must already exist
# under it (lib/operator-root.sh); either miss is exit 3 with nothing
# recorded. The prompt names the manifest the acknowledgement goes into.
#
# Exit: 0 acknowledged or nothing left to acknowledge, 2 usage, 3 notes.md
#       or manifest not usable, or REPOS_ROOT unresolved or disagreeing, 4 agent context or no terminal, 5 no risk on
#       record, 6 the typed id did not match (nothing recorded), 7 the risk
#       text cannot be shown safely or does not match its id, 1 a tool or a
#       write failed. Only exit 0 with acknowledged=true means it is done.
set -eo pipefail

_RA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: regression-ack.sh <TICKET_ID> [--note \"<why>\"] [--notes <notes.md>]" >&2
  exit 2
}
die() {
  local code="$1"
  shift
  echo "regression-ack: $*" >&2
  exit "$code"
}

tid="" note="" notes=""
while [ $# -gt 0 ]; do
  case "$1" in
  --note | --notes)
    [ $# -ge 2 ] || usage
    case "$1" in
    --note) note="$2" ;;
    --notes) notes="$2" ;;
    esac
    shift 2
    ;;
  -*) usage ;;
  *)
    [ -z "$tid" ] || usage
    tid="$1"
    shift
    ;;
  esac
done
[[ "$tid" =~ ^[A-Z]+-[0-9]+$ ]] || usage

if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -n "${FLEET_WORKER_PID:-}" ] || [ -n "${FLEET_GENERATION:-}" ]; then
  die 4 "refusing to run in an agent or fleetd-worker context (CLAUDE_CODE_SESSION_ID/FLEET_WORKER_PID/FLEET_GENERATION set). A person acknowledges a regression risk; run it in a terminal."
fi
# The controlling terminal, opened once for the prompt and the answer.
if ! { exec 9<>/dev/tty; } 2>/dev/null || ! [ -t 9 ]; then
  die 4 "no terminal. A person acknowledges a regression risk by typing its id at the prompt; run this in an interactive terminal."
fi

# shellcheck source=/dev/null
source "$_RA_DIR/manifest-write.sh" || die 1 "manifest-write.sh could not be loaded"
# shellcheck source=/dev/null
source "$_RA_DIR/regression-risk.sh" || die 1 "regression-risk.sh could not be loaded"

# The operator's own words are stored and later logged: plain, one line.
note=$(printf '%s' "$note" | tr '\n\r|' '   ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') || die 1 "could not read --note"
[ -z "$note" ] || regression_risk_plain "$note" || die 2 "--note holds control or invisible characters"

# REPOS_ROOT: the environment, else the ticket's env file, else ./CLAUDE.md;
# one that disagrees with ./CLAUDE.md is refused, and the manifest must
# already exist under it (lib/operator-root.sh, GitHub #818). Without this an
# exported REPOS_ROOT from another project got a fresh _adhoc manifest
# created there, holding an acknowledgement this project never sees.
# shellcheck source=/dev/null
source "$_RA_DIR/operator-root.sh" || die 1 "operator-root.sh could not be loaded"
operator_resolve_repos_root "regression-ack" "$tid" || exit 3
manifest_path=$(operator_require_manifest "regression-ack" "$tid") || exit 3

# Sets RR_NOTES and RR_MANIFEST, or says why not (rc 2).
_rr_resolve "$tid" "$notes" || exit 3
notes="$RR_NOTES"

# The section as it stands: read once, here. This text is what is shown,
# hashed, recorded and acknowledged for the current version.
_rr_section "$notes" || exit 7
cur="$RR_SHA" cur_body="$RR_BODY"
if [ -n "$cur" ]; then
  regression_risk_plain "$cur_body" ||
    die 7 "the Regression Risk section for $tid (risk ${cur:0:12}) is not plain text: it holds control or invisible characters, or is not valid UTF-8. Such text can hide or rewrite what a terminal shows, so nothing is displayed and nothing is acknowledged. Inspect it with 'cat -v $notes', have the section rewritten as plain text, then run this again."
  _rr_record "$tid" "$cur" "$cur_body" || die 1 "could not record the risk in the manifest for $tid"
fi

recorded=$(regression_risk_recorded "$tid") || die 3 "the manifest for $tid could not be read"
[ -n "$recorded" ] || die 5 "$notes has no Regression Risk section and no risk is recorded for $tid — nothing to acknowledge"
outstanding_text=$(regression_risk_outstanding "$tid") || die 3 "the manifest for $tid could not be read"
outstanding=()
while IFS= read -r r; do
  [ -z "$r" ] || outstanding+=("$r")
done <<<"$outstanding_text"

if [ "${#outstanding[@]}" -eq 0 ]; then
  already=true
else
  already=false
  # Every version is checked before anything is printed: its id is a sha256,
  # and the text to be shown hashes to exactly that id and is plain.
  declare -A show=() withheld=()
  for r in "${outstanding[@]}"; do
    [[ "$r" =~ ^[0-9a-f]{64}$ ]] || die 7 "the manifest for $tid holds a recorded risk whose id is not a sha256 — it was not written by the pipeline. Nothing is acknowledged."
    if [ "$r" = "$cur" ]; then
      body="$cur_body"
    else
      entry=$(jq -c --arg r "$r" '[(.regression_risks // [])[] | select(.risk == $r)] | if length == 1 then .[0] else error("ambiguous") end' "$RR_MANIFEST") ||
        die 7 "the manifest for $tid has no single entry for risk ${r:0:12}. Nothing is acknowledged."
      if [ "$(jq -r '.plain | tostring' <<<"$entry")" != "true" ]; then
        withheld[$r]=1
        continue
      fi
      body=$(jq -r 'if (.body | type) == "string" then .body else error("no body") end' <<<"$entry") ||
        die 7 "risk ${r:0:12} for $tid has no recorded text. Nothing is acknowledged."
    fi
    sum=$(regression_risk_text_sha "$body") || die 1 "no sha256 tool (sha256sum or shasum)"
    [ "$sum" = "$r" ] ||
      die 7 "the text recorded for risk ${r:0:12} does not match its id: what would be shown is not what would be acknowledged. The manifest for $tid was changed outside the pipeline. Nothing is acknowledged."
    regression_risk_plain "$body" ||
      die 7 "the text recorded for risk ${r:0:12} is not plain text. Nothing is displayed and nothing is acknowledged."
    show[$r]="$body"
  done

  last="${outstanding[$((${#outstanding[@]} - 1))]}"
  id="${last:0:12}"
  {
    echo
    echo "Regression risk for $tid — ${#outstanding[@]} version(s) not acknowledged."
    for r in "${outstanding[@]}"; do
      echo
      if [ "$r" = "$cur" ]; then
        echo "--- risk ${r:0:12}: the section as notes.md has it now ---"
      else
        echo "--- risk ${r:0:12}: recorded earlier; notes.md no longer says this ---"
      fi
      if [ -n "${withheld[$r]:-}" ]; then
        echo "  !! This version held control or invisible characters when it was recorded."
        echo "  !! Its text was not kept and cannot be shown. You are acknowledging a"
        echo "  !! version you cannot read here. Ask what it said before you go on."
      else
        printf '%s\n' "${show[$r]}" | sed 's/^/  /'
      fi
    done
    echo
    if [ -z "$cur" ]; then
      echo "notes.md no longer has a Regression Risk section. Find out why before you acknowledge."
    elif [ "$last" != "$cur" ]; then
      echo "notes.md now shows a version that is already acknowledged. The text above is what is not."
    fi
    echo "Recording in: $manifest_path (REPOS_ROOT from the $OPERATOR_ROOT_SOURCE)"
    printf 'Type %s to acknowledge everything shown above (anything else aborts): ' "$id"
  } >&9
  answer=""
  IFS= read -r answer <&9 || answer=""
  answer=$(printf '%s' "$answer" | tr -d '[:space:]' | tr 'A-F' 'a-f') || answer=""
  [ "$answer" = "$id" ] || die 6 "not acknowledged — the id typed did not match. Nothing was recorded."

  by="${TICKET_ACK_BY:-}"
  [ -n "$by" ] || by=$(git config user.name 2>/dev/null || true)
  [ -n "$by" ] || by="${USER:-unknown}"
  by=$(printf '%s' "$by" | tr '\n\r|;' '    ') || by="unknown"
  regression_risk_plain "$by" || by="unknown"
  [ -n "$by" ] || by="unknown"

  # notes.md must still say what was shown: a section changed while the
  # person was reading is not what they acknowledged.
  _rr_section "$notes" || exit 7
  [ "$RR_SHA" = "$cur" ] || die 6 "notes.md changed while the risk was on screen. Nothing was recorded; run this again."

  for r in "${outstanding[@]}"; do
    set_ticket_regression_ack "$tid" "$r" human "$by" "$note" || die 1 "manifest write failed for $tid"
  done
  left=$(regression_risk_outstanding "$tid") || die 1 "the manifest for $tid could not be read back"
  [ -z "$left" ] || die 1 "the manifest still shows an unacknowledged risk after the write"
  # One gate-released record per acknowledged risk; fail-soft, the manifest
  # fact is the record the gate reads.
  for r in "${outstanding[@]}"; do
    (
      source "$_RA_DIR/events.sh" 2>/dev/null || exit 1
      emit_event --idem "${tid}:regression-ack:${r:0:12}" "$tid" gate-released \
        "$(jq -nc --arg r "$r" '{provenance: "human", gate: "regression-risk", risk: $r}')"
    ) >/dev/null 2>&1 || echo "regression-ack: outbox event not written (the manifest fact stands)" >&2
  done
fi

# The summary reads the manifest back. Its values are printed only when
# plain; the manifest is a file others can write.
ack=$(regression_risk_ack_json "$tid") || die 1 "the manifest for $tid could not be read back"
[ -n "$ack" ] || die 1 "no human acknowledgement is on record for $tid"
_field() {
  local v
  v=$(jq -r --arg f "$1" '.[$f] // "" | tostring' <<<"$ack" 2>/dev/null) || v=""
  if regression_risk_plain "$v" && [[ "$v" != *$'\n'* ]]; then printf '%s' "$v"; else printf '?'; fi
}
risk_out=$(_field risk)
echo "risk=${risk_out:0:12}"
echo "acknowledged=true"
echo "already_acknowledged=$already"
echo "acknowledged_versions=${#outstanding[@]}"
echo "provenance=$(_field provenance)"
echo "by=$(_field by)"
echo "at=$(_field at)"
echo "Re-run /ticket-auto $tid (or /ticket-implement $tid) to continue."
