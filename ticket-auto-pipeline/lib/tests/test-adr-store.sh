#!/usr/bin/env bash
# test-adr-store.sh — unit tests for lib/adr-store.sh
# Usage: bash test-adr-store.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
STORE="$LIB_DIR/adr-store.sh"

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
  mkdir -p "$_wiki"
}
_teardown() {
  [ -n "$_ws" ] && rm -rf "$_ws"
  _ws=""
}

_body() {
  cat >"$_ws/body.md" <<'EOF'
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
}

_OUT=""
_RC=0
_write() {
  local title="$1" components="$2" source_flag="$3" source_val="$4"
  set +e
  _OUT=$(env -u CLAUDE_CODE_SESSION_ID bash "$STORE" write --wiki-root "$_wiki" \
    --title "$title" --components "$components" "$source_flag" "$source_val" \
    --body-file "$_ws/body.md" 2>&1)
  _RC=$?
  set -e
}

# ── test: first ADR in an empty store gets 0001 ─────────────────────────────
test_first_adr_numbering() {
  _setup
  _body
  _write "Do X" "foo" --ticket "T-1"
  _teardown
  echo "$_OUT" | grep -q "ADR_ID=ADR-0001"
}

# ── test: gap-tolerant numbering ────────────────────────────────────────────
test_gap_tolerant_numbering() {
  _setup
  mkdir -p "$_wiki/decisions"
  touch "$_wiki/decisions/0001-foo.md" "$_wiki/decisions/0003-bar.md"
  _body
  _write "Do X" "foo" --ticket "T-1"
  _teardown
  echo "$_OUT" | grep -q "ADR_ID=ADR-0004"
}

# ── test: existence check true ──────────────────────────────────────────────
test_exists_true() {
  _setup
  _body
  _write "Do X" "foo" --ticket "T-1"
  set +e
  _OUT=$(bash "$STORE" exists --wiki-root "$_wiki" T-1)
  _RC=$?
  set -e
  _teardown
  [ "$_RC" -eq 0 ] && echo "$_OUT" | grep -q "ADR_STORE_EXISTS=true"
}

# ── test: existence check false ─────────────────────────────────────────────
test_exists_false() {
  _setup
  _body
  _write "Do X" "foo" --ticket "T-1"
  set +e
  _OUT=$(bash "$STORE" exists --wiki-root "$_wiki" T-999)
  _RC=$?
  set -e
  _teardown
  [ "$_RC" -eq 1 ] && echo "$_OUT" | grep -q "ADR_STORE_EXISTS=false"
}

# ── test: existence match survives a title change (idempotent re-run) ──────
test_exists_after_title_change() {
  _setup
  _body
  _write "Do X" "foo" --ticket "T-1"
  local first_id
  first_id=$(echo "$_OUT" | grep ADR_ID= | cut -d= -f2)
  _write "Do X, renamed" "foo,bar" --ticket "T-1"
  local second_id count
  second_id=$(echo "$_OUT" | grep ADR_ID= | cut -d= -f2)
  count=$(find "$_wiki/decisions" -maxdepth 1 -name '*.md' ! -name index.md | wc -l | tr -d ' ')
  _teardown
  echo "$_OUT" | grep -q "ADR_STORE_STATUS=exists" &&
    [ "$first_id" = "$second_id" ] && [ "$count" = "1" ]
}

# ── test: index regenerated after a write ───────────────────────────────────
test_index_regeneration() {
  _setup
  _body
  _write "Do X" "foo" --ticket "T-1"
  local ok=0
  grep -q "ADR-0001" "$_wiki/decisions/index.md" &&
    grep -q "Do X" "$_wiki/decisions/index.md" &&
    grep -q "proposed" "$_wiki/decisions/index.md" && ok=1
  _teardown
  [ "$ok" = "1" ]
}

# ── test: index reflects a status change after accept ───────────────────────
test_index_reflects_status_change() {
  _setup
  _body
  _write "Do X" "foo" --ticket "T-1"
  env -u CLAUDE_CODE_SESSION_ID bash "$STORE" accept --wiki-root "$_wiki" ADR-0001 --deciders "alice" >/dev/null
  local ok=1
  grep -q "| accepted |" "$_wiki/decisions/index.md" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: concurrent writers get distinct sequential numbers ───────────────
test_concurrent_write_race() {
  _setup
  _body
  local pids=()
  local i
  for i in 1 2 3 4 5; do
    (env -u CLAUDE_CODE_SESSION_ID bash "$STORE" write --wiki-root "$_wiki" \
      --title "Concurrent $i" --components "foo" --ticket "T-$i" \
      --body-file "$_ws/body.md" >"$_ws/out-$i.txt" 2>&1) &
    pids+=("$!")
  done
  local pid
  for pid in "${pids[@]}"; do wait "$pid"; done
  local count ids_unique
  count=$(find "$_wiki/decisions" -maxdepth 1 -name '*.md' ! -name index.md | wc -l | tr -d ' ')
  ids_unique=$(grep -h '^id:' "$_wiki"/decisions/*.md | sort -u | wc -l | tr -d ' ')
  local idx_rows
  idx_rows=$(grep -c '^| ADR-' "$_wiki/decisions/index.md")
  _teardown
  [ "$count" = "5" ] && [ "$ids_unique" = "5" ] && [ "$idx_rows" = "5" ]
}

# ── test: agent-context refuses accept ──────────────────────────────────────
test_accept_refused_in_agent_context() {
  _setup
  _body
  _write "Do X" "foo" --ticket "T-1"
  set +e
  _OUT=$(CLAUDE_CODE_SESSION_ID=fake-session bash "$STORE" accept --wiki-root "$_wiki" ADR-0001 --deciders "alice" 2>&1)
  _RC=$?
  set -e
  _teardown
  [ "$_RC" -eq 4 ]
}

# ── test: invalid transition (accepted -> proposed unreachable, superseded re-accept rejected) ──
test_invalid_transition_rejected() {
  _setup
  _body
  _write "Do X" "foo" --ticket "T-1"
  env -u CLAUDE_CODE_SESSION_ID bash "$STORE" accept --wiki-root "$_wiki" ADR-0001 --deciders "alice" >/dev/null
  set +e
  _OUT=$(env -u CLAUDE_CODE_SESSION_ID bash "$STORE" accept --wiki-root "$_wiki" ADR-0001 --deciders "bob" 2>&1)
  _RC=$?
  set -e
  _teardown
  [ "$_RC" -eq 3 ]
}

# ── test: supersession auto-triggers on accepting a replacement ────────────
test_auto_supersede_on_accept() {
  _setup
  _body
  _write "Do X" "foo" --ticket "T-1"
  env -u CLAUDE_CODE_SESSION_ID bash "$STORE" accept --wiki-root "$_wiki" ADR-0001 --deciders "alice" >/dev/null
  _write "Do Y instead" "foo" --ticket "T-2"
  local newid
  newid=$(echo "$_OUT" | grep ADR_ID= | cut -d= -f2)
  # supersedes wasn't passed via _write helper — write directly with --supersedes
  set +e
  _OUT=$(env -u CLAUDE_CODE_SESSION_ID bash "$STORE" write --wiki-root "$_wiki" \
    --title "Do Y instead v2" --components "foo" --ticket "T-3" \
    --body-file "$_ws/body.md" --supersedes "ADR-0001")
  _RC=$?
  set -e
  local replacement_id
  replacement_id=$(echo "$_OUT" | grep ADR_ID= | cut -d= -f2)
  env -u CLAUDE_CODE_SESSION_ID bash "$STORE" accept --wiki-root "$_wiki" "$replacement_id" --deciders "bob" >/dev/null
  local ok=1
  grep -q "^status: superseded" "$_wiki/decisions/0001"*.md || ok=0
  grep -q "superseded_by: \"${replacement_id}\"" "$_wiki/decisions/0001"*.md || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: query by component ────────────────────────────────────────────────
test_query_by_component() {
  _setup
  _body
  _write "Do X" "foo,bar" --ticket "T-1"
  _write "Do Z" "baz" --ticket "T-2"
  set +e
  _OUT=$(bash "$STORE" query --wiki-root "$_wiki" --components "bar")
  _RC=$?
  set -e
  _teardown
  [ "$_RC" -eq 0 ] && echo "$_OUT" | grep -q "ADR-0001" && ! echo "$_OUT" | grep -q "ADR-0002"
}

# ── run ──────────────────────────────────────────────────────────────────────

FILTER="${1:-}"
for t in test_first_adr_numbering test_gap_tolerant_numbering test_exists_true \
  test_exists_false test_exists_after_title_change test_index_regeneration \
  test_index_reflects_status_change test_concurrent_write_race \
  test_accept_refused_in_agent_context test_invalid_transition_rejected \
  test_auto_supersede_on_accept test_query_by_component; do
  if [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]]; then continue; fi
  _run "$t" "$t"
done

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
