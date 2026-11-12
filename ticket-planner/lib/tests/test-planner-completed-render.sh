#!/usr/bin/env bash
# test-planner-completed-render.sh — planner_completed_render (DET-PL-4):
# COMPLETED.md is rendered in bash from the state log and epic manifest, and the
# Completed prompt runs the renderer instead of asking the agent to write it.
#
# Run: bash ticket-planner/lib/tests/test-planner-completed-render.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-completed.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
REPOS_ROOT="$TMPDIR"
export REPOS_ROOT

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
has() { grep -qF -- "$2" <<<"$1"; }

# Fake fleet-features.sh: prints FLEET_AUTO_DISPATCH=$FAKE_DISPATCH, never env-driven in prod.
FAKE_FF="$TMPDIR/fleet-features.sh"
cat >"$FAKE_FF" <<'EOF'
printf '{"flags":[{"name":"FLEET_AUTO_DISPATCH","value":"%s","source":"settings.local.json"}]}\n' "$FAKE_DISPATCH"
EOF
export FLEET_FEATURES_SH="$FAKE_FF"

# Fixture: all 11 phases, Specify retried, 3 created + 1 idempotent skip,
# one accepted Crosscheck finding, one test-data advisory.
mk_log() {
  local id="$1" dir
  dir="$TMPDIR/.ticket-auto/initiatives/$id"
  mkdir -p "$dir/artifacts"
  {
    echo "2026-01-01T00:00:00Z|META|schema|start|1"
    echo "2026-01-01T00:00:01Z|META|idea|start|Add CSV export"
    local i=10 p
    for p in Appraisal Discovery Architecture Specify Review Consensus Crosscheck EpicGen TicketGen Refinement Completed; do
      echo "2026-01-01T00:${i}:00Z|$p|main|start|go"
      if [ "$p" = Specify ]; then
        echo "2026-01-01T00:${i}:30Z|$p|main|fail|retry"
        echo "2026-01-01T00:${i}:40Z|$p|main|start|again"
      fi
      [ "$p" = Completed ] || echo "2026-01-01T00:${i}:50Z|$p|main|done|ok"
      [ "$p" != EpicGen ] || echo "2026-01-01T00:${i}:55Z|EpicGen|create|done|EPIC_ID=WIL-9"
      [ "$p" != Crosscheck ] || echo "2026-01-01T00:${i}:20Z|META|crosscheck|accepted|CARVE_SCOPE_LOST documented rescope"
      i=$((i + 1))
    done
    echo "2026-01-01T00:30:00Z|META|ticketgen|step|Created WIL-10: A"
    echo "2026-01-01T00:30:01Z|META|ticketgen|step|Created WIL-11: B"
    echo "2026-01-01T00:30:02Z|META|ticketgen|step|Created WIL-12: C"
    echo "2026-01-01T00:30:03Z|META|ticketgen|done|3 tickets created, 1 skipped (idempotent), 0 failed"
    echo "2026-01-01T00:31:00Z|META|refinement-testdata|warn|WIL-10 TEST_DATA_GAP: \"q\" — no user [abcd1234]"
  } >"$dir/state.log"
  mkdir -p "$TMPDIR/.ticket-auto/initiatives/WIL-9/epic"
  echo '{"children":["WIL-10","WIL-11","WIL-12","WIL-13"]}' >"$TMPDIR/.ticket-auto/initiatives/WIL-9/epic/manifest.json"
}

echo "--- happy path ---"
mk_log INIT-A
out=$(FAKE_DISPATCH=false planner_completed_render INIT-A)
doc=$(cat "$TMPDIR/.ticket-auto/initiatives/INIT-A/artifacts/COMPLETED.md")
has "$out" "COMPLETED_TICKETS=4" && pass "prints 4 tickets (3 created + 1 skip)" || fail "ticket count" "$out"
has "$out" "COMPLETED_EPIC=WIL-9" && pass "prints the epic" || fail "epic" "$out"
for h in "## Initiative" "## Tickets Created" "## Epic" "## Execution Status" "## Phase Timeline" "## Warnings"; do
  has "$doc" "$h" && pass "heading $h" || fail "heading $h" "missing"
done
has "$doc" "- WIL-13" && pass "manifest child without a Created line listed" || fail "WIL-13" "missing"
has "$doc" "**Idea:** Add CSV export" && pass "idea from the log" || fail "idea" "missing"
rows=$(grep -c '^| [A-Z][A-Za-z]* | 2026' <<<"$doc" || true)
[ "$rows" -eq 11 ] && pass "11 timeline rows" || fail "timeline rows" "$rows"
has "$doc" "| Specify | 2026-01-01T00:13:00Z | 2026-01-01T00:13:50Z |" && pass "retried phase: first start, last done" || fail "retry row" "$(grep Specify <<<"$doc")"
has "$doc" "| Completed | 2026-01-01T00:20:00Z | - |" && pass "Completed in progress has no end" || fail "Completed row" "missing"
has "$doc" "Crosscheck accepted by operator: CARVE_SCOPE_LOST documented rescope" && pass "accepted reason quoted" || fail "accepted" "missing"
has "$doc" "WIL-10 TEST_DATA_GAP" && pass "test-data advisory listed" || fail "advisory" "missing"
has "$doc" "WARNING: FLEET_AUTO_DISPATCH is not true" && pass "dispatch-off warning" || fail "dispatch warning" "missing"
has "$doc" "(source: settings.local.json)" && pass "dispatch source named" || fail "dispatch source" "missing"

echo "--- determinism ---"
FAKE_DISPATCH=false planner_completed_render INIT-A >/dev/null
[ "$doc" = "$(cat "$TMPDIR/.ticket-auto/initiatives/INIT-A/artifacts/COMPLETED.md")" ] &&
  pass "re-render byte-identical" || fail "determinism" "differs"

echo "--- no warnings ---"
mk_log INIT-B
sed -i '/accepted\|refinement-testdata/d' "$TMPDIR/.ticket-auto/initiatives/INIT-B/state.log"
FAKE_DISPATCH=true planner_completed_render INIT-B >/dev/null
doc=$(cat "$TMPDIR/.ticket-auto/initiatives/INIT-B/artifacts/COMPLETED.md")
grep -A1 '^## Warnings' <<<"$doc" | grep -qx 'None.' && pass "no warnings -> None." || fail "None." "$doc"
has "$doc" "WARNING:" && fail "dispatch on" "warned anyway" || pass "dispatch on: no warning"

echo "--- failure: no EPIC_ID ---"
mk_log INIT-C
sed -i '/EPIC_ID=/d' "$TMPDIR/.ticket-auto/initiatives/INIT-C/state.log"
if FAKE_DISPATCH=true planner_completed_render INIT-C >/dev/null 2>&1; then
  fail "no EPIC_ID" "rendered"
else
  [ ! -e "$TMPDIR/.ticket-auto/initiatives/INIT-C/artifacts/COMPLETED.md" ] &&
    pass "no EPIC_ID -> rc 1, nothing written" || fail "no EPIC_ID" "file written"
fi

echo "--- CLI ---"
FAKE_DISPATCH=true bash "${LIB_DIR}/planner-completed.sh" INIT-B | grep -q '^COMPLETED_TICKETS=4$' &&
  pass "CLI runs" || fail "CLI" "no output"

echo "--- prompt ---"
source "${LIB_DIR}/planner-phase-prompts.sh"
prompt=$(planner_prompt_completed INIT-A "idea" "$TMPDIR/.ticket-auto/initiatives/INIT-A")
has "$prompt" "planner-completed.sh" && pass "prompt runs the renderer" || fail "prompt renderer" "missing"
has "$prompt" "Write a completion summary" && fail "prompt" "still asks the agent to write it" || pass "prompt no longer hand-writes"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
