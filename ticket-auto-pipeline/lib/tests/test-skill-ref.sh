#!/usr/bin/env bash
# test-skill-ref.sh — lib/skill-ref.sh, the resolver for a skill's reference
# files through the plugin cache (skill-glue-collapse, design D3).
#
# Covers:
#   1. installed_plugins.json's installPath wins over a newer cached version.
#   2. Without installed_plugins.json, numeric version order (0.62.7 > 0.9.4).
#   3. A stale installPath (file absent there) falls back to the scan.
#   4. Missing file: exit 1, empty stdout, stderr names skill and file.
#   5. Usage: fewer than two args or an empty arg → exit 2.
#   6. Path escape: `..` components and absolute paths → exit 2, empty stdout.
#
# Run: bash ticket-auto-pipeline/lib/tests/test-skill-ref.sh

set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SKILL_REF="${LIB_DIR}/skill-ref.sh"

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
expect() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="${TMP}/home"
CACHE="${HOME}/.claude/plugins/cache/willard-pro-claude-plugins"
INSTALLED="${HOME}/.claude/plugins/installed_plugins.json"
REF="references/x.md"

for v in 0.9.4 0.62.7; do
  mkdir -p "${CACHE}/ticket-auto-pipeline/${v}/skills/ticket-verify/references"
  echo "$v" >"${CACHE}/ticket-auto-pipeline/${v}/skills/ticket-verify/${REF}"
done
# Only in the old version: proves a stale installPath falls back.
mkdir -p "${CACHE}/ticket-auto-pipeline/0.9.4/skills/ticket-verify/references"
echo old >"${CACHE}/ticket-auto-pipeline/0.9.4/skills/ticket-verify/references/old-only.md"

write_installed() {
  cat >"$INSTALLED" <<JSON
{
  "version": 2,
  "plugins": {
    "ticket-auto-pipeline@willard-pro-claude-plugins": [
      {"scope": "user", "installPath": "${CACHE}/ticket-auto-pipeline/${1}", "version": "${1}"}
    ]
  }
}
JSON
}

run() {
  OUT=""
  ERR=""
  RC=0
  OUT=$(bash "$SKILL_REF" "$@" 2>"$TMP/err") || RC=$?
  ERR=$(cat "$TMP/err")
}

# ── 1. installPath wins ──────────────────────────────────────────────────────
write_installed 0.9.4
run ticket-verify "$REF"
expect "1: installed 0.9.4 wins over cached 0.62.7" \
  "0:${CACHE}/ticket-auto-pipeline/0.9.4/skills/ticket-verify/${REF}" "${RC}:${OUT}"

# ── 2. Numeric order without installed_plugins.json ──────────────────────────
rm -f "$INSTALLED"
run ticket-verify "$REF"
expect "2: numeric order picks 0.62.7 over 0.9.4" \
  "0:${CACHE}/ticket-auto-pipeline/0.62.7/skills/ticket-verify/${REF}" "${RC}:${OUT}"

# ── 3. Stale installPath falls back ──────────────────────────────────────────
write_installed 0.62.7
run ticket-verify references/old-only.md
expect "3: file absent at installPath falls back to the scan" \
  "0:${CACHE}/ticket-auto-pipeline/0.9.4/skills/ticket-verify/references/old-only.md" "${RC}:${OUT}"

# ── 4. Missing file ──────────────────────────────────────────────────────────
run ticket-verify references/none.md
expect "4a: missing file exits 1 with empty stdout" "1:" "${RC}:${OUT}"
case "$ERR" in
*ticket-verify*references/none.md*) pass "4b: stderr names skill and file" ;;
*) fail "4b: stderr names skill and file" "$ERR" ;;
esac

# ── 5. Usage ─────────────────────────────────────────────────────────────────
run ticket-verify
expect "5a: one argument exits 2" "2:" "${RC}:${OUT}"
run
expect "5b: no arguments exits 2" "2:" "${RC}:${OUT}"
run "" "$REF"
expect "5c: empty skill exits 2" "2:" "${RC}:${OUT}"
run ticket-verify ""
expect "5d: empty file exits 2" "2:" "${RC}:${OUT}"

# ── 6. Path escape ───────────────────────────────────────────────────────────
run ticket-verify ../../lib/linear-api.sh
expect "6a: leading .. refused" "2:" "${RC}:${OUT}"
run ticket-verify references/../../ticket-flow/flow.sh
expect "6b: embedded .. refused" "2:" "${RC}:${OUT}"
run ticket-verify references/..
expect "6c: trailing .. refused" "2:" "${RC}:${OUT}"
run .. "$REF"
expect "6d: .. as the skill refused" "2:" "${RC}:${OUT}"
run ticket-verify /etc/passwd
expect "6e: absolute file refused" "2:" "${RC}:${OUT}"
run /ticket-verify "$REF"
expect "6f: absolute skill refused" "2:" "${RC}:${OUT}"
run ticket-verify references/..x.md
expect "6g: a name merely starting with .. is not a component (not found, exit 1)" "1:" "${RC}:${OUT}"

echo ""
echo "skill-ref: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
