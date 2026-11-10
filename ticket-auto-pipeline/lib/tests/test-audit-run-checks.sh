#!/usr/bin/env bash
# test-audit-run-checks.sh — lib/audit-run-checks.sh (ticket-audit Step 6
# deterministic checks, skill-deterministic-extraction 6a).
#
# Parity oracle: the pre-extraction Step 6 fences (main @ 267c17f) embedded
# below, run in one shell from the plugin root (they sourced `lib/…`
# relative to the CWD) with the variables the prose assumed set from the
# same ticket (each fence was its own shell, so the errexit the audit libs
# set at file scope is turned off again after every source). Two deliberate differences are applied to the oracle, not
# hidden: the fences joined text with a literal `\n` inside double quotes
# (two characters, not a newline), which the script fixes, so the oracle
# joins with a real newline; and the prose never defined
# `$acceptance_criteria`, so both sides use the script's definition (the
# `## Acceptance Criteria` section). Order and messages come from the prose.
#
# Usage: bash test-audit-run-checks.sh
set -eo pipefail

AR_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AR_LIB_DIR="$(cd "$AR_TEST_DIR/.." && pwd)"
ARC="$AR_LIB_DIR/audit-run-checks.sh"

PASS=0 FAIL=0
_ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
_ko() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}
_same() {
  if [ "$2" = "$3" ]; then _ok "$1"; else
    _ko "$1"
    diff <(echo "$2") <(echo "$3") | sed 's/^/    /' || true
  fi
}
WS=$(mktemp -d)
trap 'rm -rf "$WS"' EXIT
export TICKET_AUDIT_STALE_DAYS=30
SVCS="attorney-service,billing-service,notification-service"

# Step 6 fences (Checks 2-6, 8 and split step 1), main @ 267c17f, `\n` as a
# real newline. Prints each check's output under the script's headers.
_old() { # <ticket.json>
  (cd "$AR_LIB_DIR/.." && J="$1" SVCS="$SVCS" bash -c '
set +eo pipefail
ticket_json=$(cat "$J")
title=$(jq -r ".title" <<<"$ticket_json")
description=$(jq -r ".description // \"\"" <<<"$ticket_json")
labels=$(jq -r "[(.labels.nodes? // .labels // [])[]? | (.name? // .)] | join(\",\")" <<<"$ticket_json")
updatedAt=$(jq -r ".updatedAt" <<<"$ticket_json")
wiki_services_csv="$SVCS"; extra_patterns=""
source lib/planned-ticket-check.sh
set +eo pipefail
description_stripped="$(_strip_planner_context_block "$description")"
acceptance_criteria=$(_extract_md_section "$description" "Acceptance Criteria" 2>/dev/null | sed "1{/^## /d}")
NL=$'"'"'\n'"'"'
echo "=== CHECK 2 ==="
source lib/audit-ac-testability.sh
set +eo pipefail
audit_ac_testability "$acceptance_criteria"
echo "=== CHECK 3 ==="
source lib/audit-test-data-check.sh
set +eo pipefail
audit_test_data_check "${description}${NL}${acceptance_criteria}"
echo "=== CHECK 4 ==="
source lib/audit-scope-check.sh
set +eo pipefail
audit_scope_check "${title}${NL}${description_stripped}" "$wiki_services_csv" "$extra_patterns"
echo "=== CHECK 5 ==="
source lib/audit-repro-check.sh
set +eo pipefail
audit_repro_check "${description}${NL}${acceptance_criteria}" "$labels"
echo "=== CHECK 6 ==="
content="$(echo "$description_stripped $acceptance_criteria" | sed '"'"'s/[#*_`~>|\[\]()]//g'"'"')"
word_count=$(echo "$content" | wc -w)
if [ "$word_count" -lt 20 ]; then
  echo "BLOCKER: Empty ticket (< 20 substantive words)"
fi
echo "=== CHECK 8 ==="
stale_seconds=$((TICKET_AUDIT_STALE_DAYS * 86400))
updated_epoch=$(date -d "$updatedAt" +%s 2>/dev/null || echo 0)
now_epoch=$(date +%s)
age_seconds=$((now_epoch - updated_epoch))
if [ "$age_seconds" -gt "$stale_seconds" ]; then
  state_name="$(echo "$ticket_json" | jq -r ".state.name")"
  if [ "$state_name" = "Backlog" ] || [ "$state_name" = "Todo" ]; then
    echo "WARNING: Stale ticket (not updated in ${TICKET_AUDIT_STALE_DAYS}+ days, still in $state_name)"
  fi
fi
echo "=== SPLIT ==="
ticket_text="${title}${NL}${description_stripped}${NL}${acceptance_criteria}"
source lib/audit-size-check.sh
set +eo pipefail
audit_size_check "$ticket_text" "$wiki_services_csv"
' 2>/dev/null)
}
# The lib outputs of a section, for comparison with the oracle.
_section() { awk -v h="=== $2 ===" '$0 == h {s = 1; next} /^=== / {s = 0} s' <<<"$1"; }

_ticket() { # <name> <jq program>
  jq -n "$2" >"$WS/$1.json"
}
_ticket clean '{identifier:"T-1",title:"Attorney assignment export",description:"Add a CSV export to the attorney-service assignment page so staff can download the weekly list for reporting and audits without manual copying.\n\n## Acceptance Criteria\n1. The export button returns a CSV within 2 seconds\n2. The CSV has a header row\n",labels:{nodes:[{name:"feature"}]},updatedAt:(now|todate),state:{name:"Todo"}}'
_ticket messy '{identifier:"T-2",title:"Fix things",description:"Broken.\n\n## Acceptance Criteria\n1. It should work properly\n2. Given an existing user, it is fast\n\n## Planner Context\n**Affected Services:** attorney-service, billing-service, notification-service\n",labels:{nodes:[{name:"bug"}]},updatedAt:"2025-01-01T00:00:00Z",state:{name:"Backlog"}}'
_ticket big '{identifier:"T-3",title:"Rework attorney-service billing-service notification-service",description:("Long text. " * 220 + "\n\n## Acceptance Criteria\n1. a works\n2. b works\n3. c works\n4. d works\n5. e works\n6. f works\n7. g works\n"),labels:["feature"],updatedAt:(now|todate),state:{name:"In Progress"}}'

echo "=== parity with the Step 6 fences ==="
for t in clean messy big; do
  old=$(_old "$WS/$t.json") || true
  new=$(bash "$ARC" --ticket-json "$WS/$t.json" --wiki-services "$SVCS")
  for c in "CHECK 2" "CHECK 3" "CHECK 4" "CHECK 5" "SPLIT"; do
    _same "$t: $c output" "$(_section "$old" "$c")" "$(_section "$new" "$c")"
  done
  # Checks 6 and 8 printed findings; the script prints them as FINDING lines.
  _same "$t: CHECK 6 finding" "$(_section "$old" "CHECK 6" | sed 's/^BLOCKER: /FINDING=BLOCKER|/')" \
    "$(grep '^FINDING=BLOCKER|Empty' <<<"$new" || true)"
  _same "$t: CHECK 8 finding" "$(_section "$old" "CHECK 8" | sed 's/^WARNING: /FINDING=WARNING|/')" \
    "$(grep '^FINDING=WARNING|Stale' <<<"$new" || true)"
done

echo "=== findings and order ==="
new=$(bash "$ARC" --ticket-json "$WS/messy.json" --wiki-services "$SVCS")
_same "messy: headers in SKILL.md order" "CHECK 2,CHECK 3,CHECK 4,CHECK 5,CHECK 6,CHECK 8,SPLIT,RESULT" \
  "$(grep '^=== ' <<<"$new" | sed 's/=== \(.*\) ===/\1/' | paste -sd,)"
grep -q '^REVIEW=CHECK_2|.*should work properly' <<<"$new" && _ok "messy: vague AC sent to the LLM" || _ko "messy: CHECK_2 review: $new"
grep -qx "FINDING=WARNING|Bug without repro steps: no numbered steps, action bullets, or 'Steps to reproduce' section found." <<<"$new" &&
  _ok "messy: bug without repro" || _ko "messy: repro finding"
printf '{"title":"x","description":"Tiny.","labels":[],"updatedAt":"","state":{"name":"Done"}}' >"$WS/tiny.json"
grep -qx 'FINDING=BLOCKER|Empty ticket (< 20 substantive words)' <<<"$(bash "$ARC" --ticket-json "$WS/tiny.json")" &&
  _ok "tiny: empty ticket" || _ko "tiny: empty"
grep -qx 'FINDING=WARNING|Stale ticket (not updated in 30+ days, still in Backlog)' <<<"$new" && _ok "messy: stale" || _ko "messy: stale"
grep -q 'MATCHED_SERVICES=""' <<<"$(_section "$new" "CHECK 4")" && _ok "messy: Planner Context not counted as scope" ||
  _ko "messy: planner block counted: $(_section "$new" "CHECK 4")"
new=$(bash "$ARC" --ticket-json "$WS/big.json" --wiki-services "$SVCS")
grep -q '^FINDING=WARNING|Split candidate: ' <<<"$new" && _ok "big: split candidate" || _ko "big: split: $new"
! grep -q 'Stale\|Empty' <<<"$new" && _ok "big: not stale (In Progress), not empty" || _ko "big: $new"
new=$(bash "$ARC" --ticket-json "$WS/clean.json" --wiki-services "$SVCS")
[ -z "$(grep '^FINDING=\|^REVIEW=' <<<"$new")" ] && _ok "clean: no findings" || _ko "clean: $(grep '^FINDING=\|^REVIEW=' <<<"$new")"

rc=0
echo '[]' >"$WS/bad.json"
bash "$ARC" --ticket-json "$WS/bad.json" >/dev/null 2>&1 || rc=$?
_same "non-object JSON exits 2" 2 "$rc"
rc=0
bash "$ARC" >/dev/null 2>&1 || rc=$?
_same "usage exits 2" 2 "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
