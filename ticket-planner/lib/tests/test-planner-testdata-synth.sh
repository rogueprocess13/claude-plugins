#!/usr/bin/env bash
# test-planner-testdata-synth.sh — planner-test-data-derivation tasks 4.1-4.7, 5.1-5.2, 6.6:
# need collection (generate rows + TESTDATA_CONFIRM generate answers; exists,
# external, seeded-by, pending cited artifacts and synth-marked specs skipped),
# grouping (shared key → pack, single consumer → <slug>-test-data), slug
# truncation, the collision check, and the TD spec template (guard, composer,
# ticket-auto's chore body check, Seed channel from the inventory).
#
# Run: bash ticket-planner/lib/tests/test-planner-testdata-synth.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
TAP_LIB="${SCRIPT_DIR}/../../../ticket-auto-pipeline/lib"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-ticket-body.sh"
source "${LIB_DIR}/planner-testdata-synth.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"

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
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_contains() {
  case "$2" in
  *"$3"*) pass "$1" ;;
  *) fail "$1" "missing '$3' in: $2" ;;
  esac
}
assert_not_contains() {
  case "$2" in
  *"$3"*) fail "$1" "unexpected '$3' in: $2" ;;
  *) pass "$1" ;;
  esac
}

INIT="INIT-42"
ART="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}/artifacts"
SPECS="${ART}/specs"

# A consumer spec. Usage: mkspec <slug> <serves-json> <ac-line> <notes-rows...>
# Each notes row: "<criterion>|<test data>|<source>".
mkspec() {
  local slug="$1" serves="$2" ac="$3" row crit td src
  shift 3
  {
    printf '# %s\n\n## Title\n\n%s\n\n## Description\n\n## Summary\n\nDoes %s.\n\n' "$slug" "$slug" "$slug"
    printf '## Acceptance Criteria\n\n- [ ] %s\n\n' "$ac"
    printf '## Labels\n\nplanned, %s, feature\n\n' "$INIT"
    printf '## Signals\n\n```json\n{"Kind": "business", "Serves": %s, "Enables": []}\n```\n\n' "$serves"
    printf '## Verification Notes\n\n| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |\n|---|---|---|---|---|---|---|\n'
    for row in "$@"; do
      IFS='|' read -r crit td src <<<"$row"
      printf '| %s | admin | %s | %s | Home | shown | yes |\n' "$crit" "$td" "$src"
    done
  } >"${SPECS}/${slug}.md"
}

setup() {
  rm -rf "${REPOS_ROOT}/.ticket-auto"
  mkdir -p "$SPECS"
  printf '2026-10-01T00:00:00Z|META|schema|start|1\n2026-10-01T00:00:00Z|META|contract|start|test-data-source-v1\n' \
    >"${ART}/../state.log"
  cat >"${ART}/discovery.md" <<'EOF'
# Discovery

## Test Data Inventory

| Entity | States/variants | Roles | Volume | Source | Load via | Privacy |
|---|---|---|---|---|---|---|
| `invoice` | paid, overdue | finance | 10 | none | sql | synthetic |
| `client` | active, archived | admin | 5 | none | api | masked |

## Cited Artifacts

- `legacy import file` — NOT FOUND (searched: artifacts/)
EOF
  printf '# Consensus\n\n## Open Questions\n\n- CITED_ARTIFACT: `legacy import file` — cited but not retrievable. Answer: PENDING\n' >"${ART}/consensus.md"
}

# ── 4.2 need collection ─────────────────────────────────────────────────────

echo "--- planner_testdata_synth_needs ---"
setup
mkspec inv-0-list '["O1"]' "The list shows paid invoices" \
  'The list shows paid invoices|5 `invoice` records in state paid|generate'
mkspec inv-0-export '["O2"]' "Export includes paid invoices" \
  'Export includes paid invoices|3 paid invoices|generate'
mkspec inv-0-audit '["O3"]' "Audit shows the event" \
  'Audit shows the event|an `audit-event` record|generate'
mkspec inv-0-clients '["O1"]' "Archived clients are hidden" \
  'Archived clients are hidden|an archived `client`|exists:staging seed' \
  'Archived clients are hidden|the regional price list|external:pricing team' \
  'Archived clients are hidden|rows from the `legacy import file`|generate'
needs=$(planner_testdata_synth_needs "$INIT")
assert_eq "three generate needs, one per row (pending cited artifact skipped)" "$(grep -c . <<<"$needs")" 3
assert_contains "list need keyed by backticked inventory entity" "$needs" $'inv-0-list\037The list shows paid invoices\0375 `invoice` records in state paid\037invoice\037invoice\037sql'
assert_contains "export need keyed by inventory word match" "$needs" $'inv-0-export\037Export includes paid invoices\0373 paid invoices\037invoice\037invoice\037sql'
assert_contains "non-inventory backticked entity, no load via" "$needs" $'inv-0-audit\037Audit shows the event\037an `audit-event` record\037audit-event\037audit-event\037'
assert_not_contains "exists: row not synthesized" "$needs" "archived"
assert_not_contains "external: row not synthesized" "$needs" "price list"
assert_not_contains "pending cited artifact not synthesized" "$needs" "legacy import"

echo "--- cited artifact answered generate → synthesized ---"
sed -i 's/Answer: PENDING/Answer: generate/' "${ART}/consensus.md"
needs=$(planner_testdata_synth_needs "$INIT")
assert_contains "answered cited artifact need collected" "$needs" "legacy import file"
assert_contains "backticked artifact name is the key" "$needs" $'\037rows from the `legacy import file`\037legacy import file\037'
rec=$(_planner_tds_need_record s "c" "Two signed PDF contracts." "$(planner_testdata_inventory_entities "$INIT")")
assert_eq "no entity → normalized data text key" "$rec" $'s\037c\037Two signed PDF contracts.\037two signed pdf contract\037\037'
sed -i 's/Answer: generate/Answer: PENDING/' "${ART}/consensus.md"

echo "--- seeded-by / none rows and synth-marked specs skipped ---"
mkspec inv-0-seeded '["O1"]' "Seeded list" 'Seeded list|2 `invoice` records|seeded-by:inv-0-list'
mkspec inv-0-none '["O1"]' "The header renders" 'The header renders|none|—'
mkspec inv-0-list-test-data '[]' "the seed command exits 0 on two consecutive runs" \
  'the seed command exits 0 on two consecutive runs|9 `invoice` records|generate'
printf '\n%s\n' "$PLANNER_TESTDATA_SYNTH_MARKER" >>"${SPECS}/inv-0-list-test-data.md"
needs=$(planner_testdata_synth_needs "$INIT")
assert_not_contains "seeded-by row skipped" "$needs" "inv-0-seeded"
assert_not_contains "none row skipped" "$needs" "inv-0-none"
assert_not_contains "synth-marked spec is never a consumer" "$needs" "9 \`invoice\`"
rm -f "${SPECS}/inv-0-seeded.md" "${SPECS}/inv-0-none.md"

echo "--- TESTDATA_CONFIRM generate answer → need ---"
mkspec inv-0-report '["O4"]' "Given 2 archived \`client\` records, the report lists them" \
  "Given 2 archived \`client\` records, the report lists them|none|—"
ents=$(_planner_testdata_entity_names "$INIT")
trig=$(_planner_testdata_spec_trigger "${SPECS}/inv-0-report.md" "$ents")
hash=$(cut -d$'\037' -f4 <<<"$trig")
assert_eq "report spec has a strong trigger" "$(cut -d$'\037' -f1 <<<"$trig")" strong
planner_testdata_answer_set "${ART}/consensus.md" inv-0-report "$hash" "generate: 2 archived clients"
needs=$(planner_testdata_synth_needs "$INIT")
assert_contains "generate answer is a need on the trigger criterion" "$needs" \
  $'inv-0-report\037Given 2 archived `client` records, the report lists them\0372 archived clients\037client\037client\037api'

# ── 4.3 grouping ────────────────────────────────────────────────────────────

echo "--- prefix ---"
assert_eq "common -bounded prefix" "$(planner_testdata_synth_prefix "$INIT")" "inv-0"

echo "--- planner_testdata_synth_groups ---"
groups=$(planner_testdata_synth_groups "$INIT")
assert_eq "three TD specs" "$(grep -c . <<<"$groups")" 3
assert_contains "shared invoice key → pack serving both" "$groups" $'inv-0-test-data-pack\037pack\037invoice\037inv-0-export,inv-0-list'
assert_contains "single consumer → <slug>-test-data" "$groups" $'inv-0-audit-test-data\037single\037audit-event\037inv-0-audit'
assert_contains "answer need → its own single" "$groups" $'inv-0-report-test-data\037single\037client\037inv-0-report'
assert_eq "groups are deterministic" "$(planner_testdata_synth_groups "$INIT")" "$groups"

echo "--- assign: global td numbering ---"
assigned=$(planner_testdata_synth_assign "$INIT")
assert_eq "four assigned needs" "$(grep -c . <<<"$assigned")" 4
assert_eq "numbering 1..4 in slug order" "$(cut -d$'\037' -f1,2 <<<"$assigned" | tr '\037\n' ': ')" \
  "inv-0-audit-test-data:1 inv-0-report-test-data:2 inv-0-test-data-pack:3 inv-0-test-data-pack:4 "

echo "--- prefix fallback ---"
mkspec other-thing '["O1"]' "x" 'x|none|—'
assert_eq "no common prefix → init-<id>" "$(planner_testdata_synth_prefix "$INIT")" "init-42"
rm -f "${SPECS}/other-thing.md"

echo "--- norm key ---"
assert_eq "norm key: case, punct, ws, trailing s" "$(planner_testdata_synth_norm_key '  Five  Paid, Receipts. ')" "five paid receipt"
assert_eq "norm key drops only one s" "$(planner_testdata_synth_norm_key 'glass')" "glas"

echo "--- slug truncation ---"
long="a-very-long-consumer-spec-slug-that-goes-well-past-the-sixty-character-cap"
s1=$(planner_testdata_synth_slug "$long" "-test-data")
s2=$(planner_testdata_synth_slug "$long" "-test-data")
assert_eq "truncation deterministic" "$s1" "$s2"
assert_eq "truncated to the cap" "$([ "${#s1}" -le 60 ] && echo ok)" ok
assert_contains "suffix kept" "$s1" "-test-data"
[[ "$s1" =~ -[0-9a-f]{6}-test-data$ ]] && pass "6-hex hash before suffix" || fail "6-hex hash before suffix" "$s1"
s3=$(planner_testdata_synth_slug "${long}-b" "-test-data")
[ "$s1" != "$s3" ] && pass "distinct long stems → distinct slugs" || fail "distinct long stems" "$s1 = $s3"
assert_eq "short slug untouched" "$(planner_testdata_synth_slug "Audit-Log" "-test-data")" "audit-log-test-data"

echo "--- collision ---"
printf '# inv-0-audit-test-data\n\nhand-written\n' >"${SPECS}/inv-0-audit-test-data.md"
err=$(planner_testdata_synth_groups "$INIT" 2>&1 >/dev/null)
rc=0
planner_testdata_synth_groups "$INIT" >/dev/null 2>&1 || rc=$?
assert_eq "unmarked file at a TD slug fails" "$rc" 1
assert_contains "failure names the file" "$err" "inv-0-audit-test-data.md"
assert_eq "synthesize fails too" "$(planner_testdata_synthesize "$INIT" >/dev/null 2>&1 && echo 0 || echo 1)" 1
printf '%s\n' "$PLANNER_TESTDATA_SYNTH_MARKER" >>"${SPECS}/inv-0-audit-test-data.md"
rc=0
planner_testdata_synth_groups "$INIT" >/dev/null 2>&1 || rc=$?
assert_eq "a marked file at the slug is ours — no collision" "$rc" 0
rm -f "${SPECS}/inv-0-audit-test-data.md"

echo "--- synthesize: plan output ---"
plan=$(planner_testdata_synthesize "$INIT")
assert_contains "lists the pack with its need count" "$plan" $'inv-0-test-data-pack\037pack\0372'
# The 4.4 section below renders from $assigned; synthesis' own writes are
# exercised further down (4.5-4.7) after a fresh setup.

# ── 4.4 template ────────────────────────────────────────────────────────────

echo "--- planner_testdata_synth_render ---"
out="${TMPDIR}/td"
mkdir -p "$out"
for td in inv-0-test-data-pack inv-0-audit-test-data inv-0-report-test-data; do
  kind=single
  [ "$td" = inv-0-test-data-pack ] && kind=pack
  if planner_testdata_synth_render "$td" "$INIT" "$kind" <<<"$assigned" >"${out}/${td}.md"; then
    pass "render ${td}"
  else
    fail "render ${td}" "rc != 0"
  fi
done
pack=$(cat "${out}/inv-0-test-data-pack.md")
assert_contains "marker" "$pack" "$PLANNER_TESTDATA_SYNTH_MARKER"
assert_contains "seed command" "$pack" "Seed command: make seed-inv-0-test-data-pack"
assert_contains "verify command" "$pack" "Verify command: make verify-seed-inv-0-test-data-pack"
assert_contains "seed channel from inventory Load via" "$pack" "Seed channel: sql"
assert_contains "make-only sentence" "$pack" 'must stay `make <target>`'
assert_contains "record key td-<init>-<n> + consumer criterion" "$pack" \
  '- `td-42-3` — 3 paid invoices — for `inv-0-export`: Export includes paid invoices'
assert_contains "second record" "$pack" '`td-42-4` — 5 `invoice` records in state paid — for `inv-0-list`'
assert_contains "AC phrase: two consecutive runs" "$pack" "the seed command exits 0 on two consecutive runs"
assert_contains "AC phrase: verify passes" "$pack" "the verify command passes"
assert_contains "AC: synthetic or masked" "$pack" "synthetic or masked"
assert_contains "AC: reset command" "$pack" "make reset-seed-inv-0-test-data-pack"
assert_contains "AC: README key map" "$pack" "A README maps every record key"
assert_contains "Labels line" "$pack" "planned, INIT-42, chore"
assert_contains "Enables section names consumer outcomes" "$pack" "**Enables:** O1, O2"
assert_eq "type is chore" "$(planner_ticketgen_spec_type "${out}/inv-0-test-data-pack.md")" chore
sig=$(planner_ticketgen_signals "${out}/inv-0-test-data-pack.md")
assert_eq "Signals Kind enabler" "$(jq -r .Kind <<<"$sig")" enabler
assert_eq "Signals Serves empty" "$(jq -c .Serves <<<"$sig")" "[]"
assert_eq "Signals Enables = consumer outcomes" "$(jq -c .Enables <<<"$sig")" '["O1","O2"]'
assert_eq "Signals Strategy maps to simple" "$(jq -r .Strategy <<<"$sig")" Conservative
assert_eq "Signals Priority High" "$(jq -r .Priority <<<"$sig")" High
conf=$(planner_confidence_derive "$sig")
assert_eq "derived confidence reaches the default pre-approve threshold" \
  "$(awk -v c="$conf" 'BEGIN { print (c >= 0.85) ? "yes" : "no" }')" yes
assert_not_contains "no FE layer in Scope" "$pack" "| FE"
for w in navigate click browser screenshot "go to" visit; do
  assert_not_contains "no browser word '${w}'" "$(tr '[:upper:]' '[:lower:]' <<<"$pack")" "$w"
done
assert_contains "single-consumer seed channel from client Load via" \
  "$(cat "${out}/inv-0-report-test-data.md")" "Seed channel: api"
assert_contains "no known Load via → default channel" \
  "$(cat "${out}/inv-0-audit-test-data.md")" "Seed channel: ${PLANNER_TESTDATA_SYNTH_DEFAULT_CHANNEL}"
assert_eq "render is deterministic" \
  "$(planner_testdata_synth_render inv-0-test-data-pack "$INIT" pack <<<"$assigned")" "$pack"

echo "--- guard, composer, Crosscheck notes reader, chore body check ---"
for td in inv-0-test-data-pack inv-0-audit-test-data inv-0-report-test-data; do
  f="${out}/${td}.md"
  if _planner_tb_guard "$f" 2>"${TMPDIR}/guard.err"; then pass "${td}: _planner_tb_guard"; else fail "${td}: _planner_tb_guard" "$(cat "${TMPDIR}/guard.err")"; fi
  assert_eq "${td}: no Verification Notes problems" "$(_planner_testdata_notes_problems "$f")" ""
  assert_eq "${td}: every notes row is none" \
    "$(_planner_testdata_spec_needs "$f" | awk -F'\037' '$2 != "none"' | wc -l | tr -d ' ')" 0
  ctx=$(planner_ticketgen_context_block "$INIT" "EPIC-1" "$f" 2>/dev/null)
  assert_contains "${td}: Planner Context Pre-approved true" "$ctx" "**Pre-approved:** true"
  body=$(planner_ticket_body_compose "$f" "$ctx" 2>"${TMPDIR}/compose.err")
  if [ -n "$body" ]; then pass "${td}: composes"; else fail "${td}: composes" "$(cat "${TMPDIR}/compose.err")"; fi
  assert_contains "${td}: body keeps Seed command" "$body" "Seed command: make seed-${td}"
  assert_contains "${td}: body keeps Test Data Provided" "$body" "## Test Data Provided"
  assert_not_contains "${td}: body drops Signals" "$body" "## Signals"
  # shellcheck disable=SC1091
  res=$(
    source "${TAP_LIB}/planned-ticket-body-check.sh" >/dev/null 2>&1
    check_planned_body "TD-1" chore "$body" "false" >/dev/null 2>&1
    echo "$?|${BODY_CHECK_MISSING}"
  )
  assert_eq "${td}: check_planned_body chore passes" "$res" "0|"
done

echo "--- 6.6: a TD body passes TicketGen's validator, dor-check (strict) and gate-check ---"
# A gate-check entry run in a fresh process, with the same mocks
# test-gate-check.sh installs (no network, no flow.sh). Usage:
#   _td_gate_run <body-file> <description-file> <strict:true|false> [seam:1|0]
# Prints `rc=<n> mode=<Check 2.6 classification>` then the GATE/gate-stop lines.
cat >"${TMPDIR}/td-gate.sh" <<'GATE_EOF'
TAP_LIB="$1" BODY="$2" DESC="$3" STRICT="$4"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export REPOS_ROOT="$W/repos" CLAUDE_SKILLS_LIB="$TAP_LIB" FLEET_PIPELINE_LOG_DIR="$W"
# Opt into gate-check.sh's test seam (GATE_CHECK_TEST_TICKET_MODE) unless arg 5 is 0.
if [ "${5:-1}" = 1 ]; then GATE_CHECK_TEST_MODE=1; fi
mkdir -p "$REPOS_ROOT" "$W/TD-1--seed"
source "$TAP_LIB/gate-check.sh"
source "$TAP_LIB/manifest-write.sh"
TICKET_ID=TD-1 LOG_FILE="$W/TD-1-pipeline.log" HB_LOG_FILE="$W/hb.log"
_desc=$(cat "$DESC")
get_issue() { jq -n --arg d "$_desc" '{id:"TD-1",identifier:"TD-1",title:"Seed",description:$d,labels:{nodes:[]}}'; }
get_complexity() { echo simple; }
printf '#!/bin/sh\nexit 0\n' >"$W/flow.sh"
chmod +x "$W/flow.sh"
_resolve_flow_sh() { echo "$W/flow.sh"; }
FLOW_SH="$W/flow.sh"
resolve_ticket_dir() { echo "$W/TD-1--seed"; }
emit_event() { :; }
{
  printf '# Seed\n\n**Labels:** chore\n\n## Description\n'
  awk '/^## /{on=($0=="## Acceptance Criteria");next} on && /^- \[ \] /{sub(/^- \[ \] /,""); n++; print n ". " $0}' "$BODY"
} >"$W/TD-1--seed/context.md"
printf '## Complexity\n**Score:** simple\n' >"$W/TD-1--seed/notes.md"
cp "$BODY" "$W/simple-fix.md"
for l in "META|schema|info|1" "META|title|info|ID:TD-1 -- Seed" "META|autonomy|info|auto" \
  "APPRAISE|appraise|done|complexity=simple" "META|artifact|info|plan:$W/simple-fix.md" \
  "EXEC|create-artifact|done|simple-fix"; do
  echo "2026-10-01T00:00:00Z|$l" >>"$LOG_FILE"
done
write_ticket_manifest TD-1 INIT-42 chore '[]' >/dev/null
rc=0
if [ "$STRICT" = true ]; then
  DOR_STRICT_TEST_DATA=true DOR_STRICT_VPLAN=true _gate_entry >/dev/null 2>&1 || rc=$?
else
  _gate_entry >/dev/null 2>&1 || rc=$?
fi
echo "rc=$rc mode=${GATE_CHECK_TEST_TICKET_MODE:-unset}"
grep -E '\|(GATE|META)\|(gate|gate-stop|planned-check|vplan-source)\|' "$LOG_FILE"
GATE_EOF
_td_gate_run() { bash "${TMPDIR}/td-gate.sh" "$TAP_LIB" "$1" "$2" "$3" "${4:-1}" </dev/null 2>/dev/null; }

for td in inv-0-test-data-pack inv-0-audit-test-data; do
  f="${out}/${td}.md"
  ctx=$(planner_ticketgen_context_block "$INIT" "EPIC-1" "$f" 2>/dev/null)
  body=$(planner_ticket_body_compose "$f" "$ctx" 2>/dev/null)
  printf '%s\n' "$body" >"${TMPDIR}/${td}.body"
  rc=0
  planner_validate_ticket "$body" true chore >/dev/null 2>"${TMPDIR}/validate.err" || rc=$?
  assert_eq "${td}: TicketGen's planner_validate_ticket passes (Planner Context + chore body)" "$rc|$(tr '\n' ' ' <"${TMPDIR}/validate.err")" "0|"
  assert_not_contains "${td}: Planner Context names Affected Services" "$ctx" "**Affected Services:** "$'\n'
  assert_contains "${td}: Target Symbols are the Make targets" "$ctx" "**Target Symbols:** seed-${td}:Makefile; verify-seed-${td}:Makefile"
  # shellcheck disable=SC1091
  res=$(
    source "${TAP_LIB}/dor-check.sh" >/dev/null 2>&1
    rc=0
    DOR_STRICT_TEST_DATA=true DOR_STRICT_VPLAN=true \
      check_ticket_ready TD-1 --body "${TMPDIR}/${td}.body" --type chore --no-fetch >/dev/null 2>&1 || rc=$?
    echo "${rc}|${DOR_STATUS}|${DOR_MISSING}"
  )
  assert_eq "${td}: dor-check ready as a chore with strict test-data + vplan" "$res" "0|ready|[]"
done

body_f="${TMPDIR}/inv-0-test-data-pack.body"
gate=$(_td_gate_run "$body_f" "$body_f" true)
assert_contains "gate (strict): entry gate passes" "$gate" "rc=0 "
assert_contains "gate: 2.7a Planner Context valid" "$gate" "|GATE|planned-check|done|valid"
assert_contains "gate: 2.7c body complete for chore" "$gate" "|GATE|planned-check|done|body complete for type chore"
assert_not_contains "gate: no gate-stop" "$gate" "gate-stop"
assert_not_contains "gate: no Check 2.6 hold" "$gate" "held:"
# Check 2.6 classifies by scanning the plan artifact when no Verification Plan
# table parses (notes.md, body.md and the description all lack one) — the
# path a TD ticket takes when its appraise artifact carries no table.
sed '/^## Verification Plan$/,/^## Related Tickets$/{/^## Related Tickets$/!d}' "$body_f" >"${TMPDIR}/td-novplan.body"
gate=$(_td_gate_run "$body_f" "${TMPDIR}/td-novplan.body" false)
assert_contains "gate: Check 2.6 artifact scan classifies the TD body build-only" "$gate" "mode=build-only"
assert_contains "gate: …and the build-only prerequisites are met (no hold)" "$gate" "rc=0 "
assert_contains "gate: …the scan path was taken" "$gate" "source=none"
gate=$(_td_gate_run "$body_f" "${TMPDIR}/td-novplan.body" false 0)
assert_contains "gate: test seam is inert without GATE_CHECK_TEST_MODE=1" "$gate" "mode=unset"

echo "--- 5.2: TicketGen priority (High only for synth-marked specs) ---"
assert_eq "TD spec → Linear priority 2 (High)" "$(planner_ticketgen_priority "${out}/inv-0-test-data-pack.md")" 2
assert_eq "consumer spec → no priority" "$(planner_ticketgen_priority "${SPECS}/inv-0-export.md")" ""
assert_eq "missing file → no priority" "$(planner_ticketgen_priority "${TMPDIR}/nope.md")" ""
sed 's/"Priority": "High"/"Priority": "Low"/' "${out}/inv-0-test-data-pack.md" >"${TMPDIR}/td-low.md"
assert_eq "TD spec Signals Priority Low → 4" "$(planner_ticketgen_priority "${TMPDIR}/td-low.md")" 4
sed '/"Priority": "High"/d; s/"Enables": \(.*\),$/"Enables": \1/' "${out}/inv-0-test-data-pack.md" >"${TMPDIR}/td-nopri.md"
assert_eq "TD spec without a Priority → High" "$(planner_ticketgen_priority "${TMPDIR}/td-nopri.md")" 2
sed 's/"Kind": "business"/"Kind": "business", "Priority": "Urgent"/' "${SPECS}/inv-0-export.md" >"${TMPDIR}/cons-pri.md"
assert_eq "an unmarked spec's own Signals Priority is ignored" "$(planner_ticketgen_priority "${TMPDIR}/cons-pri.md")" ""
assert_contains "TicketGen prompt passes the priority to issueCreate" \
  "$(
    timeout 30 bash -c 'source "$1/planner-phase-prompts.sh"; planner_prompt_ticketgen "$2" idea "$3"' _ \
      "$LIB_DIR" "$INIT" "${ART}/.." </dev/null 2>/dev/null
  )" 'TICKET_PRIORITY=$(planner_ticketgen_priority "$spec_file")'

echo "--- TD Affected Services: consumers' union, else test-data ---"
svc_dir="${TMPDIR}/svc-specs"
mkdir -p "$svc_dir"
printf '## Signals\n\n```json\n{"AffectedServices": "billing, api-gateway"}\n```\n' >"${svc_dir}/a.md"
printf '## Signals\n\n```json\n{"AffectedServices": "billing,ledger"}\n```\n' >"${svc_dir}/b.md"
printf '## Signals\n\n```json\n{"Kind": "business"}\n```\n' >"${svc_dir}/c.md"
assert_eq "union, sorted, unique" "$(_planner_tds_consumer_services "$svc_dir" a b c)" "api-gateway, billing, ledger"
assert_eq "no consumer names one → test-data" "$(_planner_tds_consumer_services "$svc_dir" c)" "test-data"

echo "--- 5.1: EpicGen UAT policy ---"
UAT_INIT="INIT-44"
UAT_ART="${REPOS_ROOT}/.ticket-auto/initiatives/${UAT_INIT}/artifacts"
mkdir -p "$UAT_ART"
assert_eq "no sidecar → empty" "$(planner_testdata_synth_uat_policy "$UAT_INIT" true "")" ""
echo '{"version":1,"td_specs":[],"overrides":[],"edges":[]}' >"${UAT_ART}/testdata-synth.json"
assert_eq "sidecar with no TD specs → empty" "$(planner_testdata_synth_uat_policy "$UAT_INIT" true "")" ""
echo '{"version":1,"td_specs":[{"slug":"x-test-data","kind":"single"}],"overrides":[],"edges":[]}' >"${UAT_ART}/testdata-synth.json"
assert_eq "TD specs + shared branch → epic" "$(planner_testdata_synth_uat_policy "$UAT_INIT" true "")" "epic"
assert_eq "TD specs, no shared branch → empty" "$(planner_testdata_synth_uat_policy "$UAT_INIT" false "")" ""
assert_eq "explicit per-ticket wins" "$(planner_testdata_synth_uat_policy "$UAT_INIT" true per-ticket)" "per-ticket"
assert_eq "explicit epic kept without TD specs" "$(planner_testdata_synth_uat_policy INIT-NONE false epic)" "epic"
echo 'not json' >"${UAT_ART}/testdata-synth.json"
assert_eq "unreadable sidecar → empty (rc 0)" "$(planner_testdata_synth_uat_policy "$UAT_INIT" true "" && echo ok)" "ok"

echo "--- SIGNALS_UNIFORM skips synth-marked specs (template signals by design) ---"
source "${LIB_DIR}/planner-crosscheck-signals.sh"
SIG_INIT="INIT-43"
mkdir -p "${REPOS_ROOT}/.ticket-auto/initiatives/${SIG_INIT}/artifacts/specs"
cp "${out}"/*.md "${REPOS_ROOT}/.ticket-auto/initiatives/${SIG_INIT}/artifacts/specs/"
sigout=$(planner_crosscheck_signals "$SIG_INIT" 2>&1)
assert_eq "no SIGNALS_UNIFORM across TD specs" "$sigout" ""

# ── 4.5-4.7 recompute, sidecar, INDEX.md, Crosscheck wiring ─────────────────

echo "--- synthesize: writes TD specs, sidecar, INDEX block; consumers untouched ---"
setup
mkspec inv-0-list '["O1"]' "The list shows paid invoices" \
  'The list shows paid invoices|5 `invoice` records in state paid|generate'
mkspec inv-0-audit '["O3"]' "Audit shows the event" \
  'Audit shows the event|an `audit-event` record|generate'
printf '# Spec index\n\n- inv-0-list\n- inv-0-audit\n' >"${SPECS}/INDEX.md"
cons_sum=$(sha256sum "${SPECS}/inv-0-list.md" "${SPECS}/inv-0-audit.md")
rc=0
planner_testdata_synthesize "$INIT" >/dev/null || rc=$?
assert_eq "synthesize rc 0" "$rc" 0
SC="${ART}/testdata-synth.json"
assert_eq "single TD specs written" "$(find "$SPECS" -name '*-test-data.md' | wc -l | tr -d ' ')" 2
assert_eq "consumer specs byte-identical" "$(sha256sum "${SPECS}/inv-0-list.md" "${SPECS}/inv-0-audit.md")" "$cons_sum"
assert_contains "TD spec carries its keys line" "$(cat "${SPECS}/inv-0-list-test-data.md")" "<!-- planner:testdata-synth keys: invoice -->"
assert_eq "TD spec mode follows the umask (not mktemp's 0600)" \
  "$(stat -c %a "${SPECS}/inv-0-list-test-data.md")" "$(printf '%o' $((0666 & ~$(umask))))"
assert_eq "sidecar version 1" "$(jq -r .version "$SC")" 1
assert_eq "sidecar is jq -S formatted" "$(jq -S . "$SC")" "$(cat "$SC")"
assert_eq "sidecar edges" "$(jq -c '[.edges[] | [.consumer, .blocked_by]]' "$SC")" \
  '[["inv-0-audit","inv-0-audit-test-data"],["inv-0-list","inv-0-list-test-data"]]'
assert_eq "sidecar override for the list need" \
  "$(jq -c '.overrides[] | select(.consumer == "inv-0-list") | [.criterion, .data, .record, .source]' "$SC")" \
  '["The list shows paid invoices","5 `invoice` records in state paid","td-42-2","seeded-by:inv-0-list-test-data"]'
idx=$(cat "${SPECS}/INDEX.md")
assert_contains "INDEX keeps Specify's lines" "$idx" "- inv-0-audit"
assert_contains "INDEX block lists the TD spec" "$idx" '- `inv-0-list-test-data` — synthesized test data (single) for `inv-0-list`'
ov=$(planner_testdata_synth_overrides "$INIT")
assert_contains "overrides reader" "$ov" $'inv-0-list\037The list shows paid invoices\0375 `invoice` records in state paid\037seeded-by:inv-0-list-test-data\037td-42-2'
assert_eq "edges reader" "$(planner_testdata_synth_edges "$INIT" | tr '\037\n' '> ')" \
  "inv-0-audit>inv-0-audit-test-data inv-0-list>inv-0-list-test-data "

echo "--- synthesize: idempotent (no content or mtime change) ---"
snap() { (cd "$ART" && find . -type f -printf '%P %s %T@\n' | LC_ALL=C sort); }
touch -d '2001-01-01' "${SPECS}"/*.md "$SC"
before=$(snap)
planner_testdata_synthesize "$INIT" >/dev/null
assert_eq "second run changes no file" "$(snap)" "$before"

echo "--- overrides reader drops a stale entry (TD spec gone) ---"
mv "${SPECS}/inv-0-audit-test-data.md" "${TMPDIR}/audit-td.md"
assert_not_contains "missing TD spec → no override" "$(planner_testdata_synth_overrides "$INIT")" "inv-0-audit-test-data"
mv "${TMPDIR}/audit-td.md" "${SPECS}/inv-0-audit-test-data.md"

echo "--- stable record numbers across a need change ---"
mkspec inv-0-aaa '["O5"]' "Aaa shows a widget" 'Aaa shows a widget|a `widget` record|generate'
planner_testdata_synthesize "$INIT" >/dev/null
assert_eq "existing needs keep their record keys, the new one gets max+1" \
  "$(jq -r '.overrides[] | .consumer + "=" + .record' "$SC" | LC_ALL=C sort | tr '\n' ' ')" \
  "inv-0-aaa=td-42-3 inv-0-audit=td-42-1 inv-0-list=td-42-2 "
rm -f "${SPECS:?}/inv-0-aaa.md"
planner_testdata_synthesize "$INIT" >/dev/null
assert_eq "removed need: TD spec deleted (no ticket)" "$([ -e "${SPECS}/inv-0-aaa-test-data.md" ] && echo present || echo gone)" gone
assert_not_contains "removed need: INDEX line removed" "$(cat "${SPECS}/INDEX.md")" "inv-0-aaa-test-data"

echo "--- 1 → 2 consumers: single replaced by the pack ---"
mkspec inv-0-export '["O2"]' "Export includes paid invoices" 'Export includes paid invoices|3 paid invoices|generate'
planner_testdata_synthesize "$INIT" >/dev/null
assert_eq "single removed" "$([ -e "${SPECS}/inv-0-list-test-data.md" ] && echo present || echo gone)" gone
assert_eq "pack written" "$([ -e "${SPECS}/inv-0-test-data-pack.md" ] && echo present || echo gone)" present
assert_eq "list need keeps td-42-2 inside the pack" \
  "$(jq -r '.overrides[] | select(.consumer == "inv-0-list") | .record + " " + .source' "$SC")" "td-42-2 seeded-by:inv-0-test-data-pack"

echo "--- 2 → 1 consumers: pack replaced by the single ---"
rm -f "${SPECS:?}/inv-0-export.md"
planner_testdata_synthesize "$INIT" >/dev/null
assert_eq "pack removed" "$([ -e "${SPECS}/inv-0-test-data-pack.md" ] && echo present || echo gone)" gone
assert_eq "single back" "$([ -e "${SPECS}/inv-0-list-test-data.md" ] && echo present || echo gone)" present

echo "--- dispatched TD spec: kept byte-for-byte, owned key re-attached ---"
mkdir -p "${ART}/../.intents"
printf '{"status":"created","linear_id":"TD-9"}\n' >"${ART}/../.intents/ticket-inv-0-list-test-data.json"
printf '\nFrozen: ticket body already in the tracker.\n' >>"${SPECS}/inv-0-list-test-data.md"
frozen=$(sha256sum "${SPECS}/inv-0-list-test-data.md")
assert_eq "has_ticket via the TicketGen intent file" \
  "$(planner_testdata_synth_has_ticket "$INIT" inv-0-list-test-data && echo yes)" yes
mkspec inv-0-export '["O2"]' "Export includes paid invoices" 'Export includes paid invoices|3 paid invoices|generate'
mkspec inv-0-list '["O1"]' "The list shows paid invoices" \
  'The list shows paid invoices|5 `invoice` records in state paid|generate' \
  'The list shows paid invoices|2 `refund` records|generate' \
  'The list shows paid invoices|1 `invoice` record in state draft|generate'
planner_testdata_synthesize "$INIT" >/dev/null
assert_eq "dispatched file untouched" "$(sha256sum "${SPECS}/inv-0-list-test-data.md")" "$frozen"
assert_eq "frozen spec lists the need it was rendered with" \
  "$(_planner_tds_spec_listed "$INIT" inv-0-list-test-data)" \
  '5 `invoice` records in state paid — for `inv-0-list`: The list shows paid invoices'
# Gap fix: a NEW need on a key the frozen spec owns is never attached to it —
# its ticket body is already in the tracker and does not list the need. The
# fresh needs group by the usual rule (2 fresh consumers on `invoice` → pack).
assert_eq "only the need the frozen spec lists stays on it; new needs on the owned key are placed fresh" \
  "$(jq -r '.overrides[] | select(.data | test("invoice")) | .consumer + ">" + .source' "$SC" | tr '\n' ' ')" \
  "inv-0-export>seeded-by:inv-0-test-data-pack inv-0-list>seeded-by:inv-0-test-data-pack inv-0-list>seeded-by:inv-0-list-test-data "
assert_eq "…the listed one is the frozen spec's own need" \
  "$(jq -r '.overrides[] | select(.source == "seeded-by:inv-0-list-test-data") | .data' "$SC")" '5 `invoice` records in state paid'
assert_contains "…and the pack lists the new need on the owned key" \
  "$(cat "${SPECS}/inv-0-test-data-pack.md")" '1 `invoice` record in state draft — for `inv-0-list`'
assert_eq "frozen spec still listed with only its own consumer" \
  "$(jq -c '.td_specs[] | select(.slug == "inv-0-list-test-data") | [.consumers, .dispatched]' "$SC")" '[["inv-0-list"],true]'
assert_eq "a new key from the same consumer gets a -2 slug" \
  "$(jq -r '.overrides[] | select(.data | test("refund")) | .source' "$SC")" "seeded-by:inv-0-list-test-data-2"
assert_eq "sidecar marks it dispatched" \
  "$(jq -r '.td_specs[] | select(.slug == "inv-0-list-test-data") | .dispatched' "$SC")" true
rm -f "${SPECS:?}/inv-0-export.md"
planner_testdata_synthesize "$INIT" >/dev/null
assert_eq "a single consumer's new need on the frozen key → <td-slug>-2, never the frozen spec" \
  "$(jq -r '.overrides[] | select(.data | test("draft")) | .source' "$SC")" "seeded-by:inv-0-list-test-data-2"
assert_eq "…frozen file still untouched" "$(sha256sum "${SPECS}/inv-0-list-test-data.md")" "$frozen"
rm -f "${SPECS:?}/inv-0-list.md"
planner_testdata_synthesize "$INIT" >/dev/null
assert_eq "dispatched spec survives losing every need" "$(sha256sum "${SPECS}/inv-0-list-test-data.md")" "$frozen"
assert_eq "…and stays in the sidecar with no consumer" \
  "$(jq -c '.td_specs[] | select(.slug == "inv-0-list-test-data") | .consumers' "$SC")" "[]"

echo "--- nothing to synthesize: no sidecar created, INDEX untouched ---"
setup
mkspec inv-0-none '["O1"]' "The header renders" 'The header renders|none|—'
printf '# Spec index\n' >"${SPECS}/INDEX.md"
planner_testdata_synthesize "$INIT" >/dev/null
assert_eq "no sidecar" "$([ -e "${ART}/testdata-synth.json" ] && echo present || echo gone)" gone
assert_eq "INDEX untouched" "$(cat "${SPECS}/INDEX.md")" "# Spec index"

echo "--- Crosscheck wiring: brackets after check|start, synth-failure finding ---"
source "${LIB_DIR}/planner-crosscheck.sh"
setup
mkspec inv-0-audit '["O3"]' "Audit shows the event" 'Audit shows the event|an `audit-event` record|generate'
planner_crosscheck_run "$INIT" >/dev/null 2>&1
LOG="${ART}/../state.log"
# (setup's pending cited artifact makes this attempt block — only the
# ordering of the phase and sub-step markers matters here.)
order=$(grep -E '\|Crosscheck\|(check|testdata-synth)\|' "$LOG" | cut -d'|' -f2-4 | sed 's/|check|fail$/|check|done/' | tr '\n' ' ')
assert_eq "check|start, then testdata-synth start|done, then the phase's terminal line" "$order" \
  "Crosscheck|check|start Crosscheck|testdata-synth|start Crosscheck|testdata-synth|done Crosscheck|check|done "
assert_contains "done message names TD specs and needs" "$(cat "$LOG")" "|Crosscheck|testdata-synth|done|1 TD spec(s), 1 need(s)"
printf '2026-10-01T00:00:00Z|Crosscheck|check|start|x\n2026-10-01T00:00:00Z|Crosscheck|testdata-synth|start|x\n2026-10-01T00:00:00Z|Crosscheck|testdata-synth|done|x\n' >>"$LOG"
assert_eq "position_derive: a crash after testdata-synth|done resumes Crosscheck" "$(planner_position_derive "$INIT")" Crosscheck
printf '# inv-0-audit-test-data\n\nhand-written\n' >"${SPECS}/inv-0-audit-test-data.md"
rm -f "${ART:?}/testdata-synth.json"
rc=0
planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
assert_eq "collision blocks Crosscheck" "$rc" 1
assert_contains "TEST_DATA_SYNTH_FAILED finding names the file" "$(planner_crosscheck_findings_report "$INIT")" "TEST_DATA_SYNTH_FAILED"
assert_contains "…grouped under the colliding spec" "$(planner_crosscheck_findings_report "$INIT" | grep -A1 -x 'inv-0-audit-test-data.md')" "TEST_DATA_SYNTH_FAILED"
assert_contains "the need it could not own is still TEST_DATA_UNOWNED" "$(planner_crosscheck_findings_summary "$INIT")" "TEST_DATA_UNOWNED"
assert_eq "no testdata-synth fail line (phase fail count stays per attempt)" "$(grep -c '|Crosscheck|testdata-synth|fail|' "$LOG")" 0
assert_contains "UNOWNED remedy no longer asks for a hand-written pack" "$(grep 'TEST_DATA_UNOWNED' "$LOG" | tail -1)" "do not hand-write a test-data pack"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
