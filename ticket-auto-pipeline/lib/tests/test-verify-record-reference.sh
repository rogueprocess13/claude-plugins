#!/usr/bin/env bash
# test-verify-record-reference.sh — ticket-verify's recording reference
# (openspec change ticket-auto-record, PR 2).
#
# Text tests for skills/ticket-verify/references/record.md and the one guarded
# line in SKILL.md that loads it, plus one run of the reference's own
# `record.sh append` command line against the real lib/record.sh, so the
# prose cannot drift away from the command it tells the agent to run.
# The references/ layout rules (manifest order, skill-ref.sh form) are
# test-skill-references.sh's; the size ratchet is scripts/check-skill-size.sh's.
# -u (nounset) intentionally omitted — see test-detect-resume.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
SKILL_MD="$LIB_DIR/../skills/ticket-verify/SKILL.md"
TABLE="$LIB_DIR/../skills/ticket-flow/dispatch-table.json"
BASELINE="$REPO_ROOT/scripts/skill-size-baseline.tsv"

# shellcheck source=skill-text.sh
source "$SCRIPT_DIR/skill-text.sh"
REF=$(_skill_ref_path ticket-verify/references/record.md)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Never let an operator's settings reach the code under test.
unset REPOS_ROOT FLEET_PIPELINE_LOG_DIR TAP_LOG LOG_FILE LOCAL_URL UAT_URL \
  RECORD_ALLOWED RECORD_UAT_SYNTHETIC RECORD_BOARD_URL RECORD_DISABLE

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# ── the reference ─────────────────────────────────────────────────────────────

test_ref_fixes_the_viewport() {
  grep -q 'mcp__playwright__browser_resize' "$REF" &&
    grep -q '1280' "$REF" && grep -q '800' "$REF" &&
    grep -q 'Before the first `mcp__playwright__browser_navigate`' "$REF"
}

test_ref_one_frame_per_settled_step() {
  grep -q 'mcp__playwright__browser_take_screenshot' "$REF" &&
    grep -qi 'each time a step has settled' "$REF"
}

test_ref_names_the_append_call() {
  local line
  line=$(grep -F 'record.sh append' "$REF" | grep -F 'bash ~/.claude/skills/lib/record.sh' | head -1)
  [ -n "$line" ] &&
    for flag in '--tid' '--phase verify' '--step' '--src' '--url'; do
      grep -qF -- "$flag" <<<"$line" || return 1
    done &&
    grep -q '|| true$' <<<"$line" &&
    grep -qF 'source ~/.claude/skills/lib/ticket-env.sh {TICKET-ID}' "$REF"
}

test_ref_password_rule() {
  local sec
  sec=$(_section "$REF" '^## Password rule' '^## ')
  grep -qi 'never take a recording frame' <<<"$sec" && grep -qi 'password' <<<"$sec" &&
    grep -qi 'skip' <<<"$sec"
}

test_ref_failures_never_change_the_verdict() {
  local sec
  sec=$(_section "$REF" '^## Failures are ignored' '^## ')
  grep -q 'never a reason for a FAIL' <<<"$sec" &&
    grep -qi 'do not write a pipeline log line' <<<"$sec" &&
    grep -qi 'never changes .*the verdict' "$REF"
}

test_ref_agent_never_touches_recordings_dir() {
  grep -q 'Never name, read, list or glob a file under `{ticket-dir}/artifacts/recordings/`' "$REF" &&
    # The evidence screenshot must not be handed over: append deletes the
    # source of a page it may not record.
    grep -q 'Never pass a Step 4b evidence screenshot' "$REF"
}

# Only the agent-side scratch name appears; destination names are record.sh's.
test_ref_names_no_destination_file() {
  ! grep -Eq 'verify-a[0-9{]|manifest\.jsonl' "$REF"
}

test_ref_follows_reference_rules() {
  local n
  n=$(wc -l <"$REF")
  { [ "$n" -le 100 ] || grep -q '^## Contents' "$REF"; } &&
    ! grep -Eq '(^|[^\\])\$(1|ARGUMENTS)\b' "$REF" &&
    ! grep -q 'references/' "$REF" # one level deep: links no other reference
}

# ── the SKILL.md line ─────────────────────────────────────────────────────────

_guard_line() { grep -F 'references/record.md' "$SKILL_MD" | grep -F 'skill-ref.sh' | head -1; }

test_skill_guard_line_standard_form() {
  local line
  line=$(_guard_line)
  [ -n "$line" ] &&
    grep -qF 'bash ~/.claude/skills/lib/record.sh enabled "$TAP_LOG"' <<<"$line" &&
    grep -qF 'VERIFY_MODE=browser' <<<"$line" &&
    grep -qF 'bash ~/.claude/skills/lib/skill-ref.sh ticket-verify references/record.md' <<<"$line" &&
    grep -qF 'Read the printed path in full' <<<"$line" &&
    grep -qF 'reference-missing fail "references/record.md"' <<<"$line" &&
    grep -q 'and stop\.' <<<"$line" &&
    # condition → path → resolver → read → stop, in that order
    awk -v l="$line" 'BEGIN {
      a = index(l, "If it prints"); b = index(l, "skill-ref.sh ticket-verify references/record.md")
      c = index(l, "Read the printed path"); d = index(l, "exits non-zero")
      exit !(a > 0 && a < b && b < c && c < d)
    }'
}

test_skill_guard_is_the_only_mention_and_before_step_3() {
  local at step3
  [ "$(grep -cF 'references/record.md' "$SKILL_MD")" -eq 1 ] || return 1
  at=$(grep -nF 'references/record.md' "$SKILL_MD" | head -1 | cut -d: -f1)
  step3=$(grep -n '^## Step 3 ' "$SKILL_MD" | head -1 | cut -d: -f1)
  [ -n "$at" ] && [ -n "$step3" ] && [ "$at" -lt "$step3" ]
}

test_manifest_lists_the_reference() {
  jq -e '.prompt_manifests["ticket-verify"].files
    | index("plugin:skills/ticket-verify/references/record.md") != null' "$TABLE" >/dev/null
}

# SKILL.md did not grow: its baseline entry carries no allow-growth line and
# the file still fits the entry.
test_skill_md_did_not_grow() {
  local rel=ticket-auto-pipeline/skills/ticket-verify/SKILL.md max_b max_l above bytes
  max_b=$(awk -F'\t' -v p="$rel" '$1 == p { print $2 }' "$BASELINE")
  max_l=$(awk -F'\t' -v p="$rel" '$1 == p { print $3 }' "$BASELINE")
  above=$(awk -F'\t' -v p="$rel" '$1 == p { print prev } { prev = $0 }' "$BASELINE")
  bytes=$(wc -c <"$SKILL_MD")
  [ -n "$max_b" ] && [ "$bytes" -le "$max_b" ] && [ "$max_b" -le 58395 ] && [ "$max_l" -le 948 ] &&
    [[ "$above" != *allow-growth* ]]
}

# ── the documented command runs ───────────────────────────────────────────────

# The reference's own append line, placeholders filled in, against the real
# record.sh: a local page yields the first frame of attempt 1.
test_documented_append_command_runs() {
  local root="$WORK/ws" line cmd out log
  mkdir -p "$root/CRE-12--demo-ticket" "$root/logs"
  log="$root/logs/CRE-12-pipeline.log"
  printf 'x|META|schema|info|1\nx|META|record|info|on\n' >"$log"
  printf 'PNGDATA' >"$root/record-CRE-12.png"
  line=$(grep -F 'bash ~/.claude/skills/lib/record.sh append' "$REF" | head -1)
  cmd=${line//'~/.claude/skills/lib'/$LIB_DIR}
  cmd=${cmd//'{TICKET-ID}'/CRE-12}
  cmd=${cmd//'<label>'/C1: total shows 120.00}
  cmd=${cmd//'<path reported by browser_take_screenshot>'/$root/record-CRE-12.png}
  cmd=${cmd//'<current page URL>'/http://localhost:4200/invoices?page=2}
  [[ "$cmd" != *'<'* && "$cmd" != *'{'* ]] || return 1
  out=$(REPOS_ROOT="$root" TAP_LOG="$log" LOCAL_URL=http://localhost:4200 RECORD_ALLOWED=local \
    bash -c "$cmd")
  [ "$out" = "ok verify-a1-001.png" ] &&
    [ -f "$root/CRE-12--demo-ticket/artifacts/recordings/verify-a1-001.png" ] &&
    [ "$(jq -r '.step' "$root/CRE-12--demo-ticket/artifacts/recordings/manifest.jsonl")" = "C1: total shows 120.00" ] &&
    [ "$(wc -l <"$log")" -eq 2 ] &&
    bash "$LIB_DIR/record.sh" enabled "$log"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  _run "$t" "$t"
done

echo ""
echo "test-verify-record-reference.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
