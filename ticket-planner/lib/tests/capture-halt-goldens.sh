#!/usr/bin/env bash
# capture-halt-goldens.sh — record every planner halt's stdout, stderr and
# exit code into fixtures/halt-goldens/ (planner-headless-questions task 1.1).
#
# Run once, on main, before a change that could touch a halt — the goldens
# are what test-planner-stop-describe.sh holds every later run to. Re-run it
# only when a halt's output is meant to change, and review the diff.
#
# Run: bash ticket-planner/lib/tests/capture-halt-goldens.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
GOLDEN_DIR="${SCRIPT_DIR}/fixtures/halt-goldens"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export CLAUDE_PLUGIN_ROOT
CLAUDE_PLUGIN_ROOT="$(cd "$LIB_DIR/.." && pwd)"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
source "${SCRIPT_DIR}/halt-fixtures.sh"

mkdir -p "$GOLDEN_DIR"
for pair in $HALT_FIXTURE_REASONS; do
  name="${pair%%:*}"
  export REPOS_ROOT="${WORK}/repos-${name}"
  mkdir -p "$REPOS_ROOT"
  halt_fixture_init "$name" "INIT-1700000000-4242" >/dev/null
  halt_fixture_run "$name" "INIT-1700000000-4242" "$GOLDEN_DIR"
  echo "${name}: exit $(cat "${GOLDEN_DIR}/${name}.rc")"
done
