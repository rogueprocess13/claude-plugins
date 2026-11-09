#!/usr/bin/env bash
# Tests for scripts/ci-nightly-issue.sh against a stub `gh` — no real GitHub
# call is ever made.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/scripts/ci-nightly-issue.sh"
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

# Stub gh: logs each call's argv (one line) and, for create/comment, the body
# file's contents. `issue list` answers with $STUB_EXISTING.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
case "$1 $2" in
"run view") echo "tests (shard 2/4), otel" ;;
"issue list") [ -z "${STUB_EXISTING:-}" ] || echo "$STUB_EXISTING" ;;
"issue create" | "issue comment")
  while [ "$#" -gt 0 ]; do
    [ "$1" = "--body-file" ] && cp "$2" "$STUB_BODY"
    shift
  done
  echo "https://example.invalid/issues/1"
  ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"

run() {
  : >"$TMP/gh.log"
  rm -f "$TMP/body.md"
  env -u HB_LOG_FILE PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/gh.log" STUB_BODY="$TMP/body.md" \
    GITHUB_REPOSITORY=owner/repo RUN_URL=https://example.invalid/runs/9 SHA=abc1234 RUN_ID=9 \
    "$@" bash "$SCRIPT" >"$TMP/out.txt" 2>&1
}

echo "=== no open issue: a new one is filed ==="
run
rc=$?
[ "$rc" -eq 0 ] && ok "exits 0" || bad "exit $rc: $(cat "$TMP/out.txt")"
grep -q '^issue create --repo owner/repo --title Nightly CI failed on main --label ci-nightly ' "$TMP/gh.log" &&
  ok "files 'Nightly CI failed on main' with the ci-nightly label" || bad "create call: $(cat "$TMP/gh.log")"
grep -q '^label create ci-nightly' "$TMP/gh.log" && ok "ensures the label exists" || bad "no label create"
grep -q '^issue list --repo owner/repo --state open --label ci-nightly' "$TMP/gh.log" &&
  ok "looks for an open issue first" || bad "no issue list"
for h in '**Severity:** P1' '**Plugin:** Repo-level' '## Current Behavior (Actual)' '## Expected Behavior' \
  '## Steps to Reproduce' '## Root Cause' '## Handover Package' '## Verification Checklist' '## Related'; do
  grep -qF "$h" "$TMP/body.md" || bad "body lacks '$h'"
done
grep -qF 'Failing jobs: tests (shard 2/4), otel' "$TMP/body.md" && grep -qF 'abc1234' "$TMP/body.md" &&
  grep -qF 'https://example.invalid/runs/9' "$TMP/body.md" &&
  ok "body is the agent-handoff shape with the jobs, commit and run" || bad "body: $(cat "$TMP/body.md")"

echo "=== an open issue: a comment, no new issue ==="
run STUB_EXISTING=42
rc=$?
[ "$rc" -eq 0 ] && ok "exits 0" || bad "exit $rc: $(cat "$TMP/out.txt")"
grep -q '^issue comment 42 ' "$TMP/gh.log" && ok "comments on #42" || bad "no comment on #42: $(cat "$TMP/gh.log")"
grep -q '^issue create' "$TMP/gh.log" && bad "filed a second issue" || ok "files no second issue"
grep -qF 'tests (shard 2/4), otel' "$TMP/body.md" && ok "the comment names the failing jobs" ||
  bad "comment: $(cat "$TMP/body.md")"

echo "=== missing env fails without calling gh ==="
: >"$TMP/gh.log"
env -u HB_LOG_FILE -u RUN_URL PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/gh.log" GITHUB_REPOSITORY=owner/repo SHA=x \
  bash "$SCRIPT" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$TMP/gh.log" ] && ok "no RUN_URL: non-zero, gh untouched" || bad "rc=$rc, gh: $(cat "$TMP/gh.log")"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
