#!/usr/bin/env bash
# audit-run-checks.sh — ticket-audit Step 6's deterministic checks for one
# ticket, in the SKILL.md order (skill-deterministic-extraction 6a).
#
# Usage:
#   audit-run-checks.sh --ticket-json F [--wiki-services CSV] [--extra-patterns P]
#
# F is one Linear issue object (title, description, labels{nodes}|labels,
# updatedAt, state{name}, identifier). The `## Planner Context` block is
# stripped before Checks 4 and 6 and split detection, so the planner's own
# mandated metadata is never counted as ticket content. The acceptance
# criteria are the description's `## Acceptance Criteria` section, else its
# numbered / checkbox lines.
#
# Prints, in order, each check's raw lib output under a header:
#   === CHECK 2 ===  audit_ac_testability   (LLM confirms VAGUE_ACS only)
#   === CHECK 3 ===  audit_test_data_check  (LLM confirms ASSUMPTIONS only)
#   === CHECK 4 ===  audit_scope_check
#   === CHECK 5 ===  audit_repro_check
#   === CHECK 6 ===  WORD_COUNT=<substantive words>
#   === CHECK 8 ===  STALE=true|false STATE=<name>
#   === SPLIT ===    audit_size_check
# then one `FINDING=<BLOCKER|WARNING>|<text>` line per deterministic finding
# (Checks 4, 5, 6, 8 and a split candidate) and one `REVIEW=CHECK_2|…` /
# `REVIEW=CHECK_3|…` line when the LLM has something to confirm. Checks 1, 7
# and 9 are LLM work and stay in the skill.
#
# Env: TICKET_AUDIT_STALE_DAYS (config.sh, default 30).
# Exit codes: 0 ran (findings are output, not a failure), 2 usage or an
# unreadable ticket JSON.

_ARC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_arc_usage() {
  sed -n '6,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
_json="" _svcs="" _extra=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || _arc_usage
  case "$1" in
  --ticket-json) _json="$2" ;;
  --wiki-services) _svcs="$2" ;;
  --extra-patterns) _extra="$2" ;;
  *) _arc_usage ;;
  esac
  shift 2
done
[ -n "$_json" ] || _arc_usage
jq -e 'type == "object"' "$_json" >/dev/null 2>&1 || {
  echo "audit-run-checks: $_json is not a ticket JSON object" >&2
  exit 2
}

for _l in config planned-ticket-check audit-ac-testability audit-test-data-check \
  audit-scope-check audit-repro-check audit-size-check; do
  # shellcheck disable=SC1090
  source "$_ARC_DIR/$_l.sh"
done
set +eo pipefail # the audit libs set them at file scope

title=$(jq -r '.title // ""' "$_json")
description=$(jq -r '.description // ""' "$_json")
labels=$(jq -r '[(.labels.nodes? // .labels // [])[]? | (.name? // .)] | join(",")' "$_json" 2>/dev/null)
updatedAt=$(jq -r '.updatedAt // ""' "$_json")
state_name=$(jq -r '.state.name // ""' "$_json")
description_stripped="$(_strip_planner_context_block "$description")"
acceptance_criteria=$(_extract_md_section "$description" "Acceptance Criteria" 2>/dev/null | sed '1{/^## /d}')
if [ -z "$(tr -d '[:space:]' <<<"$acceptance_criteria")" ]; then
  acceptance_criteria=$(grep -E '^[[:space:]]*([0-9]+[.)]|- \[[ xX]\])' <<<"$description_stripped" || true)
fi
nl=$'\n'
_findings=()
_reviews=()

echo "=== CHECK 2 ==="
_o=$(audit_ac_testability "$acceptance_criteria")
printf '%s\n' "$_o"
if grep -qx 'ALL_CLEAR=false' <<<"$_o"; then
  _reviews+=("CHECK_2|$(sed -n 's/^VAGUE_ACS="\(.*\)"$/\1/p' <<<"$_o")")
fi

echo "=== CHECK 3 ==="
_o=$(audit_test_data_check "${description}${nl}${acceptance_criteria}")
printf '%s\n' "$_o"
if grep -qx 'NEEDS_TEST_DATA=true' <<<"$_o"; then
  _reviews+=("CHECK_3|$(sed -n 's/^ASSUMPTIONS="\(.*\)"$/\1/p' <<<"$_o")")
fi

echo "=== CHECK 4 ==="
_o=$(audit_scope_check "${title}${nl}${description_stripped}" "$_svcs" "$_extra")
printf '%s\n' "$_o"
grep -qx 'SCOPE_FOUND=false' <<<"$_o" &&
  _findings+=("WARNING|Scope unclear: ticket does not reference any known service, component, or scope indicator.")

echo "=== CHECK 5 ==="
_o=$(audit_repro_check "${description}${nl}${acceptance_criteria}" "$labels")
printf '%s\n' "$_o"
grep -qx 'IS_BUG=true' <<<"$_o" && grep -qx 'HAS_REPRO=false' <<<"$_o" &&
  _findings+=("WARNING|Bug without repro steps: no numbered steps, action bullets, or 'Steps to reproduce' section found.")

echo "=== CHECK 6 ==="
content="$(echo "$description_stripped $acceptance_criteria" | sed 's/[#*_`~>|\[\]()]//g')"
word_count=$(echo "$content" | wc -w | tr -d ' ')
echo "WORD_COUNT=$word_count"
[ "$word_count" -lt 20 ] && _findings+=("BLOCKER|Empty ticket (< 20 substantive words)")

echo "=== CHECK 8 ==="
stale_seconds=$((TICKET_AUDIT_STALE_DAYS * 86400))
updated_epoch=$(date -d "$updatedAt" +%s 2>/dev/null || echo 0)
age_seconds=$(($(date +%s) - updated_epoch))
_stale=false
if [ "$age_seconds" -gt "$stale_seconds" ] && { [ "$state_name" = "Backlog" ] || [ "$state_name" = "Todo" ]; }; then
  _stale=true
  _findings+=("WARNING|Stale ticket (not updated in ${TICKET_AUDIT_STALE_DAYS}+ days, still in $state_name)")
fi
printf 'STALE=%s\nSTATE=%s\n' "$_stale" "$state_name"

echo "=== SPLIT ==="
_o=$(audit_size_check "${title}${nl}${description_stripped}${nl}${acceptance_criteria}" "$_svcs")
printf '%s\n' "$_o"
_sc=$(sed -n 's/^SIGNAL_COUNT=//p' <<<"$_o")
if [ "${_sc:-0}" -ge 2 ]; then
  _findings+=("WARNING|Split candidate: $(sed -n 's/^SPLIT_SUGGESTION="\(.*\)"$/\1/p' <<<"$_o")")
fi

echo "=== RESULT ==="
for _f in "${_findings[@]}"; do echo "FINDING=$_f"; done
for _r in "${_reviews[@]}"; do echo "REVIEW=$_r"; done
exit 0
