#!/usr/bin/env bash
# Tests for scripts/select-tests.sh — which test commands a PR's CI run needs —
# and its use with run-tests.sh --only on the real Makefile.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SEL="$ROOT/scripts/select-tests.sh"
RUNNER="$ROOT/scripts/run-tests.sh"
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}
# sel PATH... — the selection for these changed paths.
sel() { printf '%s\n' "$@" | bash "$SEL" 2>/dev/null; }
expect() {
  local name="$1" want="$2" got
  shift 2
  got=$(sel "$@")
  [ "$got" = "$want" ] && ok "$name" || bad "$name: want [$want], got [$got]"
}

FF=fleet-controller/lib/tests/test-fleet-features.sh
DD=ticket-auto-pipeline/lib/tests/test-diagram-drift.sh
TC=ticket-auto-pipeline/lib/tests/test-ticket-create.sh

echo "=== one changed path ==="
expect "knowledge-curator: itself plus the every-plugin scans" \
  "$FF knowledge-curator/ $DD" knowledge-curator/lib/kc-item.sh
expect "grill-me: itself, ticket-planner and the scans" \
  "$FF grill-me/ $DD ticket-planner/" grill-me/lib/grill-seal.sh
expect "ticket-planner: itself, test-ticket-create.sh and the scans" \
  "$FF $DD $TC ticket-planner/" ticket-planner/lib/planner-state.sh
expect "fleet-controller: itself, ticket-auto, ticket-planner, scripts" \
  "fleet-controller/ scripts/ ticket-auto-pipeline/ ticket-planner/" fleet-controller/fleetd/supervisor.py
expect "ticket-auto-pipeline: everything but knowledge-curator" \
  "fleet-controller/ grill-me/ scripts/ ticket-auto-pipeline/ ticket-planner/" \
  ticket-auto-pipeline/lib/linear-api.sh
expect "a plugin doc counts as the plugin (tests read docs)" \
  "$FF $DD $TC ticket-planner/" ticket-planner/skills/ticket-planner/SKILL.md
expect "root notes (CHANGELOG.md) run nothing" none CHANGELOG.md
expect "root notes (next.md) run nothing" none next.md
for p in README.md CLAUDE.md .github/workflows/test.yml scripts/run-tests.sh Makefile \
  docs/index.html .claude-plugin/marketplace.json .gitignore LICENSE new-plugin/lib/x.sh; do
  expect "$p runs everything" all "$p"
done
expect "a file named like a plugin at the root runs everything" all ticket-planner

echo "=== several changed paths ==="
expect "notes plus a plugin: the plugin's selection" \
  "$FF knowledge-curator/ $DD" CHANGELOG.md next.md knowledge-curator/test/test-kc-item.sh
expect "two plugins: the union" \
  "$FF grill-me/ knowledge-curator/ $DD ticket-planner/" knowledge-curator/x grill-me/y
expect "a plugin plus scripts/: everything" all knowledge-curator/x scripts/select-tests.sh
expect "ticket-auto plus knowledge-curator: every group, said as all" all \
  ticket-auto-pipeline/lib/a.sh knowledge-curator/b
expect "ticket-planner plus ticket-auto: no single-file entry inside a whole group" \
  "fleet-controller/ grill-me/ scripts/ ticket-auto-pipeline/ ticket-planner/" \
  ticket-planner/a ticket-auto-pipeline/b
got=$(printf '' | bash "$SEL" 2>/dev/null)
[ "$got" = all ] && ok "an empty change list runs everything" || bad "empty list gave [$got]"
got=$(printf '\n\n' | bash "$SEL" 2>/dev/null)
[ "$got" = all ] && ok "blank lines only run everything" || bad "blank lines gave [$got]"
printf 'grill-me/a\nnext.md\n' >"$TMP/changed.txt"
got=$(bash "$SEL" --files "$TMP/changed.txt" 2>"$TMP/why.txt")
[ "$got" = "$FF grill-me/ $DD ticket-planner/" ] && ok "--files FILE reads the list" || bad "--files gave [$got]"
grep -q "next.md -> no tests" "$TMP/why.txt" && grep -q "grill-me/a -> grill-me ticket-planner" "$TMP/why.txt" &&
  ok "the reason for each path goes to stderr" || bad "reasons: $(cat "$TMP/why.txt")"

echo "=== usage errors exit 2 ==="
bash "$SEL" --bogus </dev/null >/dev/null 2>&1
[ $? -eq 2 ] && ok "unknown option" || bad "unknown option did not exit 2"
bash "$SEL" --files "$TMP/no-such" >/dev/null 2>&1
[ $? -eq 2 ] && ok "--files with a missing file" || bad "missing --files did not exit 2"
bash "$SEL" --base >/dev/null 2>&1
[ $? -eq 2 ] && ok "--base with no value" || bad "--base with no value did not exit 2"

echo "=== --base REF diffs against HEAD in the current repo ==="
R="$TMP/repo"
mkdir -p "$R/knowledge-curator/lib" "$R/grill-me"
(
  cd "$R" &&
    git init -q &&
    git config user.email t@example.invalid &&
    git config user.name t &&
    git config commit.gpgsign false &&
    echo a >knowledge-curator/lib/a.sh &&
    echo n >next.md &&
    git add . &&
    git commit -qm one &&
    echo b >>knowledge-curator/lib/a.sh &&
    echo m >>next.md &&
    git commit -qam two
) || bad "fixture repo setup failed"
got=$(cd "$R" && bash "$SEL" --base HEAD~1 2>/dev/null)
[ "$got" = "$FF knowledge-curator/ $DD" ] && ok "--base HEAD~1 selects the commit's plugin" || bad "--base gave [$got]"
(cd "$R" && bash "$SEL" --base no-such-ref >/dev/null 2>&1)
[ $? -eq 2 ] && ok "a bad --base ref exits 2 (the caller runs everything)" || bad "bad ref did not exit 2"

echo "=== the map matches the repo ==="
plugins_script=$(sed -n 's/^PLUGINS=(\(.*\))$/\1/p' "$SEL" | tr ' ' '\n' | sort)
plugins_disk=$(cd "$ROOT" && for d in */.claude-plugin/plugin.json; do echo "${d%%/*}"; done | sort)
[ "$plugins_script" = "$plugins_disk" ] && ok "PLUGINS is every directory with a .claude-plugin/plugin.json" ||
  bad "PLUGINS [$(echo $plugins_script)] vs disk [$(echo $plugins_disk)]"
for f in "$FF" "$DD" "$TC"; do
  if [ -f "$ROOT/$f" ] && grep -qF "$f" "$ROOT/Makefile"; then
    ok "$f exists and is a Makefile test"
  else
    bad "$f is gone or unregistered: update select-tests.sh"
  fi
done
read -r -a targets <<<"$(make -s --no-print-directory -C "$ROOT" print-test-targets)"
TEST_LOG_DIR="$TMP/real" bash "$RUNNER" --list "${targets[@]}" 2>/dev/null >"$TMP/all.txt"
groups="$(echo $plugins_disk) scripts"
stray=$(
  python3 - "$TMP/all.txt" "$ROOT" "$groups" <<'PY'
import re, sys
root, groups = sys.argv[2], set(sys.argv[3].split())
pat = re.compile(r"(?:^|\s)(?:bash|python3 -m pytest)\s+(\S+)")
for c in open(sys.argv[1]):
    m = pat.search(c)
    p = m.group(1) if m else ""
    p = p[len(root) + 1:] if p.startswith(root + "/") else p
    if p.split("/")[0] not in groups:
        print(c.strip())
PY
)
[ -z "$stray" ] && ok "every Makefile test lives in a plugin directory or scripts/" ||
  bad "tests no group selects (a subset run would never run them): $stray"

echo "=== a selection runs on the real Makefile, split over 4 shards ==="
total=$(wc -l <"$TMP/all.txt")
for change in knowledge-curator/lib/kc-item.sh ticket-planner/lib/planner-state.sh fleet-controller/lib/fleet-dispatch.sh; do
  only=$(sel "$change")
  TEST_LOG_DIR="$TMP/real" bash "$RUNNER" --list --only "$only" "${targets[@]}" 2>/dev/null | sort >"$TMP/subset.txt"
  n=$(wc -l <"$TMP/subset.txt")
  : >"$TMP/union.txt"
  for K in 1 2 3 4; do
    TEST_LOG_DIR="$TMP/real" bash "$RUNNER" --list --only "$only" --shard "$K/4" "${targets[@]}" 2>/dev/null >>"$TMP/union.txt"
  done
  if [ "$n" -gt 0 ] && [ "$n" -lt "$total" ] && [ "$(sort "$TMP/union.txt")" = "$(cat "$TMP/subset.txt")" ]; then
    ok "${change%%/*} change: $n of $total commands, 4 shards cover them once"
  else
    bad "${change%%/*} change: subset $n of $total, shard union $(wc -l <"$TMP/union.txt")"
  fi
done
only=$(sel knowledge-curator/lib/kc-item.sh)
if TEST_LOG_DIR="$TMP/real" bash "$RUNNER" --list --only "$only" "${targets[@]}" 2>/dev/null |
  grep -vqE "knowledge-curator/|$FF|$DD"; then
  bad "a knowledge-curator change selected another plugin's tests"
else
  ok "a knowledge-curator change selects nothing else but the two scans"
fi
grep -q "test-select-tests.sh" "$TMP/all.txt" && ok "this test is a Makefile test" || bad "test-select-tests.sh unregistered"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
