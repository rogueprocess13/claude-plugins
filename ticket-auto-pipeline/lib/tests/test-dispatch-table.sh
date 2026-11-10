#!/usr/bin/env bash
# test-dispatch-table.sh — unit tests for skills/ticket-flow/dispatch-table.json
# and its generator, gen-dispatch-table.py.
#
# The generator is the drift gate between the canonical JSON and SKILL.md's
# rendered table. These tests prove the gate actually fires: a JSON edit that is
# not regenerated MUST fail --check, and --write MUST propagate it.
#
# Usage: bash test-dispatch-table.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
FLOW_DIR="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-flow"
GEN="$FLOW_DIR/gen-dispatch-table.py"
TABLE="$FLOW_DIR/dispatch-table.json"
SKILL="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-auto/SKILL.md"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc)"
    ((FAIL++)) || true
  fi
}

# ── sandbox ───────────────────────────────────────────────────────────────────
# Every mutating test runs against copies in a temp dir, never the real files,
# so a failed assertion can never leave the repo's SKILL.md rewritten.
_sandbox=""
_mksandbox() {
  _sandbox=$(mktemp -d "${TMPDIR:-/tmp}/test-dispatch-table.XXXXXX")
  cp "$TABLE" "$_sandbox/dispatch-table.json"
  cp "$SKILL" "$_sandbox/SKILL.md"
}
_cleanup() { [ -n "$_sandbox" ] && rm -rf "$_sandbox"; }
trap _cleanup EXIT

_gen() { python3 "$GEN" --table "$_sandbox/dispatch-table.json" --skill "$_sandbox/SKILL.md" "$@"; }

# ── tests ─────────────────────────────────────────────────────────────────────

test_json_is_valid_and_has_required_fields() {
  python3 - "$TABLE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
steps = data["steps"]
assert steps, "no steps"
for i, s in enumerate(steps):
    for f in ("step_id", "table_label", "table_action", "action"):
        assert f in s, f"steps[{i}] missing {f}"
ids = [s["step_id"] for s in steps]
assert len(ids) == len(set(ids)), f"duplicate step_id in {ids}"
PY
}

test_every_router_managed_loop_cap_is_recorded() {
  # Task 1.2: there are four router-managed cycle caps, not two. A regression
  # that drops one from the JSON silently drops it from fleetd's dispatch.
  python3 - "$TABLE" <<'PY'
import json, sys
steps = json.load(open(sys.argv[1]))["steps"]
loops = {s["step_id"]: s["loop"] for s in steps if "loop" in s}
expected = {
    "STEP_3_5": ("RECONCILE_CYCLE", 3, "RECONCILE_EXHAUSTED"),
    "STEP_4_5": ("VERIFY_ATTEMPTS", 2, "VERIFY_EXHAUSTED"),
    "STEP_4_6": ("ITERATION", 3, "PR_REVIEW_EXHAUSTED"),
    "STEP_5_5": ("PR_FEEDBACK_CYCLE", 3, "PR_FEEDBACK_EXHAUSTED"),
}
assert set(loops) == set(expected), f"loop steps drifted: {sorted(loops)}"
for sid, (counter, cap, code) in expected.items():
    got = loops[sid]
    assert got["counter"] == counter, f"{sid} counter {got['counter']} != {counter}"
    assert got["max_iterations"] == cap, f"{sid} cap {got['max_iterations']} != {cap}"
    assert got["gate_stop_code"] == code, f"{sid} code {got['gate_stop_code']!r} != {code!r}"

# STEP_4_6 shipped with a null code; fleetd-phase-supervisor task 4.6 named it.
# An unnamed cap makes pipeline-finalize.sh write "stopped: gate-stop " — a run
# that stopped without recording why — so the invariant is now that every
# router-managed cap names its exhaustion.
for sid, got in loops.items():
    assert got.get("gate_stop_code"), f"{sid} exhausts with no named gate-stop code"
PY
}

test_step_3_is_recorded_as_an_alias_of_step_2_5() {
  python3 - "$TABLE" <<'PY'
import json, sys
steps = {s["step_id"]: s for s in json.load(open(sys.argv[1]))["steps"]}
assert steps["STEP_3"]["action"] == "alias"
assert steps["STEP_3"]["alias_of"] == "STEP_2_5"
assert "STEP_3" in steps["STEP_2_5"]["aliases"]
PY
}

# skill-prose-dedupe 3a: the rendered table has no Type column and no row of
# its own for an alias step. The alias id must still reach the router, on its
# target's row — detect-resume.sh can emit STEP_3.
test_rendered_table_has_no_type_column_and_folds_aliases() {
  local block
  block=$(python3 "$GEN")
  grep -qxF '| RESUME_STEP | Action |' <<<"$block" || return 1
  ! grep -q '| Type |' <<<"$block" || return 1
  grep -q '^| `STEP_2_5` / `STEP_3` | Run `bash gate-check.sh --mode entry` |$' <<<"$block" || return 1
  ! grep -q '^| `STEP_3` |' <<<"$block"
}

test_verify_last_precondition_is_captured() {
  # Task 1.3: the VERIFY_LAST=fail crash-resume branch is dispatch-relevant
  # control flow a step->action table cannot express.
  python3 - "$TABLE" <<'PY'
import json, sys
steps = {s["step_id"]: s for s in json.load(open(sys.argv[1]))["steps"]}
pre = steps["STEP_4_5"]["precondition"]
assert pre["variable"] == "VERIFY_LAST"
assert pre["equals"] == "fail"
assert pre["then_dispatch_first"] == "STEP_4"
PY
}

test_check_passes_against_committed_skill_md() {
  python3 "$GEN" --check >/dev/null
}

test_generated_block_matches_skill_md_byte_for_byte() {
  local expected actual
  expected=$(python3 "$GEN")
  actual=$(awk '/GENERATED:dispatch-table START/,/GENERATED:dispatch-table END/' "$SKILL")
  [ "$expected" = "$actual" ]
}

test_check_fails_when_json_changes_without_regeneration() {
  _mksandbox
  python3 - "$_sandbox/dispatch-table.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
data["steps"].append({
    "step_id": "STEP_TEST_ONLY", "table_label": "`STEP_TEST_ONLY`",
    "table_action": "Throwaway row", "action": "agent",
})
json.dump(data, open(p, "w"), indent=2)
PY
  # Must fail with exit 1 (drift), not 2 (structural).
  local rc=0
  _gen --check >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

test_write_propagates_a_new_step_into_skill_md() {
  # Sandbox already carries the throwaway step from the previous test's setup;
  # rebuild it here so the test stands alone.
  _mksandbox
  python3 - "$_sandbox/dispatch-table.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
data["steps"].append({
    "step_id": "STEP_TEST_ONLY", "table_label": "`STEP_TEST_ONLY`",
    "table_action": "Throwaway row", "action": "agent",
})
json.dump(data, open(p, "w"), indent=2)
PY
  _gen --write >/dev/null
  grep -q '^| `STEP_TEST_ONLY` | Throwaway row |$' "$_sandbox/SKILL.md" || return 1
  # And the gate is green again once regenerated.
  _gen --check >/dev/null || return 1
  # A write that actually rewrites the file must still leave every byte outside
  # the markers alone. test_write_touches_nothing_outside_the_markers cannot
  # cover this: with no drift, --write short-circuits and never writes at all.
  _head_of() { awk '/GENERATED:dispatch-table START/{exit} {print}' "$1"; }
  _tail_of() { awk 'f{print} /GENERATED:dispatch-table END/{f=1}' "$1"; }
  [ "$(_head_of "$SKILL")" = "$(_head_of "$_sandbox/SKILL.md")" ] || return 1
  [ "$(_tail_of "$SKILL")" = "$(_tail_of "$_sandbox/SKILL.md")" ] || return 1
}

test_write_touches_nothing_outside_the_markers() {
  _mksandbox
  _gen --write >/dev/null
  diff -q "$SKILL" "$_sandbox/SKILL.md"
}

test_missing_markers_is_a_structural_error_not_drift() {
  _mksandbox
  grep -v 'GENERATED:dispatch-table' "$SKILL" >"$_sandbox/SKILL.md"
  local rc=0
  _gen --check >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_malformed_json_is_a_structural_error() {
  _mksandbox
  echo '{ not json' >"$_sandbox/dispatch-table.json"
  local rc=0
  _gen --check >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_missing_required_field_is_rejected() {
  _mksandbox
  python3 - "$_sandbox/dispatch-table.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
del data["steps"][0]["table_action"]
json.dump(data, open(p, "w"), indent=2)
PY
  local rc=0
  _gen --check >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_render_is_deterministic() {
  local a b
  a=$(python3 "$GEN")
  b=$(python3 "$GEN")
  [ "$a" = "$b" ]
}

test_check_and_write_are_mutually_exclusive() {
  _mksandbox
  local rc=0
  _gen --check --write >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

# #406: reapprove gate must run AFTER pr-iterate (pr-iterate is what moves
# Review->Ready and re-adds approved). Assertions are positional so a
# WARN-routing change (#407) can still edit the surrounding text.
test_pr_loop_body_runs_pr_iterate_before_reapprove() {
  python3 - "$TABLE" <<'PYEOF'
import json, sys
t = json.load(open(sys.argv[1]))
step = next(s for s in t["steps"] if s["step_id"] == "STEP_4_6")
body = step["loop"]["body"]
assert body.index("pr-iterate") < body.index("--mode reapprove"), body
PYEOF
}

test_skill_warn_routing_runs_pr_iterate_before_reapprove() {
  local line
  line=$(grep -F 'VERDICT=WARN) AND ITERATION < 3' "$SKILL")
  [ -n "$line" ]
  python3 - "$line" <<'PYEOF'
import sys
l = sys.argv[1]
assert l.index("pr-iterate") < l.index("--mode reapprove"), l
PYEOF
}

# ── prompt_manifests schema ──────────────────────────────────────────────────
# hooks/skill-fingerprint.sh fails open to `unresolved` on a bad label, which is
# only visible on a host. This check catches the same mistakes in the source
# tree: an unknown label prefix, a plugin:/lib: entry that does not exist, and a
# reference entry (skill-progressive-disclosure) that is not exactly
# plugin:skills/<name>/references/<f>.md or names a file that is not there.
_check_manifests() { # $1=table $2=plugin root
  python3 - "$1" "$2" <<'PY'
import json, os, re, sys
table, root = sys.argv[1], sys.argv[2]
data = json.load(open(table))
ref_re = re.compile(r"^skills/[a-z0-9-]+/references/[A-Za-z0-9._-]+\.md$")
errors = []
for key, val in (data.get("prompt_manifests") or {}).items():
    files = val.get("files") if isinstance(val, dict) else None
    if not isinstance(files, list) or not all(isinstance(f, str) for f in files):
        errors.append(f"{key}: files must be a list of strings")
        continue
    for label in files:
        prefix, sep, rest = label.partition(":")
        if not sep or prefix not in ("plugin", "lib", "home"):
            errors.append(f"{key}: unknown label prefix: {label}")
            continue
        if "references/" in rest:
            if prefix != "plugin" or not ref_re.match(rest):
                errors.append(f"{key}: reference must be plugin:skills/<name>/references/<f>.md: {label}")
            elif not os.path.isfile(os.path.join(root, rest)):
                errors.append(f"{key}: reference file missing: {label}")
            continue
        if prefix == "plugin" and not os.path.isfile(os.path.join(root, rest)):
            errors.append(f"{key}: missing file: {label}")
        if prefix == "lib" and not os.path.isfile(os.path.join(root, "lib", rest)):
            errors.append(f"{key}: missing file: {label}")
for e in errors:
    print(e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
}

# A throwaway plugin root holding one skill with one reference file.
_mkmanifest_root() {
  _sandbox=$(mktemp -d "${TMPDIR:-/tmp}/test-dispatch-table.XXXXXX")
  mkdir -p "$_sandbox/skills/alpha/references" "$_sandbox/lib"
  echo body >"$_sandbox/skills/alpha/SKILL.md"
  echo ref >"$_sandbox/skills/alpha/references/deep.md"
}
_manifest_table() { # $@=labels for manifest alpha
  jq -n '{prompt_manifests: {alpha: {files: $ARGS.positional}}}' --args "$@" >"$_sandbox/t.json"
}

test_committed_prompt_manifests_resolve() {
  _check_manifests "$TABLE" "$REPO_ROOT/ticket-auto-pipeline"
}

test_manifest_accepts_existing_reference() {
  _mkmanifest_root
  _manifest_table plugin:skills/alpha/SKILL.md plugin:skills/alpha/references/deep.md
  _check_manifests "$_sandbox/t.json" "$_sandbox"
}

test_manifest_rejects_missing_reference() {
  _mkmanifest_root
  _manifest_table plugin:skills/alpha/SKILL.md plugin:skills/alpha/references/gone.md
  ! _check_manifests "$_sandbox/t.json" "$_sandbox" 2>/dev/null
}

test_manifest_rejects_nested_or_misrooted_reference() {
  _mkmanifest_root
  mkdir -p "$_sandbox/skills/alpha/references/sub"
  echo ref >"$_sandbox/skills/alpha/references/sub/x.md"
  _manifest_table plugin:skills/alpha/references/sub/x.md
  ! _check_manifests "$_sandbox/t.json" "$_sandbox" 2>/dev/null || return 1
  _manifest_table lib:skills/alpha/references/deep.md
  ! _check_manifests "$_sandbox/t.json" "$_sandbox" 2>/dev/null
}

test_manifest_rejects_unknown_prefix() {
  _mkmanifest_root
  _manifest_table plugn:skills/alpha/references/deep.md
  ! _check_manifests "$_sandbox/t.json" "$_sandbox" 2>/dev/null
}

# ── runner ────────────────────────────────────────────────────────────────────
FILTER="${1:-}"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  if [ -z "$FILTER" ] || [[ $t == *"$FILTER"* ]]; then
    _run "$t" "$t"
  fi
done

echo
echo "=== test-dispatch-table.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
