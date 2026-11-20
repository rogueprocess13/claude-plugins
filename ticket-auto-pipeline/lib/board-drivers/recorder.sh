#!/usr/bin/env bash
# recorder.sh — board driver that keeps one screenshot of the board per card
# move of a recording ticket (openspec change ticket-auto-record, design D6).
#
# Usage (the board driver CLI contract, see linear.sh):
#   recorder.sh apply <TID> <EVENT> <SEQ> <JSON_DATA>
# Operator commands, run from the tickets root:
#   recorder.sh login     headed browser; saves the Linear session
#   recorder.sh import    saves a Playwright storage state read from stdin
#   recorder.sh check     prints ok | browser-missing | no-session | expired |
#                         timeout | error
#
# `apply` exits 0 for every input: a recording problem is a manifest entry,
# never a failed drain. It writes only under <ticket dir>/artifacts/recordings/
# and never to the pipeline log (a drain runs after META|outcome, which must
# stay the last line). It projects nothing and changes no cursor.
#
# Configure it AFTER linear: FLEET_BOARD_DRIVERS=linear,recorder. One pass
# drains linear first, so by the time this driver sees an event the card has
# moved. Steps, in order:
#   1. workspace from $REPOS_ROOT (unset, missing, ambiguous -> nothing)
#   2. nothing unless record_enabled and the event maps to a column in
#      workflow.json's board_drivers.linear.events
#   3. board-{SEQ}-{EVENT}.png already there -> nothing (replay)
#   4. a later event in the outbox also moves the card -> skipped/superseded
#   5. the linear cursor is below SEQ -> skipped/board-not-applied
#   6. RECORD_BOARD_URL unset -> fail/no-board-url; not an https://linear.app
#      URL whose path holds /project/ or /view/ -> fail/bad-board-url
#   7. timeout -k 2 ${RECORD_SHOT_TIMEOUT:-25} node record/board-shot.mjs shoot
#      0 ok | 3 skipped/column-mismatch | 4 fail/session-expired |
#      5 fail/browser-missing | 6, 124, 137 fail/timeout | 7 fail/no-session |
#      other fail/shot-failed
#
# The linear cursor is read (board_cursor_get, no lock) for step 5 only.
#
# Manifest entries are built here (record.sh's own builder writes
# event/seq/column null) and appended through record_append_entry:
#   source "board", phase/attempt/step/env null, event, seq, column set.
#
# RECORDER_NODE_OVERRIDE / RECORDER_SHOT_OVERRIDE name another interpreter and
# script for the screenshot (tests only, never production config).
#
# Sets no shell options: nothing here may end the process non-zero.

_RD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RD_LIB_DIR="$(cd "$_RD_DIR/.." && pwd)"

source "$_RD_LIB_DIR/record.sh" 2>/dev/null || true
source "$_RD_LIB_DIR/ticket-dir.sh" 2>/dev/null || true
source "$_RD_LIB_DIR/board-cursor.sh" 2>/dev/null || true

_RD_EVENT_RE='^[a-z0-9-]+$'

# Same chain linear.sh uses, anchored at this file, never $PWD.
_recorder_workflow_json() {
  local cand found
  for cand in \
    "$_RD_LIB_DIR/../skills/ticket-flow/workflow.json" \
    "$HOME/.claude/skills/ticket-flow/workflow.json"; do
    if [ -f "$cand" ]; then
      echo "$cand"
      return 0
    fi
  done
  declare -f tap_cache_find >/dev/null 2>&1 ||
    source "$_RD_LIB_DIR/plugin-cache.sh" 2>/dev/null || true
  found=$(tap_cache_find ticket-auto-pipeline skills/ticket-flow/workflow.json 2>/dev/null || true)
  [ -n "$found" ] && [ -f "$found" ] && echo "$found"
  return 0
}

_recorder_log_dir() {
  if declare -f ticket_log_dir_or >/dev/null 2>&1; then
    ticket_log_dir_or "${FLEET_PIPELINE_LOG_DIR:-./logs}"
  else
    echo "${FLEET_PIPELINE_LOG_DIR:-./logs}"
  fi
}

# _recorder_column <workflow.json> <event> <data> — the column the event moves
# the card to (linear.sh's own from_data rule), or nothing.
_recorder_column() {
  local data="$3"
  printf '%s' "$data" | jq -e 'type == "object"' >/dev/null 2>&1 || data='{}'
  jq -r --arg e "$2" --argjson d "$data" '
    (.board_drivers.linear.events[$e].column? // null) as $c
    | if $c == null then empty
      elif ($c | type) == "object" then
        (if (($d[$c.from_data] // false) | tostring) == "true"
         then $c["true"] else $c["false"] end) // empty
      else $c end' "$1" 2>/dev/null || true
}

# _recorder_columns <workflow.json> — every column name, as a JSON array.
_recorder_columns() {
  jq -c '[.board_drivers.linear.events[]? | .column?
          | if type == "object" then (.["true"], .["false"]) else . end
          | strings] | unique' "$1" 2>/dev/null || echo '[]'
}

# _recorder_superseded <workflow.json> <outbox> <seq> — 0 when a later outbox
# event also maps to a column.
_recorder_superseded() {
  [ -f "$2" ] || return 1
  jq -Rn -e --argjson seq "$3" --slurpfile wf "$1" '
    ($wf[0].board_drivers.linear.events // {}) as $ev
    | any(inputs | fromjson? | objects
          | select((.seq | type) == "number" and .seq > $seq)
          | ($ev[.event // ""].column? // null);
          . != null)' "$2" >/dev/null 2>&1
}

# _recorder_entry <tid> <seq> <event> <column> <file> <status> <reason>
_recorder_entry() {
  jq -nc --arg ts "$(_record_now)" --arg tid "$1" --argjson seq "$2" \
    --arg event "$3" --arg column "$4" --arg file "$5" --arg status "$6" \
    --arg reason "$7" '
    def n: if . == "" then null else . end;
    {ts: $ts, tid: $tid, source: "board", phase: null, attempt: null,
     step: null, file: ($file | n), env: null, event: $event, seq: $seq,
     column: ($column | n), status: $status, reason: ($reason | n)}'
}

_recorder_note() {
  record_append_entry "$1" "$(_recorder_entry "${@:2}")" 2>/dev/null || true
}

_recorder_board_url_ok() {
  [[ "$1" =~ ^https://linear\.app/[^[:space:]]*/(project|view)/ ]]
}

_recorder_shot_timeout() {
  local t="${RECORD_SHOT_TIMEOUT:-25}"
  # Below the pusher's 60 s driver timeout, whatever the operator sets.
  if [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -ge 1 ] && [ "$t" -le 55 ]; then
    echo "$t"
  else
    echo 25
  fi
}

_recorder_apply() {
  local tid="${1:-}" event="${2:-}" seq="${3:-}" data="${4:-}"
  [[ "$tid" =~ $_REC_TID_RE ]] || return 0
  [[ "$event" =~ $_RD_EVENT_RE ]] || return 0
  [[ "$seq" =~ ^[0-9]+$ ]] || return 0
  seq=$((10#$seq))

  [ -n "${REPOS_ROOT:-}" ] && [ -d "$REPOS_ROOT" ] || return 0
  local tdir
  # CLAUDE_LOG_FILE= : "not found" must not reach any log (error_return).
  tdir=$(CLAUDE_LOG_FILE='' resolve_ticket_dir "$tid" "$REPOS_ROOT" 2>/dev/null) || tdir=""
  [ -n "$tdir" ] && [ -d "$tdir" ] || return 0

  local log_dir
  log_dir=$(_recorder_log_dir)
  record_enabled "$log_dir/${tid}-pipeline.log" || return 0

  local wf column
  wf=$(_recorder_workflow_json)
  [ -n "$wf" ] || return 0
  column=$(_recorder_column "$wf" "$event" "$data")
  [ -n "$column" ] || return 0

  local rec_dir="$tdir/artifacts/recordings"
  [ -L "$tdir/artifacts" ] || [ -L "$rec_dir" ] && return 0
  mkdir -p "$rec_dir" 2>/dev/null || return 0

  local name="board-${seq}-${event}.png"
  local out="$rec_dir/$name"
  # Replay: the frame is already there.
  [ -e "$out" ] || [ -L "$out" ] && return 0

  if _recorder_superseded "$wf" "$log_dir/${tid}-outbox.jsonl" "$seq"; then
    _recorder_note "$rec_dir" "$tid" "$seq" "$event" "$column" "" skipped superseded
    return 0
  fi

  local cur
  cur=$(board_cursor_get "$tid" linear 2>/dev/null) || cur=""
  if ! [[ "$cur" =~ ^[0-9]+$ ]] || [ "$cur" -lt "$seq" ]; then
    _recorder_note "$rec_dir" "$tid" "$seq" "$event" "$column" "" skipped board-not-applied
    return 0
  fi

  local url
  url=$(record_field RECORD_BOARD_URL 2>/dev/null) || url=""
  if [ -z "$url" ]; then
    _recorder_note "$rec_dir" "$tid" "$seq" "$event" "$column" "" fail no-board-url
    return 0
  fi
  if ! _recorder_board_url_ok "$url"; then
    _recorder_note "$rec_dir" "$tid" "$seq" "$event" "$column" "" fail bad-board-url
    return 0
  fi

  local node="${RECORDER_NODE_OVERRIDE:-node}"
  local shot="${RECORDER_SHOT_OVERRIDE:-$_RD_DIR/record/board-shot.mjs}"
  if ! command -v "$node" >/dev/null 2>&1 || [ ! -f "$shot" ]; then
    _recorder_note "$rec_dir" "$tid" "$seq" "$event" "$column" "" fail browser-missing
    return 0
  fi

  local rc=0 status reason
  timeout -k 2 "$(_recorder_shot_timeout)" "$node" "$shot" shoot \
    --repos-root "$REPOS_ROOT" --url "$url" --tid "$tid" --column "$column" \
    --columns "$(_recorder_columns "$wf")" --out "$out" \
    </dev/null >/dev/null 2>&1 || rc=$?
  case "$rc" in
  0)
    if [ -f "$out" ] && [ ! -L "$out" ] && [ -s "$out" ]; then
      _recorder_note "$rec_dir" "$tid" "$seq" "$event" "$column" "$name" ok ""
      return 0
    fi
    status=fail reason=shot-failed
    ;;
  3) status=skipped reason=column-mismatch ;;
  4) status=fail reason=session-expired ;;
  5) status=fail reason=browser-missing ;;
  6 | 124 | 137) status=fail reason=timeout ;;
  7) status=fail reason=no-session ;;
  *) status=fail reason=shot-failed ;;
  esac
  # No frame without an ok entry: drop whatever a failed run left behind.
  rm -f -- "$out" "$rec_dir/.${name}.tmp-"* 2>/dev/null
  _recorder_note "$rec_dir" "$tid" "$seq" "$event" "$column" "" "$status" "$reason"
  return 0
}

# login | import | check — for a person at the tickets root. REPOS_ROOT comes
# from the environment, else ./CLAUDE.md.
_recorder_operator() {
  local mode="$1" root url node shot
  root="${REPOS_ROOT:-}"
  if [ -z "$root" ] && [ -f ./CLAUDE.md ]; then
    root=$(claude_md_field ./CLAUDE.md REPOS_ROOT 2>/dev/null) || root=""
  fi
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "recorder.sh $mode: REPOS_ROOT is not set (environment or ./CLAUDE.md)" >&2
    return 2
  fi
  export REPOS_ROOT="$root"
  node="${RECORDER_NODE_OVERRIDE:-node}"
  shot="${RECORDER_SHOT_OVERRIDE:-$_RD_DIR/record/board-shot.mjs}"
  if ! command -v "$node" >/dev/null 2>&1; then
    [ "$mode" = check ] && echo browser-missing
    echo "recorder.sh $mode: node is not installed" >&2
    return 5
  fi
  local args=("--$mode" --repos-root "$root")
  url=$(record_field RECORD_BOARD_URL 2>/dev/null) || url=""
  if [ "$mode" != import ] && _recorder_board_url_ok "$url"; then
    args+=(--url "$url")
  fi
  "$node" "$shot" "${args[@]}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
  apply)
    shift
    _recorder_apply "$@" || true
    exit 0
    ;;
  login | import | check)
    _recorder_operator "$1"
    exit $?
    ;;
  *)
    echo "Usage: recorder.sh apply <TID> <EVENT> <SEQ> <JSON_DATA> | login | import | check" >&2
    # An unknown subcommand from a drain must not fail the drain either.
    exit 0
    ;;
  esac
fi
