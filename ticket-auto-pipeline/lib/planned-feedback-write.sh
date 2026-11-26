#!/usr/bin/env bash
# planned-feedback-write.sh — Post-implement hook that emits META|planner-feedback
# entries to the pipeline log for planned tickets.
#
# Conditional on FROM_PLANNED=true or a local ticket manifest existing — no
# behavior change for unplanned tickets. fleet-feedback.sh aggregates these
# entries by initiative.
#
# Usage: planned_feedback_write <TICKET_ID> <LOG_FILE>
# Returns: 0 on success (or no-op skip), non-zero on error.
#
# Sourceable library — no set -euo pipefail.

# manifest-read.sh backs the planned-ticket check below (tracker-planner-and-
# fallback-cutover, 3.14 sweep). Guarded — not every caller of this file has
# already sourced it.
if ! declare -f ticket_is_planned >/dev/null 2>&1; then
  _PFW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$_PFW_LIB_DIR/manifest-read.sh" ] && source "$_PFW_LIB_DIR/manifest-read.sh"
fi

# planner-context-extract.sh is the shared Planner Context block reader
# (GitHub #513). Guarded the same way.
if ! declare -f planner_context_field >/dev/null 2>&1; then
  _PFW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$_PFW_LIB_DIR/planner-context-extract.sh" ] && source "$_PFW_LIB_DIR/planner-context-extract.sh"
fi

# ── Main entry point ────────────────────────────────────────────────────────────

planned_feedback_write() {
  local tid="$1" log_file="$2"

  # Gate: only emit feedback for planned tickets. tracker-planner-and-
  # fallback-cutover (3.14 sweep) + Section 5 discriminator fix: a real
  # initiative, not bare manifest existence, is what makes a ticket planned —
  # flow.sh's _ensure_manifest stamps an _adhoc manifest onto every non-epic
  # trigger, so ticket_manifest_exists alone would misclassify an ad-hoc
  # ticket as planned the moment any trigger fires for it.
  # ticket_is_planned is the fallback when the caller hasn't already set
  # FROM_PLANNED; no live Linear read needed.
  if [ "${FROM_PLANNED:-false}" != "true" ]; then
    local has_planned=false
    if declare -f ticket_is_planned >/dev/null 2>&1 && ticket_is_planned "$tid"; then
      has_planned=true
    fi
    if [ "$has_planned" != "true" ]; then
      return 0 # Not a planned ticket — silent no-op
    fi
  fi

  # Ensure log file exists
  if [ ! -f "$log_file" ]; then
    echo "planned-feedback-write: log file not found: $log_file" >&2
    return 1
  fi

  # ── Gather data from pipeline log ────────────────────────────────────────────

  # Outcome label (Smooth/Rough/Hard)
  local outcome
  outcome=$(grep '^[^|]*|META|outcome-label|info|' "$log_file" 2>/dev/null | tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}')

  # Corrections count (from CORRECTIONS blocks in notes.md, or pipeline log)
  local corrections_count=0
  if grep -q '^[^|]*|META|corrections|' "$log_file" 2>/dev/null; then
    corrections_count=$(grep -c '^[^|]*|META|corrections|' "$log_file" 2>/dev/null || true)
    corrections_count=${corrections_count:-0}
  fi

  # Files changed — the ticket branch against its resolved base, in the
  # ticket's own worktrees (GitHub #768).
  local files_changed
  files_changed=$(_pfw_files_changed "$tid" "$log_file")
  [ -n "$files_changed" ] || files_changed="[]"
  # Fallback: log any files referenced in implement step
  if [ "$files_changed" = "[]" ] || [ "$files_changed" = "" ]; then
    files_changed=$(grep '^[^|]*|IMPLEMENT|' "$log_file" 2>/dev/null | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}' | grep -oP '/?[a-zA-Z0-9_/.-]+\.[a-zA-Z]+' 2>/dev/null | sort -u | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
  fi

  # ── Confidence ───────────────────────────────────────────────────────────────
  #
  # tracker-local-facts-read-migration (task 6.1): declare-tolerated, not
  # retargeted. Confidence/Affected-Services/exploration fields are planning
  # OUTPUT, not flow-control state — the design's scope note is explicit that
  # these stay description-derived ("continue to be read from the ticket
  # description exactly as today — migrating that parser is not called for
  # anywhere in the plan"). The ticket manifest schema deliberately carries
  # none of them (only type/initiative/blocked_by/dispatch/outcome_label).
  # The `get_issue` read is informational-only (feedback/drift computation,
  # never a gate) and only made when the caller already loaded linear-api.sh;
  # otherwise, or when it fails, the block comes from the local copies
  # (_pfw_planner_block). The block and its fields are read through
  # planner-context-extract.sh (GitHub #513) — the same anchored, fence-aware
  # extractor every other consumer uses, and the field names
  # planner_context_generate actually writes (`**Confidence:**`,
  # `**Affected Services:**`), not the older `- Confidence:` bullet shape.

  # Predicted confidence — the Planner Context block's **Confidence:** value,
  # or null when no block or no usable value can be read (GitHub #768). Never
  # 0: a 0 reads downstream as a real prediction and a major planning miss.
  local confidence_predicted=null pc_block="" conf_val
  pc_block=$(_pfw_planner_block "$tid" "$log_file")
  if [ -n "$pc_block" ]; then
    conf_val=$(printf '%s\n' "$pc_block" | planner_context_field "Confidence")
    # --argjson below needs a valid JSON number (no leading zeros, so
    # `00.5` is refused rather than breaking the payload).
    if [[ "$conf_val" =~ ^(0|[1-9][0-9]*)(\.[0-9]+)?$ ]]; then
      confidence_predicted="$conf_val"
    fi
  fi

  # Actual confidence — derived from outcome signals
  local confidence_actual
  confidence_actual=$(_compute_actual_confidence "$outcome" "$corrections_count")

  # ── Services touched ─────────────────────────────────────────────────────────

  local services_touched="[]"
  # Extract from Planner Context block
  if [ -n "$pc_block" ]; then
    services_touched=$(printf '%s\n' "$pc_block" | planner_context_field "Affected Services" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
    [ -n "$services_touched" ] || services_touched="[]"
  fi

  # ── Decision drift ───────────────────────────────────────────────────────────

  local decision_drift
  decision_drift=$(_compute_decision_drift "$confidence_predicted" "$confidence_actual")

  # ── Exploration accuracy ─────────────────────────────────────────────────────

  local exploration_depth_declared="" exploration_depth_actual="" missed_symbols="[]" false_traces="[]" code_paths_traced=""

  # Extract exploration fields from Planner Context block (optional
  # Schema-Version 2 fields — planner_context_generate does not emit them, so
  # this section is dormant for generator-written blocks).
  if [ -n "$pc_block" ]; then
    exploration_depth_declared=$(printf '%s\n' "$pc_block" | planner_context_field "Exploration Depth")
    code_paths_traced=$(printf '%s\n' "$pc_block" | planner_context_field "Code Paths Traced")
  fi

  # Compute exploration accuracy when the ticket was planned with exploration data
  if [ -n "$exploration_depth_declared" ]; then
    # Parse declared code paths into a clean list for comparison
    local traced_list="[]"
    if [ -n "$code_paths_traced" ]; then
      traced_list=$(echo "$code_paths_traced" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
    fi

    # Compare actual files changed vs. traced code paths
    # missed_symbols: files in the diff whose symbols were NOT in Code Paths Traced
    # false_traces: symbols in Code Paths Traced whose files were NOT in the diff
    if [ "$files_changed" != "[]" ] && [ -n "$files_changed" ]; then
      local changed_files_list
      changed_files_list=$(echo "$files_changed" | jq -r '.[]' 2>/dev/null || true)

      if [ "$traced_list" != "[]" ] && [ -n "$changed_files_list" ]; then
        # Extract file paths from traced symbols (symbol:file → file)
        local traced_files
        traced_files=$(echo "$code_paths_traced" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sed 's/^[^:]*://' | sort -u)

        # missed_symbols: changed files not in traced files
        local missed_list=""
        while IFS= read -r f; do
          [ -z "$f" ] && continue
          if ! grep -qF "$f" <<<"$traced_files"; then
            missed_list="${missed_list}${missed_list:+,}\"${f}\""
          fi
        done <<<"$changed_files_list"
        missed_symbols="[${missed_list}]"

        # false_traces: traced symbols whose file wasn't changed
        local false_list=""
        while IFS= read -r entry; do
          [ -z "$entry" ] && continue
          local sym_file
          sym_file=$(echo "$entry" | sed 's/^[^:]*://') # extract file from symbol:file
          if ! grep -qF "$sym_file" <<<"$changed_files_list"; then
            false_list="${false_list}${false_list:+,}\"${entry}\""
          fi
        done <<<"$(echo "$code_paths_traced" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')"
        false_traces="[${false_list}]"
      elif [ -z "$changed_files_list" ] || [ "$changed_files_list" = "[]" ]; then
        # No files changed — all traced paths are false traces
        false_traces="$traced_list"
      fi
    fi

    # Determine exploration_depth_actual
    # sufficient: no missed symbols, no false traces
    # insufficient: missed symbols found
    # over: false traces found but no missed symbols
    local missed_count false_count
    missed_count=$(echo "$missed_symbols" | jq 'length' 2>/dev/null || echo 0)
    false_count=$(echo "$false_traces" | jq 'length' 2>/dev/null || echo 0)

    if [ "$missed_count" -gt 0 ] 2>/dev/null; then
      exploration_depth_actual="insufficient"
    elif [ "$false_count" -gt 0 ] 2>/dev/null; then
      exploration_depth_actual="$exploration_depth_declared" # over-traced but depth was sufficient
    else
      exploration_depth_actual="$exploration_depth_declared"
    fi
  fi

  # ── Emit feedback entry ──────────────────────────────────────────────────────

  local payload iso
  payload=$(jq -nc \
    --argjson confidence_predicted "$confidence_predicted" \
    --argjson confidence_actual "$confidence_actual" \
    --arg outcome "$outcome" \
    --argjson corrections_count "$corrections_count" \
    --argjson files_changed "$files_changed" \
    --argjson services_touched "$services_touched" \
    --arg decision_drift "$decision_drift" \
    --arg exploration_depth_declared "$exploration_depth_declared" \
    --arg exploration_depth_actual "$exploration_depth_actual" \
    --argjson missed_symbols "$missed_symbols" \
    --argjson false_traces "$false_traces" \
    '{
      confidence_predicted: $confidence_predicted,
      confidence_actual: $confidence_actual,
      outcome: $outcome,
      corrections_count: $corrections_count,
      files_changed: $files_changed,
      services_touched: $services_touched,
      decision_drift: $decision_drift
    }
    + if $exploration_depth_declared != "" then {
      exploration_depth_declared: $exploration_depth_declared,
      exploration_depth_actual: $exploration_depth_actual,
      missed_symbols: $missed_symbols,
      false_traces: $false_traces
    } else {} end' 2>/dev/null)

  if [ -z "$payload" ]; then
    echo "planned-feedback-write: jq payload construction failed" >&2
    return 1
  fi

  iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "${iso}|META|planner-feedback|info|${payload}" >>"$log_file"

  return 0
}

# ── Helpers ─────────────────────────────────────────────────────────────────────

# F9: _compute_actual_confidence extracted to lib/confidence.sh to prevent drift
# between verifier-result.sh and planned-feedback-write.sh.
#
# confidence.sh sets `set -eo pipefail` at source time (it assumes the more
# common caller, verifier-result.sh, which already opts into that itself) —
# left unrestored here it leaks past this file's own "no set -euo pipefail"
# contract (see file header) into every caller's shell, including the
# router's own long-lived bash block in SKILL.md that sources this file
# inline. Restored immediately after sourcing so this file's documented
# contract actually holds.
_PFW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_PFW_DIR/confidence.sh" ]; then
  source "$_PFW_DIR/confidence.sh"
  set +e +o pipefail
elif [ -f "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/confidence.sh" ]; then
  source "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/confidence.sh"
  set +e +o pipefail
fi

# _pfw_planner_block <TID> <LOG_FILE>
# Prints the ticket's `## Planner Context` block, or nothing. Sources, in
# order: the tracker description when the caller already loaded
# linear-api.sh; the planner's own body.md under the initiative; context.md in
# the ticket workspace (looked up in the cwd and beside the log dir). The
# router's post-implement block sources this file alone, so without the local
# sources every run recorded no prediction at all (GitHub #768).
_pfw_planner_block() {
  local tid="$1" log_file="$2" block="" description="" f root
  declare -f planner_context_extract >/dev/null 2>&1 || return 0

  if declare -f get_issue >/dev/null 2>&1 && declare -f tracker_read >/dev/null 2>&1; then
    description=$(tracker_read informational "" -- get_issue "$tid" | jq -r '.description // ""' 2>/dev/null || true)
    [ -z "$description" ] || block=$(printf '%s\n' "$description" | planner_context_extract)
  fi

  if [ -z "$block" ] && [ -n "${REPOS_ROOT:-}" ]; then
    for f in "$REPOS_ROOT"/.ticket-auto/initiatives/*/tickets/"$tid"/planner/body.md; do
      [ -f "$f" ] || continue
      block=$(planner_context_extract "$f")
      [ -z "$block" ] || break
    done
  fi

  if [ -z "$block" ]; then
    for root in "$PWD" "$(dirname "$log_file")/.."; do
      for f in "$root"/"$tid"--*/context.md; do
        [ -f "$f" ] || continue
        block=$(planner_context_extract "$f")
        [ -z "$block" ] || break 2
      done
    done
  fi

  [ -z "$block" ] || printf '%s\n' "$block"
  return 0
}

# _pfw_branch_field <LOG_FILE> <key>
# One field of the last `META|branch-context` line (`ticket`, `base`, ...).
_pfw_branch_field() {
  local line
  line=$(grep '^[^|]*|META|branch-context|info|' "$1" 2>/dev/null | tail -1)
  [ -n "$line" ] || return 0
  printf '%s\n' "${line#*|META|branch-context|info|}" | tr ';' '\n' | sed -n "s/^$2=//p" | head -1
}

# _pfw_git_ref_ok <name> — a plain branch name, never an option or a range.
_pfw_git_ref_ok() {
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$1" != -* ]] && [[ "$1" != *..* ]]
}

# _pfw_repo_diff <repo-dir> <branch> <base>
# Names of the files the ticket branch changed against its base, one per
# line. The base is `origin/<base>` when the remote ref exists, else the local
# branch; the head is the ticket branch, else its remote ref.
_pfw_repo_diff() {
  local dir="$1" branch="$2" base="$3" head_ref="" base_ref=""
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
  if git -C "$dir" rev-parse --verify -q "${branch}^{commit}" >/dev/null 2>&1; then
    head_ref="$branch"
  elif git -C "$dir" rev-parse --verify -q "origin/${branch}^{commit}" >/dev/null 2>&1; then
    head_ref="origin/$branch"
  else
    return 0
  fi
  if git -C "$dir" rev-parse --verify -q "origin/${base}^{commit}" >/dev/null 2>&1; then
    base_ref="origin/$base"
  elif git -C "$dir" rev-parse --verify -q "${base}^{commit}" >/dev/null 2>&1; then
    base_ref="$base"
  else
    return 0
  fi
  git -C "$dir" diff --name-only "${base_ref}...${head_ref}" 2>/dev/null
}

# _pfw_files_changed <TID> <LOG_FILE>
# JSON array of the files the ticket changed. The ticket branch and its base
# come from the log's `META|branch-context` line (the base is the epic branch
# or the project default, not always `main`), and the diff runs in each of the
# ticket's worktrees under $REPOS_ROOT/.ticket-auto/worktrees/<TID>/, since
# the caller's cwd is the tickets root, not a code repo. Paths are prefixed
# with the repo directory name, as Target Symbols are. With no worktree the
# cwd is tried when it is a repo holding the branch. Prints `[]` when nothing
# can be resolved.
_pfw_files_changed() {
  local tid="$1" log_file="$2" branch base wt slug list=""
  branch=$(_pfw_branch_field "$log_file" ticket)
  base=$(_pfw_branch_field "$log_file" base)
  if ! _pfw_git_ref_ok "$branch" || ! _pfw_git_ref_ok "$base"; then
    echo "[]"
    return 0
  fi

  if [ -n "${REPOS_ROOT:-}" ]; then
    for wt in "$REPOS_ROOT"/.ticket-auto/worktrees/"$tid"/*/; do
      [ -d "$wt" ] || continue
      slug=$(basename "$wt")
      list+=$(_pfw_repo_diff "$wt" "$branch" "$base" | sed "s|^|${slug}/|")$'\n'
    done
  fi
  if [ -z "${list//$'\n'/}" ]; then
    list=$(_pfw_repo_diff "$PWD" "$branch" "$base")
  fi

  printf '%s\n' "$list" | sort -u | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]"
}

# Compute decision drift label from predicted vs actual confidence.
# Both values are ranked on the shared scale of _confidence_tier
# (confidence.sh, issue #826) and the ranks compared: same rank none, one apart
# minor, two apart (low vs high) major. The raw values are on different
# scales, so a raw difference was "major" on every Smooth ticket. unknown when
# there is no prediction to compare (GitHub #768); a missing actual counts as 0.
_compute_decision_drift() {
  local predicted="$1" actual="$2" p_tier a_tier diff

  if [ -z "$predicted" ] || [ "$predicted" = "null" ]; then
    echo "unknown"
    return 0
  fi
  p_tier=$(_confidence_tier "$predicted") || {
    echo "unknown"
    return 0
  }
  a_tier=$(_confidence_tier "${actual:-0}") || a_tier=0

  diff=$((p_tier - a_tier))
  [ "$diff" -lt 0 ] && diff=$((-diff))
  case "$diff" in
  0) echo "none" ;;
  1) echo "minor" ;;
  *) echo "major" ;;
  esac
}
