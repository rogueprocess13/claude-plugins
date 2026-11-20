#!/usr/bin/env bash
# regression-ack.sh — the one way to acknowledge a ticket's Regression Risk
# (GitHub #771). An operator script: a person runs it in a terminal.
#
# Usage: regression-ack.sh <TICKET_ID> [--note "<why>"] [--notes <notes.md>]
#
# It prints the Regression Risk section and its risk id, then asks on the
# terminal for that id to be typed back. Only a matching answer records the
# acknowledgement. When notes.md no longer has the section but a risk was
# recorded for the ticket, it says so and asks for the recorded id.
#
# An acknowledgement writes, in the ticket's local manifest:
#   regression_ack = {risk, provenance: "human", by, at[, note]}
# and one `gate-released` outbox event ({provenance: "human",
# gate: "regression-risk", risk}). It never edits notes.md and writes no
# pipeline-log line (nothing follows a run's outcome line); the gate
# (lib/regression-risk.sh check) logs the acknowledgement, with who and when,
# on the next ticket-implement run. A repeat for the same risk is a no-op
# and asks nothing. `by` is TICKET_ACK_BY, else `git config user.name`, else
# $USER.
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
# What this guarantees: an unattended agent run, and an agent that only
# unsets the variables, cannot acknowledge. What it does not: an agent that
# allocates its own pseudo-terminal (script, expect, python pty) and types
# the id can, and so can anything that writes the manifest file directly.
# And a person who tells an agent to do either has delegated the decision.
# The control raises the bar and makes a bypass a deliberate, visible act;
# it is not a sandbox.
#
# Exit: 0 acknowledged or already acknowledged, 2 usage, 3 notes.md or
#       manifest not found, 4 agent context or no terminal, 5 nothing to
#       acknowledge, 6 the typed id did not match (nothing recorded),
#       1 write failed.
set -eo pipefail

_RA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: regression-ack.sh <TICKET_ID> [--note \"<why>\"] [--notes <notes.md>]" >&2
  exit 2
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
note=$(printf '%s' "$note" | tr '\n\r|' '   ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -n "${FLEET_WORKER_PID:-}" ] || [ -n "${FLEET_GENERATION:-}" ]; then
  echo "regression-ack: refusing to run in an agent or fleetd-worker context (CLAUDE_CODE_SESSION_ID/FLEET_WORKER_PID/FLEET_GENERATION set). A person acknowledges a regression risk; run it in a terminal." >&2
  exit 4
fi
# The controlling terminal, opened once for the prompt and the answer.
if ! { exec 9<>/dev/tty; } 2>/dev/null || ! [ -t 9 ]; then
  echo "regression-ack: no terminal. A person acknowledges a regression risk by typing its id at the prompt; run this in an interactive terminal." >&2
  exit 4
fi

# shellcheck source=/dev/null
source "$_RA_DIR/manifest-write.sh"
# shellcheck source=/dev/null
source "$_RA_DIR/regression-risk.sh"

if [ -z "$notes" ]; then
  declare -f resolve_ticket_dir >/dev/null 2>&1 || source "$_RA_DIR/ticket-dir.sh" 2>/dev/null || true
  _dir=$(resolve_ticket_dir "$tid" . 2>/dev/null) || _dir=""
  [ -z "$_dir" ] || notes="$_dir/notes.md"
fi
if [ -z "$notes" ] || [ ! -f "$notes" ]; then
  echo "regression-ack: notes.md for $tid not found — run from the tickets root, or pass --notes <path>" >&2
  exit 3
fi

ensure_ticket_manifest "$tid" || {
  echo "regression-ack: could not make $tid manifest-addressable (is REPOS_ROOT exported?)" >&2
  exit 3
}

_rc=0
removed=false
sha=$(regression_risk_fingerprint "$notes") || _rc=$?
if [ "$_rc" -eq 1 ]; then
  sha=$(regression_risk_recorded "$tid")
  if ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "regression-ack: $notes has no Regression Risk section and no risk is recorded for $tid — nothing to acknowledge" >&2
    exit 5
  fi
  removed=true
elif [ "$_rc" -ne 0 ]; then
  echo "regression-ack: no sha256 tool (sha256sum or shasum)" >&2
  exit 1
else
  # The risk exists from now on, whatever notes.md says later.
  [ "$(regression_risk_recorded "$tid")" = "$sha" ] || set_ticket_regression_risk "$tid" "$sha" || {
    echo "regression-ack: manifest write failed for $tid" >&2
    exit 1
  }
fi
id="${sha:0:12}"

ack=$(regression_risk_ack_json "$tid")
if [ -n "$ack" ] && [ "$(jq -r '.risk // ""' <<<"$ack")" = "$sha" ] &&
  [ "$(jq -r '.provenance // ""' <<<"$ack")" = "human" ]; then
  already=true
else
  already=false
  {
    echo
    if $removed; then
      echo "A regression risk was recorded for $tid, and $notes no longer has the section."
      echo "Find out why it was removed before you acknowledge."
    else
      echo "Regression Risk for $tid ($notes):"
      echo
      regression_risk_body "$notes" | sed 's/^/  /'
    fi
    echo
    echo "risk id: $id"
    printf 'Type the risk id to acknowledge this risk (anything else aborts): '
  } >&9
  answer=""
  IFS= read -r answer <&9 || answer=""
  answer=$(printf '%s' "$answer" | tr -d '[:space:]' | tr 'A-F' 'a-f')
  if [ "$answer" != "$id" ]; then
    echo "regression-ack: not acknowledged — the id typed did not match. Nothing was recorded." >&2
    exit 6
  fi

  by="${TICKET_ACK_BY:-}"
  [ -n "$by" ] || by=$(git config user.name 2>/dev/null || true)
  [ -n "$by" ] || by="${USER:-unknown}"
  by=$(printf '%s' "$by" | tr '\n\r|;' '    ')
  set_ticket_regression_ack "$tid" "$sha" human "$by" "$note" || {
    echo "regression-ack: manifest write failed for $tid" >&2
    exit 1
  }
  ack=$(regression_risk_ack_json "$tid")
  if [ "$(jq -r '.risk // ""' <<<"$ack")" != "$sha" ]; then
    echo "regression-ack: manifest does not show the acknowledgement after the write" >&2
    exit 1
  fi
  # One gate-released record per acknowledged risk; fail-soft, the manifest
  # fact is the record the gate reads.
  (
    source "$_RA_DIR/events.sh" 2>/dev/null || exit 1
    emit_event --idem "${tid}:regression-ack:${id}" "$tid" gate-released \
      "$(jq -nc --arg r "$sha" '{provenance: "human", gate: "regression-risk", risk: $r}')"
  ) >/dev/null 2>&1 || echo "regression-ack: outbox event not written (the manifest fact stands)" >&2
fi

echo "risk=$id"
echo "acknowledged=true"
echo "already_acknowledged=$already"
echo "provenance=$(jq -r '.provenance' <<<"$ack")"
echo "by=$(jq -r '.by' <<<"$ack")"
echo "at=$(jq -r '.at' <<<"$ack")"
echo "Re-run /ticket-auto $tid (or /ticket-implement $tid) to continue."
