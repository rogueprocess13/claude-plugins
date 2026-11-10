#!/usr/bin/env bash
# test-plan-artifact-callers.sh — the callers of the one plan-artifact
# resolver (lib/ticket-dir.sh, review findings DET-IP-2 / DET-AP-4 / DET-IP-13).
#
#   1. ticket-gate-reconcile's plan resolution runs for real:
#      lib/gate-reconcile-prep.sh (skill-deterministic-extraction 6a, which
#      replaced the Step 1 fences this test used to extract from SKILL.md)
#      runs in a fixture tickets repo. Guards DET-IP-13 (NOTES_PATH read
#      before it was set, so an openspec ticket with no EXEC line resolved to
#      simple-fix.md) and the whole-ID change-dir match.
#   2. A lint over every SKILL.md: no substring plan-artifact lookup
#      (`grep -i "{ticket-id-lowercase}"`, `-path "*{TICKET-ID}*"`) survives.
#
# Usage: bash test-plan-artifact-callers.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
SKILLS_DIR="$PLUGIN_DIR/skills"
GR_SKILL="$SKILLS_DIR/ticket-gate-reconcile/SKILL.md"

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

# Runs lib/gate-reconcile-prep.sh for <tid> inside <tickets-repo> (comments
# from an empty list, scratch dir private) and prints its ARTIFACT_TYPE /
# ARTIFACT_PATH lines. Exit = the script's exit status.
_run_gr_step1() {
  local tid="$1" ws="$2"
  mkdir -p -m 700 "$ws/.scratch"
  echo '[]' >"$ws/.comments.json"
  (cd "$ws" && env -u LINEAR_API_KEY HOME="$ws" TICKET_TMP_DIR="$ws/.scratch" \
    bash "$LIB_DIR/gate-reconcile-prep.sh" "$tid" --comments-file .comments.json 2>/dev/null) |
    grep -E '^ARTIFACT_(TYPE|PATH)='
  return "${PIPESTATUS[0]}"
}

# The skill calls the script, not an inline resolver.
test_gr_skill_calls_prep() {
  grep -q 'lib/gate-reconcile-prep.sh {TICKET-ID}' "$GR_SKILL" &&
    ! grep -q 'resolve_plan_artifact' "$GR_SKILL"
}

# DET-IP-13: no EXEC create-artifact line, notes.md says openspec → openspec.
test_gr_notes_fallback_resolves_openspec() {
  local ws out rc=0
  ws=$(mktemp -d)
  mkdir -p "$ws/logs" "$ws/TEST-7--add-thing" "$ws/openspec/changes/test-7-add-thing"
  echo "1|META|schema|info|1" >"$ws/logs/TEST-7-pipeline.log"
  printf '## Complexity\n**Score:** complex\n\n- Artifact type: openspec\n' >"$ws/TEST-7--add-thing/notes.md"
  echo "- [ ] task" >"$ws/openspec/changes/test-7-add-thing/tasks.md"
  out=$(_run_gr_step1 TEST-7 "$ws") || rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ] &&
    grep -qx 'ARTIFACT_TYPE=openspec' <<<"$out" &&
    grep -qx 'ARTIFACT_PATH=openspec/changes/test-7-add-thing/tasks.md' <<<"$out"
}

# Whole-ID: TEST-7 must never amend test-77's tasks.md; it fails closed.
test_gr_openspec_whole_id_fails_closed() {
  local ws out rc=0 logged=0
  ws=$(mktemp -d)
  mkdir -p "$ws/logs" "$ws/TEST-7--add-thing" "$ws/openspec/changes/test-77-other"
  echo "1|EXEC|create-artifact|done|openspec" >"$ws/logs/TEST-7-pipeline.log"
  echo "- [ ] other" >"$ws/openspec/changes/test-77-other/tasks.md"
  out=$(_run_gr_step1 TEST-7 "$ws") || rc=$?
  grep -q '|GATE|reconcile|fail|' "$ws/logs/TEST-7-pipeline.log" && logged=1
  rm -rf "$ws"
  [ "$rc" -eq 1 ] && [ "$logged" -eq 1 ] && ! grep -q 'test-77' <<<"$out"
}

test_gr_simple_fix_path() {
  local ws out rc=0
  ws=$(mktemp -d)
  mkdir -p "$ws/logs" "$ws/TEST-7--fix"
  echo "1|EXEC|create-artifact|done|simple-fix" >"$ws/logs/TEST-7-pipeline.log"
  touch "$ws/TEST-7--fix/simple-fix.md"
  out=$(_run_gr_step1 TEST-7 "$ws") || rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ] &&
    grep -qx 'ARTIFACT_TYPE=simple-fix' <<<"$out" &&
    grep -qx 'ARTIFACT_PATH=./TEST-7--fix/simple-fix.md' <<<"$out"
}

# Lint: no SKILL.md keeps a substring plan-artifact lookup.
test_skills_have_no_substring_plan_lookup() {
  local hits
  hits=$(grep -rnE 'grep -i "?\{ticket-id-lowercase\}|-path "\*\{TICKET-ID\}\*"' \
    "$SKILLS_DIR" --include=SKILL.md || true)
  if [ -n "$hits" ]; then
    echo "$hits" >&2
    return 1
  fi
  return 0
}

_run "gate-reconcile skill runs gate-reconcile-prep.sh" test_gr_skill_calls_prep
_run "gate-reconcile: notes.md fallback resolves openspec (DET-IP-13)" test_gr_notes_fallback_resolves_openspec
_run "gate-reconcile: TEST-7 never resolves test-77 change dir" test_gr_openspec_whole_id_fails_closed
_run "gate-reconcile: simple-fix path" test_gr_simple_fix_path
_run "no SKILL.md keeps a substring plan-artifact lookup" test_skills_have_no_substring_plan_lookup

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
