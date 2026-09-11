#!/usr/bin/env bash
# test-wiki-verify.sh — unit tests for lib/wiki-verify.sh
# Usage: bash test-wiki-verify.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
VERIFY="$LIB_DIR/wiki-verify.sh"
BOOTSTRAP="$LIB_DIR/wiki-bootstrap.sh"
ADR_STORE="$LIB_DIR/adr-store.sh"

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
  bash "$BOOTSTRAP" --wiki-root "$_wiki" >/dev/null
}
_teardown() {
  [ -n "$_ws" ] && rm -rf "$_ws"
  _ws=""
}

_OUT=""
_RC=0
_verify() {
  set +e
  _OUT=$(timeout 30 bash "$VERIFY" --wiki-root "$_wiki" 2>&1)
  _RC=$?
  set -e
}

# Writes a well-formed ADR into the store via adr-store.sh's own write path
# (registers correctly in the index — not a hand-written fixture) and
# returns its id via stdout.
_write_clean_adr() {
  local title="$1" components="$2" source_flag="$3" source_val="$4"
  local body="$_ws/body-$$-$RANDOM.md"
  cat >"$body" <<'EOF'
## Context

Some context.

## Decision

We will do the thing.

## Considered Options

- Option A
- Option B

## Consequences

Some consequence.

## Affected Components

component-x
EOF
  local out
  out=$(bash "$ADR_STORE" write --wiki-root "$_wiki" --title "$title" \
    --components "$components" "--${source_flag}" "$source_val" --body-file "$body")
  echo "$out" | grep '^ADR_ID=' | cut -d= -f2
}

# Hand-written ADR fixture bypassing adr_write, for constructing states the
# store's own write path would refuse to produce (duplicate source, a
# missing required section) — same technique as test-adr-check.sh's
# _fixture helper.
_fixture_adr() {
  local filename="$1" id="$2" source_line="$3" sections_override="$4"
  mkdir -p "$_wiki/decisions"
  {
    echo "---"
    echo "id: ${id}"
    echo "status: proposed"
    echo "date: 2026-09-11"
    echo "components: [component-x]"
    echo "$source_line"
    echo "deciders: []"
    echo "supersedes: \"\""
    echo "superseded_by: \"\""
    echo "---"
    echo
    echo "# ${id}: Fixture decision"
    echo
    if [ -n "$sections_override" ]; then
      echo "$sections_override"
    else
      echo "## Context"
      echo
      echo "Ctx."
      echo
      echo "## Decision"
      echo
      echo "We will do it."
      echo
      echo "## Considered Options"
      echo
      echo "- A"
      echo
      echo "## Consequences"
      echo
      echo "Cons."
      echo
      echo "## Affected Components"
      echo
      echo "component-x"
    fi
  } >"$_wiki/decisions/$filename"
}

# ── clean golden fixture ─────────────────────────────────────────────────────

test_clean_wiki_verifies() {
  _setup
  _write_clean_adr "Use Redis" "component-x" "manual" "M-1" >/dev/null
  _verify
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -qE '^WIKI_VERIFY_SUMMARY\|checks=[0-9]+\|violations=0$' || ok=0
  echo "$_OUT" | grep -q '^WIKI_VERIFY|' && ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── registry completeness (task 8.2) ────────────────────────────────────────

test_unregistered_file() {
  _setup
  cat >"$_wiki/orphan.md" <<'EOF'
---
services: []
entities: []
flows: []
keywords: []
related: []
verified_at: "2026-09-11"
verified_against: {repo: "x", sha: "abc"}
stale_after: 90
verified: machine-verified
---
# Orphan
EOF
  _verify
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q '^WIKI_VERIFY|UNREGISTERED_FILE|.*orphan.md|' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_orphaned_registry_row() {
  _setup
  python3 - "$_wiki/index.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("| (no entries yet) | |\n\n## Lookup by Topic",
              "| ghost.md | never existed |\n\n## Lookup by Topic")
open(p, "w").write(s)
PY
  _verify
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q "^WIKI_VERIFY|ORPHANED_REGISTRY_ROW|.*index.md|registry names 'ghost.md'" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── related: link integrity (task 8.3) ──────────────────────────────────────

test_broken_related_link() {
  _setup
  cat >"$_wiki/flow-a.md" <<'EOF'
---
services: []
entities: []
flows: []
keywords: []
related: ["missing.md"]
verified_at: "2026-09-11"
verified_against: {repo: "x", sha: "abc"}
stale_after: 90
verified: machine-verified
---
# Flow A
EOF
  python3 - "$_wiki/index.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("| (no entries yet) | |\n\n## Lookup by Topic",
              "| flow-a.md | test |\n\n## Lookup by Topic")
open(p, "w").write(s)
PY
  _verify
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q "^WIKI_VERIFY|LINK_INTEGRITY|.*flow-a.md|related: target 'missing.md' does not exist$" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── ADR store integrity backstop (tasks 8.4, 8.6) ───────────────────────────

test_adr_schema_violation_forwarded() {
  _setup
  _fixture_adr "0001-broken.md" "ADR-0001" "manual: M-1" "## Context

Ctx only, no other sections."
  _verify
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q '^WIKI_VERIFY|ADR_CHECK:MISSING_SECTIONS|.*0001-broken.md|' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_adr_duplicate_source_forwarded() {
  _setup
  _fixture_adr "0001-first.md" "ADR-0001" "manual: DUP-1" ""
  _fixture_adr "0002-second.md" "ADR-0002" "manual: DUP-1" ""
  _verify
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q '^WIKI_VERIFY|ADR_CHECK:DUPLICATE_SOURCE|' || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── decisions-index consistency (task 8.5) ──────────────────────────────────

test_unindexed_adr() {
  _setup
  local id
  id=$(_write_clean_adr "Use Postgres" "component-x" "manual" "M-2")
  local fname
  fname=$(basename "$(find "$_wiki/decisions" -maxdepth 1 -name '*.md' ! -name index.md)")
  # Drop the row adr_write's own regen just wrote — simulates index drift.
  python3 - "$_wiki/decisions/index.md" "$id" <<'PY'
import sys
p, adr_id = sys.argv[1], sys.argv[2]
lines = open(p).read().splitlines(keepends=True)
lines = [l for l in lines if not l.startswith(f"| {adr_id}")]
open(p, "w").writelines(lines)
PY
  _verify
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q "^WIKI_VERIFY|UNINDEXED_ADR|.*${fname}|id '${id}' has no row" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_index_orphan_row() {
  _setup
  _write_clean_adr "Use Postgres" "component-x" "manual" "M-2" >/dev/null
  echo '| ADR-0099 | Ghost | proposed | 2026-09-11 | manual:GHOST |' >>"$_wiki/decisions/index.md"
  _verify
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q "^WIKI_VERIFY|INDEX_ORPHAN_ROW|.*index.md|index names 'ADR-0099'" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── glossary: term-drift + entry-rot (task 8.8) ─────────────────────────────

test_glossary_term_drift() {
  _setup
  python3 - "$_wiki/glossary.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("(no entries yet)", "### Commission\n\nThe amount earned per transaction.\n\nAvoid: fee\n")
open(p, "w").write(s)
PY
  cat >"$_wiki/flow-b.md" <<'EOF'
---
services: []
entities: []
flows: []
keywords: []
related: []
verified_at: "2026-09-11"
verified_against: {repo: "x", sha: "abc"}
stale_after: 90
verified: machine-verified
---
# Flow B

We charge a fee at settlement, and the commission table drives payout too.
EOF
  python3 - "$_wiki/index.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("| (no entries yet) | |\n\n## Lookup by Topic",
              "| flow-b.md | test |\n\n## Lookup by Topic")
open(p, "w").write(s)
PY
  _verify
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q "^WIKI_VERIFY|TERM_DRIFT|.*flow-b.md|uses avoided synonym 'fee' for preferred term 'Commission'$" || ok=0
  # "commission" also appears in flow-b.md, so the term itself is used — no rot.
  echo "$_OUT" | grep -q '^WIKI_VERIFY|GLOSSARY_ROT|' && ok=0
  _teardown
  [ "$ok" = "1" ]
}

test_glossary_entry_rot() {
  _setup
  python3 - "$_wiki/glossary.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("(no entries yet)", "### NeverUsedTerm\n\nA term nobody references.\n")
open(p, "w").write(s)
PY
  _verify
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q "^WIKI_VERIFY|GLOSSARY_ROT|.*glossary.md|term 'NeverUsedTerm' has no usages" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── violation output grammar / non-blocking / setup failure (task 8.9) ──────

test_setup_failure_distinguishable_from_clean() {
  set +e
  _OUT=$(timeout 10 bash "$VERIFY" --wiki-root "/nonexistent/$$/path" 2>&1)
  _RC=$?
  set -e
  local ok=1
  [ "$_RC" -eq 2 ] || ok=0
  echo "$_OUT" | grep -q '^ERROR:' || ok=0
  echo "$_OUT" | grep -q '^WIKI_VERIFY_SUMMARY' && ok=0
  [ "$ok" = "1" ]
}

test_usage_error_missing_flag() {
  set +e
  _OUT=$(timeout 10 bash "$VERIFY" 2>&1)
  _RC=$?
  set -e
  [ "$_RC" -eq 2 ]
}

# ── run ──────────────────────────────────────────────────────────────────────

FILTER="${1:-}"
for t in test_clean_wiki_verifies test_unregistered_file test_orphaned_registry_row \
  test_broken_related_link test_adr_schema_violation_forwarded \
  test_adr_duplicate_source_forwarded test_unindexed_adr test_index_orphan_row \
  test_glossary_term_drift test_glossary_entry_rot \
  test_setup_failure_distinguishable_from_clean test_usage_error_missing_flag; do
  if [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]]; then continue; fi
  _run "$t" "$t"
done

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
