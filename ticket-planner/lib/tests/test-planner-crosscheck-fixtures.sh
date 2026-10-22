#!/usr/bin/env bash
# test-planner-crosscheck-fixtures.sh — Golden fixture corpus regression test
# for the Crosscheck checkers (issue #231).
#
# Every unit test in test-planner-crosscheck*.sh hand-writes synthetic
# artifacts scoped to one code path. Issue #231's origin story: across the 7
# initiatives the planner has actually run so far (VS-1 through VS-4 and the
# Evidence-Based initiative — see CHANGELOG.md 0.8.5, 0.8.12-0.8.14), the
# real Specify output kept finding false-positive classes none of those
# hand-written cases exercised — citation-grammar quirks, word-wrapped
# prose, copy-pasted-vs-legitimately-trivial Signals blocks — because a
# synthetic test can only cover the shapes its author thought to write.
#
# This file does NOT hand-write those shapes as inline heredocs the way
# test-planner-crosscheck*.sh do. It is a data-driven runner: every
# subdirectory of fixtures/crosscheck/ with an expected.json is one fixture.
# Dropping in a new fixture directory is the only step needed to add a
# regression case — nothing here needs editing.
#
# IMPORTANT — what "golden" means for today's corpus: issue #231 asked for
# real (sanitized) initiative artifacts. This environment has read access to
# real initiative directories on disk (e.g. VS-1 == INIT-1788043814-1898,
# under REPOS_ROOT/.ticket-auto/initiatives/), but their proposal.md/specs
# are unreleased business planning content for a real product — copying and
# "sanitizing" that into a public marketplace repo is a judgment call this
# automated run does not have standing to make unilaterally. See fixtures/
# crosscheck/README.md. Every fixture below is therefore synthetic-but-
# pattern-derived: built from the specific false-positive shapes CHANGELOG.md
# already documents as having been found on real initiatives (VS-1, VS-2,
# VS-4, the Evidence-Based initiative's ebc-* specs) and fixed in this repo's
# history — grounded in real prior bugs, not invented from nothing, and not
# claimed to be the genuine VS-1/etc. artifacts themselves.
#
# Each fixture calls the REAL planner_crosscheck_run — the same function the
# router calls from SKILL.md's dispatch loop — against its own isolated
# REPOS_ROOT. Nothing here is mocked or stubbed: a checker regression changes
# what this test observes exactly as it would change what a live initiative
# observes.
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-fixtures.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
FIXTURES_DIR="${SCRIPT_DIR}/fixtures/crosscheck"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-crosscheck.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available — cannot parse fixture expected.json files" >&2
  exit 0
fi

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

echo "=== planner-crosscheck golden fixture corpus (#231) ==="

if [ ! -d "$FIXTURES_DIR" ]; then
  fail "fixtures directory exists" "missing: $FIXTURES_DIR"
  echo ""
  echo "=== Results: $PASS passed, $FAIL failed ==="
  exit 1
fi

FIXTURE_COUNT=0

for fixture_dir in "$FIXTURES_DIR"/*/; do
  [ -d "$fixture_dir" ] || continue
  fixture_name="$(basename "$fixture_dir")"
  expected_file="${fixture_dir}expected.json"

  [ -f "$expected_file" ] || continue
  FIXTURE_COUNT=$((FIXTURE_COUNT + 1))

  echo "--- fixture: ${fixture_name} ---"

  if ! jq -e . "$expected_file" >/dev/null 2>&1; then
    fail "${fixture_name}: expected.json is valid JSON" "unparseable: $expected_file"
    continue
  fi

  exp_blocking=$(jq -r '.blocking // "MISSING"' "$expected_file")
  exp_warn=$(jq -r '.warn // "MISSING"' "$expected_file")
  exp_accepted=$(jq -r '.accepted // "MISSING"' "$expected_file")

  case "$exp_blocking$exp_warn$exp_accepted" in
  *MISSING*)
    fail "${fixture_name}: expected.json has blocking/warn/accepted" \
      "blocking=${exp_blocking} warn=${exp_warn} accepted=${exp_accepted} in $expected_file"
    continue
    ;;
  esac

  # Isolated REPOS_ROOT per fixture — planner-crosscheck-contracts.sh scans
  # sibling initiatives under REPOS_ROOT/.ticket-auto/initiatives/*, so
  # fixtures sharing a root could false-cross-contaminate each other's
  # contract findings. A fresh root per fixture is what a real initiative
  # gets too — Crosscheck never runs two initiatives against the same root
  # inside one process.
  export REPOS_ROOT="${TMPDIR}/repos-${fixture_name}"
  mkdir -p "$REPOS_ROOT"

  init_id="INIT-fixture-${fixture_name}"
  state_dir="${REPOS_ROOT}/.ticket-auto/initiatives/${init_id}"
  mkdir -p "${state_dir}/artifacts/specs"

  for artifact in proposal.md discovery.md consensus.md; do
    [ -f "${fixture_dir}${artifact}" ] && cp "${fixture_dir}${artifact}" "${state_dir}/artifacts/${artifact}"
  done

  if [ -d "${fixture_dir}specs" ]; then
    find "${fixture_dir}specs" -maxdepth 1 -name '*.md' -exec cp {} "${state_dir}/artifacts/specs/" \;
  fi

  # intents/ — TicketGen idempotency records (`ticket-<slug>.json`), copied to
  # the initiative's .intents/: a TD spec whose slug has one counts as
  # dispatched, so test-data synthesis keeps it (planner-test-data-derivation).
  if [ -d "${fixture_dir}intents" ]; then
    mkdir -p "${state_dir}/.intents"
    cp "${fixture_dir}intents/"*.json "${state_dir}/.intents/" 2>/dev/null
  fi

  # repo-stub/ mirrors the shape of a REPOS_ROOT checkout — copied in
  # verbatim so citation/precedent checks resolve against real files
  # instead of a mocked lookup table.
  if [ -d "${fixture_dir}repo-stub" ]; then
    cp -r "${fixture_dir}repo-stub/." "${REPOS_ROOT}/"
  fi

  planner_state_init "$init_id" "golden fixture: ${fixture_name}" >/dev/null 2>&1
  # What SKILL.md's argument-persistence step does on every plan/resume: record
  # the no-tests rule once (#503), here by detection from repo-stub/CLAUDE.md.
  planner_testdata_no_tests_rule_persist "$init_id" >/dev/null 2>&1

  planner_crosscheck_run "$init_id" >/dev/null 2>&1
  rc=$?

  log_file=$(planner_state_log "$init_id")
  blocking=$(grep -c '|META|crosscheck|fail|' "$log_file" 2>/dev/null)
  warn=$(grep -c '|META|crosscheck|warn|' "$log_file" 2>/dev/null)
  accepted=$(grep -c '|META|crosscheck|accepted|' "$log_file" 2>/dev/null)
  : "${blocking:=0}" "${warn:=0}" "${accepted:=0}"

  if [ "$blocking" -eq "$exp_blocking" ]; then
    pass "${fixture_name}: blocking count matches (${blocking})"
  else
    fail "${fixture_name}: blocking count matches" "expected ${exp_blocking}, got ${blocking}"
    planner_crosscheck_findings_report "$init_id"
  fi

  if [ "$warn" -eq "$exp_warn" ]; then
    pass "${fixture_name}: warn count matches (${warn})"
  else
    fail "${fixture_name}: warn count matches" "expected ${exp_warn}, got ${warn}"
    planner_crosscheck_findings_report "$init_id"
  fi

  if [ "$accepted" -eq "$exp_accepted" ]; then
    pass "${fixture_name}: accepted count matches (${accepted})"
  else
    fail "${fixture_name}: accepted count matches" "expected ${exp_accepted}, got ${accepted}"
  fi

  # Optional: the exact multiset of blocking codes (sorted), and substrings
  # every blocking finding message taken together must contain (#503/#504) —
  # counts alone cannot tell "the right finding" from "a different one".
  if jq -e 'has("codes")' "$expected_file" >/dev/null 2>&1; then
    exp_codes=$(jq -r '.codes[]' "$expected_file" | LC_ALL=C sort | tr '\n' ' ')
    got_codes=$(grep '|META|crosscheck|fail|' "$log_file" | cut -d'|' -f5 | awk '{print $1}' | LC_ALL=C sort | tr '\n' ' ')
    if [ "$exp_codes" = "$got_codes" ]; then
      pass "${fixture_name}: blocking codes match (${got_codes% })"
    else
      fail "${fixture_name}: blocking codes match" "expected '${exp_codes}', got '${got_codes}'"
    fi
  fi
  if jq -e 'has("message_contains")' "$expected_file" >/dev/null 2>&1; then
    fail_text=$(grep '|META|crosscheck|fail|' "$log_file")
    while IFS= read -r needle; do
      [ -n "$needle" ] || continue
      if [[ "$fail_text" == *"$needle"* ]]; then
        pass "${fixture_name}: finding mentions '${needle}'"
      else
        fail "${fixture_name}: finding mentions '${needle}'" "not in: ${fail_text}"
      fi
    done < <(jq -r '.message_contains[]' "$expected_file")
  fi

  # Consumer specs are never written by Crosscheck (test-data synthesis keeps
  # its edits in TD specs, the sidecar and INDEX.md): every fixture spec
  # without the synthesis marker must be byte-identical after the run.
  if [ -d "${fixture_dir}specs" ]; then
    changed_specs=""
    for src_spec in "${fixture_dir}specs/"*.md; do
      [ -f "$src_spec" ] || continue
      grep -qF -- "$PLANNER_TESTDATA_SYNTH_MARKER" "$src_spec" && continue
      cmp -s "$src_spec" "${state_dir}/artifacts/specs/$(basename "$src_spec")" ||
        changed_specs="${changed_specs} $(basename "$src_spec")"
    done
    if [ -z "$changed_specs" ]; then
      pass "${fixture_name}: consumer specs byte-identical"
    else
      fail "${fixture_name}: consumer specs byte-identical" "changed:${changed_specs}"
    fi
  fi

  # Optional synthesis assertions (planner-test-data-derivation). Paths are
  # relative to the initiative's artifacts/ directory.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -e "${state_dir}/artifacts/${rel}" ]; then pass "${fixture_name}: ${rel} present"; else fail "${fixture_name}: ${rel} present" "missing"; fi
  done < <(jq -r '.files_present[]?' "$expected_file")
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ ! -e "${state_dir}/artifacts/${rel}" ]; then pass "${fixture_name}: ${rel} absent"; else fail "${fixture_name}: ${rel} absent" "exists"; fi
  done < <(jq -r '.files_absent[]?' "$expected_file")
  while IFS=$'\t' read -r rel needle; do
    [ -n "$rel" ] || continue
    if grep -qF -- "$needle" "${state_dir}/artifacts/${rel}" 2>/dev/null; then
      pass "${fixture_name}: ${rel} contains '${needle}'"
    else
      fail "${fixture_name}: ${rel} contains '${needle}'" "not found"
    fi
  done < <(jq -r '(.file_contains // {}) | to_entries[] | .key as $k | .value[] | [$k, .] | @tsv' "$expected_file")
  while IFS= read -r expr; do
    [ -n "$expr" ] || continue
    if jq -e "$expr" "${state_dir}/artifacts/testdata-synth.json" >/dev/null 2>&1; then
      pass "${fixture_name}: sidecar ${expr}"
    else
      fail "${fixture_name}: sidecar ${expr}" "false or no sidecar"
    fi
  done < <(jq -r '.sidecar_jq[]?' "$expected_file")
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    if grep -qF -- "$needle" "$log_file"; then pass "${fixture_name}: state.log has '${needle}'"; else fail "${fixture_name}: state.log has '${needle}'" "not found"; fi
  done < <(jq -r '.log_contains[]?' "$expected_file")

  # idempotent: a second planner_crosscheck_run with no input change must
  # change no artifact file — content, size or mtime.
  if [ "$(jq -r '.idempotent // false' "$expected_file")" = true ]; then
    snap() { (cd "${state_dir}/artifacts" && find . -type f -printf '%P %s %T@\n' | LC_ALL=C sort && find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2); }
    before=$(snap)
    sleep 0.05
    planner_crosscheck_run "$init_id" >/dev/null 2>&1
    after=$(snap)
    if [ "$before" = "$after" ]; then
      pass "${fixture_name}: second run changes no artifact file"
    else
      fail "${fixture_name}: second run changes no artifact file" "$(diff <(echo "$before") <(echo "$after") | head -5 | tr '\n' ' ')"
    fi
  fi

  # planner_crosscheck_run's own return code is 0 iff no blocking finding —
  # cross-check it agrees with the log-derived blocking count above, since
  # that return code is what actually gates the dispatch loop.
  if [ "$exp_blocking" -eq 0 ]; then
    if [ "$rc" -eq 0 ]; then
      pass "${fixture_name}: planner_crosscheck_run returns 0 (no blocking finding)"
    else
      fail "${fixture_name}: planner_crosscheck_run returns 0 (no blocking finding)" "returned ${rc}"
    fi
  else
    if [ "$rc" -ne 0 ]; then
      pass "${fixture_name}: planner_crosscheck_run returns nonzero (blocking finding present)"
    else
      fail "${fixture_name}: planner_crosscheck_run returns nonzero (blocking finding present)" "returned 0"
    fi
  fi
done

if [ "$FIXTURE_COUNT" -eq 0 ]; then
  fail "at least one fixture discovered" "no subdirectory of ${FIXTURES_DIR} has an expected.json"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed (${FIXTURE_COUNT} fixture(s)) ==="
[ "$FAIL" -eq 0 ]
