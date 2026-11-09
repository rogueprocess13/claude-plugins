#!/usr/bin/env bash
# planner-run-telemetry.sh — per-phase and per-run time and token records for
# a ticket-planner initiative (GitHub #631). Deterministic bash + jq, no model.
#
# Storage: <initiative>/telemetry/runs.jsonl, one JSON object per line, two
# kinds — `planner_phase` (one per phase attempt) and `planner_run` (one per
# planner invocation, written on completion and on every halt). It is NOT the
# workspace runs.jsonl ticket-auto writes: the kinds are distinct anyway, so a
# reader that filters on `.kind` ignores them (test-planner-run-telemetry.sh
# proves it for the ticket-auto readers).
#
# Time comes from state.log: an attempt runs from its first state.log line to
# its last (second resolution). Tokens come from Claude Code's own subagent
# transcripts (<projects>/<slug>/<session>/subagents/agent-*.jsonl), matched by
# the Agent description the skill passes ("Run planner phase: <P> for <INIT>",
# or "<kind>: <id>" for the spawn-list agents), summed per message id. A phase
# with no matching transcript gets `tokens: null` — never an estimate.
#
# Why not the ticket-auto token-tracker hooks: they resolve identity only from
# `ticket-auto-*-spawn-meta.txt` and refuse any LOG_FILE not ending in
# `-pipeline.log` (#619), and fleet detectors treat every `*-pipeline.log` as a
# live ticket pipeline. A planner spawn-meta would either weaken that guard or
# plant a fake pipeline. Named-subagent spawns (dor-semantic-agent,
# draft-revise-agent) also arrive without `agent_transcript_path`. Reading the
# transcript files after the fact needs neither.
#
# Lifecycle:
#   begin  <INIT>             SKILL.md step 7, once per invocation. Opens the run
#                             and registers this Claude session for the Stop hook.
#   finish <INIT> [closed_by] hooks/planner-telemetry-stop.sh at turn end (every
#                             halt and completion ends the turn). Syncs phase
#                             records, then writes the `planner_run` summary.
#   sync   <INIT>             Write phase records for every closed attempt.
#   attempts <INIT>           Debug: the attempt table (TSV).
#
# Every entry point is fail-soft: telemetry never changes a planner exit code.
# Sourceable library — no set -euo pipefail.

_PRT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f planner_initiative_dir >/dev/null 2>&1; then
  # shellcheck source=planner-state.sh
  source "${_PRT_DIR}/planner-state.sh"
fi

PLANNER_TELEMETRY_SCHEMA=1
# Phases whose own work is bash. Draft readiness and Refinement still spawn
# agents; their tokens are the sum of those agents when any ran.
PLANNER_TELEMETRY_BASH_PHASES="Crosscheck DraftReadiness Refinement"

# ── Paths ─────────────────────────────────────────────────────────────────────
_prt_transcript_root() {
  printf '%s\n' "${PLANNER_TRANSCRIPT_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"
}

_prt_state_root() {
  printf '%s\n' "${PLANNER_TELEMETRY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ticket-planner/telemetry}"
}

_prt_valid_sid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]{1,128}$ ]]
}

# PLANNER_TELEMETRY_NOW is a test seam (fixture logs carry fixed timestamps).
_prt_now() { printf '%s\n' "${PLANNER_TELEMETRY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }

# ── Transcript token accounting ───────────────────────────────────────────────
# planner_transcript_usage <transcript.jsonl> [from_iso] [to_iso]
# Prints one compact JSON object {input, output, cache_read, cache_create,
# messages, model, first_ts, last_ts} or `null` when the file holds no
# assistant usage in the window. Claude Code writes one line per content block
# of a streamed message, each repeating the message's usage, so usage is
# counted once per message id (the last line wins). Unparseable lines are
# skipped. Timestamps compare at second resolution. Ported verbatim to
# grill-me/lib/grill-telemetry.sh (`_grill_transcript_usage`); keep in step.
planner_transcript_usage() {
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

# _prt_subagent_index <INIT> <telemetry_dir>
# One JSON array of every subagent transcript of every registered session:
# {file, description, agent_type, first_ts, last_ts, usage}.
_prt_subagent_index() {
  local tdir="$2" root sid meta jsonl desc atype usage
  root=$(_prt_transcript_root)
  [ -f "$tdir/sessions" ] || {
    echo '[]'
    return 0
  }
  {
    while IFS= read -r sid; do
      _prt_valid_sid "$sid" || continue
      for meta in "$root"/*/"$sid"/subagents/agent-*.meta.json; do
        [ -f "$meta" ] || continue
        jsonl="${meta%.meta.json}.jsonl"
        [ -f "$jsonl" ] || continue
        desc=$(jq -r '.description // empty' "$meta" 2>/dev/null)
        atype=$(jq -r '.agentType // empty' "$meta" 2>/dev/null)
        usage=$(planner_transcript_usage "$jsonl")
        jq -nc --arg f "$jsonl" --arg d "$desc" --arg a "$atype" --argjson u "${usage:-null}" \
          '{file: $f, description: $d, agent_type: $a, usage: $u}'
      done
    done <"$tdir/sessions"
  } | jq -sc '.' 2>/dev/null || echo '[]'
}

# ── Attempt table from state.log ──────────────────────────────────────────────
# planner_telemetry_attempts <INIT>
# TSV: phase attempt started_at ended_at outcome halt_code revise_rounds closed
# An attempt is a contiguous run of state.log lines belonging to one phase
# (META steps are mapped onto the phase that writes them; draft readiness is
# the pseudo-phase DraftReadiness). A new attempt starts when another phase's
# line appears, or when a step starts again in the same phase (a retry after a
# fail or a halt, or a re-run after a crash). `closed` is 0 only for the last
# attempt when it has no terminal line yet.
planner_telemetry_attempts() {
  local init="$1" log
  log=$(planner_state_log "$init" 2>/dev/null) || return 0
  [ -f "$log" ] || return 0
  local -a seq
  planner_phase_sequence seq
  awk -F'|' -v seq="${seq[*]}" '
    BEGIN { n = split(seq, s, " "); for (i = 1; i <= n; i++) isphase[s[i]] = 1 }
    function target(ph, st, status) {
      if (ph in isphase) return ph
      if (ph != "META" || status == "accepted") return ""
      if (st == "crosscheck") return "Crosscheck"
      if (st == "draft-readiness" || st == "draft-revise") return "DraftReadiness"
      if (st == "refinement" || st ~ /^refinement-/) return "Refinement"
      if (st == "ticketgen") return "TicketGen"
      if (st == "adr-gate") return "Architecture"
      return ""
    }
    function flush(superseded) {
      if (cur == "") return
      if (adr) { outcome = "halt"; halt = "ADR_GATE" }
      closed = (outcome != "") ? 1 : 0
      if (!closed && superseded) { outcome = "incomplete"; closed = 1 }
      if (outcome == "") outcome = "open"
      att[cur]++
      printf "%s\t%d\t%s\t%s\t%s\t%s\t%d\t%d\n", cur, att[cur], bstart, bend, outcome, (halt == "" ? "-" : halt), rounds, closed
      cur = ""
    }
    function open_block(t, ts) {
      cur = t; bstart = ts; bend = ts; outcome = ""; halt = ""; rounds = 0; adr = 0
      delete started
    }
    {
      ts = $1; ph = $2; st = $3; status = $4; msg = $5
      t = target(ph, st, status)
      if (t == "") next
      absorbed = 0
      # Draft readiness re-runs Crosscheck after an applied revision; those
      # lines belong to the gate run, not to a new Crosscheck attempt.
      if (cur == "DraftReadiness" && outcome == "" && t == "Crosscheck") { t = "DraftReadiness"; absorbed = 1 }
      opening = (!absorbed && ((ph != "META" && status == "start") || (ph == "META" && st == "draft-readiness" && status == "start")))
      key = ph "|" st
      # A phase writes nothing after its own fail or halt line, so any later
      # line of that phase is the next attempt (Refinement writes no start).
      if (cur != "" && (t != cur || outcome == "fail" || outcome == "halt" || (opening && (key in started)))) flush(1)
      if (cur == "") open_block(t, ts)
      bend = ts
      if (opening) started[key] = 1
      if (absorbed) next
      if (ph != "META") {
        if (st == "testdata-synth") next
        if (status == "done" || status == "skip") { outcome = status; halt = "" }
        else if (status == "fail") {
          if (ph == "Crosscheck") { outcome = "halt"; halt = "CROSSCHECK_BLOCKED" }
          else { outcome = "fail"; halt = "" }
        }
        next
      }
      if (st == "refinement-gate" && status == "fail") { outcome = "halt"; halt = "REFINEMENT_HALT"; next }
      if (st == "adr-gate" && status == "fail") { adr = 1; next }
      if (st == "draft-readiness") {
        if (status == "done") {
          if (msg ~ /^blocked/) { outcome = "halt"; halt = "DRAFT_NOT_READY" } else { outcome = "done"; halt = "" }
        } else if (status == "skip") { outcome = "skip" }
        next
      }
      if (st == "draft-revise" && match(msg, /round=[0-9]+/)) {
        r = substr(msg, RSTART + 6, RLENGTH - 6) + 0
        if (r > rounds) rounds = r
      }
    }
    END { flush(0) }
  ' "$log"
}

# ── Phase records ─────────────────────────────────────────────────────────────
# _prt_phase_records <INIT> <telemetry_dir> <runs_json>
# Prints one `planner_phase` JSON line per closed attempt. <runs_json> is the
# list of known run windows [{run_id, started_at, ended_at}] used to attribute
# each attempt to the run it started in.
_prt_phase_records() {
  local init="$1" tdir="$2" runs_json="$3" dir attempts agents
  dir=$(planner_initiative_dir "$init") || return 0
  attempts=$(planner_telemetry_attempts "$init" |
    jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
      | {phase: .[0], attempt: (.[1] | tonumber), started_at: .[2], ended_at: .[3],
         outcome: .[4], halt_code: (if .[5] == "-" then null else .[5] end),
         revise_rounds: (.[6] | tonumber), closed: (.[7] == "1")})')
  [ -n "$attempts" ] || return 0
  agents=$(_prt_subagent_index "$init" "$tdir")
  # Ids the spawn-list agents may name: this initiative's tickets (Refinement)
  # and its draft slugs (draft readiness).
  local tids slugs
  tids=$(_prt_subdirs "$dir/tickets")
  slugs=$(_prt_subdirs "$dir/artifacts/draft-readiness")
  jq -nc --arg init "$init" --argjson schema "$PLANNER_TELEMETRY_SCHEMA" \
    --argjson atts "$attempts" --argjson agents "${agents:-[]}" --argjson runs "${runs_json:-[]}" \
    --argjson tids "${tids:-[]}" --argjson slugs "${slugs:-[]}" '
    def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
    def target($a):
      ($a.description | capture("^Run planner phase: (?<p>[A-Za-z]+) for (?<i>\\S+)$")) as $m
        | if $m.i == $init then $m.p else null end;
    def spawn_target($a):
      ($a.description | capture("^(?<k>scan|audit|revise): (?<id>\\S+)$")) as $m
        | if ($tids | index($m.id)) then "Refinement"
          elif ($slugs | index($m.id)) then "DraftReadiness" else null end;
    # Each transcript names its phase; it belongs to the latest attempt of that
    # phase that started before the transcript ended (5s grace: state.log
    # stamps whole seconds).
    [ $agents[] | select(.usage != null)
      | . + {phase: ((try target(.) catch null) // (try spawn_target(.) catch null))}
      | select(.phase != null) ] as $tagged
    | [ $tagged[] | . as $t
        | ([$atts[] | select(.phase == $t.phase and (.started_at | epoch) <= (($t.usage.last_ts | epoch) + 5))]
           | last) as $hit
        | select($hit != null)
        | {phase: $hit.phase, attempt: $hit.attempt, agent_type: $t.agent_type, usage: $t.usage} ] as $assigned
    | $atts[] | select(.closed) | . as $a
    | [$assigned[] | select(.phase == $a.phase and .attempt == $a.attempt)] as $mine
    | ([$runs[] | select((.started_at | epoch) <= ($a.started_at | epoch)
                          and ((.ended_at // "9999-12-31T00:00:00Z") | epoch) >= ($a.started_at | epoch))] | last) as $run
    | {kind: "planner_phase", schema: $schema, initiative: $init,
       run_id: ($run.run_id // null), phase: $a.phase, attempt: $a.attempt,
       started_at: $a.started_at, ended_at: $a.ended_at,
       wall_ms: ((($a.ended_at | epoch) - ($a.started_at | epoch)) * 1000),
       outcome: $a.outcome, halt_code: $a.halt_code,
       revise_rounds: (if $a.phase == "DraftReadiness" then $a.revise_rounds else null end),
       agents: ($mine | length),
       agent_types: ($mine | map(.agent_type) | unique),
       tokens: (if ($mine | length) == 0 then null else
         {input: ($mine | map(.usage.input) | add), output: ($mine | map(.usage.output) | add),
          cache_read: ($mine | map(.usage.cache_read) | add),
          cache_create: ($mine | map(.usage.cache_create) | add)} end),
       model: ([$mine[] | .usage.model // empty] | last)}' 2>/dev/null
}

# _prt_subdirs <dir> — JSON array of the names of <dir>'s subdirectories.
_prt_subdirs() {
  local d
  for d in "$1"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    printf '%s\n' "${d##*/}"
  done | jq -Rsc 'split("\n") | map(select(length > 0))'
}

_prt_runs_file() { printf '%s/runs.jsonl\n' "$1"; }

_prt_append() {
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

# _prt_run_windows <telemetry_dir> — closed runs plus the open one.
_prt_run_windows() {
  local tdir="$1" runs
  runs=$(_prt_runs_file "$tdir")
  {
    [ -f "$runs" ] && jq -cR 'fromjson? | select(.kind == "planner_run") | {run_id, started_at, ended_at}' "$runs" 2>/dev/null
    [ -f "$tdir/open-run.json" ] && jq -c '{run_id, started_at, ended_at: null}' "$tdir/open-run.json" 2>/dev/null
  } | jq -sc '.' 2>/dev/null || echo '[]'
}

# planner_telemetry_sync <INIT>
# Appends a `planner_phase` line for each closed attempt not yet recorded with
# the same (phase, started_at, ended_at, outcome, agents). An attempt that grew
# after an earlier sync gets a newer line; readers take the last line per
# (phase, started_at).
planner_telemetry_sync() {
  local init="$1" dir tdir runs windows line seen
  dir=$(planner_initiative_dir "$init" 2>/dev/null) || return 0
  [ -d "$dir" ] || return 0
  tdir="$dir/telemetry"
  mkdir -p "$tdir" 2>/dev/null || return 0
  runs=$(_prt_runs_file "$tdir")
  windows=$(_prt_run_windows "$tdir")
  seen=""
  [ -f "$runs" ] && seen=$(jq -rR 'fromjson? | select(.kind == "planner_phase")
    | [.phase, .started_at, .ended_at, .outcome, (.agents | tostring)] | join("|")' "$runs" 2>/dev/null)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local k
    k=$(printf '%s' "$line" | jq -r '[.phase, .started_at, .ended_at, .outcome, (.agents | tostring)] | join("|")')
    if grep -Fxq -- "$k" <<<"$seen"; then
      continue
    fi
    _prt_append "$runs" "$line"
    seen="${seen}"$'\n'"${k}"
  done < <(_prt_phase_records "$init" "$tdir" "$windows")
  return 0
}

# planner_telemetry_begin <INIT>
# Opens the run record for this invocation. Idempotent within one Claude
# session; a run left open by a session that never reached its Stop hook is
# closed first (closed_by "next-begin"). Prints PLANNER_RUN_ID=<id>.
planner_telemetry_begin() {
  local init="$1" dir tdir sid now run_id pos open_sid
  dir=$(planner_initiative_dir "$init" 2>/dev/null) || return 0
  [ -d "$dir" ] || return 0
  tdir="$dir/telemetry"
  mkdir -p "$tdir" 2>/dev/null || return 0
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  _prt_valid_sid "$sid" || sid=""
  if [ -f "$tdir/open-run.json" ]; then
    open_sid=$(jq -r '.session_id // empty' "$tdir/open-run.json" 2>/dev/null)
    if [ -n "$sid" ] && [ "$open_sid" = "$sid" ]; then
      echo "PLANNER_RUN_ID=$(jq -r '.run_id' "$tdir/open-run.json" 2>/dev/null)"
      return 0
    fi
    planner_telemetry_finish "$init" next-begin >/dev/null 2>&1 || true
  fi
  now=$(_prt_now)
  local stamp="${now//[-:]/}"
  run_id="planner-${init}-${stamp}-$$${RANDOM}"
  pos=$(planner_position_derive "$init" 2>/dev/null)
  jq -nc --arg r "$run_id" --arg i "$init" --arg s "$sid" --arg t "$now" --arg p "$pos" \
    '{run_id: $r, initiative: $i, session_id: (if $s == "" then null else $s end),
      started_at: $t, start_position: $p}' >"$tdir/open-run.json.tmp" 2>/dev/null &&
    mv "$tdir/open-run.json.tmp" "$tdir/open-run.json"
  if [ -n "$sid" ]; then
    grep -Fxq -- "$sid" "$tdir/sessions" 2>/dev/null || printf '%s\n' "$sid" >>"$tdir/sessions"
    local sdir
    sdir="$(_prt_state_root)/sessions"
    if (umask 077 && mkdir -p "$sdir") 2>/dev/null && [ ! -L "$sdir" ] && [ -O "$sdir" ]; then
      grep -Fxq -- "$dir" "$sdir/$sid" 2>/dev/null || printf '%s\n' "$dir" >>"$sdir/$sid"
      # Markers of sessions that never fired their Stop hook.
      find "$sdir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
    fi
  fi
  echo "PLANNER_RUN_ID=${run_id}"
}

# planner_telemetry_finish <INIT> [closed_by]
# Syncs phase records, then writes the run summary and closes the run. Runs on
# completion and on every halt: whatever stopped the loop, the turn ends and
# the Stop hook calls this. A no-op when no run is open.
planner_telemetry_finish() {
  local init="$1" closed_by="${2:-manual}" dir tdir open runs now log
  dir=$(planner_initiative_dir "$init" 2>/dev/null) || return 0
  tdir="$dir/telemetry"
  open="$tdir/open-run.json"
  [ -f "$open" ] || return 0
  planner_telemetry_sync "$init"
  runs=$(_prt_runs_file "$tdir")
  now=$(_prt_now)
  log=$(planner_state_log "$init" 2>/dev/null)
  local started sid ended reason position orch
  started=$(jq -r '.started_at' "$open" 2>/dev/null)
  sid=$(jq -r '.session_id // empty' "$open" 2>/dev/null)
  # A run closed by the next begin ended at its last state.log line, not now.
  ended="$now"
  if [ "$closed_by" = "next-begin" ] && [ -f "$log" ]; then
    ended=$(awk -F'|' -v s="$started" '$1 >= s { e = $1 } END { print e }' "$log")
    [ -n "$ended" ] || ended="$started"
  fi
  reason=$(bash "${_PRT_DIR}/planner-stop-describe.sh" "$init" --json 2>/dev/null | jq -r '.reason // empty' 2>/dev/null)
  position=$(planner_position_derive "$init" 2>/dev/null)
  orch=null
  if [ -n "$sid" ]; then
    local f
    for f in "$(_prt_transcript_root)"/*/"${sid}.jsonl"; do
      [ -f "$f" ] && orch=$(planner_transcript_usage "$f" "$started" "$ended") && break
    done
  fi
  local -a seq
  planner_phase_sequence seq
  local window
  window=$([ -f "$log" ] && awk -F'|' -v s="$started" -v e="$ended" '$1 >= s && $1 <= e' "$log")
  local line
  line=$(jq -nc --slurpfile o "$open" --arg ended "$ended" --arg by "$closed_by" \
    --arg reason "$reason" --arg pos "$position" --argjson orch "${orch:-null}" \
    --arg seq "${seq[*]}" --arg window "$window" --argjson schema "$PLANNER_TELEMETRY_SCHEMA" \
    --slurpfile phases <([ -f "$runs" ] && jq -cR 'fromjson? | select(.kind == "planner_phase")' "$runs" 2>/dev/null) '
    def epoch: fromdateiso8601;
    def addtok($a; $b): if $a == null then $b elif $b == null then $a else
      {input: ($a.input + $b.input), output: ($a.output + $b.output),
       cache_read: ($a.cache_read + $b.cache_read), cache_create: ($a.cache_create + $b.cache_create)} end;
    ($o[0]) as $run
    | ($seq | split(" ")) as $order
    | ($window | split("\n") | map(select(length > 0) | split("|"))) as $lines
    | ([$lines[] | select(.[1] != "META") | .[1]] | map(. as $p | $order | index($p)) | map(select(. != null)) | max) as $fi
    | [$phases[] | select(.run_id == $run.run_id)]
    | group_by([.phase, .started_at]) | map(last) | sort_by(.started_at) as $mine
    | ([$mine[] | .tokens] | reduce .[] as $t (null; addtok(.; $t))) as $ptok
    | {kind: "planner_run", schema: $schema, initiative: $run.initiative, run_id: $run.run_id,
       session_id: $run.session_id, started_at: $run.started_at, ended_at: $ended,
       wall_ms: ((($ended | epoch) - ($run.started_at | epoch)) * 1000),
       start_position: $run.start_position,
       furthest_phase: (if $fi == null then null else $order[$fi] end),
       next_phase: (if $pos == "" then null else $pos end),
       stop_reason: (if $reason == "" then null else $reason end),
       halt_code: (if $reason == "" or $reason == "COMPLETED" or $reason == "RUNNING" then null else $reason end),
       phase_attempts: ($mine | length),
       failed_attempts: ([$mine[] | select(.outcome == "fail" or .outcome == "incomplete")] | length),
       draft_revise_rounds: ([$lines[] | select(.[1] == "META" and .[2] == "draft-revise" and .[3] == "start")
                              | ((.[4] // "") | capture("round=(?<n>[0-9]+)").n | tonumber)] | max // 0),
       draft_revise_spawns: ([$lines[] | select(.[1] == "META" and .[2] == "draft-revise" and .[3] == "start")] | length),
       human_answer_rounds: ([$lines[] | select(.[1] == "META" and .[2] == "human-hold" and .[3] == "done")] | length),
       unmeasured_phases: [$mine[] | select(.tokens == null and .agents == 0) | .phase] ,
       tokens: {phases: $ptok, orchestrator: $orch,
                total: addtok($ptok; (if $orch == null then null else ($orch | {input, output, cache_read, cache_create}) end))},
       closed_by: $by}' 2>/dev/null)
  [ -n "$line" ] && _prt_append "$runs" "$line"
  rm -f "$open"
  if [ -n "$sid" ]; then
    local marker
    marker="$(_prt_state_root)/sessions/$sid"
    if [ -f "$marker" ] && [ ! -L "$marker" ]; then
      grep -Fxv -- "$dir" "$marker" >"${marker}.tmp" 2>/dev/null
      if [ -s "${marker}.tmp" ]; then mv "${marker}.tmp" "$marker"; else rm -f "${marker}.tmp" "$marker"; fi
    fi
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
  begin) planner_telemetry_begin "${2:?Usage: planner-run-telemetry.sh begin <INIT>}" ;;
  finish) planner_telemetry_finish "${2:?Usage: planner-run-telemetry.sh finish <INIT> [closed_by]}" "${3:-manual}" ;;
  sync) planner_telemetry_sync "${2:?Usage: planner-run-telemetry.sh sync <INIT>}" ;;
  attempts) planner_telemetry_attempts "${2:?Usage: planner-run-telemetry.sh attempts <INIT>}" ;;
  usage) planner_transcript_usage "${2:?Usage: planner-run-telemetry.sh usage <transcript> [from] [to]}" "${3:-}" "${4:-}" ;;
  *)
    echo "Usage: planner-run-telemetry.sh begin|finish|sync|attempts <INIT> | usage <transcript> [from] [to]" >&2
    exit 2
    ;;
  esac
  exit 0
fi
