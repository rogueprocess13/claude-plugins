#!/usr/bin/env bash
# test-spawn-skill-qualified.sh — GitHub #569 regression tests.
#
# A bare skill name (/ticket-implement) resolves to a personal
# ~/.claude/skills/<name> copy before the plugin's own skill, so a stale
# personal copy silently shadows the phase skill in an interactive
# /ticket-auto run. Guards both layers of the fix:
#   1. skills/ticket-auto/SKILL.md passes plugin-qualified names to
#      spawn_agent_pre (no bare SKILL=/<name>, no bare "Run /ticket-...").
#   2. spawn_agent_pre itself qualifies a bare plugin skill name, so a
#      dispatch site that regresses still spawns the plugin skill.
# Usage: bash test-spawn-skill-qualified.sh [test_name_filter]
# -u (nounset) intentionally omitted (see sibling test files).
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROUTER_SKILL="$LIB_DIR/../skills/ticket-auto/SKILL.md"

_TMPDIR=$(mktemp -d)
_cleanup() {
  rm -rf "$_TMPDIR" 2>/dev/null || true
  rm -f /tmp/ticket-auto-TEST-569-* 2>/dev/null || true
}
trap _cleanup EXIT

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

# ── tests ──────────────────────────────────────────────────────────────────────

test_router_skill_has_no_bare_skill_args() {
  local bad
  bad=$(grep -nE 'SKILL=/[a-z]' "$ROUTER_SKILL" | grep -v 'SKILL=/ticket-auto-pipeline:' || true)
  if [ -n "$bad" ]; then
    echo "  bare SKILL= in ticket-auto/SKILL.md:" >&2
    echo "$bad" >&2
    return 1
  fi
}

test_router_skill_has_no_bare_run_instruction() {
  local bad
  bad=$(grep -nE 'Run /(ticket-|wiki-maintenance|guidance-extractor)' "$ROUTER_SKILL" |
    grep -vE 'Run /ticket-auto-pipeline:' || true)
  if [ -n "$bad" ]; then
    echo "  bare 'Run /<skill>' in ticket-auto/SKILL.md:" >&2
    echo "$bad" >&2
    return 1
  fi
}

test_qualify_bare_names() {
  (
    # shellcheck source=/dev/null
    source "$LIB_DIR/spawn-helper.sh" >/dev/null 2>&1
    [ "$(spawn_qualify_skill /ticket-implement)" = "/ticket-auto-pipeline:ticket-implement" ] &&
      [ "$(spawn_qualify_skill /wiki-maintenance)" = "/ticket-auto-pipeline:wiki-maintenance" ] &&
      [ "$(spawn_qualify_skill /guidance-extractor)" = "/ticket-auto-pipeline:guidance-extractor" ]
  )
}

test_qualify_leaves_qualified_and_foreign_names() {
  (
    # shellcheck source=/dev/null
    source "$LIB_DIR/spawn-helper.sh" >/dev/null 2>&1
    [ "$(spawn_qualify_skill /ticket-auto-pipeline:ticket-verify)" = "/ticket-auto-pipeline:ticket-verify" ] &&
      [ "$(spawn_qualify_skill /fleet-controller:fleet-controller)" = "/fleet-controller:fleet-controller" ] &&
      [ "$(spawn_qualify_skill /opsx:apply)" = "/opsx:apply" ] &&
      [ "$(spawn_qualify_skill /simplify)" = "/simplify" ] &&
      [ "$(spawn_qualify_skill /ticket-not-a-skill)" = "/ticket-not-a-skill" ]
  )
}

# SPAWN_PLUGIN_SKILLS must list exactly the skills this plugin ships.
test_plugin_skill_list_matches_skills_dir() {
  local want got
  want=$(find "$LIB_DIR/../skills" -mindepth 2 -maxdepth 2 -name SKILL.md -printf '%h\n' |
    xargs -n1 basename | sort | tr '\n' ' ')
  got=$(
    # shellcheck source=/dev/null
    source "$LIB_DIR/spawn-helper.sh" >/dev/null 2>&1
    tr ' ' '\n' <<<"$SPAWN_PLUGIN_SKILLS" | sed '/^$/d' | sort | tr '\n' ' '
  )
  if [ "$want" != "$got" ]; then
    echo "  skills/: $want" >&2
    echo "  list:    $got" >&2
    return 1
  fi
}

test_spawn_agent_pre_prompt_is_qualified() {
  local log="$_TMPDIR/TEST-569-pipeline.log" out
  touch "$log"
  out=$(
    # shellcheck source=/dev/null
    source "$LIB_DIR/spawn-helper.sh" >/dev/null 2>&1
    unset HB_LOG_FILE
    spawn_agent_pre PHASE=IMPLEMENT STEP=implement TICKET_ID=TEST-569 \
      LOG_FILE="$log" SKILL=/ticket-implement 2>/dev/null
  )
  echo "$out" | grep -q '^AGENT_PROMPT=Run /ticket-auto-pipeline:ticket-implement TEST-569 '
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"
for fn in \
  test_router_skill_has_no_bare_skill_args \
  test_router_skill_has_no_bare_run_instruction \
  test_qualify_bare_names \
  test_qualify_leaves_qualified_and_foreign_names \
  test_plugin_skill_list_matches_skills_dir \
  test_spawn_agent_pre_prompt_is_qualified; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
