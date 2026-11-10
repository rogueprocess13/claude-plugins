#!/usr/bin/env bash
# test-verify-readiness.sh — lib/verify-readiness.sh, the one readiness scorer
# shared by gate-check.sh Check 2.6 (the authority that holds) and
# ticket-appraise-exec Step 3.8 (advisory only, never stops).
#
# Part 1 — the gate verdict matrix. Each case builds a ticket workspace and runs
# gate-check.sh's _gate_entry against a lib dir. fixtures/verify-readiness/
# old-verdicts.tsv was produced by running this same harness against main @
# 8f510c9 (gate-check.sh with verify_mode_gate_class, before the shared scorer
# and the unified mode classifier). A case's verdict must match its old one
# unless the case is listed in VR_CHANGED, which names the new verdict and the
# reason it legitimately moved.
#
# Part 2 — the advisory CLI used by appraise-exec Step 3.8.
#
# Usage: bash test-verify-readiness.sh
# VR_GEN_LIB=<lib dir> VR_GEN_OUT=<dir> bash test-verify-readiness.sh writes
# every case's output for that lib dir into <dir> and exits (fixture
# generation; never used by CI).
# -u (nounset) intentionally omitted (repo convention, see gate-check.sh).
set -eo pipefail

VR_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VR_LIB_DIR="$(cd "$VR_TEST_DIR/.." && pwd)"
VR_FX="$VR_TEST_DIR/fixtures/verify-readiness"
VR_TID="CRE-47"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION TICKETS_ROOT CLAUDE_PLUGIN_ROOT

# ── Case vocabulary ────────────────────────────────────────────────────────────
# <artifact>__<context>__<notes>
#   artifact: what the plan artifact (simple-fix.md, or an openspec change dir)
#             says — this is what the probes scan.
#   context:  ui = context.md repro steps click through a page (the default
#             test-gate-check scaffold); plain = no UI words at all.
#   notes:    crit = critique PASS 75, no Verification Plan (artifact fallback);
#             navgap = critique flags "No navigation path";
#             vplan = critique + a verifiable Verification Plan table;
#             nocrit = no critique and no plan (Check 2.6 not enforced).
VR_ARTIFACTS="browser_full browser_partial bare build build_cb live_eureka infra_dash zipkin_user api_full api_bare three_prereq na_bold na_plain dir_full dir_empty"
VR_CASES=""
for _a in $VR_ARTIFACTS; do
  for _c in ui plain; do
    for _n in crit navgap; do VR_CASES="$VR_CASES ${_a}__${_c}__${_n}"; done
  done
done
VR_CASES="$VR_CASES bare__ui__vplan build_cb__plain__vplan api_bare__plain__vplan bare__ui__nocrit dir_empty__plain__nocrit"
unset _a _c _n

# Cases whose gate verdict moved on purpose (decisions 1+3). Every other case
# must keep its old verdict. Format: case|new verdict|reason
VR_CHANGED="
api_full__ui__crit|hold:verification-prerequisites-missing|context.md clicks through a page, so verify runs it in a browser; the plan has no test user or nav path
api_full__ui__navgap|hold:verification-prerequisites-missing|same as api_full__ui__crit
build__ui__crit|hold:verification-prerequisites-missing|context.md UI words make verify run a browser (it reads context.md); the plan has no test user or nav path
build__ui__navgap|hold:verification-prerequisites-missing|same as build__ui__crit
build_cb__plain__crit|hold:verification-prerequisites-missing|verify reads 'circuit breaker' as live-backend (a runtime check), so the gate requires expected behaviour + env setup, not a build command
build_cb__plain__navgap|hold:verification-prerequisites-missing|same as build_cb__plain__crit
build_cb__ui__crit|hold:verification-prerequisites-missing|context.md UI words make it browser; no test user or nav path in the plan
build_cb__ui__navgap|hold:verification-prerequisites-missing|same as build_cb__ui__crit
dir_full__plain__crit|hold:complex-ticket|the openspec change dir is now scanned (design.md, tasks.md, specs) instead of grepped as a file, so Check 2.6 passes and the complex-ticket hold applies
dir_full__plain__navgap|hold:critique-cross-validation-failed|change dir scanned (as above), so Check 2.6 passes; the critique nav gap is still unresolved by a plan table
dir_full__ui__crit|hold:complex-ticket|same as dir_full__plain__crit
dir_full__ui__navgap|hold:critique-cross-validation-failed|same as dir_full__plain__navgap
infra_dash__ui__navgap|hold:critique-cross-validation-failed|context.md UI words make it browser (infra-only is gone); the critique nav gap is unresolved by the plan
live_eureka__ui__crit|hold:verification-prerequisites-missing|context.md UI words make it browser; the plan has no test user or nav path
live_eureka__ui__navgap|hold:verification-prerequisites-missing|same as live_eureka__ui__crit
na_bold__ui__crit|hold:verification-prerequisites-missing|context.md UI words make it browser (a browser signal beats Test User: N/A in verify too); no nav path
na_bold__ui__navgap|hold:verification-prerequisites-missing|same as na_bold__ui__crit
na_plain__ui__crit|hold:verification-prerequisites-missing|same as na_bold__ui__crit
na_plain__ui__navgap|hold:verification-prerequisites-missing|same as na_bold__ui__crit
zipkin_user__plain__navgap|hold:critique-cross-validation-failed|zipkin/actuator are not live-backend words in verify's vocabulary, so a ticket with a test user stays browser (infra-only is gone) and the critique nav gap applies
zipkin_user__ui__navgap|hold:critique-cross-validation-failed|same as zipkin_user__plain__navgap
"

_vr_write_artifact() { # kind path
  local kind="$1" p="$2"
  case "$kind" in
  browser_full)
    printf '# Fix\n\n**User:** test@example.com\n\n## How to implement\n1. Navigate to /handover/\n2. Click Send button\n\n## Expected Behavior\n- Handover appears in list\n\n## Setup\n- Seed data: 3 handovers\n' >"$p"
    ;;
  browser_partial)
    printf '# Fix\n\n**User:** test@example.com\n\n## How to implement\n1. Navigate to /handover/\n2. Click Send button\n' >"$p"
    ;;
  bare) printf '# Fix\n\n## How to implement\nChange line 42 of foo.js.\n' >"$p" ;;
  build) printf '# Fix\n\n## Summary\nBump the parent POM dependency versions.\n\n## How to implement\n1. Run `mvn clean install`\n2. Confirm BUILD SUCCESS in CI logs\n' >"$p" ;;
  build_cb) printf '# Fix\n\n## Summary\nMigrate circuit breaker library from Hystrix to Resilience4j.\n\n## How to implement\n1. Run `mvn clean install`\n2. Confirm BUILD SUCCESS in CI logs\n' >"$p" ;;
  live_eureka) printf '# Fix\n\nThe service must register with Eureka on startup.\n\n## Expected Behavior\n- Eureka lists the service as UP\n\n## Setup\n- Start the database before testing\n' >"$p" ;;
  infra_dash)
    printf '# Fix\n\n## Summary\nPhase A smoke test across 5 microservices.\n\n## How to implement\n1. Open http://localhost:9000 (gateway UI)\n2. Log in as gerhard.steyn at http://localhost:8761 (Eureka dashboard)\n3. Confirm all services registered\n\n## Expected Behavior\n- All 5 services show as UP in Eureka\n\n## Setup\n- Seed data: test users pre-provisioned\n' >"$p"
    ;;
  zipkin_user) printf '# Fix\n\nLog in as ops.user and check the Zipkin traces and the actuator health page.\n\n## Expected Behavior\n- Traces span all services\n\n## Setup\n- Seed data: none beyond the default fixture\n' >"$p" ;;
  api_full) printf '# Fix\n\nPOST /api/x returns 201.\n\n## Expected Behavior\n- The response carries the new id\n\n## Setup\n- Test data: one tenant\n' >"$p" ;;
  api_bare) printf '# Fix\n\nPOST /api/x returns 201.\n' >"$p" ;;
  three_prereq) printf '# Fix\n\n**User:** test@example.com\n\n## How to implement\nChange line 42 of foo.js.\n\n## Expected Behavior\n- Result appears after save\n\n## Setup\n- Seed data: test fixture needed\n' >"$p" ;;
  na_bold) printf '# Fix\n\n**Test User:** N/A\nEnvironment: full stack running locally\n\n## Expected Behavior\n- Health endpoint reports UP\n\n## Setup\n- Start the database before testing\n' >"$p" ;;
  na_plain) printf '# Fix\n\n**Test User**: N/A\nEnvironment: full stack running locally\n\n## Expected Behavior\n- Health endpoint reports UP\n\n## Setup\n- Start the database before testing\n' >"$p" ;;
  dir_full)
    mkdir -p "$p/specs/x"
    printf '# Design\n\n**User:** test@example.com\n\nNavigate to /admin/ and click Save.\n' >"$p/design.md"
    printf '## Tasks\n- [ ] Seed data: 2 admin rows\n' >"$p/tasks.md"
    printf '### Requirement: x\n\n## Acceptance Criteria\n- saving works\n' >"$p/specs/x/spec.md"
    ;;
  dir_empty) mkdir -p "$p" ;;
  esac
}

_vr_write_context() { # kind td
  if [ "$1" = "ui" ]; then
    printf '# Test Ticket\n\n**Labels:** feature\n\n## Description\n1. Test acceptance criterion 1\n2. Test acceptance criterion 2\n\n## Steps to Reproduce\n1. Go to /handover/\n2. Click Send button\n3. See error message\n' >"$2/context.md"
  else
    printf '# Test Ticket\n\n**Labels:** feature\n\n## Description\n1. Test acceptance criterion 1\n2. Test acceptance criterion 2\n' >"$2/context.md"
  fi
}

_vr_write_notes() { # kind td complexity
  local n="$2/notes.md"
  printf '## Complexity\n**Score:** %s\n' "$3" >"$n"
  case "$1" in
  crit) printf '\n## Readiness Critique\n**Score:** 75\n**Status:** PASS\n' >>"$n" ;;
  navgap) printf '\n## Readiness Critique\n**Date:** 2026-06-25\n**Status:** WARNINGS\n**Score:** 65\n**WARNING count:** 1\n**BLOCKER count:** 0\n\n### Findings\n- [WARNING] No navigation path specified. Verifier will need to discover the feature location from code.\n' >>"$n" ;;
  vplan)
    printf '\n## Readiness Critique\n**Score:** 75\n**Status:** PASS\n' >>"$n"
    printf '\n## Verification Plan\n**Date:** 2026-06-24\n\n### Per-Criterion Verification\n\n| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |\n|---|---|---|---|---|---|---|\n| 1 | Thing works | global | /handover/ | none | It works | ✓ |\n' >>"$n"
    ;;
  nocrit) : ;;
  esac
}

# _vr_gate_out <lib dir> <case> — prints the case's gate result:
#   VERDICT=pass | hold:<gate-held reason> | stop:<gate-stop code> | rc=<n>
#   MODE=<Check 2.6 ticket mode>   (empty when Check 2.6 did not run)
#   the GATE|vplan-source and GATE|gate|fail lines, timestamps masked.
_vr_gate_out() (
  local lib="$1" case="$2" art ctx notes ws td complexity atype apath rc=0
  art="${case%%__*}"
  ctx="${case#*__}"
  ctx="${ctx%%__*}"
  notes="${case##*__}"
  ws=$(mktemp -d)
  ws=$(cd "$ws" && pwd -P)
  td="$ws/$VR_TID--test"
  mkdir -p "$td" "$ws/home"
  export HOME="$ws/home" CLAUDE_SKILLS_LIB="$lib" TICKET_TMP_DIR="$ws/scratch" GATE_CHECK_TEST_MODE=1
  mkdir -m 700 "$ws/scratch"
  LOG_FILE="$ws/$VR_TID-pipeline.log"
  HB_LOG_FILE="$ws/$VR_TID-heartbeat.log"
  TICKET_ID="$VR_TID"
  case "$art" in
  dir_*)
    complexity=complex atype=openspec apath="$ws/openspec/changes/cre-47-fix"
    ;;
  *) complexity=simple atype=simple-fix apath="$ws/simple-fix.md" ;;
  esac
  {
    echo "2026-06-05T10:00:00Z|META|schema|info|1"
    echo "2026-06-05T10:00:00Z|META|title|info|ID:$VR_TID -- Test Ticket"
    echo "2026-06-05T10:00:00Z|META|autonomy|info|auto"
    echo "2026-06-05T10:00:00Z|APPRAISE|appraise|done|complexity=$complexity"
    echo "2026-06-05T10:00:00Z|META|artifact|info|plan:$apath"
    echo "2026-06-05T10:00:00Z|EXEC|create-artifact|done|$atype"
  } >"$LOG_FILE"
  mkdir -p "$(dirname "$apath")"
  _vr_write_artifact "$art" "$apath"
  _vr_write_context "$ctx" "$td"
  _vr_write_notes "$notes" "$td" "$complexity"

  # shellcheck source=/dev/null
  source "$lib/gate-check.sh"
  get_issue() { echo '{"id":"CRE-47","identifier":"CRE-47","title":"Test","labels":{"nodes":[]}}'; }
  _VR_COMPLEXITY="$complexity" _VR_TD="$td"
  get_complexity() { echo "$_VR_COMPLEXITY"; }
  printf '#!/usr/bin/env bash\nexit 0\n' >"$ws/mock-flow.sh"
  chmod +x "$ws/mock-flow.sh"
  _VR_WS="$ws"
  _resolve_flow_sh() { echo "$_VR_WS/mock-flow.sh"; }
  FLOW_SH="$ws/mock-flow.sh"
  resolve_ticket_dir() { echo "$_VR_TD"; }
  emit_event() { echo "$2|$3" >>"$_VR_WS/emit.log"; }
  ticket_manifest_exists() { return 1; }
  ticket_is_planned() { return 1; }

  set +e
  _gate_entry >/dev/null 2>&1
  rc=$?
  set -e
  local verdict
  if [ "$rc" = 0 ]; then
    verdict=pass
  elif [ "$rc" = 1 ] && [ -f "$ws/emit.log" ] && grep -q '^gate-held|' "$ws/emit.log"; then
    verdict="hold:$(grep '^gate-held|' "$ws/emit.log" | tail -1 | cut -d'|' -f2- | jq -r '.reason')"
  elif [ "$rc" = 2 ]; then
    verdict="stop:$(grep '|META|gate-stop|fail|' "$LOG_FILE" | tail -1 | cut -d'|' -f5 | cut -d' ' -f1)"
  else
    verdict="rc=$rc"
  fi
  echo "VERDICT=$verdict"
  echo "MODE=${GATE_CHECK_TEST_TICKET_MODE:-}"
  grep -E '\|GATE\|(vplan-source|gate)\|(done|fail)\|' "$LOG_FILE" | cut -d'|' -f2- | sed "s|$ws|\$WS|g" || true
  rm -rf "$ws"
)

if [ -n "${VR_GEN_LIB:-}" ]; then
  mkdir -p "$VR_GEN_OUT"
  for c in $VR_CASES; do
    _vr_gate_out "$VR_GEN_LIB" "$c" >"$VR_GEN_OUT/$c.out"
  done
  exit 0
fi

PASS=0 FAIL=0
_ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
_ko() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

echo "=== Part 1: gate verdict matrix (old verdicts vs the shared scorer) ==="
for c in $VR_CASES; do
  old=$(awk -F'\t' -v c="$c" '$1 == c { print $2 }' "$VR_FX/old-verdicts.tsv")
  if [ -z "$old" ]; then
    _ko "$c: no old verdict in old-verdicts.tsv"
    continue
  fi
  got=$(_vr_gate_out "$VR_LIB_DIR" "$c" | sed -n 's/^VERDICT=//p')
  changed=$(printf '%s\n' "$VR_CHANGED" | awk -F'|' -v c="$c" '$1 == c { print $2 }')
  if [ -n "$changed" ]; then
    [ "$got" = "$changed" ] && _ok "$c: $old -> $got (VR_CHANGED)" || _ko "$c: VR_CHANGED expects $changed, got $got (old $old)"
  else
    [ "$got" = "$old" ] && _ok "$c: $got" || _ko "$c: old verdict $old, got $got (not in VR_CHANGED)"
  fi
done
# Every VR_CHANGED entry must name a real case.
while IFS='|' read -r c _ _; do
  [ -z "$c" ] && continue
  case " $VR_CASES " in *" $c "*) ;; *) _ko "VR_CHANGED names unknown case $c" ;; esac
done <<<"$VR_CHANGED"

echo "=== Part 1b: the held line keeps its wording (parsed outside the gate) ==="
out=$(_vr_gate_out "$VR_LIB_DIR" bare__plain__crit)
grep -q '^GATE|gate|fail|held: plan missing 2/2 verification prerequisites (mode=api-only test_user=0 nav=0 expected=0 env=0)$' <<<"$out" &&
  _ok "api-only held line" || _ko "api-only held line: $out"
out=$(_vr_gate_out "$VR_LIB_DIR" browser_partial__plain__crit)
grep -q '^GATE|gate|fail|held: plan missing 2/4 verification prerequisites (mode=browser test_user=1 nav=1 expected=0 env=0)$' <<<"$out" &&
  _ok "browser held line" || _ko "browser held line: $out"

echo "=== Part 2: verify_readiness_artifact_text ==="
ws=$(mktemp -d)
mkdir -p "$ws/chg/specs/a" "$ws/chg/sub"
printf 'B\n' >"$ws/chg/tasks.md"
printf 'A\n' >"$ws/chg/design.md"
printf 'S\n' >"$ws/chg/specs/a/spec.md"
printf 'X\n' >"$ws/chg/sub/notes.txt"
# shellcheck source=/dev/null
source "$VR_LIB_DIR/verify-readiness.sh"
got=$(verify_readiness_artifact_text "$ws/chg" | grep -v '^$' | tr '\n' ' ')
[ "$got" = "A S B " ] && _ok "change dir: every *.md, sorted by path" || _ko "change dir text: [$got]"
printf 'F\n' >"$ws/f.md"
got=$(verify_readiness_artifact_text "$ws/f.md")
[ "$got" = "F" ] && _ok "plain file" || _ko "plain file: [$got]"
got=$(verify_readiness_artifact_text "$ws/none.md")
[ -z "$got" ] && _ok "missing artifact: empty" || _ko "missing artifact: [$got]"
rm -rf "$ws"

echo "=== Part 3: advisory CLI (appraise-exec Step 3.8) ==="
VR="$VR_LIB_DIR/verify-readiness.sh"
ws=$(mktemp -d)
ws=$(cd "$ws" && pwd -P)
td="$ws/$VR_TID--test"
mkdir -p "$td" "$ws/home"
mkdir -m 700 "$ws/scratch"
export HOME="$ws/home" TICKET_TMP_DIR="$ws/scratch" CLAUDE_SKILLS_LIB="$VR_LIB_DIR"
export LOG_FILE="$ws/$VR_TID-pipeline.log"
: >"$LOG_FILE"
printf '# Fix\n\n## How to implement\nChange line 42 of foo.js.\n' >"$ws/simple-fix.md"
printf '# Test Ticket\n\n## Description\nRefactor.\n' >"$td/context.md"
printf '## Complexity\n**Score:** simple\n\n## Readiness Critique\n**Score:** 75\n' >"$td/notes.md"

rc=0
out=$(bash "$VR" "$VR_TID" --ticket-dir "$td" --artifact "$ws/simple-fix.md") || rc=$?
[ "$rc" = 0 ] && _ok "INCOMPLETE still exits 0 (advisory)" || _ko "advisory rc=$rc"
grep -qx 'VR_STATUS=INCOMPLETE' <<<"$out" && grep -qx 'VR_MODE=api-only' <<<"$out" && grep -qx 'VR_MISSING=2' <<<"$out" &&
  grep -qx 'VR_MISSING_LIST=expected behavior, environment prerequisites' <<<"$out" &&
  _ok "prints status, mode, missing" || _ko "CLI output: $out"
grep -q '|EXEC|verify-readiness|start|' "$LOG_FILE" && grep -q '|EXEC|verify-readiness|done|INCOMPLETE — advisory, mode=api-only missing 2/2: expected behavior, environment prerequisites$' "$LOG_FILE" &&
  _ok "start + advisory done lines" || _ko "log: $(cat "$LOG_FILE")"
! grep -q 'gate-stop\|VERIFY_READINESS_INCOMPLETE' "$LOG_FILE" && _ok "never gate-stops" || _ko "advisory call wrote a gate-stop"
[ "$(grep -c '^## Verification Readiness$' "$td/notes.md")" = 1 ] && grep -q '^\*\*Status:\*\* INCOMPLETE$' "$td/notes.md" &&
  grep -q '^## Readiness Critique$' "$td/notes.md" && _ok "notes.md section written, other sections kept" || _ko "notes: $(cat "$td/notes.md")"

printf '\n## Expected Behavior\n- It works\n\n## Setup\n- Seed data: one row\n' >>"$ws/simple-fix.md"
out=$(bash "$VR" "$VR_TID" --ticket-dir "$td" --artifact "$ws/simple-fix.md")
grep -qx 'VR_STATUS=CLEAR' <<<"$out" && [ "$(grep -c '^## Verification Readiness$' "$td/notes.md")" = 1 ] &&
  grep -q '^\*\*Status:\*\* CLEAR$' "$td/notes.md" && ! grep -q 'INCOMPLETE' "$td/notes.md" &&
  _ok "rerun replaces the section in place" || _ko "rerun: $out / $(cat "$td/notes.md")"
grep -qF '| Expected behavior | found | plan: ## Expected Behavior |' "$td/notes.md" &&
  grep -qF '| Environment prerequisites | found | plan: - Seed data: one row |' "$td/notes.md" &&
  _ok "Source cell carries the first matching plan line (verify Step 1.7 reads it)" || _ko "source cells: $(cat "$td/notes.md")"

cp "$td/notes.md" "$ws/notes.before"
: >"$LOG_FILE"
out=$(bash "$VR" "$VR_TID" --ticket-dir "$td" --artifact "$ws/simple-fix.md" --no-write --no-log)
cmp -s "$td/notes.md" "$ws/notes.before" && [ ! -s "$LOG_FILE" ] && grep -qx 'VR_STATUS=CLEAR' <<<"$out" &&
  _ok "--no-write --no-log: prints only" || _ko "--no-write --no-log"

printf '\n## Verification Plan\n**Date:** 2026-06-24\n\n### Per-Criterion Verification\n\n| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |\n|---|---|---|---|---|---|---|\n| 1 | Works | global | /handover/ | none | It works | ✓ |\n' >>"$td/notes.md"
printf 'Click the Save button.\n' >"$ws/bare.md"
out=$(bash "$VR" "$VR_TID" --ticket-dir "$td" --artifact "$ws/bare.md" --no-log)
grep -qx 'VR_STATUS=CLEAR' <<<"$out" && grep -qx 'VR_MODE=browser' <<<"$out" && grep -q '| Test user | found | Verification Plan (notes.md) |' "$td/notes.md" &&
  _ok "a verifiable plan row marks every prerequisite found" || _ko "vplan: $out"

for args in "" "$VR_TID" "$VR_TID --ticket-dir $td" "$VR_TID --artifact x" "$VR_TID --ticket-dir" "$VR_TID --bogus"; do
  rc=0
  # shellcheck disable=SC2086
  bash "$VR" $args >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && _ok "usage: [$args] -> 2" || _ko "usage: [$args] rc=$rc"
done
rm -rf "$ws"

echo ""
echo "verify-readiness: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
