#!/usr/bin/env bash
# test-fleet-plugin-cache.sh — fleet-controller's plugin-cache lookup picks the
# installed version, then the newest cached version by *version* order (#468).
#
# A text sort puts 0.9.4 after 0.62.7, so fleet-intervene.sh's post-mortem
# lookup ran the stale 0.9.4 copy of ticket-auto-pipeline's
# pipeline-postmortem.sh whenever both were cached.
#
# Run: bash fleet-controller/lib/tests/test-fleet-plugin-cache.sh

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
expect() {
  if [ "$2" = "$3" ]; then
    echo "  PASS $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $1: expected '$2', got '$3'"
    FAIL=$((FAIL + 1))
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FX_HOME="${TMP}/home"
CACHE="${FX_HOME}/.claude/plugins/cache/willard-pro-claude-plugins"
INSTALLED="${FX_HOME}/.claude/plugins/installed_plugins.json"
MARK="${TMP}/postmortem-ran"

# Each cached pipeline-postmortem.sh records which version ran.
for v in 0.9.4 0.62.7; do
  mkdir -p "${CACHE}/ticket-auto-pipeline/${v}/lib"
  printf '#!/usr/bin/env bash\necho %s >"%s"\n' "$v" "$MARK" \
    >"${CACHE}/ticket-auto-pipeline/${v}/lib/pipeline-postmortem.sh"
done

write_installed() {
  cat >"$INSTALLED" <<JSON
{"version":2,"plugins":{"ticket-auto-pipeline@willard-pro-claude-plugins":[
  {"scope":"user","installPath":"${CACHE}/ticket-auto-pipeline/${1}","version":"${1}"}]}}
JSON
}

find_with() {
  HOME="$FX_HOME" bash -c 'set -eo pipefail; source "$1"; fleet_cache_find "$2" "$3"; echo "rc=$?"' \
    _ "${LIB_DIR}/fleet-plugin-cache.sh" "$1" "$2"
}

# Runs fleet-intervene.sh's real _fleet_postmortem and reports which cached
# version of pipeline-postmortem.sh it executed.
postmortem_ran() {
  rm -f "$MARK"
  HOME="$FX_HOME" FLEET_POSTMORTEM_ON_KILL=true bash -c \
    'source "$1"; _fleet_postmortem T-1 /dev/null /dev/null >/dev/null 2>&1' \
    _ "${LIB_DIR}/fleet-intervene.sh"
  cat "$MARK" 2>/dev/null || echo "none"
}

echo "=== fleet plugin-cache lookup tests (#468) ==="

rm -f "$INSTALLED"
expect "cache scan picks 0.62.7 over 0.9.4" \
  "${CACHE}/ticket-auto-pipeline/0.62.7/lib/pipeline-postmortem.sh"$'\n'"rc=0" \
  "$(find_with ticket-auto-pipeline lib/pipeline-postmortem.sh)"
expect "_fleet_postmortem runs 0.62.7, not 0.9.4" "0.62.7" "$(postmortem_ran)"

write_installed 0.9.4
expect "installPath wins over a newer cache dir" \
  "${CACHE}/ticket-auto-pipeline/0.9.4/lib/pipeline-postmortem.sh"$'\n'"rc=0" \
  "$(find_with ticket-auto-pipeline lib/pipeline-postmortem.sh)"
expect "_fleet_postmortem follows installPath" "0.9.4" "$(postmortem_ran)"

write_installed 9.9.9
expect "stale installPath falls back to the numeric scan" \
  "${CACHE}/ticket-auto-pipeline/0.62.7/lib/pipeline-postmortem.sh"$'\n'"rc=0" \
  "$(find_with ticket-auto-pipeline lib/pipeline-postmortem.sh)"

expect "no copy anywhere prints nothing and returns 0 under set -e" \
  "rc=0" "$(find_with ticket-auto-pipeline lib/does-not-exist.sh)"

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
