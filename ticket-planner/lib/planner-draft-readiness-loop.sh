#!/usr/bin/env bash
# planner-draft-readiness-loop.sh — the bounded auto-revise loop of the draft
# readiness gate (openspec change planner-draft-readiness, slice S3b: design
# D8, D11, D12, D14). planner-draft-readiness-gate.sh sources this file and
# calls it from its next / apply / gate functions; SKILL.md is unchanged (the
# step 1e spawn loop runs `revise` lines like any other kind).
#
# One loop iteration (D8):
#   1. every stale draft is evaluated (scan + audit, cached by body hash);
#   2. each spec with a revisable blocker (planner_draft_revise_classify),
#      revision budget left and no `unchanged` revision on its current spec
#      gets one ticket-planner:draft-revise-agent spawn — even when another
#      spec has a non-revisable blocker;
#   3. the round's results go through S3a's guards (finish / fail); applied
#      specs trigger a Crosscheck re-run, and a Crosscheck regression reverts
#      every spec applied in that round (D12);
#   4. back to 1: only drafts whose body changed are re-evaluated.
# When no spawn is left, planner_draft_readiness_gate runs the end-of-loop
# demotion (_pdl_converge, D11) and halts on whatever still blocks.
#
# Run-level halts (written to artifacts/draft-readiness/halt, reported by the
# gate as `(run) <CODE>`): SPAWN_BUDGET (the next spawn list would exceed
# PLANNER_DRAFT_SPAWN_BUDGET), CROSSCHECK_BLOCKED (Crosscheck still blocks
# after the round was reverted), DEMOTE_CEILING (too many specs ended with a
# reverted/failed demotion).
#
# Files under artifacts/draft-readiness/ added by this slice:
#   (outside the workspace, _pdl_round_file) round — an open revise round:
#                  "snap <name>", then one "<slug> <N> <spawned> <pending>"
#                  line per spec, and "settled" once every status file exists
#   spawns         "<n> <spec-set-hash>": draft-stage spawns since the spec
#                  set last changed between gate runs (D8)
#   halt           "<CODE> <detail>" — run-level halt of the current run
#   <slug>/lineage.json, lineage.prev.json   draft lineage (D11)
#   <slug>/revise-prompt.r<N>.txt            the revise agent's prompt
#
# Env: PLANNER_DRAFT_REVISE_MAX_ROUNDS (default 2, 0 = the halt-only gate),
# PLANNER_DRAFT_SPAWN_BUDGET (default 8 x spec count),
# PLANNER_DRAFT_DEMOTE_CEILING (default 0.5).
#
# Sourceable library — no set -euo pipefail.

_PLANNER_DRAFT_LOOP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f planner_draft_revise_finish >/dev/null 2>&1; then
  # shellcheck source=planner-draft-revise.sh
  source "${_PLANNER_DRAFT_LOOP_LIB_DIR}/planner-draft-revise.sh"
fi
if ! declare -f planner_semantic_demote >/dev/null 2>&1; then
  # shellcheck source=planner-refinement.sh
  source "${_PLANNER_DRAFT_LOOP_LIB_DIR}/planner-refinement.sh"
fi

# ── Config (validated at gate start) ──────────────────────────────────────

# planner_draft_readiness_config_check — rc 1 with a message on a bad value.
planner_draft_readiness_config_check() {
  local m="${PLANNER_DRAFT_REVISE_MAX_ROUNDS-2}" b="${PLANNER_DRAFT_SPAWN_BUDGET-}" c="${PLANNER_DRAFT_DEMOTE_CEILING-0.5}"
  [[ "$m" =~ ^[0-9]+$ ]] || {
    echo "planner-draft-readiness: PLANNER_DRAFT_REVISE_MAX_ROUNDS must be a non-negative integer, got '$m'" >&2
    return 1
  }
  [ -z "$b" ] || [[ "$b" =~ ^[1-9][0-9]*$ ]] || {
    echo "planner-draft-readiness: PLANNER_DRAFT_SPAWN_BUDGET must be a positive integer, got '$b'" >&2
    return 1
  }
  [[ "$c" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || {
    echo "planner-draft-readiness: PLANNER_DRAFT_DEMOTE_CEILING must be a number from 0 to 1, got '$c'" >&2
    return 1
  }
}

# Revision rounds per spec; an invalid value reads as 0 (halt-only) so a
# caller that skipped the start check can never loop.
_pdl_max_rounds() {
  local m="${PLANNER_DRAFT_REVISE_MAX_ROUNDS-2}"
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  printf '%s' "$m"
}

_pdl_budget() {
  local b="${PLANNER_DRAFT_SPAWN_BUDGET-}" n specs_dir
  if [[ "$b" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$b"
    return 0
  fi
  specs_dir=$(planner_ticketgen_specs_dir "$1") || return 1
  n=$(planner_ticketgen_slugs "$specs_dir" | grep -c .)
  printf '%s' $((8 * n))
}

# ── Small helpers ─────────────────────────────────────────────────────────

_pdl_root() { planner_draft_readiness_root "$1"; }

# Atomic write of stdin to <file>; ledgered when a round snapshot is named.
_pdl_write() {
  local init="$1" snap="$2" f="$3"
  if [ -n "$snap" ]; then
    _pdrv_owned_write "$init" "$snap" "$f"
  else
    _pdrv_write "$f"
  fi
}

# A state.log line, ledgered while a round is open.
_pdl_log() {
  local init="$1" snap="$2"
  shift 2
  if [ -n "$snap" ]; then
    planner_draft_revise_log "$init" "$snap" "$@"
  else
    planner_state_write "$init" "$@"
  fi
}

# The open revise round's plan. It lives OUTSIDE the initiative workspace,
# next to S3a's snapshots (PLANNER_DRAFT_SNAPSHOT_ROOT, mode 0700): the
# revise agent can Write any workspace path, so a plan it could edit (rows
# dropped, a forged `settled`) would let it skip finish and the guards. A
# `round` file an agent writes into the workspace is just an out-of-scope
# edit. Prints the path; creates the directory.
_pdl_round_file() {
  local d
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "planner-draft-readiness: invalid initiative id" >&2
    return 1
  }
  d="$(_pdrv_snap_root)/$1"
  (umask 077 && mkdir -p "$d") || return 1
  printf '%s/round' "$d"
}

_pdl_round_snap() {
  local f
  f=$(_pdl_round_file "$1") || return 1
  [ -f "$f" ] && awk '$1 == "snap" { print $2; exit }' "$f"
}

# ── Spawn budget (D8) ─────────────────────────────────────────────────────

_pdl_spec_set_hash() { _planner_draft_spec_hashes "$1" | _planner_draft_sha; }

_pdl_spawns() {
  local f n
  f="$(_pdl_root "$1")/spawns"
  n=0
  [ -f "$f" ] && read -r n _ <"$f"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# _pdl_spawns_add <INIT> <k> [<snapshot>]
_pdl_spawns_add() {
  local init="$1" k="$2" snap="${3:-}" f n h=""
  f="$(_pdl_root "$init")/spawns"
  n=$(_pdl_spawns "$init")
  [ -f "$f" ] && read -r _ h <"$f"
  [ -n "$h" ] || h=$(_pdl_spec_set_hash "$init")
  echo "$((n + k)) ${h}" | _pdl_write "$init" "$snap" "$f"
}

# Gate start: the counter carries over only while the spec set is the one
# the last gate run closed on (D8 "earlier gate runs on unchanged specs").
planner_draft_readiness_spawns_begin() {
  local init="$1" f h cur
  f="$(_pdl_root "$init")/spawns"
  cur=$(_pdl_spec_set_hash "$init") || return 1
  h=""
  [ -f "$f" ] && read -r _ h <"$f"
  [ "$h" = "$cur" ] || echo "0 ${cur}" | _pdrv_write "$f"
}

_pdl_spawns_close() {
  local init="$1" f
  f="$(_pdl_root "$init")/spawns"
  echo "$(_pdl_spawns "$init") $(_pdl_spec_set_hash "$init")" | _pdrv_write "$f"
}

# _pdl_budget_ok <INIT> <k> — rc 1 (and the SPAWN_BUDGET halt written) when
# k more spawns would exceed the budget.
_pdl_budget_ok() {
  local init="$1" k="$2" n b
  n=$(_pdl_spawns "$init")
  b=$(_pdl_budget "$init") || return 1
  [ $((n + k)) -le "$b" ] && return 0
  echo "SPAWN_BUDGET next spawn list needs ${k}, ${n}/${b} spent" | _pdrv_write "$(_pdl_root "$init")/halt"
  planner_state_write "$init" "META" "draft-readiness" "warn" "SPAWN_BUDGET spawns=${n}/${b} next=${k}"
  return 1
}

# The per-iteration info line (D14).
_pdl_info() {
  local init="$1" revise="$2" reeval="$3" k=0 d u
  for d in "$(_pdl_root "$init")"/*/; do
    [ -d "$d" ] || continue
    u=$(planner_draft_revise_rounds_used "$init" "$(basename "$d")")
    [ "$u" -gt "$k" ] && k="$u"
  done
  [ "$revise" -gt 0 ] && k=$((k + 1))
  planner_state_write "$init" "META" "draft-readiness" "info" \
    "round=${k} revise=${revise} reevaluate=${reeval} spawns=$(_pdl_spawns "$init")/$(_pdl_budget "$init")"
}

# _pdl_restatus <INIT> <refresh-output> — the same lines with cached/stale
# re-judged against the verdict files (apply may have written some), without
# composing the drafts again.
_pdl_restatus() {
  local init="$1" root slug hash status v_hash v_eval v_status
  root=$(_pdl_root "$init") || return 1
  while IFS=$'\t' read -r slug hash status; do
    [ -n "$slug" ] || continue
    if [ "$status" != "error" ]; then
      v_hash="" v_eval="" v_status=""
      [ -f "${root}/${slug}/verdict" ] && read -r v_hash v_eval v_status <"${root}/${slug}/verdict"
      status=stale
      [ "$v_hash" = "$hash" ] && [ "$v_eval" = "${DOR_SEMANTIC_EVALUATOR:-}" ] && [ -n "$v_status" ] && status=cached
    fi
    printf '%s\t%s\t%s\n' "$slug" "$hash" "$status"
  done <<<"$2"
}

# ── Deterministic pass for re-composed drafts ─────────────────────────────

# _pdl_det_missing <INIT> <refresh-output>: a draft whose body changed lost
# its dor-result.json with its other result files; check it again.
_pdl_det_missing() {
  local init="$1" refresh="$2" root slug hash status
  root=$(_pdl_root "$init") || return 1
  while IFS=$'\t' read -r slug hash status; do
    [ "$status" = "stale" ] || continue
    [ -f "${root}/${slug}/dor-result.json" ] && continue
    _planner_draft_det "$init" "$slug" || return 1
  done <<<"$refresh"
}

# ── Draft evaluation with lineage (D3/D16 parity, D11) ────────────────────

# _pdl_evaluate <tid> <dir> <scan-json> <audit-json>
# Prints {semantic, codes, lineage}: S1's dor_semantic_findings →
# dor_semantic_lineage_from (prior = <dir>/lineage.json; null at
# MAX_ROUNDS=0, so every evaluation is round 1 as in the halt-only gate) →
# dor_semantic_assemble → dor_semantic_blocking_codes. Pure; writes nothing.
_pdl_evaluate() {
  local tid="$1" dir="$2" scan="$3" audit="$4" body hash judged prior="null" built sem codes max
  body=$(cat "${dir}/body.md") || return 1
  hash=$(_dor_body_hash "$body")
  judged=$(dor_semantic_findings "$tid" "$body" "$scan" "$audit") || return 1
  max=$(_pdl_max_rounds)
  if [ "$max" -gt 0 ] && [ -s "${dir}/lineage.json" ]; then
    prior=$(jq -c '.' "${dir}/lineage.json" 2>/dev/null) || prior="null"
  fi
  built=$(DOR_SEMANTIC_MAX_ROUNDS="$max" DOR_SEMANTIC_DRIFT_DEMOTE=true \
    DOR_SEMANTIC_ROUND_RESET_SHARE="${DOR_SEMANTIC_ROUND_RESET_SHARE:-0.5}" \
    dor_semantic_lineage_from "$prior" "$body" "$hash" "$(jq -c '.findings' <<<"$judged")" \
    "$(jq -c '.audit // []' <<<"$audit")" 2>/dev/null) || return 1
  # A security-relevant finding (pdr_security) is never drift-demoted at
  # draft stage: it stays blocking, so a revise round takes it while budget
  # is left; past the budget it is demoted round-limit and reported as a
  # security finding (pass output, warn line, epic summary).
  built=$(jq -c "$(planner_draft_security_def)"' .findings = [(.findings // [])[]
      | if .demoted == "drift" and .verified == true and pdr_security
        then del(.demoted) + {severity: "blocking"} else . end]' <<<"$built") || return 1
  # An audit MISSED entry that matches the security rule is a gap the scan
  # missed: it joins the findings as a blocking one (origin audit-missed), so
  # it takes the security path — the next revise round while budget is left,
  # else a round-limit demotion shown as a security finding.
  local missed_f
  missed_f=$(_pdl_missed_findings "$audit") || return 1
  built=$(jq -c --argjson m "$missed_f" '.findings = ((.findings // []) + $m)' <<<"$built") || return 1
  sem=$(dor_semantic_assemble "$hash" "$(jq -c '.findings' <<<"$built")" \
    "$(jq -c '.unverified_gaps' <<<"$judged")" "$scan" "$audit") || return 1
  codes=$(dor_semantic_blocking_codes "$sem") || return 1
  jq -nc --argjson s "$sem" --argjson c "$codes" --argjson l "$(jq -c '.lineage' <<<"$built")" \
    '{semantic: $s, codes: $c, lineage: $l}'
}

# The one form a MISSED reason is stored and compared in: control
# characters (tabs, newlines, ANSI escapes) become spaces, runs collapse,
# at most 500 characters. Evaluator text, so it never reaches a terminal or
# a prompt raw.
PDL_MISSED_TEXT_DEF=' def pdl_missed_text: tostring | gsub("[[:cntrl:]]"; " ") | gsub(" +"; " ") | sub("^ "; "") | sub(" $"; "") | .[0:500];'

# _pdl_missed_findings <audit-json> — a JSON array: one blocking finding per
# audit MISSED entry ({code, reason}) whose code is a known, blocking,
# non-structural semantic code and whose code/reason match the security rule
# (planner_draft_security_def). Shape: {id: "m-<sha12>", code, dimension,
# severity: "blocking", verified: true, detail: <reason>, origin:
# "audit-missed", lineage: "new"} — no quote (the audit gives none), so it
# never anchors to a unit. Every other MISSED entry stays in `missed` only
# and is reported as an advisory (planner_draft_readiness_missed_report).
_pdl_missed_findings() {
  local audit="$1" known='{}' code structural cand out='[]' id reason
  structural=$(_dor_semantic_structural_codes | jq -R . | jq -sc 'map(select(. != ""))')
  for code in "${!DOR_SEMANTIC_CODES[@]}"; do
    [ "$(_dor_semantic_severity "$code")" = blocking ] || continue
    known=$(jq -c --arg c "$code" --arg d "${DOR_SEMANTIC_CODES[$code]}" '. + {($c): $d}' <<<"$known")
  done
  cand=$(jq -c --argjson k "$known" --argjson st "$structural" "$(planner_draft_security_def)${PDL_MISSED_TEXT_DEF}"'
    [(.missed // [])[] | select(type == "object")
     | {code: (.code // "" | tostring), detail: (.reason // "" | pdl_missed_text)}
     | select($k[.code] != null and (.code as $c | $st | index($c)) == null and .detail != "")
     | select(pdr_security) | . + {dimension: $k[.code]}]' <<<"$audit" 2>/dev/null) || cand='[]'
  # Each candidate stays a JSON object end to end (its reason is stored
  # byte-for-byte, so the advisory report can tell it was converted).
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    code=$(jq -r '.code' <<<"$c")
    reason=$(jq -r '.detail' <<<"$c")
    id="m-$(printf '%s\n%s' "$code" "$(_pdrv_norm "$reason")" | sha256sum | cut -c1-12)"
    out=$(jq -c --arg i "$id" --argjson f "$c" \
      '. + [$f + {id: $i, severity: "blocking", verified: true, origin: "audit-missed", lineage: "new"}]
       | unique_by(.id)' <<<"$out") || return 1
  done < <(jq -c '.[]' <<<"$cand")
  printf '%s\n' "$out"
}

# planner_draft_readiness_missed <INIT> — "<slug>\t<security|advisory>\t<CODE>\t<reason>"
# per audit MISSED entry of every draft with a semantic verdict that did not
# become a finding (_pdl_missed_findings): the scan missed it and nothing
# blocks on it, so it is reported. `security` when it matches the security
# rule (a structural or unknown code is never turned into a finding).
planner_draft_readiness_missed() {
  local init="$1" root d slug
  root=$(_pdl_root "$init") || return 0
  for d in "$root"/*/; do
    [ -s "${d}semantic.json" ] || continue
    slug=$(basename "$d")
    jq -r --arg s "$slug" "$(planner_draft_security_def)${PDL_MISSED_TEXT_DEF}"'
      [(.findings // [])[] | select(.origin == "audit-missed") | .detail] as $f
      | (.missed // [])[] | select(type == "object")
      | {code: (.code // "" | tostring | pdl_missed_text), detail: (.reason // "" | pdl_missed_text)}
      | select(.detail != "" and (.detail as $r | ($f | index($r)) == null))
      | [$s, (if pdr_security then "security" else "advisory" end), .code, .detail] | @tsv' \
      "${d}semantic.json" 2>/dev/null
  done
  return 0
}

# planner_draft_readiness_missed_report <INIT> — the human-readable list, or
# nothing.
planner_draft_readiness_missed_report() {
  local lines slug kind code reason
  lines=$(planner_draft_readiness_missed "$1")
  [ -n "$lines" ] || return 0
  echo "Audit advisories (gaps the scan missed; they do not block):"
  while IFS=$'\t' read -r slug kind code reason; do
    if [ "$kind" = security ]; then
      echo "  ${slug}: Security ${code} — ${reason}"
    else
      echo "  ${slug}: ${code} — ${reason}"
    fi
  done <<<"$lines"
}

# _pdl_lineage_write <dir> <lineage-json>: keeps the previous lineage of a
# different body as lineage.prev.json (the drift rule on revised units).
_pdl_lineage_write() {
  local dir="$1" lin="$2" old_h new_h
  if [ -s "${dir}/lineage.json" ]; then
    old_h=$(jq -r '.body_hash // ""' "${dir}/lineage.json" 2>/dev/null)
    new_h=$(jq -r '.body_hash // ""' <<<"$lin")
    [ "$old_h" != "$new_h" ] && cp -p "${dir}/lineage.json" "${dir}/lineage.prev.json"
  fi
  printf '%s\n' "$lin" | _pdrv_write "${dir}/lineage.json"
}

# Headings passed to the evaluator prompt must look like section names and
# exist in both the last evaluated body and the current one; anything else
# makes the scan a full scan instead of reaching the prompt.
PLANNER_DRAFT_SECTION_NAME_RE='^[A-Za-z][A-Za-z0-9 ()/&,.-]{0,59}$'

# _pdl_changed_sections <dir> — "<h1|h2…>": the headings whose section hash
# differs between the draft's last evaluated body (lineage.json) and the
# current body.md, `#n` repeat suffixes stripped — the scoped-rescan hint
# Refinement passes as --changed-sections (planner-refinement-convergence
# D4). Empty (full scan) at MAX_ROUNDS=0, with no lineage, for another
# evaluator, or when nothing changed.
_pdl_changed_sections() {
  local dir="$1" sec
  [ "$(_pdl_max_rounds)" -gt 0 ] && [ -s "${dir}/lineage.json" ] && [ -f "${dir}/body.md" ] || return 0
  sec=$(_dor_section_hashes "$(cat "${dir}/body.md")" 2>/dev/null) || return 0
  [ -n "$sec" ] || return 0
  jq -r --argjson s "$sec" --arg e "${DOR_SEMANTIC_EVALUATOR:-}" --arg re "$PLANNER_DRAFT_SECTION_NAME_RE" '
    if (.evaluator // "") != $e then ""
    else (.section_hashes // null) as $o
      | if ($o | type) != "object" then ""
        else [(($o | keys) + ($s | keys) | unique)[] | select($o[.] != $s[.])] as $chg
             # A heading added or removed since the last evaluation is not
             # named (full scan): only headings both bodies share, which the
             # revise agent cannot create, reach the prompt.
             | if all($chg[]; $o[.] != null and $s[.] != null) and all($chg[]; sub("#[0-9]+$"; "") | test($re))
               then [$chg[] | sub("#[0-9]+$"; "")] | unique | join("|") else "" end end end' "${dir}/lineage.json" 2>/dev/null || true
}

# ── Revision regression (a new structural finding) ────────────────────────
#
# A revision may add a criterion that contradicts a section it may not edit
# (e.g. "an empty secret counts as unset" against a Technical Context
# `?? 'default'` fallback). The evaluator then raises a structural code
# (CONTRADICTORY_REQUIREMENTS, …) that is never revisable and never
# demoted, so the gate would halt on a gap the revision itself created. The
# first evaluation after an applied revision is therefore compared with the
# evaluation the round started from: a verified structural code that was not
# there before reverts that spec's revision (`reverted:REVISION_REGRESSION`,
# reason class `reverted`) and restores the pre-round verdict, instead of
# halting.
#
# The pre-round copy (spec, draft body, lineage, result files) lives OUTSIDE
# the workspace, next to the round plan (mode 0700): every agent of the gate
# can Write any workspace path. The spec it restores is copied before the
# round's snapshot and is never read back from the workspace; the evaluation
# files are copied from the workspace (the same trust the gate already gives
# them), so forging them can at most suppress a revert (the gate then halts,
# fail-closed) or restore a verdict the gate would have trusted anyway. A
# revert also needs the current spec to be the one the revision produced
# (`post.sha`, written by the orchestrator at settle), so a hand edit made
# after an interrupted run is never undone.

PLANNER_DRAFT_EVAL_SAVE_FILES="body.md lineage.json lineage.prev.json ${PLANNER_DRAFT_RESULT_FILES}"

# _pdl_eval_dir <INIT> <slug> <N> — the pre-round copy for round N.
_pdl_eval_dir() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$3" =~ ^[1-9][0-9]*$ ]] || {
    echo "planner-draft-readiness: invalid initiative, slug or round" >&2
    return 1
  }
  printf '%s/%s/eval/%s.r%s' "$(_pdrv_snap_root)" "$1" "$2" "$3"
}

# _pdl_eval_save <INIT> <slug> <N> — before round N's snapshot: the spec and
# the draft's evaluation as they are now. Kept when present (a crash resume
# must not overwrite it with a spec the agent may already have edited).
_pdl_eval_save() {
  local init="$1" slug="$2" n="$3" e dir spec f
  e=$(_pdl_eval_dir "$init" "$slug" "$n") || return 1
  [ -f "${e}/spec.md" ] && return 0
  dir="$(_pdl_root "$init")/${slug}"
  spec=$(_pdrv_spec "$init" "$slug") || return 1
  rm -rf "${e}.tmp"
  (umask 077 && mkdir -p "${e}.tmp") || return 1
  for f in $PLANNER_DRAFT_EVAL_SAVE_FILES; do
    if [ -f "${dir}/${f}" ] && [ ! -L "${dir}/${f}" ]; then
      cp -p "${dir}/${f}" "${e}.tmp/${f}" || return 1
    fi
  done
  cp -p "$spec" "${e}.tmp/spec.md" || return 1
  rm -rf "$e"
  mv -f "${e}.tmp" "$e"
}

# _pdl_eval_drop <INIT> — the gate's close: every pre-round copy goes (a
# copy is only read by the first evaluation after its round, which the loop
# has run by then).
_pdl_eval_drop() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  rm -rf "$(_pdrv_snap_root)/$1/eval"
}

# _pdl_regression <INIT> <slug> <eval-json> — prints the new structural codes
# (space-separated, rc 0) when <eval-json> is the first evaluation after the
# spec's latest revision, that revision was applied, and it raised a verified
# blocking structural code the pre-round evaluation did not have. rc 1
# otherwise (no revision, not applied, no pre-round copy, nothing new).
_pdl_regression() {
  local init="$1" slug="$2" eval_json="$3" dir n e structural new
  dir="$(_pdl_root "$init")/${slug}"
  n=$(planner_draft_revise_rounds_used "$init" "$slug") || return 1
  [ "$n" -gt 0 ] || return 1
  [ "$(cat "${dir}/revise.r${n}.status" 2>/dev/null)" = "applied" ] || return 1
  e=$(_pdl_eval_dir "$init" "$slug" "$n") || return 1
  [ -f "${e}/spec.md" ] && [ -s "${e}/semantic.json" ] && [ -f "${e}/body.md" ] && [ -s "${e}/post.sha" ] || return 1
  # Only the spec the revision produced: a later hand edit (e.g. after an
  # interrupted run) is never undone by a revert.
  [ "$(sha256sum <"$(_pdrv_spec "$init" "$slug")" | cut -c1-64)" = "$(head -1 "${e}/post.sha")" ] || return 1
  # The pre-round body is not the one just judged: this is the evaluation of
  # the revised draft, not a re-judgement of the old one.
  [ "$(_dor_body_hash "$(cat "${e}/body.md")")" != "$(jq -r '.semantic.body_hash // ""' <<<"$eval_json")" ] || return 1
  structural=$(_dor_semantic_structural_codes | jq -R . | jq -sc 'map(select(. != ""))')
  # Only a finding on a unit the revision changed counts (evaluator noise on
  # untouched text is not the revision's doing), when the pre-round lineage
  # names its units.
  local old_units='null'
  [ -s "${e}/lineage.json" ] && old_units=$(jq -c '.units // null' "${e}/lineage.json" 2>/dev/null) || true
  [ -n "$old_units" ] || old_units='null'
  new=$(jq -r --argjson st "$structural" --argjson ou "$old_units" --slurpfile old "${e}/semantic.json" '
    ([($old[0].findings // [])[] | select(.verified == true) | .code]) as $was
    | (.lineage.units // {}) as $nu
    | (if $ou == null then null
       else [(($ou | keys) + ($nu | keys)) | unique[] | select($ou[.] != $nu[.])] end) as $chg
    | [(.semantic.findings // [])[]
       | select(.verified == true and .severity == "blocking")
       | select($chg == null or ([(.units // [])[] | select(. as $u | ($chg | index($u)) != null)] | length > 0))
       | .code | select(. as $c | ($st | index($c)) != null and ($was | index($c)) == null)]
    | unique | join(" ")' <<<"$eval_json" 2>/dev/null) || return 1
  [ -n "$new" ] || return 1
  printf '%s\n' "$new"
}

# _pdl_revert_regression <INIT> <slug> <codes> — restores the spec and the
# pre-round evaluation from the copy, marks the round
# `reverted:REVISION_REGRESSION`, re-runs Crosscheck (CROSSCHECK_BLOCKED halt
# when it now blocks) and flags the run so the next spawn list recomposes.
_pdl_revert_regression() {
  local init="$1" slug="$2" codes="$3" root dir n e spec f body vhash
  root=$(_pdl_root "$init")
  dir="${root}/${slug}"
  n=$(planner_draft_revise_rounds_used "$init" "$slug") || return 1
  e=$(_pdl_eval_dir "$init" "$slug" "$n") || return 1
  spec=$(_pdrv_spec "$init" "$slug") || return 1
  cp -p "${e}/spec.md" "${spec}.tmp.$$" && mv -f "${spec}.tmp.$$" "$spec" || return 1
  for f in $PLANNER_DRAFT_EVAL_SAVE_FILES; do
    rm -f "${dir:?}/${f}"
  done
  # Restore the pre-round verdict only when it is for the draft the restored
  # spec composes to; otherwise the draft is simply re-evaluated.
  vhash=""
  [ -f "${e}/verdict" ] && read -r vhash _ _ <"${e}/verdict"
  if body=$(planner_draft_readiness_compose "$init" "$slug" 2>/dev/null) &&
    [ -n "$vhash" ] && [ "$(_dor_body_hash "$body")" = "$vhash" ]; then
    for f in $PLANNER_DRAFT_EVAL_SAVE_FILES; do
      [ "$f" = verdict ] && continue
      [ -f "${e}/${f}" ] && cp -p "${e}/${f}" "${dir}/${f}"
    done
    cp -p "${e}/verdict" "${dir}/verdict"
  elif [ -f "${e}/lineage.json" ]; then
    cp -p "${e}/lineage.json" "${dir}/lineage.json"
  fi
  echo "reverted:REVISION_REGRESSION" | _pdrv_write "${dir}/revise.r${n}.status"
  planner_state_write "$init" "META" "draft-revise" "fail" "${slug} round=${n} REVISION_REGRESSION \"${codes}\""
  if ! planner_crosscheck_run "$init" >/dev/null 2>&1; then
    echo "CROSSCHECK_BLOCKED $(_pdl_crosscheck_codes "$init")" | _pdrv_write "${root}/halt"
  fi
  : >"${root}/.recompose"
}

# ── Revise round: plan and spawn (D8 step 3) ──────────────────────────────

# Is <slug> due a revision? Prints its round number N.
_pdl_due() {
  local init="$1" slug="$2" hash="$3" max="$4" root dir v_hash v_eval v_status cls used spec
  root=$(_pdl_root "$init")
  dir="${root}/${slug}"
  v_hash="" v_eval="" v_status=""
  [ -f "${dir}/verdict" ] && read -r v_hash v_eval v_status <"${dir}/verdict"
  [ "$v_hash" = "$hash" ] && [ "$v_eval" = "${DOR_SEMANTIC_EVALUATOR:-}" ] && [ "$v_status" = "blocked" ] || return 1
  [ -f "${dir}/semantic.json" ] || return 1
  cls=$(planner_draft_revise_classify "${dir}/semantic.json" "${dir}/dor-result.json") || return 1
  [ "$(jq '.revisable | length' <<<"$cls")" -gt 0 ] || return 1
  used=$(planner_draft_revise_rounds_used "$init" "$slug")
  [ "$used" -lt "$max" ] || return 1
  if [ "$used" -gt 0 ]; then
    spec=$(_pdrv_spec "$init" "$slug")
    # No second revision of a spec the last one left unchanged (D8 step 3).
    if [ "$(cat "${dir}/revise.r${used}.status" 2>/dev/null)" = "unchanged" ] &&
      cmp -s "${dir}/spec.r$((used - 1)).md" "$spec"; then
      return 1
    fi
  fi
  printf '%s' "$((used + 1))"
}

# The findings given to the agent: the revisable ones, with the evaluator's
# quote and reason for semantic findings.
_pdl_round_findings() {
  local dir="$1" cls
  cls=$(planner_draft_revise_classify "${dir}/semantic.json" "${dir}/dor-result.json") || return 1
  jq -c --argjson cls "$cls" '
    . as $s
    | [$cls.revisable[] as $r
       | if $r.kind == "semantic" then
           ($s.findings // [])[] | select(.id == $r.id)
           | {id, kind: "semantic", code, severity, quote, quote_b, detail, unit, units}
         else {id: $r.id, kind: "deterministic", code: $r.code} end]' "${dir}/semantic.json"
}

# _pdl_revise_next <INIT> <refresh-output> — prints the revise spawn list, or nothing (no
# spec due, or the SPAWN_BUDGET halt). Opens the round: findings, prompts,
# marker and .pending are written BEFORE the snapshot; the start lines after
# it go through the ledger (S3a's rule).
_pdl_revise_next() {
  local init="$1" refresh="$2" root max slug hash status n
  max=$(_pdl_max_rounds)
  [ "$max" -gt 0 ] || return 0
  root=$(_pdl_root "$init") || return 1
  local -a plan=()
  while IFS=$'\t' read -r slug hash status; do
    [ -n "$slug" ] && [ "$status" != "error" ] || continue
    n=$(_pdl_due "$init" "$slug" "$hash" "$max") || continue
    plan+=("${slug} ${n}")
  done <<<"$refresh"
  [ "${#plan[@]}" -gt 0 ] || return 0
  _pdl_budget_ok "$init" "${#plan[@]}" || return 0

  local item dir csv="" marker out="" snap
  snap="round-$(date +%s)-$$"
  marker="snap ${snap}"$'\n'
  for item in "${plan[@]}"; do
    slug="${item% *}"
    n="${item#* }"
    dir="${root}/${slug}"
    planner_draft_revise_prepare "$init" "$slug" "$n" "$(_pdl_round_findings "$dir")" || return 1
    _pdl_eval_save "$init" "$slug" "$n" || return 1
    planner_prompt_spec_revise "$init" "$slug" "${dir}/findings.r${n}.json" | _pdrv_write "${dir}/revise-prompt.r${n}.txt" || return 1
    csv+="${csv:+,}${slug}"
    marker+="${slug} ${n} 1 1"$'\n'
    out+="${slug}"$'\t'"revise"$'\t'"${PLANNER_DRAFT_REVISE_AGENT}"$'\t'"${dir}/revise-prompt.r${n}.txt"$'\t'"${dir}/revise.r${n}.md"$'\n'
  done
  _pdl_spawns_add "$init" "${#plan[@]}"
  _pdl_info "$init" "${#plan[@]}" 0
  printf '%s' "$marker" | _pdrv_write "$(_pdl_round_file "$init")"
  printf '%s' "$out" | _pdrv_write "${root}/.pending"
  if ! planner_draft_revise_snapshot "$init" "$snap"; then
    rm -f "$(_pdl_round_file "$init")" "${root}/.pending"
    return 1
  fi
  for item in "${plan[@]}"; do
    slug="${item% *}"
    n="${item#* }"
    _pdl_log "$init" "$snap" "META" "draft-revise" "start" \
      "${slug} round=${n} findings=$(jq 'length' "${root}/${slug}/findings.r${n}.json")"
  done
  printf '%s' "$out"
}

# _pdl_round_retry_list <INIT> — after apply left the round open: one more
# spawn for every spec whose agent wrote no result (the one retry, D9).
_pdl_round_retry_list() {
  local init="$1" root snap slug n spawned pending dir out="" marker k=0
  root=$(_pdl_root "$init")
  snap=$(_pdl_round_snap "$init")
  marker="snap ${snap}"$'\n'
  while read -r slug n spawned pending; do
    [ "$slug" = "snap" ] && continue
    [ -n "$slug" ] || continue
    dir="${root}/${slug}"
    if [ ! -f "${dir}/revise.r${n}.md" ] && [ "$pending" = 0 ] && [ "$spawned" -lt "$PLANNER_DRAFT_MAX_ATTEMPTS" ]; then
      spawned=$((spawned + 1))
      pending=1
      k=$((k + 1))
      out+="${slug}"$'\t'"revise"$'\t'"${PLANNER_DRAFT_REVISE_AGENT}"$'\t'"${dir}/revise-prompt.r${n}.txt"$'\t'"${dir}/revise.r${n}.md"$'\n'
    fi
    marker+="${slug} ${n} ${spawned} ${pending}"$'\n'
  done <"$(_pdl_round_file "$init")"
  if [ -z "$out" ]; then
    echo "planner-draft-readiness: open revise round with nothing to spawn" >&2
    return 1
  fi
  # Retries are counted, never refused: a half-finished round cannot halt.
  _pdl_spawns_add "$init" "$k" "$snap"
  printf '%s' "$marker" | _pdrv_write "$(_pdl_round_file "$init")"
  printf '%s' "$out" | _pdl_write "$init" "$snap" "${root}/.pending"
  printf '%s' "$out"
}

# ── Revise round: settle (D9 retry, D10 guards, D12 Crosscheck) ───────────

# _pdl_round_apply <INIT> — rc 0; the round stays open only while a spec
# waits for its retry. Finishes run only once every spec has a result or has
# used its attempts, so no agent can edit a spec after its guards ran.
_pdl_round_apply() {
  local init="$1" root snap slug n spawned pending dir csv="" wait=0 marker
  root=$(_pdl_root "$init")
  snap=$(_pdl_round_snap "$init")
  [ -n "$snap" ] || {
    echo "planner-draft-readiness: revise round marker without a snapshot" >&2
    return 1
  }
  local -a rows=()
  while read -r slug n spawned pending; do
    [ -n "$slug" ] && [ "$slug" != "snap" ] && [ "$slug" != "settled" ] || continue
    rows+=("${slug} ${n} ${spawned} ${pending}")
    csv+="${csv:+,}${slug}"
  done <"$(_pdl_round_file "$init")"

  if ! grep -qx settled "$(_pdl_round_file "$init")"; then
    marker="snap ${snap}"$'\n'
    local row
    for row in "${rows[@]}"; do
      read -r slug n spawned pending <<<"$row"
      dir="${root}/${slug}"
      if [ ! -f "${dir}/revise.r${n}.md" ] && ! _pdrv_status_trusted "$init" "$snap" "${dir}/revise.r${n}.status"; then
        pending=0
        [ "$spawned" -lt "$PLANNER_DRAFT_MAX_ATTEMPTS" ] && wait=1
      fi
      marker+="${slug} ${n} ${spawned} ${pending}"$'\n'
    done
    if [ "$wait" -eq 1 ]; then
      printf '%s' "$marker" | _pdrv_write "$(_pdl_round_file "$init")"
      return 0
    fi
    for row in "${rows[@]}"; do
      read -r slug n spawned pending <<<"$row"
      dir="${root}/${slug}"
      local rc=0
      planner_draft_revise_finish "$init" "$slug" "$n" "$snap" "$csv" >/dev/null || rc=$?
      if [ "$rc" -eq 3 ]; then
        planner_draft_revise_fail "$init" "$slug" "$n" "$snap" AGENT_FAILED "$csv" >/dev/null || return 1
      elif [ "$rc" -ne 0 ]; then
        return 1
      fi
    done
    echo settled >>"$(_pdl_round_file "$init")"
  fi

  planner_draft_revise_snapshot_drop "$init" "$snap"
  rm -f "${root}/.pending"

  # D12: a round that applied any spec re-runs Crosscheck.
  local -a applied=()
  local row
  for row in "${rows[@]}"; do
    read -r slug n _ _ <<<"$row"
    [ "$(cat "${root}/${slug}/revise.r${n}.status" 2>/dev/null)" = "applied" ] && applied+=("${slug} ${n}")
  done
  # The spec each applied revision produced, for the regression check.
  local e
  for row in "${applied[@]}"; do
    read -r slug n <<<"$row"
    e=$(_pdl_eval_dir "$init" "$slug" "$n") || continue
    [ -d "$e" ] && sha256sum <"$(_pdrv_spec "$init" "$slug")" | cut -c1-64 >"${e}/post.sha"
  done
  if [ "${#applied[@]}" -gt 0 ] && ! planner_crosscheck_run "$init" >/dev/null 2>&1; then
    local codes spec
    codes=$(_pdl_crosscheck_codes "$init")
    for row in "${applied[@]}"; do
      read -r slug n <<<"$row"
      dir="${root}/${slug}"
      spec=$(_pdrv_spec "$init" "$slug")
      # The pre-round spec from outside the workspace when it exists.
      local pre="${dir}/spec.r$((n - 1)).md" ec
      ec=$(_pdl_eval_dir "$init" "$slug" "$n" 2>/dev/null) && [ -f "${ec}/spec.md" ] && pre="${ec}/spec.md"
      cp -p "$pre" "${spec}.tmp.$$" && mv -f "${spec}.tmp.$$" "$spec"
      echo "reverted:CROSSCHECK_REGRESSION" | _pdrv_write "${dir}/revise.r${n}.status"
      planner_state_write "$init" "META" "draft-revise" "fail" "${slug} round=${n} CROSSCHECK_REGRESSION \"${codes}\""
    done
    if ! planner_crosscheck_run "$init" >/dev/null 2>&1; then
      echo "CROSSCHECK_BLOCKED $(_pdl_crosscheck_codes "$init")" | _pdrv_write "${root}/halt"
    fi
  fi
  rm -f "$(_pdl_round_file "$init")"
  return 0
}

# Blocking Crosscheck codes of its latest attempt, space-separated.
_pdl_crosscheck_codes() {
  local log start
  log=$(planner_state_log "$1") || return 0
  start=$(grep -n '^[^|]*|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  [ -n "$start" ] || return 0
  tail -n "+${start}" "$log" | grep '^[^|]*|META|crosscheck|fail|' | cut -d'|' -f5 |
    awk '{print $1}' | sort -u | paste -sd' ' -
}

# ── End of loop (D11) ─────────────────────────────────────────────────────

# _pdl_reason_map <INIT> <slug> — {"<finding-id>": "<class>"}, per finding.
# A finding given to a round takes that round's class: `assumed` (ASSUMED in
# an applied round — the guards checked its Scope row), `rebutted` (REBUTTED
# or unaddressed, or any round left unchanged), `revised` (applied),
# `reverted` (reverted by a guard or Crosscheck), `failed` (agent failed);
# across rounds the highest of assumed > rebutted > revised > reverted >
# failed wins. A finding no round was given is `revised` when it sits on a
# unit the last body change made by an applied revision touched (a gap the
# revision introduced, or the re-phrased form of the one it fixed), else
# `untouched` — the evaluator raised it on text no revision changed.
_pdl_reason_map() {
  local init="$1" slug="$2" dir f st n ff disp cls given='{}' any_applied=0 chg='[]'
  local none='{"resolved":[],"assumed":[],"rebutted":[],"unaddressed":[]}'
  dir="$(_pdl_root "$init")/${slug}"
  for f in "${dir}"/revise.r*.status; do
    [ -f "$f" ] || continue
    st=$(cat "$f")
    n="${f##*/revise.r}"
    n="${n%.status}"
    ff="${dir}/findings.r${n}.json"
    [ -f "$ff" ] || continue
    case "$st" in
    applied)
      cls=revised
      any_applied=1
      ;;
    unchanged) cls=rebutted ;;
    reverted:*) cls=reverted ;;
    failed:*) cls=failed ;;
    *) continue ;;
    esac
    disp="$none"
    if [ "$st" = "applied" ] || [ "$st" = "unchanged" ]; then
      # Only the revise file the guards saw (hash recorded at finish).
      disp=$(planner_draft_revise_dispositions_trusted "$dir" "$n" 2>/dev/null) || disp="$none"
    fi
    given=$(jq -c --slurpfile fs "$ff" --argjson d "$disp" --arg c "$cls" --arg st "$st" '
      def rank: {"failed": 1, "reverted": 2, "revised": 3, "rebutted": 4, "assumed": 5}[.] // 0;
      ([($d.rebutted // [])[].id] + ($d.unaddressed // [])) as $reb
      | ([($d.assumed // [])[].id]) as $asm
      | reduce ($fs[0][] | (.id // .code)) as $i (.;
          (if $st == "applied" and ($asm | index($i)) != null then "assumed"
           elif ($reb | index($i)) != null then "rebutted"
           else $c end) as $k
          | if ((.[$i] // "") | rank) < ($k | rank) then .[$i] = $k else . end)' <<<"$given") || return 1
  done
  if [ "$any_applied" -eq 1 ] && [ -s "${dir}/lineage.prev.json" ] && [ -s "${dir}/lineage.json" ]; then
    chg=$(jq -nc --slurpfile p "${dir}/lineage.prev.json" --slurpfile c "${dir}/lineage.json" '
      ($p[0].units // {}) as $pu | ($c[0].units // {}) as $cu
      | [(($pu | keys) + ($cu | keys)) | unique[] | select($pu[.] != $cu[.])]') || chg='[]'
  fi
  jq -c --argjson g "$given" --argjson chg "$chg" '
    reduce (.findings // [])[] as $f ({};
      .[$f.id] = ($g[$f.id] // (if ([($f.units // [])[] | select(. as $u | ($chg | index($u)) != null)] | length) > 0
                                then "revised" else "untouched" end)))' "${dir}/semantic.json"
}

# _pdl_drift_ids <dir> — ids of `new` findings on a unit the last applied
# revision changed whose code matches a finding that revision addressed on
# the same unit (D11 drift on revised units). Security findings excluded.
_pdl_drift_ids() {
  local dir="$1" n=0 f k
  for f in "${dir}"/revise.r*.status; do
    [ "$(cat "$f" 2>/dev/null)" = "applied" ] || continue
    k="${f##*/revise.r}"
    k="${k%.status}"
    [ "$k" -gt "$n" ] && n="$k"
  done
  [ "$n" -gt 0 ] && [ -s "${dir}/lineage.prev.json" ] && [ -s "${dir}/lineage.json" ] || return 0
  jq -r --slurpfile p "${dir}/lineage.prev.json" --slurpfile c "${dir}/lineage.json" \
    --slurpfile a "${dir}/findings.r${n}.json" "$(planner_draft_security_def)"'
    ($p[0].units // {}) as $pu | ($c[0].units // {}) as $cu
    | ([(($pu | keys) + ($cu | keys)) | unique[] | select($pu[.] != $cu[.])]) as $chg
    | [(.findings // [])[]
       | select(.verified == true and .lineage == "new"
                and (.severity == "blocking" or (.demoted == "round-limit" and .demote_reason == null)))
       # Never relabel a security finding as drift (evaluator noise).
       | select(pdr_security | not)
       | select([(.units // [])[] | select(. as $u | ($chg | index($u)) != null)] | length > 0)
       | . as $f
       # Unit keys carry a content hash, so a rewritten criterion is a new
       # key: "same unit" is the identical key, or the addressed unit gone
       # and the finding on a unit new in the same section.
       | def same($au): ($f.units // []) | any(. as $u | $au == $u
           or (($cu[$au] == null) and ($pu[$u] == null) and (($chg | index($u)) != null)
               and (($au | split("/")[0]) == ($u | split("/")[0]))));
       select([$a[0][] | select(.kind == "semantic" and .code == $f.code and .unit != null and same(.unit))] | length > 0)
       | .id] | join(",")' "${dir}/semantic.json"
}

# _pdl_converge <INIT> <refresh-output> — end-of-loop demotion for every spec that was
# revised at least once (D11). Prints the number of specs that ended with a
# reverted/failed demotion. Writes semantic.json and re-judges the verdict.
_pdl_converge() {
  local init="$1" refresh="$2" root slug hash status dir v_hash v_eval v_status map drift sem new structural ceil_hits=0
  root=$(_pdl_root "$init")
  structural=$(_dor_semantic_structural_codes | jq -R . | jq -sc 'map(select(. != ""))')
  while IFS=$'\t' read -r slug hash status; do
    [ -n "$slug" ] && [ "$status" != "error" ] || continue
    dir="${root}/${slug}"
    v_hash="" v_eval="" v_status=""
    [ -f "${dir}/verdict" ] && read -r v_hash v_eval v_status <"${dir}/verdict"
    [ "$v_hash" = "$hash" ] && [ "$v_eval" = "${DOR_SEMANTIC_EVALUATOR:-}" ] || continue
    [ "$v_status" = "unavailable" ] && continue
    [ -s "${dir}/semantic.json" ] || continue
    [ "$(planner_draft_revise_rounds_used "$init" "$slug")" -gt 0 ] || continue

    map=$(_pdl_reason_map "$init" "$slug") || continue
    sem=$(cat "${dir}/semantic.json")
    drift=$(_pdl_drift_ids "$dir")
    if [ -n "$drift" ]; then
      sem=$(planner_semantic_demote "$sem" drift draft-revise "$drift" "$map") || continue
      # Already demoted round-limit at evaluation: relabel as drift.
      sem=$(jq -c --arg ids "$drift" --argjson st "$structural" '($ids | split(",")) as $d
        | .findings = [(.findings // [])[] | if ((.id as $i | $d | index($i)) != null) and .demoted == "round-limit"
            and ((.code as $c | $st | index($c)) == null) then . + {demoted: "drift", demoted_by: "draft-revise"} else . end]' <<<"$sem") || continue
    fi
    sem=$(planner_semantic_demote "$sem" round-limit draft-revise "" "$map") || continue
    # Findings the lineage already demoted at evaluation get their class too.
    sem=$(jq -c --argjson m "$map" '.findings = [(.findings // [])[]
        | if (.demoted == "round-limit" or .demoted == "drift") and .demote_reason == null and $m[.id] != null
          then . + {demote_reason: $m[.id]} else . end]' <<<"$sem") || continue
    new=$(jq -c . <<<"$sem") || continue
    [ -n "$new" ] || continue
    if [ "$new" != "$(jq -c . "${dir}/semantic.json")" ]; then
      printf '%s\n' "$new" | _pdrv_write "${dir}/semantic.json"
    fi
    local verdict=ready
    if [ "$(dor_semantic_blocking_codes "$new" | jq 'length')" -gt 0 ] ||
      jq -e '(.missing // []) | length > 0' "${dir}/dor-result.json" >/dev/null 2>&1; then
      verdict=blocked
    fi
    [ "$verdict" = "$v_status" ] ||
      planner_draft_readiness_verdict_write "$init" "$slug" "$hash" "${DOR_SEMANTIC_EVALUATOR:-}" "$verdict"
    local code dem cls id
    while IFS=$'\t' read -r code dem cls id; do
      [ -n "$code" ] || continue
      planner_state_write "$init" "META" "draft-readiness" "info" "${slug} DEMOTED ${code} ${dem} ${cls} ${id}"
    done < <(jq -r '(.findings // [])[] | select((.demoted == "round-limit" or .demoted == "drift") and .demote_reason != null)
        | [.code, .demoted, .demote_reason, .id] | @tsv' <<<"$new")
    jq -e '[(.findings // [])[] | select(.demote_reason == "reverted" or .demote_reason == "failed")] | length > 0' \
      <<<"$new" >/dev/null && ceil_hits=$((ceil_hits + 1))
  done <<<"$refresh"
  echo "$ceil_hits"
}

# planner_draft_readiness_security <INIT> — "<slug>\t<CODE>\t<id>\t<quote>"
# per security-relevant finding (pdr_security) that the draft stage demoted
# to advisory, across every spec with a current verdict. These pass the gate
# (the loop stays hands-free) but are never silent: the gate logs a warn
# line per finding and prints them on pass, the halt report and the epic
# summary list them, and Refinement carries them like any demotion.
planner_draft_readiness_security() {
  local init="$1" root d slug v_hash v_eval v_status
  root=$(_pdl_root "$init") || return 0
  for d in "$root"/*/; do
    [ -s "${d}semantic.json" ] || continue
    slug=$(basename "$d")
    jq -r --arg s "$slug" "$(planner_draft_security_def)"' (.findings // [])[]
      | select(.verified == true and .demoted != null and pdr_security)
      | [$s, .code, (.id // ""), ((.quote // .detail // "") | gsub("[\t\r\n]"; " "))] | @tsv' "${d}semantic.json" 2>/dev/null
  done
  return 0
}

# planner_draft_readiness_security_report <INIT> — the human-readable list
# (stdout), or nothing.
planner_draft_readiness_security_report() {
  local lines slug code id quote
  lines=$(planner_draft_readiness_security "$1")
  [ -n "$lines" ] || return 0
  echo "Security findings demoted at draft stage (review before dispatch):"
  while IFS=$'\t' read -r slug code id quote; do
    echo "  ${slug}: ${code} \"${quote}\" (${id})"
  done <<<"$lines"
}

# planner_draft_readiness_loop_close <INIT> <refresh-output> — called by the gate before it
# writes its fail lines: end-of-loop demotion, the DEMOTE_CEILING halt, and
# one `META|draft-readiness|warn|<slug> SECURITY <CODE> <id> "<quote>"` line
# per demoted security finding. A no-op at MAX_ROUNDS=0 or after another
# run-level halt.
planner_draft_readiness_loop_close() {
  local init="$1" root hits total ceil
  root=$(_pdl_root "$init") || return 1
  [ "$(_pdl_max_rounds)" -gt 0 ] || return 0
  [ -f "${root}/halt" ] && return 0
  hits=$(_pdl_converge "$init" "$2") || return 1
  local slug code id quote
  while IFS=$'\t' read -r slug code id quote; do
    [ -n "$slug" ] || continue
    planner_state_write "$init" "META" "draft-readiness" "warn" "${slug} SECURITY ${code} ${id} \"${quote//\"/\'}\""
  done < <(planner_draft_readiness_security "$init")
  total=$(planner_ticketgen_slugs "$(planner_ticketgen_specs_dir "$init")" | grep -c .)
  ceil="${PLANNER_DRAFT_DEMOTE_CEILING-0.5}"
  if [ "$total" -gt 0 ] && awk -v h="$hits" -v t="$total" -v c="$ceil" 'BEGIN { exit !(h / t > c) }'; then
    echo "DEMOTE_CEILING ${hits}/${total} specs ended with a reverted or failed demotion (ceiling ${ceil})" |
      _pdrv_write "${root}/halt"
  fi
  return 0
}

# planner_draft_readiness_history <INIT> <slug> — one line: the statuses of
# the spec's revision rounds, e.g. "2 revision(s): applied, reverted:FROZEN_CHANGED".
planner_draft_readiness_history() {
  local dir f n=0 list=""
  dir="$(_pdl_root "$1")/$2"
  for f in "${dir}"/revise.r*.status; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    list+="${list:+, }$(cat "$f")"
  done
  [ "$n" -gt 0 ] && printf '%s revision(s): %s\n' "$n" "$list"
  return 0
}

# planner_draft_readiness_history_report <INIT> — the revision history of
# the latest run (D14): per revised spec, its rounds, rebuttals and
# demotions with reason class. Prints nothing when no spec was revised.
planner_draft_readiness_history_report() {
  local init="$1" root d slug h run printed=0
  root=$(_pdl_root "$init") || return 0
  run=$(_planner_draft_run_lines "$init")
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    slug=$(basename "$d")
    h=$(planner_draft_readiness_history "$init" "$slug")
    [ -n "$h" ] || continue
    [ "$printed" -eq 1 ] || echo "Revision history:"
    printed=1
    echo "  ${slug}: ${h}"
    printf '%s\n' "$run" | grep -E "^[^|]*\|META\|draft-revise\|info\|${slug} REBUTTAL " | cut -d'|' -f5- |
      sed "s/^${slug} REBUTTAL /    rebutted: /"
    printf '%s\n' "$run" | grep -E "^[^|]*\|META\|draft-readiness\|info\|${slug} DEMOTED " | cut -d'|' -f5- |
      sed "s/^${slug} DEMOTED /    demoted (does not block): /"
    planner_draft_revise_assumptions "$(_pdrv_spec "$init" "$slug")" 2>/dev/null |
      grep -vxF -f <(
        planner_draft_revise_assumptions "${d}spec.r0.md" 2>/dev/null
        echo ""
      ) |
      sed 's/^/    assumption (review): /'
  done
  return 0
}
