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

# Scratch files (env.sh, spawn-meta) live in the private dir lib/ticket-tmp.sh
# resolves (GitHub #619); point it at a dir this suite owns.
TICKET_TMP_DIR=$(mktemp -d)
export TICKET_TMP_DIR
ROUTER_SKILL="$LIB_DIR/../skills/ticket-auto/SKILL.md"

_TMPDIR=$(mktemp -d)
_cleanup() {
  rm -rf "$_TMPDIR" 2>/dev/null || true
  rm -rf "$TICKET_TMP_DIR" 2>/dev/null || true
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
  grep -q '^AGENT_PROMPT=Run /ticket-auto-pipeline:ticket-implement TEST-569 ' <<<"$out"
}

# GitHub #602: a phase agent type has no Skill tool, so it finds SKILL.md on
# disk and could pick a stale ~/.claude/skills/<name>/SKILL.md even with the
# qualified name. spawn_agent_pre must name the installed plugin's file.
# _fake_home <dir> [installed=1] — a HOME holding a stale personal copy and,
# optionally, an installed plugin version recorded in installed_plugins.json.
_fake_home() {
  local h="$1"
  mkdir -p "$h/.claude/skills/ticket-gate-reconcile"
  echo "STALE personal copy" >"$h/.claude/skills/ticket-gate-reconcile/SKILL.md"
  [ "${2:-1}" = 1 ] || return 0
  local inst="$h/.claude/plugins/cache/willard-pro-claude-plugins/ticket-auto-pipeline/9.9.9"
  mkdir -p "$inst/skills/ticket-gate-reconcile"
  echo "installed copy" >"$inst/skills/ticket-gate-reconcile/SKILL.md"
  cat >"$h/.claude/plugins/installed_plugins.json" <<EOF
{"plugins": {"ticket-auto-pipeline@willard-pro-claude-plugins": [{"installPath": "$inst"}]}}
EOF
}

_prompt_with_home() {
  local h="$1" log="$_TMPDIR/TEST-569-pipeline.log"
  touch "$log"
  (
    export HOME="$h" SPAWN_PLUGIN_ROOT_FILE="${SPAWN_PLUGIN_ROOT_FILE:-$h/no-plugin-root}"
    # shellcheck source=/dev/null
    source "$LIB_DIR/spawn-helper.sh" >/dev/null 2>&1
    unset HB_LOG_FILE
    spawn_agent_pre PHASE=GATE STEP=gate-reconcile TICKET_ID=TEST-569 \
      LOG_FILE="$log" SKILL=/ticket-auto-pipeline:ticket-gate-reconcile 2>/dev/null
  ) | grep '^AGENT_PROMPT='
}

test_spawn_prompt_pins_installed_skill_file() {
  local h="$_TMPDIR/home-installed" out want
  _fake_home "$h" 1
  want="$h/.claude/plugins/cache/willard-pro-claude-plugins/ticket-auto-pipeline/9.9.9/skills/ticket-gate-reconcile/SKILL.md"
  out=$(_prompt_with_home "$h")
  if ! grep -qF "The skill's instructions are the file ${want}: read that exact file" <<<"$out"; then
    echo "  prompt does not pin $want:" >&2
    echo "  $out" >&2
    return 1
  fi
  # The stale personal copy is named only as the one NOT to use.
  ! grep -qF "file $h/.claude/skills/ticket-gate-reconcile/SKILL.md" <<<"$out"
}

test_spawn_prompt_unpinned_when_not_installed() {
  local h="$_TMPDIR/home-bare" out
  _fake_home "$h" 0
  out=$(_prompt_with_home "$h")
  grep -q '^AGENT_PROMPT=Run /ticket-auto-pipeline:ticket-gate-reconcile TEST-569 --from-auto\. Before starting' <<<"$out"
}

test_skill_file_ignores_foreign_skills() {
  local h="$_TMPDIR/home-foreign"
  _fake_home "$h" 1
  (
    export HOME="$h" SPAWN_PLUGIN_ROOT_FILE="${SPAWN_PLUGIN_ROOT_FILE:-$h/no-plugin-root}"
    # shellcheck source=/dev/null
    source "$LIB_DIR/spawn-helper.sh" >/dev/null 2>&1
    declare -f spawn_skill_file >/dev/null &&
      [ -n "$(spawn_skill_file /ticket-auto-pipeline:ticket-gate-reconcile)" ] &&
      [ -z "$(spawn_skill_file /opsx:apply)" ] &&
      [ -z "$(spawn_skill_file /ticket-gate-reconcile)" ] &&
      [ -z "$(spawn_skill_file /ticket-auto-pipeline:../x)" ]
  )
}

# The plugin root the SessionStart sync recorded wins over tap_cache_find, so
# the pinned SKILL.md and the synced libs come from one plugin version.
test_plugin_root_pin_beats_cache() {
  local h="$_TMPDIR/home-root" root="$_TMPDIR/dev-plugin" out
  _fake_home "$h" 1
  mkdir -p "$root/skills/ticket-gate-reconcile"
  echo "dev copy" >"$root/skills/ticket-gate-reconcile/SKILL.md"
  printf '%s\n' "$root" >"$_TMPDIR/plugin-root"
  out=$(SPAWN_PLUGIN_ROOT_FILE="$_TMPDIR/plugin-root" _prompt_with_home "$h")
  grep -qF "the file $root/skills/ticket-gate-reconcile/SKILL.md: read that exact file" <<<"$out" || return 1
  # A recorded root without the skill falls back to the cache.
  printf '%s\n' "$_TMPDIR/nowhere" >"$_TMPDIR/plugin-root"
  out=$(SPAWN_PLUGIN_ROOT_FILE="$_TMPDIR/plugin-root" _prompt_with_home "$h")
  grep -qF "ticket-auto-pipeline/9.9.9/skills/ticket-gate-reconcile/SKILL.md: read" <<<"$out"
}

# The SessionStart sync command records CLAUDE_PLUGIN_ROOT next to the libs.
test_session_start_sync_records_plugin_root() {
  local h="$_TMPDIR/home-sync" cmd
  mkdir -p "$h"
  cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$LIB_DIR/../.claude-plugin/plugin.json")
  HOME="$h" CLAUDE_PLUGIN_ROOT="$(cd "$LIB_DIR/.." && pwd)" bash -c "$cmd" >/dev/null 2>&1
  [ "$(cat "$h/.claude/skills/lib/.plugin-root" 2>/dev/null)" = "$(cd "$LIB_DIR/.." && pwd)" ] &&
    [ -f "$h/.claude/skills/lib/spawn-helper.sh" ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"
for fn in \
  test_router_skill_has_no_bare_skill_args \
  test_router_skill_has_no_bare_run_instruction \
  test_qualify_bare_names \
  test_qualify_leaves_qualified_and_foreign_names \
  test_plugin_skill_list_matches_skills_dir \
  test_spawn_agent_pre_prompt_is_qualified \
  test_spawn_prompt_pins_installed_skill_file \
  test_spawn_prompt_unpinned_when_not_installed \
  test_skill_file_ignores_foreign_skills \
  test_plugin_root_pin_beats_cache \
  test_session_start_sync_records_plugin_root; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
