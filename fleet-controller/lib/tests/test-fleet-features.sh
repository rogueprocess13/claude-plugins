#!/usr/bin/env bash
# test-fleet-features.sh — feature-flag catalog drift gate + unit tests for
# lib/fleet-features.sh.
#
# The drift gate (test_gate_*) scans plugin source for boolean feature-flag
# defaults and fails when one is neither in fleet-controller/features.json nor
# in IGNORE_FLAGS below, or when a catalog `default` disagrees with the code.
# Adding a new opt-in flag therefore REQUIRES a catalog entry.
#
# Usage: bash test-fleet-features.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
REPO_DIR="$(cd "$PLUGIN_DIR/.." && pwd)"
CATALOG="$PLUGIN_DIR/features.json"
FEATURES="$LIB_DIR/fleet-features.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if [ -n "${FILTER:-}" ] && [[ "$name" != *"$FILTER"* ]]; then
    return 0
  fi
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# ── Ignore list ─────────────────────────────────────────────────────────────────
# Names the scanner matches that are NOT operator feature flags. Every entry
# needs a reason. Do not add a real opt-in flag here — catalog it instead.
IGNORE_FLAGS=(
  # Script-local state / parsed results, never read from the operator's env:
  APPROVED               # approve.sh/reject.sh manifest field read-back
  DIRTY                  # prescan-check.sh working-tree state
  EMIT_DIRECTIVE         # planner prompt template variable
  EXIT_CODE              # exit-path.sh / postmortem argument
  FAST_PATH_PRE_APPROVED # appraise-fast-path.sh parsed result
  FAST_PATH_REGENERATE   # appraise-fast-path.sh parsed result
  FROM_PLANNED           # planned-feedback-write.sh parsed result
  GITNEXUS_INDEXED       # ticket-prescan probe result
  # Counters and scores (":-0" is a numeric default, not a switch):
  CORRECTION_COUNT
  FENCE_CHECK_FENCED_GEN
  GITNEXUS_SYMBOL_COUNT
  ITERATION
  PR_FEEDBACK_CYCLE
  QA_COPIED_COUNT
  QA_EXCLUDED_COUNT
  RECONCILE_CYCLE
  RECONCILE_N
  STALENESS_SCORE
  TOTAL_COUNT
  UNCHECKED_COUNT
  VAGUE_AC_COUNT
  VERIFY_ATTEMPTS
  VPLAN_ROWS
  VPLAN_VERIFIABLE
  VAR # literal `${VAR:-0}` quoted in a phase_dispatch.py docstring
  # Test-only hooks:
  GATE_CHECK_TEST_MODE # gate-check.sh test seam
  # Dead knob: ticket-auto-pipeline/lib/config.sh defines it, nothing reads it.
  FLEET_DEBUG
)

# _scan ROOT — prints NAME<TAB>DEFAULT<TAB>FILE:LINE for every boolean
# feature-flag default under ROOT's plugin source.
#   shell:  ${NAME:-false|0|off|true|on}
#   python: os.environ.get('NAME', 'D')[.lower()] ==|!= 'true|false|1|0|on|off'
#           (multi-line calls included)
# Scope: *.sh, *.py and skills/**/SKILL.md (they hold executed bash) inside
# the plugin directories; tests, fixtures and openspec are excluded.
_scan() {
  python3 - "$1" <<'PY'
import os, re, sys
root = sys.argv[1]
plugins = ["fleet-controller", "ticket-auto-pipeline", "ticket-planner",
           "knowledge-curator", "grill-me"]
skip = re.compile(r"(^|/)(tests?|fixtures|openspec|node_modules|__pycache__)(/|$)")
sh = re.compile(r"\$\{([A-Z][A-Z0-9_]*):-(false|0|off|true|on)\}")
py = re.compile(r"(?:os\.environ\.get|os\.getenv)\(\s*['\"]([A-Z][A-Z0-9_]*)['\"]\s*,"
                r"\s*['\"]([^'\"]*)['\"]\s*\)\s*(?:\.lower\(\)\s*)?(?:==|!=)\s*"
                r"['\"](?:true|false|1|0|on|off)['\"]")
for p in plugins:
    base = os.path.join(root, p)
    for d, dirs, files in os.walk(base):
        rel_d = os.path.relpath(d, root)
        dirs[:] = [x for x in dirs if not skip.search(os.path.join(rel_d, x))]
        for f in files:
            rel = os.path.join(rel_d, f)
            if skip.search(rel):
                continue
            if f.endswith(".sh") or (f == "SKILL.md" and "/skills/" in "/" + rel):
                rx = sh
            elif f.endswith(".py"):
                rx = py
            else:
                continue
            try:
                text = open(os.path.join(root, rel), encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for m in rx.finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                print(f"{m.group(1)}\t{m.group(2)}\t{rel}:{line}")
PY
}

# _gate_problems ROOT CATALOG — prints one line per drift problem; empty = clean.
_gate_problems() {
  local root="$1" catalog="$2"
  _scan "$root" | IGNORE="${IGNORE_FLAGS[*]}" python3 -c '
import json, os, sys
cat = {f["name"]: f for f in json.load(open(sys.argv[1]))["flags"]}
ignore = set(os.environ.get("IGNORE", "").split())
OFF, ON = {"", "0", "false", "off", "no"}, {"1", "true", "on", "yes"}
def norm(v):
    v = str(v).lower()
    return "off" if v in OFF else "on" if v in ON else v
seen, problems = set(), []
for raw in sys.stdin:
    name, default, where = raw.rstrip("\n").split("\t")
    if name in ignore:
        continue
    if name not in cat:
        problems.append(f"UNCATALOGUED {name} (code default {default!r}) at {where}: add it to fleet-controller/features.json or, if it is not an operator flag, to IGNORE_FLAGS with a reason")
        continue
    seen.add(name)
    entry = cat[name]
    if norm(default) == norm(entry["default"]):
        continue
    f = where.rsplit(":", 1)[0]
    if any(e["file"] == f and norm(e["default"]) == norm(default)
           for e in entry.get("default_exceptions", [])):
        continue
    want = entry.get("default")
    problems.append(f"DEFAULT MISMATCH {name}: code {default!r} at {where}, catalog {want!r}")
for name in sorted(set(cat) - seen):
    problems.append(f"STALE {name}: in the catalog but no boolean default found in plugin source")
print("\n".join(problems))
' "$catalog"
}

# ── Drift gate ──────────────────────────────────────────────────────────────────

test_gate_repo_clean() {
  local problems
  # A scanner/checker crash must fail the gate, not read as "no problems".
  problems=$(_gate_problems "$REPO_DIR" "$CATALOG") || {
    echo "drift gate checker failed" >&2
    return 1
  }
  [ -z "$problems" ] || {
    echo "$problems" >&2
    return 1
  }
}

test_gate_scanner_finds_known_shapes() {
  # Shell, single-line python and multi-line python shapes must all be seen.
  local hits
  hits=$(_scan "$REPO_DIR") || return 1
  grep -q $'^FLEET_EPIC_AUTO_PR\tfalse\t' <<<"$hits" &&
    grep -q $'^FLEET_STORE_ENABLE\ttrue\tfleet-controller/fleetd/' <<<"$hits" &&
    grep -q $'^FLEET_BOARD_PUSHER_ENABLE\tfalse\tfleet-controller/fleetd/supervisor.py' <<<"$hits" &&
    grep -q $'^FLEETD_SPAWN_ENABLED\t\tfleet-controller/fleetd/' <<<"$hits"
}

# A synthetic plugin tree: the gate must reject an uncatalogued flag and a
# wrong default, and accept the same tree once both are fixed.
test_gate_rejects_uncatalogued_and_mismatch() {
  local tmp rc=0 problems
  tmp=$(mktemp -d)
  mkdir -p "$tmp/fleet-controller/lib" "$tmp/fleet-controller/lib/tests"
  cat >"$tmp/fleet-controller/lib/x.sh" <<'EOF'
A="${FAKE_FEATURE_ENABLE:-false}"
B="${FAKE_KNOWN:-true}"
EOF
  # Hits inside tests/ are out of scope.
  echo 'C="${FAKE_TEST_ONLY:-false}"' >"$tmp/fleet-controller/lib/tests/t.sh"
  cat >"$tmp/catalog.json" <<'EOF'
{"flags": [{"name": "FAKE_KNOWN", "default": "false"}]}
EOF
  problems=$(_gate_problems "$tmp" "$tmp/catalog.json") || rc=1
  grep -q "UNCATALOGUED FAKE_FEATURE_ENABLE" <<<"$problems" || rc=1
  grep -q "DEFAULT MISMATCH FAKE_KNOWN" <<<"$problems" || rc=1
  if grep -q "FAKE_TEST_ONLY" <<<"$problems"; then rc=1; fi
  cat >"$tmp/catalog.json" <<'EOF'
{"flags": [{"name": "FAKE_KNOWN", "default": "true"},
           {"name": "FAKE_FEATURE_ENABLE", "default": "0"}]}
EOF
  problems=$(_gate_problems "$tmp" "$tmp/catalog.json") || rc=1
  [ -z "$problems" ] || rc=1
  rm -rf "$tmp"
  return $rc
}

test_catalog_schema() {
  jq -e '
    .flags | length > 0 and all(
      (.name | test("^[A-Z][A-Z0-9_]*$")) and
      (.plugin | IN("fleet-controller", "ticket-auto-pipeline", "ticket-planner", "knowledge-curator", "grill-me")) and
      (.default | type == "string") and
      (.category | IN("feature", "safety", "strictness", "debug-escape-hatch", "intentional-off")) and
      (.recommend | IN("on", "off", "situational")) and
      (.summary | type == "string" and length > 0) and
      (.why | type == "string" and length > 0) and
      (.docs | type == "string" and length > 0) and
      (.requires | type == "array"))
    and ([.[].name] | length == (unique | length))
  ' "$CATALOG" >/dev/null
}

test_catalog_docs_paths_exist() {
  local p missing=0
  while IFS= read -r p; do
    [ -e "$REPO_DIR/${p%%#*}" ] || {
      echo "docs path missing: $p" >&2
      missing=1
    }
  done < <(jq -r '.flags[].docs' "$CATALOG")
  return $missing
}

test_catalog_flag_requires_resolve() {
  # Every {"flag": X} prerequisite must itself be a catalog entry.
  jq -e '[.flags[].name] as $n | all(.flags[].requires[]; (has("flag") | not) or (.flag | IN($n[])))' \
    "$CATALOG" >/dev/null
}

# ── Script behaviour (anonymised fixture) ───────────────────────────────────────

_mk_fixture() {
  local d="$1"
  mkdir -p "$d/ws/.claude"
  cat >"$d/catalog.json" <<'EOF'
{"flags": [
  {"name": "TF_ENV_WINS", "plugin": "fleet-controller", "default": "false", "category": "feature",
   "summary": "s", "requires": [], "recommend": "on", "why": "w", "docs": "d"},
  {"name": "TF_START_WINS", "plugin": "fleet-controller", "default": "false", "category": "feature",
   "summary": "s", "requires": [], "recommend": "on", "why": "w", "docs": "d"},
  {"name": "TF_SETTINGS_ONLY", "plugin": "fleet-controller", "default": "false", "category": "feature",
   "summary": "s", "requires": [], "recommend": "on", "why": "w", "docs": "d"},
  {"name": "TF_DYNAMIC", "plugin": "fleet-controller", "default": "false", "category": "feature",
   "summary": "s", "requires": [], "recommend": "on", "why": "w", "docs": "d"},
  {"name": "TF_COMMENTED", "plugin": "fleet-controller", "default": "false", "category": "feature",
   "summary": "s", "requires": [], "recommend": "on", "why": "w", "docs": "d"},
  {"name": "TF_SPAWN", "plugin": "fleet-controller", "default": "0", "on_value": "1", "category": "feature",
   "summary": "s", "requires": [], "recommend": "on", "why": "w", "docs": "d"},
  {"name": "TF_NEEDS_OFF_FLAG", "plugin": "fleet-controller", "default": "false", "category": "feature",
   "summary": "s", "requires": [{"flag": "TF_COMMENTED"}, {"env": "TF_SECRET_TOKEN"}, {"step": "do a thing"}],
   "recommend": "on", "why": "w", "docs": "d"},
  {"name": "TF_NEEDS_MET", "plugin": "fleet-controller", "default": "false", "category": "feature",
   "summary": "s", "requires": [{"flag": "TF_START_WINS"}, {"env": "TF_PRESENT_KEY"}],
   "recommend": "on", "why": "w", "docs": "d"},
  {"name": "TF_API_KEY_ENABLE", "plugin": "fleet-controller", "default": "false", "category": "feature",
   "summary": "s", "requires": [], "recommend": "on", "why": "w", "docs": "d"}
]}
EOF
  cat >"$d/ws/fleet-start.sh" <<'EOF'
#!/usr/bin/env bash
export TF_ENV_WINS=false
export TF_START_WINS=true   # trailing comment
export TF_START_WINS="false"
export TF_START_WINS="true" # last assignment wins
# export TF_COMMENTED=true
if true; then
  export TF_DYNAMIC="${TF_DYNAMIC:-$(jq -r '.env.TF_DYNAMIC // empty' settings.json)}"
fi
export TF_SPAWN=1
export TF_API_KEY_ENABLE=supersecretvalue
EOF
  cat >"$d/ws/.claude/settings.local.json" <<'EOF'
{"env": {"TF_SETTINGS_ONLY": "true", "TF_START_WINS": "false", "TF_DYNAMIC": "true",
         "TF_PRESENT_KEY": "hunter2-do-not-print", "TF_SECRET_TOKEN": ""}}
EOF
}

_features_json() {
  local d="$1"
  shift
  env -u TF_START_WINS -u TF_SETTINGS_ONLY -u TF_DYNAMIC -u TF_COMMENTED -u TF_SPAWN \
    -u TF_PRESENT_KEY -u TF_SECRET_TOKEN -u TF_API_KEY_ENABLE \
    TF_ENV_WINS=true bash "$FEATURES" --workspace "$d/ws" --catalog "$d/catalog.json" --json "$@"
}

_field() { jq -r --arg n "$2" --arg f "$3" '.flags[] | select(.name == $n) | .[$f] | tostring' <<<"$1"; }

test_json_is_valid() {
  local tmp out rc=0
  tmp=$(mktemp -d)
  _mk_fixture "$tmp"
  out=$(_features_json "$tmp") || rc=1
  jq -e '.count == 9 and (.flags | length == 9)' <<<"$out" >/dev/null || rc=1
  # The real catalog against an empty workspace must also produce valid JSON.
  mkdir -p "$tmp/empty"
  bash "$FEATURES" --workspace "$tmp/empty" --no-env --json | jq -e '.count > 30' >/dev/null || rc=1
  rm -rf "$tmp"
  return $rc
}

test_precedence() {
  local tmp out rc=0
  tmp=$(mktemp -d)
  _mk_fixture "$tmp"
  out=$(_features_json "$tmp")
  [ "$(_field "$out" TF_ENV_WINS source)" = "env" ] && [ "$(_field "$out" TF_ENV_WINS value)" = "true" ] || rc=1
  [ "$(_field "$out" TF_START_WINS source)" = "fleet-start.sh" ] && [ "$(_field "$out" TF_START_WINS value)" = "true" ] || rc=1
  [ "$(_field "$out" TF_SETTINGS_ONLY source)" = "settings.local.json" ] || rc=1
  [[ "$(_field "$out" TF_DYNAMIC source)" == "settings.local.json (fleet-start.sh line is dynamic)" ]] || rc=1
  [ "$(_field "$out" TF_DYNAMIC enabled)" = "true" ] || rc=1
  [ "$(_field "$out" TF_COMMENTED source)" = "default" ] && [ "$(_field "$out" TF_COMMENTED enabled)" = "false" ] || rc=1
  [ "$(_field "$out" TF_SPAWN enabled)" = "true" ] || rc=1
  # --no-env drops layer 1: TF_ENV_WINS falls through to fleet-start.sh.
  out=$(_features_json "$tmp" --no-env)
  [ "$(_field "$out" TF_ENV_WINS source)" = "fleet-start.sh" ] && [ "$(_field "$out" TF_ENV_WINS value)" = "false" ] || rc=1
  rm -rf "$tmp"
  return $rc
}

test_workspace_from_fleetd_workspace_env() {
  local tmp out rc=0
  tmp=$(mktemp -d)
  _mk_fixture "$tmp"
  out=$(cd / && env -u TF_START_WINS FLEETD_WORKSPACE="$tmp/ws" bash "$FEATURES" --catalog "$tmp/catalog.json" --json --no-env)
  [ "$(_field "$out" TF_START_WINS source)" = "fleet-start.sh" ] || rc=1
  rm -rf "$tmp"
  return $rc
}

test_secret_values_never_printed() {
  local tmp json table rc=0
  tmp=$(mktemp -d)
  _mk_fixture "$tmp"
  json=$(_features_json "$tmp")
  table=$(env -u TF_API_KEY_ENABLE bash "$FEATURES" --workspace "$tmp/ws" --catalog "$tmp/catalog.json")
  [ "$(_field "$json" TF_API_KEY_ENABLE value)" = "****" ] || rc=1
  for out in "$json" "$table"; do
    if grep -q "supersecretvalue\|hunter2" <<<"$out"; then rc=1; fi
  done
  rm -rf "$tmp"
  return $rc
}

test_unmet_requires_marked() {
  local tmp out table rc=0
  tmp=$(mktemp -d)
  _mk_fixture "$tmp"
  out=$(_features_json "$tmp")
  [ "$(_field "$out" TF_NEEDS_OFF_FLAG requires_met)" = "false" ] || rc=1
  # Empty-string env value counts as unset.
  jq -e '.flags[] | select(.name == "TF_NEEDS_OFF_FLAG") |
    (.unmet | sort) == ["TF_COMMENTED", "TF_SECRET_TOKEN"] and .manual_steps == ["do a thing"]' \
    <<<"$out" >/dev/null || rc=1
  [ "$(_field "$out" TF_NEEDS_MET requires_met)" = "true" ] || rc=1
  table=$(env -u TF_COMMENTED -u TF_SECRET_TOKEN bash "$FEATURES" --workspace "$tmp/ws" --catalog "$tmp/catalog.json")
  grep -q "TF_NEEDS_OFF_FLAG.*UNMET:" <<<"$table" || rc=1
  rm -rf "$tmp"
  return $rc
}

test_never_executes_fleet_start() {
  local tmp rc=0
  tmp=$(mktemp -d)
  _mk_fixture "$tmp"
  echo "touch \"$tmp/EXECUTED\"" >>"$tmp/ws/fleet-start.sh"
  _features_json "$tmp" >/dev/null || rc=1
  [ ! -e "$tmp/EXECUTED" ] || rc=1
  rm -rf "$tmp"
  return $rc
}

test_bad_args_exit_12() {
  local rc=0
  bash "$FEATURES" --bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 12 ]
}

# ── Run ─────────────────────────────────────────────────────────────────────────
FILTER="${1:-}"
_run test_gate_repo_clean test_gate_repo_clean
_run test_gate_scanner_finds_known_shapes test_gate_scanner_finds_known_shapes
_run test_gate_rejects_uncatalogued_and_mismatch test_gate_rejects_uncatalogued_and_mismatch
_run test_catalog_schema test_catalog_schema
_run test_catalog_docs_paths_exist test_catalog_docs_paths_exist
_run test_catalog_flag_requires_resolve test_catalog_flag_requires_resolve
_run test_json_is_valid test_json_is_valid
_run test_precedence test_precedence
_run test_workspace_from_fleetd_workspace_env test_workspace_from_fleetd_workspace_env
_run test_secret_values_never_printed test_secret_values_never_printed
_run test_unmet_requires_marked test_unmet_requires_marked
_run test_never_executes_fleet_start test_never_executes_fleet_start
_run test_bad_args_exit_12 test_bad_args_exit_12

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
