#!/usr/bin/env bash
# planner-draft-readiness-gate.sh — the draft readiness gate
# (openspec change planner-draft-readiness, slice S2b: design D1, D4–D7, D16).
#
# Before the first Linear write, every spec's would-be ticket body (the draft,
# planner-draft-readiness.sh) goes through the same deterministic DoR check
# and the same semantic evaluator Refinement runs on real tickets. Before
# a draft with a blocking finding halts the run with `DRAFT_NOT_READY`
# (nothing exists in Linear yet), the bounded revise loop in
# planner-draft-readiness-loop.sh (S3b) tries to fix the specs;
# PLANNER_DRAFT_REVISE_MAX_ROUNDS=0 keeps the halt-only gate.
#
# Bash cannot spawn agents, so SKILL.md drives the gate with the shared
# spawn-list loop (step 1d):
#
#   planner_draft_readiness_begin <INIT>   rc 0 run the loop, 2 passed with no
#                                          evaluation (skip / accepted), 3 halt
#                                          (re-run Crosscheck blocked), 1 error
#   planner_draft_readiness_next <INIT>    one spawn line per agent to run now,
#                                          "<slug>\t<kind>\t<subagent-type>\t<prompt-file>\t<result-file>",
#                                          or "done 0"
#   planner_draft_readiness_apply <INIT>   consumes the result files
#   planner_draft_readiness_gate <INIT>    rc 0 every draft ready, 3 blocked;
#                                          writes the fail and done lines
#   planner_draft_readiness_report <INIT>  the halt report (stdout)
#
# Other entry points:
#   planner_draft_readiness_accept <INIT> <reason>
#                                          `--accept DRAFT_NOT_READY:"…"`: binds
#                                          the accept to the combined draft hash
#                                          computed now (D5, D16)
#   planner_draft_readiness_combined_hash <INIT>
#                                          sha256 over "<slug> <body-hash>" lines
#                                          + the evaluator; composes in memory
#   planner_draft_readiness_state <INIT>   none|running|ready|accepted|blocked|stale|crosscheck
#                                          (read-only; the stop describer's input)
#
# State on disk, under artifacts/draft-readiness/ (D4): per spec `body.md`,
# `dor-result.json`, `scan-prompt.txt`, `scan-result.txt`, `audit-prompt.txt`,
# `audit-result.txt`, `semantic.json`, `attempts` ("<hash> <n>"), and
# `verdict` written last; at the root `.pending` (the last spawn list) and
# `blocked-specs` (spec file hashes of the last blocked run, D5 re-Crosscheck).
#
# The gate never calls Linear and never creates or writes a ticket or epic
# manifest. The semantic verdict is judged by ticket-auto-pipeline's own pure
# functions (dor_semantic_findings → dor_semantic_lineage_from with the
# draft's lineage.json as prior → dor_semantic_assemble →
# dor_semantic_blocking_codes), so drafts get the same findings, severity and
# SEMANTIC_* codes as Refinement without a copy of either (D3/D16 parity).
#
# Sourceable library — no set -euo pipefail.

_PLANNER_DRAFT_GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f planner_draft_readiness_refresh >/dev/null 2>&1; then
  # shellcheck source=planner-draft-readiness.sh
  source "${_PLANNER_DRAFT_GATE_LIB_DIR}/planner-draft-readiness.sh"
fi
if ! declare -f planner_draft_readiness_loop_close >/dev/null 2>&1; then
  # shellcheck source=planner-draft-readiness-loop.sh
  source "${_PLANNER_DRAFT_GATE_LIB_DIR}/planner-draft-readiness-loop.sh"
fi

PLANNER_DRAFT_AGENT_TYPE="ticket-auto-pipeline:dor-semantic-agent"
# Agent attempts per draft and body hash before its verdict is `unavailable`
# (one retry, as Refinement does — D5).
PLANNER_DRAFT_MAX_ATTEMPTS=2

_planner_draft_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

_planner_draft_tid() { printf '%s%s' "$PLANNER_DRAFT_ID_PREFIX" "$1"; }

# Line number of the latest `META|draft-readiness|start` (empty: none).
_planner_draft_start_line() {
  local log
  log=$(planner_state_log "$1" 2>/dev/null) || return 1
  [ -f "$log" ] || return 0
  grep -n '^[^|]*|META|draft-readiness|start|' "$log" | tail -1 | cut -d: -f1
}

# Lines of the latest gate run (everything after its start line).
_planner_draft_run_lines() {
  local log start
  log=$(planner_state_log "$1" 2>/dev/null) || return 1
  start=$(_planner_draft_start_line "$1")
  [ -n "$start" ] || return 0
  tail -n "+$((start + 1))" "$log"
}

# "<slug>\t<sha256 of the spec file>" per spec, sorted.
_planner_draft_spec_hashes() {
  local specs_dir slug
  specs_dir=$(planner_ticketgen_specs_dir "$1") || return 1
  while IFS= read -r slug; do
    [ -n "$slug" ] && printf '%s\t%s\n' "$slug" "$(_planner_draft_sha <"${specs_dir}/${slug}.md")"
  done < <(planner_ticketgen_slugs "$specs_dir")
}

# planner_draft_readiness_combined_hash <INIT>
# Composes every draft in memory (no file written) and hashes the sorted
# "<slug> <body-hash>" lines plus the evaluator, so an accept binds to the
# exact text the evaluator judged. rc 1 when a draft does not compose.
planner_draft_readiness_combined_hash() {
  local init="$1" specs_dir slug body
  specs_dir=$(planner_ticketgen_specs_dir "$init") || return 1
  _planner_refinement_source_deps >/dev/null || return 1
  {
    while IFS= read -r slug; do
      [ -z "$slug" ] && continue
      body=$(planner_draft_readiness_compose "$init" "$slug") || return 1
      printf '%s %s\n' "$slug" "$(_dor_body_hash "$body")"
    done < <(planner_ticketgen_slugs "$specs_dir")
    printf 'evaluator %s\n' "${DOR_SEMANTIC_EVALUATOR:-}"
  } | _planner_draft_sha
}

# planner_draft_readiness_accept <INIT> <reason>
# Writes `META|draft-readiness|accepted|<combined-hash> <reason>`. Never
# touches planner_crosscheck_accept_set: the Crosscheck summary stays clean.
planner_draft_readiness_accept() {
  local init="$1" reason="$2" h
  if [ -z "${reason//[[:space:]]/}" ]; then
    echo "planner-draft-readiness: --accept DRAFT_NOT_READY needs a reason" >&2
    return 1
  fi
  h=$(planner_draft_readiness_combined_hash "$init") || {
    echo "planner-draft-readiness: cannot accept DRAFT_NOT_READY — the drafts do not compose (has Crosscheck passed?)" >&2
    return 1
  }
  planner_state_write "$init" "META" "draft-readiness" "accepted" "${h} ${reason}"
}

# The reason of an accept bound to <hash> (rc 1: none).
_planner_draft_accepted() {
  local log line
  log=$(planner_state_log "$1" 2>/dev/null) || return 1
  line=$(grep "^[^|]*|META|draft-readiness|accepted|${2} " "$log" 2>/dev/null | tail -1)
  [ -n "$line" ] || return 1
  printf '%s\n' "${line#*|META|draft-readiness|accepted|${2} }"
}

# The deterministic DoR pass for one draft (D5): ticket-auto's
# check_ticket_ready on body.md with Refinement's strict prefixes, written
# to dor-result.json (the shape the audit prompt reads). Writes no manifest:
# DRAFT-<slug> has none, and check_ticket_ready only reads one.
_planner_draft_det() {
  local init="$1" slug="$2" dir specs_dir type
  dir="$(planner_draft_readiness_root "$init")/${slug}"
  specs_dir=$(planner_ticketgen_specs_dir "$init") || return 1
  type=$(planner_ticketgen_spec_type "${specs_dir}/${slug}.md" 2>/dev/null) || type=""
  [ -n "$type" ] || type="feature"
  DOR_MISSING="" DOR_ADVISORY="" DOR_STATUS=""
  DOR_STRICT_TEST_DATA=true DOR_STRICT_VPLAN=true \
    check_ticket_ready "$(_planner_draft_tid "$slug")" --body "${dir}/body.md" --type "$type" --no-fetch >/dev/null 2>&1 || true
  case "${DOR_STATUS:-}" in
  ready | not-ready) ;;
  *) DOR_MISSING='["DOR_CHECK_UNAVAILABLE"]' DOR_ADVISORY='[]' DOR_STATUS="not-ready" ;;
  esac
  jq -nc --argjson m "${DOR_MISSING:-[]}" --argjson a "${DOR_ADVISORY:-[]}" --arg s "$DOR_STATUS" \
    '{missing: $m, advisory: $a, status: $s}' >"${dir}/dor-result.json.tmp" &&
    mv -f "${dir}/dor-result.json.tmp" "${dir}/dor-result.json"
}

# Failed agent attempts for <slug> on body <hash>.
_planner_draft_attempts() {
  local f h n
  f="$(planner_draft_readiness_root "$1")/$2/attempts"
  [ -f "$f" ] || {
    echo 0
    return 0
  }
  read -r h n <"$f"
  if [ "$h" = "$3" ] && [[ "$n" =~ ^[0-9]+$ ]]; then echo "$n"; else echo 0; fi
}

# planner_draft_readiness_begin <INIT>
# Opens a gate run. Order (D1, D5):
#   1. an explicit `--until Crosscheck` skips the gate (`skip` line, rc 2);
#   2. `start` line;
#   3. specs changed since the last blocked run → planner_crosscheck_run
#      first; a blocking Crosscheck finding halts (rc 3);
#   4. recompose every draft (cache, D4) and run the deterministic pass;
#   5. an accept bound to the current combined hash passes (rc 2).
# rc 0 = run the spawn loop, then planner_draft_readiness_gate.
planner_draft_readiness_begin() {
  local init="$1" root specs_now prev slug hash status reason combined n=0
  if [ "$(planner_config_get "$init" "stop-after" 2>/dev/null)" = "Crosscheck" ]; then
    planner_state_write "$init" "META" "draft-readiness" "skip" "--until Crosscheck"
    return 2
  fi
  planner_draft_readiness_config_check || return 1
  root=$(planner_draft_readiness_root "$init") || return 1
  _planner_refinement_source_deps >/dev/null || return 1
  # A revise round left open by a crash: write nothing the round's guards
  # would see as an out-of-scope edit; `next` settles the round first.
  if [ -f "$(_pdl_round_file "$init")" ]; then
    planner_draft_revise_log "$init" "$(_pdl_round_snap "$init")" "META" "draft-readiness" "start" "evaluator=${DOR_SEMANTIC_EVALUATOR:-} resume-round"
    return 0
  fi
  planner_state_write "$init" "META" "draft-readiness" "start" "evaluator=${DOR_SEMANTIC_EVALUATOR:-}" || return 1
  rm -f "${root}/halt"
  # No round open: a pre-round copy left by an interrupted run is stale.
  _pdl_eval_drop "$init"

  if [ -f "${root}/blocked-specs" ]; then
    specs_now=$(_planner_draft_spec_hashes "$init") || return 1
    prev=$(cat "${root}/blocked-specs")
    if [ "$specs_now" != "$prev" ]; then
      declare -f planner_crosscheck_run >/dev/null 2>&1 ||
        source "${_PLANNER_DRAFT_GATE_LIB_DIR}/planner-crosscheck.sh"
      if ! planner_crosscheck_run "$init" >/dev/null 2>&1; then
        planner_state_write "$init" "META" "draft-readiness" "fail" "CROSSCHECK_BLOCKED specs changed since the last blocked run and Crosscheck now blocks"
        planner_state_write "$init" "META" "draft-readiness" "done" "blocked crosscheck"
        return 3
      fi
    fi
  fi

  # An `unavailable` verdict is retried on every new run, as Refinement
  # retries SEMANTIC_UNAVAILABLE on resume; within one run it stands.
  local vf
  for vf in "$root"/*/verdict; do
    [ -f "$vf" ] || continue
    if [ "$(cut -d' ' -f3 "$vf")" = "unavailable" ]; then
      rm -f "$vf" "$(dirname "$vf")/semantic.json" "$(dirname "$vf")/attempts"
    fi
  done

  local refresh
  refresh=$(planner_draft_readiness_refresh "$init") || return 1
  planner_draft_readiness_spawns_begin "$init" || return 1
  while IFS=$'\t' read -r slug hash status; do
    [ -n "$slug" ] || continue
    n=$((n + 1))
    [ "$status" = "error" ] && continue
    _planner_draft_det "$init" "$slug" || return 1
  done <<<"$refresh"
  rm -f "${root}/.pending"

  if ! printf '%s\n' "$refresh" | grep -q $'\terror$'; then
    combined=$(
      printf '%s\n' "$refresh" | awk -F'\t' 'NF {print $1 " " $2}'
      printf 'evaluator %s\n' "${DOR_SEMANTIC_EVALUATOR:-}"
    )
    combined=$(printf '%s\n' "$combined" | _planner_draft_sha)
    if reason=$(_planner_draft_accepted "$init" "$combined"); then
      planner_state_write "$init" "META" "draft-readiness" "warn" "accepted ${combined} ${reason}"
      planner_state_write "$init" "META" "draft-readiness" "done" "accepted ${n}/${n}"
      return 2
    fi
  fi
  return 0
}

# planner_draft_readiness_next <INIT>
# Applies whatever results are already on disk (crash resume), then prints
# the next spawn list: a scan for each stale draft with no scan result, else
# an audit for each with a scan but no audit result — at most
# PLANNER_REFINEMENT_PARALLEL drafts per list. The audit is built only after
# the scan returned (the scan is blind by construction). Prints `done 0`
# when no draft needs an agent. Records the list in `.pending`.
planner_draft_readiness_next() {
  local init="$1" root slug hash status dir tid max emitted=0 out=""
  root=$(planner_draft_readiness_root "$init") || return 1
  # The spawn list is stdout's only content (strict contract, step 1e).
  # An open revise round settles first and writes nothing else meanwhile.
  if [ -f "$(_pdl_round_file "$init")" ]; then
    planner_draft_readiness_apply "$init" >&2 || return 1
    if [ -f "$(_pdl_round_file "$init")" ]; then
      _pdl_round_retry_list "$init"
      return
    fi
  fi
  local refresh="" revise=""
  refresh=$(planner_draft_readiness_refresh "$init") || return 1
  planner_draft_readiness_apply "$init" "$refresh" >&2 || return 1
  # A reverted revision changed a spec after the refresh: recompose.
  if [ -f "${root}/.recompose" ]; then
    rm -f "${root}/.recompose"
    refresh=$(planner_draft_readiness_refresh "$init") || return 1
  fi
  if [ -f "${root}/halt" ]; then
    refresh=""
  else
    refresh=$(_pdl_restatus "$init" "$refresh")
    _pdl_det_missing "$init" "$refresh" || return 1
  fi
  max="${PLANNER_REFINEMENT_PARALLEL:-4}"
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=4
  while IFS=$'\t' read -r slug hash status; do
    [ "$status" = "stale" ] || continue
    [ "$emitted" -lt "$max" ] || break
    dir="${root}/${slug}"
    tid=$(_planner_draft_tid "$slug")
    if [ ! -s "${dir}/scan-result.txt" ]; then
      # After a revision (or any edit) the rescan is scoped to the changed
      # sections, as Refinement scopes its rescans.
      local cs
      cs=$(_pdl_changed_sections "$dir")
      if [ -n "$cs" ]; then
        dor_semantic_prompt scan --changed-sections "$cs" "$tid" "${dir}/body.md" "${dir}/scan-result.txt" >"${dir}/scan-prompt.txt" || return 1
      else
        dor_semantic_prompt scan "$tid" "${dir}/body.md" "${dir}/scan-result.txt" >"${dir}/scan-prompt.txt" || return 1
      fi
      out+="${slug}"$'\t'"scan"$'\t'"${PLANNER_DRAFT_AGENT_TYPE}"$'\t'"${dir}/scan-prompt.txt"$'\t'"${dir}/scan-result.txt"$'\n'
    elif [ ! -s "${dir}/audit-result.txt" ]; then
      dor_semantic_prompt audit "$tid" "${dir}/body.md" "${dir}/audit-result.txt" "${dir}/dor-result.json" >"${dir}/audit-prompt.txt" || return 1
      out+="${slug}"$'\t'"audit"$'\t'"${PLANNER_DRAFT_AGENT_TYPE}"$'\t'"${dir}/audit-prompt.txt"$'\t'"${dir}/audit-result.txt"$'\n'
    else
      continue
    fi
    emitted=$((emitted + 1))
  done <<<"$refresh"
  if [ -n "$out" ] && ! _pdl_budget_ok "$init" "$emitted"; then
    out=""
  elif [ -n "$out" ]; then
    _pdl_spawns_add "$init" "$emitted"
    [ "$(_pdl_max_rounds)" -gt 0 ] && _pdl_info "$init" 0 "$emitted"
  fi
  if [ -z "$out" ]; then
    rm -f "${root}/.pending"
    [ -f "${root}/halt" ] || revise=$(_pdl_revise_next "$init" "$refresh") || return 1
    if [ -n "$revise" ]; then
      printf '%s' "$revise"
      return 0
    fi
    echo "done 0"
    return 0
  fi
  printf '%s' "$out" >"${root}/.pending"
  printf '%s' "$out"
}

# One failed attempt for <slug> on <hash>: the result files go, and the
# second failure makes the verdict `unavailable` (blocks).
_planner_draft_fail() {
  local init="$1" slug="$2" hash="$3" dir n
  dir="$(planner_draft_readiness_root "$init")/${slug}"
  n=$(($(_planner_draft_attempts "$init" "$slug" "$hash") + 1))
  printf '%s %s\n' "$hash" "$n" >"${dir}/attempts"
  rm -f "${dir}/scan-result.txt" "${dir}/audit-result.txt"
  if [ "$n" -ge "$PLANNER_DRAFT_MAX_ATTEMPTS" ]; then
    jq -nc --arg e "${DOR_SEMANTIC_EVALUATOR:-}" --arg h "$hash" \
      '{evaluator: $e, body_hash: $h, unavailable: true, findings: [], gaps: {}, audit: [], missed: []}' \
      >"${dir}/semantic.json"
    planner_draft_readiness_verdict_write "$init" "$slug" "$hash" "${DOR_SEMANTIC_EVALUATOR:-}" unavailable
  fi
}

# planner_draft_readiness_apply <INIT> [<refresh-output>]
# For each stale draft: a spawn in `.pending` whose result file is missing
# is a failed attempt; a draft with both result files is parsed and judged.
# A parse or judge failure is a failed attempt. A judged draft gets
# semantic.json, then `verdict` (written last): blocked when the semantic
# result has a SEMANTIC_* code or dor-result.json a missing code.
planner_draft_readiness_apply() {
  local init="$1" refresh="${2:-}" root parse slug hash status dir kind type pf rf
  root=$(planner_draft_readiness_root "$init") || return 1
  [ -d "$root" ] || return 0
  _planner_refinement_source_deps >/dev/null || return 1
  if [ -f "$(_pdl_round_file "$init")" ]; then
    _pdl_round_apply "$init"
    return
  fi
  parse=$(_planner_refinement_resolve "dor-semantic-parse.sh") || {
    echo "planner-draft-readiness: dor-semantic-parse.sh not found (install ticket-auto-pipeline)" >&2
    return 1
  }
  [ -n "$refresh" ] || refresh=$(planner_draft_readiness_refresh "$init") || return 1
  local -A failed=()
  if [ -f "${root}/.pending" ]; then
    while IFS=$'\t' read -r slug kind type pf rf; do
      [ -n "$slug" ] || continue
      [ -s "$rf" ] || failed[$slug]=1
    done <"${root}/.pending"
    rm -f "${root}/.pending"
  fi
  while IFS=$'\t' read -r slug hash status; do
    [ "$status" = "stale" ] || continue
    dir="${root}/${slug}"
    if [ -n "${failed[$slug]:-}" ]; then
      _planner_draft_fail "$init" "$slug" "$hash"
      continue
    fi
    [ -s "${dir}/scan-result.txt" ] && [ -s "${dir}/audit-result.txt" ] || continue
    local scan_json audit_json eval_json verdict=ready
    if ! scan_json=$(bash "$parse" --kind scan --result-file "${dir}/scan-result.txt" 2>/dev/null) ||
      ! audit_json=$(bash "$parse" --kind audit --result-file "${dir}/audit-result.txt" --det-result "${dir}/dor-result.json" 2>/dev/null) ||
      ! eval_json=$(_pdl_evaluate "$(_planner_draft_tid "$slug")" "$dir" "$scan_json" "$audit_json"); then
      _planner_draft_fail "$init" "$slug" "$hash"
      continue
    fi
    # A revision that raised a new structural finding is reverted, not judged.
    local regress
    if regress=$(_pdl_regression "$init" "$slug" "$eval_json"); then
      _pdl_revert_regression "$init" "$slug" "$regress" || return 1
      continue
    fi
    printf '%s\n' "$eval_json" | jq -c '.semantic' >"${dir}/semantic.json.tmp" &&
      mv -f "${dir}/semantic.json.tmp" "${dir}/semantic.json" || return 1
    _pdl_lineage_write "$dir" "$(jq -c '.lineage' <<<"$eval_json")" || return 1
    if printf '%s\n' "$eval_json" | jq -e '.codes | length > 0' >/dev/null 2>&1 ||
      jq -e '(.missing // []) | length > 0' "${dir}/dor-result.json" >/dev/null 2>&1; then
      verdict=blocked
    fi
    planner_draft_readiness_verdict_write "$init" "$slug" "$hash" "${DOR_SEMANTIC_EVALUATOR:-}" "$verdict" || return 1
  done <<<"$refresh"
  return 0
}

# _planner_draft_findings <dir>
# "<CODE>\t<quote>" per blocking finding of one draft: deterministic missing
# codes, blocking semantic findings, unverified findings and gaps
# (SEMANTIC_UNVERIFIED), SEMANTIC_UNAVAILABLE.
_planner_draft_findings() {
  local dir="$1"
  [ -f "${dir}/dor-result.json" ] && jq -r '(.missing // [])[] | . + "\t"' "${dir}/dor-result.json" 2>/dev/null
  [ -f "${dir}/semantic.json" ] && jq -r '
    if .unavailable == true then "SEMANTIC_UNAVAILABLE\t"
    else
      ((.findings // [])[] | select(.verified == true and .severity == "blocking")
        | "\(.code)\t\((.quote // .detail // "") | tostring | gsub("[\t\r\n]"; " "))"),
      ((.findings // [])[] | select(.verified == false) | "SEMANTIC_UNVERIFIED\t\(.code): \(.quote // "")"),
      ((.unverified_gaps // [])[] | "SEMANTIC_UNVERIFIED\tgap: \(.)")
    end' "${dir}/semantic.json" 2>/dev/null
  return 0
}

# planner_draft_readiness_gate <INIT>
# Closes the gate run: one `META|draft-readiness|fail|<slug> <CODE> "<quote>"`
# line per blocking finding, then `done|blocked n/m` (rc 3) or
# `done|ready m/m` (rc 0). A draft with no current verdict after the loop,
# or one that does not compose, blocks. A blocked run records the spec
# hashes so the next run re-runs Crosscheck when a spec changed (D5).
planner_draft_readiness_gate() {
  local init="$1" root slug hash status dir v_hash v_eval v_status total=0 blocked=0 code quote
  root=$(planner_draft_readiness_root "$init") || return 1
  _planner_refinement_source_deps >/dev/null || return 1
  local refresh halt=""
  refresh=$(planner_draft_readiness_refresh "$init") || return 1
  planner_draft_readiness_loop_close "$init" "$refresh" || return 1
  _pdl_eval_drop "$init"
  [ -f "${root}/halt" ] && halt=$(cat "${root}/halt")
  while IFS=$'\t' read -r slug hash status; do
    [ -n "$slug" ] || continue
    total=$((total + 1))
    dir="${root}/${slug}"
    local lines=""
    if [ "$status" = "error" ]; then
      lines="DRAFT_COMPOSE_FAILED"$'\t'
    else
      v_hash="" v_eval="" v_status=""
      [ -f "${dir}/verdict" ] && read -r v_hash v_eval v_status <"${dir}/verdict"
      if [ "$v_hash" != "$hash" ] || [ "$v_eval" != "${DOR_SEMANTIC_EVALUATOR:-}" ]; then
        lines="SEMANTIC_UNAVAILABLE"$'\t'"no verdict for the current draft"
      else
        lines=$(_planner_draft_findings "$dir")
        if [ -z "$lines" ] && [ "$v_status" != "ready" ]; then
          lines="SEMANTIC_${v_status^^}"$'\t'
        fi
      fi
    fi
    [ -n "$lines" ] || continue
    blocked=$((blocked + 1))
    while IFS=$'\t' read -r code quote; do
      [ -n "$code" ] || continue
      quote=$(printf '%s' "$quote" | tr '\n\r"' "  '")
      planner_state_write "$init" "META" "draft-readiness" "fail" "${slug} ${code} \"${quote}\""
    done <<<"$lines"
  done <<<"$refresh"

  _pdl_spawns_close "$init"
  if [ -n "$halt" ]; then
    quote="${halt#* }"
    planner_state_write "$init" "META" "draft-readiness" "fail" "(run) ${halt%% *} \"${quote//\"/\'}\""
  fi
  if [ "$blocked" -gt 0 ] || [ -n "$halt" ]; then
    _planner_draft_spec_hashes "$init" >"${root}/blocked-specs.tmp" &&
      mv -f "${root}/blocked-specs.tmp" "${root}/blocked-specs"
    planner_state_write "$init" "META" "draft-readiness" "done" "blocked ${blocked}/${total}${halt:+ ${halt%% *}}"
    return 3
  fi
  rm -f "${root}/blocked-specs"
  planner_state_write "$init" "META" "draft-readiness" "done" "ready ${total}/${total}"
  planner_draft_readiness_history_report "$init"
  planner_draft_readiness_security_report "$init"
  planner_draft_readiness_missed_report "$init"
  return 0
}

# planner_draft_readiness_report <INIT>
# The halt report for the latest gate run, grouped by spec, from its fail
# lines. A run halted by the Crosscheck re-run prints Crosscheck's own
# remediation report instead.
planner_draft_readiness_report() {
  local init="$1" run state_dir done_msg slug code quote cur=""
  run=$(_planner_draft_run_lines "$init") || return 1
  state_dir=$(dirname "$(planner_state_log "$init")")
  done_msg=$(printf '%s\n' "$run" | grep '^[^|]*|META|draft-readiness|done|' | tail -1 | cut -d'|' -f5-)
  if [ "$done_msg" = "blocked crosscheck" ]; then
    declare -f planner_crosscheck_findings_report >/dev/null 2>&1 ||
      source "${_PLANNER_DRAFT_GATE_LIB_DIR}/planner-crosscheck.sh"
    echo "Draft readiness halted — specs changed since the last blocked run, and Crosscheck now blocks."
    echo ""
    planner_crosscheck_findings_report "$init"
    echo ""
    echo "Artifacts:  ${state_dir}/artifacts/"
    echo "Resume:     /ticket-planner resume ${init}"
    return 0
  fi
  case "$done_msg" in
  ready* | accepted*)
    echo "Draft readiness passed (${done_msg}) — nothing was created in Linear yet."
    echo ""
    planner_draft_readiness_history_report "$init"
    planner_draft_readiness_security_report "$init"
    planner_draft_readiness_missed_report "$init"
    echo "Artifacts:  ${state_dir}/artifacts/draft-readiness/"
    return 0
    ;;
  "")
    echo "Draft readiness has not finished (no done line in the latest run)."
    echo "Resume:     /ticket-planner resume ${init}"
    return 0
    ;;
  esac
  echo "Draft readiness halted (${done_msg#blocked }) — nothing was created in Linear."
  printf '%s\n' "$run" | grep '^[^|]*|META|draft-readiness|fail|' | cut -d'|' -f5- |
    while read -r slug code quote; do
      if [ "$slug" != "$cur" ]; then
        echo ""
        echo "${slug} (artifacts/specs/${slug}.md)"
        cur="$slug"
      fi
      if [ "$quote" = '""' ] || [ -z "$quote" ]; then
        echo "  - ${code}"
      else
        echo "  - ${code}: ${quote}"
      fi
    done
  echo ""
  planner_draft_readiness_history_report "$init"
  planner_draft_readiness_security_report "$init"
  planner_draft_readiness_missed_report "$init"
  echo "Edit artifacts/specs/<slug>.md, then: /ticket-planner resume ${init}"
  echo "A draft pass does not guarantee Refinement passes; Refinement re-checks the real ticket bodies."
  echo "Accept as is: /ticket-planner resume ${init} --accept DRAFT_NOT_READY:\"<reason>\""
  echo "Artifacts:  ${state_dir}/artifacts/draft-readiness/"
}

# planner_draft_readiness_state <INIT>
# Read-only (composes in memory, writes nothing). Prints:
#   none        no gate run yet
#   running     the latest run has no done line
#   crosscheck  the latest run halted on the Crosscheck re-run
#   ready       the latest run passed
#   accepted    an accept bound to the current combined hash holds
#   blocked     the latest run blocked and every verdict is still current
#   stale       the latest run blocked but a draft or verdict changed since
planner_draft_readiness_state() {
  local init="$1" run done_msg root specs_dir slug body hash v_hash v_eval v_status combined
  run=$(_planner_draft_run_lines "$init") || return 1
  [ -n "$(_planner_draft_start_line "$init")" ] || {
    echo none
    return 0
  }
  done_msg=$(printf '%s\n' "$run" | grep '^[^|]*|META|draft-readiness|done|' | tail -1 | cut -d'|' -f5-)
  case "$done_msg" in
  "") echo running ;;
  "blocked crosscheck") echo crosscheck ;;
  ready* | accepted*) echo ready ;;
  blocked*)
    if combined=$(planner_draft_readiness_combined_hash "$init" 2>/dev/null) &&
      _planner_draft_accepted "$init" "$combined" >/dev/null; then
      echo accepted
      return 0
    fi
    root=$(planner_draft_readiness_root "$init") || return 1
    specs_dir=$(planner_ticketgen_specs_dir "$init") || return 1
    _planner_refinement_source_deps >/dev/null || return 1
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      body=$(planner_draft_readiness_compose "$init" "$slug" 2>/dev/null) || continue
      hash=$(_dor_body_hash "$body")
      v_hash="" v_eval="" v_status=""
      [ -f "${root}/${slug}/verdict" ] && read -r v_hash v_eval v_status <"${root}/${slug}/verdict"
      if [ "$v_hash" != "$hash" ] || [ "$v_eval" != "${DOR_SEMANTIC_EVALUATOR:-}" ]; then
        echo stale
        return 0
      fi
    done < <(planner_ticketgen_slugs "$specs_dir")
    echo blocked
    ;;
  *) echo running ;;
  esac
}

# planner_draft_readiness_blocked_findings <INIT>
# "<slug>\t<CODE>\t<quote>" per fail line of the latest gate run.
planner_draft_readiness_blocked_findings() {
  _planner_draft_run_lines "$1" | grep '^[^|]*|META|draft-readiness|fail|' | cut -d'|' -f5- |
    while read -r slug code quote; do
      [ "$code" = "" ] && continue
      printf '%s\t%s\t%s\n' "$slug" "$code" "$quote"
    done
}
