#!/usr/bin/env bash
# test-fleet-skill-locator.sh — `fleet-plugin-cache.sh run`, the shared
# locator that replaced the inline lookup fences in the fleet-env-check and
# fleet-features skills (skill-deterministic-extraction 6c).
#
# Both old fences are embedded verbatim below as oracles (CI checkouts are
# shallow, so they cannot be read back with `git show`) and run against the
# same fixture HOME as the new call. The mktemp path in output is masked.
#
# Run: bash fleet-controller/lib/tests/test-fleet-skill-locator.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGIN_DIR="$(cd "${LIB_DIR}/.." && pwd)"

PASS=0
FAIL=0
expect() {
  if [ "$2" = "$3" ]; then
    echo "  PASS $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $1"
    echo "    expected: $(printf '%q' "$2")"
    echo "    got:      $(printf '%q' "$3")"
    FAIL=$((FAIL + 1))
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FX_HOME="$TMP/home"
CACHE="$FX_HOME/.claude/plugins/cache/willard-pro-claude-plugins/fleet-controller"
INSTALLED="$FX_HOME/.claude/plugins/installed_plugins.json"
mkdir -p "$FX_HOME/.claude/skills/lib" "$FX_HOME/.claude/plugins"
cp "$LIB_DIR/fleet-plugin-cache.sh" "$FX_HOME/.claude/skills/lib/"

# Fake scripts that say which copy ran and with what arguments.
fake_scripts() { # fake_scripts DIR LABEL
  mkdir -p "$1/lib"
  cat >"$1/lib/fleet-env-check.sh" <<EOF
#!/usr/bin/env bash
sf=""
while [ \$# -gt 0 ]; do
  case "\$1" in --summary-file) sf="\$2"; shift ;; esac
  shift
done
[ -n "\$sf" ] && [ "\${FAKE_EMPTY:-}" != 1 ] && printf -- '---BEGIN_VARS---\nX|ok|$2\nROWCOUNT=1\n---END_VARS---\n' >"\$sf"
echo "Summary written to \${sf}"
exit \${FAKE_RC:-0}
EOF
  cat >"$1/lib/fleet-features.sh" <<EOF
#!/usr/bin/env bash
[ "\${FAKE_EMPTY:-}" = 1 ] || echo "{\"from\":\"$2\",\"args\":\"\$*\"}"
exit \${FAKE_RC:-0}
EOF
}
fake_scripts "$CACHE/0.9.4" "0.9.4"
fake_scripts "$CACHE/0.46.8" "0.46.8"
fake_scripts "$TMP/root" "plugin-root"

installed() {
  printf '{"version":2,"plugins":{"fleet-controller@willard-pro-claude-plugins":[{"scope":"user","installPath":"%s","version":"%s"}]}}\n' \
    "$CACHE/$1" "$1" >"$INSTALLED"
}

# ── Oracles: the pre-extraction fences (main @ c4e2b01) ──────────────

old_env_check() {
  OUT=$(mktemp) # private 0600 file, never a fixed /tmp name
  ENV_CHECK=""
  # Not synced: the installed version recorded in installed_plugins.json, then the
  # newest cached version by *version* order (a plain sort picks 0.9.x over 0.62.x, #468).
  [ -f "$ENV_CHECK" ] || ENV_CHECK="$(sed -n 's/.*"installPath"[[:space:]]*:[[:space:]]*"\([^"]*\/fleet-controller\/[^"]*\)".*/\1/p' \
    "${HOME}/.claude/plugins/installed_plugins.json" 2>/dev/null | sort -V | tail -1)/lib/fleet-env-check.sh"
  [ -f "$ENV_CHECK" ] || ENV_CHECK=$(find "${HOME}/.claude/plugins/cache" \
    -path "*/fleet-controller/*/lib/fleet-env-check.sh" 2>/dev/null | sort -V | tail -1)
  [ -f "$ENV_CHECK" ] || ENV_CHECK=""
  if [ -z "$ENV_CHECK" ] && [ -f "$CLAUDE_PLUGIN_ROOT/lib/fleet-env-check.sh" ]; then
    ENV_CHECK="$CLAUDE_PLUGIN_ROOT/lib/fleet-env-check.sh"
  fi
  if [ -n "$ENV_CHECK" ]; then
    bash "$ENV_CHECK" --summary-file "$OUT" || true
  else
    echo "fleet-env-check.sh not found — reinstall the plugin"
  fi
  [ -s "$OUT" ] && cat "$OUT" || echo "OUTPUT_FILE_MISSING"
  rm -f "$OUT"
}

old_features() {
  OUT=$(mktemp) # private 0600 file, never a fixed /tmp name
  FEATURES_SH=""
  if [ -f ~/.claude/skills/lib/fleet-plugin-cache.sh ]; then
    source ~/.claude/skills/lib/fleet-plugin-cache.sh
    FEATURES_SH=$(fleet_cache_find fleet-controller lib/fleet-features.sh)
  fi
  if [ -z "$FEATURES_SH" ] && [ -f "$CLAUDE_PLUGIN_ROOT/lib/fleet-features.sh" ]; then
    FEATURES_SH="$CLAUDE_PLUGIN_ROOT/lib/fleet-features.sh"
  fi
  if [ -n "$FEATURES_SH" ]; then
    # Pass --workspace DIR here when the user gave one.
    bash "$FEATURES_SH" --json >"$OUT" || echo "fleet-features.sh failed (exit $?)"
  else
    echo "fleet-features.sh not found — reinstall the fleet-controller plugin"
  fi
  [ -s "$OUT" ] && cat "$OUT" || echo "OUTPUT_FILE_MISSING"
  rm -f "$OUT"
}

mask() { sed -E 's#/tmp/tmp\.[A-Za-z0-9]+#<OUT>#g; s#'"$TMP"'#<FX>#g'; }

# run_old FN [ENV...] / run_new ARGS... — each in a fresh shell with the fixture HOME.
run_old() {
  local fn="$1"
  shift
  env -i PATH="$PATH" HOME="$FX_HOME" CLAUDE_PLUGIN_ROOT="${CPR:-}" "$@" \
    bash -c "$(declare -f "$fn"); $fn" 2>&1 | mask
}
run_new() {
  env -i PATH="$PATH" HOME="$FX_HOME" CLAUDE_PLUGIN_ROOT="${CPR:-}" ${FAKE_ENV:-} \
    bash -c 'bash ~/.claude/skills/lib/fleet-plugin-cache.sh run "$@"' _ "$@" 2>&1 | mask
}

both() { # both LABEL — compares env-check and features, old vs new
  local o n
  o=$(run_old old_env_check ${FAKE_ENV:-})
  n=$(run_new --summary-file lib/fleet-env-check.sh)
  expect "$1: env-check matches oracle" "$o" "$n"
  o=$(run_old old_features ${FAKE_ENV:-})
  n=$(run_new lib/fleet-features.sh --json)
  expect "$1: features matches oracle" "$o" "$n"
}

echo "=== fleet skill locator (fleet-plugin-cache.sh run) ==="

CPR="" FAKE_ENV="" both "no installed_plugins.json → newest cache by version"
expect "  … and it is 0.46.8, not 0.9.4" '{"from":"0.46.8","args":"--json"}' "$(CPR="" run_new lib/fleet-features.sh --json)"

installed 0.9.4
CPR="" FAKE_ENV="" both "installPath wins over a newer cache dir"
expect "  … and it is 0.9.4" '{"from":"0.9.4","args":"--json"}' "$(CPR="" run_new lib/fleet-features.sh --json)"

installed 9.9.9
CPR="" FAKE_ENV="" both "stale installPath falls back to the cache scan"

FAKE_ENV="FAKE_RC=3" CPR="" both "script exits non-zero"
FAKE_ENV="FAKE_EMPTY=1" CPR="" both "script writes nothing → OUTPUT_FILE_MISSING"
FAKE_ENV="FAKE_EMPTY=1 FAKE_RC=4" CPR="" both "fails and writes nothing"
expect "  … features reports the exit code" \
  $'fleet-features.sh failed (exit 4)\nOUTPUT_FILE_MISSING' \
  "$(FAKE_ENV="FAKE_EMPTY=1 FAKE_RC=4" CPR="" run_new lib/fleet-features.sh --json)"

rm -f "$INSTALLED"
mv "$CACHE" "$TMP/cache-away"
CPR="$TMP/root" FAKE_ENV="" both "no cached copy → CLAUDE_PLUGIN_ROOT"

o=$(CPR="" run_old old_features)
n=$(CPR="" run_new lib/fleet-features.sh --json)
expect "nothing anywhere: features matches oracle" "$o" "$n"
# Behaviour change: env-check's not-found line now names the plugin.
expect "nothing anywhere: env-check names the plugin" \
  $'fleet-env-check.sh not found — reinstall the fleet-controller plugin\nOUTPUT_FILE_MISSING' \
  "$(CPR="" run_new --summary-file lib/fleet-env-check.sh)"
mv "$TMP/cache-away" "$CACHE"

# Sourcing defines functions only; the CLI does not run.
out=$(bash -c 'source "$1" run lib/fleet-features.sh; type -t fleet_cache_find' _ "$LIB_DIR/fleet-plugin-cache.sh" 2>&1)
expect "sourcing stays side-effect free" "function" "$out"
env -i PATH="$PATH" HOME="$FX_HOME" bash "$LIB_DIR/fleet-plugin-cache.sh" >/dev/null 2>&1
expect "no subcommand → exit 2" "2" "$?"
env -i PATH="$PATH" HOME="$FX_HOME" bash "$LIB_DIR/fleet-plugin-cache.sh" run >/dev/null 2>&1
expect "run without relpath → exit 2" "2" "$?"

echo "--- skills ---"
EC="$PLUGIN_DIR/skills/fleet-env-check/SKILL.md"
FF="$PLUGIN_DIR/skills/fleet-features/SKILL.md"
grep -q 'fleet-plugin-cache.sh run --summary-file lib/fleet-env-check.sh' "$EC"
expect "fleet-env-check calls the locator" "0" "$?"
grep -q 'fleet-plugin-cache.sh run lib/fleet-features.sh --json' "$FF"
expect "fleet-features calls the locator" "0" "$?"
if grep -q 'installPath\|fleet_cache_find\|OUTPUT_FILE_MISSING"' "$EC" "$FF"; then r=1; else r=0; fi
expect "inline locator fences are gone" "0" "$r"

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
