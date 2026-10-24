#!/usr/bin/env bash
# planner-stop-describe.sh — why a planner run stopped, and which answers
# resume it, as one machine-readable human-hold block (planner-headless-questions).
#
# Every planner halt is `exit 0` plus prose. A person reads the prose; a caller
# with no terminal (an orchestrator running `claude -p`, a Slack bridge) cannot
# tell why the run stopped or what it needs. This script derives the stop from
# the state log — the same facts the halts themselves read — and prints a
# human-hold Schema-Version 2 block (ticket-auto-pipeline/docs/human-hold-schema.md)
# whose question bindings map onto the existing resume flags. The answers come
# back through `resume <INIT_ID> --answers <file>` (lib/planner-answers.sh).
#
# It is a separate script on purpose: the halt sites in SKILL.md stay
# byte-identical (operators, docs and goldens see no change), and the
# describer is plain bash over files, unit-testable with fixture logs.
#
# Reasons, in the order they are checked:
#   RUNNING                 a phase holds the live phase lock
#   COMPLETED               planner_position_derive returns empty
#   ADR_GATE                Architecture parked on a blocking ADR verdict
#   SPECIFY_DECISION        position Review with an open NEEDS_HUMAN_DECISION
#                           in proposal.md ## Business Outcomes — one
#                           specify-answer:O<n> input question per decision,
#                           audience either (planner-specify-waiting-on-human)
#   CONSENSUS_BLOCKED       position Crosscheck with consensus.md Readiness:
#                           blocked (one `note` question; the release is an
#                           edit of consensus.md or a Consensus re-run)
#   CREATE_GATE             the next phase writes to Linear, unauthorized
#   PROJECT_GATE            Epic Gen stopped on a single matching project
#   CROSSCHECK_BLOCKED      the last Crosscheck run has unaccepted blocking codes
#                           (CITED_ARTIFACT_UNRESOLVED also asks one
#                           consensus-answer:cited:<n> question per artifact;
#                           TEST_DATA_IMPLIED one consensus-answer:testdata:<slug>
#                           question per spec)
#   REFINEMENT_HALT         Refinement halted with waivable not-ready codes,
#                           or on BODY_DRIFT/BODY_UNVERIFIED (one
#                           flag:refresh-bodies question, never a waive)
#   UNTIL_STOP              the run stopped after its --until phase
#   FAILED_RETRY_EXHAUSTED  the current phase spent its retry budget
#   RUNNING                 none of the above — a plain resume makes progress
#
# Output: one v2 block, or one terminal line REASON=COMPLETED, REASON=RUNNING
# or REASON=FAILED_RETRY_EXHAUSTED. `--json` prints the underlying model
# instead (the form planner-answers.sh validates against).
#
# No agent, no network. Refinement questions read the local ticket manifests
# (ticket-auto-pipeline's manifest-read.sh, resolved like planner-refinement.sh
# resolves it) because that is where readiness verdicts live; the state log
# only records that the gate failed.
#
# Sourceable library (planner_stop_describe, planner_stop_describe_json,
# planner_stop_round) and standalone CLI. No set -euo pipefail at file scope
# (repo convention for this directory).

_PLANNER_STOP_DESCRIBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f planner_state_log >/dev/null 2>&1 ||
  source "${_PLANNER_STOP_DESCRIBE_DIR}/planner-state.sh"
declare -f planner_stop_phase >/dev/null 2>&1 ||
  source "${_PLANNER_STOP_DESCRIBE_DIR}/planner-router.sh"
declare -f planner_adr_gate_blocked >/dev/null 2>&1 ||
  source "${_PLANNER_STOP_DESCRIBE_DIR}/planner-adr-gate.sh"
declare -f planner_specify_decisions_open >/dev/null 2>&1 ||
  source "${_PLANNER_STOP_DESCRIBE_DIR}/planner-specify-decisions.sh"
declare -f planner_consensus_gate >/dev/null 2>&1 ||
  source "${_PLANNER_STOP_DESCRIBE_DIR}/planner-consensus-gate.sh"

# The reason values this script emits as a block (the rest are terminal lines).
PLANNER_STOP_BLOCK_REASONS="CREATE_GATE CROSSCHECK_BLOCKED CONSENSUS_BLOCKED ADR_GATE SPECIFY_DECISION PROJECT_GATE REFINEMENT_HALT UNTIL_STOP"

# Longest finding/message excerpt quoted inside a question.
_PLANNER_STOP_EXCERPT_MAX=200
# Longest Specify business question quoted inside a question (design D4).
_PLANNER_STOP_DECISION_MAX=600

# planner_stop_round <INIT>
# One more than the number of answered rounds. The same log always yields the
# same round.
planner_stop_round() {
  local log count
  log=$(planner_state_log "$1") || return 1
  count=0
  [ -f "$log" ] && count=$(grep -c '^[^|]*|META|human-hold|done|' "$log" 2>/dev/null) || true
  echo $((${count:-0} + 1))
}

# _planner_stop_excerpt <text> [max]
# Single-line, length-capped excerpt for question text (max defaults to 200).
_planner_stop_excerpt() {
  local text max="${2:-$_PLANNER_STOP_EXCERPT_MAX}"
  text=$(printf '%s' "$1" | tr '\n\r\t' '   ' | tr -s ' ')
  if [ "${#text}" -gt "$max" ]; then
    text="${text:0:$max}…"
  fi
  printf '%s' "$text"
}

# _planner_stop_question <id> <binding> <text> [options] [default]
_planner_stop_question() {
  jq -nc --arg id "$1" --arg binding "$2" --arg text "$3" \
    --arg options "${4:-}" --arg default "${5:-}" \
    '{id: $id, text: $text, binding: $binding}
     + (if $options == "" then {} else {options: ($options | split("|"))} end)
     + (if $default == "" then {} else {default: $default} end)'
}

# _planner_stop_model <reason> <blocks> <round> <questions_json> [kind] [audience]
# kind defaults to approval and audience to operator — every stop but
# SPECIFY_DECISION, whose output must not move a byte.
_planner_stop_model() {
  jq -nc --arg reason "$1" --arg blocks "$2" --argjson round "$3" \
    --argjson questions "$4" --arg kind "${5:-approval}" \
    --arg audience "${6:-operator}" \
    '{reason: $reason, terminal: false, phase: "PLANNER", kind: $kind,
      audience: $audience, round: $round, blocks: $blocks,
      questions: $questions}'
}

_planner_stop_terminal() {
  jq -nc --arg reason "$1" --arg detail "${2:-}" \
    '{reason: $reason, terminal: true}
     + (if $detail == "" then {} else {detail: $detail} end)'
}

# Is a phase holding the live phase lock right now?
_planner_stop_locked() {
  local log lock pid
  log=$(planner_state_log "$1") || return 1
  lock="${log}.phase-lock"
  [ -f "$lock" ] || return 1
  pid=$(cat "$lock" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Latest non-META line for <phase>: "<step>|<status>|<msg>".
_planner_stop_last_phase_line() {
  local log="$1" phase="$2"
  grep "^[^|]*|${phase}|" "$log" 2>/dev/null | tail -1 | cut -d'|' -f3-
}

# Every distinct backticked cited-artifact name in the latest Crosscheck
# attempt's <CODE> findings (#504), comma-separated — so an operator answering
# headlessly sees every artifact the code stands for, not just the first.
_planner_stop_cited_names() {
  _planner_stop_cited_name_list "$@" | head -20 | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g'
}

# The same names, one per line, without backticks, in finding order.
_planner_stop_cited_name_list() {
  local init="$1" code="$2" log start
  log=$(planner_state_log "$init") || return 1
  start=$(grep -n '|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  [ -n "$start" ] || return 0
  tail -n "+$((start + 1))" "$log" | grep "^[^|]*|META|crosscheck|fail|${code} " |
    cut -d'|' -f5- | grep -o 'cited artifact `[^`]*`' | sed 's/^cited artifact `//; s/`$//' |
    awk '!seen[$0]++'
}

# One headless question per unresolved cited artifact (#515), as JSON
# question objects on one line each. Each binds `consensus-answer:cited:<n>`,
# n being the artifact's question in consensus.md — the last CITED_ARTIFACT
# line for its name, the one Crosscheck reads. The id carries a hash of the
# name as well as n, so an answers file written before consensus.md was
# edited (questions renumbered) is refused as UNKNOWN_QUESTION_ID instead of
# answering the wrong artifact.
_planner_stop_cited_questions() {
  local init="$1" consensus key n lkey lname lkind lvalue lraw h
  declare -f planner_cited_answer_lines >/dev/null 2>&1 ||
    source "${_PLANNER_STOP_DESCRIBE_DIR}/planner-crosscheck-testdata.sh"
  consensus="$(planner_initiative_dir "$init")/artifacts/consensus.md" || return 1
  [ -f "$consensus" ] || return 0

  # Effective (last) line per name key.
  local -A last_n=() last_name=() last_kind=()
  while IFS=$'\037' read -r n lkey lname lkind lvalue lraw; do
    last_n["$lkey"]="$n"
    last_name["$lkey"]="$lname"
    last_kind["$lkey"]="$lkind"
  done < <(planner_cited_answer_lines "$consensus")

  local name seen=" "
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    key=$(_planner_testdata_name_key "$name")
    [ -n "${last_n[$key]+set}" ] || continue
    [ "${last_kind[$key]}" = "unresolved" ] || continue
    n="${last_n[$key]}"
    case "$seen" in *" $n "*) continue ;; esac
    seen="${seen}${n} "
    h=$(printf '%s' "$key" | _planner_stop_sha | cut -c1-8)
    _planner_stop_question "cited-${n}-${h}" "consensus-answer:cited:${n}" \
      "Cited artifact \`$(_planner_stop_excerpt "${last_name[$key]}")\` (consensus.md cited-artifact question ${n}) is cited but not retrievable. Answer exists:<where> if it exists (say where), external:<who> if someone outside will supply it, or generate if it should be synthesised. The answer is written into consensus.md; every spec need that cites it must carry the same Source, or Crosscheck reports CITED_ARTIFACT_SOURCE_MISMATCH."
  done < <(_planner_stop_cited_name_list "$init" CITED_ARTIFACT_UNRESOLVED)
}

# Slugs named by the latest Crosscheck attempt's TEST_DATA_IMPLIED findings,
# one per line, in finding order. The finding message starts
# `<slug>.md [<hash8>] match="…"`.
_planner_stop_testdata_slugs() {
  local init="$1" log start
  log=$(planner_state_log "$init") || return 1
  start=$(grep -n '|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  [ -n "$start" ] || return 0
  tail -n "+$((start + 1))" "$log" | grep '^[^|]*|META|crosscheck|fail|TEST_DATA_IMPLIED ' |
    cut -d'|' -f5- | sed -n 's/^TEST_DATA_IMPLIED \([A-Za-z0-9_-]*\)\.md \[[0-9a-f]\{8\}\] .*/\1/p' |
    awk '!seen[$0]++'
}

# One test-data question per spec with a TEST_DATA_IMPLIED finding in the
# latest Crosscheck attempt (planner-test-data-derivation), as JSON question
# objects on one line each. Bound to `consensus-answer:testdata:<slug>`; the id
# carries the hash of the spec's CURRENT trigger criterion, not the finding's,
# so a criterion rewritten since Crosscheck re-asks under a new id and an
# answers file written against the old one is refused (UNKNOWN_QUESTION_ID)
# instead of confirming text nobody read. A spec whose trigger is gone, no
# longer strong, or already answered under its current hash gets no question.
# Headless default: `generate: <matched noun phrase>`.
_planner_stop_testdata_questions() {
  local init="$1" state_dir ents slug spec trig tier reason phrase hash crit
  declare -f _planner_testdata_spec_trigger >/dev/null 2>&1 ||
    source "${_PLANNER_STOP_DESCRIBE_DIR}/planner-crosscheck-testdata.sh"
  state_dir=$(planner_initiative_dir "$init") || return 1
  ents=$(_planner_testdata_entity_names "$init")

  local -A resolved=()
  local r_slug r_hash r_rest
  while IFS=$'\037' read -r r_slug r_hash r_rest; do
    [ -n "$r_slug" ] && resolved["$r_slug"]="$r_hash"
  done < <(planner_testdata_confirm_resolved "$init" "$ents")

  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    spec="${state_dir}/artifacts/specs/${slug}.md"
    [ -f "$spec" ] || continue
    trig=$(_planner_testdata_spec_trigger "$spec" "$ents")
    [ -n "$trig" ] || continue
    IFS=$'\037' read -r tier reason phrase hash crit <<<"$trig"
    [ "$tier" = "strong" ] || continue
    [ "${resolved[$slug]:-}" = "$hash" ] && continue
    phrase=$(printf '%s' "$phrase" | tr -d '|\r\n`"')
    _planner_stop_question "testdata-${slug}-${hash}" "consensus-answer:testdata:${slug}" \
      "Spec \`${slug}\` says Test data none on every Verification Notes row, but its criterion \"$(_planner_stop_excerpt "$(printf '%s' "$crit" | tr -d '"')")\" implies data must exist first (matched \"${phrase}\"). Answer none if nothing must exist, generate: <what> to have the planner synthesise it, exists:<where> if it already exists, or external:<who> if someone outside will supply it. The answer is written into consensus.md as a TESTDATA_CONFIRM line for this criterion; rewriting the criterion voids it." \
      "none|generate: ${phrase}|exists|external" "generate: ${phrase}"
  done < <(_planner_stop_testdata_slugs "$init")
}

_planner_stop_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# Unaccepted blocking codes from the latest Crosscheck attempt, one
# "<CODE>\t<count>\t<first message>" line each, sorted by code.
_planner_stop_crosscheck_codes() {
  local init="$1" log start accepted
  log=$(planner_state_log "$init") || return 1
  start=$(grep -n '|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  [ -n "$start" ] || return 0

  # Accepted codes, read the way planner_crosscheck_run reads them: once
  # accepted, a code stays accepted for the life of the initiative.
  accepted=" $(grep '^[^|]*|META|crosscheck|accepted|' "$log" | cut -d'|' -f5- |
    awk '{print $1}' | sort -u | tr '\n' ' ')"

  tail -n "+$((start + 1))" "$log" | grep '^[^|]*|META|crosscheck|fail|' |
    cut -d'|' -f5- | awk -v accepted="$accepted" '
      { code = $1; msg = $0; sub(/^[^ ]+ ?/, "", msg)
        if (index(accepted, " " code " ")) next
        if (!(code in count)) first[code] = msg
        count[code]++ }
      END { for (c in count) printf "%s\t%d\t%s\n", c, count[c], first[c] }' |
    LC_ALL=C sort
}

# Waivable not-ready codes per Refinement child, "<TID>\t<CODE>" each, in
# epic-children order then code order. SEMANTIC_UNAVAILABLE/UNVERIFIED/STALE
# are excluded: resume retries those by itself, a waiver is not the answer.
# BODY_DRIFT/BODY_UNVERIFIED are excluded too — never waivable, they get the
# refresh question instead (_planner_stop_refinement_body_tids) — and so is
# any code in `ready.demoted` (an audit demotion no longer blocks).
_planner_stop_refinement_codes() {
  local init="$1"
  declare -f _planner_refinement_source_deps >/dev/null 2>&1 ||
    source "${_PLANNER_STOP_DESCRIBE_DIR}/planner-refinement.sh"
  _planner_refinement_source_deps >/dev/null 2>&1 || return 1

  local epic_id children tid ready_json
  epic_id=$(planner_epic_id "$init") || return 1
  children=$(get_epic_manifest_field "$epic_id" children 2>/dev/null)
  [ -n "$children" ] || children='[]'

  for tid in $(echo "$children" | jq -r '.[]' 2>/dev/null); do
    ready_json=$(get_ticket_manifest_field "$tid" ready 2>/dev/null)
    [ -n "$ready_json" ] && [ "$ready_json" != "null" ] || continue
    echo "$ready_json" | jq -r --arg tid "$tid" '
      select(.status != "ready")
      | (.waived // {} | keys) as $w
      | (.demoted // {} | keys) as $d
      | (.missing // [])[]
      | select(. as $c | ($w | index($c)) | not)
      | select(. as $c | ($d | index($c)) | not)
      | select(. != "SEMANTIC_UNAVAILABLE" and . != "SEMANTIC_UNVERIFIED" and . != "SEMANTIC_STALE")
      | select(. != "BODY_DRIFT" and . != "BODY_UNVERIFIED")
      | "\($tid)\t\(.)"' 2>/dev/null | LC_ALL=C sort -u
  done
}

# Not-ready Refinement children held on BODY_DRIFT or BODY_UNVERIFIED
# (planner-refinement-convergence D6), "<TID>\t<CODE[,CODE]>" each, in
# epic-children order.
_planner_stop_refinement_body_tids() {
  local init="$1"
  declare -f _planner_refinement_source_deps >/dev/null 2>&1 ||
    source "${_PLANNER_STOP_DESCRIBE_DIR}/planner-refinement.sh"
  _planner_refinement_source_deps >/dev/null 2>&1 || return 1

  local epic_id children tid ready_json
  epic_id=$(planner_epic_id "$init") || return 1
  children=$(get_epic_manifest_field "$epic_id" children 2>/dev/null)
  [ -n "$children" ] || children='[]'

  for tid in $(echo "$children" | jq -r '.[]' 2>/dev/null); do
    ready_json=$(get_ticket_manifest_field "$tid" ready 2>/dev/null)
    [ -n "$ready_json" ] && [ "$ready_json" != "null" ] || continue
    echo "$ready_json" | jq -r --arg tid "$tid" '
      select(.status != "ready")
      | [(.missing // [])[] | select(. == "BODY_DRIFT" or . == "BODY_UNVERIFIED")] | unique
      | select(length > 0)
      | "\($tid)\t\(join(","))"' 2>/dev/null
  done
}

# planner_stop_describe_json <INIT>
# Prints the stop model as one JSON object.
planner_stop_describe_json() {
  local init="$1" log pos round
  planner_validate_initiative_id "$init" || return 1
  log=$(planner_state_log "$init") || return 1
  if [ ! -f "$log" ]; then
    echo "planner-stop-describe: no state log for '${init}'" >&2
    return 1
  fi

  if _planner_stop_locked "$init"; then
    _planner_stop_terminal RUNNING "a phase holds the phase lock"
    return 0
  fi

  pos=$(planner_position_derive "$init")
  if [ -z "$pos" ]; then
    _planner_stop_terminal COMPLETED
    return 0
  fi

  round=$(planner_stop_round "$init")
  local q questions="[]"

  # ── ADR gate ───────────────────────────────────────────────────────────
  # Bound as `note`, not `adr:<ID>`: adr-store.sh's adr_accept refuses to run
  # inside an agent session (CLAUDE_CODE_SESSION_ID), so acceptance stays a
  # human action outside the planner. The answer only records that it was done.
  if [ "$pos" = "Architecture" ]; then
    local hit verdict adr_id
    if hit=$(planner_adr_gate_blocked "$init" "Architecture" "design"); then
      verdict=$(printf '%s' "$hit" | cut -f1)
      adr_id=$(printf '%s' "$hit" | cut -f2)
      q=$(_planner_stop_question "adr-${adr_id:-unknown}" "note" \
        "Architecture is parked on the ADR gate (${verdict}, ${adr_id:-no id}). Accept or resolve ${adr_id:-the ADR} out of band (adr-store.sh accept), then answer 'resolved' to re-run Architecture." \
        "resolved" "")
      questions=$(jq -nc --argjson q "$q" '[$q]')
      _planner_stop_model ADR_GATE "artifacts/architecture.md" "$round" "$questions"
      return 0
    fi
  fi

  # ── Specify decisions ──────────────────────────────────────────────────
  # Read-only: the scan of proposal.md, never planner_specify_gate (which
  # writes the tripwire line). Checked before the create gate and --until,
  # so a run stopped by --until Specify surfaces the decision in the same
  # run. No OPTIONS and no DEFAULT: a default would be a business outcome
  # the planner made up.
  if [ "$pos" = "Review" ]; then
    local open oid h8 lno dq
    if ! open=$(planner_specify_decisions_open "$init"); then
      echo "planner-stop-describe: cannot scan proposal.md for '${init}'" >&2
      return 1
    fi
    if [ -n "$open" ]; then
      while IFS=$'\t' read -r oid h8 lno dq; do
        [ -n "$oid" ] || continue
        q=$(_planner_stop_question "decision-${oid}-${h8}" "specify-answer:${oid}" \
          "Specify could not source business outcome ${oid} and needs a decision: $(_planner_stop_excerpt "$dq" "$_PLANNER_STOP_DECISION_MAX"). Answer in one line (at most 500 characters); it is written into proposal.md as a verbatim human decision. Answer __defer__ to leave it open and carry the question into the epic unresolved.")
        questions=$(jq -nc --argjson a "$questions" --argjson q "$q" '$a + [$q]')
      done <<<"$open"
      _planner_stop_model SPECIFY_DECISION "artifacts/proposal.md" "$round" "$questions" input either
      return 0
    fi
  fi

  # ── consensus readiness ────────────────────────────────────────────────
  # Read-only, like the halt itself (planner-consensus-gate.sh): bound as
  # `note` — the answer records that the plan was fixed; the gate releases
  # only when consensus.md's Readiness is no longer `blocked`.
  if [ "$pos" = "Crosscheck" ]; then
    local cg_rc=0
    planner_consensus_gate "$init" || cg_rc=$?
    if [ "$cg_rc" -eq 3 ]; then
      q=$(_planner_stop_question "consensus-blocked" "note" \
        "Consensus marked the plan Readiness: blocked — it could not resolve a blocking review finding. Fix the plan, change consensus.md's Readiness to ready-for-spec (or re-run Consensus), then answer 'resolved' to run Crosscheck." \
        "resolved" "")
      questions=$(jq -nc --argjson q "$q" '[$q]')
      _planner_stop_model CONSENSUS_BLOCKED "artifacts/consensus.md" "$round" "$questions"
      return 0
    fi
  fi

  # ── create gate ────────────────────────────────────────────────────────
  if planner_phase_writes_linear "$pos" && ! planner_create_authorized "$init"; then
    q=$(_planner_stop_question "create" "flag:create" \
      "Planning for ${init} reached the create gate: Crosscheck passed and nothing is in Linear yet. Create the epic and its tickets in Linear?" \
      "yes|no" "no")
    questions=$(jq -nc --argjson q "$q" '[$q]')
    _planner_stop_model CREATE_GATE "artifacts/specs/" "$round" "$questions"
    return 0
  fi

  # ── project gate ───────────────────────────────────────────────────────
  if [ "$pos" = "EpicGen" ]; then
    local last candidate
    last=$(_planner_stop_last_phase_line "$log" "EpicGen")
    case "$last" in
    "project|fail|"*"matches this initiative"*)
      candidate=$(printf '%s' "$last" | sed -n "s/.*team project '\(.*\)' matches this initiative.*/\1/p")
      if [ -n "$candidate" ]; then
        q=$(_planner_stop_question "project" "flag:project" \
          "Epic Gen stopped: no Linear project is set, but the team project '${candidate}' matches this initiative. File the epic and its tickets under it? Answer with a project name or id, or __none__ for no project." \
          "${candidate}|__none__" "")
        questions=$(jq -nc --argjson q "$q" '[$q]')
        _planner_stop_model PROJECT_GATE "state.log#EpicGen-project" "$round" "$questions"
        return 0
      fi
      ;;
    esac
  fi

  # ── crosscheck blocker ─────────────────────────────────────────────────
  if [ "$pos" = "Crosscheck" ] &&
    [ "$(grep '|Crosscheck|check|' "$log" | tail -1 | cut -d'|' -f4)" = "fail" ]; then
    local code count msg
    local cited
    while IFS=$'\t' read -r code count msg; do
      [ -n "$code" ] || continue
      case "$code" in
      CITED_ARTIFACT_*)
        # #515: an unanswered artifact gets its own question, whose answer is
        # written into consensus.md. Emitted ahead of the code's accept
        # question, which stays as the blanket override (#504).
        if [ "$code" = "CITED_ARTIFACT_UNRESOLVED" ]; then
          while IFS= read -r q; do
            [ -n "$q" ] || continue
            questions=$(jq -nc --argjson a "$questions" --argjson q "$q" '$a + [$q]')
          done < <(_planner_stop_cited_questions "$init")
        fi
        # #504: name every artifact, and say how to answer each one; the
        # accept binding stays as the blanket override.
        cited=$(_planner_stop_cited_names "$init" "$code")
        q=$(_planner_stop_question "accept-${code}" "flag:accept:${code}" \
          "Crosscheck blocking finding ${code} (${count}x) for cited artifact(s): ${cited:-see state.log} — answer each in consensus.md ## Open Questions (Answer: exists:<where>, external:<who> or generate), set the matching specs' Source to it, and resume. Or accept the code for every artifact as genuine and expected: answer with the reason, or __skip__ to fix the artifacts instead.")
        ;;
      *)
        # planner-test-data-derivation: one TESTDATA_CONFIRM question per
        # spec, ahead of the code's blanket accept question.
        if [ "$code" = "TEST_DATA_IMPLIED" ]; then
          while IFS= read -r q; do
            [ -n "$q" ] || continue
            questions=$(jq -nc --argjson a "$questions" --argjson q "$q" '$a + [$q]')
          done < <(_planner_stop_testdata_questions "$init")
        fi
        q=$(_planner_stop_question "accept-${code}" "flag:accept:${code}" \
          "Crosscheck blocking finding ${code} (${count}x): $(_planner_stop_excerpt "$msg") — Accept it as genuine and expected? Answer with the reason, or __skip__ to fix the artifacts instead.")
        ;;
      esac
      questions=$(jq -nc --argjson a "$questions" --argjson q "$q" '$a + [$q]')
    done < <(_planner_stop_crosscheck_codes "$init")
    if [ "$questions" != "[]" ]; then
      _planner_stop_model CROSSCHECK_BLOCKED "state.log#Crosscheck" "$round" "$questions"
      return 0
    fi
  fi

  # ── refinement halt ────────────────────────────────────────────────────
  if [ "$pos" = "Refinement" ] && grep -q '|META|refinement-gate|fail|' "$log" 2>/dev/null; then
    local tid code
    # Sourced here, not inside the helper: the helper runs in a process
    # substitution, and planner_epic_id is needed in this shell too.
    declare -f planner_epic_id >/dev/null 2>&1 ||
      source "${_PLANNER_STOP_DESCRIBE_DIR}/planner-refinement.sh"
    # Body drift is answered by taking Linear's text, never by a waiver
    # (planner-refinement-convergence D6): one question for the epic, bound
    # to the one-shot --refresh-bodies flag.
    local body_list
    body_list=$(_planner_stop_refinement_body_tids "$init" | awk -F'\t' '{printf "%s%s (%s)", (NR > 1 ? ", " : ""), $1, $2}')
    if [ -n "$body_list" ]; then
      q=$(_planner_stop_question "refresh-bodies" "flag:refresh-bodies" \
        "Refinement cannot trust these bodies: $(_planner_stop_excerpt "$body_list"). BODY_DRIFT means the Linear description and the body Refinement evaluated disagree; BODY_UNVERIFIED means Linear could not be read. Neither can be waived. Take Linear's text for every drifted ticket (resume --refresh-bodies)? For a local-ahead ticket, copy the local edit into Linear first." \
        "yes|no" "no")
      questions=$(jq -nc --argjson a "$questions" --argjson q "$q" '$a + [$q]')
    fi
    while IFS=$'\t' read -r tid code; do
      [ -n "$tid" ] || continue
      q=$(_planner_stop_question "waive-${tid}-${code}" "waive:${tid}:${code}" \
        "${tid} is not ready: ${code}. Waive it? Answer with the reason, or __skip__ to fix the ticket instead.")
      questions=$(jq -nc --argjson a "$questions" --argjson q "$q" '$a + [$q]')
    done < <(_planner_stop_refinement_codes "$init")
    if [ "$questions" != "[]" ]; then
      _planner_stop_model REFINEMENT_HALT "epic $(planner_epic_id "$init")" "$round" "$questions"
      return 0
    fi
  fi

  # ── --until stop ───────────────────────────────────────────────────────
  local until_phase until_idx pos_idx
  until_phase=$(planner_config_get "$init" "stop-after")
  if [ -n "$until_phase" ]; then
    until_idx=$(planner_phase_index "$until_phase" 2>/dev/null) || until_idx=-1
    pos_idx=$(planner_phase_index "$pos" 2>/dev/null) || pos_idx=-1
    if [ "$until_idx" -ge 0 ] && [ "$pos_idx" -eq $((until_idx + 1)) ] &&
      planner_phase_is_done "$init" "$until_phase"; then
      q=$(_planner_stop_question "continue" "note" \
        "The run stopped after ${until_phase} because --until ${until_phase} was set. Answer 'continue' to resume from ${pos}." \
        "continue" "")
      questions=$(jq -nc --argjson q "$q" '[$q]')
      _planner_stop_model UNTIL_STOP "state.log#stop-after" "$round" "$questions"
      return 0
    fi
  fi

  if planner_phase_retries_exhausted "$init" "$pos"; then
    _planner_stop_terminal FAILED_RETRY_EXHAUSTED "${pos} exhausted its retry budget"
    return 0
  fi

  _planner_stop_terminal RUNNING "resume continues from ${pos}"
}

# planner_stop_describe <INIT>
# Prints the v2 hold block, or one REASON=<terminal> line.
planner_stop_describe() {
  local model
  model=$(planner_stop_describe_json "$1") || return 1

  if [ "$(printf '%s' "$model" | jq -r '.terminal')" = "true" ]; then
    echo "REASON=$(printf '%s' "$model" | jq -r '.reason')"
    return 0
  fi

  # Values are single-line by construction (_planner_stop_excerpt and the
  # fixed templates above); jq -r renders them as data, never through a shell.
  printf '%s' "$model" | jq -r '
    "=== HUMAN_HOLD ===",
    "SCHEMA_VERSION: 2",
    "PHASE: \(.phase)",
    "REASON: \(.reason)",
    "BLOCKS: \(.blocks)",
    "ROUND: \(.round)",
    "KIND: \(.kind)",
    "AUDIENCE: \(.audience)",
    (.questions | to_entries[] | (.key + 1) as $n | .value |
      "QUESTION_\($n): \(.text)",
      "QUESTION_\($n)_ID: \(.id)",
      (if .options then "QUESTION_\($n)_OPTIONS: \(.options | join("|"))" else empty end),
      (if .default then "QUESTION_\($n)_DEFAULT: \(.default)" else empty end),
      "QUESTION_\($n)_BINDING: \(.binding)"),
    "=== END HUMAN_HOLD ==="'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ -z "${1:-}" ]; then
    echo "Usage: planner-stop-describe.sh <INIT_ID> [--json]" >&2
    exit 2
  fi
  if [ "${2:-}" = "--json" ]; then
    planner_stop_describe_json "$1"
  else
    planner_stop_describe "$1"
  fi
  exit $?
fi
