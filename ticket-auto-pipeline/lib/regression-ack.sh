#!/usr/bin/env bash
# regression-ack.sh — the one way to acknowledge a ticket's Regression Risk
# (GitHub #771). An operator script: a person runs it in a terminal.
#
# Usage: regression-ack.sh <TICKET_ID> [--note "<why>"] [--notes <notes.md>]
#
# It prints every recorded version of the risk that no person has
# acknowledged yet (the section as notes.md has it now, and any earlier or
# removed version, from the text kept in the manifest), each with its risk
# id, then asks on the terminal for the id of the last one shown to be typed
# back. Only a matching answer records an acknowledgement, for every version
# shown.
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
# What the person sees is the text an agent wrote, so it is not trusted:
# a control character (ESC and the other C0 codes except tab, DEL, the C1
# range) or a Unicode direction or zero-width character could hide or
# rewrite the lines above the prompt. When the section as notes.md has it
# now holds one, the script prints nothing of it and refuses (exit 7) until
# the section is rewritten as plain text. An earlier recorded version that
# holds one cannot be rewritten, so it is printed with those bytes made
# visible (cat -v) under a warning. Everything else printed is filtered too.
#
# What this guarantees: an unattended agent run, and an agent that only
# unsets the variables, cannot acknowledge. What it does not: an agent that
# allocates its own pseudo-terminal (script, expect, python pty) and types
# the id can, and so can anything that writes the manifest file directly.
# And a person who tells an agent to do either has delegated the decision.
# The control raises the bar and makes a bypass a deliberate, visible act;
# it is not a sandbox.
#
# Exit: 0 acknowledged or nothing left to acknowledge, 2 usage, 3 notes.md
#       or manifest not found, 4 agent context or no terminal, 5 no risk on
#       record, 6 the typed id did not match (nothing recorded), 7 the risk
#       text holds control characters, 1 write failed.
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
note=$(printf '%s' "$note" | LC_ALL=C tr -d '\000-\010\013-\037\177' | tr '\n|' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

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
manifest=$(_rr_manifest_path "$tid") || {
  echo "regression-ack: no manifest for $tid" >&2
  exit 3
}

# The section as it stands is put on record first, so what is shown and
# acknowledged below is exactly what the gate will judge.
_rc=0
cur=$(regression_risk_fingerprint "$notes") || _rc=$?
if [ "$_rc" -eq 1 ]; then
  cur=""
elif [ "$_rc" -ne 0 ]; then
  echo "regression-ack: no sha256 tool (sha256sum or shasum)" >&2
  exit 1
else
  _rr_record "$tid" "$cur" "$notes" || {
    echo "regression-ack: could not record the risk in the manifest for $tid" >&2
    exit 1
  }
fi

if [ -z "$(regression_risk_recorded "$tid")" ]; then
  echo "regression-ack: $notes has no Regression Risk section and no risk is recorded for $tid — nothing to acknowledge" >&2
  exit 5
fi

mapfile -t outstanding < <(regression_risk_outstanding "$tid")

# _ra_unsafe — 0 when stdin holds a byte or character that must never reach
# the approver's terminal: C0 controls except tab and newline, DEL, C1
# controls (U+0080–U+009F), zero-width and direction marks (U+200B–U+200F,
# U+202A–U+202E, U+2066–U+2069), and any byte that is not valid UTF-8 text
# on its own (a lone 0x80–0x9F is a C1 control on an 8-bit terminal).
_ra_unsafe() {
  LC_ALL=C grep -qaP '[\x00-\x08\x0B-\x1F\x7F]|\xC2[\x80-\x9F]|\xE2\x80[\x8B-\x8F\xAA-\xAE]|\xE2\x81[\xA6-\xA9]|(?<![\xC2-\xF4\x80-\xBF])[\x80-\xBF]'
}
# _ra_clean — the same set removed. Used on everything printed, as a second
# layer: text that passed _ra_unsafe is unchanged by it.
_ra_clean() {
  LC_ALL=C tr -d '\000-\010\013-\037\177' |
    LC_ALL=C sed -e 's/\xC2[\x80-\x9F]//g' -e 's/\xE2\x80[\x8B-\x8F\xAA-\xAE]//g' -e 's/\xE2\x81[\xA6-\xA9]//g'
}
_ra_body() { jq -r --arg r "$1" '(.regression_risks // [])[] | select(.risk == $r) | .body // ""' "$manifest"; }

if [ "${#outstanding[@]}" -eq 0 ]; then
  already=true
else
  already=false
  # The section as it stands must be clean: refuse, the person has it fixed
  # in notes.md. An earlier recorded version cannot be fixed (the record is
  # append-only), so refusing would hold the ticket for ever: it is shown
  # with every such byte made visible (cat -v) under a warning instead.
  declare -A escaped=()
  for r in "${outstanding[@]}"; do
    if _ra_body "$r" | _ra_unsafe; then
      if [ "$r" = "$cur" ]; then
        echo "regression-ack: the Regression Risk section for $tid (risk ${r:0:12}) holds control or invisible characters. They can hide or rewrite what a terminal shows, so nothing is displayed and nothing is acknowledged. Inspect it with 'cat -v $notes', have the section rewritten as plain text, then run this again." >&2
        exit 7
      fi
      escaped[$r]=1
    fi
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
      if [ -n "${escaped[$r]:-}" ]; then
        echo "  !! WARNING: this version held control or invisible characters, which can"
        echo "  !! hide text on a terminal. It is shown escaped (^[ is ESC, M- marks a"
        echo "  !! non-ASCII byte). Read it with suspicion."
        _ra_body "$r" | LC_ALL=C cat -v | sed 's/^/  /'
      else
        _ra_body "$r" | _ra_clean | sed 's/^/  /'
      fi
    done
    echo
    if [ -z "$cur" ]; then
      echo "notes.md no longer has a Regression Risk section. Find out why before you acknowledge."
    elif [ "$last" != "$cur" ]; then
      echo "notes.md now shows a version that is already acknowledged. The text above is what is not."
    fi
    printf 'Type %s to acknowledge everything shown above (anything else aborts): ' "$id"
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
  by=$(printf '%s' "$by" | LC_ALL=C tr -d '\000-\010\013-\037\177' | tr '\n|;' '   ')
  for r in "${outstanding[@]}"; do
    set_ticket_regression_ack "$tid" "$r" human "$by" "$note" || {
      echo "regression-ack: manifest write failed for $tid" >&2
      exit 1
    }
  done
  if [ -n "$(regression_risk_outstanding "$tid")" ]; then
    echo "regression-ack: manifest still shows an unacknowledged risk after the write" >&2
    exit 1
  fi
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

ack=$(regression_risk_ack_json "$tid")
[ -n "$ack" ] || ack='{}'
echo "risk=$(jq -r '(.risk // "")[0:12]' <<<"$ack")"
echo "acknowledged=true"
echo "already_acknowledged=$already"
echo "acknowledged_versions=${#outstanding[@]}"
echo "provenance=$(jq -r '.provenance // ""' <<<"$ack")"
echo "by=$(jq -r '.by // ""' <<<"$ack")"
echo "at=$(jq -r '.at // ""' <<<"$ack")"
echo "Re-run /ticket-auto $tid (or /ticket-implement $tid) to continue."
