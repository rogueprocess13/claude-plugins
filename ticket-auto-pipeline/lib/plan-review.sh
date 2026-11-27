#!/usr/bin/env bash
# plan-review.sh — the router's independent plan review, STEP_2_2 (GitHub #667).
#
# Under the router a phase runs as a subagent and cannot spawn another agent,
# so ticket-appraise-exec Step 3.6's "adversarial reviewer" ran inline, in the
# context that wrote the plan. With TICKET_ROUTER_PLAN_REVIEW=complex (the
# default; `true` = every ticket, `false` = never) the router runs the review itself, after EXEC, as a fresh read-only agent
# (ticket-plan-review-agent) that sees the ticket workspace and the repos but
# not the producing phase's context. Everything around that spawn is here:
# no step of this file asks a model anything.
#
# The decision is per ticket, recorded once by ticket-preamble.sh:
#   META|plan-review|info|router        the router runs STEP_2_2 for a complex
#                                       ticket (flag `complex`); Step 3.6 skips
#   META|plan-review|info|router — every ticket
#                                       the same for every ticket (flag `true`)
#   META|plan-review|info|inline — …    the flag was on but this orchestrator
#                                       (fleetd phase dispatch) does not run
#                                       STEP_2_2; Step 3.6 runs inline as before
# No line: the flag was `false`. Every reader asks this file, never the env var.
#
# Verdict records are the ones Step 3.6 writes, so adversarial-rounds.sh,
# adversarial-override.sh, flow.sh's verdict gate and exit-path.sh need no
# change:
#   EXEC|adversarial-review|done|<PASS|WARNINGS|BLOCKED> — independent review round N: …
#   META|verifier-result|…  adversarial_review / EXEC
#   META|gate-stop|fail|ADVERSARIAL_BLOCKED — round N — …      (cap reached)
# The step's own bracket is EXEC|plan-review|waiting → done|fail, and a
# simple ticket gets EXEC|plan-review|skip|.
#
# Usage:
#   plan-review.sh mode [--log-file F]        router | inline   (F, else TAP_LOG/LOG_FILE)
#   plan-review.sh state <LOG>                off | review | revise | resolved | stopped
#   plan-review.sh scope <LOG>                complex | every   (which tickets are reviewed)
#   plan-review.sh prepare <TID> --log-file F [--ticket-dir D] [--repos-root R] [--out P]
#   plan-review.sh done <TID> --log-file F [--ticket-dir D] [--return-file P]
#   plan-review.sh revise <TID> --log-file F [--ticket-dir D] [--out P]
#
# state — read from the log alone (this is what makes the step resumable):
#   off       no router marker
#   review    no verdict yet, or the plan was produced again (an
#             EXEC|exec|done| line) after a BLOCKED verdict → run STEP_2_2
#   revise    latest verdict BLOCKED, under the cap, plan not yet revised
#             → re-run STEP_2 (EXEC) with the findings file as input
#   stopped   latest verdict BLOCKED and its ADVERSARIAL_BLOCKED gate-stop
#             written → a person decides (re-run, or adversarial-override.sh)
#   resolved  latest verdict PASS/WARNINGS, or the review was skipped
#
# prepare — before the spawn. Prints PLAN_REVIEW_READY=skip when there is
# nothing to review (state is not `review`; a simple ticket unless the marker
# is `router — every ticket`; no plan artifact:
# the entry gate reports that), else removes any earlier result file, writes
# the reviewer's instructions to --out (default
# ./logs/<TID>-plan-review-instructions.txt) and prints
#   PLAN_REVIEW_READY=spawn  PLAN_REVIEW_ROUND=<n>
#   PLAN_REVIEW_INSTRUCTIONS_FILE=<path>  PLAN_REVIEW_RESULT_FILE=<path>
#
# done — after the agent returned (its return already written to
# --return-file, default ./logs/<TID>-agent-return.txt). Reads
# <ticket dir>/plan-review.md, which only the reviewer writes:
#   `## Findings`, then `None.` or headings
#   `### F<n> — <blocker|major|minor|nit> — <title>`
#   any blocker → BLOCKED; other findings → WARNINGS; None. → PASS.
#   Missing or malformed → no verdict: META|gate-stop|fail|PLAN_REVIEW_NO_VERDICT
#   and a fail terminal; the next run reviews again. Never a pass.
# A valid result is copied to plan-review-r<N>.md and appended to notes.md
# under `## Adversarial Review` (verbatim, as Step 3.6 did), so non-blocking
# findings travel with the ticket. BLOCKED loops back once: the number of
# BLOCKED verdicts since the last pass or gate-stop is compared with STEP_2_2's
# `revise_loop.max_iterations` in dispatch-table.json (2: one review, one
# revise, one re-review), the same shape as the verify retry.
# Closes the bracket itself (spawn_capture ATTEMPT=plan-review-<N>,
# spawn_agent_post), as router-step.sh inspector-done does. Prints
#   PLAN_REVIEW_VERDICT=PASS|WARNINGS|BLOCKED|NONE
#   PLAN_REVIEW_DECISION=advance|retry|exhausted|invalid
#   PLAN_REVIEW_ROUND=<n>  PLAN_REVIEW_BLOCKERS=<n>  PLAN_REVIEW_FINDINGS=<n>
# The caller finalizes and exits 1 on exhausted/invalid, and loops on the rest.
#
# revise — the instructions for the EXEC re-run (FROM_STEP=create-artifact),
# written to --out (default ./logs/<TID>-plan-revise-instructions.txt); prints
# PLAN_REVISE_INSTRUCTIONS_FILE=<path> and logs META|plan-revise|info|round#N.
#
# Exit 0 on every decision; 2 usage.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.

_PRV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# plan_review_mode <LOG> — router | inline.
plan_review_mode() {
  local log="${1:-}" last=""
  if [ -n "$log" ] && [ -r "$log" ]; then
    last=$(awk -F'|' '$2 == "META" && $3 == "plan-review" && $4 == "info" { m = $5 } END { print m }' "$log" 2>/dev/null) || last=""
  fi
  case "$last" in
  router | "router "*) echo router ;;
  *) echo inline ;;
  esac
}

# plan_review_scope <LOG> — every | complex: which tickets the router reviews.
plan_review_scope() {
  local log="${1:-}" last=""
  if [ -n "$log" ] && [ -r "$log" ]; then
    last=$(awk -F'|' '$2 == "META" && $3 == "plan-review" && $4 == "info" { m = $5 } END { print m }' "$log" 2>/dev/null) || last=""
  fi
  case "$last" in
  "router — every ticket"*) echo every ;;
  *) echo complex ;;
  esac
}

# plan_review_state <LOG> — see the header.
plan_review_state() {
  local log="${1:-}"
  if [ "$(plan_review_mode "$log")" != router ]; then
    echo off
    return 0
  fi
  awk -F'|' '
    { sub(/\r$/, "") }
    $2 == "EXEC" && $3 == "adversarial-review" && $4 == "done" {
      v = $5; sub(/[^A-Z].*$/, "", v); redone = 0; stop = 0; next
    }
    $2 == "EXEC" && $3 == "plan-review" && $4 == "skip" { v = "SKIP"; next }
    $2 == "EXEC" && $3 == "exec" && $4 == "done" { redone = 1; next }
    $2 == "META" && $3 == "gate-stop" && $4 == "fail" && $5 ~ /^ADVERSARIAL_BLOCKED([^A-Za-z0-9_]|$)/ { stop = 1 }
    END {
      if (v == "") print "review"
      else if (v == "PASS" || v == "WARNINGS" || v == "SKIP") print "resolved"
      else if (redone) print "review"
      else if (stop) print "stopped"
      else print "revise"
    }
  ' "$log" 2>/dev/null || echo review
}

# plan_review_blocked_count <LOG> — BLOCKED verdicts since the last passing
# verdict or ADVERSARIAL_BLOCKED gate-stop (one person-visible stop ends a
# streak: a re-run after it gets a fresh budget).
plan_review_blocked_count() {
  local log="${1:-}"
  if [ -z "$log" ] || [ ! -r "$log" ]; then
    echo 0
    return 0
  fi
  awk -F'|' '
    { sub(/\r$/, "") }
    $2 == "EXEC" && $3 == "adversarial-review" && $4 == "done" && $5 ~ /^BLOCKED([^A-Za-z0-9_]|$)/ { n++; next }
    $2 == "EXEC" && $3 == "adversarial-review" && $4 == "done" { n = 0; next }
    $2 == "META" && $3 == "gate-stop" && $4 == "fail" && $5 ~ /^ADVERSARIAL_BLOCKED([^A-Za-z0-9_]|$)/ { n = 0 }
    END { print n + 0 }
  ' "$log" 2>/dev/null || echo 0
}

# plan_review_round <LOG> — the round about to run (or just run, when called
# before its verdict line is written): consecutive BLOCKED verdicts since the
# last pass, plus one. Gate-stops do not reset it, as adversarial-rounds.sh.
plan_review_round() {
  local log="${1:-}" n=0
  if [ -n "$log" ] && [ -r "$log" ]; then
    n=$(awk -F'|' '
      { sub(/\r$/, "") }
      $2 == "EXEC" && $3 == "adversarial-review" && $4 == "done" && $5 ~ /^BLOCKED([^A-Za-z0-9_]|$)/ { n++; next }
      $2 == "EXEC" && $3 == "adversarial-review" && $4 == "done" { n = 0 }
      END { print n + 0 }
    ' "$log" 2>/dev/null) || n=0
  fi
  echo $((n + 1))
}

# plan_review_cap — STEP_2_2's revise_loop.max_iterations, else 2.
plan_review_cap() {
  local table="${PLAN_REVIEW_TABLE:-}" cap=""
  [ -n "$table" ] || table="$_PRV_DIR/../skills/ticket-flow/dispatch-table.json"
  # Synced layout: ~/.claude/skills/lib beside ~/.claude/skills/ticket-flow.
  [ -f "$table" ] || table="$_PRV_DIR/../ticket-flow/dispatch-table.json"
  if [ ! -f "$table" ] && [ -f "$_PRV_DIR/plugin-cache.sh" ]; then
    # shellcheck source=plugin-cache.sh
    source "$_PRV_DIR/plugin-cache.sh" 2>/dev/null || true
    if declare -f tap_cache_find >/dev/null 2>&1; then
      table=$(tap_cache_find ticket-auto-pipeline skills/ticket-flow/dispatch-table.json 2>/dev/null) || table=""
    fi
  fi
  if [ -n "$table" ] && [ -f "$table" ]; then
    cap=$(jq -r '.steps[]? | select(.step_id == "STEP_2_2") | .revise_loop.max_iterations // empty' "$table" 2>/dev/null | head -1) || cap=""
  fi
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=2
  echo "$cap"
}

# plan_review_parse <RESULT-FILE> — sets PRV_VALID (true|false), PRV_REASON,
# PRV_BLOCKERS, PRV_FINDINGS. The grammar is the header's.
plan_review_parse() {
  local file="${1:-}" out=""
  PRV_VALID=false PRV_REASON="" PRV_BLOCKERS=0 PRV_FINDINGS=0
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    PRV_REASON="no result file"
    return 0
  fi
  out=$(awk '
    { sub(/\r$/, "") }
    /^## / { in_f = ($0 ~ /^## Findings[[:space:]]*$/); if (in_f) seen = 1; next }
    !in_f { next }
    /^### / {
      line = $0
      # em dash, en dash or hyphen between the three parts
      gsub(/[[:space:]]+(—|–|-)[[:space:]]+/, "\t", line)
      n = split(line, p, "\t")
      if (n < 3 || p[1] !~ /^### F[0-9]+$/ || p[2] !~ /^(blocker|major|minor|nit)$/) { bad++; next }
      total++
      if (p[2] == "blocker") blockers++
      next
    }
    /^None\.[[:space:]]*$/ { none = 1 }
    END { printf "%d %d %d %d %d\n", seen + 0, total + 0, blockers + 0, bad + 0, none + 0 }
  ' "$file" 2>/dev/null) || out=""
  local seen total blockers bad none
  read -r seen total blockers bad none <<<"$out"
  if [ "${seen:-0}" != 1 ]; then
    PRV_REASON="no Findings section"
  elif [ "${bad:-0}" != 0 ]; then
    PRV_REASON="malformed finding heading"
  elif [ "${total:-0}" = 0 ] && [ "${none:-0}" != 1 ]; then
    PRV_REASON="neither findings nor None."
  elif [ "${total:-0}" != 0 ] && [ "${none:-0}" = 1 ]; then
    PRV_REASON="findings and None. together"
  else
    PRV_VALID=true
    PRV_BLOCKERS="$blockers"
    PRV_FINDINGS="$total"
  fi
  return 0
}

_prv_usage() {
  sed -n '31,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

_prv_plog() {
  bash "$_PRV_DIR/plog.sh" --log-file "$_prv_log" "$@" || true
}

# _prv_ticket_dir — --ticket-dir, else the one `<TID>--slug` dir under the cwd.
_prv_ticket_dir() {
  if [ -n "$_prv_dir" ]; then
    printf '%s\n' "$_prv_dir"
    return 0
  fi
  (
    # shellcheck source=ticket-dir.sh
    source "$_PRV_DIR/ticket-dir.sh" 2>/dev/null || exit 0
    resolve_ticket_dir "$_prv_tid" "." 2>/dev/null || true
  )
}

# _prv_plan_paths <ticket dir> — the plan artifact, one absolute path per line
# (simple-fix.md, or the openspec change dir).
_prv_plan_paths() {
  local dir="$1" out="" PLAN_MODE="" PLAN_PATH="" CHANGE_DIR=""
  out=$(bash "$_PRV_DIR/ticket-dir.sh" plan "$_prv_tid" --ticket-dir "$dir" --log-file "$_prv_log" 2>/dev/null) || out=""
  eval "$out" 2>/dev/null || true
  if [ -n "$CHANGE_DIR" ] && [ -d "$CHANGE_DIR" ]; then
    realpath "$CHANGE_DIR" 2>/dev/null || printf '%s\n' "$CHANGE_DIR"
  elif [ -n "$PLAN_PATH" ] && [ -e "$PLAN_PATH" ]; then
    realpath "$PLAN_PATH" 2>/dev/null || printf '%s\n' "$PLAN_PATH"
  fi
}

_prv_prepare() {
  [ -n "$_prv_log" ] || _prv_usage
  if [ "$(plan_review_state "$_prv_log")" != review ]; then
    echo "PLAN_REVIEW_READY=skip"
    return 0
  fi
  local dir complexity="" plan=""
  dir=$(_prv_ticket_dir)
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    dir=$(realpath "$dir" 2>/dev/null || printf '%s' "$dir")
    complexity=$(
      # shellcheck source=notes-parse.sh
      source "$_PRV_DIR/notes-parse.sh" 2>/dev/null || exit 0
      get_complexity "$dir" 2>/dev/null || true
    )
    plan=$(_prv_plan_paths "$dir")
  fi
  if [ "$complexity" != complex ] && [ "$(plan_review_scope "$_prv_log")" != every ]; then
    _prv_plog EXEC plan-review skip "complexity=${complexity:-unknown} — plan review runs for complex tickets only"
    echo "PLAN_REVIEW_READY=skip"
    return 0
  fi
  if [ -z "$plan" ]; then
    _prv_plog EXEC plan-review skip "no plan artifact resolved — the entry gate reports it"
    echo "PLAN_REVIEW_READY=skip"
    return 0
  fi
  local round result out repos
  round=$(plan_review_round "$_prv_log")
  result="$dir/plan-review.md"
  rm -f "$result" 2>/dev/null || true
  out="${_prv_out:-./logs/${_prv_tid}-plan-review-instructions.txt}"
  repos="${_prv_repos_root:-${REPOS_ROOT:-}}"
  mkdir -p "$(dirname "$out")" 2>/dev/null || true
  {
    printf 'You have no Bash tool: skip the "Before starting, run" line above.\n'
    printf 'Ticket: %s. Review round: %s.\n' "$_prv_tid" "$round"
    printf 'Ticket workspace (read context.md and notes.md there): %s\n' "$dir"
    printf 'Plan artifact under review: %s\n' "$plan"
    if [ -n "$repos" ] && [ -d "$repos" ]; then
      printf 'Repositories root (every Grep and Glob call must pass a path inside it or inside the ticket workspace): %s\n' "$repos"
    fi
    printf 'Result file (the only file you write): %s\n' "$result"
  } >"$out.tmp.$$" 2>/dev/null && mv -f "$out.tmp.$$" "$out" 2>/dev/null || {
    rm -f "$out.tmp.$$" 2>/dev/null || true
    echo "plan-review: could not write instructions to $out" >&2
    echo "PLAN_REVIEW_READY=skip"
    return 0
  }
  echo "PLAN_REVIEW_READY=spawn"
  echo "PLAN_REVIEW_ROUND=$round"
  printf 'PLAN_REVIEW_INSTRUCTIONS_FILE=%q\n' "$out"
  printf 'PLAN_REVIEW_RESULT_FILE=%q\n' "$result"
}

# _prv_notes_append <notes.md> <result> <verdict> <round> — same-directory
# temp file and rename, so a crash never leaves half a section.
_prv_notes_append() {
  local notes="$1" result="$2" verdict="$3" round="$4" tmp
  [ -f "$notes" ] || return 0
  tmp="$notes.plan-review.$$"
  {
    cat "$notes"
    printf '\n## Adversarial Review\n\n**Verdict:** %s (independent plan review, round %s, router STEP_2_2)\n\n' "$verdict" "$round"
    awk '/^## Findings[[:space:]]*$/ { on = 1 } on' "$result"
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$notes" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# _prv_close <done|fail> <msg> — close the EXEC|plan-review bracket. PHASE and
# STEP come from the spawn-meta spawn_agent_pre wrote, so the pinger and
# watchdog it started are stopped too; they are named here only when that
# meta is not this step's (a `done` run with no spawn before it).
_prv_close() {
  local meta="" step=""
  meta=$(ticket_tmp_path "$_prv_tid" spawn-meta.txt 2>/dev/null) || meta=""
  if [ -n "$meta" ] && [ -f "$meta" ]; then
    step=$(_spawn_meta_get "$meta" STEP 2>/dev/null) || step=""
  fi
  if [ "$step" = plan-review ]; then
    spawn_agent_post TICKET_ID="$_prv_tid" RESULT="$1" MSG="$2" 2>/dev/null || true
  else
    spawn_agent_post TICKET_ID="$_prv_tid" RESULT="$1" MSG="$2" LOG_FILE="$_prv_log" \
      PHASE=EXEC STEP=plan-review 2>/dev/null || true
  fi
}

_prv_done() {
  [ -n "$_prv_log" ] || _prv_usage
  local dir result round cap verdict decision vr blocked
  dir=$(_prv_ticket_dir)
  [ -z "$dir" ] || dir=$(realpath "$dir" 2>/dev/null || printf '%s' "$dir")
  result="${dir:-.}/plan-review.md"
  round=$(plan_review_round "$_prv_log")
  cap=$(plan_review_cap)
  [ -n "$_prv_return" ] || _prv_return="./logs/${_prv_tid}-agent-return.txt"

  if ! declare -f spawn_agent_post >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_PRV_DIR/spawn-helper.sh"
  fi
  if [ -f "$_prv_return" ]; then
    spawn_capture TICKET_ID="$_prv_tid" PHASE=EXEC RESULT_FILE="$_prv_return" \
      ATTEMPT="plan-review-$round" 2>/dev/null ||
      echo "plan-review: spawn_capture failed (continuing)" >&2
  fi

  plan_review_parse "$result"
  if [ "$PRV_VALID" != true ]; then
    _prv_plog META gate-stop fail "PLAN_REVIEW_NO_VERDICT — round $round — ${PRV_REASON} ($result); re-run to review again"
    _prv_close fail "no verdict round#$round — ${PRV_REASON}"
    echo "PLAN_REVIEW_VERDICT=NONE"
    echo "PLAN_REVIEW_DECISION=invalid"
    echo "PLAN_REVIEW_ROUND=$round"
    echo "PLAN_REVIEW_BLOCKERS=0"
    echo "PLAN_REVIEW_FINDINGS=0"
    return 0
  fi

  if [ "$PRV_BLOCKERS" -gt 0 ]; then
    verdict=BLOCKED vr=BLOCK
  elif [ "$PRV_FINDINGS" -gt 0 ]; then
    verdict=WARNINGS vr=WARN
  else
    verdict=PASS vr=PASS
  fi

  cp -f "$result" "${result%.md}-r${round}.md" 2>/dev/null || true
  _prv_notes_append "$dir/notes.md" "$result" "$verdict" "$round"

  _prv_plog EXEC adversarial-review done "$verdict — independent review round $round: findings=$PRV_FINDINGS blockers=$PRV_BLOCKERS"
  local total="$PRV_FINDINGS"
  [ "$total" -gt 0 ] || total=1
  (
    export LOG_FILE="$_prv_log"
    # shellcheck source=verifier-result.sh
    source "$_PRV_DIR/verifier-result.sh" 2>/dev/null || exit 0
    write_verifier_result verifier=adversarial_review verdict="$vr" \
      criteria_met=$((total - PRV_BLOCKERS)) criteria_total="$total" \
      attempt="$round" phase=EXEC
  ) >/dev/null 2>&1 || true

  if [ "$verdict" != BLOCKED ]; then
    decision=advance
    _prv_close done "$verdict round#$round — findings=$PRV_FINDINGS"
  else
    blocked=$(plan_review_blocked_count "$_prv_log")
    if [ "$blocked" -ge "$cap" ]; then
      decision=exhausted
      _prv_plog META gate-stop fail "ADVERSARIAL_BLOCKED — round $round — $_prv_tid independent plan review found blocking issues ($blocked of $cap reviews blocked)"
      _prv_close fail "BLOCKED round#$round — blockers=$PRV_BLOCKERS, cap $cap reached"
    else
      decision=retry
      _prv_close done "BLOCKED round#$round — blockers=$PRV_BLOCKERS, revising the plan ($blocked of $cap)"
    fi
  fi

  echo "PLAN_REVIEW_VERDICT=$verdict"
  echo "PLAN_REVIEW_DECISION=$decision"
  echo "PLAN_REVIEW_ROUND=$round"
  echo "PLAN_REVIEW_BLOCKERS=$PRV_BLOCKERS"
  echo "PLAN_REVIEW_FINDINGS=$PRV_FINDINGS"
}

_prv_revise() {
  [ -n "$_prv_log" ] || _prv_usage
  local dir out round plan
  dir=$(_prv_ticket_dir)
  [ -z "$dir" ] || dir=$(realpath "$dir" 2>/dev/null || printf '%s' "$dir")
  # The round whose findings are being answered is the last one run.
  round=$(($(plan_review_round "$_prv_log") - 1))
  [ "$round" -ge 1 ] || round=1
  plan=$(_prv_plan_paths "$dir")
  out="${_prv_out:-./logs/${_prv_tid}-plan-revise-instructions.txt}"
  mkdir -p "$(dirname "$out")" 2>/dev/null || true
  {
    printf 'An independent plan review (round %s) BLOCKED this plan. ' "$round"
    printf 'Before anything else: read %s/plan-review.md and revise the plan artifact (%s) so every `blocker` finding is resolved; address the other findings where the fix is small. ' "$dir" "${plan:-see notes.md}"
    printf 'Append a `## Plan Review Response (round %s)` section to notes.md with one line per finding id saying what changed, or why nothing did. ' "$round"
    printf 'Do not edit plan-review.md or any `## Adversarial Review` section, and do not write an adversarial-review log line. '
    printf 'Then run Step 3.4 (appraise-exec-coherence.sh) again and continue the skill from Step 3.5. Follow the skill exactly for the rest.\n'
  } >"$out.tmp.$$" 2>/dev/null && mv -f "$out.tmp.$$" "$out" 2>/dev/null || {
    rm -f "$out.tmp.$$" 2>/dev/null || true
    echo "plan-review: could not write revise instructions to $out" >&2
    return 0
  }
  _prv_plog META plan-revise info "round#$round — re-running EXEC from create-artifact with plan-review.md as input"
  printf 'PLAN_REVISE_INSTRUCTIONS_FILE=%q\n' "$out"
  echo "PLAN_REVISE_ROUND=$round"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -eo pipefail
  _prv_cmd="${1:-}"
  [ -n "$_prv_cmd" ] || _prv_usage
  shift
  _prv_tid="" _prv_log="" _prv_dir="" _prv_repos_root="" _prv_out="" _prv_return=""
  case "$_prv_cmd" in
  mode)
    if [ "${1:-}" = "--log-file" ]; then
      _prv_log="${2:-}"
    fi
    plan_review_mode "${_prv_log:-${TAP_LOG:-${LOG_FILE:-}}}"
    exit 0
    ;;
  state)
    [ $# -eq 1 ] || _prv_usage
    plan_review_state "$1"
    exit 0
    ;;
  scope)
    [ $# -eq 1 ] || _prv_usage
    plan_review_scope "$1"
    exit 0
    ;;
  prepare | done | revise)
    [ $# -ge 1 ] || _prv_usage
    _prv_tid="$1"
    shift
    [[ "$_prv_tid" =~ ^[A-Za-z0-9_-]+$ ]] || _prv_usage
    ;;
  *) _prv_usage ;;
  esac
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || _prv_usage
    # An unfilled {PLACEHOLDER} reads as empty, as router-step.sh's do.
    case "$2" in "{"*"}") _v="" ;; *) _v="$2" ;; esac
    case "$1" in
    --log-file) _prv_log="$_v" ;;
    --ticket-dir) _prv_dir="$_v" ;;
    --repos-root) _prv_repos_root="$_v" ;;
    --out) _prv_out="$_v" ;;
    --return-file) _prv_return="$_v" ;;
    *) _prv_usage ;;
    esac
    shift 2
  done
  case "$_prv_cmd" in
  prepare) _prv_prepare ;;
  done) _prv_done ;;
  revise) _prv_revise ;;
  esac
  exit 0
fi
