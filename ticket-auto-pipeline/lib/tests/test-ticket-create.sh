#!/usr/bin/env bash
# test-ticket-create.sh — unit tests for skills/ticket-create/create.sh
# (ticket-create-skill). Linear is stubbed by appending a linear_graphql
# override to a copy of the real linear-api.sh, so search_issues/create_issue/
# get_issue run their real code against canned responses. CI runs no
# SessionStart hooks, so every lib comes from this checkout via
# CLAUDE_SKILLS_LIB.
# Usage: bash test-ticket-create.sh [filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
REPO_DIR="$(cd "$PLUGIN_DIR/.." && pwd)"
CREATE_SH="$PLUGIN_DIR/skills/ticket-create/create.sh"
FIXTURES="$REPO_DIR/ticket-planner/lib/tests/fixtures/business-framing"

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

TEAM_UUID="11111111-2222-3333-4444-555555555555"

# _setup — builds $T (tmpdir) with a stubbed lib dir, a REPOS_ROOT, and
# canned responses. $1 = JSON array of open issues search_issues returns.
# $2 = "fail" to make issueCreate fail.
_setup() {
  local search_nodes="${1:-[]}" create_mode="${2:-ok}"
  T=$(mktemp -d)
  mkdir -p "$T/lib" "$T/repos"
  cp "$LIB_DIR/"*.sh "$T/lib/"
  echo "$search_nodes" >"$T/search.json"
  cat >>"$T/lib/linear-api.sh" <<STUBEOF

# ── test stub ──
linear_graphql() {
  local payload="\$1"
  case "\$payload" in
  *issueCreate*)
    echo "\$payload" >"$T/create-called"
    if [ "$create_mode" = "fail" ]; then
      echo "GraphQL error: boom" >&2
      exit 10
    fi
    echo '{"data":{"issueCreate":{"success":true,"issue":{"id":"uuid-new","identifier":"WIL-99","title":"t","url":"https://linear.app/x/issue/WIL-99"}}}}'
    ;;
  *"issues(filter"*)
    jq -c '{data:{issues:{nodes:.}}}' "$T/search.json"
    ;;
  *"teams {"*)
    echo '{"data":{"teams":{"nodes":[{"id":"$TEAM_UUID","key":"WIL","name":"Willard"}]}}}'
    ;;
  *"issue(id"*)
    echo '{"data":{"issue":{"id":"uuid-parent","identifier":"WIL-1","title":"p","labels":{"nodes":[]}}}}'
    ;;
  *) echo '{"data":{}}' ;;
  esac
}
STUBEOF
}

_teardown() { rm -rf "$T"; }

# _run_create <args...> — runs create.sh, sets OUT (stdout), ERR, RC.
_run_create() {
  RC=0
  OUT=$(cd "$T" && CLAUDE_SKILLS_LIB="$T/lib" REPOS_ROOT="${TEST_REPOS_ROOT:-$T/repos}" \
    LINEAR_API_KEY=test LINEAR_TEAM_ID="" HB_LOG_FILE="" \
    bash "$CREATE_SH" "$@" 2>"$T/stderr") || RC=$?
  ERR=$(cat "$T/stderr")
}

_manifest() { echo "$T/repos/.ticket-auto/initiatives/_adhoc/tickets/$1/planner/manifest.json"; }

# Feature body (FE scope) with its Navigation Path section removed. The
# Verification Plan goes too: _has_section_nav_path also accepts its
# "Navigation path" column header as evidence of a path.
_feature_no_nav() {
  awk '/^## (Navigation Path|Verification Plan)/{skip=1; next} /^## /{skip=0} !skip' "$FIXTURES/business-lock-period.md"
}

# Enabler body with both why/outcome headings removed.
_no_intent() {
  awk '/^## (Background \/ Motivation|Proposed Changes)/{skip=1; next} /^## /{skip=0} !skip' "$FIXTURES/enabler-bom-java17.md"
}

# ── usage errors → 1 ─────────────────────────────────────────────────────────

test_usage_errors() {
  _setup
  local ok=1 body="$FIXTURES/enabler-bom-java17.md"
  _run_create --kind enabler --title x --body-file "$body"
  [ "$RC" -eq 1 ] || ok=0
  _run_create --type story --kind enabler --title x --body-file "$body"
  [ "$RC" -eq 1 ] || ok=0
  _run_create --type chore --kind discovery --title x --body-file "$body"
  [ "$RC" -eq 1 ] || ok=0
  _run_create --type chore --kind enabler --title "   " --body-file "$body"
  [ "$RC" -eq 1 ] || ok=0
  _run_create --type chore --kind enabler --title x --body-file "$T/nope.md"
  [ "$RC" -eq 1 ] || ok=0
  _run_create --type chore --kind enabler --title x --body-file "$body" --bogus
  [ "$RC" -eq 1 ] || ok=0
  _run_create --type chore --kind enabler --title x --body-file "$body" --duplicate-ok "  "
  [ "$RC" -eq 1 ] || ok=0
  [ ! -f "$T/create-called" ] || ok=0
  _teardown
  [ "$ok" -eq 1 ]
}

# ── body / readiness checks → 2 ──────────────────────────────────────────────

test_feature_missing_nav_path() {
  _setup
  _feature_no_nav >"$T/body.md"
  _run_create --type feature --kind business --title "Lock period" --body-file "$T/body.md"
  local ok=1
  [ "$RC" -eq 2 ] || ok=0
  [[ "$OUT" == *"BODY_CHECK_MISSING=Navigation Path"* ]] || ok=0
  [ ! -f "$T/create-called" ] || ok=0
  _teardown
  [ "$ok" -eq 1 ]
}

test_missing_intent_blocks() {
  _setup
  _no_intent >"$T/body.md"
  _run_create --type chore --kind enabler --title "Migrate bom to Java 17" --body-file "$T/body.md"
  local ok=1
  [ "$RC" -eq 2 ] || ok=0
  [[ "$OUT" == *"DOR_MISSING="*"INTENT_MISSING"* ]] || ok=0
  [ ! -f "$T/create-called" ] || ok=0
  _teardown
  [ "$ok" -eq 1 ]
}

# ── duplicates → 3, override → 0 ─────────────────────────────────────────────

test_near_duplicate_blocks() {
  _setup '[{"id":"u1","identifier":"WIL-5","title":"Client web upload: duplicate rejection is surfaced","url":"u"}]'
  _run_create --type chore --kind enabler --title "Client upload surfaces duplicate rejection" \
    --body-file "$FIXTURES/enabler-bom-java17.md"
  local ok=1
  [ "$RC" -eq 3 ] || ok=0
  [[ "$OUT" == *"DUPLICATE|WIL-5|"* ]] || ok=0
  [ ! -f "$T/create-called" ] || ok=0
  _teardown
  [ "$ok" -eq 1 ]
}

test_unrelated_open_issue_does_not_block() {
  _setup '[{"id":"u1","identifier":"WIL-5","title":"Client portal login timeout","url":"u"}]'
  _run_create --type chore --kind enabler --title "Client upload surfaces duplicate rejection" \
    --body-file "$FIXTURES/enabler-bom-java17.md"
  local rc="$RC"
  _teardown
  [ "$rc" -eq 0 ]
}

test_duplicate_override_records_reason() {
  _setup '[{"id":"u1","identifier":"WIL-5","title":"Client web upload: duplicate rejection is surfaced","url":"u"}]'
  _run_create --type chore --kind enabler --title "Client upload surfaces duplicate rejection" \
    --body-file "$FIXTURES/enabler-bom-java17.md" --duplicate-ok "different root cause: zip path only"
  local ok=1
  [ "$RC" -eq 0 ] || ok=0
  local desc
  desc=$(jq -r '.variables.input.description' "$T/create-called" 2>/dev/null)
  [[ "$desc" == *"Possible duplicate of WIL-5 — accepted: different root cause: zip path only"* ]] || ok=0
  # The note lands under the existing ## Related Tickets heading, not a new one.
  [ "$(grep -c '^## Related Tickets' <<<"$desc")" -eq 1 ] || ok=0
  _teardown
  [ "$ok" -eq 1 ]
}

# ── API failure → 4 ──────────────────────────────────────────────────────────

test_api_failure() {
  _setup '[]' fail
  _run_create --type chore --kind enabler --title "Migrate bom to Java 17" \
    --body-file "$FIXTURES/enabler-bom-java17.md"
  local ok=1
  [ "$RC" -eq 4 ] || ok=0
  [ ! -f "$(_manifest WIL-99)" ] || ok=0
  _teardown
  [ "$ok" -eq 1 ]
}

# ── manifest failure → 5, JSON still printed ─────────────────────────────────

test_manifest_failure() {
  _setup
  : >"$T/not-a-dir"
  TEST_REPOS_ROOT="$T/not-a-dir" _run_create --type chore --kind enabler \
    --title "Migrate bom to Java 17" --body-file "$FIXTURES/enabler-bom-java17.md"
  local ok=1
  [ "$RC" -eq 5 ] || ok=0
  echo "$OUT" | tail -1 | jq -e '.identifier == "WIL-99" and .manifest == false' >/dev/null 2>&1 || ok=0
  _teardown
  [ "$ok" -eq 1 ]
}

# ── happy path chore → 0 ─────────────────────────────────────────────────────

test_happy_path_chore() {
  _setup
  _run_create --type chore --kind enabler --title "Migrate bom to Java 17" \
    --body-file "$FIXTURES/enabler-bom-java17.md" --team WIL --parent WIL-1
  local ok=1
  [ "$RC" -eq 0 ] || ok=0
  echo "$OUT" | tail -1 | jq -e '.identifier == "WIL-99" and .id == "uuid-new" and .type == "chore"
    and .kind == "enabler" and .manifest == true and (.url | length > 0)' >/dev/null 2>&1 || ok=0
  jq -e --arg t "$TEAM_UUID" '.variables.input.teamId == $t and .variables.input.parentId == "uuid-parent"
    and (.variables.input | has("labelIds") | not)' "$T/create-called" >/dev/null 2>&1 || ok=0
  jq -e '.type == "chore" and .initiative == "_adhoc"' "$(_manifest WIL-99)" >/dev/null 2>&1 || ok=0
  [ "$(cat "$T/repos/.ticket-auto/initiatives/_index/WIL-99.initiative" 2>/dev/null)" = "_adhoc" ] || ok=0
  _teardown
  [ "$ok" -eq 1 ]
}

test_business_feature_passes() {
  _setup
  _run_create --type feature --kind business --title "Matter owners can lock a reporting period" \
    --body-file "$FIXTURES/business-lock-period.md" --team "$TEAM_UUID"
  local rc="$RC"
  _teardown
  [ "$rc" -eq 0 ]
}

# ── dry run → 0, no writes ───────────────────────────────────────────────────

test_dry_run_no_writes() {
  _setup
  _run_create --type chore --kind enabler --title "Migrate bom to Java 17" \
    --body-file "$FIXTURES/enabler-bom-java17.md" --dry-run
  local ok=1
  [ "$RC" -eq 0 ] || ok=0
  echo "$OUT" | tail -1 | jq -e '.dry_run == true and .type == "chore"' >/dev/null 2>&1 || ok=0
  [ ! -f "$T/create-called" ] || ok=0
  [ ! -d "$T/repos/.ticket-auto" ] || ok=0
  _teardown
  [ "$ok" -eq 1 ]
}

FILTER="${1:-}"
for fn in \
  test_usage_errors \
  test_feature_missing_nav_path \
  test_missing_intent_blocks \
  test_near_duplicate_blocks \
  test_unrelated_open_issue_does_not_block \
  test_duplicate_override_records_reason \
  test_api_failure \
  test_manifest_failure \
  test_happy_path_chore \
  test_business_feature_passes \
  test_dry_run_no_writes; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  if "$fn"; then _pass "$fn"; else _fail "$fn"; fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
