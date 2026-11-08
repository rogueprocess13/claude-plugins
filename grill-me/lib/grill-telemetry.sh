#!/usr/bin/env bash
# grill-telemetry.sh — per-round and per-session time and token records for a
# grill-me run (GitHub #631). Deterministic bash + jq, no model.
#
# Storage: <work_dir>/telemetry/runs.jsonl, two kinds:
#   grill_round    one per scoring (grill_score calls `round` itself), so a
#                  round runs from the previous score — or the start of the
#                  turn — to this one, and includes the time the person took
#                  to answer the previous round's questions (human_wait_ms).
#   grill_session  one per invocation of the skill, written by the Stop hook
#                  when the turn ends: sealed, waiting for answers, at the cap,
#                  aborted or refused. A headless grill spans several
#                  invocations (`--emit-questions`, then one `--answers` per
#                  round); each gets its own record, numbered `invocation`.
#
# Tokens: the assessment runs in the skill's own context (SKILL.md Step 3, no
# subagent), so a round's tokens are the session transcript's assistant usage
# between the round's start and end, counted once per message id. No session
# id or no transcript → `tokens: null`, never an estimate. Telemetry is active
# only inside a Claude Code session (CLAUDE_CODE_SESSION_ID set): the Stop hook
# that closes the session record keys on it.
#
# Every entry point is fail-soft and prints nothing on stdout except the
# `report` read-out — grill_score's callers parse its stdout.
# Sourceable library — no set -euo pipefail.

GRILL_TELEMETRY_SCHEMA=1

_gt_state_root() {
  printf '%s\n' "${GRILL_TELEMETRY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/grill-me/telemetry}"
}
_gt_transcript_root() {
  printf '%s\n' "${GRILL_TRANSCRIPT_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"
}
# GRILL_TELEMETRY_NOW is a test seam.
_gt_now() { printf '%s\n' "${GRILL_TELEMETRY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }
_gt_valid_sid() { [[ "${1:-}" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; }

# _grill_transcript_usage <transcript.jsonl> [from_iso] [to_iso]
# Ported verbatim from ticket-planner's planner_transcript_usage (grill-me
# installs standalone); keep the two in step.
_grill_transcript_usage() {
  local file="$1" from="${2:-}" to="${3:-}"
  [ -f "$file" ] || {
    echo null
    return 0
  }
  jq -cR 'fromjson? | select(type == "object")' "$file" 2>/dev/null |
    jq -sc --arg from "$from" --arg to "$to" '
      def sec: (. // "") | sub("\\.[0-9]+"; "");
      [.[] | .timestamp | sec | select(. != "")] as $all
      | [.[] | select(.type == "assistant" and (.message.usage | type) == "object")
          | select(($from == "" or (.timestamp | sec) >= $from)
                   and ($to == "" or (.timestamp | sec) <= $to))]
      | if length == 0 then null else
          (group_by(.message.id // .uuid) | map(last)) as $m
          | {input: ($m | map(.message.usage.input_tokens // 0) | add),
             output: ($m | map(.message.usage.output_tokens // 0) | add),
             cache_read: ($m | map(.message.usage.cache_read_input_tokens // 0) | add),
             cache_create: ($m | map(.message.usage.cache_creation_input_tokens // 0) | add),
             messages: ($m | length),
             model: ([$m[] | .message.model // empty | select(. != "<synthetic>")] | last),
             first_ts: ($all | min), last_ts: ($all | max)}
        end' 2>/dev/null || echo null
}

# _gt_human_wait <transcript> <from> <to> — ms between each AskUserQuestion
# call in the window and its answer.
_gt_human_wait() {
  local file="$1" from="$2" to="$3"
  [ -f "$file" ] || {
    echo null
    return 0
  }
  jq -cR 'fromjson? | select(type == "object")' "$file" 2>/dev/null |
    jq -sc --arg from "$from" --arg to "$to" '
      def sec: (. // "") | sub("\\.[0-9]+"; "");
      def ms: (sec | fromdateiso8601) * 1000;
      ([.[] | select(.type == "assistant") | .timestamp as $t
         | (.message.content // []) | if type == "array" then .[] else empty end
         | select(.type == "tool_use" and .name == "AskUserQuestion") | {key: .id, value: $t}] | from_entries) as $asks
      | [.[] | select(.type == "user") | .timestamp as $t
         | (.message.content // []) | if type == "array" then .[] else empty end
         | select(.type == "tool_result" and ($asks[.tool_use_id] != null))
         | {ask: $asks[.tool_use_id], ans: $t}
         | select((.ask | sec) >= $from and (.ask | sec) <= $to)
         | ((.ans | ms) - (.ask | ms))]
      | add // 0' 2>/dev/null || echo null
}

_gt_main_transcript() {
  local sid="$1" f
  for f in "$(_gt_transcript_root)"/*/"${sid}.jsonl"; do
    [ -f "$f" ] && {
      printf '%s\n' "$f"
      return 0
    }
  done
  return 1
}

# _gt_turn_start <transcript> <now> — timestamp of the person's last prompt
# (a user message that is not only tool results) at or before <now>.
_gt_turn_start() {
  jq -cR 'fromjson? | select(type == "object" and .type == "user")' "$1" 2>/dev/null |
    jq -rs --arg now "$2" '
      [.[] | select((.message.content | type) == "string"
                    or ([.message.content[]? | select(.type != "tool_result")] | length) > 0)
         | .timestamp // empty | sub("\\.[0-9]+"; "") | select(. <= $now)] | max // empty' 2>/dev/null
}

_gt_append() {
  local runs="$1" line="$2"
  [ -n "$line" ] || return 0
  if command -v flock >/dev/null 2>&1; then
    {
      flock -w 5 9 || return 0
      printf '%s\n' "$line" >>"$runs"
    } 9>"${runs}.lock"
  else
    printf '%s\n' "$line" >>"$runs"
  fi
}

# grill_telemetry_begin <work_dir>
# Opens the session record for this invocation (idempotent per Claude session)
# and registers the session for the Stop hook. A record left open by another
# session is closed first (closed_by "next-begin").
grill_telemetry_begin() {
  local wd="$1" sid tdir open now start inv tr
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  _gt_valid_sid "$sid" || return 0
  [ -d "$wd" ] || return 0
  wd=$(cd "$wd" && pwd) || return 0
  tdir="$wd/telemetry"
  open="$tdir/open.json"
  if [ -f "$open" ]; then
    [ "$(jq -r '.session_id // empty' "$open" 2>/dev/null)" = "$sid" ] && return 0
    grill_telemetry_finish "$wd" next-begin
  fi
  mkdir -p "$tdir" 2>/dev/null || return 0
  now=$(_gt_now)
  start=""
  tr=$(_gt_main_transcript "$sid") && start=$(_gt_turn_start "$tr" "$now")
  [ -n "$start" ] || start="$now"
  inv=$(($(jq -cR 'fromjson? | select(.kind == "grill_session")' "$tdir/runs.jsonl" 2>/dev/null | wc -l) + 1))
  jq -nc --arg s "$sid" --arg t "$start" --argjson i "$inv" \
    '{session_id: $s, invocation: $i, started_at: $t, round_started_at: $t, sealed: null}' \
    >"$open.tmp" 2>/dev/null && mv "$open.tmp" "$open"
  local sdir
  sdir="$(_gt_state_root)/sessions"
  if (umask 077 && mkdir -p "$sdir") 2>/dev/null && [ ! -L "$sdir" ] && [ -O "$sdir" ]; then
    grep -Fxq -- "$wd" "$sdir/$sid" 2>/dev/null || printf '%s\n' "$wd" >>"$sdir/$sid"
    find "$sdir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
  fi
  return 0
}

# grill_telemetry_round <work_dir>
# Called by grill_score after it writes result.json. Records the round that
# ends now; the next round starts now.
grill_telemetry_round() {
  local wd="$1" sid open now line tr tokens wait
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  _gt_valid_sid "$sid" || return 0
  grill_telemetry_begin "$wd"
  wd=$(cd "$wd" 2>/dev/null && pwd) || return 0
  open="$wd/telemetry/open.json"
  [ -f "$open" ] || return 0
  now=$(_gt_now)
  local from
  from=$(jq -r '.round_started_at' "$open" 2>/dev/null)
  tokens=null
  wait=null
  if tr=$(_gt_main_transcript "$sid"); then
    tokens=$(_grill_transcript_usage "$tr" "$from" "$now")
    wait=$(_gt_human_wait "$tr" "$from" "$now")
  fi
  line=$(jq -nc --slurpfile o "$open" --arg wd "$wd" --arg now "$now" \
    --argjson tokens "${tokens:-null}" --argjson wait "${wait:-null}" --argjson schema "$GRILL_TELEMETRY_SCHEMA" \
    --slurpfile res <(cat "$wd/result.json" 2>/dev/null) --slurpfile asm <(cat "$wd/assessment.json" 2>/dev/null) '
    ($o[0]) as $s | ($res[0] // {}) as $r
    | {kind: "grill_round", schema: $schema, grill_id: ($wd | split("/") | last),
       session_id: $s.session_id, invocation: $s.invocation,
       round: (($asm[0] // {}).round // $r.round // null),
       started_at: $s.round_started_at, ended_at: $now,
       wall_ms: ((($now | fromdateiso8601) - ($s.round_started_at | fromdateiso8601)) * 1000),
       human_wait_ms: $wait,
       readiness: ($r.readiness // null), recommendation: ($r.recommendation // null),
       questions: (($r.questions // []) | length),
       tokens: (if $tokens == null then null else ($tokens | {input, output, cache_read, cache_create}) end),
       model: ($tokens.model // null)}' 2>/dev/null)
  _gt_append "$wd/telemetry/runs.jsonl" "$line"
  jq -c --arg now "$now" '.round_started_at = $now' "$open" >"$open.tmp" 2>/dev/null && mv "$open.tmp" "$open"
  return 0
}

# grill_telemetry_sealed <document_path>
# Called by grill_seal_generate: marks this session's open record as sealed.
grill_telemetry_sealed() {
  local doc="$1" sid marker wd
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  _gt_valid_sid "$sid" || return 0
  marker="$(_gt_state_root)/sessions/$sid"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  while IFS= read -r wd; do
    [ -f "$wd/telemetry/open.json" ] || continue
    jq -c --arg p "$doc" '.sealed = $p' "$wd/telemetry/open.json" >"$wd/telemetry/open.json.tmp" 2>/dev/null &&
      mv "$wd/telemetry/open.json.tmp" "$wd/telemetry/open.json"
  done <"$marker"
  return 0
}

# grill_telemetry_finish <work_dir> [closed_by]
# Writes the grill_session record for the open invocation and closes it.
grill_telemetry_finish() {
  local wd="$1" by="${2:-manual}" open now tr tokens wait sid line ended
  wd=$(cd "$wd" 2>/dev/null && pwd) || return 0
  open="$wd/telemetry/open.json"
  [ -f "$open" ] || return 0
  now=$(_gt_now)
  sid=$(jq -r '.session_id // empty' "$open" 2>/dev/null)
  local from
  from=$(jq -r '.started_at' "$open" 2>/dev/null)
  ended="$now"
  # Closed late by another session: it ended at its last round.
  [ "$by" = "next-begin" ] && ended=$(jq -r '.round_started_at' "$open" 2>/dev/null)
  tokens=null
  wait=null
  if _gt_valid_sid "$sid" && tr=$(_gt_main_transcript "$sid"); then
    tokens=$(_grill_transcript_usage "$tr" "$from" "$ended")
    wait=$(_gt_human_wait "$tr" "$from" "$ended")
  fi
  line=$(jq -nc --slurpfile o "$open" --arg wd "$wd" --arg ended "$ended" --arg by "$by" \
    --argjson tokens "${tokens:-null}" --argjson wait "${wait:-null}" --argjson schema "$GRILL_TELEMETRY_SCHEMA" \
    --slurpfile res <(cat "$wd/result.json" 2>/dev/null) --slurpfile asm <(cat "$wd/assessment.json" 2>/dev/null) \
    --slurpfile st <(cat "$wd/state.json" 2>/dev/null) \
    --slurpfile rounds <(jq -cR 'fromjson? | select(.kind == "grill_round")' "$wd/telemetry/runs.jsonl" 2>/dev/null) '
    ($o[0]) as $s | ($res[0] // {}) as $r | ($st[0] // {}) as $state
    | {kind: "grill_session", schema: $schema, grill_id: ($wd | split("/") | last),
       session_id: $s.session_id, invocation: $s.invocation,
       started_at: $s.started_at, ended_at: $ended,
       wall_ms: ((($ended | fromdateiso8601) - ($s.started_at | fromdateiso8601)) * 1000),
       status: (if $s.sealed != null then "sealed" else ($state.status // "unsealed") end),
       sealed_path: $s.sealed,
       verdict: ($r.recommendation // null), score: ($r.readiness // null),
       rounds: (($asm[0] // {}).round // null),
       rounds_this_invocation: ([$rounds[] | select(.invocation == $s.invocation and .session_id == $s.session_id)] | length),
       human_wait_ms: $wait,
       tokens: (if $tokens == null then null else ($tokens | {input, output, cache_read, cache_create}) end),
       model: ($tokens.model // null),
       closed_by: $by}' 2>/dev/null)
  _gt_append "$wd/telemetry/runs.jsonl" "$line"
  rm -f "$open"
  if _gt_valid_sid "$sid"; then
    local marker
    marker="$(_gt_state_root)/sessions/$sid"
    if [ -f "$marker" ] && [ ! -L "$marker" ]; then
      grep -Fxv -- "$wd" "$marker" >"${marker}.tmp" 2>/dev/null
      if [ -s "${marker}.tmp" ]; then mv "${marker}.tmp" "$marker"; else rm -f "${marker}.tmp" "$marker"; fi
    fi
  fi
  return 0
}

# grill_telemetry_report <work_dir> — markdown read-out (rounds + sessions).
grill_telemetry_report() {
  local runs="$1/telemetry/runs.jsonl"
  [ -s "$runs" ] || {
    echo "No grill telemetry in $1" >&2
    return 1
  }
  jq -rRs '
    def dur: (. // 0) / 1000 | floor
      | if . >= 3600 then "\(. / 3600 | floor)h \(. % 3600 / 60 | floor)m"
        elif . >= 60 then "\(. / 60 | floor)m \(. % 60)s" else "\(.)s" end;
    def tok: if . == null then "UNMEASURED" else "\(.input)/\(.output)/\(.cache_read)/\(.cache_create)" end;
    [split("\n")[] | fromjson? | select(type == "object")] as $all
    | "| Invocation | Round | Wall-clock | Human wait | Readiness | Recommendation | Tokens (in/out/cache r/w) |",
      "|---|---|---|---|---|---|---|",
      ($all[] | select(.kind == "grill_round")
        | "| \(.invocation) | \(.round) | \(.wall_ms | dur) | \(if .human_wait_ms == null then "-" else (.human_wait_ms | dur) end) | \(.readiness) | \(.recommendation) | \(.tokens | tok) |"),
      "",
      "| Invocation | Status | Verdict | Score | Rounds | Wall-clock | Tokens (in/out/cache r/w) |",
      "|---|---|---|---|---|---|---|",
      ($all[] | select(.kind == "grill_session")
        | "| \(.invocation) | \(.status) | \(.verdict) | \(.score) | \(.rounds) | \(.wall_ms | dur) | \(.tokens | tok) |")
  ' "$runs"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
  begin) grill_telemetry_begin "${2:?work_dir}" ;;
  round) grill_telemetry_round "${2:?work_dir}" ;;
  sealed) grill_telemetry_sealed "${2:?document}" ;;
  finish) grill_telemetry_finish "${2:?work_dir}" "${3:-manual}" ;;
  report)
    grill_telemetry_report "${2:?work_dir}"
    exit $?
    ;;
  usage) _grill_transcript_usage "${2:?transcript}" "${3:-}" "${4:-}" ;;
  *)
    echo "Usage: grill-telemetry.sh begin|round|finish <work_dir> [closed_by] | sealed <doc> | report <work_dir> | usage <transcript> [from] [to]" >&2
    exit 2
    ;;
  esac
  exit 0
fi
