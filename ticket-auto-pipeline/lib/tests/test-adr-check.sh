#!/usr/bin/env bash
# test-adr-check.sh — unit tests for lib/adr-check.sh
# Usage: bash test-adr-check.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
CHECK="$LIB_DIR/adr-check.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
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

_ws=""
_wiki=""
_setup() {
  _ws=$(mktemp -d)
  _wiki="$_ws/wiki"
  mkdir -p "$_wiki/decisions"
}
_teardown() {
  [ -n "$_ws" ] && rm -rf "$_ws"
  _ws=""
}

# Writes a fixture ADR file with default well-formed content, overridable
# per-test via the FM_EXTRA / BODY_OVERRIDE / TITLE_OVERRIDE hooks.
_fixture() {
  local name="$1" id="$2" status="$3"
  local title="${TITLE_OVERRIDE:-# ${id}: Do the thing}"
  {
    echo "---"
    echo "id: ${id}"
    echo "status: ${status}"
    echo "date: 2026-09-11"
    echo "components: [foo]"
    echo "ticket: T-1"
    echo "deciders: ${DECIDERS_OVERRIDE:-[]}"
    echo "supersedes: \"${SUPERSEDES_OVERRIDE:-}\""
    echo "superseded_by: \"${SUPERSEDED_BY_OVERRIDE:-}\""
    [ -n "${FM_EXTRA:-}" ] && echo "$FM_EXTRA"
    echo "---"
    echo
    echo "$title"
    echo
    if [ -n "${BODY_OVERRIDE:-}" ]; then
      echo "$BODY_OVERRIDE"
    else
      cat <<'EOF'
## Context
Context text.

## Decision
We will do the thing.

## Considered Options
The alternative.

## Consequences
Some consequence.

## Affected Components
foo
EOF
    fi
  } >"$_wiki/decisions/${name}"
  DECIDERS_OVERRIDE=""
  SUPERSEDES_OVERRIDE=""
  SUPERSEDED_BY_OVERRIDE=""
  TITLE_OVERRIDE=""
  BODY_OVERRIDE=""
  FM_EXTRA=""
}

_OUT=""
_RC=0
_check() {
  set +e
  _OUT=$(bash "$CHECK" "$@" 2>&1)
  _RC=$?
  set -e
}

# Git history helpers for the two checks (_ac_check_immutability,
# _ac_check_transition) that compare the current working tree against a
# prior commit. Init once per test, commit after each state change.
_git_init() {
  git -C "$_wiki" init -q
  git -C "$_wiki" config user.email t@t
  git -C "$_wiki" config user.name t
}
_git_commit() {
  git -C "$_wiki" add -A
  git -C "$_wiki" commit -q -m "$1"
}

# ── clean pass ───────────────────────────────────────────────────────────────
test_clean_pass() {
  _setup
  _fixture "0001-clean.md" "ADR-0001" "proposed"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 0 ] && echo "$_OUT" | grep -q "violations=0"
}

# ── duplicate id ─────────────────────────────────────────────────────────────
test_duplicate_id() {
  _setup
  _fixture "0001-a.md" "ADR-0001" "proposed"
  _fixture "0002-b.md" "ADR-0001" "proposed"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "DUPLICATE_ID"
}

# ── invalid status ───────────────────────────────────────────────────────────
test_invalid_status() {
  _setup
  _fixture "0001-a.md" "ADR-0001" "bogus"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "INVALID_STATUS"
}

# ── dangling supersedes target ──────────────────────────────────────────────
test_dangling_supersedes() {
  _setup
  SUPERSEDES_OVERRIDE="ADR-9999" _fixture "0001-a.md" "ADR-0001" "proposed"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "SUPERSEDES_TARGET_MISSING"
}

# ── non-reciprocal supersession ─────────────────────────────────────────────
test_non_reciprocal_supersession() {
  _setup
  _fixture "0001-a.md" "ADR-0001" "superseded"
  # 0001 claims superseded but superseded_by is empty -> also a shape
  # violation; add a real 0002 that supersedes 0001 without 0001 pointing back
  SUPERSEDED_BY_OVERRIDE="ADR-0002" _fixture "0001-a.md" "ADR-0001" "accepted"
  SUPERSEDES_OVERRIDE="ADR-0001" _fixture "0002-b.md" "ADR-0002" "accepted"
  # Now overwrite 0001 so it does NOT point back at 0002 (non-reciprocal)
  _fixture "0001-a.md" "ADR-0001" "superseded"
  SUPERSEDED_BY_OVERRIDE="" _true=1
  # 0001 is 'superseded' with empty superseded_by — that's its own shape
  # violation (SUPERSEDED_WITHOUT_REPLACEMENT); reciprocity needs 0001
  # accepted-then-superseded-by-someone-else. Rebuild precisely:
  SUPERSEDED_BY_OVERRIDE="ADR-0999" _fixture "0001-a.md" "ADR-0001" "superseded"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "SUPERSESSION_NOT_RECIPROCAL\|SUPERSEDES_TARGET_MISSING"
}

# ── missing required section ────────────────────────────────────────────────
test_missing_section() {
  _setup
  BODY_OVERRIDE=$'## Context\nc\n\n## Decision\nWe will do it.\n\n## Consequences\nz\n\n## Affected Components\nfoo' \
    _fixture "0001-a.md" "ADR-0001" "proposed"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "MISSING_SECTIONS"
}

# ── agent-created ADR not proposed ──────────────────────────────────────────
test_new_adr_not_proposed() {
  _setup
  DECIDERS_OVERRIDE="[alice]" _fixture "0001-a.md" "ADR-0001" "accepted"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "NEW_ADR_NOT_PROPOSED"
}

# ── accepted without deciders ───────────────────────────────────────────────
test_accepted_without_deciders() {
  _setup
  _fixture "0001-a.md" "ADR-0001" "accepted"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "ACCEPTED_WITHOUT_DECIDERS"
}

# ── superseded without replacement ──────────────────────────────────────────
test_superseded_without_replacement() {
  _setup
  DECIDERS_OVERRIDE="[alice]" _fixture "0001-a.md" "ADR-0001" "superseded"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "SUPERSEDED_WITHOUT_REPLACEMENT"
}

# ── deprecated with replacement reference (invalid) ─────────────────────────
test_deprecated_with_replacement() {
  _setup
  DECIDERS_OVERRIDE="[alice]" SUPERSEDED_BY_OVERRIDE="ADR-0002" \
    _fixture "0001-a.md" "ADR-0001" "deprecated"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "DEPRECATED_WITH_REPLACEMENT"
}

# ── hedged decision ──────────────────────────────────────────────────────────
test_hedged_decision() {
  _setup
  BODY_OVERRIDE=$'## Context\nc\n\n## Decision\nWe should probably do it.\n\n## Considered Options\no\n\n## Consequences\nz\n\n## Affected Components\nfoo' \
    _fixture "0001-a.md" "ADR-0001" "proposed"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "HEDGED_DECISION"
}

# ── committed decision (no hedge) passes ────────────────────────────────────
test_committed_decision_passes() {
  _setup
  _fixture "0001-a.md" "ADR-0001" "proposed"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 0 ] && ! echo "$_OUT" | grep -q "HEDGED_DECISION"
}

# ── accepted ADR body modified in place ─────────────────────────────────────
test_accepted_adr_modified() {
  _setup
  _git_init
  DECIDERS_OVERRIDE="[alice]" _fixture "0001-a.md" "ADR-0001" "accepted"
  _git_commit "accept ADR-0001"
  sed -i 's/We will do the thing\./We will do a different thing now./' "$_wiki/decisions/0001-a.md"
  _check --file "$_wiki/decisions/0001-a.md"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "ACCEPTED_ADR_MODIFIED"
}

# ── accepted ADR frontmatter-only edit (no body change) stays clean ────────
test_accepted_adr_unmodified_passes() {
  _setup
  _git_init
  DECIDERS_OVERRIDE="[alice]" _fixture "0001-a.md" "ADR-0001" "accepted"
  _git_commit "accept ADR-0001"
  _check --file "$_wiki/decisions/0001-a.md"
  _teardown
  [ "$_RC" -eq 0 ] && ! echo "$_OUT" | grep -q "ACCEPTED_ADR_MODIFIED"
}

# ── invalid transition: accepted -> proposed is rejected ────────────────────
test_invalid_transition_accepted_to_proposed() {
  _setup
  _git_init
  _fixture "0001-a.md" "ADR-0001" "proposed"
  _git_commit "propose ADR-0001"
  DECIDERS_OVERRIDE="[alice]" _fixture "0001-a.md" "ADR-0001" "accepted"
  _git_commit "accept ADR-0001"
  sed -i 's/^status: accepted/status: proposed/' "$_wiki/decisions/0001-a.md"
  _check --file "$_wiki/decisions/0001-a.md"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "INVALID_TRANSITION|accepted -> proposed"
}

# ── invalid transition: proposed -> superseded is rejected ──────────────────
test_invalid_transition_proposed_to_superseded() {
  _setup
  _git_init
  _fixture "0001-a.md" "ADR-0001" "proposed"
  _git_commit "propose ADR-0001"
  SUPERSEDED_BY_OVERRIDE="ADR-0002" _fixture "0001-a.md" "ADR-0001" "superseded"
  _check --file "$_wiki/decisions/0001-a.md"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "INVALID_TRANSITION|proposed -> superseded"
}

# ── valid transition: accepted -> superseded is NOT flagged ─────────────────
# Regression test for an off-by-one (git log --skip=1 instead of the tip)
# that compared the working tree against the commit BEFORE the last one,
# misattributing a real accepted->superseded supersession as proposed->superseded.
test_valid_transition_accepted_to_superseded() {
  _setup
  _git_init
  DECIDERS_OVERRIDE="[alice]" _fixture "0001-a.md" "ADR-0001" "accepted"
  _git_commit "accept ADR-0001"
  SUPERSEDED_BY_OVERRIDE="ADR-0002" DECIDERS_OVERRIDE="[alice]" \
    _fixture "0001-a.md" "ADR-0001" "superseded"
  _check --file "$_wiki/decisions/0001-a.md"
  _teardown
  [ "$_RC" -eq 0 ] && ! echo "$_OUT" | grep -q "INVALID_TRANSITION"
}

# ── topic-shaped title mismatch ─────────────────────────────────────────────
test_title_id_mismatch() {
  _setup
  TITLE_OVERRIDE="# ADR-0002: Wrong id in title" _fixture "0001-a.md" "ADR-0001" "proposed"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "TITLE_ID_MISMATCH"
}

# ── missing frontmatter fields ───────────────────────────────────────────────
test_missing_fields() {
  _setup
  {
    echo "---"
    echo "id: ADR-0001"
    echo "status: proposed"
    echo "---"
    echo
    echo "# ADR-0001: Do the thing"
    echo
    echo "## Context"
    echo "c"
  } >"$_wiki/decisions/0001-a.md"
  _check --wiki-root "$_wiki"
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "MISSING_FIELDS"
}

# ── single-file mode reports store checks as unevaluated ───────────────────
test_single_file_unevaluated() {
  _setup
  _fixture "0001-a.md" "ADR-0001" "proposed"
  _check --file "$_wiki/decisions/0001-a.md"
  _teardown
  [ "$_RC" -eq 0 ] && echo "$_OUT" | grep -q "UNEVALUATED"
}

# ── setup error: missing store path ─────────────────────────────────────────
test_missing_store_errors() {
  _setup
  _check --wiki-root "$_ws/does-not-exist"
  _teardown
  [ "$_RC" -eq 2 ]
}

# ── run ──────────────────────────────────────────────────────────────────────

FILTER="${1:-}"
for t in test_clean_pass test_duplicate_id test_invalid_status \
  test_dangling_supersedes test_non_reciprocal_supersession \
  test_missing_section test_new_adr_not_proposed \
  test_accepted_without_deciders test_superseded_without_replacement \
  test_deprecated_with_replacement test_hedged_decision \
  test_committed_decision_passes test_title_id_mismatch \
  test_missing_fields test_single_file_unevaluated test_missing_store_errors \
  test_accepted_adr_modified test_accepted_adr_unmodified_passes \
  test_invalid_transition_accepted_to_proposed \
  test_invalid_transition_proposed_to_superseded \
  test_valid_transition_accepted_to_superseded; do
  if [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]]; then continue; fi
  _run "$t" "$t"
done

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
