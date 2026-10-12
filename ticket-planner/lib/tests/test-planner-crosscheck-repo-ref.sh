#!/usr/bin/env bash
# test-planner-crosscheck-repo-ref.sh — Tests for planner-crosscheck-repo-ref.sh
# (issue #217: Crosscheck must resolve against the ref Discovery explored,
# not whatever branch the live REPOS_ROOT checkout happens to be on).
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-repo-ref.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck-repo-ref.sh"
source "${LIB_DIR}/planner-crosscheck-citations.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"

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

echo "=== planner-crosscheck-repo-ref tests ==="

# ── Fixture: a git repo with two branches that genuinely differ ────────────
# Mirrors the VS-2 defect exactly: worker/metrics.py exists on develop only.

REPO_DIR="${REPOS_ROOT}/ledgerly"
mkdir -p "${REPO_DIR}/worker"
git -C "$REPOS_ROOT" init -q ledgerly
git -C "$REPO_DIR" config user.email "test@example.com"
git -C "$REPO_DIR" config user.name "Test"

echo "def handler(): pass" >"${REPO_DIR}/worker/main.py"
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "main: baseline"
git -C "$REPO_DIR" branch -M main

git -C "$REPO_DIR" checkout -q -b develop
cat >"${REPO_DIR}/worker/metrics.py" <<'EOF'
def record_metric(name, value):
    pass
EOF
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "develop: add metrics module"
DEVELOP_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)

# Live checkout lands back on main — develop's file is now invisible to a
# plain filesystem resolve.
git -C "$REPO_DIR" checkout -q main

INIT_ID="INIT-217-test"
planner_state_init "$INIT_ID" "test idea" >/dev/null 2>&1

# ── planner_crosscheck_repo_refs: read-back ─────────────────────────────────

echo "--- planner_crosscheck_repo_refs ---"

OUT=$(planner_crosscheck_repo_refs "$INIT_ID")
if [ -z "$OUT" ]; then
  pass "no repo-ref entries yet returns nothing"
else
  fail "no repo-ref entries yet returns nothing" "$OUT"
fi

planner_state_write "$INIT_ID" "META" "discovery" "repo-ref" "ledgerly@develop@${DEVELOP_SHA}"

OUT=$(planner_crosscheck_repo_refs "$INIT_ID")
if [ "$OUT" = "ledgerly develop ${DEVELOP_SHA}" ]; then
  pass "reads back the recorded repo-ref"
else
  fail "reads back the recorded repo-ref" "$OUT"
fi

# Last-write-wins per repo.
OTHER_SHA="0000000000000000000000000000000000abcd"
planner_state_write "$INIT_ID" "META" "discovery" "repo-ref" "ledgerly@main@${OTHER_SHA}"
OUT=$(planner_crosscheck_repo_refs "$INIT_ID")
if [ "$OUT" = "ledgerly main ${OTHER_SHA}" ]; then
  pass "last-write-wins per repo"
else
  fail "last-write-wins per repo" "$OUT"
fi

# Restore the develop repo-ref for the rest of the tests.
planner_state_write "$INIT_ID" "META" "discovery" "repo-ref" "ledgerly@develop@${DEVELOP_SHA}"

# ── planner_crosscheck_repo_ref_ensure ──────────────────────────────────────

echo "--- planner_crosscheck_repo_ref_ensure ---"

LIVE_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
OUT=$(planner_crosscheck_repo_ref_ensure "$REPOS_ROOT" "ledgerly" "main" "$LIVE_SHA")
if [ -z "$OUT" ]; then
  pass "matching live checkout is a no-op (no worktree, no exclusion)"
else
  fail "matching live checkout is a no-op" "$OUT"
fi

OUT=$(planner_crosscheck_repo_ref_ensure "$REPOS_ROOT" "ledgerly" "develop" "$DEVELOP_SHA")
if [ "$OUT" = "ledgerly" ]; then
  pass "mismatched live checkout returns the live dir's REPOS_ROOT-relative path to exclude"
else
  fail "mismatched live checkout returns the live dir's REPOS_ROOT-relative path to exclude" "$OUT"
fi

WORKTREE_DIR=$(find "$REPOS_ROOT" -maxdepth 1 -type d -name 'ledgerly-crosscheck-develop-*' | head -1)
if [ -n "$WORKTREE_DIR" ] && [ -f "${WORKTREE_DIR}/worker/metrics.py" ]; then
  pass "worktree created alongside the live repo, containing develop's file"
else
  fail "worktree created alongside the live repo, containing develop's file" "dir='$WORKTREE_DIR'"
fi

if [ "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)" = "main" ]; then
  pass "live checkout is untouched — still on main"
else
  fail "live checkout is untouched — still on main" "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
fi

# Idempotent — a second call reuses the existing worktree rather than failing.
OUT2=$(planner_crosscheck_repo_ref_ensure "$REPOS_ROOT" "ledgerly" "develop" "$DEVELOP_SHA")
if [ "$OUT2" = "ledgerly" ]; then
  pass "second call is idempotent (reuses the existing worktree)"
else
  fail "second call is idempotent" "$OUT2"
fi

# Non-git directory — best-effort no-op, never fatal.
mkdir -p "${REPOS_ROOT}/not-a-repo"
OUT=$(planner_crosscheck_repo_ref_ensure "$REPOS_ROOT" "not-a-repo" "develop" "deadbeef")
if [ -z "$OUT" ]; then
  pass "non-git repo dir is a silent no-op"
else
  fail "non-git repo dir is a silent no-op" "$OUT"
fi

# ── End-to-end: planner_crosscheck_citations resolves against the pinned ref ─

echo "--- planner_crosscheck_citations resolves against Discovery's pinned ref ---"

ARTIFACTS_DIR="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_ID}/artifacts"
mkdir -p "$ARTIFACTS_DIR"
cat >"${ARTIFACTS_DIR}/proposal.md" <<'EOF'
## Title
Repo-ref test proposal

## Description
Metrics are recorded via `worker/metrics.py:1`.

## Labels
planned
EOF

if planner_crosscheck_citations "$INIT_ID" >/tmp/cc-repo-ref-out.txt 2>&1; then
  pass "citation against develop-only file resolves via the pinned-ref worktree"
else
  fail "citation against develop-only file resolves via the pinned-ref worktree" "$(cat /tmp/cc-repo-ref-out.txt)"
fi

if [ "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)" = "main" ]; then
  pass "live checkout still untouched after a full Crosscheck citations run"
else
  fail "live checkout still untouched after a full Crosscheck citations run" "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
fi

# ── #500: nested repos (REPOS_ROOT/microservices/<repo>) ────────────────────

echo "--- #500: nested repo layout ---"

NESTED_PARENT="${REPOS_ROOT}/microservices"
NESTED_DIR="${NESTED_PARENT}/debt-collection"
mkdir -p "$NESTED_PARENT"
git -C "$NESTED_PARENT" init -q debt-collection
git -C "$NESTED_DIR" config user.email "test@example.com"
git -C "$NESTED_DIR" config user.name "Test"
mkdir -p "${NESTED_DIR}/src"
echo "class Base {}" >"${NESTED_DIR}/src/Base.java"
git -C "$NESTED_DIR" add -A
git -C "$NESTED_DIR" commit -q -m "main: baseline"
git -C "$NESTED_DIR" branch -M main
git -C "$NESTED_DIR" checkout -q -b feature
echo "class Collector {}" >"${NESTED_DIR}/src/Collector.java"
git -C "$NESTED_DIR" add -A
git -C "$NESTED_DIR" commit -q -m "feature: add collector"
NESTED_FEATURE_SHA=$(git -C "$NESTED_DIR" rev-parse HEAD)
git -C "$NESTED_DIR" checkout -q main

OUT=$(planner_crosscheck_repo_dir "$REPOS_ROOT" "microservices/debt-collection")
if [ "$OUT" = "$NESTED_DIR" ]; then
  pass "relative path recorded by Discovery resolves to the nested checkout"
else
  fail "relative path resolves to the nested checkout" "$OUT"
fi

OUT=$(planner_crosscheck_repo_dir "$REPOS_ROOT" "debt-collection")
if [ "$OUT" = "$NESTED_DIR" ]; then
  pass "bare name (older initiatives) resolves by unique search under REPOS_ROOT"
else
  fail "bare name resolves by unique search under REPOS_ROOT" "$OUT"
fi

OUT=$(planner_crosscheck_repo_dir "$REPOS_ROOT" "ledgerly")
if [ "$OUT" = "${REPOS_ROOT}/ledgerly" ]; then
  pass "root-level repo still resolves directly"
else
  fail "root-level repo still resolves directly" "$OUT"
fi

OUT=$(planner_crosscheck_repo_dir "$REPOS_ROOT" "../ledgerly")
if [ -z "$OUT" ]; then
  pass "a path escaping REPOS_ROOT never resolves"
else
  fail "a path escaping REPOS_ROOT never resolves" "$OUT"
fi

# Ambiguity: two same-named checkouts — no guessing.
mkdir -p "${REPOS_ROOT}/commons" "${REPOS_ROOT}/legacy"
git -C "${REPOS_ROOT}/commons" init -q util
git -C "${REPOS_ROOT}/legacy" init -q util
OUT=$(planner_crosscheck_repo_dir "$REPOS_ROOT" "util")
if [ -z "$OUT" ]; then
  pass "an ambiguous bare name resolves to nothing"
else
  fail "an ambiguous bare name resolves to nothing" "$OUT"
fi
OUT=$(planner_crosscheck_repo_dir "$REPOS_ROOT" "commons/util")
if [ "$OUT" = "${REPOS_ROOT}/commons/util" ]; then
  pass "a relative path disambiguates same-named repos"
else
  fail "a relative path disambiguates same-named repos" "$OUT"
fi

# Acceptance: Crosscheck creates the pinned-ref worktree for a nested repo
# whose live checkout has moved.
OUT=$(planner_crosscheck_repo_ref_ensure "$REPOS_ROOT" "debt-collection" "feature" "$NESTED_FEATURE_SHA")
NESTED_WT=$(find "$NESTED_PARENT" -maxdepth 1 -type d -name 'debt-collection-crosscheck-feature-*' | head -1)
if [ "$OUT" = "microservices/debt-collection" ] && [ -f "${NESTED_WT}/src/Collector.java" ]; then
  pass "nested repo with a moved live checkout gets a pinned-ref worktree beside it"
else
  fail "nested repo gets a pinned-ref worktree beside it" "out='$OUT' wt='$NESTED_WT'"
fi

# A same-named checkout *inside* a crosscheck worktree directory must not
# make the bare name ambiguous — the `*-crosscheck-*` prune has to fire.
mkdir -p "${REPOS_ROOT}/x-crosscheck-y/debt-collection/.git"
OUT=$(planner_crosscheck_repo_dir "$REPOS_ROOT" "debt-collection")
if [ "$OUT" = "$NESTED_DIR" ]; then
  pass "crosscheck worktree directories are never resolution candidates"
else
  fail "crosscheck worktree directories are never resolution candidates" "$OUT"
fi
rm -rf "${REPOS_ROOT}/x-crosscheck-y"

# Glob metacharacters in a recorded name match literally, not as a pattern.
OUT=$(planner_crosscheck_repo_dir "$REPOS_ROOT" "debt-*")
if [ -z "$OUT" ]; then
  pass "a glob in a recorded name never matches a real repo"
else
  fail "a glob in a recorded name never matches a real repo" "$OUT"
fi

# A stale relative path never falls back to a name search (which would pick
# another same-named repo).
mv "${REPOS_ROOT}/commons/util" "${REPOS_ROOT}/commons/util-moved"
OUT=$(planner_crosscheck_repo_dir "$REPOS_ROOT" "commons/util")
if [ -z "$OUT" ]; then
  pass "a stale relative path resolves to nothing, not to a same-named repo elsewhere"
else
  fail "a stale relative path resolves to nothing" "$OUT"
fi
rm -rf "${REPOS_ROOT}/commons" "${REPOS_ROOT}/legacy"

# A symlinked REPOS_ROOT is followed by the bare-name search.
ln -s "$REPOS_ROOT" "${TMPDIR}/repos-link"
OUT=$(planner_crosscheck_repo_dir "${TMPDIR}/repos-link" "debt-collection")
if [ "$OUT" = "${TMPDIR}/repos-link/microservices/debt-collection" ]; then
  pass "a bare name resolves under a symlinked REPOS_ROOT"
else
  fail "a bare name resolves under a symlinked REPOS_ROOT" "$OUT"
fi

# ── #500 review: anchored exclusion, dedupe, end-to-end nested citations ────

echo "--- #500: nested citations end to end ---"

# microservices/gateway: live on main, Discovery pinned it at feature.
GW_DIR="${NESTED_PARENT}/gateway"
git -C "$NESTED_PARENT" init -q gateway
git -C "$GW_DIR" config user.email "test@example.com"
git -C "$GW_DIR" config user.name "Test"
mkdir -p "${GW_DIR}/src"
echo "class Router {}" >"${GW_DIR}/src/Router.java"
git -C "$GW_DIR" add -A
git -C "$GW_DIR" commit -q -m "main: baseline"
git -C "$GW_DIR" branch -M main
git -C "$GW_DIR" checkout -q -b feature
echo "class RateLimiter {}" >"${GW_DIR}/src/RateLimiter.java"
git -C "$GW_DIR" add -A
git -C "$GW_DIR" commit -q -m "feature: rate limiter"
GW_FEATURE_SHA=$(git -C "$GW_DIR" rev-parse HEAD)
git -C "$GW_DIR" checkout -q main
echo "class LiveOnlySymbol {}" >"${GW_DIR}/src/LiveOnly.java"
git -C "$GW_DIR" add -A
git -C "$GW_DIR" commit -q -m "main: moved on since Discovery"

# Sibling repo with a package directory that shares the gateway's name.
BILLING_DIR="${NESTED_PARENT}/billing"
mkdir -p "${BILLING_DIR}/src/main/java/com/x/gateway"
git -C "$NESTED_PARENT" init -q billing
echo "class BillingGatewayClient {}" >"${BILLING_DIR}/src/main/java/com/x/gateway/Client.java"

NINIT="INIT-500-nested"
planner_state_init "$NINIT" "nested test" >/dev/null 2>&1
# An older run recorded the bare name, the newer one the relative path —
# both name the same checkout and must yield exactly one entry/worktree.
planner_state_write "$NINIT" "META" "discovery" "repo-ref" "gateway@feature@${GW_FEATURE_SHA}"
planner_state_write "$NINIT" "META" "discovery" "repo-ref" "microservices/gateway@feature@${GW_FEATURE_SHA}"

OUT=$(planner_crosscheck_repo_refs_resolved "$NINIT" "$REPOS_ROOT")
if [ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 1 ] &&
  [ "$(printf '%s' "$OUT" | cut -d$'\037' -f2)" = "microservices/gateway" ]; then
  pass "bare-name and relative-path refs to one checkout dedupe, last write wins"
else
  fail "bare-name and relative-path refs dedupe" "$OUT"
fi

OUT=$(planner_crosscheck_repo_ref_setup "$NINIT" "$REPOS_ROOT")
WT_COUNT=$(find "$NESTED_PARENT" -maxdepth 1 -type d -name 'gateway-crosscheck-*' | grep -c .)
if [ "$OUT" = "microservices/gateway" ] && [ "$WT_COUNT" -eq 1 ]; then
  pass "setup returns the anchored relative path and creates exactly one worktree"
else
  fail "setup returns the anchored relative path, one worktree" "out='$OUT' worktrees=$WT_COUNT"
fi

NART="${REPOS_ROOT}/.ticket-auto/initiatives/${NINIT}/artifacts"
mkdir -p "$NART"
cat >"${NART}/proposal.md" <<'EOF'
## Title
Nested repo-ref test proposal

## Description
The client lives at `src/main/java/com/x/gateway/Client.java:1` and the
limiter at `src/RateLimiter.java:1`. Billing mirrors the existing `BillingGatewayClient`.

## Labels
planned
EOF

if planner_crosscheck_citations "$NINIT" >"${TMPDIR}/cc-nested.txt" 2>&1; then
  pass "sibling repo's same-named package dir is not excluded with the live repo"
else
  fail "sibling repo's same-named package dir is not excluded" "$(cat "${TMPDIR}/cc-nested.txt")"
fi

# The live (moved-on) checkout is still excluded: a symbol that exists only
# there, not at the pinned ref, must not count as a precedent.
cat >"${NART}/proposal.md" <<'EOF'
## Title
Nested repo-ref test proposal

## Description
Routing mirrors the existing `LiveOnlySymbol`.

## Labels
planned
EOF
if planner_crosscheck_citations "$NINIT" >"${TMPDIR}/cc-nested2.txt" 2>&1; then
  fail "live-only symbol is excluded in favour of the pinned ref" "$(cat "${TMPDIR}/cc-nested2.txt")"
elif grep -q "PRECEDENT_NOT_FOUND.*LiveOnlySymbol" "${TMPDIR}/cc-nested2.txt"; then
  pass "live-only symbol is excluded in favour of the pinned ref"
else
  fail "live-only symbol is excluded in favour of the pinned ref" "$(cat "${TMPDIR}/cc-nested2.txt")"
fi

if [ "${#PLANNER_CROSSCHECK_EXCLUDE_PATHS[@]}" -eq 0 ]; then
  pass "anchored exclusions are restored after the run"
else
  fail "anchored exclusions are restored after the run" "${PLANNER_CROSSCHECK_EXCLUDE_PATHS[*]}"
fi

if [ "$(git -C "$NESTED_DIR" rev-parse --abbrev-ref HEAD)" = "main" ]; then
  pass "nested live checkout is untouched"
else
  fail "nested live checkout is untouched" "$(git -C "$NESTED_DIR" rev-parse --abbrev-ref HEAD)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
