#!/usr/bin/env bash
# ci-nightly-issue.sh — file, or add to, the issue for a failed nightly CI run.
#
# Run by the `nightly-issue` job of .github/workflows/test.yml when the
# scheduled full run on main fails. One open issue carries every failure: if
# an open issue with TITLE and LABEL exists it gets a comment, otherwise a new
# one is filed. The body is the repo's agent-handoff shape
# (github_issue_body_template, CLAUDE.md "Issue filing conventions") and holds
# no ticket ids or user data: only the commit, the run link and job names.
#
# Env: GITHUB_REPOSITORY (owner/repo), RUN_URL, SHA, and gh's GH_TOKEN.
#      RUN_ID (optional) lists the failing jobs by name.
# Exit: 0 filed or commented, non-zero on a gh failure.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../ticket-auto-pipeline/lib/github-issues.sh
source "$ROOT/ticket-auto-pipeline/lib/github-issues.sh"

TITLE="Nightly CI failed on main"
LABEL="ci-nightly"
export GITHUB_ISSUE_REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${RUN_URL:?RUN_URL is required}" "${SHA:?SHA is required}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

jobs=""
if [ -n "${RUN_ID:-}" ]; then
  jobs=$(gh run view "$RUN_ID" --repo "$GITHUB_ISSUE_REPO" --json jobs \
    --jq '[.jobs[] | select(.conclusion == "failure") | .name] | join(", ")' 2>/dev/null) || jobs=""
fi
[ -n "$jobs" ] || jobs="(not listed; open the run)"
day=$(date -u +%Y-%m-%d)

# The label must exist before an issue can carry it; an existing one is fine.
gh label create "$LABEL" --repo "$GITHUB_ISSUE_REPO" --color B60205 \
  --description "The nightly full CI run on main failed" >/dev/null 2>&1 || true

existing=$(gh issue list --repo "$GITHUB_ISSUE_REPO" --state open --label "$LABEL" --limit 100 \
  --json number,title --jq ".[] | select(.title == \"$TITLE\") | .number")
existing="${existing%%$'\n'*}"

if [ -n "$existing" ]; then
  cat >"$TMP/comment.md" <<EOF
Failed again on ${day} at \`${SHA}\`.

- Failing jobs: ${jobs}
- Run: ${RUN_URL}
EOF
  github_issue_comment "$existing" "$TMP/comment.md"
  echo "ci-nightly-issue: commented on #$existing"
  exit 0
fi

github_issue_body_template \
  "P1" \
  "Repo-level" \
  ".github/workflows/test.yml (nightly full run)" \
  "The scheduled full test run on \`main\` failed on ${day} at commit \`${SHA}\`.

Failing jobs: ${jobs}

Run: ${RUN_URL}" \
  "The nightly run (every test command, all four shards, the gates and the OTel SDK job) passes on \`main\`." \
  "1. Open the run above and read the failing job's log; failing test output is printed in full at the end of a shard's log, and per-command logs are in the \`test-logs-shard-K\` artifact.
2. Re-run the whole workflow on main: \`gh workflow run test.yml --ref main\`.
3. Locally: \`git checkout ${SHA} && make test > /tmp/make-test.log 2>&1\`, then grep the log for FAIL (never pipe \`make test\`)." \
  "Not yet diagnosed. A PR's CI runs only the tests for the plugins it touches (scripts/select-tests.sh), so a failure first seen here is either a flaky test, a change on main that broke another plugin through a dependency scripts/select-tests.sh does not list, or an outside change (runner image, a dependency release, the OTel SDK)." \
  "- Failing jobs and run: see Current Behavior.
- Selection map: scripts/select-tests.sh (DEPENDENTS, ANY_PLUGIN). If a PR went green because its change was not selected, add the missing dependency there and a case to scripts/tests/test-select-tests.sh.
- Flake: confirm it is in a file the breaking commit did not touch before re-running; fix the race rather than retrying." \
  "- [ ] The cause is named in a comment here (test, commit, or outside change).
- [ ] The fix is merged, or the selection map gains the missing dependency with a test case.
- [ ] A manual \`workflow_dispatch\` run of test.yml on main passes, then this issue is closed." \
  "Workflow: .github/workflows/test.yml; selection: scripts/select-tests.sh" \
  >"$TMP/body.md"

github_issue_create "$TITLE" "$LABEL" "$TMP/body.md"
