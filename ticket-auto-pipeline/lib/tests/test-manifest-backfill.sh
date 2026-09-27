#!/usr/bin/env bash
# test-manifest-backfill.sh — unit tests for lib/manifest-backfill.sh
# (tracker-approval-by-script). Usage: bash test-manifest-backfill.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKFILL_SH="$LIB_DIR/manifest-backfill.sh"

PASS=0
FAIL=0
_pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_fail() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}

_new_workspace() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/lib" "$tmpdir/repos" "$tmpdir/logs"
  cp "$LIB_DIR/manifest-write.sh" "$LIB_DIR/manifest-read.sh" \
    "$LIB_DIR/planned-ticket-check.sh" "$LIB_DIR/branch-directive-check.sh" \
    "$LIB_DIR/epic-branch.sh" "$tmpdir/lib/"
  cat >"$tmpdir/lib/linear-api.sh" <<'STUBEOF'
get_issue() {
  case "$1" in
  WIL-1) jq -n '{id:"i1",identifier:"WIL-1",state:{name:"Ready"},labels:{nodes:[{name:"approved"},{name:"bug"},{name:"INIT-42"},{name:"blocked-by:WIL-9"},{name:"needs-info"}]}}' ;;
  WIL-2) jq -n '{id:"i2",identifier:"WIL-2",state:{name:"Backlog"},labels:{nodes:[]}}' ;;
  NOPE-1) return 1 ;;
  *) return 1 ;;
  esac
}
get_epics_by_label() {
  echo '[]'
}
STUBEOF
  echo "$tmpdir"
}

# ── seeds from a mocked get_issue ────────────────────────────────────────────

test_backfill_seeds_from_mocked_get_issue() {
  local ws
  ws=$(_new_workspace)
  touch "$ws/logs/WIL-1-pipeline.log" "$ws/logs/WIL-2-pipeline.log"

  local out rc=0
  out=$(CLAUDE_SKILLS_LIB="$ws/lib" REPOS_ROOT="$ws/repos" bash "$BACKFILL_SH" "$ws/logs" 2>&1) || rc=$?

  local m1 m2
  m1=$(find "$ws/repos" -path '*/WIL-1/planner/manifest.json' 2>/dev/null | head -1)
  m2=$(find "$ws/repos" -path '*/WIL-2/planner/manifest.json' 2>/dev/null | head -1)
  local approved1 stage1 stage2 approved2
  approved1=$(jq -r '.approved // empty' "$m1" 2>/dev/null)
  stage1=$(jq -r '.stage // empty' "$m1" 2>/dev/null)
  stage2=$(jq -r '.stage // empty' "$m2" 2>/dev/null)
  approved2=$(jq -r '.approved // empty' "$m2" 2>/dev/null)
  # tracker-planner-and-fallback-cutover (2.4): the four fields backfill now
  # also seeds from the same live labels — WIL-1's stub carries bug,
  # INIT-42, blocked-by:WIL-9 and needs-info.
  local type1 init1 blocked1 flags1
  type1=$(jq -r '.type // empty' "$m1" 2>/dev/null)
  init1=$(jq -r '.initiative // empty' "$m1" 2>/dev/null)
  blocked1=$(jq -c '.blocked_by // empty' "$m1" 2>/dev/null)
  flags1=$(jq -c '.flags // empty' "$m1" 2>/dev/null)
  rm -rf "$ws"

  if [ "$rc" -eq 0 ] && [ "$approved1" = "true" ] && [ "$stage1" = "Ready" ] &&
    [ "$stage2" = "Backlog" ] && [ -z "$approved2" ] &&
    [ "$type1" = "bug" ] && [ "$init1" = "INIT-42" ] &&
    [ "$blocked1" = '["WIL-9"]' ] && [ "$flags1" = '["needs-info"]' ] &&
    echo "$out" | grep -q "2 seeded, 0 already complete, 0 failed"; then
    _pass "manifest-backfill.sh: seeds approved+stage+type+initiative+blocked_by+flags from mocked get_issue"
  else
    _fail "manifest-backfill.sh: seeding mismatch (rc=$rc approved1=$approved1 stage1=$stage1 stage2=$stage2 approved2=$approved2 type1=$type1 init1=$init1 blocked1=$blocked1 flags1=$flags1 out=$out)"
  fi
}

# ── idempotency ───────────────────────────────────────────────────────────────

test_backfill_idempotent() {
  local ws
  ws=$(_new_workspace)
  touch "$ws/logs/WIL-1-pipeline.log" "$ws/logs/WIL-2-pipeline.log"

  CLAUDE_SKILLS_LIB="$ws/lib" REPOS_ROOT="$ws/repos" bash "$BACKFILL_SH" "$ws/logs" >/dev/null 2>&1
  local out rc=0
  out=$(CLAUDE_SKILLS_LIB="$ws/lib" REPOS_ROOT="$ws/repos" bash "$BACKFILL_SH" "$ws/logs" 2>&1) || rc=$?
  rm -rf "$ws"

  if [ "$rc" -eq 0 ] && echo "$out" | grep -q "0 seeded, 2 already complete, 0 failed"; then
    _pass "manifest-backfill.sh: second run is a no-op for every already-processed ticket"
  else
    _fail "manifest-backfill.sh: should be a no-op on re-run (rc=$rc out=$out)"
  fi
}

# ── dry-run writes nothing ───────────────────────────────────────────────────

test_backfill_dry_run_writes_nothing() {
  local ws
  ws=$(_new_workspace)
  touch "$ws/logs/WIL-1-pipeline.log"

  local out rc=0
  out=$(CLAUDE_SKILLS_LIB="$ws/lib" REPOS_ROOT="$ws/repos" bash "$BACKFILL_SH" --dry-run "$ws/logs" 2>&1) || rc=$?

  local manifest_count
  manifest_count=$(find "$ws/repos" -name manifest.json 2>/dev/null | wc -l | tr -d ' ')
  local index_count
  index_count=$(find "$ws/repos" -name '*.initiative' 2>/dev/null | wc -l | tr -d ' ')
  rm -rf "$ws"

  if [ "$rc" -eq 0 ] && [ "$manifest_count" -eq 0 ] && [ "$index_count" -eq 0 ] &&
    echo "$out" | grep -q "WOULD SEED" && echo "$out" | grep -q "dry-run"; then
    _pass "manifest-backfill.sh: --dry-run reports without writing any manifest or index file"
  else
    _fail "manifest-backfill.sh: --dry-run should write nothing (rc=$rc manifests=$manifest_count index=$index_count out=$out)"
  fi
}

# ── ad-hoc ticket handled ────────────────────────────────────────────────────

test_backfill_handles_adhoc_ticket() {
  local ws
  ws=$(_new_workspace)
  touch "$ws/logs/WIL-1-pipeline.log"
  # Deliberately no pre-seeded initiative index — WIL-1 is ad-hoc here.

  CLAUDE_SKILLS_LIB="$ws/lib" REPOS_ROOT="$ws/repos" bash "$BACKFILL_SH" "$ws/logs" >/dev/null 2>&1
  local rc=$?

  local init
  init=$(cat "$ws/repos/.ticket-auto/initiatives/_index/WIL-1.initiative" 2>/dev/null)
  local approved
  approved=$(jq -r '.approved // empty' "$ws/repos/.ticket-auto/initiatives/_adhoc/tickets/WIL-1/planner/manifest.json" 2>/dev/null)
  rm -rf "$ws"

  [ "$rc" -eq 0 ] && [ "$init" = "_adhoc" ] && [ "$approved" = "true" ] &&
    _pass "manifest-backfill.sh: provisions an ad-hoc ticket with no prior manifest" ||
    _fail "manifest-backfill.sh: should provision an ad-hoc ticket (rc=$rc init=$init approved=$approved)"
}

# ── get_issue failure is reported, not silently dropped ─────────────────────

test_backfill_reports_get_issue_failure() {
  local ws
  ws=$(_new_workspace)
  touch "$ws/logs/NOPE-1-pipeline.log"

  local out rc=0
  out=$(CLAUDE_SKILLS_LIB="$ws/lib" REPOS_ROOT="$ws/repos" bash "$BACKFILL_SH" "$ws/logs" 2>&1) || rc=$?
  rm -rf "$ws"

  echo "$out" | grep -q "0 seeded, 0 already complete, 1 failed" &&
    _pass "manifest-backfill.sh: a get_issue failure is counted as failed, not silently skipped" ||
    _fail "manifest-backfill.sh: expected 1 failed in summary (out=$out)"
}

# ── epic dispatch stamp (tracker-planner-and-fallback-cutover, 2.1/2.4) ────────

_EPIC_DIRECTIVE_DESC='## Branch Directive
**Schema-Version:** 1
**Branch:** epic/init-99
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** none
**Created:** 2026-09-01T00:00:00Z'

_new_workspace_with_epic() {
  local tmpdir
  tmpdir=$(_new_workspace)
  cat >>"$tmpdir/lib/linear-api.sh" <<STUBEOF
get_epics_by_label() {
  jq -n --arg desc "$_EPIC_DIRECTIVE_DESC" '[{"id":"e1","identifier":"INIT-99","description":\$desc,"state":{"name":"Backlog"},"children":{"nodes":[{"identifier":"WIL-1"}]}}]'
}
STUBEOF
  echo "$tmpdir"
}

test_backfill_stamps_epic_dispatch_from_state_execution() {
  local ws
  ws=$(_new_workspace_with_epic)
  # get_epics_by_label is redefined last in the appended file — bash keeps
  # only the final definition, overriding the "[]" stub from _new_workspace.

  local out rc=0
  out=$(CLAUDE_SKILLS_LIB="$ws/lib" REPOS_ROOT="$ws/repos" bash "$BACKFILL_SH" "$ws/logs" 2>&1) || rc=$?

  local m dispatch branch uat merge children
  m="$ws/repos/.ticket-auto/initiatives/INIT-99/epic/manifest.json"
  dispatch=$(jq -r '.dispatch // empty' "$m" 2>/dev/null)
  branch=$(jq -r '.branch // empty' "$m" 2>/dev/null)
  uat=$(jq -r '.uat_policy // empty' "$m" 2>/dev/null)
  merge=$(jq -r '.merge_policy // empty' "$m" 2>/dev/null)
  children=$(jq -c '.children // empty' "$m" 2>/dev/null)
  rm -rf "$ws"

  if [ "$rc" -eq 0 ] && [ "$dispatch" = "true" ] && [ "$branch" = "epic/init-99" ] &&
    [ "$uat" = "per-ticket" ] && [ "$merge" = "manual" ] && [ "$children" = '["WIL-1"]' ] &&
    echo "$out" | grep -q "1 seeded, 0 already complete, 0 failed"; then
    _pass "manifest-backfill.sh: stamps epic dispatch+directive+children from state:execution"
  else
    _fail "manifest-backfill.sh: epic stamp mismatch (rc=$rc dispatch=$dispatch branch=$branch uat=$uat merge=$merge children=$children out=$out)"
  fi
}

test_backfill_epic_dispatch_idempotent() {
  local ws
  ws=$(_new_workspace_with_epic)

  CLAUDE_SKILLS_LIB="$ws/lib" REPOS_ROOT="$ws/repos" bash "$BACKFILL_SH" "$ws/logs" >/dev/null 2>&1
  local out rc=0
  out=$(CLAUDE_SKILLS_LIB="$ws/lib" REPOS_ROOT="$ws/repos" bash "$BACKFILL_SH" "$ws/logs" 2>&1) || rc=$?
  rm -rf "$ws"

  if [ "$rc" -eq 0 ] && echo "$out" | grep -q "0 seeded, 1 already complete, 0 failed"; then
    _pass "manifest-backfill.sh: second run is a no-op for an already-stamped epic"
  else
    _fail "manifest-backfill.sh: epic stamp should be idempotent (rc=$rc out=$out)"
  fi
}

test_backfill_epic_dry_run_writes_nothing() {
  local ws
  ws=$(_new_workspace_with_epic)

  local out rc=0
  out=$(CLAUDE_SKILLS_LIB="$ws/lib" REPOS_ROOT="$ws/repos" bash "$BACKFILL_SH" --dry-run "$ws/logs" 2>&1) || rc=$?

  local manifest_count
  manifest_count=$(find "$ws/repos" -name manifest.json 2>/dev/null | wc -l | tr -d ' ')
  rm -rf "$ws"

  if [ "$rc" -eq 0 ] && [ "$manifest_count" -eq 0 ] &&
    echo "$out" | grep -q "epics (dry-run): 1 would be seeded"; then
    _pass "manifest-backfill.sh: --dry-run reports the epic stamp without writing it"
  else
    _fail "manifest-backfill.sh: --dry-run should not write the epic manifest (rc=$rc manifests=$manifest_count out=$out)"
  fi
}

# ── run ───────────────────────────────────────────────────────────────────────

test_backfill_seeds_from_mocked_get_issue
test_backfill_idempotent
test_backfill_dry_run_writes_nothing
test_backfill_handles_adhoc_ticket
test_backfill_reports_get_issue_failure
test_backfill_stamps_epic_dispatch_from_state_execution
test_backfill_epic_dispatch_idempotent
test_backfill_epic_dry_run_writes_nothing

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
