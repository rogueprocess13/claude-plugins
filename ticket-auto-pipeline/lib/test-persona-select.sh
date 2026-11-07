#!/usr/bin/env bash
# test-persona-select.sh — unit tests for lib/persona-select.sh
# Tests the selection tables, specializer detection, auto-include keywords,
# graceful fallback, and error handling.
set -euo pipefail

# The selector falls back to the ticket's local manifest `type` when TICKET_ID
# and REPOS_ROOT are both set. Unset them so a pipeline worker's environment
# cannot change the result of any case below; the manifest cases set them
# explicitly per invocation.
unset TICKET_ID REPOS_ROOT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTOR="$SCRIPT_DIR/persona-select.sh"
PASS=0
FAIL=0

# ── Helpers ────────────────────────────────────────────────────────────────────

assert_contains() {
  local desc="$1" output="$2" key="$3" expected="$4"
  local actual
  actual=$(echo "$output" | grep "^${key}=" | cut -d'=' -f2-)
  if echo "$actual" | grep -q "$expected"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — expected '$expected' in ${key}=${actual}" >&2
  fi
}

assert_empty() {
  local desc="$1" output="$2" key="$3"
  local actual
  actual=$(echo "$output" | grep "^${key}=" | cut -d'=' -f2-)
  if [ -z "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — expected empty ${key}, got '${actual}'" >&2
  fi
}

assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — expected exit $expected, got $actual" >&2
  fi
}

# ── Setup: create temp repo directories with mock files ────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Python project
mkdir -p "$TMPDIR/python-project"
touch "$TMPDIR/python-project/pyproject.toml"

# Java project
mkdir -p "$TMPDIR/java-project"
touch "$TMPDIR/java-project/pom.xml"

# Node.js backend project
mkdir -p "$TMPDIR/node-project"
cat >"$TMPDIR/node-project/package.json" <<'JSON'
{"name": "api", "dependencies": {"express": "^4.0.0"}}
JSON

# Angular project
mkdir -p "$TMPDIR/angular-project"
touch "$TMPDIR/angular-project/angular.json"
cat >"$TMPDIR/angular-project/package.json" <<'JSON'
{"name": "ng-app"}
JSON

# React project
mkdir -p "$TMPDIR/react-project"
cat >"$TMPDIR/react-project/package.json" <<'JSON'
{"name": "react-app", "dependencies": {"react": "^18.0.0", "react-dom": "^18.0.0"}}
JSON

# Vue project
mkdir -p "$TMPDIR/vue-project"
cat >"$TMPDIR/vue-project/package.json" <<'JSON'
{"name": "vue-app", "dependencies": {"vue": "^3.0.0"}}
JSON

# Unknown project (no markers)
mkdir -p "$TMPDIR/unknown-project"

# Multi-service project
mkdir -p "$TMPDIR/microservices-project/services/auth"
mkdir -p "$TMPDIR/microservices-project/services/orders"

# ── Test: Base persona selection (layer + phase combinations) ─────────────────

echo "## Base persona selection"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer FE --phase implement)
assert_contains "FE + implement → frontend-developer" "$output" "PERSONA_BASE" "frontend-developer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "BE + implement → backend-developer" "$output" "PERSONA_BASE" "backend-developer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer infra --phase implement)
assert_contains "infra + implement → backend-developer" "$output" "PERSONA_BASE" "backend-developer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --phase appraise)
assert_contains "appraise phase → analyzer" "$output" "PERSONA_BASE" "analyzer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --phase review)
assert_contains "review phase → analyzer" "$output" "PERSONA_BASE" "analyzer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --phase audit)
assert_contains "audit phase → product-owner" "$output" "PERSONA_BASE" "product-owner"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer FE)
assert_contains "FE layer, no phase → frontend-developer" "$output" "PERSONA_BASE" "frontend-developer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE)
assert_contains "BE layer, no phase → backend-developer" "$output" "PERSONA_BASE" "backend-developer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_contains "no flags → analyzer (default)" "$output" "PERSONA_BASE" "analyzer"

# ── Test: Specializer detection ────────────────────────────────────────────────

echo "## Specializer detection"

output=$("$SELECTOR" --repo "$TMPDIR/python-project" --layer BE --phase implement)
assert_contains "pyproject.toml → python specializer" "$output" "PERSONA_SPECIALIZER" "backend/python"

output=$("$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "pom.xml → java specializer" "$output" "PERSONA_SPECIALIZER" "backend/java"

# Migration keyword in ticket overrides standard java specializer
output=$(TICKET_TITLE="Upgrade Java from 8 to 25" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "Java + upgrade keyword → migration specializer" "$output" "PERSONA_SPECIALIZER" "backend/java-migration"

output=$(TICKET_DESCRIPTION="Migrate all services to Java 21 LTS" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "Java + migrate keyword → migration specializer" "$output" "PERSONA_SPECIALIZER" "backend/java-migration"

# No migration keywords → still gets standard java specializer (not migration)
output=$(TICKET_TITLE="Add new REST endpoint for orders" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "Java + no migration keyword → standard java" "$output" "PERSONA_SPECIALIZER" "backend/java"

# Refactor keyword overrides standard specializer (Java)
output=$(TICKET_TITLE="Refactor order service to use repository pattern" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "Java + refactor keyword → refactor specializer" "$output" "PERSONA_SPECIALIZER" "backend/java-refactor"

output=$(TICKET_DESCRIPTION="Code quality cleanup of the payment module" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "Java + code quality cleanup keyword → refactor" "$output" "PERSONA_SPECIALIZER" "backend/java-refactor"

# Refactor keyword overrides standard (Python)
output=$(TICKET_TITLE="Refactor auth middleware for clarity" "$SELECTOR" --repo "$TMPDIR/python-project" --layer BE --phase implement)
assert_contains "Python + refactor keyword → refactor specializer" "$output" "PERSONA_SPECIALIZER" "backend/python-refactor"

# Refactor keyword (Node)
output=$(TICKET_TITLE="Restructure Express routes for consistency" "$SELECTOR" --repo "$TMPDIR/node-project" --layer BE --phase implement)
assert_contains "Node + restructure keyword → refactor specializer" "$output" "PERSONA_SPECIALIZER" "backend/node-refactor"

# Refactor without language stack → no specializer (no base stack to extend)
output=$(TICKET_TITLE="Refactor configuration loading" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_empty "refactor + unknown stack → empty specializer" "$output" "PERSONA_SPECIALIZER"

# Multi-word refactor keywords
output=$(TICKET_TITLE="Clean up the authentication service" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "clean up keyword → refactor specializer" "$output" "PERSONA_SPECIALIZER" "backend/java-refactor"

output=$(TICKET_DESCRIPTION="Pay down technical debt in the data layer" "$SELECTOR" --repo "$TMPDIR/python-project" --layer BE --phase implement)
assert_contains "technical debt keyword → refactor specializer" "$output" "PERSONA_SPECIALIZER" "backend/python-refactor"

# Migration > refactor priority (migration wins when both keywords present)
output=$(TICKET_TITLE="Upgrade and refactor Java from 8 to 25" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "migration + refactor → migration wins" "$output" "PERSONA_SPECIALIZER" "backend/java-migration"

# Non-Java upgrade → standard, not migration (only Java has migration specializer)
output=$(TICKET_TITLE="Upgrade Python from 3.9 to 3.12" "$SELECTOR" --repo "$TMPDIR/python-project" --layer BE --phase implement)
assert_contains "Python + upgrade → standard python (no migration override)" "$output" "PERSONA_SPECIALIZER" "backend/python"

# BE_TEST_RUNNER with pyenv + refactor → python-refactor
output=$(BE_TEST_RUNNER="pyenv exec pytest" TICKET_TITLE="Refactor auth module" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "BE_TEST_RUNNER pyenv + refactor → python-refactor" "$output" "PERSONA_SPECIALIZER" "backend/python-refactor"

# Java + security auto-include + refactor (three-path emission)
output=$(TICKET_TITLE="Refactor payment processing module" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "refactor + payment → refactor specializer" "$output" "PERSONA_SPECIALIZER" "backend/java-refactor"
assert_contains "refactor + payment → security auto-include" "$output" "PERSONA_AUTO_INCLUDE" "security"

output=$("$SELECTOR" --repo "$TMPDIR/node-project" --layer BE --phase implement)
assert_contains "package.json w/o FE → node specializer" "$output" "PERSONA_SPECIALIZER" "backend/node"

output=$("$SELECTOR" --repo "$TMPDIR/angular-project" --layer FE --phase implement)
assert_contains "angular.json → angular specializer" "$output" "PERSONA_SPECIALIZER" "frontend/angular"

output=$("$SELECTOR" --repo "$TMPDIR/react-project" --layer FE --phase implement)
assert_contains "react in package.json → react specializer" "$output" "PERSONA_SPECIALIZER" "frontend/react"

output=$("$SELECTOR" --repo "$TMPDIR/vue-project" --layer FE --phase implement)
assert_contains "vue in package.json → vue specializer" "$output" "PERSONA_SPECIALIZER" "frontend/vue"

# UAT_URL does NOT override dev stack specializer — QA specializers are selected
# separately by ticket-verify, not by persona-select.sh in implement phase
output=$(UAT_URL="http://localhost:3000" "$SELECTOR" --repo "$TMPDIR/react-project" --layer FE --phase implement)
assert_contains "UAT_URL set + FE → react specializer (not qa override)" "$output" "PERSONA_SPECIALIZER" "frontend/react"

output=$(UAT_URL="http://localhost:3000" "$SELECTOR" --repo "$TMPDIR/node-project" --layer BE --phase implement)
assert_contains "UAT_URL set + implement → node specializer (not qa override)" "$output" "PERSONA_SPECIALIZER" "backend/node"

# Microservices detection
output=$("$SELECTOR" --repo "$TMPDIR/microservices-project" --layer BE --phase implement)
assert_contains "multi-service dirs → microservices specializer" "$output" "PERSONA_SPECIALIZER" "architect/microservices"

# BE_TEST_RUNNER with pyenv
output=$(BE_TEST_RUNNER="pyenv exec pytest" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "BE_TEST_RUNNER with pyenv → python specializer" "$output" "PERSONA_SPECIALIZER" "backend/python"

# ── Test: Graceful fallback for unknown stacks ─────────────────────────────────

echo "## Graceful fallback"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_empty "unknown BE stack → empty specializer" "$output" "PERSONA_SPECIALIZER"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer FE --phase implement)
assert_empty "unknown FE stack → empty specializer" "$output" "PERSONA_SPECIALIZER"

# unknown stack does not cause errors
set +e
"$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "unknown stack → exit 0" 0 "$rc"

# ── Test: Auto-include security keywords ───────────────────────────────────────

echo "## Auto-include security"

output=$(TICKET_TITLE="Add user authentication system" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_contains "auth keyword → security auto-include" "$output" "PERSONA_AUTO_INCLUDE" "security"

output=$(TICKET_DESCRIPTION="Implement payment processing for checkout" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_contains "payment keyword → security auto-include" "$output" "PERSONA_AUTO_INCLUDE" "security"

output=$(TICKET_TITLE="Fix login redirect loop" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_contains "login keyword → security auto-include" "$output" "PERSONA_AUTO_INCLUDE" "security"

output=$(TICKET_TITLE="Add PII data masking" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_contains "PII keyword → security auto-include" "$output" "PERSONA_AUTO_INCLUDE" "security"

output=$(TICKET_TITLE="Update user profile page" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_empty "no security keywords → empty auto-include" "$output" "PERSONA_AUTO_INCLUDE"

output=$(TICKET_TITLE="Optimize database queries" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_empty "db optimization → empty auto-include" "$output" "PERSONA_AUTO_INCLUDE"

# Case-insensitive match
output=$(TICKET_TITLE="Refactor Authentication Middleware" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_contains "case-insensitive auth match" "$output" "PERSONA_AUTO_INCLUDE" "security"

# ── Test: Error handling ──────────────────────────────────────────────────────

echo "## Error handling"

set +e
"$SELECTOR" --phase implement 2>&1
rc=$?
set -e
assert_exit_code "missing --repo → exit 1" 1 "$rc"

set +e
"$SELECTOR" --repo "$TMPDIR/unknown-project" --layer INVALID 2>&1
rc=$?
set -e
assert_exit_code "invalid --layer → exit 1" 1 "$rc"

set +e
"$SELECTOR" --repo "$TMPDIR/unknown-project" --phase unknown 2>&1
rc=$?
set -e
assert_exit_code "invalid --phase → exit 1" 1 "$rc"

# ── Test: CLAUDE_PLUGIN_ROOT resolution (issue #328) ───────────────────────────

echo "## CLAUDE_PLUGIN_ROOT resolution"

# CLAUDE_PLUGIN_ROOT set to a path with no personas/ subdirectory (a wrong
# plugin's root, as seen in a spawned worker's env) must fall back to
# $SCRIPT_DIR/../personas and still resolve a real base persona file.
output=$(CLAUDE_PLUGIN_ROOT="$TMPDIR/unknown-project" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "CLAUDE_PLUGIN_ROOT w/o personas/ → falls back to script-relative" "$output" "PERSONA_BASE" "backend-developer"

fallback_base_path=$(echo "$output" | grep "^PERSONA_BASE=" | cut -d'=' -f2-)
if [ -n "$fallback_base_path" ] && [ -f "$fallback_base_path" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: fallback PERSONA_BASE path resolves to a real file"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: fallback PERSONA_BASE path does not exist: $fallback_base_path" >&2
fi

# CLAUDE_PLUGIN_ROOT unset entirely (the original/default env) still works
# exactly as before — regression guard for the pre-existing fallback.
output=$(env -u CLAUDE_PLUGIN_ROOT "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "CLAUDE_PLUGIN_ROOT unset → still resolves backend-developer" "$output" "PERSONA_BASE" "backend-developer"

# True not-found: CLAUDE_PLUGIN_ROOT points at a dir that DOES have a
# personas/ subdirectory (so it is trusted and not falled back from), but is
# missing the specific persona file. The error message must include the
# resolved PERSONAS_DIR value, not just the relative path that was tried.
mkdir -p "$TMPDIR/fake-plugin-root/personas/base"
set +e
CLAUDE_PLUGIN_ROOT="$TMPDIR/fake-plugin-root" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement >/dev/null 2>"$TMPDIR/stderr.txt"
rc=$?
set -e
assert_exit_code "true not-found (valid root, missing file) → exit 2" 2 "$rc"

if grep -q "PERSONAS_DIR=$TMPDIR/fake-plugin-root/personas" "$TMPDIR/stderr.txt"; then
  PASS=$((PASS + 1))
  echo "  PASS: not-found error includes resolved PERSONAS_DIR"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: not-found error missing resolved PERSONAS_DIR — got: $(cat "$TMPDIR/stderr.txt")" >&2
fi

# ── Test: All emitted paths reference existing files ───────────────────────────

echo "## Path existence"

# Test a few representative combinations
check_paths() {
  local desc="$1" output="$2"
  local base spec auto ok
  base=$(echo "$output" | grep "^PERSONA_BASE=" | cut -d'=' -f2-)
  spec=$(echo "$output" | grep "^PERSONA_SPECIALIZER=" | cut -d'=' -f2-)
  auto=$(echo "$output" | grep "^PERSONA_AUTO_INCLUDE=" | cut -d'=' -f2-)

  if [ -n "$base" ] && [ -f "$base" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc — base path exists"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — base path not found: $base" >&2
  fi

  if [ -n "$spec" ]; then
    if [ -f "$spec" ]; then
      PASS=$((PASS + 1))
      echo "  PASS: $desc — specializer path exists"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: $desc — specializer path not found: $spec" >&2
    fi
  fi

  if [ -n "$auto" ]; then
    if [ -f "$auto" ]; then
      PASS=$((PASS + 1))
      echo "  PASS: $desc — auto-include path exists"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: $desc — auto-include path not found: $auto" >&2
    fi
  fi
}

output=$("$SELECTOR" --repo "$TMPDIR/python-project" --layer BE --phase implement)
check_paths "python+BE+implement" "$output"

output=$("$SELECTOR" --repo "$TMPDIR/angular-project" --layer FE --phase implement)
check_paths "angular+FE+implement" "$output"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --phase appraise)
check_paths "appraise phase" "$output"

output=$(TICKET_TITLE="Add auth endpoint" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
check_paths "implement+security" "$output"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
check_paths "BE unknown stack" "$output"

# Verify new specializer files exist on disk
output=$(TICKET_TITLE="Upgrade Java to 21" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
check_paths "java-migration" "$output"

output=$(TICKET_TITLE="Refactor order service" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
check_paths "java-refactor" "$output"

output=$(TICKET_TITLE="Refactor middleware" "$SELECTOR" --repo "$TMPDIR/python-project" --layer BE --phase implement)
check_paths "python-refactor" "$output"

output=$(TICKET_TITLE="Refactor Express routes" "$SELECTOR" --repo "$TMPDIR/node-project" --layer BE --phase implement)
check_paths "node-refactor" "$output"

# ── Test-data persona ──────────────────────────────────────────────────────────

echo ""
echo "── Test-data persona ──"

# Count the colon-separated entries of a key's value.
td_count() {
  local output="$1" key="$2" actual
  actual=$(echo "$output" | grep "^${key}=" | cut -d'=' -f2-)
  if [ -z "$actual" ]; then
    echo 0
  else
    awk -F: '{print NF}' <<<"$actual"
  fi
}

assert_count() {
  local desc="$1" output="$2" key="$3" expected="$4" actual
  actual=$(td_count "$output" "$key")
  if [ "$actual" -eq "$expected" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — expected $expected entries in $key, got $actual" >&2
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" key="$3" unexpected="$4" actual
  actual=$(echo "$output" | grep "^${key}=" | cut -d'=' -f2-)
  if echo "$actual" | grep -q "$unexpected"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — did not expect '$unexpected' in ${key}=${actual}" >&2
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

mkdir -p "$TMPDIR/sql-project/src/main/resources/db/migration"
mkdir -p "$TMPDIR/api-project/docs"
touch "$TMPDIR/api-project/docs/openapi.yaml"
mkdir -p "$TMPDIR/factory-project"
printf '[project]\ndependencies = ["factory_boy"]\n' >"$TMPDIR/factory-project/pyproject.toml"

# Strong signal → base swap on implement, whatever the layer
td_file="$TMPDIR/td-strong.md"
printf '## Test Data Provided\n- invoice records\n\nSeed command: make seed-invoices\n' >"$td_file"
output=$(TICKET_TEXT_FILE="$td_file" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "strong signal + BE implement → test-data-engineer base" "$output" "PERSONA_BASE" "base/test-data-engineer"
assert_contains "strong signal → PERSONA_TESTDATA set" "$output" "PERSONA_TESTDATA" "base/test-data-engineer"
output=$(TICKET_TEXT_FILE="$td_file" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer FE --phase implement)
assert_contains "strong signal + FE implement → test-data-engineer base" "$output" "PERSONA_BASE" "base/test-data-engineer"

# Each strong marker on its own
output=$(TICKET_DESCRIPTION="Seed command: make seed" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "Seed command line alone → strong" "$output" "PERSONA_BASE" "base/test-data-engineer"
output=$(TICKET_DESCRIPTION="<!-- planner:testdata-synth v1 -->" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "synth marker alone → strong" "$output" "PERSONA_BASE" "base/test-data-engineer"

# Strong signal outside implement keeps the phase base
output=$(TICKET_TEXT_FILE="$td_file" "$SELECTOR" --repo "$TMPDIR/unknown-project" --phase appraise)
assert_contains "strong signal + appraise → analyzer base" "$output" "PERSONA_BASE" "analyzer"
assert_contains "strong signal + appraise → PERSONA_TESTDATA set" "$output" "PERSONA_TESTDATA" "base/test-data-engineer"
output=$(TICKET_TEXT_FILE="$td_file" "$SELECTOR" --repo "$TMPDIR/unknown-project" --phase review)
assert_contains "strong signal + review → analyzer base" "$output" "PERSONA_BASE" "analyzer"

# Weak signal adds, never swaps
output=$(TICKET_TITLE="Add the export button; update fixtures for the report" "$SELECTOR" --repo "$TMPDIR/react-project" --layer FE --phase implement)
assert_contains "weak keyword + FE implement → frontend-developer base kept" "$output" "PERSONA_BASE" "frontend-developer"
assert_contains "weak keyword → PERSONA_TESTDATA set" "$output" "PERSONA_TESTDATA" "base/test-data-engineer"
assert_contains "weak keyword → stack specializer kept" "$output" "PERSONA_SPECIALIZER" "frontend/react"
for phrase in "seed data" "sample data" "demo data" "mock data" "synthetic data" "generate the data" "data load" "bulk import" "test data"; do
  output=$(TICKET_TITLE="Ticket about $phrase" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
  assert_contains "weak phrase '$phrase' → PERSONA_TESTDATA set" "$output" "PERSONA_TESTDATA" "base/test-data-engineer"
done

# Channels: explicit line wins over keywords and probes
output=$(TICKET_DESCRIPTION="Seed command: make seed
Seed channel: api
insert the rows with SQL" "$SELECTOR" --repo "$TMPDIR/sql-project" --layer BE --phase implement)
assert_contains "explicit Seed channel: api → api specializer" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/api.md"
assert_count "explicit channel → exactly one specializer" "$output" "PERSONA_TESTDATA_SPECIALIZERS" 1

output=$(TICKET_DESCRIPTION="Seed command: make seed
Seed channel: sql, files" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "explicit list → sql" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/sql.md"
assert_contains "explicit list → files" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/files.md"
assert_count "explicit list of two → two specializers" "$output" "PERSONA_TESTDATA_SPECIALIZERS" 2

# Channels: keyword families, several at once
output=$(TICKET_TITLE="Load test data: insert rows via SQL and upload the CSV import file" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "keywords → sql" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/sql.md"
assert_contains "keywords → files" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/files.md"
output=$(TICKET_TITLE="Seed data through the REST API endpoints" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "keywords → api" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/api.md"
output=$(TICKET_TITLE="Test data entered through the UI form" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "keywords → ui-forms" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/ui-forms.md"
output=$(TICKET_TITLE="Sample data built with a factory and faker" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "keywords → factories" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/factories.md"
output=$(TICKET_TITLE="Seed data for the rest of the team; post it to the wiki" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_not_contains "'rest of' / 'post it' do not select api" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/api.md"

# Channels: cap at three
output=$(TICKET_TITLE="Test data via SQL, a REST API endpoint, the UI form, a CSV upload and a factory" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_count "five channel families → capped at three" "$output" "PERSONA_TESTDATA_SPECIALIZERS" 3

# Channels: repo probes
output=$(TICKET_TITLE="Provide test data" "$SELECTOR" --repo "$TMPDIR/sql-project" --layer BE --phase implement)
assert_contains "migrations dir → sql" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/sql.md"
output=$(TICKET_TITLE="Provide test data" "$SELECTOR" --repo "$TMPDIR/api-project" --layer BE --phase implement)
assert_contains "openapi.yaml → api" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/api.md"
output=$(TICKET_TITLE="Provide test data" "$SELECTOR" --repo "$TMPDIR/factory-project" --layer BE --phase implement)
assert_contains "factory_boy dependency → factories" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/factories.md"
output=$(TICKET_TITLE="Provide test data" UAT_URL="http://localhost:4200" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "nothing matched + UAT_URL → ui-forms" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "testdata/ui-forms.md"
output=$(TICKET_TITLE="Provide test data" UAT_URL="" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_empty "nothing matched, no UAT_URL → no channel" "$output" "PERSONA_TESTDATA_SPECIALIZERS"
output=$(TICKET_TITLE="Provide test data" UAT_URL="http://localhost:4200" "$SELECTOR" --repo "$TMPDIR/sql-project" --layer BE --phase implement)
assert_not_contains "UAT_URL does not add ui-forms when a probe matched" "$output" "PERSONA_TESTDATA_SPECIALIZERS" "ui-forms"

# No signal → both keys empty, legacy keys unchanged
output=$(TICKET_TITLE="Fix API timeout on the report endpoint" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_empty "no signal → PERSONA_TESTDATA empty" "$output" "PERSONA_TESTDATA"
assert_empty "no signal → PERSONA_TESTDATA_SPECIALIZERS empty" "$output" "PERSONA_TESTDATA_SPECIALIZERS"
assert_contains "no signal → base unchanged" "$output" "PERSONA_BASE" "backend-developer"
assert_contains "no signal → specializer unchanged" "$output" "PERSONA_SPECIALIZER" "backend/java"
output=$("$SELECTOR" --repo "$TMPDIR/python-project" --phase prescan)
assert_empty "prescan → PERSONA_TESTDATA empty" "$output" "PERSONA_TESTDATA"

# Every emitted test-data path exists
output=$(TICKET_DESCRIPTION="Seed command: make seed
Seed channel: sql, api, ui-forms" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
td_paths=$(echo "$output" | grep "^PERSONA_TESTDATA_SPECIALIZERS=" | cut -d'=' -f2- | tr ':' '\n')
while IFS= read -r p; do
  if [ -f "$p" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: test-data specializer path exists: ${p##*/}"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: test-data specializer path not found: $p" >&2
  fi
done <<<"$td_paths"

# ── Test-data persona files: frontmatter lint ──────────────────────────────────

echo ""
echo "── Test-data persona frontmatter ──"

PERSONAS_ROOT="$SCRIPT_DIR/../personas"

frontmatter() { awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f {print}' "$1"; }

check_fields() {
  local file="$1"
  shift
  local fm field
  fm=$(frontmatter "$file")
  for field in "$@"; do
    if grep -q "^${field}:" <<<"$fm"; then
      PASS=$((PASS + 1))
      echo "  PASS: ${file#"$PERSONAS_ROOT"/} has $field"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: ${file#"$PERSONAS_ROOT"/} missing frontmatter field $field" >&2
    fi
  done
}

base_file="$PERSONAS_ROOT/base/test-data-engineer.md"
check_fields "$base_file" name role priority-hierarchy used-by auto-include-when version last-reviewed
if frontmatter "$base_file" | grep -q '^role: test-data-engineer$'; then
  PASS=$((PASS + 1))
  echo "  PASS: base role is test-data-engineer"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: base role is not test-data-engineer" >&2
fi

for ch in sql api ui-forms files factories; do
  f="$PERSONAS_ROOT/specializers/testdata/${ch}.md"
  check_fields "$f" name extends detect version last-reviewed
  if frontmatter "$f" | grep -q '^extends: test-data-engineer$'; then
    PASS=$((PASS + 1))
    echo "  PASS: testdata/${ch}.md extends test-data-engineer"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: testdata/${ch}.md does not extend test-data-engineer" >&2
  fi
done

# ── Debugger overlay (debugger-persona-overlay) ────────────────────────────────

echo ""
echo "── Debugger overlay ──"

kv() { echo "$1" | grep "^$2=" | cut -d'=' -f2- || true; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — expected '$expected', got '$actual'" >&2
  fi
}

# Like assert_contains, but tolerant of a missing key (output may be an error
# message while the overlay is unimplemented — never abort the run).
assert_in() {
  local desc="$1" output="$2" key="$3" expected="$4" actual
  actual=$(kv "$output" "$key")
  if grep -q -- "$expected" <<<"$actual"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — expected '$expected' in ${key}=${actual}" >&2
  fi
}

LEGACY_KEYS="PERSONA_BASE PERSONA_SPECIALIZER PERSONA_AUTO_INCLUDE PERSONA_TESTDATA PERSONA_TESTDATA_SPECIALIZERS"

legacy_keys() {
  local out="$1" k
  for k in $LEGACY_KEYS; do
    echo "$k=$(kv "$out" "$k")"
  done
}

# Mixed repo (JHipster shape): Java backend + Angular frontend in one tree.
mkdir -p "$TMPDIR/mixed-project"
touch "$TMPDIR/mixed-project/pom.xml" "$TMPDIR/mixed-project/angular.json"
printf '{"name": "jh"}\n' >"$TMPDIR/mixed-project/package.json"

# Both selectors resolve personas through the same CLAUDE_PLUGIN_ROOT string so
# their emitted paths are byte-comparable.
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NEW() { CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$SELECTOR" "$@"; }

# 1.1 Golden: the selector as it was before the debugger overlay (pinned main
# commit, not HEAD — once the overlay is committed HEAD is the new selector and
# the comparison would be tautological). Every pre-existing key must be
# byte-identical for every existing input — the detect_stack refactor must not
# move PERSONA_SPECIALIZER. A shallow clone (CI's default checkout) lacks the
# pinned commit, so the matrix is skipped there and runs in full checkouts.
GOLDEN_REV=4a2383682ea9884a39364968f658485957354914
OLD_SELECTOR="$TMPDIR/old-select.sh"
if git -C "$SCRIPT_DIR" show "$GOLDEN_REV:ticket-auto-pipeline/lib/persona-select.sh" >"$OLD_SELECTOR" 2>/dev/null && [ -s "$OLD_SELECTOR" ]; then
  chmod +x "$OLD_SELECTOR"
  OLD() { CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$OLD_SELECTOR" "$@"; }
  HAVE_GOLDEN=true
else
  echo "  NOTE: pre-overlay selector ($GOLDEN_REV) not in this clone — golden comparisons skipped"
  HAVE_GOLDEN=false
fi

golden_java=""
if [ "$HAVE_GOLDEN" = true ]; then
  golden_java=$(legacy_keys "$(OLD --repo "$TMPDIR/java-project" --layer BE --phase implement)")

  # Every existing fixture × layer × phase: new selector without the new flags
  # emits exactly what the old one did for the five legacy keys.
  for fx in python-project java-project node-project angular-project react-project vue-project unknown-project microservices-project mixed-project; do
    for layer in "" BE FE infra; do
      for phase in "" implement appraise review audit; do
        args=(--repo "$TMPDIR/$fx")
        [ -n "$layer" ] && args+=(--layer "$layer")
        [ -n "$phase" ] && args+=(--phase "$phase")
        old_out=$(legacy_keys "$(OLD "${args[@]}")")
        new_out=$(legacy_keys "$(NEW "${args[@]}")")
        if [ "$old_out" != "$new_out" ]; then
          FAIL=$((FAIL + 1))
          echo "  FAIL: golden drift for $fx layer='$layer' phase='$phase'" >&2
          diff <(echo "$old_out") <(echo "$new_out") >&2 || true
        else
          PASS=$((PASS + 1))
        fi
      done
    done
  done
  # Keyword-refined specializers stay identical too.
  for title in "Upgrade Java from 8 to 25" "Refactor order service" "Fix login redirect loop"; do
    for fx in java-project python-project node-project; do
      old_out=$(legacy_keys "$(TICKET_TITLE="$title" OLD --repo "$TMPDIR/$fx" --layer BE --phase implement)")
      new_out=$(legacy_keys "$(TICKET_TITLE="$title" NEW --repo "$TMPDIR/$fx" --layer BE --phase implement)")
      assert_eq "golden: '$title' on $fx unchanged" "$old_out" "$new_out"
    done
  done
  old_out=$(legacy_keys "$(BE_TEST_RUNNER="pyenv exec pytest" OLD --repo "$TMPDIR/unknown-project" --layer BE --phase implement)")
  new_out=$(legacy_keys "$(BE_TEST_RUNNER="pyenv exec pytest" NEW --repo "$TMPDIR/unknown-project" --layer BE --phase implement)")
  assert_eq "golden: BE_TEST_RUNNER pyenv unchanged" "$old_out" "$new_out"
  echo "  (golden matrix compared)"
fi

# Always-on (no git needed): the overlay flags never move a legacy key — the
# same selector with and without --type/--remediation agrees on all five.
for fx in java-project python-project node-project angular-project mixed-project unknown-project; do
  for layer in BE FE; do
    plain=$(legacy_keys "$(NEW --repo "$TMPDIR/$fx" --layer "$layer" --phase implement)")
    for flags in "--type bug" "--type feature" "--remediation"; do
      # shellcheck disable=SC2086 # word-split flags on purpose
      flagged=$(legacy_keys "$(NEW --repo "$TMPDIR/$fx" --layer "$layer" --phase implement $flags)")
      assert_eq "overlay flags ($flags) leave legacy keys unchanged on $fx/$layer" "$plain" "$flagged"
    done
  done
done

DEBUGGER_PATH="$PLUGIN_ROOT/personas/base/debugger.md"
DBG_DIR="$PLUGIN_ROOT/personas/specializers/debug"

# 1.2 Java backend bug: overlay set, legacy keys untouched.
output=$(NEW --repo "$TMPDIR/java-project" --layer BE --phase implement --type bug 2>&1 || true)
assert_eq "java + --type bug → PERSONA_DEBUG = debugger" "$DEBUGGER_PATH" "$(kv "$output" PERSONA_DEBUG)"
assert_eq "java + --type bug → PERSONA_DEBUG_SPECIALIZER = debug/jvm.md" "$DBG_DIR/jvm.md" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"
if [ "$HAVE_GOLDEN" = true ]; then
  assert_eq "java + --type bug → five legacy keys equal golden" "$golden_java" "$(legacy_keys "$output")"
fi

# 1.3 Type handling.
output=$(NEW --repo "$TMPDIR/java-project" --layer BE --phase implement --type feature 2>&1 || true)
assert_eq "--type feature → PERSONA_DEBUG empty" "" "$(kv "$output" PERSONA_DEBUG)"
assert_eq "--type feature → PERSONA_DEBUG_SPECIALIZER empty" "" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"
if grep -q '^PERSONA_DEBUG=' <<<"$output"; then
  PASS=$((PASS + 1))
  echo "  PASS: --type feature → PERSONA_DEBUG key still emitted"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: --type feature → PERSONA_DEBUG key missing from output" >&2
fi
if [ "$HAVE_GOLDEN" = true ]; then
  assert_eq "--type feature → five legacy keys equal golden" "$golden_java" "$(legacy_keys "$output")"
fi

set +e
hotfix_err=$(NEW --repo "$TMPDIR/java-project" --layer BE --phase implement --type hotfix 2>&1 >/dev/null)
rc=$?
set -e
assert_exit_code "--type hotfix → exit 1" 1 "$rc"
if grep -q 'bug' <<<"$hotfix_err" && grep -q 'feature' <<<"$hotfix_err" && grep -q 'chore' <<<"$hotfix_err"; then
  PASS=$((PASS + 1))
  echo "  PASS: --type hotfix error lists known types"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: --type hotfix error does not list known types — got: $hotfix_err" >&2
fi

set +e
output=$(NEW --repo "$TMPDIR/java-project" --layer BE --phase implement --type "" 2>&1)
rc=$?
set -e
assert_exit_code "--type \"\" → exit 0 (treated as absent)" 0 "$rc"
assert_eq "--type \"\" → PERSONA_DEBUG empty" "" "$(kv "$output" PERSONA_DEBUG)"

output=$(NEW --repo "$TMPDIR/java-project" --layer BE --phase implement --type feature --remediation 2>&1 || true)
assert_eq "--type feature --remediation → PERSONA_DEBUG set" "$DEBUGGER_PATH" "$(kv "$output" PERSONA_DEBUG)"
assert_eq "--type feature --remediation → debug/jvm.md" "$DBG_DIR/jvm.md" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"

output=$(NEW --repo "$TMPDIR/java-project" --layer BE --phase implement --remediation 2>&1 || true)
assert_eq "--remediation alone → PERSONA_DEBUG set" "$DEBUGGER_PATH" "$(kv "$output" PERSONA_DEBUG)"

# 1.4 Stack → debug specializer.
output=$(NEW --repo "$TMPDIR/angular-project" --layer FE --phase implement --type bug 2>&1 || true)
assert_eq "angular + FE bug → debug/browser.md" "$DBG_DIR/browser.md" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"

output=$(NEW --repo "$TMPDIR/mixed-project" --layer FE --phase implement --type bug 2>&1 || true)
assert_in "mixed repo + FE → angular specializer" "$output" "PERSONA_SPECIALIZER" "frontend/angular.md"
assert_eq "mixed repo + FE bug → debug/browser.md (layer decides)" "$DBG_DIR/browser.md" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"

output=$(NEW --repo "$TMPDIR/mixed-project" --layer BE --phase implement --type bug 2>&1 || true)
assert_eq "mixed repo + BE bug → debug/jvm.md (layer decides)" "$DBG_DIR/jvm.md" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"

output=$(BE_TEST_RUNNER="pyenv exec pytest" NEW --repo "$TMPDIR/unknown-project" --layer BE --phase implement --type bug 2>&1 || true)
assert_eq "no markers + BE_TEST_RUNNER pyenv → debug/python.md" "$DBG_DIR/python.md" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"

output=$(NEW --repo "$TMPDIR/python-project" --layer BE --phase implement --type bug 2>&1 || true)
assert_eq "pyproject.toml + BE bug → debug/python.md" "$DBG_DIR/python.md" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"

output=$(NEW --repo "$TMPDIR/node-project" --layer BE --phase implement --type bug 2>&1 || true)
assert_eq "node (no FE deps) + BE bug → debug/node.md" "$DBG_DIR/node.md" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"

output=$(NEW --repo "$TMPDIR/react-project" --phase implement --type bug 2>&1 || true)
assert_eq "react + no layer → tries BE then FE → debug/browser.md" "$DBG_DIR/browser.md" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"

output=$(NEW --repo "$TMPDIR/java-project" --phase implement --type bug 2>&1 || true)
assert_eq "java + no layer → debug/jvm.md" "$DBG_DIR/jvm.md" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"

for layer in BE ""; do
  largs=()
  [ -n "$layer" ] && largs=(--layer "$layer")
  set +e
  output=$(NEW --repo "$TMPDIR/unknown-project" "${largs[@]}" --phase implement --type bug 2>&1)
  rc=$?
  set -e
  assert_exit_code "empty repo layer='$layer' bug → exit 0" 0 "$rc"
  assert_eq "empty repo layer='$layer' bug → PERSONA_DEBUG set" "$DEBUGGER_PATH" "$(kv "$output" PERSONA_DEBUG)"
  assert_eq "empty repo layer='$layer' bug → PERSONA_DEBUG_SPECIALIZER empty" "" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"
done

# 1.5 Manifest fallback (lib/manifest-read.sh layout).
MF="$TMPDIR/mf-root"
mkdir -p "$MF/.ticket-auto/initiatives/_index" "$MF/.ticket-auto/initiatives/INIT-1/tickets/T-1/planner" \
  "$MF/.ticket-auto/initiatives/INIT-1/tickets/T-2/planner"
echo "INIT-1" >"$MF/.ticket-auto/initiatives/_index/T-1.initiative"
echo "INIT-1" >"$MF/.ticket-auto/initiatives/_index/T-2.initiative"
echo '{"type":"bug"}' >"$MF/.ticket-auto/initiatives/INIT-1/tickets/T-1/planner/manifest.json"
echo '{"type":null}' >"$MF/.ticket-auto/initiatives/INIT-1/tickets/T-2/planner/manifest.json"

output=$(TICKET_ID=T-1 REPOS_ROOT="$MF" NEW --repo "$TMPDIR/java-project" --layer BE --phase implement 2>&1 || true)
assert_eq "manifest type=bug, no --type → PERSONA_DEBUG set" "$DEBUGGER_PATH" "$(kv "$output" PERSONA_DEBUG)"
assert_eq "manifest type=bug → debug/jvm.md" "$DBG_DIR/jvm.md" "$(kv "$output" PERSONA_DEBUG_SPECIALIZER)"

output=$(TICKET_ID=T-1 REPOS_ROOT="$MF" NEW --repo "$TMPDIR/java-project" --layer BE --phase implement --type feature 2>&1 || true)
assert_eq "manifest bug + --type feature → explicit wins, PERSONA_DEBUG empty" "" "$(kv "$output" PERSONA_DEBUG)"

set +e
output=$(TICKET_ID=T-9 REPOS_ROOT="$MF" NEW --repo "$TMPDIR/java-project" --layer BE --phase implement 2>&1)
rc=$?
set -e
assert_exit_code "no index entry → exit 0" 0 "$rc"
assert_eq "no index entry → PERSONA_DEBUG empty" "" "$(kv "$output" PERSONA_DEBUG)"
assert_eq "no index entry → PERSONA_DEBUG key emitted" "1" "$(grep -c '^PERSONA_DEBUG=' <<<"$output" || true)"

set +e
output=$(TICKET_ID=T-2 REPOS_ROOT="$MF" NEW --repo "$TMPDIR/java-project" --layer BE --phase implement 2>&1)
rc=$?
set -e
assert_exit_code "manifest type=null → exit 0" 0 "$rc"
assert_eq "manifest type=null → PERSONA_DEBUG empty" "" "$(kv "$output" PERSONA_DEBUG)"
assert_eq "manifest type=null → PERSONA_DEBUG key emitted" "1" "$(grep -c '^PERSONA_DEBUG=' <<<"$output" || true)"

set +e
output=$(TICKET_ID="" REPOS_ROOT="$MF" NEW --repo "$TMPDIR/java-project" --layer BE --phase implement 2>&1)
rc=$?
set -e
assert_exit_code "empty TICKET_ID → exit 0" 0 "$rc"
assert_eq "empty TICKET_ID → PERSONA_DEBUG empty" "" "$(kv "$output" PERSONA_DEBUG)"

# 1.6 Output contract.
output=$(NEW --repo "$TMPDIR/python-project" --phase prescan --type bug 2>&1 || true)
for k in PERSONA_DEBUG PERSONA_DEBUG_SPECIALIZER; do
  if grep -qx "${k}=" <<<"$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: prescan emits empty $k"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: prescan does not emit empty $k" >&2
  fi
done
assert_in "prescan still emits PERSONA_SET" "$output" "PERSONA_SET" "architect"

# Contract pin (expected green before this change): TICKET_TEXT_FILE is the
# ticket-text input every skill now passes (context.md) — it must reach the
# keyword detectors.
sec_file="$TMPDIR/ctx-security.md"
printf '# Ticket\n\nThe password reset flow sends a stale link.\n' >"$sec_file"
output=$(TICKET_TEXT_FILE="$sec_file" NEW --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_in "TICKET_TEXT_FILE 'password reset flow' → security auto-include (contract pin)" "$output" "PERSONA_AUTO_INCLUDE" "base/security.md"

# Key order: the two new keys follow PERSONA_TESTDATA_SPECIALIZERS.
output=$(NEW --repo "$TMPDIR/java-project" --layer BE --phase implement --type bug 2>&1 || true)
order=$(grep -oE '^PERSONA_[A-Z_]+' <<<"$output" | tr '\n' ' ' || true)
assert_eq "key order: debug keys emitted last" "PERSONA_BASE PERSONA_SPECIALIZER PERSONA_AUTO_INCLUDE PERSONA_TESTDATA PERSONA_TESTDATA_SPECIALIZERS PERSONA_DEBUG PERSONA_DEBUG_SPECIALIZER " "$order"

# 1.7 --ticket-dir (skill-glue-collapse, persona-select-ticket-dir spec):
# derives --type and the ticket-text file from the ticket workspace.
echo ""
echo "── --ticket-dir ──"
TD="$TMPDIR/td-root"
mkdir -p "$TD/.ticket-auto/initiatives/_index"
td_ticket() { # <tid> <manifest-json|-> <labels-line|-> [extra context.md text]
  local tid="$1" dir="$TD/tickets/${1}--some-slug"
  mkdir -p "$dir"
  if [ "$2" != "-" ]; then
    mkdir -p "$TD/.ticket-auto/initiatives/INIT-7/tickets/$tid/planner"
    echo "INIT-7" >"$TD/.ticket-auto/initiatives/_index/$tid.initiative"
    echo "$2" >"$TD/.ticket-auto/initiatives/INIT-7/tickets/$tid/planner/manifest.json"
  fi
  {
    echo "# $tid"
    [ "$3" = "-" ] || echo "$3"
    [ -z "${4:-}" ] || printf '%s\n' "$4"
  } >"$dir/context.md"
  echo "$dir"
}
TDNEW() { REPOS_ROOT="$TD" NEW --repo "$TMPDIR/java-project" --layer BE "$@" 2>&1; }

d=$(td_ticket TD-1 '{"type":"bug"}' '**Labels:** backend')
output=$(TDNEW --phase implement --ticket-dir "$d")
assert_eq "manifest type bug → PERSONA_DEBUG set" "$DEBUGGER_PATH" "$(kv "$output" PERSONA_DEBUG)"
assert_eq "manifest type bug → PERSONA_TYPE=bug" "bug" "$(kv "$output" PERSONA_TYPE)"

d=$(td_ticket TD-2 - '**Labels:** Bug, backend')
output=$(TDNEW --phase implement --ticket-dir "$d")
assert_eq "no manifest + Labels 'Bug, backend' → PERSONA_TYPE=bug" "bug" "$(kv "$output" PERSONA_TYPE)"
assert_eq "labels bug → PERSONA_DEBUG set" "$DEBUGGER_PATH" "$(kv "$output" PERSONA_DEBUG)"

d=$(td_ticket TD-3 '{"type":null}' '**Labels:** debugging, bugfix')
output=$(TDNEW --phase implement --ticket-dir "$d")
assert_eq "labels 'debugging, bugfix' are not a whole bug label → PERSONA_TYPE empty" "" "$(kv "$output" PERSONA_TYPE)"
assert_eq "no bug label → PERSONA_DEBUG empty" "" "$(kv "$output" PERSONA_DEBUG)"

d=$(td_ticket TD-4 '{"type":"hotfix"}' '**Labels:** backend')
set +e
output=$(TDNEW --phase implement --ticket-dir "$d")
rc=$?
set -e
assert_exit_code "unknown manifest type hotfix → exit 0" 0 "$rc"
assert_eq "unknown manifest type dropped → PERSONA_TYPE empty" "" "$(kv "$output" PERSONA_TYPE)"

d=$(td_ticket TD-5 '{"type":"hotfix"}' '**Labels:** Bug')
output=$(TDNEW --phase implement --ticket-dir "$d")
assert_eq "unknown manifest type falls through to the labels → bug" "bug" "$(kv "$output" PERSONA_TYPE)"

d=$(td_ticket TD-6 '{"type":"feature"}' '**Labels:** Bug')
output=$(TDNEW --phase implement --ticket-dir "$d")
assert_eq "known manifest type wins over the labels" "feature" "$(kv "$output" PERSONA_TYPE)"
assert_eq "manifest feature → PERSONA_DEBUG empty" "" "$(kv "$output" PERSONA_DEBUG)"

d=$(td_ticket TD-1 '{"type":"bug"}' '**Labels:** Bug')
output=$(TDNEW --phase implement --type feature --ticket-dir "$d")
assert_eq "explicit --type feature wins over manifest bug → PERSONA_DEBUG empty" "" "$(kv "$output" PERSONA_DEBUG)"
assert_eq "explicit --type → PERSONA_TYPE=feature" "feature" "$(kv "$output" PERSONA_TYPE)"

# TICKET_ID from the env beats the directory name.
d=$(td_ticket TD-8 '{"type":"feature"}' '-')
output=$(TICKET_ID=TD-1 TDNEW --phase implement --ticket-dir "$d")
assert_eq "TICKET_ID env names the manifest (TD-1 bug)" "bug" "$(kv "$output" PERSONA_TYPE)"

d=$(td_ticket TD-9 - '-' '## Test Data Provided')
output=$(TDNEW --phase implement --ticket-dir "$d")
assert_in "context.md '## Test Data Provided' → test-data-engineer base" "$output" "PERSONA_BASE" "base/test-data-engineer"

# An explicit TICKET_TEXT_FILE still wins over context.md.
sec2="$TMPDIR/td-explicit.md"
printf '# Ticket\n\nThe password reset flow sends a stale link.\n' >"$sec2"
output=$(TICKET_TEXT_FILE="$sec2" TDNEW --phase implement --ticket-dir "$d")
assert_in "explicit TICKET_TEXT_FILE wins → security auto-include" "$output" "PERSONA_AUTO_INCLUDE" "base/security.md"
assert_eq "explicit TICKET_TEXT_FILE wins → no test-data base swap" "" "$(kv "$output" PERSONA_BASE | grep test-data-engineer || true)"

for missing in "$TMPDIR/td-nope" "$TMPDIR/td-empty"; do
  mkdir -p "$TMPDIR/td-empty"
  set +e
  output=$(TDNEW --phase implement --ticket-dir "$missing")
  rc=$?
  set -e
  assert_exit_code "--ticket-dir $(basename "$missing") (no context.md) → exit 0" 0 "$rc"
  assert_eq "--ticket-dir $(basename "$missing") → PERSONA_TYPE empty" "" "$(kv "$output" PERSONA_TYPE)"
  assert_eq "--ticket-dir $(basename "$missing") → PERSONA_TYPE key emitted" "1" "$(grep -c '^PERSONA_TYPE=' <<<"$output" || true)"
done

# Without --ticket-dir the output is unchanged: no PERSONA_TYPE key.
output=$(NEW --repo "$TMPDIR/java-project" --layer BE --phase implement --type bug 2>&1)
assert_eq "no --ticket-dir → no PERSONA_TYPE key" "0" "$(grep -c '^PERSONA_TYPE=' <<<"$output" || true)"
output=$(TDNEW --phase implement --type bug --ticket-dir "$d")
order=$(grep -oE '^PERSONA_[A-Z_]+' <<<"$output" | tr '\n' ' ' || true)
assert_eq "key order with --ticket-dir: PERSONA_TYPE last" "PERSONA_BASE PERSONA_SPECIALIZER PERSONA_AUTO_INCLUDE PERSONA_TESTDATA PERSONA_TESTDATA_SPECIALIZERS PERSONA_DEBUG PERSONA_DEBUG_SPECIALIZER PERSONA_TYPE " "$order"

# ── Debugger persona files: lint, size, tokens, bundle ─────────────────────────

echo ""
echo "── Debugger persona files ──"

file_size() { if [ -f "$1" ]; then wc -c <"$1" | tr -d ' '; else echo 999999; fi; }

assert_le() {
  local desc="$1" actual="$2" limit="$3"
  if [ "$actual" -le "$limit" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc ($actual ≤ $limit)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc ($actual > $limit)" >&2
  fi
}

dbg_file="$PERSONAS_ROOT/base/debugger.md"
if [ -f "$dbg_file" ]; then
  check_fields "$dbg_file" name role priority-hierarchy used-by auto-include-when version last-reviewed
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: base/debugger.md missing" >&2
fi
if [ -f "$dbg_file" ] && frontmatter "$dbg_file" | grep -q '^role: debugger$'; then
  PASS=$((PASS + 1))
  echo "  PASS: base role is debugger"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: base/debugger.md role is not debugger" >&2
fi
assert_le "base/debugger.md size" "$(file_size "$dbg_file")" 2560
for tok in VERIFY_EXHAUSTED HUMAN_HOLD third "## Priority Hierarchy" "## Core Principles" "## Composition Note"; do
  if [ -f "$dbg_file" ] && grep -qF -- "$tok" "$dbg_file"; then
    PASS=$((PASS + 1))
    echo "  PASS: debugger.md contains '$tok'"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: debugger.md missing '$tok'" >&2
  fi
done
if [ -f "$dbg_file" ] && grep -q '## Preferred Tools' "$dbg_file"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: debugger.md carries a Preferred Tools section (delta-only rule)" >&2
else
  PASS=$((PASS + 1))
  echo "  PASS: debugger.md has no Preferred Tools section"
fi

for st in jvm python node browser; do
  f="$PERSONAS_ROOT/specializers/debug/${st}.md"
  if [ ! -f "$f" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: specializers/debug/${st}.md missing" >&2
    continue
  fi
  check_fields "$f" name extends detect version last-reviewed
  if frontmatter "$f" | grep -q '^extends: debugger$'; then
    PASS=$((PASS + 1))
    echo "  PASS: debug/${st}.md extends debugger"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: debug/${st}.md does not extend debugger" >&2
  fi
  detect_n=$(frontmatter "$f" | awk '/^detect:/ {d=1; next} d && /^[[:space:]]+- / {n++; next} d && /^[^[:space:]]/ {d=0} END {print n+0}')
  if [ "$detect_n" -gt 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: debug/${st}.md detect list non-empty"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: debug/${st}.md detect list empty" >&2
  fi
  bullets=$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {f=0; b=1; next} b && /^- / {n++} END {print n+0}' "$f")
  assert_le "debug/${st}.md technique bullets" "$bullets" 4
  assert_le "debug/${st}.md size" "$(file_size "$f")" 2048
done

# Worst-case implement bundle: stack base + stack specializer + security +
# test-data (weak signal adds it beside the base) + debugger + debug spec.
# NOTE: the change's spec states 10240 B, but the four pre-existing files
# alone already total ~9.4 KB (test-data-engineer.md is 3.2 KB), so no
# debugger content fits under it. The budget below is the tightest one the
# required content fits; see openspec handoff.md (Slice A).
BUNDLE_BUDGET=12288
bundle=0
for rel in base/backend-developer.md specializers/backend/java.md base/security.md base/test-data-engineer.md base/debugger.md specializers/debug/jvm.md; do
  bundle=$((bundle + $(file_size "$PERSONAS_ROOT/$rel")))
done
assert_le "worst-case implement persona bundle" "$bundle" "$BUNDLE_BUDGET"

# ── 6-gram shingle check: no restated text ─────────────────────────────────────

# Print the body (frontmatter stripped) as lowercase words, one 6-gram per line.
shingles() {
  awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {f=0; next} !f {print}' "$1" |
    tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n' ' ' | tr ' ' '\n' | grep -v '^$' |
    awk '{w[NR]=$0} END {for (i=1; i+5<=NR; i++) print w[i]" "w[i+1]" "w[i+2]" "w[i+3]" "w[i+4]" "w[i+5]}' | sort -u
}

assert_no_shared_shingles() {
  local desc="$1" target="$2"
  shift 2
  if [ ! -f "$target" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — file missing" >&2
    return
  fi
  local ref_sh shared
  ref_sh=$(for r in "$@"; do shingles "$r"; done | sort -u)
  shared=$(comm -12 <(shingles "$target") <(echo "$ref_sh"))
  if [ -z "$shared" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — shared 6-grams:" >&2
    echo "$shared" | head -5 | sed 's/^/      /' >&2
  fi
}

assert_no_shared_shingles "debugger.md shares no 6-gram with analyzer/backend-developer/qa-engineer" \
  "$dbg_file" "$PERSONAS_ROOT/base/analyzer.md" "$PERSONAS_ROOT/base/backend-developer.md" "$PERSONAS_ROOT/base/qa-engineer.md"
for st in jvm python node browser; do
  assert_no_shared_shingles "debug/${st}.md shares no 6-gram with backend/* or frontend/*" \
    "$PERSONAS_ROOT/specializers/debug/${st}.md" "$PERSONAS_ROOT"/specializers/backend/*.md "$PERSONAS_ROOT"/specializers/frontend/*.md
done

# ── QA specializers on the prescan --with-qa lens (issue #559) ─────────────────

echo ""
echo "--- QA specializers (prescan --with-qa) ---"

# _qa_line <output> — the PERSONA_SET line carrying the qa-engineer base.
_qa_line() { printf '%s\n' "$1" | sed 's/^PERSONA_SET=//' | grep 'base/qa-engineer.md' || true; }

assert_qa_line() {
  local desc="$1" line="$2" want="$3" # want: a substring, or "" for no specializer
  local ok="false"
  if [ -n "$line" ]; then
    if [ -n "$want" ]; then
      case "$line" in *"|"*"$want") [ -f "${line#*|}" ] && ok="true" ;; esac
    else
      case "$line" in *"|"*) ;; *) ok="true" ;; esac
    fi
  fi
  if [ "$ok" = "true" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — qa-engineer entry was '${line}'" >&2
  fi
}

mkdir -p "$TMPDIR/qa-playwright" "$TMPDIR/qa-playwright-dep" "$TMPDIR/qa-openapi/docs" "$TMPDIR/qa-postman" "$TMPDIR/qa-both"
touch "$TMPDIR/qa-playwright/playwright.config.ts"
echo '{"devDependencies": {"@playwright/test": "^1.0.0"}}' >"$TMPDIR/qa-playwright-dep/package.json"
touch "$TMPDIR/qa-openapi/docs/openapi.yaml"
touch "$TMPDIR/qa-postman/smoke.postman_collection.json"
touch "$TMPDIR/qa-both/playwright.config.js" "$TMPDIR/qa-both/swagger.json"

output=$("$SELECTOR" --repo "$TMPDIR/qa-playwright" --phase prescan --with-qa)
assert_qa_line "playwright.config.ts → qa-engineer|qa/playwright-web" "$(_qa_line "$output")" "specializers/qa/playwright-web.md"
output=$("$SELECTOR" --repo "$TMPDIR/qa-playwright-dep" --phase prescan --with-qa)
assert_qa_line "@playwright/test dependency → qa/playwright-web" "$(_qa_line "$output")" "specializers/qa/playwright-web.md"
output=$("$SELECTOR" --repo "$TMPDIR/qa-openapi" --phase prescan --with-qa)
assert_qa_line "nested openapi.yaml → qa-engineer|qa/api-testing" "$(_qa_line "$output")" "specializers/qa/api-testing.md"
output=$("$SELECTOR" --repo "$TMPDIR/qa-postman" --phase prescan --with-qa)
assert_qa_line "Postman collection → qa/api-testing" "$(_qa_line "$output")" "specializers/qa/api-testing.md"
output=$("$SELECTOR" --repo "$TMPDIR/qa-both" --phase prescan --with-qa)
assert_qa_line "Playwright wins over OpenAPI" "$(_qa_line "$output")" "specializers/qa/playwright-web.md"
output=$("$SELECTOR" --repo "$TMPDIR/python-project" --phase prescan --with-qa)
assert_qa_line "no qa signal → bare qa-engineer, exit 0" "$(_qa_line "$output")" ""
output=$("$SELECTOR" --repo "$TMPDIR/qa-playwright" --phase prescan)
if printf '%s\n' "$output" | grep -q 'qa-engineer\|specializers/qa/'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: without --with-qa no qa persona is emitted" >&2
else
  PASS=$((PASS + 1))
  echo "  PASS: without --with-qa no qa persona is emitted"
fi
output=$("$SELECTOR" --repo "$TMPDIR/qa-playwright" --layer FE --phase implement)
assert_not_contains "implement phase never emits a qa specializer" "$output" "PERSONA_SPECIALIZER" "specializers/qa/"

# ── Results ────────────────────────────────────────────────────────────────────

echo ""
echo "========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
