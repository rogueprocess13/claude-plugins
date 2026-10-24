#!/usr/bin/env bash
# test-persona-injection.sh — guard test for persona injection in pipeline skills
# (openspec change debugger-persona-overlay, specs persona-selection-input +
# debugger-persona).
#
# Fails when:
#   - a persona-select.sh invocation in a pipeline skill lacks a TICKET_TEXT_FILE=
#     prefix (the dead-haystack defect: keyword triggers never saw ticket text);
#   - a skill named in any personas/base/*.md `used-by:` list has no
#     `persona-select.sh --repo` invocation (the 2026-09 "zero persona
#     injection" retro finding — a prose mention does not count);
#   - the debugger overlay wiring is missing from implement/appraise/pr-review,
#     or leaks into verify/reproduce/appraise-exec;
#   - the META|persona-select line would move detect-resume's resume point;
#   - the verify cap drifts from 2 (the "last rework" wording depends on it).
#
# Usage: bash test-persona-injection.sh [test_name_filter]
# -u (nounset) intentionally omitted, as in the other lib tests.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
SKILLS_DIR="$PLUGIN_DIR/skills"
PERSONAS_DIR="$PLUGIN_DIR/personas"
DETECT_SH="$SKILLS_DIR/ticket-detect-resume/detect-resume.sh"
export CLAUDE_SKILLS_LIB="${CLAUDE_SKILLS_LIB:-$LIB_DIR}"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# Skills whose SKILL.md invokes the selector and must feed it ticket text.
CALL_SITE_SKILLS=(ticket-appraise ticket-implement ticket-pr-review ticket-audit ticket-prescan)
# Skills that consume the debugger overlay.
DEBUG_SKILLS=(ticket-appraise ticket-implement ticket-pr-review)
# Skills that load no persona by design.
NO_PERSONA_SKILLS=(ticket-verify ticket-reproduce ticket-appraise-exec)

# ── helpers ────────────────────────────────────────────────────────────────────

# _invocations <SKILL.md> — print one line per persona-select.sh invocation.
# Backslash-continued lines are joined first (prescan's `eval $(bash … \`
# spans two lines), then quotes and backticks are dropped so
# `persona-select.sh" \ --repo` and `persona-select.sh --repo` look alike. An
# invocation is `persona-select.sh` followed by `--repo`; a prose mention of
# the script (persona-refresh's "does not modify persona-select.sh") has no
# `--repo` and is not printed.
_invocations() {
  awk '
    /\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, ""); buf = buf $0 " "; next }
    { print buf $0; buf = "" }
    END { if (buf != "") print buf }
  ' "$1" | tr -d "\"'\`" | grep -E 'persona-select\.sh[[:space:]]+--repo' || true
}

# _section <file> <start-regex> <end-regex> — lines from the first start match
# up to (not including) the next end match.
_section() {
  awk -v s="$2" -v e="$3" '
    !on && $0 ~ s { on = 1; print; next }
    on && $0 ~ e { exit }
    on { print }
  ' "$1"
}

# _used_by <persona.md> — skill names in the frontmatter `used-by:` list,
# with any "(…)" annotation stripped.
_used_by() {
  awk '
    NR == 1 && /^---/ { fm = 1; next }
    fm && /^---/ { exit }
    fm && /^used-by:/ { inlist = 1; next }
    fm && inlist && /^[[:space:]]+-[[:space:]]/ {
      sub(/^[[:space:]]+-[[:space:]]+/, ""); sub(/[[:space:]]*\(.*$/, ""); sub(/[[:space:]]+$/, "")
      print; next
    }
    fm && inlist && /^[^[:space:]]/ { inlist = 0 }
  ' "$1"
}

_detect_resume_with_log() {
  local ticket_id="$1"
  shift
  local tmpdir rc=0
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  printf '%s\n' "$@" >"$tmpdir/logs/${ticket_id}-pipeline.log"
  (cd "$tmpdir" && bash "$DETECT_SH" "$ticket_id" 2>/dev/null) || rc=$?
  rm -rf "$tmpdir"
  return $rc
}

_field() {
  echo "$1" | grep "^  ${2}:" | sed -E "s/^  ${2}: *//"
}

# ── call sites carry ticket text ───────────────────────────────────────────────

test_every_call_site_has_ticket_text_prefix() {
  local skill md inv bad="" count
  for skill in "${CALL_SITE_SKILLS[@]}"; do
    md="$SKILLS_DIR/$skill/SKILL.md"
    [ -f "$md" ] || {
      echo "  missing $md"
      return 1
    }
    count=0
    while IFS= read -r inv; do
      [ -n "$inv" ] || continue
      count=$((count + 1))
      # The assignment must come before the script on the same (joined) line.
      if ! echo "$inv" | grep -qE 'TICKET_TEXT_FILE=[^[:space:]]*[[:space:]].*persona-select\.sh'; then
        bad="$bad\n  $skill: $inv"
      fi
    done < <(_invocations "$md")
    [ "$count" -gt 0 ] || bad="$bad\n  $skill: no persona-select.sh --repo invocation found"
  done
  [ -z "$bad" ] || {
    echo -e "  invocations without a TICKET_TEXT_FILE= prefix:$bad"
    return 1
  }
}

# The scanner itself: a line-continued invocation is found, a prose mention is not.
test_invocation_scanner_handles_continuation_and_prose() {
  local tmp out
  tmp=$(mktemp)
  cat >"$tmp" <<'EOF'
   eval $(TICKET_TEXT_FILE="" bash "$HOME/.claude/skills/lib/persona-select.sh" \
     --repo "$repo" --phase prescan)
It does not modify `persona-select.sh` selection logic.
EOF
  out=$(_invocations "$tmp")
  rm -f "$tmp"
  [ "$(echo "$out" | grep -c 'persona-select')" -eq 1 ] && echo "$out" | grep -q -- '--phase prescan'
}

# ── used-by ↔ invocation cross-check ───────────────────────────────────────────

test_used_by_skills_invoke_the_selector() {
  local persona skill md bad="" n=0
  for persona in "$PERSONAS_DIR"/base/*.md; do
    n=$((n + 1))
    while IFS= read -r skill; do
      [ -n "$skill" ] || continue
      md="$SKILLS_DIR/$skill/SKILL.md"
      if [ ! -f "$md" ]; then
        bad="$bad\n  $(basename "$persona") used-by $skill: no skills/$skill/SKILL.md"
      elif [ -z "$(_invocations "$md")" ]; then
        bad="$bad\n  $(basename "$persona") used-by $skill: no persona-select.sh --repo invocation"
      fi
    done < <(_used_by "$persona")
  done
  [ "$n" -gt 0 ] || {
    echo "  no base personas found under $PERSONAS_DIR/base"
    return 1
  }
  [ -z "$bad" ] || {
    echo -e "  declared users without a selector call:$bad"
    return 1
  }
}

test_used_by_parser_reads_every_base_persona() {
  local persona
  for persona in "$PERSONAS_DIR"/base/*.md; do
    [ -n "$(_used_by "$persona")" ] || {
      echo "  $(basename "$persona"): empty or unparsable used-by list"
      return 1
    }
  done
}

# ── debugger overlay wiring ────────────────────────────────────────────────────

test_debug_skills_reference_persona_debug() {
  local skill missing=""
  for skill in "${DEBUG_SKILLS[@]}"; do
    grep -q 'PERSONA_DEBUG' "$SKILLS_DIR/$skill/SKILL.md" || missing="$missing $skill"
  done
  [ -z "$missing" ] || {
    echo "  PERSONA_DEBUG missing in:$missing"
    return 1
  }
}

test_no_persona_skills_do_not_reference_persona_debug() {
  local skill leaked=""
  for skill in "${NO_PERSONA_SKILLS[@]}"; do
    [ -f "$SKILLS_DIR/$skill/SKILL.md" ] || continue
    if grep -q 'PERSONA_DEBUG' "$SKILLS_DIR/$skill/SKILL.md"; then leaked="$leaked $skill"; fi
  done
  [ -z "$leaked" ] || {
    echo "  PERSONA_DEBUG referenced in:$leaked"
    return 1
  }
}

test_implement_step2_passes_type_and_logs_meta_line() {
  local sec
  sec=$(_section "$SKILLS_DIR/ticket-implement/SKILL.md" '^## Step 2 — ' '^## Step 2\.5')
  # Type derivation (manifest type, else bug label) lives in persona-select.sh
  # --ticket-dir, covered by lib/test-persona-select.sh section 1.7.
  echo "$sec" | grep -q -- '--ticket-dir "{ticket-dir}"' || {
    echo "  Step 2 does not pass --ticket-dir"
    return 1
  }
  echo "$sec" | grep -q 'for _k in PERSONA_TYPE ' || {
    echo "  Step 2 does not print PERSONA_TYPE (Part B reuses it)"
    return 1
  }
  echo "$sec" | grep -q 'PERSONA_DEBUG_SPECIALIZER' || {
    echo "  Step 2 does not read PERSONA_DEBUG_SPECIALIZER"
    return 1
  }
  echo "$sec" | grep -qF 'plog.sh META persona-select info "base=' || {
    echo "  Step 2 does not write META|persona-select|info|base=…"
    return 1
  }
  # Never an IMPLEMENT|persona-select line — detect-resume would turn it into IMPLEMENT_FROM.
  if echo "$sec" | grep -qE '\|IMPLEMENT\|persona-select\||plog\.sh IMPLEMENT persona-select'; then
    echo "  Step 2 writes an IMPLEMENT|persona-select line"
    return 1
  fi
}

test_implement_rework_section_has_debugger_rules() {
  local sec tok missing=""
  sec=$(_section "$SKILLS_DIR/ticket-implement/SKILL.md" '^### Part B' '^## Step 3')
  [ -n "$sec" ] || {
    echo "  Part B section not found"
    return 1
  }
  for tok in 'persona-select.sh' '--remediation' 'VERIFY_EXHAUSTED' 'failing test' '=== HUMAN_HOLD ===' 'last rework' 'hypothesis'; do
    echo "$sec" | grep -qF -- "$tok" || missing="$missing [$tok]"
  done
  [ -z "$missing" ] || {
    echo "  Part B missing:$missing"
    return 1
  }
  # The old "starting point" instruction must be gone.
  if echo "$sec" | grep -qF 'Use the Suggested Fix as the starting point'; then
    echo "  Part B still says to use the Suggested Fix as the starting point"
    return 1
  fi
  echo "$sec" | grep -qE 'PR Review #N.*--remediation|--remediation.*PR Review #N' || {
    echo "  Part B does not say the PR Review #N path skips --remediation"
    return 1
  }
}

test_appraise_step3_writes_root_cause_hypothesis() {
  local md="$SKILLS_DIR/ticket-appraise/SKILL.md" s25 s3 s3a
  s25=$(_section "$md" '^## Step 2\.5' '^## Step 2\.6')
  echo "$s25" | grep -q -- '--type' || {
    echo "  Step 2.5 does not pass --type"
    return 1
  }
  s3=$(_section "$md" '^## Step 3 — ' '^## Step 3-Agent')
  echo "$s3" | grep -qF '### Root cause hypothesis' || {
    echo "  Step 3 lacks ### Root cause hypothesis"
    return 1
  }
  echo "$s3" | grep -qF 'would disprove' || {
    echo "  Step 3 lacks 'would disprove'"
    return 1
  }
  s3a=$(_section "$md" '^## Step 3-Agent' '^## Step 3\.5')
  echo "$s3a" | grep -qF 'Root cause hypothesis' || {
    echo "  Step 3-Agent lacks Root cause hypothesis"
    return 1
  }
}

test_pr_review_step2_adds_bug_checks() {
  local sec tok missing=""
  sec=$(_section "$SKILLS_DIR/ticket-pr-review/SKILL.md" '^## Step 2 — ' '^## Step 3 — ')
  for tok in 'PERSONA_DEBUG' 'root cause' 'regression test' '--type'; do
    echo "$sec" | grep -qF -- "$tok" || missing="$missing [$tok]"
  done
  [ -z "$missing" ] || {
    echo "  pr-review Step 2 missing:$missing"
    return 1
  }
}

test_log_format_documents_persona_select_meta() {
  grep -qF 'META|persona-select|info|base=' "$PLUGIN_DIR/pipeline-log-format.md" || {
    echo "  pipeline-log-format.md does not document META|persona-select"
    return 1
  }
}

# ── resume safety + cap ────────────────────────────────────────────────────────

test_meta_persona_select_line_does_not_move_resume() {
  local base=(
    "2026-10-24T10:00:00Z|META|schema|info|1"
    "2026-10-24T10:00:01Z|APPRAISE|appraise|done|ok"
    "2026-10-24T10:00:02Z|IMPLEMENT|check-approval|done|Authorized"
    "2026-10-24T10:00:03Z|IMPLEMENT|detect-path|done|simple-fix"
  )
  local without with probe
  without=$(_detect_resume_with_log "TEST-1" "${base[@]}")
  with=$(_detect_resume_with_log "TEST-1" "${base[@]}" \
    "2026-10-24T10:00:04Z|META|persona-select|info|base=backend-developer;spec=backend/java.md;debug=debug/jvm.md")
  [ -n "$(_field "$without" RESUME_STEP)" ] || {
    echo "  fixture produced no RESUME_STEP"
    return 1
  }
  [ "$(_field "$without" RESUME_STEP)" = "$(_field "$with" RESUME_STEP)" ] || {
    echo "  RESUME_STEP changed: $(_field "$without" RESUME_STEP) -> $(_field "$with" RESUME_STEP)"
    return 1
  }
  [ "$(_field "$without" IMPLEMENT_FROM)" = "$(_field "$with" IMPLEMENT_FROM)" ] || {
    echo "  IMPLEMENT_FROM changed: $(_field "$without" IMPLEMENT_FROM) -> $(_field "$with" IMPLEMENT_FROM)"
    return 1
  }
  # Sensitivity check: the same fact written as an IMPLEMENT line DOES move it,
  # which is why the skill must use the META pseudo-phase.
  probe=$(_detect_resume_with_log "TEST-1" "${base[@]}" \
    "2026-10-24T10:00:04Z|IMPLEMENT|persona-select|done|base=backend-developer")
  [ "$(_field "$probe" IMPLEMENT_FROM)" != "$(_field "$without" IMPLEMENT_FROM)" ] || {
    echo "  fixture is insensitive: an IMPLEMENT|persona-select line did not change IMPLEMENT_FROM"
    return 1
  }
}

test_verify_cap_is_two() {
  local cap
  cap=$(jq -r '[.steps[] | .loop? // empty | select(.counter == "VERIFY_ATTEMPTS") | .max_iterations][0]' \
    "$SKILLS_DIR/ticket-flow/dispatch-table.json")
  [ "$cap" = "2" ] || {
    echo "  VERIFY max_iterations is '$cap', not 2 — update the 'last rework' wording in ticket-implement Part B and personas/base/debugger.md"
    return 1
  }
}

# ── dispatcher ─────────────────────────────────────────────────────────────────

filter="${1:-}"

for func in $(declare -F | grep '^declare -f test_' | sed 's/declare -f //'); do
  if [ -z "$filter" ] || echo "$func" | grep -q "$filter"; then
    _run "$func" "$func"
  fi
done

echo "---"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
