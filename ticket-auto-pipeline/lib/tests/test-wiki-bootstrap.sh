#!/usr/bin/env bash
# test-wiki-bootstrap.sh — unit tests for lib/wiki-bootstrap.sh
# Usage: bash test-wiki-bootstrap.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
BOOTSTRAP="$LIB_DIR/wiki-bootstrap.sh"

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
}
_teardown() {
  [ -n "$_ws" ] && rm -rf "$_ws"
  _ws=""
}

_OUT=""
_RC=0
_bootstrap() {
  set +e
  _OUT=$(bash "$BOOTSTRAP" --wiki-root "$_wiki" 2>&1)
  _RC=$?
  set -e
}

# ── test: full scaffold on an empty wiki root ───────────────────────────────
test_full_scaffold() {
  _setup
  _bootstrap
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q "^WIKI_BOOTSTRAP_STATUS=ok$" || ok=0
  echo "$_OUT" | grep -q "^WIKI_BOOTSTRAP_CREATED=index.md,decisions/index.md,glossary.md$" || ok=0
  [ -f "$_wiki/index.md" ] || ok=0
  [ -f "$_wiki/decisions/index.md" ] || ok=0
  [ -f "$_wiki/glossary.md" ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: scaffolded index.md carries the sections prescan-route.sh parses ──
test_index_schema() {
  _setup
  _bootstrap
  local ok=1
  grep -q "^## File Registry$" "$_wiki/index.md" || ok=0
  grep -q "^## Lookup by Topic$" "$_wiki/index.md" || ok=0
  grep -q "^## Lookup by Service$" "$_wiki/index.md" || ok=0
  # Table shape prescan-route.sh actually parses: | col | col |
  grep -qE '^\| Topic \| File \|$' "$_wiki/index.md" || ok=0
  grep -qE '^\| Service \| File \|$' "$_wiki/index.md" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: scaffolded glossary.md carries the wiki freshness frontmatter ─────
test_glossary_frontmatter() {
  _setup
  _bootstrap
  local ok=1
  head -1 "$_wiki/glossary.md" | grep -qx -- "---" || ok=0
  grep -q "^verified_at:" "$_wiki/glossary.md" || ok=0
  grep -q "^verified_against:" "$_wiki/glossary.md" || ok=0
  grep -q "^stale_after:" "$_wiki/glossary.md" || ok=0
  grep -q "^verified:" "$_wiki/glossary.md" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: no-op when the wiki already fully exists ──────────────────────────
test_noop_existing_wiki() {
  _setup
  _bootstrap
  echo "HAND-WRITTEN CONTENT" >>"$_wiki/index.md"
  local sentinel_sha
  sentinel_sha=$(sha256sum "$_wiki/decisions/index.md" | cut -d' ' -f1)
  _bootstrap
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q "^WIKI_BOOTSTRAP_CREATED=$" || ok=0
  grep -q "HAND-WRITTEN CONTENT" "$_wiki/index.md" || ok=0
  [ "$(sha256sum "$_wiki/decisions/index.md" | cut -d' ' -f1)" = "$sentinel_sha" ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: partial wiki — only missing pieces are scaffolded ─────────────────
test_partial_scaffold() {
  _setup
  _bootstrap
  echo "HAND-WRITTEN INDEX" >"$_wiki/index.md"
  rm -rf "$_wiki/decisions" "$_wiki/glossary.md"
  _bootstrap
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q "^WIKI_BOOTSTRAP_CREATED=decisions/index.md,glossary.md$" || ok=0
  grep -q "HAND-WRITTEN INDEX" "$_wiki/index.md" || ok=0
  [ -f "$_wiki/decisions/index.md" ] || ok=0
  [ -f "$_wiki/glossary.md" ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: no-op (and no crash) when WIKI_ROOT is unset ──────────────────────
test_noop_unset_wiki_root() {
  set +e
  _OUT=$(env -u WIKI_ROOT bash "$BOOTSTRAP" 2>&1)
  _RC=$?
  set -e
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q "^WIKI_BOOTSTRAP_STATUS=skipped$" || ok=0
  echo "$_OUT" | grep -q "^WIKI_BOOTSTRAP_REASON=no-wiki-root$" || ok=0
  [ "$ok" = "1" ]
}

# ── test: WIKI_ROOT env var is honored when --wiki-root is omitted ──────────
test_wiki_root_env_var() {
  _setup
  set +e
  _OUT=$(WIKI_ROOT="$_wiki" bash "$BOOTSTRAP" 2>&1)
  _RC=$?
  set -e
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  [ -f "$_wiki/index.md" ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── test: decisions/index.md matches adr-store.sh's own regenerated shape ───
test_decisions_index_matches_adr_store_shape() {
  _setup
  _bootstrap
  local ok=1
  grep -q "^# Decisions Index$" "$_wiki/decisions/index.md" || ok=0
  grep -qE '^\| ADR \| Title \| Status \| Date \| Source \|$' "$_wiki/decisions/index.md" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── term-drift: clean wiki reports nothing ──────────────────────────────────
test_term_drift_clean() {
  _setup
  _bootstrap
  set +e
  _OUT=$(bash "$BOOTSTRAP" term-drift --wiki-root "$_wiki" 2>&1)
  _RC=$?
  set -e
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  [ -z "$_OUT" ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── term-drift: avoided synonym in a flow file is reported ──────────────────
test_term_drift_violation() {
  _setup
  _bootstrap
  python3 - "$_wiki/glossary.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("(no entries yet)", "### Commission\n\nThe fee an intermediary earns.\n\nAvoid: fee, take-rate\n")
open(p, "w").write(s)
PY
  mkdir -p "$_wiki/flows"
  cat >"$_wiki/flows/billing.md" <<'EOF'
---
services: []
entities: []
flows: []
keywords: []
related: []
verified_at: "2026-01-01"
verified_against: {repo: "test", sha: "abc"}
stale_after: 90
verified: machine-verified
---
# Billing

We charge a platform fee at settlement using the take-rate table.
EOF
  set +e
  _OUT=$(bash "$BOOTSTRAP" term-drift --wiki-root "$_wiki" 2>&1)
  _RC=$?
  set -e
  local ok=1
  [ "$_RC" -eq 1 ] || ok=0
  echo "$_OUT" | grep -q "^TERM_DRIFT|.*flows/billing.md|fee|Commission$" || ok=0
  echo "$_OUT" | grep -q "^TERM_DRIFT|.*flows/billing.md|take-rate|Commission$" || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── term-drift: glossary.md's own Avoid: line is never flagged ──────────────
test_term_drift_ignores_glossary_itself() {
  _setup
  _bootstrap
  python3 - "$_wiki/glossary.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("(no entries yet)", "### Commission\n\nThe fee an intermediary earns.\n\nAvoid: fee\n")
open(p, "w").write(s)
PY
  set +e
  _OUT=$(bash "$BOOTSTRAP" term-drift --wiki-root "$_wiki" 2>&1)
  _RC=$?
  set -e
  local ok=1
  [ "$_RC" -eq 0 ] || ok=0
  [ -z "$_OUT" ] || ok=0
  _teardown
  [ "$ok" = "1" ]
}

# ── run ──────────────────────────────────────────────────────────────────────

FILTER="${1:-}"
for t in test_full_scaffold test_index_schema test_glossary_frontmatter \
  test_noop_existing_wiki test_partial_scaffold test_noop_unset_wiki_root \
  test_wiki_root_env_var test_decisions_index_matches_adr_store_shape \
  test_term_drift_clean test_term_drift_violation \
  test_term_drift_ignores_glossary_itself; do
  if [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]]; then continue; fi
  _run "$t" "$t"
done

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
