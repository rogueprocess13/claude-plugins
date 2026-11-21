#!/usr/bin/env bash
# planner-crosscheck-body.sh — the Crosscheck ticket-body family (GitHub #773).
#
# Checks the ticket-body-v2 rules of planner-body-template.sh on every spec
# of an initiative that carries the `ticket-body-v2` contract marker. Silent
# without the marker, so a legacy or in-flight initiative is unchanged.
#
# Codes, one finding per spec (INDEX.md and synth-marked test-data specs are
# skipped):
#
#   VERIFY_MODE_INVALID   blocking  no `## Verify Mode` section, or its first
#                                   line is not `**Verify mode:** <shape>`
#                                   with one of the five shapes
#                                   ticket-auto's verify-mode.sh accepts
#   EDGE_CASES_MISSING    blocking  a feature or improvement spec, or one
#                                   whose verify mode is api-only or
#                                   live-backend, has no non-empty
#                                   `## Errors and Edge Cases` section
#   SCOPE_TC_MISMATCH     warn      a file `## Technical Context` names is not
#                                   in `## Scope`, or a Scope file is neither
#                                   named in Technical Context nor marked
#                                   `(read-only)`
#   AC_COUNT_HIGH         warn      more than PLANNER_AC_SOFT_CAP criteria
#   AC_UNTAGGED           warn      criteria with no leading [unit] / [live]
#   AC_POST_MERGE_STATE   warn      a criterion refers to a state after merge
#                                   or to a base branch
#
# and one for the initiative:
#
#   SECURITY_DECISIONS_MISSING  warn  proposal.md talks about sign-in,
#                                     passwords, tokens, secrets or personal
#                                     data and has no non-empty
#                                     `## Security & Identity Decisions`
#
# The two blocking codes are exact structural checks of sections the Specify
# prompt requires and its own self-lint runs. The warn codes are pattern
# matches over prose; they never block.
#
# Usage:
#   planner_crosscheck_body <initiative_id>
#     Returns: 0 if clean, 1 if any finding was reported.
#
# Sourceable library — no set -euo pipefail.

# Units judged (planner-halt-recall): planner_crosscheck_units_add is a no-op
# unless planner_crosscheck_run set PLANNER_CROSSCHECK_UNITS_FILE.
if ! declare -f planner_crosscheck_units_add >/dev/null 2>&1; then
  # shellcheck source=planner-crosscheck-units.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/planner-crosscheck-units.sh"
fi

_PLANNER_CROSSCHECK_BODY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f planner_body_verify_mode >/dev/null 2>&1; then
  # shellcheck source=planner-body-template.sh
  source "${_PLANNER_CROSSCHECK_BODY_LIB_DIR}/planner-body-template.sh"
fi

# A criterion that can only be true after merge, or names a base branch.
_PLANNER_XCB_POST_MERGE_RE='(after|once|when)( it| this| the (pr|pull request|branch|change|ticket))?( is| has been| gets)? merged|post-merge|after (the )?merge\b|\b(on|in|into|to|against) (the )?(`(develop|main|master)`|(develop|main|master) branch)'
# proposal.md wording that means the plan touches auth or user data.
_PLANNER_XCB_SECURITY_RE='\b(passwords?|jwt|sign[- ]?up|sign[- ]?in|log[- ]?in|credentials?|(access|auth|bearer|refresh|session) tokens?|session cookies?|api keys?|secrets?|personal data|pii)\b'

# Text made safe for a state-log message and a one-line report.
_planner_xcb_safe() {
  printf '%s' "$1" | tr '|\r\n' '   ' | sed -E 's/"/'"'"'/g'
}

# "`a`, `b`" from newline-separated names, at most 6 then "and N more".
_planner_xcb_list() {
  awk 'NF { n++; if (n <= 6) out = out (n > 1 ? ", " : "") "`" $0 "`" }
       END { if (n > 6) out = out " and " (n - 6) " more"; print out }'
}

# The Scope <-> Technical Context comparison of one spec. Prints the finding
# detail, or nothing when the two sections agree.
_planner_xcb_scope_detail() {
  local spec="$1" f mode g hit missing="" extra=""
  local -a tc=() sc=() sc_mode=()
  while IFS=$'\t' read -r f mode; do
    [ -n "$f" ] && tc+=("$f")
  done < <(planner_body_files "$spec" "technical context")
  while IFS=$'\t' read -r f mode; do
    [ -n "$f" ] || continue
    sc+=("$f")
    sc_mode+=("$mode")
  done < <(planner_body_files "$spec" "scope")

  for f in "${tc[@]}"; do
    hit=0
    for g in "${sc[@]}"; do
      planner_body_file_match "$f" "$g" && hit=1 && break
    done
    [ "$hit" -eq 1 ] || missing+="${f}"$'\n'
  done
  local i
  for i in "${!sc[@]}"; do
    [ "${sc_mode[$i]}" = "ro" ] && continue
    hit=0
    for g in "${tc[@]}"; do
      planner_body_file_match "${sc[$i]}" "$g" && hit=1 && break
    done
    [ "$hit" -eq 1 ] || extra+="${sc[$i]}"$'\n'
  done

  local out=""
  [ -n "$missing" ] && out="named in Technical Context but not in the Scope table: $(_planner_xcb_list <<<"$missing")"
  if [ -n "$extra" ]; then
    [ -n "$out" ] && out+="; "
    out+="in the Scope table but neither named in Technical Context nor marked (read-only): $(_planner_xcb_list <<<"$extra")"
  fi
  printf '%s' "$out"
}

# Usage: planner_crosscheck_body_one <spec_file>
planner_crosscheck_body_one() {
  local spec="$1" base shape rc type need total untagged first hit detail found=0
  base="$(basename "$spec")"
  local p="planner-crosscheck-body:"

  planner_crosscheck_units_add body
  shape=$(planner_body_verify_mode "$spec")
  rc=$?
  case "$rc" in
  1)
    echo "${p} VERIFY_MODE_INVALID ${base} has no ## Verify Mode section — add it with the first line **Verify mode:** <shape> (one of: ${PLANNER_VERIFY_MODE_SHAPES// /, })"
    found=1
    ;;
  2)
    echo "${p} VERIFY_MODE_INVALID ${base} ## Verify Mode does not start with **Verify mode:** <shape> — the shape is exactly one of: ${PLANNER_VERIFY_MODE_SHAPES// /, }"
    found=1
    ;;
  esac

  type=$(planner_body_spec_type "$spec")
  need=""
  case "$type" in feature | improvement) need="a ${type} spec" ;; esac
  case "$shape" in api-only | live-backend) need="${need:-a ${shape} spec}" ;; esac
  if [ -n "$need" ] && ! planner_body_section "$spec" "errors and edge cases" | grep -q '[^[:space:]]'; then
    echo "${p} EDGE_CASES_MISSING ${base} is ${need} with no ## Errors and Edge Cases section — answer its five prompts (failure, check order, empty or malformed input, late or concurrent responses, unauthorised viewer), each with the behaviour or Not applicable"
    found=1
  fi

  detail=$(_planner_xcb_scope_detail "$spec")
  if [ -n "$detail" ]; then
    echo "${p} SCOPE_TC_MISMATCH ${base} $(_planner_xcb_safe "$detail")"
    found=1
  fi

  total=$(planner_body_ac_items "$spec" | grep -c . || true)
  if [ "${total:-0}" -gt "$PLANNER_AC_SOFT_CAP" ]; then
    echo "${p} AC_COUNT_HIGH ${base} has ${total} acceptance criteria (soft cap ${PLANNER_AC_SOFT_CAP}) — group field checks into one criterion per response or behaviour, or split the ticket"
    found=1
  fi

  untagged=$(planner_body_ac_items "$spec" | grep -cvE '^\[(unit|live)\] ' || true)
  if [ "${untagged:-0}" -gt 0 ]; then
    first=$(planner_body_ac_items "$spec" | grep -vE '^\[(unit|live)\] ' | head -1)
    echo "${p} AC_UNTAGGED ${base} ${untagged} of ${total} acceptance criteria have no [unit] or [live] tag — first: \"$(_planner_xcb_safe "${first:0:120}")\""
    found=1
  fi

  hit=$(planner_body_ac_items "$spec" | grep -iE -m1 -- "$_PLANNER_XCB_POST_MERGE_RE" || true)
  if [ -n "$hit" ]; then
    echo "${p} AC_POST_MERGE_STATE ${base} a criterion refers to a state after merge or to a base branch, which cannot hold on the PR branch — \"$(_planner_xcb_safe "${hit:0:160}")\""
    found=1
  fi

  [ "$found" -eq 0 ]
}

# Usage: planner_crosscheck_body_proposal <proposal.md>
planner_crosscheck_body_proposal() {
  local proposal="$1" hit
  [ -f "$proposal" ] || return 0
  hit=$(tr -d '\r' <"$proposal" | awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    !fence { print }
  ' | grep -ioE -m1 -- "$_PLANNER_XCB_SECURITY_RE" | head -1 || true)
  [ -n "$hit" ] || return 0
  local section
  section=$(planner_body_section "$proposal" "security & identity decisions")
  [ -n "$section" ] || section=$(planner_body_section "$proposal" "security and identity decisions")
  grep -q '[^[:space:]]' <<<"$section" && return 0
  echo "planner-crosscheck-body: SECURITY_DECISIONS_MISSING proposal.md mentions \"$(_planner_xcb_safe "$hit")\" and has no ## Security & Identity Decisions section — list identifier normalisation, secret and config policy per environment, and token handling, each as a policy row of ## Parameters, never as an assumption"
  return 1
}

# Usage: planner_crosscheck_body <initiative_id>
planner_crosscheck_body() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-}"
  [ -n "$repos_root" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  planner_body_contract_initiative "$initiative_id" || return 0
  local artifacts="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts"
  local specs_dir="${artifacts}/specs"

  local spec_file found=0
  planner_crosscheck_body_proposal "${artifacts}/proposal.md" || found=1
  [ -d "$specs_dir" ] || return "$found"
  for spec_file in "$specs_dir"/*.md; do
    planner_body_spec_checked "$spec_file" || continue
    planner_crosscheck_body_one "$spec_file" || found=1
  done
  [ "$found" -eq 0 ]
}
