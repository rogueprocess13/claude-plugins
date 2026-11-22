#!/usr/bin/env bash
# test-qa-persona-wanted.sh — lib/qa-persona-wanted.sh (openspec change
# verify-qa-persona, task group 5): VERIFY_QA_PERSONA bug|true|false with a
# `bug` default, the ticket type from ticket-type.sh.
# -u (nounset) intentionally omitted — see test-detect-resume.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$LIB_DIR/qa-persona-wanted.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

unset VERIFY_QA_PERSONA REPOS_ROOT LOG_FILE TAP_LOG CLAUDE_LOG_FILE TICKET_ID

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# Fixtures: a REPOS_ROOT with manifest types, and context.md files.
ROOT="$WORK/root"
_manifest() {
  local tid="$1" type="$2" d="$ROOT/.ticket-auto/initiatives/INIT-1/tickets/$1/planner"
  mkdir -p "$d" "$ROOT/.ticket-auto/initiatives/_index"
  echo INIT-1 >"$ROOT/.ticket-auto/initiatives/_index/$tid.initiative"
  jq -n --arg t "$type" '{type: $t}' >"$d/manifest.json"
}
_manifest CRE-1 bug
_manifest CRE-2 feature
printf '# CRE-3: x\n\n**Labels:** Bug, frontend\n' >"$WORK/bug-label.md"
printf '# CRE-4: x\n\n**Labels:** debug, frontend\n' >"$WORK/feature-label.md"

# _want <VERIFY_QA_PERSONA|-> <TID> [context] — the helper's stdout.
_want() {
  local v="$1"
  shift
  if [ "$v" = "-" ]; then
    REPOS_ROOT="$ROOT" bash "$HELPER" "$@" 2>/dev/null
  else
    VERIFY_QA_PERSONA="$v" REPOS_ROOT="$ROOT" bash "$HELPER" "$@" 2>/dev/null
  fi
}

test_matrix() {
  local row v tid ctx want got bad=0
  # value | tid | context | want
  while IFS='|' read -r v tid ctx want; do
    [ -n "$v" ] || continue
    if [ -n "$ctx" ]; then got=$(_want "$v" "$tid" "$WORK/$ctx"); else got=$(_want "$v" "$tid"); fi
    if [ "$got" != "$want" ]; then
      echo "  VERIFY_QA_PERSONA=$v $tid ${ctx:-(no context)}: want $want, got $got" >&2
      bad=1
    fi
  done <<'EOF'
-|CRE-1||true
-|CRE-2||false
-|CRE-9||false
-|CRE-3|bug-label.md|true
-|CRE-4|feature-label.md|false
-|CRE-2|bug-label.md|false
bug|CRE-1||true
bug|CRE-2||false
true|CRE-2||true
true|CRE-9||true
false|CRE-1||false
false|CRE-3|bug-label.md|false
EOF
  # Empty counts as unset.
  row=$(VERIFY_QA_PERSONA="" REPOS_ROOT="$ROOT" bash "$HELPER" CRE-1 2>/dev/null)
  [ "$row" = "true" ] || {
    echo "  empty value: want true, got $row" >&2
    bad=1
  }
  [ "$bad" -eq 0 ]
}

test_unknown_value_counts_as_bug_and_warns_once() {
  local log="$WORK/pipeline.log" out err
  : >"$log"
  out=$(VERIFY_QA_PERSONA=yes REPOS_ROOT="$ROOT" LOG_FILE="$log" bash "$HELPER" CRE-1 2>"$WORK/err") || return 1
  err=$(cat "$WORK/err")
  [ "$out" = "true" ] &&
    [ "$(VERIFY_QA_PERSONA=yes REPOS_ROOT="$ROOT" bash "$HELPER" CRE-2 2>/dev/null)" = "false" ] &&
    [ "$(grep -c '|META|qa-persona|warn|' "$log")" -eq 1 ] &&
    [ "$(grep -c 'VERIFY_QA_PERSONA=yes' <<<"$err")" -eq 1 ]
}

test_no_repos_root_falls_back_to_labels() {
  [ "$(bash "$HELPER" CRE-1 2>/dev/null)" = "false" ] &&
    [ "$(bash "$HELPER" CRE-3 "$WORK/bug-label.md" 2>/dev/null)" = "true" ]
}

test_usage() {
  local rc=0
  bash "$HELPER" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || return 1
  rc=0
  bash "$HELPER" --x >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_sourcing_sets_no_options() {
  local before after
  before=$(set +o)
  # shellcheck disable=SC1090
  source "$HELPER"
  after=$(set +o)
  [ "$before" = "$after" ] && declare -f qa_persona_wanted >/dev/null
}

for t in \
  test_matrix \
  test_unknown_value_counts_as_bug_and_warns_once \
  test_no_repos_root_falls_back_to_labels \
  test_usage \
  test_sourcing_sets_no_options; do
  _run "$t" "$t"
done

echo ""
echo "test-qa-persona-wanted.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
