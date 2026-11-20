#!/usr/bin/env bash
# Don't use set -e — the feedback writer sources functions that grep logs
# where no-match exit codes are expected.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "${LIB_DIR}/planned-feedback-write.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}

echo "=== planned-feedback-write.sh tests ==="

# --- Test 1: no-op when FROM_PLANNED is false ---
echo "--- Test 1: no-op for unplanned tickets ---"
FROM_PLANNED=false
log="${TMPDIR}/test1-pipeline.log"
touch "$log"
planned_feedback_write "TEST-1" "$log" || true
if ! grep -q 'planner-feedback' "$log" 2>/dev/null; then
  pass "no feedback emitted for unplanned ticket"
else
  fail "no feedback emitted" "unexpected feedback entry found"
fi

# --- Test 2: emits feedback when FROM_PLANNED is true ---
echo "--- Test 2: emits feedback for planned tickets ---"
FROM_PLANNED=true
log="${TMPDIR}/test2-pipeline.log"
echo "2026-07-21T00:00:00Z|META|outcome-label|info|Smooth" >"$log"
planned_feedback_write "TEST-2" "$log" || true
if grep -q '|META|planner-feedback|info|' "$log" 2>/dev/null; then
  pass "feedback entry emitted for planned ticket"
else
  fail "feedback entry emitted" "no planner-feedback entry found"
fi

# --- Test 3: payload is valid JSON ---
echo "--- Test 3: payload is valid JSON ---"
payload=$(grep '|META|planner-feedback|info|' "$log" | head -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}')
if echo "$payload" | jq -e . >/dev/null 2>&1; then
  pass "feedback payload is valid JSON"
else
  fail "feedback payload is valid JSON" "jq parse failed"
fi

# --- Test 4: payload has required fields ---
echo "--- Test 4: payload has required fields ---"
# confidence_predicted is null here: TEST-2 has no Planner Context anywhere
# (GitHub #768), so the key must be present but need not be non-null.
for field in confidence_actual outcome corrections_count files_changed services_touched decision_drift; do
  if echo "$payload" | jq -e ".${field} != null" >/dev/null 2>&1; then
    pass "  field '${field}' present"
  else
    fail "  field '${field}' present" "missing or null"
  fi
done
if echo "$payload" | jq -e 'has("confidence_predicted")' >/dev/null 2>&1; then
  pass "  field 'confidence_predicted' present"
else
  fail "  field 'confidence_predicted' present" "missing"
fi

# --- Test 5: confidence_actual computation ---
echo "--- Test 5: confidence computation ---"
actual=$(_compute_actual_confidence "Smooth" 0)
if [ "$actual" = "0.90" ]; then
  pass "Smooth + 0 corrections → 0.90"
else
  fail "Smooth + 0 corrections → 0.90" "got $actual"
fi

actual=$(_compute_actual_confidence "Rough" 2)
if [ "$actual" = "0.55" ]; then
  pass "Rough + 2 corrections → 0.55"
else
  fail "Rough + 2 corrections → 0.55" "got $actual"
fi

# --- Test 6: manifest-only planned check (tracker-planner-and-fallback-cutover, 3.14) ---
echo "--- Test 6: manifest-based planned detection, no live Linear read ---"
repos_root=$(mktemp -d)
(
  source "${LIB_DIR}/manifest-write.sh"
  REPOS_ROOT="$repos_root" write_ticket_manifest "TEST-6" "INIT-1" "feature" '[]' >/dev/null
)
FROM_PLANNED=false
log="${TMPDIR}/test6-pipeline.log"
echo "2026-07-21T00:00:00Z|META|outcome-label|info|Smooth" >"$log"
REPOS_ROOT="$repos_root" planned_feedback_write "TEST-6" "$log" || true
rm -rf "$repos_root"
if grep -q '|META|planner-feedback|info|' "$log" 2>/dev/null; then
  pass "feedback emitted for a manifest-backed planned ticket, FROM_PLANNED unset"
else
  fail "feedback emitted for a manifest-backed planned ticket" "no planner-feedback entry found"
fi

# --- Test 7: no manifest and FROM_PLANNED unset → no-op ---
echo "--- Test 7: no manifest, no FROM_PLANNED → no-op ---"
repos_root=$(mktemp -d)
FROM_PLANNED=false
log="${TMPDIR}/test7-pipeline.log"
touch "$log"
REPOS_ROOT="$repos_root" planned_feedback_write "TEST-7" "$log" || true
rm -rf "$repos_root"
if ! grep -q 'planner-feedback' "$log" 2>/dev/null; then
  pass "no feedback emitted with no manifest and FROM_PLANNED unset"
else
  fail "no feedback emitted" "unexpected feedback entry found"
fi

# --- Test 8: _adhoc manifest never emits feedback (Section 5 discriminator fix) ---
echo "--- Test 8: _adhoc manifest, no FROM_PLANNED → no-op ---"
repos_root=$(mktemp -d)
(
  source "${LIB_DIR}/manifest-write.sh"
  REPOS_ROOT="$repos_root" ensure_ticket_manifest "TEST-8" >/dev/null
)
FROM_PLANNED=false
log="${TMPDIR}/test8-pipeline.log"
echo "2026-09-28T00:00:00Z|META|outcome-label|info|Smooth" >"$log"
REPOS_ROOT="$repos_root" planned_feedback_write "TEST-8" "$log" || true
rm -rf "$repos_root"
if ! grep -q 'planner-feedback' "$log" 2>/dev/null; then
  pass "no feedback emitted for an _adhoc-initiative manifest"
else
  fail "no feedback emitted for an _adhoc-initiative manifest" "unexpected feedback entry found"
fi

# ── GitHub #768: local Planner Context, real files_changed, null not 0 ──────

# The payload of the last planner-feedback line of a log.
_payload() {
  grep '|META|planner-feedback|info|' "$1" | tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}'
}

# A reduced planned-ticket body: prose, then the block the planner writes.
_planned_body() {
  cat <<EOF
# Readers can browse the list

## Acceptance Criteria

- The list shows every item.

## Planner Context

**Schema-Version:** 1
**Initiative:** INIT-1
**Epic:** TEST-1
**Confidence:** $1
**Strategy:** Conservative
**Decision:** One package.
**Affected Services:** svc-a, svc-b
**Target Symbols:** listPage (new):svc-a/src/list.js
**Pre-approved:** false
**Generated:** 2026-01-01T00:00:00Z
**Regenerate:** false
EOF
}

# --- Test 9: Planner Context from the workspace context.md, no tracker ---
echo "--- Test 9: confidence from context.md with no tracker functions loaded ---"
if declare -f get_issue >/dev/null 2>&1; then
  fail "test precondition" "get_issue is loaded; the test needs a tracker-less shell"
fi
root9="${TMPDIR}/t9"
mkdir -p "$root9/logs" "$root9/TEST-9--readers-can-browse"
_planned_body 0.76 >"$root9/TEST-9--readers-can-browse/context.md"
log="$root9/logs/TEST-9-pipeline.log"
echo "2026-07-21T00:00:00Z|META|outcome-label|info|Smooth" >"$log"
(cd "$TMPDIR" && FROM_PLANNED=true REPOS_ROOT="" planned_feedback_write "TEST-9" "$log") || true
payload=$(_payload "$log")
got=$(echo "$payload" | jq -c '[.confidence_predicted, .decision_drift, .services_touched]' 2>/dev/null)
if [ "$got" = '[0.76,"minor",["svc-a","svc-b"]]' ]; then
  pass "context.md beside the log dir gives 0.76, drift minor, both services"
else
  fail "context.md fallback" "got $got"
fi

# From the cwd too (the router runs from the tickets root).
log="${TMPDIR}/t9-elsewhere-pipeline.log"
echo "2026-07-21T00:00:00Z|META|outcome-label|info|Smooth" >"$log"
(cd "$root9" && FROM_PLANNED=true REPOS_ROOT="" planned_feedback_write "TEST-9" "$log") || true
got=$(_payload "$log" | jq -c '.confidence_predicted' 2>/dev/null)
if [ "$got" = "0.76" ]; then
  pass "context.md under the cwd gives 0.76"
else
  fail "context.md under the cwd" "got $got"
fi

# --- Test 10: the planner's own body.md is read before context.md ---
echo "--- Test 10: planner body.md under the initiative ---"
root10="${TMPDIR}/t10"
mkdir -p "$root10/repos/.ticket-auto/initiatives/INIT-1/tickets/TEST-10/planner" "$root10/tickets/logs" "$root10/tickets/TEST-10--x"
_planned_body 0.71 >"$root10/repos/.ticket-auto/initiatives/INIT-1/tickets/TEST-10/planner/body.md"
_planned_body 0.5 >"$root10/tickets/TEST-10--x/context.md"
log="$root10/tickets/logs/TEST-10-pipeline.log"
echo "2026-07-21T00:00:00Z|META|outcome-label|info|Smooth" >"$log"
(cd "$root10/tickets" && FROM_PLANNED=true REPOS_ROOT="$root10/repos" planned_feedback_write "TEST-10" "$log") || true
got=$(_payload "$log" | jq -c '.confidence_predicted' 2>/dev/null)
if [ "$got" = "0.71" ]; then
  pass "body.md gives 0.71"
else
  fail "planner body.md" "got $got"
fi

# --- Test 11: unknown confidence is null/unknown, never 0/major ---
echo "--- Test 11: no Planner Context anywhere ---"
root11="${TMPDIR}/t11"
mkdir -p "$root11/logs" "$root11/TEST-11--x"
printf '# A ticket\n\nNo planner block here.\n' >"$root11/TEST-11--x/context.md"
log="$root11/logs/TEST-11-pipeline.log"
echo "2026-07-21T00:00:00Z|META|outcome-label|info|Smooth" >"$log"
(cd "$root11" && FROM_PLANNED=true REPOS_ROOT="" planned_feedback_write "TEST-11" "$log") || true
got=$(_payload "$log" | jq -c '[.confidence_predicted, .decision_drift, .confidence_actual]' 2>/dev/null)
if [ "$got" = '[null,"unknown",0.90]' ] || [ "$got" = '[null,"unknown",0.9]' ]; then
  pass "no block gives null and unknown"
else
  fail "unknown confidence" "got $got"
fi

# A block whose Confidence is not a number is unknown too.
_planned_body "high" >"$root11/TEST-11--x/context.md"
log="$root11/logs/TEST-11b-pipeline.log"
echo "2026-07-21T00:00:00Z|META|outcome-label|info|Smooth" >"$log"
(cd "$root11" && FROM_PLANNED=true REPOS_ROOT="" planned_feedback_write "TEST-11" "$log") || true
got=$(_payload "$log" | jq -c '[.confidence_predicted, .decision_drift]' 2>/dev/null)
if [ "$got" = '[null,"unknown"]' ]; then
  pass "non-numeric Confidence gives null and unknown"
else
  fail "non-numeric Confidence" "got $got"
fi

if [ "$(_compute_decision_drift 0.90 0.90)" = "none" ] && [ "$(_compute_decision_drift 0.5 0.90)" = "major" ] &&
  [ "$(_compute_decision_drift null 0.90)" = "unknown" ] && [ "$(_compute_decision_drift "" 0.90)" = "unknown" ]; then
  pass "drift labels: none, major, unknown"
else
  fail "drift labels" "unexpected label"
fi

# --- Test 12: files_changed from the ticket worktree against a develop base ---
echo "--- Test 12: files changed on the ticket branch, base develop ---"
root12="${TMPDIR}/t12"
wt12="$root12/repos/.ticket-auto/worktrees/TEST-12/svc-a"
mkdir -p "$wt12" "$root12/tickets/logs"
(
  cd "$wt12" || exit 1
  git init -q -b develop .
  git config user.email t@example.invalid
  git config user.name t
  echo base >README.md
  git add README.md
  git commit -q -m base
  git checkout -q -b feat/TEST-12-list
  mkdir -p src
  echo list >src/list.js
  echo more >>README.md
  git add -A
  git commit -q -m change
) >/dev/null 2>&1
log="$root12/tickets/logs/TEST-12-pipeline.log"
{
  echo "2026-07-21T00:00:00Z|META|branch-context|info|base=develop;integration=develop;source=default;ticket=feat/TEST-12-list;uat-policy=per-ticket;merge-policy="
  echo "2026-07-21T00:00:00Z|META|outcome-label|info|Smooth"
} >"$log"
(cd "$root12/tickets" && FROM_PLANNED=true REPOS_ROOT="$root12/repos" planned_feedback_write "TEST-12" "$log") || true
got=$(_payload "$log" | jq -c '.files_changed' 2>/dev/null)
if [ "$got" = '["svc-a/README.md","svc-a/src/list.js"]' ]; then
  pass "both changed files listed, prefixed with the repo name"
else
  fail "files_changed from the worktree" "got $got"
fi

# A base that only exists as origin/<base> is used as well.
(
  cd "$wt12" || exit 1
  git update-ref refs/remotes/origin/develop develop
  git checkout -q --detach
  git branch -q -D develop
) >/dev/null 2>&1
log="$root12/tickets/logs/TEST-12b-pipeline.log"
{
  echo "2026-07-21T00:00:00Z|META|branch-context|info|base=develop;integration=develop;source=default;ticket=feat/TEST-12-list;uat-policy=per-ticket;merge-policy="
  echo "2026-07-21T00:00:00Z|META|outcome-label|info|Smooth"
} >"$log"
(cd "$root12/tickets" && FROM_PLANNED=true REPOS_ROOT="$root12/repos" planned_feedback_write "TEST-12" "$log") || true
got=$(_payload "$log" | jq -c '.files_changed' 2>/dev/null)
if [ "$got" = '["svc-a/README.md","svc-a/src/list.js"]' ]; then
  pass "origin/develop is used when there is no local develop"
else
  fail "files_changed against origin/develop" "got $got"
fi

# A branch name that is an option or a range is never passed to git.
if ! _pfw_git_ref_ok "--output=x" && ! _pfw_git_ref_ok "a..b" && ! _pfw_git_ref_ok 'a;b' && _pfw_git_ref_ok "feat/TEST-12-list"; then
  pass "branch names are checked before git runs"
else
  fail "branch name check" "an unsafe name was accepted or a plain one refused"
fi

# --- Test 13: the tracker description still wins when its functions are loaded ---
echo "--- Test 13: tracker read, when available, comes first ---"
got=$(
  cd "$root9" || exit 1
  get_issue() { jq -nc --arg d "$(_planned_body 0.91)" '{description: $d}'; }
  tracker_read() {
    shift 2
    [ "$1" = "--" ] && shift
    "$@"
  }
  log="${TMPDIR}/t13-pipeline.log"
  echo "2026-07-21T00:00:00Z|META|outcome-label|info|Smooth" >"$log"
  FROM_PLANNED=true REPOS_ROOT="" planned_feedback_write "TEST-9" "$log" || true
  _payload "$log" | jq -c '[.confidence_predicted, .decision_drift]'
)
if [ "$got" = '[0.91,"none"]' ]; then
  pass "tracker description gives 0.91"
else
  fail "tracker description first" "got $got"
fi

# A failed tracker read falls back to the local copy.
got=$(
  cd "$root9" || exit 1
  get_issue() { return 1; }
  tracker_read() {
    echo "$2"
    return 1
  }
  log="${TMPDIR}/t13b-pipeline.log"
  echo "2026-07-21T00:00:00Z|META|outcome-label|info|Smooth" >"$log"
  FROM_PLANNED=true REPOS_ROOT="" planned_feedback_write "TEST-9" "$log" || true
  _payload "$log" | jq -c '.confidence_predicted'
)
if [ "$got" = "0.76" ]; then
  pass "failed tracker read falls back to context.md"
else
  fail "tracker failure fallback" "got $got"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
