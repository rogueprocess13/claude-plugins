#!/usr/bin/env bash
# test-plugin-cache.sh — plugin-cache resolvers pick the installed version, then
# the newest cached version by *version* order, never by text order (#468).
#
# A text sort puts 0.9.4 after 0.62.7, so a cache holding both used to resolve
# to the stale 0.9.4 copy of flow.sh / workflow.json / ... for every caller.
#
# Covers:
#   1. tap_cache_find (lib/plugin-cache.sh) — numeric scan, installPath wins,
#      stale installPath falls back, always returns 0.
#   2. The lib resolver functions that use it, extracted from their files and
#      run against a fixture HOME.
#   3. Every inline SKILL.md / skill-preamble bootstrap block, run verbatim.
#   4. No lexical `sort | tail -1` / `head -1` plugin-cache lookup remains.
#
# Run: bash ticket-auto-pipeline/lib/tests/test-plugin-cache.sh

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGIN_ROOT="$(cd "${LIB_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PLUGIN_ROOT}/.." && pwd)"

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
  # expect <name> <expected> <got>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FX_HOME="${TMP}/home"
CACHE="${FX_HOME}/.claude/plugins/cache/willard-pro-claude-plugins"
INSTALLED="${FX_HOME}/.claude/plugins/installed_plugins.json"

# Files the resolvers under test look up, per plugin.
TAP_FILES="skills/ticket-flow/flow.sh skills/ticket-flow/workflow.json
skills/ticket-flow/validate-linear-config.sh skills/ticket-flow/outbox-drain.sh
skills/ticket-detect-resume/detect-resume.sh lib/planned-feedback-write.sh
lib/env-check.sh lib/pipeline-postmortem.sh
skills/ticket-retro/templates/auto-retro-finding.md"
FC_FILES="lib/fleet-notify.sh lib/fleet-env-check.sh"

for v in 0.9.4 0.62.7; do
  for f in $TAP_FILES; do
    mkdir -p "$(dirname "${CACHE}/ticket-auto-pipeline/${v}/${f}")"
    echo "$v" >"${CACHE}/ticket-auto-pipeline/${v}/${f}"
  done
  for f in $FC_FILES; do
    mkdir -p "$(dirname "${CACHE}/fleet-controller/${v}/${f}")"
    echo "$v" >"${CACHE}/fleet-controller/${v}/${f}"
  done
done

# installed_plugins.json pointing both plugins at <version>.
write_installed() {
  cat >"$INSTALLED" <<JSON
{
  "version": 2,
  "plugins": {
    "ticket-auto-pipeline@willard-pro-claude-plugins": [
      {
        "scope": "user",
        "installPath": "${CACHE}/ticket-auto-pipeline/${1}",
        "version": "${1}"
      }
    ],
    "fleet-controller@willard-pro-claude-plugins": [
      {
        "scope": "user",
        "installPath": "${CACHE}/fleet-controller/${1}/",
        "version": "${1}"
      }
    ]
  }
}
JSON
}

echo "=== plugin-cache resolver tests (#468) ==="

# ── Test 1: tap_cache_find ──────────────────────────────────────────────────────

echo "--- Test 1: tap_cache_find ---"

find_with() {
  HOME="$FX_HOME" bash -c 'set -eo pipefail; source "$1"; tap_cache_find "$2" "$3"; echo "rc=$?"' \
    _ "${LIB_DIR}/plugin-cache.sh" "$1" "$2"
}

rm -f "$INSTALLED"
expect "1a: cache scan picks 0.62.7 over 0.9.4" \
  "${CACHE}/ticket-auto-pipeline/0.62.7/skills/ticket-flow/flow.sh"$'\n'"rc=0" \
  "$(find_with ticket-auto-pipeline skills/ticket-flow/flow.sh)"

write_installed 0.9.4
expect "1b: installPath wins over a newer cache dir" \
  "${CACHE}/ticket-auto-pipeline/0.9.4/skills/ticket-flow/flow.sh"$'\n'"rc=0" \
  "$(find_with ticket-auto-pipeline skills/ticket-flow/flow.sh)"
expect "1c: installPath with a trailing slash resolves" \
  "${CACHE}/fleet-controller/0.9.4/lib/fleet-notify.sh"$'\n'"rc=0" \
  "$(find_with fleet-controller lib/fleet-notify.sh)"

write_installed 9.9.9
expect "1d: stale installPath falls back to the numeric scan" \
  "${CACHE}/ticket-auto-pipeline/0.62.7/skills/ticket-flow/flow.sh"$'\n'"rc=0" \
  "$(find_with ticket-auto-pipeline skills/ticket-flow/flow.sh)"

expect "1e: no copy anywhere prints nothing and returns 0 under set -e" \
  "rc=0" "$(find_with ticket-auto-pipeline lib/does-not-exist.sh)"

# Numeric, not version-sort-of-the-whole-path: 0.10.0 > 0.9.10 > 0.9.9.
for v in 0.9.9 0.9.10 0.10.0; do
  mkdir -p "${TMP}/h2/.claude/plugins/cache/m/demo/${v}/lib"
  touch "${TMP}/h2/.claude/plugins/cache/m/demo/${v}/lib/x.sh"
done
got=$(HOME="${TMP}/h2" bash -c 'source "$1"; tap_cache_find demo lib/x.sh' _ "${LIB_DIR}/plugin-cache.sh")
expect "1f: 0.10.0 beats 0.9.10 and 0.9.9" "${TMP}/h2/.claude/plugins/cache/m/demo/0.10.0/lib/x.sh" "$got"

# ── Test 2: lib resolver functions ──────────────────────────────────────────────
#
# Each function is extracted verbatim from its file and run with its lib-dir
# variable pointed at a fixture holding only plugin-cache.sh, so the sibling
# (source-tree) candidates miss and the cache lookup is what answers.

echo "--- Test 2: lib resolver functions ---"

FX_LIB="${TMP}/fxroot/lib"
mkdir -p "$FX_LIB"
cp "${LIB_DIR}/plugin-cache.sh" "$FX_LIB/"

# run_fn <file> <function> <lib-dir-var>
run_fn() {
  local body
  body=$(sed -n "/^${2}() {/,/^}/p" "$1")
  if [ -z "$body" ]; then
    echo "MISSING:${2}"
    return 0
  fi
  HOME="$FX_HOME" FN_BODY="$body" bash -c "${3}='${FX_LIB}'; SCRIPT_DIR='${FX_LIB}'; eval \"\$FN_BODY\"; ${2} || true"
}

check_fns() {
  local want="$1" label="$2"
  local file fn var rel got
  while read -r file fn var rel; do
    [ -n "$file" ] || continue
    got=$(run_fn "${PLUGIN_ROOT}/${file}" "$fn" "$var")
    expect "2: ${fn} ${label}" "${CACHE}/${rel/@V@/$want}" "$got"
  done <<SPEC
lib/events.sh _events_resolve_workflow_json _EV_LIB_DIR ticket-auto-pipeline/@V@/skills/ticket-flow/workflow.json
lib/board-drivers/linear.sh _linear_driver_resolve_workflow_json _LD_LIB_DIR ticket-auto-pipeline/@V@/skills/ticket-flow/workflow.json
lib/ticket-preamble.sh _tp_state_machine _TP_LIB_DIR ticket-auto-pipeline/@V@/skills/ticket-flow/workflow.json
lib/ticket-preamble.sh _tp_validate_script _TP_LIB_DIR ticket-auto-pipeline/@V@/skills/ticket-flow/validate-linear-config.sh
lib/gate-check.sh _resolve_flow_sh SCRIPT_DIR ticket-auto-pipeline/@V@/skills/ticket-flow/flow.sh
skills/ticket-flow/outbox-drain.sh _outbox_drain_resolve_fleet_notify _OD_LIB_DIR fleet-controller/@V@/lib/fleet-notify.sh
SPEC
}

rm -f "$INSTALLED"
check_fns 0.62.7 "picks 0.62.7 over 0.9.4"
write_installed 0.9.4
check_fns 0.9.4 "follows installPath"

# ── Test 3: inline SKILL.md / preamble bootstrap blocks, run verbatim ───────────
#
# These run before any helper can be sourced, so they carry their own copy of
# the lookup. Every block starts at its `VAR=` default line and ends at the
# cache-scan line.

echo "--- Test 3: inline bootstrap blocks ---"

# skill-preamble.md, skill-preamble-auto.md and ticket-gate-reconcile/SKILL.md no
# longer carry a flow.sh resolver: they fire triggers through lib/flow-run.sh,
# which uses tap_cache_find (guarded by lib/tests/test-flow-run.sh).
# ticket-flow, ticket-env-check (tap_cache_find) and fleet-features
# (fleet_cache_find) source the synced resolver instead of a pasted block, so
# they are not listed. ticket-auto lost its last block (Step 0.4 _validate_sh)
# to lib/ticket-preamble.sh (_tp_validate_script, Test 2). Only files that
# still carry a block belong here — a listed file with none fails.
BLOCK_FILES="fleet-controller/skills/fleet-env-check/SKILL.md"

# extract_blocks <file> — prints each block, NUL-separated.
extract_blocks() {
  awk '
    { line[NR] = $0 }
    /^[[:space:]]*\[ -f "\$[A-Za-z_]+" \] \|\| [A-Za-z_]+=\$\(find "\$\{HOME\}\/\.claude\/plugins\/cache" \\$/ { ends[++n] = NR + 1 }
    END {
      for (k = 1; k <= n; k++) {
        e = ends[k]
        # Walk back to the `VAR=` default assignment that opens the block.
        for (s = e; s > 0; s--) if (line[s] ~ /^[[:space:]]*[A-Za-z_]+="/ || line[s] ~ /^[[:space:]]*[A-Za-z_]+=""$/) break
        for (i = s; i <= e; i++) print line[i]
        printf "%c", 0
      }
    }' "$1"
}

total_blocks=0
run_blocks() {
  local want="$1" label="$2" f block var got n
  for f in $BLOCK_FILES; do
    n=0
    while IFS= read -r -d '' block; do
      n=$((n + 1))
      var=$(printf '%s\n' "$block" | sed -n 's/^[[:space:]]*\[ -f "\$\([A-Za-z_]*\)" \] || .*/\1/p' | head -1)
      got=$(HOME="$FX_HOME" BLOCK="$block" bash -c 'eval "$BLOCK"; echo "${'"$var"'}"')
      case "$got" in
      */"${want}"/*) pass "3: ${f} block ${n} (${var}) ${label}" ;;
      *) fail "3: ${f} block ${n} (${var}) ${label}" "got '$got'" ;;
      esac
    done < <(extract_blocks "${REPO_ROOT}/${f}")
    if [ "$n" -eq 0 ]; then
      fail "3: ${f} has a version-aware bootstrap block" "none found"
    fi
    total_blocks=$((total_blocks + n))
  done
}

rm -f "$INSTALLED"
run_blocks 0.62.7 "picks 0.62.7 over 0.9.4"
write_installed 0.9.4
run_blocks 0.9.4 "follows installPath"
write_installed 9.9.9
run_blocks 0.62.7 "falls back from a stale installPath"
echo "  ($((total_blocks / 3)) blocks)"

# ticket-flow/SKILL.md's main execution block used to carry its own flow.sh
# resolver; it now delegates to lib/flow-run.sh (tap_cache_find). Make sure it
# did not regress back to an inline copy.
if grep -q '^bash "\$_flow_sh"' "${PLUGIN_ROOT}/skills/ticket-flow/SKILL.md"; then
  fail "3: ticket-flow SKILL.md runs flow.sh through lib/flow-run.sh" "inline resolver is back"
else
  pass "3: ticket-flow SKILL.md runs flow.sh through lib/flow-run.sh"
fi

# ── Test 4: no lexical plugin-cache lookup remains ──────────────────────────────

echo "--- Test 4: no text-sorted plugin-cache lookup remains ---"

# A lookup may span two lines (`find "$HOME/.claude/plugins/cache" ... \` then
# `-path ... | sort | tail -1`), so a text-sorted line counts when it or the
# line before it names the plugin cache.
hits=$(cd "$REPO_ROOT" && find ticket-auto-pipeline fleet-controller \
  -path '*/tests' -prune -o -type f \( -name '*.sh' -o -name '*.md' \) ! -name README.md -print |
  sort | xargs awk '
    FNR == 1 { prev = "" }
    !/^[[:space:]]*#/ && /\| *sort *\| *tail -1|\| *head -1/ && (($0 prev) ~ /plugins\/cache/) { print FILENAME ":" FNR ": " $0 }
    { prev = $0 }' || true)
if [ -z "$hits" ]; then
  pass "4: no 'plugins/cache ... | sort | tail -1' or '| head -1' lookup"
else
  fail "4: lexical plugin-cache lookups remain" ""
  printf '%s\n' "$hits" | sed 's/^/    /'
fi

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
