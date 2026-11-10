#!/usr/bin/env bash
# select-tests.sh — which test commands a change needs, for a PR's CI run.
#
# Reads the changed paths of a change and prints one line for
# `run-tests.sh --only` (also TEST_ONLY):
#   all            run every test command
#   none           run nothing (only root-level notes changed)
#   ENTRY...       space-separated, sorted: a group directory ("ticket-planner/")
#                  runs every test command under it, a file path runs that
#                  one test file
# The reason for each changed path goes to stderr.
#
# Usage: select-tests.sh [--base REF] [--files FILE]
#   --base REF    changed paths are `git diff --name-only REF HEAD`
#   --files FILE  changed paths, one per line ("-" = stdin, the default)
# Exit 0 with a selection, 2 on usage or a failed git diff. A caller that
# gets a non-zero exit must run everything.
#
# The decision is conservative on purpose. A missed dependency means a PR
# goes green and main goes red, so a path this map cannot place runs
# everything, and the nightly full run (.github/workflows/test.yml) is the
# backstop for an edge the map gets wrong.
#
# Rules, first match wins, per changed path:
#   1. Under a plugin directory (PLUGINS): that plugin's tests, its DEPENDENTS
#      and the ANY_PLUGIN test files. Every file counts, docs included: tests
#      read SKILL.md files, READMEs and diagrams.
#   2. A repo-root *.md other than README.md and CLAUDE.md (CHANGELOG.md,
#      next.md, review notes): nothing. No test reads them, and nearly every
#      PR edits CHANGELOG.md and next.md; running everything for them would
#      undo the point of this script.
#   3. Anything else (.github/, scripts/, Makefile, docs/, README.md,
#      CLAUDE.md, .claude-plugin/, dotfiles, a new top-level directory):
#      everything.
# An empty change list also runs everything: it means a bad base or a
# shallow clone, not "nothing changed".
#
# DEPENDENTS[P] — what else a change to plugin P runs: a group (a plugin
# directory, or `scripts` for the repo-level tests in scripts/tests/) or one
# test file. Found by grepping every plugin's code and tests for paths into
# the others; re-check when a plugin starts sourcing another one's files.
#   ticket-auto-pipeline  fleet-controller's libs and fleetd source its lib/
#                         and run its flow.sh; ticket-planner's libs and tests
#                         source its lib/ checkers and DoR fixtures; grill-me's
#                         hold test runs its human-hold-parse.sh;
#                         scripts/e2e-preflight.sh runs its lib/.
#   fleet-controller      ticket-auto-pipeline's spawn-helper, fence-check and
#                         outbox-drain source its fleet-config/fleet-notify,
#                         and ticket-auto tests read fleetd's schema.sql,
#                         pusher.py and fleet-detect.sh; ticket-planner's
#                         run-telemetry test sources its lib/ and otel.py;
#                         scripts/e2e-preflight.sh runs a fleet dry-run.
#   ticket-planner        only test-ticket-create.sh outside it reads its files
#                         (the business-framing fixtures).
#   grill-me              ticket-planner's intent gate, project gate, answers
#                         and doctor source grill-me's lib/.
# ANY_PLUGIN — test files that scan every plugin, so any plugin change runs
# them: test-fleet-features.sh (a boolean feature flag in any plugin needs a
# catalog entry), test-diagram-drift.sh (every plugin's README.md and
# CLAUDE.md) and test-skill-references.sh (every plugin's
# skills/*/references/ files).
set -euo pipefail

PLUGINS=(ticket-auto-pipeline fleet-controller ticket-planner grill-me)

# Keys quoted: shfmt reads a bare [a-b] key as arithmetic and rewrites it.
declare -A DEPENDENTS=(
  ["ticket-auto-pipeline"]="fleet-controller ticket-planner grill-me scripts"
  ["fleet-controller"]="ticket-auto-pipeline ticket-planner scripts"
  ["ticket-planner"]="ticket-auto-pipeline/lib/tests/test-ticket-create.sh"
  ["grill-me"]="ticket-planner"
)

ANY_PLUGIN=(
  fleet-controller/lib/tests/test-fleet-features.sh
  ticket-auto-pipeline/lib/tests/test-diagram-drift.sh
  ticket-auto-pipeline/lib/tests/test-skill-references.sh
)

usage() {
  echo "usage: select-tests.sh [--base REF] [--files FILE]" >&2
  exit 2
}

BASE=""
FILES="-"
while [ "$#" -gt 0 ]; do
  case "$1" in
  --base)
    [ "$#" -ge 2 ] || usage
    BASE="$2"
    shift 2
    ;;
  --files)
    [ "$#" -ge 2 ] || usage
    FILES="$2"
    shift 2
    ;;
  *) usage ;;
  esac
done

if [ -n "$BASE" ]; then
  if ! CHANGED=$(git diff --name-only "$BASE" HEAD); then
    echo "select-tests.sh: git diff against '$BASE' failed" >&2
    exit 2
  fi
elif [ "$FILES" = "-" ]; then
  CHANGED=$(cat)
else
  [ -f "$FILES" ] || {
    echo "select-tests.sh: no such file: $FILES" >&2
    exit 2
  }
  CHANGED=$(cat "$FILES")
fi

# SEL holds groups (no "/") and single test files (with "/").
declare -A SEL=()
SAW=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  SAW=1
  top="${path%%/*}"
  plugin=""
  if [ "$path" != "$top" ]; then
    for p in "${PLUGINS[@]}"; do
      [ "$top" = "$p" ] && plugin="$p" && break
    done
  fi
  if [ -n "$plugin" ]; then
    echo "  $path -> $plugin ${DEPENDENTS[$plugin]}" >&2
    SEL[$plugin]=1
    for d in ${DEPENDENTS[$plugin]} "${ANY_PLUGIN[@]}"; do SEL[$d]=1; done
  elif [[ "$path" != */* && "$path" == *.md && "$path" != README.md && "$path" != CLAUDE.md ]]; then
    echo "  $path -> no tests (root-level notes)" >&2
  else
    echo "  $path -> all (outside the plugin directories)" >&2
    echo all
    exit 0
  fi
done <<<"$CHANGED"

if [ "$SAW" -eq 0 ]; then
  echo "  no changed paths -> all" >&2
  echo all
  exit 0
fi
if [ "${#SEL[@]}" -eq 0 ]; then
  echo none
  exit 0
fi

out=()
n_groups=0
for k in "${!SEL[@]}"; do
  if [[ "$k" != */* ]]; then
    out+=("$k/")
    n_groups=$((n_groups + 1))
  elif [ -z "${SEL[${k%%/*}]:-}" ]; then
    # A single file inside a group that already runs whole is redundant.
    out+=("$k")
  fi
done
# Every group (each plugin plus scripts) selected: say `all`, so the run
# reads the same as a full one.
if [ "$n_groups" -ge $((${#PLUGINS[@]} + 1)) ]; then
  echo all
  exit 0
fi
printf '%s\n' "${out[@]}" | sort | paste -sd' ' -
