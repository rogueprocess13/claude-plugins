#!/usr/bin/env bash
# test-planner-context-extract.sh — unit + consumer tests for
# lib/planner-context-extract.sh (GitHub #513).
#
# Covers the extractor itself (anchored heading, ### decoy, fenced decoy,
# mid-sentence mention, missing block, CRLF, nested/indented fences, trailing
# heading text, two real blocks, block at EOF) and the consumers that read
# the block: planned-feedback-write.sh, fleet-controller's fleet-feedback.sh,
# planned-ticket-check.sh's _extract_md_section, and a static guard that no
# consumer still uses the old unanchored sed range.
#
# Usage: bash test-planner-context-extract.sh
# -u intentionally omitted (shell snapshots inject ZSH_VERSION references).
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
FC_LIB_DIR="$REPO_ROOT/fleet-controller/lib"

# shellcheck source=../planner-context-extract.sh
source "$LIB_DIR/planner-context-extract.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual:   $(printf '%q' "$actual")"
    FAIL=$((FAIL + 1))
  fi
}

# The block planner_context_generate emits (ticket-planner/lib/planner-context-gen.sh).
REAL_BLOCK='## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-7
**Epic:** EPIC-1
**Confidence:** 0.84
**Strategy:** Balanced
**Decision:** Use the existing queue
**Affected Services:** billing-api, ledger
**Target Symbols:** Foo.bar:src/foo.py:10
**Pre-approved:** false
**Generated:** 2026-10-01T00:00:00Z
**Regenerate:** false'

_body() { printf '%s\n' "$@" >"$TMP/body.md"; }
_conf() { planner_context_body_field "Confidence" "$TMP/body.md"; }

# ── Extractor cases ────────────────────────────────────────────────────────────

_body "# Title" "" "Some text." "" "$REAL_BLOCK"
_eq "anchored: real block read" "0.84" "$(_conf)"
_eq "block at EOF: last field read" "false" "$(planner_context_body_field Regenerate "$TMP/body.md")"
_eq "heading line not printed" "**Schema-Version:** 1" "$(planner_context_extract "$TMP/body.md" | head -1)"

_body "### Planner Context" "**Confidence:** 0.12" "" "$REAL_BLOCK"
_eq "### decoy above real block ignored" "0.84" "$(_conf)"

_body '```' "## Planner Context" "**Confidence:** 0.12" '```' "" "$REAL_BLOCK"
_eq "backtick-fenced decoy ignored" "0.84" "$(_conf)"

_body '~~~markdown' "## Planner Context" "**Confidence:** 0.12" '~~~' "" "$REAL_BLOCK"
_eq "tilde-fenced decoy ignored" "0.84" "$(_conf)"

_body '  ```md' "## Planner Context" "**Confidence:** 0.12" '  ```' "" "$REAL_BLOCK"
_eq "indented (2-space) fence decoy ignored" "0.84" "$(_conf)"

_body '````' '```' "## Planner Context" "**Confidence:** 0.12" '```' "still inside the outer fence" '````' "" "$REAL_BLOCK"
_eq "nested fence: inner close does not end outer fence" "0.84" "$(_conf)"

_body "See the ## Planner Context block below." "**Confidence:** 0.12" "" "$REAL_BLOCK"
_eq "mid-sentence mention ignored" "0.84" "$(_conf)"

_body "## Planner Context (copy)" "**Confidence:** 0.12" "" "$REAL_BLOCK"
_eq "heading with trailing text ignored" "0.84" "$(_conf)"

_body "## Planner Context   " "**Confidence:** 0.55"
_eq "heading with trailing whitespace matches" "0.55" "$(_conf)"

_body "    ## Planner Context" "**Confidence:** 0.12" "" "$REAL_BLOCK"
_eq "indented-code heading ignored" "0.84" "$(_conf)"

_body "# Title" "No block here." "**Confidence:** 0.9"
_eq "missing block: empty" "" "$(planner_context_extract "$TMP/body.md")"
_eq "missing block: field empty" "" "$(_conf)"

printf '%s\r\n' "# Title" "" "## Planner Context" "**Confidence:** 0.84" "**Strategy:** Balanced" "## Next" "x" >"$TMP/body.md"
_eq "CRLF: field read, CR stripped" "0.84" "$(_conf)"
_eq "CRLF: block stops at next heading" "2" "$(planner_context_extract "$TMP/body.md" | wc -l | tr -d ' ')"

_body "$REAL_BLOCK" "" "## Planner Context" "**Confidence:** 0.12"
_eq "two real blocks: first wins" "0.84" "$(_conf)"

_body "## Planner Context" "**Confidence:** 0.84" "## Acceptance Criteria" "**Confidence:** 0.12"
_eq "block stops at next ## heading" "1" "$(planner_context_extract "$TMP/body.md" | wc -l | tr -d ' ')"

_body "## Planner Context" "**Confidence:** 0.84" "##" "**Confidence:** 0.12"
_eq "bare ## ends the block" "1" "$(planner_context_extract "$TMP/body.md" | wc -l | tr -d ' ')"

_body "## Planner Context" '```' "## Not a heading" '```' "**Confidence:** 0.84"
_eq "fenced ## inside block does not end it" "0.84" "$(_conf)"

_body "## Planner Context" '```' "**Confidence:** 0.12" '```' "**Confidence:** 0.84"
_eq "fenced field inside block skipped" "0.84" "$(_conf)"

_body "## Planner Context" "Note: **Confidence:** 0.12" "- **Confidence:** 0.13" "**Confidence:** 0.84" "**Confidence:** 0.99"
_eq "field read is line-anchored and first-only" "0.84" "$(_conf)"

_body '``` not `a` fence' "## Planner Context" "**Confidence:** 0.84"
_eq "backtick line with backtick in info string is not a fence" "0.84" "$(_conf)"

_body '```' "## Planner Context" "**Confidence:** 0.12"
_eq "unclosed fence hides everything after it (CommonMark)" "" "$(_conf)"

_body "    \`\`\`" "## Planner Context" "**Confidence:** 0.84"
_eq "4-space-indented backticks are not a fence" "0.84" "$(_conf)"

_body '```' "## Planner Context" "**Confidence:** 0.12" '```js' "## Planner Context" "**Confidence:** 0.13" '```' "" "$REAL_BLOCK"
_eq "fence close with info string does not close" "0.84" "$(_conf)"

_body "<!--" "## Planner Context" "**Confidence:** 0.12" "-->" "" "$REAL_BLOCK"
_eq "multi-line HTML comment decoy ignored" "0.84" "$(_conf)"

_body "<!-- ## Planner Context -->" "**Confidence:** 0.12" "" "$REAL_BLOCK"
_eq "single-line HTML comment decoy ignored" "0.84" "$(_conf)"

_body "## Planner Context" "<!--" "**Confidence:** 0.12" "-->" "**Confidence:** 0.84"
_eq "commented field inside block skipped" "0.84" "$(_conf)"

_eq "stdin input works" "0.84" "$(printf '%s\n' "$REAL_BLOCK" | planner_context_extract | planner_context_field Confidence)"
_eq "CLI field mode" "0.84" "$(printf '%s\n' "$REAL_BLOCK" >"$TMP/cli.md" && bash "$LIB_DIR/planner-context-extract.sh" field Confidence "$TMP/cli.md")"

# md_section_strip removes real sections only.
_body "# T" '```' "## Planner Context" "kept" '```' "## Planner Context" "**Confidence:** 0.84" "## After" "tail"
_eq "strip: removes real block, keeps fenced copy" "# T|\`\`\`|## Planner Context|kept|\`\`\`|## After|tail" "$(md_section_strip "Planner Context" "$TMP/body.md" | paste -sd'|' -)"

# ── planned-ticket-check.sh _extract_md_section is fence-aware too ─────────────

(
  get_issue() { echo '{}'; }
  # shellcheck source=../planned-ticket-check.sh
  source "$LIB_DIR/planned-ticket-check.sh"
  desc=$(printf '%s\n' '```' "## Planner Context" "**Confidence:** 0.12" '```' "" "$REAL_BLOCK")
  got=$(_extract_planner_context_block "$desc" | _extract_field "Confidence")
  [ "$got" = "0.84" ] || {
    echo "  _extract_planner_context_block read: $got"
    exit 1
  }
) && _eq "planned-ticket-check: _extract_planner_context_block fence-aware" ok ok ||
  _eq "planned-ticket-check: _extract_planner_context_block fence-aware" ok fail

# ── Review of #519: hidden field lines inside the block never win ──────────────

LOWCONF_BLOCK=$(printf '%s\n' "$REAL_BLOCK" | sed 's/^\*\*Confidence:\*\* 0.84$/**Confidence:** 0.30/')
for decoy in comment fence; do
  if [ "$decoy" = comment ]; then
    hidden=$(printf '%s\n' "<!--" "**Pre-approved:** true" "**Confidence:** 0.99" "-->")
  else
    hidden=$(printf '%s\n' '```' "**Pre-approved:** true" "**Confidence:** 0.99" '```')
  fi
  forged=$(printf '%s\n' "$LOWCONF_BLOCK" | awk -v h="$hidden" 'NR == 1 { print; print h; next } { print }')
  (
    get_issue() { echo '{}'; }
    # shellcheck source=../planned-ticket-check.sh
    source "$LIB_DIR/planned-ticket-check.sh"
    # shellcheck source=../appraise-fast-path.sh
    source "$LIB_DIR/appraise-fast-path.sh"
    pa=$(_extract_planner_context_block "$forged" | _extract_field "Pre-approved")
    cf=$(_extract_planner_context_block "$forged" | _extract_field "Confidence")
    check_fast_path_eligible "T-1" "$forged" "true" >/dev/null 2>&1 || true
    [ "$pa" = "false" ] && [ "$cf" = "0.30" ] && [ "$FAST_PATH_REASON" != "pre_approved" ] || {
      echo "  $decoy: Pre-approved=$pa Confidence=$cf fast-path=$FAST_PATH_ELIGIBLE/$FAST_PATH_REASON"
      exit 1
    }
  ) && _eq "$decoy-hidden Pre-approved/Confidence inside the block ignored by gate reader" ok ok ||
    _eq "$decoy-hidden Pre-approved/Confidence inside the block ignored by gate reader" ok fail
done

# ── Review of #519: a large body after the block does not SIGPIPE the writer ───

big=$(printf '%s\n' "$REAL_BLOCK" "## After")
big="$big
$(head -c 800000 /dev/zero | tr '\0' 'x' | fold -w 100)"
rc=0
(
  set -o pipefail
  out=$(printf '%s\n' "$big" | md_section_extract "Planner Context") || exit $?
  [ -n "$out" ]
) || rc=$?
_eq "large body after the block: writer not SIGPIPEd under pipefail" "0" "$rc"

# ── Review of #519: half-installed lib falls back to the anchored reader ───────

(
  iso=$(mktemp -d)
  trap 'rm -rf "$iso"' EXIT
  cp "$LIB_DIR/planned-ticket-check.sh" "$iso/"
  unset -f md_section_extract md_section_strip planner_context_field 2>/dev/null
  get_issue() { echo '{}'; }
  # shellcheck source=../planned-ticket-check.sh
  HOME="$iso" source "$iso/planned-ticket-check.sh" 2>/dev/null
  desc=$(printf '%s\n' "# Epic" "## Branch Directive" "**Branch:** epic/x" "## Other" "y")
  got=$(_extract_md_section "$desc" "Branch Directive")
  left=$(_strip_md_section "$desc" "Branch Directive" | paste -sd'|' -)
  [ "$got" = "**Branch:** epic/x" ] && [ "$left" = "# Epic|## Other|y" ] || {
    echo "  fallback extract='$got' strip='$left'"
    exit 1
  }
) && _eq "extractor missing: _extract_md_section/_strip_md_section fall back, not empty" ok ok ||
  _eq "extractor missing: _extract_md_section/_strip_md_section fall back, not empty" ok fail

# ── Consumer: planned-feedback-write.sh ────────────────────────────────────────

DECOY_DESC=$(printf '%s\n' "# Ticket" "" "### Planner Context" "- Confidence: 0.12" "- Affected Services: decoy-svc" "" '```' "## Planner Context" "**Confidence:** 0.11" '```' "" "$REAL_BLOCK")

_pfw_payload() {
  (
    export FAKE_DESC="$1"
    get_issue() { jq -nc --arg d "$FAKE_DESC" '{description: $d}'; }
    tracker_read() {
      shift 3
      "$@"
    }
    # shellcheck source=../planned-feedback-write.sh
    source "$LIB_DIR/planned-feedback-write.sh"
    log="$TMP/pfw-pipeline.log"
    echo "2026-10-01T00:00:00Z|META|outcome-label|info|Smooth" >"$log"
    FROM_PLANNED=true planned_feedback_write "TEST-1" "$log" >/dev/null 2>&1 || true
    grep '|META|planner-feedback|info|' "$log" | tail -1 | cut -d'|' -f5-
  )
}

payload=$(_pfw_payload "$DECOY_DESC")
_eq "planned-feedback-write: confidence_predicted equals generated **Confidence:**" "0.84" "$(echo "$payload" | jq -r '.confidence_predicted')"
_eq "planned-feedback-write: services from real block" '["billing-api","ledger"]' "$(echo "$payload" | jq -c '.services_touched')"

payload=$(_pfw_payload "# no block here")
_eq "planned-feedback-write: no block → confidence 0" "0" "$(echo "$payload" | jq -r '.confidence_predicted')"

payload=$(_pfw_payload "$(printf '%s\n' "## Planner Context" '**Confidence:** 0.8; rm -rf /')")
_eq "planned-feedback-write: non-numeric confidence → 0, payload still built" "0" "$(echo "$payload" | jq -r '.confidence_predicted')"

payload=$(_pfw_payload "$(printf '%s\n' "## Planner Context" '**Confidence:** 00.5')")
_eq "planned-feedback-write: leading-zero confidence → 0, payload still built" "0" "$(echo "$payload" | jq -r '.confidence_predicted')"

# ── Consumer: fleet-controller fleet-feedback.sh ───────────────────────────────

_fc_conf() {
  (
    export FAKE_DESC="$1"
    get_issue() { jq -nc --arg d "$FAKE_DESC" '{description: $d}'; }
    tracker_read() {
      shift 3
      "$@"
    }
    # shellcheck source=../../../fleet-controller/lib/fleet-feedback.sh
    source "$FC_LIB_DIR/fleet-feedback.sh"
    _fleet_confidence_predicted "TEST-1"
  )
}

_eq "fleet-feedback: decoys above real block ignored" "0.84" "$(_fc_conf "$DECOY_DESC")"
_eq "fleet-feedback: missing block → null" "null" "$(_fc_conf "# nothing")"
_eq "fleet-feedback: non-numeric → null" "null" "$(_fc_conf "$(printf '%s\n' "## Planner Context" "**Confidence:** high")")"
_eq "fleet-feedback: CRLF body" "0.84" "$(_fc_conf "$(printf '%s\r\n' "## Planner Context" "**Confidence:** 0.84")")"

# ── Static guard: no consumer uses the old unanchored sed range ────────────────

leftover=$(grep -rln "sed -n '/## Planner Context/" "$LIB_DIR"/*.sh "$FC_LIB_DIR"/*.sh 2>/dev/null || true)
_eq "no unanchored Planner Context sed range left in lib/" "" "$leftover"

leftover=$(grep -rln -- '-\\s\*Confidence:' "$LIB_DIR"/*.sh "$FC_LIB_DIR"/*.sh 2>/dev/null || true)
_eq "no consumer reads the '- Confidence:' bullet shape" "" "$leftover"

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
