#!/usr/bin/env bash
# test-uat-policy-guard.sh — lib/uat-policy-guard.sh, ticket-verify Step 1b4
# (skill-deterministic-extraction 4).
#
# fixtures/uat-policy-guard/<case>.log and <case>.err were produced by
# running the pre-extraction Step 1b4 block of ticket-verify SKILL.md (main @
# eacacbf) over the workspaces built below — never by the script. Timestamps
# are masked to TS.
#
# With UAT_POLICY_GUARD_TEST_LIB_ONLY=1 the file only defines its helpers.
set -eo pipefail

UG_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UG_LIB_DIR="$(cd "$UG_TEST_DIR/.." && pwd)"
UG="$UG_LIB_DIR/uat-policy-guard.sh"
UG_FX="$UG_TEST_DIR/fixtures/uat-policy-guard"
TID="CRE-500"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT UAT_POLICY FLEET_WORKER_PID FLEET_GENERATION LINEAR_API_KEY

_ws_new() {
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/logs" "$WS/home" "$WS/repos"
  mkdir -m 700 "$WS/scratch"
  export HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch" CLAUDE_SKILLS_LIB="$UG_LIB_DIR" REPOS_ROOT="$WS/repos"
  export TAP_LOG="$WS/logs/$TID-pipeline.log"
  : >"$TAP_LOG"
}
_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }
_mask() { sed -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g'; }
_manifests() { # uat policy of the epic
  (
    source "$UG_LIB_DIR/manifest-write.sh"
    write_ticket_manifest "$TID" "CRE-100" "bug" '[]' >/dev/null
    write_epic_manifest "CRE-100" "epic/x" "$1" "" '[]' >/dev/null
  )
}
_case_epic() { _manifests epic; }
_case_per_ticket() { _manifests per-ticket; }
_case_no_manifest() { :; }
_case_env_override() {
  _manifests per-ticket
  export UAT_POLICY=epic
}

[ "${UAT_POLICY_GUARD_TEST_LIB_ONLY:-0}" = 1 ] && return 0

PASS=0 FAIL=0
_ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
_ko() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

echo "=== parity with the Step 1b4 block (--env uat) ==="
for c in epic per_ticket no_manifest env_override; do
  _ws_new
  "_case_$c"
  rc=0
  bash "$UG" "$TID" --env uat 2>"$WS/err" || rc=$?
  unset UAT_POLICY
  [ "$(_mask <"$TAP_LOG")" = "$(cat "$UG_FX/$c.log")" ] && _ok "$c: log" || _ko "$c: log differs: $(cat "$TAP_LOG")"
  [ "$(cat "$WS/err")" = "$(cat "$UG_FX/$c.err")" ] && _ok "$c: message" || _ko "$c: stderr differs: $(cat "$WS/err")"
  case "$c" in
  epic | env_override) [ "$rc" = 3 ] && _ok "$c: refused, exit 3" || _ko "$c: rc=$rc" ;;
  *) [ "$rc" = 0 ] && _ok "$c: proceeds, exit 0" || _ko "$c: rc=$rc" ;;
  esac
  _ws_rm
done

echo "=== local verification is unaffected ==="
_ws_new
_case_epic
rc=0
bash "$UG" "$TID" --env local 2>"$WS/err" || rc=$?
[ "$rc" = 0 ] && [ ! -s "$TAP_LOG" ] && [ ! -s "$WS/err" ] && _ok "epic policy + --env local -> exit 0, silent" || _ko "local: rc=$rc"
rc=0
(
  source "$UG"
  uat_policy_guard "$TID" uat
) 2>/dev/null || rc=$?
[ "$rc" = 3 ] && _ok "sourced uat_policy_guard refuses too" || _ko "sourced rc=$rc"
rc=0
bash "$UG" "$TID" --env staging 2>/dev/null || rc=$?
[ "$rc" = 2 ] && _ok "unknown env -> exit 2" || _ko "unknown env rc=$rc"
_ws_rm

echo ""
echo "uat-policy-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
