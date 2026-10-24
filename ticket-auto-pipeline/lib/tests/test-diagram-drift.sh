#!/usr/bin/env bash
# test-diagram-drift.sh — tests for skills/ticket-flow/check-diagram-drift.py,
# the drift gate between workflow.json's triggers and the public state diagram
# (docs/ticket-auto-pipeline-diagram.html), plus a wording guard that keeps
# approval-by-label instructions out of the user-facing docs.
#
# The gate is only worth something if it fires, so most cases here mutate a
# temp copy of the diagram or workflow.json and assert the check FAILS.
#
# Usage: bash test-diagram-drift.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-flow/check-diagram-drift.py"
WORKFLOW="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-flow/workflow.json"
DIAGRAM="$REPO_ROOT/docs/ticket-auto-pipeline-diagram.html"
FILTER="${1:-}"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
    return 0
  fi
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc)"
    ((FAIL++)) || true
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# _mutate_block <out-html> <python-statement>
# Rewrites the workflow-triggers JSON block of a copy of the real diagram. The
# statement sees the parsed block as `b`.
_mutate_block() {
  local out="$1" stmt="$2"
  python3 - "$DIAGRAM" "$out" "$stmt" <<'PY'
import json, re, sys
src, out, stmt = sys.argv[1], sys.argv[2], sys.argv[3]
html = open(src, encoding="utf-8").read()
pat = re.compile(r'(<script type="application/json" id="workflow-triggers">)(.*?)(</script>)', re.S)
m = pat.search(html)
b = json.loads(m.group(2))
exec(stmt)
html = html[:m.start(2)] + "\n" + json.dumps(b, indent=2) + "\n" + html[m.end(2):]
open(out, "w", encoding="utf-8").write(html)
PY
}

# _expect_rc <want> <stderr-substring|""> <args...>
_expect_rc() {
  local want="$1" needle="$2"
  shift 2
  local rc=0
  python3 "$CHECK" "$@" >"$TMP/out" 2>"$TMP/err" || rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "  expected exit $want, got $rc" >&2
    cat "$TMP/err" >&2
    return 1
  fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" "$TMP/err"; then
    echo "  stderr does not mention: $needle" >&2
    cat "$TMP/err" >&2
    return 1
  fi
}

test_real_diagram_in_sync() {
  _expect_rc 0 "" --workflow "$WORKFLOW" --diagram "$DIAGRAM"
}

test_missing_trigger_fails() {
  _mutate_block "$TMP/missing.html" 'del b["triggers"]["epic-uat-pass"]'
  _expect_rc 1 "trigger 'epic-uat-pass' is in workflow.json but missing from the diagram" \
    --workflow "$WORKFLOW" --diagram "$TMP/missing.html"
}

test_missing_side_trigger_fails() {
  _mutate_block "$TMP/missing-side.html" 'del b["triggers"]["needs-adr"]'
  _expect_rc 1 "trigger 'needs-adr' is in workflow.json but missing" \
    --workflow "$WORKFLOW" --diagram "$TMP/missing-side.html"
}

test_extra_trigger_fails() {
  _mutate_block "$TMP/extra.html" 'b["triggers"]["made-up"] = dict(b["triggers"]["uat-pass"])'
  _expect_rc 1 "trigger 'made-up' is in the diagram but not in workflow.json" \
    --workflow "$WORKFLOW" --diagram "$TMP/extra.html"
}

test_wrong_adds_fails() {
  _mutate_block "$TMP/adds.html" 'b["triggers"]["pr-review-fail"]["adds"] = []'
  _expect_rc 1 "trigger 'pr-review-fail': adds" \
    --workflow "$WORKFLOW" --diagram "$TMP/adds.html"
}

test_wrong_removes_fails() {
  _mutate_block "$TMP/removes.html" 'b["triggers"]["human-reject"]["removes"] = []'
  _expect_rc 1 "trigger 'human-reject': removes" \
    --workflow "$WORKFLOW" --diagram "$TMP/removes.html"
}

test_wrong_target_state_fails() {
  _mutate_block "$TMP/to.html" 'b["triggers"]["uat-pass"]["to"] = "Ready"'
  _expect_rc 1 "trigger 'uat-pass': to" \
    --workflow "$WORKFLOW" --diagram "$TMP/to.html"
}

test_edge_without_kind_fails() {
  _mutate_block "$TMP/kind.html" 'b["triggers"]["epic-uat-start"]["diagram"].pop("kind")'
  _expect_rc 1 "trigger 'epic-uat-start' changes state but diagram.kind" \
    --workflow "$WORKFLOW" --diagram "$TMP/kind.html"
}

test_side_without_description_fails() {
  _mutate_block "$TMP/side.html" 'b["triggers"]["re-claim"]["diagram"] = {}'
  _expect_rc 1 "trigger 're-claim' changes no state but has no diagram.side" \
    --workflow "$WORKFLOW" --diagram "$TMP/side.html"
}

test_blocked_state_required() {
  _mutate_block "$TMP/blocked.html" 'b["side_states"] = {}'
  _expect_rc 1 "well-known state 'Blocked'" \
    --workflow "$WORKFLOW" --diagram "$TMP/blocked.html"
}

test_new_workflow_trigger_fails() {
  python3 - "$WORKFLOW" "$TMP/workflow.json" <<'PY'
import json, sys
w = json.load(open(sys.argv[1]))
w["triggers"]["brand-new"] = {"from": "Review", "to": "Done", "adds": [], "removes": [],
                              "emits": {"event": "uat-passed", "data": {}}}
json.dump(w, open(sys.argv[2], "w"))
PY
  _expect_rc 1 "trigger 'brand-new' is in workflow.json but missing from the diagram" \
    --workflow "$TMP/workflow.json" --diagram "$DIAGRAM"
}

test_hand_written_transitions_fail() {
  sed 's|^  transitions: Object.entries|  transitions: [],\n  _unused: Object.entries|' "$DIAGRAM" >"$TMP/hand.html"
  _expect_rc 1 "hand-written 'transitions: ['" --workflow "$WORKFLOW" --diagram "$TMP/hand.html"
}

test_no_data_block_is_structural() {
  # The pre-WP-5 diagram shape: a hand-kept DATA.transitions list and no block.
  printf '<html><script>const DATA = { transitions: [] };</script></html>\n' >"$TMP/legacy.html"
  _expect_rc 2 "no <script type=\"application/json\" id=\"workflow-triggers\"> block" \
    --workflow "$WORKFLOW" --diagram "$TMP/legacy.html"
}

# Approval is a local manifest fact (tracker-approval-by-script). No user-facing
# doc may tell a reader to approve by adding, or to wait for, the `approved`
# label. CHANGELOG history and openspec archives are deliberately out of scope.
test_docs_do_not_teach_approval_by_label() {
  local hits
  hits=$(cd "$REPO_ROOT" && grep -n -i -E \
    '(add|adds|attach|attaches|receives?) (the )?`?approved`? label|human `?approved`? label|approved label (is still|was removed)' \
    README.md CLAUDE.md ./*/README.md ./*/CLAUDE.md docs/*.html \
    ticket-auto-pipeline/pipeline-log-format.md \
    $(find ticket-auto-pipeline/docs -name '*.md' -not -name 'label-audit.md') 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "  approval-by-label wording found:" >&2
    echo "$hits" >&2
    return 1
  fi
}

_run "real diagram is in sync with workflow.json" test_real_diagram_in_sync
_run "a missing state-changing trigger fails" test_missing_trigger_fails
_run "a missing side trigger fails" test_missing_side_trigger_fails
_run "an extra trigger fails" test_extra_trigger_fails
_run "wrong adds fail" test_wrong_adds_fails
_run "wrong removes fail" test_wrong_removes_fails
_run "wrong target state fails" test_wrong_target_state_fails
_run "an edge without a kind fails" test_edge_without_kind_fails
_run "a side trigger without a description fails" test_side_without_description_fails
_run "Blocked must be drawn or listed" test_blocked_state_required
_run "a trigger added to workflow.json fails until drawn" test_new_workflow_trigger_fails
_run "a hand-written transitions list fails" test_hand_written_transitions_fail
_run "a diagram without the data block is structural (exit 2)" test_no_data_block_is_structural
_run "docs do not teach approval by label" test_docs_do_not_teach_approval_by_label

echo
echo "test-diagram-drift: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
