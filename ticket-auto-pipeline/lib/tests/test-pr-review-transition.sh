#!/usr/bin/env bash
# test-pr-review-transition.sh — unit tests for lib/pr-review-transition.sh,
# the ticket-pr-review Step 6a transition (skill-deterministic-extraction 2).
#
# Expected META lines are fixtures lifted from the pre-extraction SKILL.md
# (fixtures/pr-review/transition-*), timestamps masked. flow.sh is stubbed via
# FLOW_RUN_FLOW_SH; every call is recorded, so a test can prove the trigger
# fired exactly once. Runs from a temp cwd so resolve_uat_url finds no UAT target. Also carries the behavioural replacement for the #412
# "merge authorization before the transition" prose-grep test that lived in
# test-pipeline-phases.sh.
# Usage: bash test-pr-review-transition.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
PRT="$LIB_DIR/pr-review-transition.sh"
FX="$SCRIPT_DIR/fixtures/pr-review"

PASS=0
FAIL=0
FILTER="${1:-}"

_run() {
  local name="$1"
  shift
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return 0
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

unset LOG_FILE TAP_LOG HB_LOG_FILE AUTONOMY MERGE_POLICY UAT_POLICY UAT_URL REPOS_ROOT

_ws=""
_setup() {
  _ws=$(mktemp -d)
  : >"$_ws/log"
  : >"$_ws/flow.calls"
  cat >"$_ws/flow.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$_ws/flow.calls"
exit \${STUB_RC:-0}
EOF
  chmod +x "$_ws/flow.sh"
}
_teardown() { rm -rf "$_ws" 2>/dev/null || true; }

_rc=0
_out=""
# _prt <env assignments...> -- <script args...>
_prt() {
  _rc=0
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  _out=$(cd "$_ws" && env FLOW_RUN_FLOW_SH="$_ws/flow.sh" "${envs[@]}" \
    bash "$PRT" --log-file "$_ws/log" "$@" TEST-7 2>/dev/null) || _rc=$?
}

# META lines only — flow-run.sh's own failure records are not part of the fixture.
_meta_is() { diff <(grep '|META|uat-' "$_ws/log" | sed -E 's/^[^|]+\|/TS|/') "$FX/$1" >/dev/null; }
_flow_once() { [ "$(wc -l <"$_ws/flow.calls")" = 1 ] && grep -q "^TEST-7 $1\( \|$\)" "$_ws/flow.calls"; }

test_merge_pending_routes_to_uat_without_uat_url() {
  _setup
  _prt UAT_POLICY=per-ticket AUTONOMY=manual -- --verdict pass
  local ok=1
  [ "$_rc" = 0 ] && _meta_is transition-pass-merge-pending.log && _flow_once pr-review-pass-uat &&
    grep -qx 'GATE_BLOCKED=false' <<<"$_out" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_epic_policy_closes_child_to_done() {
  _setup
  _prt UAT_POLICY=epic AUTONOMY=auto UAT_URL=https://uat.example.com -- --verdict pass
  local ok=1
  [ "$_rc" = 0 ] && _meta_is transition-pass-epic.log && _flow_once pr-review-pass-done &&
    ! grep -q 'pr-review-pass-uat' "$_ws/flow.calls" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_epic_policy_ignores_merge_pending() {
  _setup
  _prt UAT_POLICY=epic AUTONOMY=manual -- --verdict pass
  local ok=1
  [ "$_rc" = 0 ] && _flow_once pr-review-pass-done &&
    grep -q '|META|uat-decision|info|trigger=pr-review-pass-done; merge pending: pipeline autonomy=manual requires human merge' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_per_ticket_self_merge_goes_done() {
  _setup
  _prt UAT_POLICY=per-ticket AUTONOMY=auto -- --verdict pass
  local ok=1
  [ "$_rc" = 0 ] && _flow_once pr-review-pass-done && ! grep -q 'uat-decision' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_unset_policy_defaults_per_ticket() {
  _setup
  _prt AUTONOMY=auto -- --verdict pass
  local ok=1
  grep -q '|META|uat-policy|info|per-ticket$' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_gaps_fires_pr_review_fail_only() {
  _setup
  _prt UAT_POLICY=per-ticket AUTONOMY=manual -- --verdict gaps
  local ok=1
  [ "$_rc" = 0 ] && _flow_once pr-review-fail && ! grep -q '|META|uat-' "$_ws/log" &&
    grep -qx 'TRIGGER=pr-review-fail' <<<"$_out" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_verdict_gate_refusal_exits_11() {
  _setup
  _prt STUB_RC=11 UAT_POLICY=per-ticket AUTONOMY=auto -- --verdict pass
  local ok=1
  [ "$_rc" = 11 ] && grep -qx 'GATE_BLOCKED=true' <<<"$_out" &&
    grep -q '|META|gate-stop|fail|VERDICT_GATE_BLOCKED' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_other_flow_failure_is_non_fatal() {
  _setup
  _prt STUB_RC=8 UAT_POLICY=per-ticket AUTONOMY=auto -- --verdict pass
  local ok=1
  [ "$_rc" = 0 ] && grep -qx 'FLOW_RC=8' <<<"$_out" && grep -qx 'GATE_BLOCKED=false' <<<"$_out" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_usage() {
  local rc=0
  bash "$PRT" --verdict maybe TEST-7 >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ]
}

test_skill_step6a_calls_the_script() {
  local skill="$PLUGIN_DIR/skills/ticket-pr-review/SKILL.md" block
  block=$(sed -n '/^### Step 6a/,/^### Step 6b/p' "$skill")
  grep -q 'pr-review-transition.sh' <<<"$block" && grep -q 'GATE_BLOCKED=true' <<<"$block" &&
    ! grep -q 'uat_decide_trigger --policy' <<<"$block"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  _run "$t" "$t"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
