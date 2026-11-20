#!/usr/bin/env bash
# get_complexity <ticket-dir>
# Reads the ## Complexity section's **Score:** value from notes.md.
# Emits "simple", "complex", or empty string if absent.
# Exit codes: 0 = found, 1 = file unreadable, 2 = section not found
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
#
# NOT guarded the way audit-ac-testability.sh/audit-test-data-check.sh are
# (dor-readiness-gate-foundation task 4.5/11) despite the identical-looking
# leak: several functions here (get_complexity, get_test_users_by_role,
# get_test_users_by_env, ...) call error_return mid-function with no
# explicit `return` after it, relying on the caller's errexit being active
# for that non-zero return to actually abort the function early — confirmed
# by test-notes-parse.sh's test_missing_notes_file, which regresses (12 ->
# 2) the moment this line stops firing for a caller with no errexit of its
# own. Guarding this file would require auditing/fixing every such
# early-return call site first, which is out of this change's scope —
# see lib/dor-check.sh's sourcing block for how it works around this
# instead (declare-guard only, no unconditional source).
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/error-handler.sh" ]; then
  source "$SCRIPT_DIR/error-handler.sh"
fi

get_complexity() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  local score
  score=$(grep -A3 '## Complexity' "$notes" 2>/dev/null |
    grep '^\*\*Score:' |
    awk '{print $2}' |
    tr -d '\r' || true)

  if [ -n "$score" ]; then
    echo "$score"
    return 0
  fi

  return 2
}

# get_critique_score <ticket-dir>
# Reads the ## Readiness Critique section's **Score:** value from notes.md.
# A re-run appends a second "## Readiness Critique (re-run <date>)" heading
# rather than replacing the first, so this takes the LAST matching heading
# (the superseding re-run), not the first.
# Emits integer (0-100) or empty string if absent.
# Exit codes: 0 = found, 1 = file unreadable, 2 = section not found
get_critique_score() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  local start_line
  start_line=$(grep -n '^## Readiness Critique' "$notes" 2>/dev/null | tail -1 | cut -d: -f1)

  if [ -z "$start_line" ]; then
    return 2
  fi

  local score
  score=$(tail -n "+$start_line" "$notes" 2>/dev/null |
    sed -n '1,/^## /p' |
    grep '^\*\*Score:' |
    head -1 |
    sed 's/.*\*\*Score:\*\* *//' |
    grep -oP '^[0-9]+' |
    head -1 || true)

  if [ -n "$score" ]; then
    echo "$score"
    return 0
  fi

  return 2
}

# get_critique_status <ticket-dir>
# Reads the ## Readiness Critique section's **Status:** value from notes.md.
# A re-run appends a second "## Readiness Critique (re-run <date>)" heading
# rather than replacing the first, so this takes the LAST matching heading
# (the superseding re-run), not the first.
# Emits BLOCKED, WARNINGS, CLEAR, or empty string if absent.
# Exit codes: 0 = found, 1 = file unreadable, 2 = section not found
get_critique_status() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  local start_line
  start_line=$(grep -n '^## Readiness Critique' "$notes" 2>/dev/null | tail -1 | cut -d: -f1)

  if [ -z "$start_line" ]; then
    return 2
  fi

  # Seam audit Track 0.3: the label is matched case-insensitively and in both
  # bold forms (`**Status:**` and `**Status**:`), and the value is
  # case-folded — "Blocked" is BLOCKED; `*` and backticks around the value
  # (`**CLEAR**`, `` `WARNINGS` ``) are dropped. A value outside the enum prints
  # nothing; the gate reads that as CRITIQUE_STATUS_MISSING, never as clear.
  local status
  status=$(tail -n "+$start_line" "$notes" 2>/dev/null |
    sed -n '1,/^## /p' |
    grep -iE '^\*\*Status(:\*\*|\*\*:)' |
    head -1 |
    sed -E 's/^\*\*[Ss][Tt][Aa][Tt][Uu][Ss](:\*\*|\*\*:)[[:space:]]*//' |
    sed -E 's/[*`]//g; s/^[[:space:]]+//' |
    tr '[:lower:]' '[:upper:]' |
    grep -oE '^(BLOCKED|WARNINGS|CLEAR)\b' || true)

  if [ -n "$status" ]; then
    echo "$status"
    return 0
  fi

  return 2
}

# get_open_needs_human_count <ticket-dir>
# Counts the open `[needs-human]` questions under notes.md `## Open Questions`
# (seam audit Track 0.3 — the entry gate holds an auto-approval on them).
# Tolerant of the shapes agents write: the heading in any case with an
# optional suffix (`:`, `(2)`), `###` subsections inside it, `-`/`*`/`+` and
# numbered (`1.`/`1)`) bullets, an unticked `[ ]` box, a bold label before the
# tag (`- **Q1:** [needs-human]`), and bold `**[needs-human]**`. A struck bullet
# (`- ~~[needs-human] …~~`) or a ticked box (`- [x] [needs-human]`) is answered.
# Lines inside ``` / ~~~ fences are skipped. Prints an integer, always.
# Exit codes: 0 = counted (may be 0), 1 = notes.md unreadable
get_open_needs_human_count() {
  local notes="$1/notes.md"
  if [ ! -f "$notes" ]; then
    echo 0
    return 1
  fi
  awk '
    /^[ ]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^##[ \t]/ && !/^###/ {
      h = tolower($0); sub(/^##[ \t]+/, "", h); sub(/[ \t:]+$/, "", h)
      f = (h ~ /^open questions([^a-z].*)?$/); next
    }
    f && tolower($0) ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]+(\[[ \t]\][ \t]+)?(\*\*[^*]*\*\*[ \t]*)?(\*\*)?\[needs-human\]/ { n++ }
    END { print n + 0 }
  ' "$notes" 2>/dev/null || echo 0
  return 0
}

# get_ac_count <ticket-dir>
# Counts acceptance criteria lines in context.md.
# Counts numbered (1., 2.) and checkbox (- [ ] and - [x]) criteria lines.
# Emits integer count or empty string.
# Exit codes: 0 = found (may be 0), 1 = file unreadable
get_ac_count() {
  local ticket_dir="$1"
  local ctx="$ticket_dir/context.md"

  if [ ! -f "$ctx" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  local count
  # Prefer an explicit "## Acceptance Criteria" section: count AC lines only
  # within that section (heading to the next heading of any level). This
  # avoids the prefix heuristic below misfiring on templates where a heading
  # like Background/Context/Environment appears BEFORE Acceptance Criteria —
  # the prefix would otherwise get truncated before the real AC section is
  # ever reached, undercounting a ticket that has ACs as zero.
  local ac_section
  ac_section=$(awk '
    { low = tolower($0) }
    low ~ /^#+[ \t]*acceptance criteria[ \t]*$/ { flag=1; next }
    /^#+[ \t]/ { if (flag) exit }
    flag { print }
  ' "$ctx" 2>/dev/null || true)
  if [ -n "$ac_section" ]; then
    count=$(echo "$ac_section" | grep -cP '^\s*(\d+\.\s|\- \[[ xX]\]\s)' 2>/dev/null || true)
    echo "${count//[^0-9]/}"
    return 0
  fi

  # Fallback: no explicit "## Acceptance Criteria" heading found — original
  # heuristic. Count numbered (1., 2.) and checkbox (- [ ] and - [x]) criteria
  # lines, stopping at the first repro section heading — reproduction steps
  # are numbered but are NOT acceptance criteria.
  local prefix
  # Boundary must look like a real section marker: either a markdown heading
  # (one-or-more '#', then a space) or the bare keyword at true column 0 with
  # zero leading whitespace. The old '^#*\s*(...)' allowed BOTH zero hashes
  # AND arbitrary leading whitespace, which collapses to "keyword anywhere
  # near line start" — an indented prose continuation line ("  context, so
  # behavior parity...") satisfied it purely by vocabulary and truncated the
  # scan before the real AC section (WIL-77 retro, 2026-09-10; ac_count
  # reported 0, actual 6).
  prefix=$(sed -E '/^(#+ *|)(Steps to Repro|Reproduct|How to Repro|Reproduction Steps|To Reproduce|Background|Context|Environment|Notes|Setup|Prerequisites)/Iq' "$ctx" 2>/dev/null || true)
  if [ -z "$prefix" ]; then
    # sed failed or file is entirely repro steps — count from whole file as fallback
    prefix=$(cat "$ctx" 2>/dev/null || true)
  fi
  count=$(echo "$prefix" | grep -cP '^\s*(\d+\.\s|\- \[[ xX]\]\s)' 2>/dev/null || true)
  echo "${count//[^0-9]/}"
  return 0
}

# get_critique_warning_count <ticket-dir>
# Counts [WARNING] markers in the latest ## Readiness Critique section of notes.md.
# Emits integer count or empty string.
# Exit codes: 0 = found (may be 0), 1 = file unreadable, 2 = section not found
get_critique_warning_count() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  # Anchor on the LAST heading: a re-run appends a new section (see
  # get_critique_score), so the first one is superseded.
  local start_line
  start_line=$(grep -n '^## Readiness Critique' "$notes" 2>/dev/null | tail -1 | cut -d: -f1)
  if [ -z "$start_line" ]; then
    return 2
  fi

  local count
  count=$(tail -n "+$start_line" "$notes" 2>/dev/null |
    sed -n '1,/^## /p' |
    grep -c '\[WARNING\]' || true)
  echo "${count//[^0-9]/}"
  return 0
}

# get_critique_blocker_count <ticket-dir>
# Counts [BLOCKER] markers in the latest ## Readiness Critique section of notes.md.
# Emits integer count or empty string.
# Exit codes: 0 = found (may be 0), 1 = file unreadable, 2 = section not found
get_critique_blocker_count() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  # Anchor on the LAST heading: a re-run appends a new section (see
  # get_critique_score), so the first one is superseded.
  local start_line
  start_line=$(grep -n '^## Readiness Critique' "$notes" 2>/dev/null | tail -1 | cut -d: -f1)
  if [ -z "$start_line" ]; then
    return 2
  fi

  local count
  count=$(tail -n "+$start_line" "$notes" 2>/dev/null |
    sed -n '1,/^## /p' |
    grep -c '\[BLOCKER\]' || true)
  echo "${count//[^0-9]/}"
  return 0
}

# resolve_test_user_catalog [tickets_root]
# Resolves the path to test-users.json. NOT bundled with the plugin — must be
# created per-project. Copy config/test-users.example.json and populate with
# real credentials in your TICKETS_ROOT or installed plugin config dir.
# Priority: $TICKETS_ROOT/test-users.json → $CLAUDE_PLUGIN_ROOT/config/ → ~/.claude/skills/config/
# Emits absolute path or empty string if no catalog found (non-fatal).
# Exit codes: 0 = found, 1 = not found (non-fatal)
resolve_test_user_catalog() {
  local tickets_root="${1:-${TICKETS_ROOT:-.}}"

  # 1. Project-level override: check tickets root first
  if [ -f "$tickets_root/test-users.json" ]; then
    echo "$tickets_root/test-users.json"
    return 0
  fi

  # 2. Plugin default: check alongside other plugin config files
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/config/test-users.json" ]; then
    echo "$CLAUDE_PLUGIN_ROOT/config/test-users.json"
    return 0
  fi
  if [ -f "$HOME/.claude/skills/config/test-users.json" ]; then
    echo "$HOME/.claude/skills/config/test-users.json"
    return 0
  fi

  # 3. Check relative to this script (plugin lib dir → config dir)
  # test-users.json is not committed to the repo — this path resolves only for
  # local dev copies where the file was placed manually.
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$script_dir/../config/test-users.json" ]; then
    echo "$script_dir/../config/test-users.json"
    return 0
  fi

  return 1
}

# get_ticket_type <ticket-dir>
# Detects bug vs. feature from context.md labels.
# Emits "bug", "feature", or "unknown".
# Exit codes: 0 = found, 1 = file unreadable
get_ticket_type() {
  local ticket_dir="$1"
  local ctx="$ticket_dir/context.md"

  if [ ! -f "$ctx" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  # Check for bug label
  if grep -qiP '\*\*Labels?:?\*\*[^*]*bug' "$ctx" 2>/dev/null; then
    echo "bug"
    return 0
  fi

  # Check for feature/enhancement label
  if grep -qiP '\*\*Labels?:?\*\*[^*]*(feature|enhancement)' "$ctx" 2>/dev/null; then
    echo "feature"
    return 0
  fi

  # Check description for bug indicators (no label but reads like a bug)
  if grep -qiP '(bug|defect|broken|not working|error|crash|regression)' "$ctx" 2>/dev/null; then
    # Weak signal — only use if no feature indicators present
    if ! grep -qiP '(feature|enhancement|new |add |implement|build|create)' "$ctx" 2>/dev/null; then
      echo "bug"
      return 0
    fi
  fi

  echo "feature"
  return 0
}

# get_has_repro_steps <ticket-dir>
# Detects whether the ticket has reproduction steps for bug verification.
# Checks context.md for numbered browser-action steps or a repro section heading.
# Emits "true" or "false".
# Exit codes: 0 = checked, 1 = file unreadable
get_has_repro_steps() {
  local ticket_dir="$1"
  local ctx="$ticket_dir/context.md"

  if [ ! -f "$ctx" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  # Pattern 1: "Steps to reproduce" or "Reproduction" heading
  if grep -qiP '(steps to repro|reproduc|how to repro|reproduction steps|to reproduce)' "$ctx" 2>/dev/null; then
    echo "true"
    return 0
  fi

  # Pattern 2: At least 2 sequential numbered lines with browser action verbs
  local numbered_count
  numbered_count=$(grep -ciP '^\s*\d+[\.\)]\s+(Go to|Navigate|Click|Open|Log in|Select|Type|Enter|Press|Choose|Check|Verify|See|Observe|Confirm)' "$ctx" 2>/dev/null || true)
  if [ "${numbered_count//[^0-9]/}" -ge 2 ] 2>/dev/null; then
    echo "true"
    return 0
  fi

  # Pattern 3: Checkbox repro steps with action verbs
  local checkbox_count
  checkbox_count=$(grep -ciP '^\s*- \[[ xX]\]\s*(Go to|Navigate|Click|Open|Log in|Select|Type|Enter)' "$ctx" 2>/dev/null || true)
  if [ "${checkbox_count//[^0-9]/}" -ge 2 ] 2>/dev/null; then
    echo "true"
    return 0
  fi

  echo "false"
  return 0
}

# get_critique_has_finding <ticket-dir> <pattern>
# Checks if the ## Readiness Critique section contains a finding matching pattern.
# Used for cross-validation: verify the plan addresses gaps the critique flagged.
# Exit codes: 0 = found, 1 = not found / file missing / section absent
get_critique_has_finding() {
  local ticket_dir="$1"
  local pattern="$2"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  local start_line
  start_line=$(grep -n '^## Readiness Critique' "$notes" 2>/dev/null | tail -1 | cut -d: -f1)
  if [ -z "$start_line" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  # A line matching the pattern but explicitly qualified N/A (e.g. "No
  # navigation path, but N/A — build-validation ticket with no UI") is a
  # disposition, not a live finding: the critique is documenting that the
  # check doesn't apply to this ticket, not flagging a gap. Only count
  # matches that aren't qualified N/A on the same line.
  grep -qvi 'N/A' < <(tail -n "+$start_line" "$notes" 2>/dev/null | sed -n '1,/^## /p' | grep "$pattern" 2>/dev/null)
}

# get_test_users_by_role <role> [catalog_path]
# Queries the test user catalog for all users with the given role.
# Resolves catalog path if not provided.
# Emits JSON array of matching user objects, or empty array if none found.
# Exit codes: 0 = success (may be empty), 1 = no catalog file
get_test_users_by_role() {
  local role="$1"
  local catalog_path="${2:-}"

  if [ -z "$catalog_path" ]; then
    catalog_path=$(resolve_test_user_catalog 2>/dev/null || true)
  fi

  if [ -z "$catalog_path" ] || [ ! -f "$catalog_path" ]; then
    echo "[]"
    error_return 12 "notes-parse: file not found"
  fi

  jq -c --arg role "$role" '[.[] | select(.roles[]? == $role)]' "$catalog_path" 2>/dev/null || echo "[]"
}

# get_test_users_by_env <env> [catalog_path]
# Queries the test user catalog for all users available in the given environment.
# Resolves catalog path if not provided.
# Emits JSON array of matching user objects, or empty array if none found.
# Exit codes: 0 = success (may be empty), 1 = no catalog file
get_test_users_by_env() {
  local env="$1"
  local catalog_path="${2:-}"

  if [ -z "$catalog_path" ]; then
    catalog_path=$(resolve_test_user_catalog 2>/dev/null || true)
  fi

  if [ -z "$catalog_path" ] || [ ! -f "$catalog_path" ]; then
    echo "[]"
    error_return 12 "notes-parse: file not found"
  fi

  jq -c --arg env "$env" '[.[] | select(.environments[]? == $env)]' "$catalog_path" 2>/dev/null || echo "[]"
}

# get_blast_radius_override <ticket-dir>
# Applies ticket-appraise Step 2.8's complexity-override thresholds to the
# LAST `## Blast Radius` table in notes.md, deterministically:
#   - any target with Risk HIGH or CRITICAL          -> override
#   - any target with 3+ d=1 callers                 -> override, UNLESS that
#     row's Edit column is `additive`
#   - 2+ distinct execution flows across all targets -> override
# Test code is not production blast radius (issue #762), so it is left out of
# both counts, on evidence in the table only:
#   - a flow is skipped when its text names a test file or directory
#     (`x.test.js`, `x.spec.ts`, `x_test.go`, `test_x.py`, `XTest.java`,
#     `test/`, `tests/`, `__tests__/`, `spec/`) or its name is a test's
#     ("smoke test", "store wiring tests", "test harness", "supertest suite");
#   - a d=1 count drops the test files listed in the cell's parentheses, and
#     only when that list enumerates every caller (entries == count). A bare
#     `5 callers`, or a partial list, keeps the stated count.
# The Edit column (`additive` | `modifying`) is the appraiser's judgement of
# whether the planned edit to that target can change any existing caller's
# behaviour. Purely additive edits (new union members, new case/switch arms
# placed before an unchanged default, new optional params, new exports)
# cannot, so their caller count is not evidence of risk — and when it came
# from the impact-data local-grep fallback it is a file count, not a
# call-graph edge count, i.e. already an upper bound. A missing or
# unrecognised Edit cell is treated as `modifying`, so a table written before
# the column existed keeps the old (stricter) rule. The exemption applies to
# the caller-count trigger ONLY: the risk and flow triggers still fire for an
# additive row.
# Emits three KEY=value lines:
#   BLAST_OVERRIDE=complex|none
#   BLAST_REASON=<"; "-joined trigger reasons, empty when none>
#   BLAST_ADDITIVE_SKIP=<"; "-joined "{symbol} ({n} callers)", empty when none>
# Exit codes: 0 = section parsed, 2 = section absent, 12 = notes.md missing
get_blast_radius_override() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  local start_line
  start_line=$(grep -n '^## Blast Radius' "$notes" 2>/dev/null | tail -1 | cut -d: -f1 || true)
  if [ -z "$start_line" ]; then
    return 2
  fi

  tail -n "+$((start_line + 1))" "$notes" 2>/dev/null | tr -d '\r' |
    sed -n '1,/^## /p' |
    awk -F'|' -v q="'" '
      function trim(s) { gsub(/^[ \t`]+|[ \t`]+$/, "", s); return s }
      function join(acc, item) { return acc == "" ? item : acc "; " item }
      # is_test_path(s): s names a test file or a test directory.
      function is_test_path(s,  l) {
        if (s ~ /[a-z0-9]Tests?\.(java|kt|cs|scala|groovy)/) return 1
        l = tolower(s)
        return l ~ /[._-](test|spec)s?\.[a-z0-9]+/ || l ~ /(^|[^a-z0-9_])test_[a-z0-9_]+\.py/ ||
          l ~ /(^|[^a-z0-9_.-])(tests?|__tests__|specs?)\//
      }
      # is_test_name(n): n (lower case, parentheses removed) is the name of a
      # test, not of a flow that merely ends in the word: "tests", "test
      # suite", "test harness" or "<kind> test". "a/b test" stays a flow.
      function is_test_name(n) {
        return n ~ /(^|[^a-z])(super)?tests$/ ||
          n ~ /(^|[^a-z])(super)?tests? (suites?|harness|runners?|cases?|files?|callers?)$/ ||
          n ~ /(^|[^a-z])(unit|integration|smoke|e2e|end-to-end|regression|acceptance|contract|snapshot) test$/
      }
      # split_top(s, out, seps): split s on any character of seps that is not
      # inside parentheses. Returns the item count.
      function split_top(s, out, seps,  i, c, depth, n, cur) {
        n = 0; cur = ""; depth = 0
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c == "(") depth++
          else if (c == ")" && depth > 0) depth--
          if (depth == 0 && index(seps, c)) { out[++n] = cur; cur = "" }
          else cur = cur c
        }
        out[++n] = cur
        return n
      }
      # test_callers(cell, d1): how many of the d1 callers are test files, when
      # the parenthesised list in the cell enumerates all d1 of them.
      function test_callers(cell, d1,  a, b, n, k, t, inner, tc) {
        a = index(cell, "("); if (!a) return 0
        inner = substr(cell, a + 1)
        b = match(inner, /\)[^)]*$/); if (b) inner = substr(inner, 1, b - 1)
        n = split_top(inner, tc, ",;")
        if (n != d1) return 0
        t = 0
        for (k = 1; k <= n; k++) if (is_test_path(tc[k])) t++
        return t
      }
      /^[ \t]*\|/ {
        # Header row: locate columns by name, so column order and extra
        # columns do not matter.
        if (!have_hdr) {
          for (i = 2; i < NF; i++) {
            h = tolower(trim($i))
            if (h ~ /^target/) c_t = i
            else if (h ~ /^risk/) c_r = i
            else if (h ~ /^d=1/) c_d1 = i
            else if (h ~ /flow/) c_f = i
            else if (h ~ /^edit/) c_e = i
          }
          have_hdr = 1
          next
        }
        if ($0 ~ /^[ \t]*\|[ \t:|-]+$/) next
        sym = c_t ? trim($c_t) : ""
        risk = c_r ? toupper(trim($c_r)) : ""
        d1 = 0
        if (c_d1 && match($c_d1, /[0-9]+/)) d1 = substr($c_d1, RSTART, RLENGTH) + 0
        if (d1 > 0) d1 -= test_callers($c_d1, d1)
        edit = c_e ? tolower(trim($c_e)) : ""
        if (risk ~ /(^|[^A-Z])(HIGH|CRITICAL)([^A-Z]|$)/)
          reason = join(reason, "risk " risk " (" sym ")")
        if (d1 >= 3) {
          if (edit == "additive")
            skip = join(skip, sym " (" d1 " callers)")
          else
            reason = join(reason, d1 " d=1 callers (" sym ")")
        }
        if (c_f) {
          # A flow may list its callers in parentheses, "Render (home, article)":
          # split outside them, or each comma inside would count as another
          # flow, and name the flow without them.
          n = split_top($c_f, parts, ",")
          for (j = 1; j <= n; j++) {
            f = parts[j]; gsub(/\([^)]*\)/, "", f)
            f = tolower(trim(f))
            if (f == "" || f == "none" || f == "-" || f == "n/a") continue
            if (is_test_path(parts[j]) || is_test_name(f)) continue
            if (!(f in flows)) { flows[f] = 1; nflows++ }
          }
        }
      }
      # Values carry symbol names (parentheses, semicolons, quotes), so each
      # is single-quoted for safe `eval` by the caller.
      function shq(s) { gsub(q, q "\\" q q, s); return q s q }
      END {
        if (nflows >= 2) reason = join(reason, nflows " execution flows")
        print "BLAST_OVERRIDE=" (reason == "" ? "none" : "complex")
        print "BLAST_REASON=" shq(reason)
        print "BLAST_ADDITIVE_SKIP=" shq(skip)
      }
    '
}
