#!/usr/bin/env bash
# test-planner-crosscheck-false-fires.sh — regression tests for the Crosscheck
# false fires planner-halt-recall part (c) found (recall.md "Checker bugs").
#
#   F94 / bug 6  RESOLUTION_NOT_PROPAGATED: a native `### F<n> … — accepted`
#                Consensus section is one block (judged on the specs that
#                open its list items), and disposition/severity words are
#                never terms.
#   bugs 1 + 2   PRECEDENT_NOT_FOUND: REPOS_ROOT/.grill/ never resolves an
#                identifier, and an identifier a spec of the same plan
#                creates is resolved.
#   bug 4        CONTRACT_MISMATCH: a sibling is compared with what this
#                initiative says about the structure as a whole, not with a
#                consumer spec's call-site paragraph.
#
# Each "false fire" case failed before the fix; each "still fires" case is the
# recall guard for the same change.
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-false-fires.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-crosscheck-propagation.sh"
source "${LIB_DIR}/planner-crosscheck-citations.sh"
source "${LIB_DIR}/planner-crosscheck-contracts.sh"

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

echo "=== planner-crosscheck false-fire regressions ==="

# ═══════════════════════════════════════════════════════════════════════════
# RESOLUTION_NOT_PROPAGATED — F94 / bug 6
# ═══════════════════════════════════════════════════════════════════════════

R="${TMPDIR}/res"
mkdir -p "${R}/specs"
cat >"${R}/specs/frontend-shell.md" <<'EOF'
## Description
The shell checks the home page heading `Conduit` on `/` and on an unknown path
such as `/no-such-page`; the heading is kept when later pages replace home.
EOF
cat >"${R}/specs/frontend-reading-pages.md" <<'EOF'
## Description
The home page starts with `<h1>Conduit</h1>` above the article previews.
EOF

echo "--- F94: a native heading is not its own block (iteration 16 shape) ---"
cat >"${R}/f94.md" <<'EOF'
# Consensus

## Findings Addressed

### F3 — minor — The home page heading that frontend-shell checks is not kept by frontend-reading-pages — accepted

`frontend-reading-pages` now keeps the heading. Its Technical Context says the home page starts with `<h1>Conduit</h1>`, and `frontend-shell` checks the heading `Conduit` on `/` and on `/no-such-page`.
EOF
out=$(planner_crosscheck_consensus_propagation "${R}/f94.md" "${R}/specs")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass "F94 shape: the resolution reached both specs, no finding"
else
  fail "F94 shape: no finding" "rc=${rc} out=${out}"
fi

echo "--- R1: native heading naming no spec, body bullets name two, one missed ---"
cat >"${R}/specs/api.md" <<'EOF'
## Description
Every response carries an `X-Request-Id` header, set by one middleware.
EOF
cat >"${R}/specs/client.md" <<'EOF'
## Description
The client logs each failed call.
EOF
cat >"${R}/r1.md" <<'EOF'
## Findings Addressed

### F90 — minor — Responses carry no request id — accepted

Every API response now carries an `X-Request-Id` header. Changes:

- `api`: the app sets `X-Request-Id` on every response.
- `client`: the client reads `X-Request-Id` and logs it next to each failed call.
EOF
out=$(planner_crosscheck_consensus_propagation "${R}/r1.md" "${R}/specs")
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'RESOLUTION_NOT_PROPAGATED has-it=\[api\] missing-it=\[client\]' <<<"$out"; then
  pass "R1 shape: the missed spec is reported (was untested: 0 units)"
else
  fail "R1 shape: reported" "rc=${rc} out=${out}"
fi
UF="${TMPDIR}/units-r1"
: >"$UF"
PLANNER_CROSSCHECK_UNITS_FILE="$UF" planner_crosscheck_consensus_propagation "${R}/r1.md" "${R}/specs" >/dev/null
if grep -q 'resolution' "$UF"; then
  pass "R1 shape: the section counts as a judged resolution unit"
else
  fail "R1 shape: judged" "units file: $(cat "$UF")"
fi

echo "--- a native section naming specs only in prose roles is not judged ---"
# iteration 11-16 shapes: a dependency ("now blocked by"), a removal ("gone
# from"), a statement of fact ("already build") — none hands the spec a piece.
cat >"${R}/prose-roles.md" <<'EOF'
## Findings Addressed

### F6 — minor — Avoidable dependency — accepted

`api` is now blocked by `client` only. The old `GET /api/legacy` entry is gone from both the proposal and `client`. `api` and `client` already build `createApp(createSeededStore())` with no `await`.
EOF
if out=$(planner_crosscheck_consensus_propagation "${R}/prose-roles.md" "${R}/specs") && [ -z "$out" ]; then
  pass "prose-role mentions: no finding"
else
  fail "prose-role mentions: no finding" "out=${out}"
fi

echo "--- the heading's disposition decides: a deferred section is never checked ---"
cat >"${R}/deferred.md" <<'EOF'
## Findings Addressed

### F9 — minor — Request ids on failed calls — deferred

Part (a) was accepted in F90; the rest is deferred.

- `api`: the app sets `X-Request-Id` on every response.
- `client`: the client reads `X-Request-Id` and logs it next to each failed call.
EOF
if out=$(planner_crosscheck_consensus_propagation "${R}/deferred.md" "${R}/specs") && [ -z "$out" ]; then
  pass "deferred heading: no finding even though the body says accepted"
else
  fail "deferred heading: no finding" "out=${out}"
fi

echo "--- an accepted heading whose body mentions a rejected option is still checked ---"
cat >"${R}/accepted-mentions-rejected.md" <<'EOF'
## Findings Addressed

### F91 — minor — Responses carry no request id — accepted

A per-route header was rejected in favour of one middleware.

- `api`: the app sets `X-Request-Id` on every response.
- `client`: the client reads `X-Request-Id` and logs it next to each failed call.
EOF
out=$(planner_crosscheck_consensus_propagation "${R}/accepted-mentions-rejected.md" "${R}/specs")
if grep -q 'missing-it=\[client\]' <<<"$out"; then
  pass "accepted heading: a body mentioning 'rejected' does not hide the section"
else
  fail "accepted heading: still checked" "out=${out}"
fi

echo "--- disposition and severity words are never terms ---"
terms=$(_planner_crosscheck_prop_terms "minor accepted rejected deferred critical major blocker nit")
if [ -z "$terms" ]; then
  pass "disposition/severity words yield no terms"
else
  fail "disposition/severity words yield no terms" "got: $(tr '\n' ' ' <<<"$terms")"
fi

echo "--- the old paragraph format still works (recall guard) ---"
cat >"${R}/list.md" <<'EOF'
## Findings Addressed

- **M9 (accepted).** `api` and `client` both handle the `X-Request-Id` header: `api` sets it on every response and `client` logs it with each failed call.
EOF
out=$(planner_crosscheck_consensus_propagation "${R}/list.md" "${R}/specs")
if grep -q 'missing-it=\[client\]' <<<"$out"; then
  pass "one-paragraph accepted list item still fires"
else
  fail "one-paragraph accepted list item still fires" "out=${out}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PRECEDENT_NOT_FOUND — bugs 1 + 2
# ═══════════════════════════════════════════════════════════════════════════

# Two roots: G holds a grill work dir quoting the brief (bug 1); P has none,
# so the bug-2 cases cannot pass by resolving against .grill/.
G="${TMPDIR}/grill"
GSPECS="${G}/.ticket-auto/initiatives/INIT-1/artifacts/specs"
mkdir -p "${G}/app" "$GSPECS" "${G}/.grill/run-1/answers"
echo "# app" >"${G}/app/README.md"
cat >"${G}/.grill/run-1/answers/round-1.json" <<'EOF'
{"entities":["users"],"answers":[{"q":"store","a":"keep widgetCache in memory"}]}
EOF
P="${TMPDIR}/prec"
PSPECS="${P}/.ticket-auto/initiatives/INIT-1/artifacts/specs"
mkdir -p "${P}/app" "$PSPECS"
echo "# app" >"${P}/app/README.md"

echo "--- bug 1: an identifier quoted only in .grill/ answers is not resolved ---"
cat >"${GSPECS}/cache.md" <<'EOF'
## Technical Context
The cache mirrors the existing `widgetCache` helper.
EOF
out=$(planner_crosscheck_citations_one "${GSPECS}/cache.md" "$G" 2>&1)
if grep -q "PRECEDENT_NOT_FOUND.*'widgetCache'" <<<"$out"; then
  pass ".grill/ never resolves a precedent claim"
else
  fail ".grill/ never resolves a precedent claim" "$out"
fi

echo "--- bug 1: the contracts repo-definition search skips .grill/ too ---"
if _planner_crosscheck_contracts_exists_in_repo "$G" "users"; then
  fail "contracts search skips .grill/" "\`users\` resolved from .grill/"
else
  pass "contracts search skips .grill/"
fi

echo "--- bug 2: a structure the same spec creates is resolved (s13 shape) ---"
cat >"${PSPECS}/backend-foundation.md" <<'EOF'
## Technical Context
- `backend/src/store.js` exports `users`, `articles`, `reset()` and `insertUser(fields)`. `reset()` empties the existing `users` and `articles` arrays in place.
EOF
out=$(planner_crosscheck_citations_one "${PSPECS}/backend-foundation.md" "$P" 2>&1)
if ! grep -q "PRECEDENT_NOT_FOUND" <<<"$out"; then
  pass "in-plan structure (same spec) is not PRECEDENT_NOT_FOUND"
else
  fail "in-plan structure (same spec)" "$out"
fi

echo "--- bug 2: a structure another spec of the plan creates is resolved ---"
cat >"${PSPECS}/api-auth.md" <<'EOF'
## Technical Context
Registration reuses `insertUser` and follows the existing `articles` array layout.
EOF
out=$(planner_crosscheck_citations_one "${PSPECS}/api-auth.md" "$P" 2>&1)
if ! grep -q "PRECEDENT_NOT_FOUND" <<<"$out"; then
  pass "in-plan structure (sibling spec) is not PRECEDENT_NOT_FOUND"
else
  fail "in-plan structure (sibling spec)" "$out"
fi

echo "--- bug 2: a (new in <slug>) marker resolves the identifier ---"
cat >"${PSPECS}/editor.md" <<'EOF'
## Technical Context
Publishing reuses `toArticleResponse` (new in api-auth).
EOF
out=$(planner_crosscheck_citations_one "${PSPECS}/editor.md" "$P" 2>&1)
if ! grep -q "PRECEDENT_NOT_FOUND" <<<"$out"; then
  pass "(new in <slug>) resolves the identifier"
else
  fail "(new in <slug>) resolves" "$out"
fi

echo "--- recall guard: a mere mention elsewhere in the plan does not resolve ---"
cat >"${PSPECS}/server.md" <<'EOF'
## Technical Context
The app factory mirrors the existing `createServer` helper. Tests call `createServer` directly.
EOF
out=$(planner_crosscheck_citations_one "${PSPECS}/server.md" "$P" 2>&1)
if grep -q "PRECEDENT_NOT_FOUND.*'createServer'" <<<"$out"; then
  pass "an identifier no spec creates still fires"
else
  fail "an identifier no spec creates still fires" "$out"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CONTRACT_MISMATCH — bug 4
# ═══════════════════════════════════════════════════════════════════════════

C="${TMPDIR}/cm"
CSELF="${C}/.ticket-auto/initiatives/INIT-SELF/artifacts/specs"
CSIB="${C}/.ticket-auto/initiatives/INIT-SIB/artifacts/specs"
mkdir -p "$CSELF" "$CSIB"
cat >"${CSELF}/session-owner.md" <<'EOF'
## Description

`sessionStore` holds `token` and `expiresAt` for each signed-in member.
EOF
cat >"${CSELF}/session-consumer.md" <<'EOF'
## Description

Each handler calls `sessionStore` from `requireAuth` before it reads the body.
EOF

echo "--- bug 4: a sibling quoting the owner verbatim does not fire on a call site ---"
cat >"${CSIB}/session-api.md" <<'EOF'
## Description

`sessionStore` holds `token` and `expiresAt` for each signed-in member.
EOF
out=$(planner_crosscheck_contract_mismatch "INIT-SELF" "$CSELF" "$C")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass "sibling agreeing with the owner: no CONTRACT_MISMATCH against the consumer"
else
  fail "sibling agreeing with the owner" "rc=${rc} out=${out}"
fi

echo "--- recall guard: a sibling disjoint from the whole initiative still fires ---"
cat >"${CSIB}/session-api.md" <<'EOF'
## Description

`sessionStore` takes `sessionId` and `scope` only.
EOF
out=$(planner_crosscheck_contract_mismatch "INIT-SELF" "$CSELF" "$C")
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'CONTRACT_MISMATCH `sessionStore`.*session-owner.md' <<<"$out"; then
  pass "disjoint sibling: CONTRACT_MISMATCH"
else
  fail "disjoint sibling: CONTRACT_MISMATCH" "rc=${rc} out=${out}"
fi

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
