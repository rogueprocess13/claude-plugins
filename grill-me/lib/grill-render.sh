#!/usr/bin/env bash
# ── grill-render.sh ───────────────────────────────────────────────────────────
# Document renderer for the grill-me readiness gate.
#
# Produces a Validated Business Intent markdown document from a result.json
# (scoring output) and an assessment.json (agent output). Fixed section order
# per the intent-document capability spec.
#
# Exports:
#   grill_render  <result-json-file> <assessment-json-file> [output-path]
#     Renders the validated business intent document. If output-path is
#     provided, writes to that file; otherwise writes to stdout.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── grill_render ──────────────────────────────────────────────────────────────
# Usage: grill_render <result-json-file> <assessment-json-file> [output-path]
# ──────────────────────────────────────────────────────────────────────────────
grill_render() {
  local result_file="$1"
  local assessment_file="$2"
  local output_path="${3:-}"

  local result assessment
  result=$(cat "$result_file")
  assessment=$(cat "$assessment_file")

  # ── Extract fields from result ─────────────────────────────────────────────
  local profile_id subject round readiness recommendation critical_missing flags
  local question_count scored_at

  profile_id=$(echo "$result" | jq -r '.profile')
  subject=$(echo "$result" | jq -r '.subject')
  round=$(echo "$result" | jq -r '.round')
  readiness=$(echo "$result" | jq -r '.readiness')
  recommendation=$(echo "$result" | jq -r '.recommendation')
  critical_missing=$(echo "$result" | jq -r '.critical_missing')
  flags=$(echo "$result" | jq -r '.flags')
  question_count=$(echo "$result" | jq -r '.question_count')
  scored_at=$(echo "$result" | jq -r '.scored_at')

  # ── Extract from assessment ──────────────────────────────────────────────
  local dim_map
  # Build mapping: dimension id → {status, evidence, gap}
  local dim_count
  dim_count=$(echo "$assessment" | jq '.dimensions | length')

  declare -A a_status a_evidence a_gap a_boundary
  local j
  for j in $(seq 0 $((dim_count - 1))); do
    local aid astatus aevidence agap aboundary
    aid=$(echo "$assessment" | jq -r ".dimensions[$j].id")
    astatus=$(echo "$assessment" | jq -r ".dimensions[$j].status // \"missing\"")
    aevidence=$(echo "$assessment" | jq -r ".dimensions[$j].evidence // \"\"")
    agap=$(echo "$assessment" | jq -r ".dimensions[$j].gap // \"\"")
    aboundary=$(echo "$assessment" | jq -r ".dimensions[$j].boundary // \"\"")
    a_status["$aid"]="$astatus"
    a_evidence["$aid"]="$aevidence"
    a_gap["$aid"]="$agap"
    a_boundary["$aid"]="$aboundary"
  done

  # ── Extract questions from result ────────────────────────────────────────
  local ranked_questions
  ranked_questions=$(echo "$result" | jq -c '.questions // []')

  # ── Extract flags from assessment ─────────────────────────────────────────
  local assessment_flags
  assessment_flags=$(echo "$assessment" | jq -r '.flags // {}')

  # ── Helper: get dimension label from result.categories ─────────────────────
  _dim_label() {
    echo "$result" | jq -r ".dimensions[] | select(.dimension == \"$1\") | .label"
  }

  _dim_weight() {
    echo "$result" | jq -r ".dimensions[] | select(.dimension == \"$1\") | .weight"
  }

  _dim_status() {
    echo "$result" | jq -r ".dimensions[] | select(.dimension == \"$1\") | .status"
  }

  _dim_contrib() {
    echo "$result" | jq -r ".dimensions[] | select(.dimension == \"$1\") | .contribution"
  }

  # Section body for a dimension: its evidence text followed by every answer
  # folded in for that dimension (latest first, superseded ones marked).
  # Evidence alone is the round-1 assessment; answers from later rounds would
  # otherwise only reach the Resolved Questions table (#458).
  # Usage: _dim_body <dimension-id> <placeholder-when-empty>
  _dim_body() {
    local body="${a_evidence[$1]:-}"
    local clar
    clar=$(_render_clarifications "$assessment" "$1" "$round")
    if [ -n "$body" ]; then
      echo "$body"
    elif ! echo "$clar" | grep -q '^- \*\*Q[0-9]*\*\* (round [^)]*): '; then
      # No evidence and no current (non-superseded) answer.
      echo "$2"
    fi
    if [ -n "$clar" ]; then
      echo
      echo "$clar"
    fi
  }

  # ── Build sections ─────────────────────────────────────────────────────────

  # Header block
  local header
  header=$(
    cat <<MD
# Validated Business Intent

**Subject:** ${subject}
**Profile:** ${profile_id}
**Readiness:** ${readiness}/100
**Recommendation:** ${recommendation}
**Round:** ${round}
**Scored:** ${scored_at}

MD
  )

  # Objective
  local objective_section
  objective_section=$(
    cat <<MD
## Objective

$(_dim_body objective "_None specified_")

MD
  )

  # Users & Problem
  local users_section
  users_section=$(
    cat <<MD
## Users & Problem

$(_dim_body users_problem "_None specified_")

MD
  )

  # Success Criteria
  local success_section
  success_section=$(
    cat <<MD
## Success Criteria

$(_dim_body success_criteria "_None identified_")

MD
  )

  # Scope (with In scope / Out of scope sub-headings)
  local scope_section
  scope_section=$(
    cat <<MD
## Scope

### In scope

$([ -n "${a_evidence[scope]:-}" ] && echo "${a_evidence[scope]}" || echo "_Not specified_")

### Out of scope

$([ -n "${a_boundary[scope]:-}" ] && echo "${a_boundary[scope]}" || echo "_Not specified_")

$(_render_clarifications "$assessment" scope "$round")

MD
  )

  # Acceptance Criteria
  local ac_section
  ac_section=$(
    cat <<MD
## Acceptance Criteria

$(_dim_body acceptance_criteria "_None identified_")

MD
  )

  # Constraints
  local constraints_section
  constraints_section=$(
    cat <<MD
## Constraints

$(_dim_body constraints "_None identified_")

MD
  )

  # Dependencies
  local dependencies_section
  dependencies_section=$(
    cat <<MD
## Dependencies

$(_dim_body dependencies "_None identified_")

MD
  )

  # Assumptions
  local assumptions_raw
  assumptions_raw=$(echo "$assessment" | jq -r '.assumptions // [] | if length == 0 then "_None identified_" else map("- " + .) | join("\n") end')

  local assumptions_section
  assumptions_section=$(
    cat <<MD
## Assumptions (require validation)

${assumptions_raw}

$(_render_clarifications "$assessment" assumptions "$round")

MD
  )

  # Risks
  local risks_raw
  risks_raw=$(echo "$assessment" | jq -r '.risks // [] | if length == 0 then "_None identified_" else map("- " + .) | join("\n") end')

  local risks_section
  risks_section=$(
    cat <<MD
## Risks

${risks_raw}

$(_render_clarifications "$assessment" risks "$round")

MD
  )

  # Edge Cases
  local edge_section
  edge_section=$(
    cat <<MD
## Edge Cases

$(_dim_body edge_cases "_None identified_")

MD
  )

  # Resolved Questions table
  local resolved_table
  resolved_table=$(_render_resolved_questions "$assessment" "$round")

  # Open Gaps table
  local gaps_table
  gaps_table=$(_render_open_gaps "$result" "$assessment")

  # Category Scores table
  local scores_table
  scores_table=$(_render_category_scores "$result")

  # ── Assemble document (without seal — seal is applied by grill-seal.sh) ──
  local doc
  doc="${header}
${objective_section}
${users_section}
${success_section}
${scope_section}
${ac_section}
${constraints_section}
${dependencies_section}
${risks_section}
${edge_section}
${assumptions_section}
${resolved_table}
${gaps_table}
${scores_table}"

  # Strip trailing whitespace from each line
  doc=$(echo "$doc" | sed 's/[[:space:]]*$//')

  if [ -n "$output_path" ]; then
    mkdir -p "$(dirname "$output_path")" 2>/dev/null || true
    echo "$doc" >"$output_path"
    echo "grill-render: document written to ${output_path}" >&2
  else
    echo "$doc"
  fi

  return 0
}

# ── _render_resolved_questions ────────────────────────────────────────────────
_render_resolved_questions() {
  local assessment="$1"
  local max_round="$2"

  # Resolved question+answer pairs are folded into assessment.resolved by the
  # interactive grill loop (SKILL.md Step 5) — .questions holds only pending
  # questions, so an empty .questions array is the expected steady state once
  # everything has been answered, not evidence nothing was ever asked.
  local r_count
  r_count=$(echo "$assessment" | jq '.resolved | length')

  if [ "$r_count" -eq 0 ]; then
    cat <<MD
## Resolved Questions

_No questions were asked — the input scored ready on the first round._

MD
    return 0
  fi

  # Build table
  local table
  table="## Resolved Questions

| # | Question | Dimension | Why | Round | Answer |
|---|----------|-----------|-----|-------|--------|
"
  local superseded_map
  superseded_map=$(_resolved_superseded_map "$assessment")

  local ri
  for ri in $(seq 0 $((r_count - 1))); do
    local q_text q_dim q_why q_round q_answer
    q_text=$(echo "$assessment" | jq -r ".resolved[$ri].question // \"\"")
    q_dim=$(echo "$assessment" | jq -r ".resolved[$ri].dimension // \"\"")
    q_why=$(echo "$assessment" | jq -r ".resolved[$ri].why // \"\"")
    q_round=$(echo "$assessment" | jq -r ".resolved[$ri].round // \"${max_round}\"")
    q_answer=$(echo "$assessment" | jq -r ".resolved[$ri].answer // \"\"")

    # Escape pipes in table cells
    q_text=$(echo "$q_text" | sed 's/|/\\|/g')
    q_why=$(echo "$q_why" | sed 's/|/\\|/g')
    q_answer=$(echo "$q_answer" | sed 's/|/\\|/g')

    local q_by
    q_by=$(echo "$superseded_map" | jq -r --arg n "$((ri + 1))" '.[$n] // empty')
    if [ -n "$q_by" ]; then
      q_answer="**SUPERSEDED by Q${q_by}** — ${q_answer}"
    fi

    table="${table}| $((ri + 1)) | ${q_text} | ${q_dim} | ${q_why} | ${q_round} | ${q_answer} |
"
  done

  echo "$table"
}

# ── _resolved_superseded_map ──────────────────────────────────────────────────
# Usage: _resolved_superseded_map <assessment-json>
# Emits a JSON object mapping an overridden question number (1-based position
# in .resolved, i.e. the `#` column of the Resolved Questions table) to the
# number of the latest question whose `supersedes` names it. `supersedes` may
# be a number or an array of numbers; references that are not strictly earlier
# questions are ignored, so a question never supersedes itself or a later one.
_resolved_superseded_map() {
  echo "$1" | jq -c '
    [ (.resolved // []) | to_entries[]
      | (.key + 1) as $new
      | (.value.supersedes // []) | (if type == "array" then . else [.] end)[]
      | (tonumber? // empty) | floor
      | select(. >= 1 and . < $new)
      | {old: tostring, new: $new} ]
    | reduce .[] as $p ({}; .[$p.old] = ([.[$p.old] // 0, $p.new] | max))'
}

# ── _render_clarifications ────────────────────────────────────────────────────
# Usage: _render_clarifications <assessment-json> <dimension-id> <max-round>
# Renders the answers folded into .resolved for one dimension as a bullet list,
# latest first, so a dimension section reads from its most recent answer. An
# answer overridden by a later question (`supersedes`) stays visible as history
# but carries a "SUPERSEDED by Qn" marker. Emits nothing when the dimension has
# no resolved answers.
_render_clarifications() {
  local assessment="$1"
  local dim="$2"
  local max_round="$3"

  local superseded_map
  superseded_map=$(_resolved_superseded_map "$assessment")

  local items
  items=$(echo "$assessment" | jq -r --arg dim "$dim" --arg max "$max_round" \
    --argjson sup "$superseded_map" '
    [ (.resolved // []) | to_entries[]
      | select(.value.dimension == $dim)
      | (.key + 1) as $n
      | {n: $n,
         round: ((.value.round // $max) | tostring),
         answer: ((.value.answer // "") | tostring | gsub("[\r\n]+"; " ")),
         by: $sup[($n | tostring)]} ]
    | reverse
    | map(if .by then
            "- **Q\(.n)** (round \(.round)) — **SUPERSEDED by Q\(.by)**, not current intent: \(.answer)"
          else
            "- **Q\(.n)** (round \(.round)): \(.answer)"
          end)
    | join("\n")')

  if [ -n "$items" ]; then
    echo "**Clarified answers (latest first; these override the text above where they conflict):**"
    echo
    echo "$items"
  fi
}

# ── _render_open_gaps ─────────────────────────────────────────────────────────
_render_open_gaps() {
  local result="$1"
  local assessment="$2"

  local gap_rows=""
  local dim_count
  dim_count=$(echo "$result" | jq '.dimensions | length')

  local i
  for i in $(seq 0 $((dim_count - 1))); do
    local did dstatus dgap
    did=$(echo "$result" | jq -r ".dimensions[$i].dimension")
    dstatus=$(echo "$result" | jq -r ".dimensions[$i].status")
    # Select by id, not index — the assessment's dimensions array may be
    # reordered relative to result's (profile-ordered) array, or omit
    # dimensions entirely (coerced to "missing" by the scorer).
    dgap=$(echo "$assessment" | jq -r --arg did "$did" '.dimensions[] | select(.id == $did) | .gap // ""')

    if [ "$dstatus" != "present" ]; then
      # Escape pipes
      dgap=$(echo "$dgap" | sed 's/|/\\|/g')
      if [ -n "$dgap" ]; then
        gap_rows="${gap_rows}| ${did} | ${dstatus} | ${dgap} |
"
      else
        gap_rows="${gap_rows}| ${did} | ${dstatus} | _Not specified_ |
"
      fi
    fi
  done

  if [ -z "$gap_rows" ]; then
    cat <<MD
## Open Gaps

_No open gaps — all dimensions are present._

MD
  else
    cat <<MD
## Open Gaps

| Dimension | Status | Gap |
|-----------|--------|-----|
${gap_rows}
MD
  fi
}

# ── _render_category_scores ───────────────────────────────────────────────────
_render_category_scores() {
  local result="$1"

  local rows=""
  local dim_count
  dim_count=$(echo "$result" | jq '.dimensions | length')

  local i
  for i in $(seq 0 $((dim_count - 1))); do
    local did dlabel dweight dstatus dcontrib
    did=$(echo "$result" | jq -r ".dimensions[$i].dimension")
    dlabel=$(echo "$result" | jq -r ".dimensions[$i].label")
    dweight=$(echo "$result" | jq -r ".dimensions[$i].weight")
    dstatus=$(echo "$result" | jq -r ".dimensions[$i].status")
    dcontrib=$(echo "$result" | jq -r ".dimensions[$i].contribution")

    rows="${rows}| ${dlabel} | ${dweight} | ${dstatus} | ${dcontrib} |
"
  done

  cat <<MD
## Category Scores

| Dimension | Weight | Status | Contribution |
|-----------|--------|--------|-------------|
${rows}
MD
}

# If executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 2 ]; then
    echo "Usage: grill-render.sh <result.json> <assessment.json> [output-path]" >&2
    exit 1
  fi
  grill_render "$1" "$2" "${3:-}"
fi
