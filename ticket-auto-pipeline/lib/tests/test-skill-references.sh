#!/usr/bin/env bash
# test-skill-references.sh — the references/ convention
# (skill-progressive-disclosure, spec skill-reference-files).
#
# For every <plugin>/skills/<skill>/references/<file>.md in the repo:
#   1. SKILL.md names the literal `references/<file>.md` path.
#   2. SKILL.md has a conditional read line: one that names that path and
#      calls skill-ref.sh (the resolver), never ${CLAUDE_PLUGIN_ROOT} or a
#      hard-coded ~/.claude/skills/<skill>/references/ path.
#   3. That conditional line comes before the first moved-step heading — the
#      heading over a "Moved to `references/<file>.md`" stub — so an agent
#      reading top-down meets the condition before the step it covers.
#   4. ticket-auto-pipeline only: every prompt_manifests entry that lists the
#      skill's SKILL.md also lists the reference, in the run of reference
#      entries directly after SKILL.md. That covers a skill with its own key
#      and a host skill's manifest (ticket-critique / ticket-setup references
#      are registered in ticket-appraise's). Other plugins have no manifest.
#
# gate rule 8 (scripts/check-skill-size.sh REF-*) already covers dead links,
# chains, `## Contents` and bare $1/$ARGUMENTS; this test covers the parts
# that need the manifest or the step layout.
#
# The checker runs on the real tree and on sandbox fixtures, so it is proven
# to fire while the repo still has no references/ files.
#
# Usage: bash test-skill-references.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
FILTER="${1:-}"

_run() {
  local name="$1"
  shift
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
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

# Sandboxes are made inside $(...) subshells, so they live under one root the
# main shell owns and removes.
_TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$_TMP_ROOT"' EXIT

# _check_references <root> — print one "VIOLATION: ..." line per problem and
# return 1 when there is any. Prints "CHECKED: <n>" with the reference count.
_check_references() {
  local root="$1" n=0 bad=0 ref sdir skill plugin fname rel md table
  local cond first_stub
  while IFS= read -r ref; do
    n=$((n + 1))
    sdir="$(dirname "$(dirname "$ref")")"
    skill="$(basename "$sdir")"
    plugin="$(basename "$(dirname "$(dirname "$sdir")")")"
    fname="$(basename "$ref")"
    rel="references/$fname"
    md="$sdir/SKILL.md"
    if [ ! -f "$md" ]; then
      echo "VIOLATION: $plugin/$skill has $rel but no SKILL.md"
      bad=1
      continue
    fi

    # 1. literal mention
    if ! grep -qF -- "$rel" "$md"; then
      echo "VIOLATION: $plugin/$skill SKILL.md never names $rel"
      bad=1
    fi

    # 2. no plugin-root or hard-coded skill-dir path to a reference
    if grep -nE "CLAUDE_PLUGIN_ROOT[^[:space:]]*/references/|~/\.claude/skills/[A-Za-z0-9._-]+/references/" "$md" >/dev/null; then
      echo "VIOLATION: $plugin/$skill SKILL.md reaches a reference without skill-ref.sh"
      bad=1
    fi
    cond=$(grep -nF -- "$rel" "$md" | grep -F 'skill-ref.sh' | head -1 | cut -d: -f1 || true)
    if [ -z "$cond" ]; then
      echo "VIOLATION: $plugin/$skill SKILL.md has no conditional read line for $rel (needs the path and skill-ref.sh on one line)"
      bad=1
    fi

    # 3. conditional line before the first moved-step heading
    first_stub=$(awk -v r="$rel" '
      /^#+[[:space:]]/ { h = NR }
      /^Moved to / && index($0, r) && h { print h; exit }
    ' "$md")
    if [ -n "$cond" ] && [ -n "$first_stub" ] && [ "$cond" -ge "$first_stub" ]; then
      echo "VIOLATION: $plugin/$skill conditional line for $rel (line $cond) is after the first moved step (line $first_stub)"
      bad=1
    fi

    # 4. manifest registration
    table="$root/$plugin/skills/ticket-flow/dispatch-table.json"
    if [ "$plugin" = ticket-auto-pipeline ] && [ -f "$table" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && echo "VIOLATION: $line" && bad=1
      done < <(jq -r --arg md "plugin:skills/$skill/SKILL.md" \
        --arg ref "plugin:skills/$skill/$rel" \
        --arg pre "plugin:skills/$skill/references/" '
        (.prompt_manifests // {}) | to_entries[] | .key as $k | .value.files as $f
        | ($f | index($md)) as $i
        | select($i != null)
        | ($f | index($ref)) as $j
        | if $j == null then "manifest \($k) lists \($md) but not \($ref)"
          elif $j < $i then "manifest \($k) lists \($ref) before \($md)"
          elif ([$f[($i + 1):$j][] | select(startswith($pre) | not)] | length) > 0
            then "manifest \($k): \($ref) is not in the reference run directly after \($md)"
          else empty end' "$table")
    fi
  done < <(find "$root" -path "$root/.git" -prune -o -path '*/fixtures' -prune -o \
    -type f -path '*/skills/*/references/*.md' -print 2>/dev/null | LC_ALL=C sort)
  echo "CHECKED: $n"
  [ "$bad" -eq 0 ]
}

# ── sandbox ──────────────────────────────────────────────────────────────────
# A fake ticket-auto-pipeline with skill alpha (own manifest key, one
# reference) and skill crit (no key; listed inside alpha's manifest).
_sandbox() {
  local sb p
  sb=$(mktemp -d "$_TMP_ROOT/sb.XXXXXX")
  p="$sb/ticket-auto-pipeline/skills"
  mkdir -p "$p/alpha/references" "$p/crit/references" "$p/ticket-flow"
  cat >"$p/alpha/SKILL.md" <<'MD'
---
name: alpha
description: fixture
---
## Step 1

**If fast-path is NOT active**: before Step 2, or resuming at it via `--from-step`, run `bash ~/.claude/skills/lib/skill-ref.sh alpha references/deep.md`, then Read the printed path in full.

## Step 2

Moved to `references/deep.md`, read per the Step 1 condition.
MD
  printf '## Step 2\n\nbody\n' >"$p/alpha/references/deep.md"
  cat >"$p/crit/SKILL.md" <<'MD'
---
name: crit
description: fixture
---
## Step 1

If the ticket is a bug, run `bash ~/.claude/skills/lib/skill-ref.sh crit references/bug.md` and Read the printed path.
MD
  printf 'bug checks\n' >"$p/crit/references/bug.md"
  cat >"$p/ticket-flow/dispatch-table.json" <<'JSON'
{"prompt_manifests": {"alpha": {"files": [
  "plugin:skills/alpha/SKILL.md",
  "plugin:skills/alpha/references/deep.md",
  "plugin:skills/crit/SKILL.md",
  "plugin:skills/crit/references/bug.md",
  "lib:skill-preamble-auto.md"
]}}}
JSON
  printf '%s' "$sb"
}
_skill() { printf '%s' "$1/ticket-auto-pipeline/skills/$2"; }
_table() { printf '%s' "$1/ticket-auto-pipeline/skills/ticket-flow/dispatch-table.json"; }
_edit_table() {
  local t
  t=$(_table "$1")
  jq "$2" "$t" >"$t.new" && mv "$t.new" "$t"
}
# _expect_violation <root> <substring>
_expect_violation() {
  local out
  if out=$(_check_references "$1"); then
    echo "  expected a violation, checker passed"
    return 1
  fi
  grep -qF -- "$2" <<<"$out" || {
    echo "  expected '$2' in:"
    echo "$out" | sed 's/^/    /'
    return 1
  }
}

# ── tests ────────────────────────────────────────────────────────────────────

test_repo_references_follow_the_convention() {
  _check_references "$REPO_ROOT"
}

test_fixture_passes() {
  local sb out
  sb=$(_sandbox)
  out=$(_check_references "$sb") || {
    echo "$out"
    return 1
  }
  grep -qx 'CHECKED: 2' <<<"$out"
}

test_unmentioned_reference_fails() {
  local sb
  sb=$(_sandbox)
  printf 'orphan\n' >"$(_skill "$sb" alpha)/references/orphan.md"
  _edit_table "$sb" '.prompt_manifests.alpha.files |= .[0:2] + ["plugin:skills/alpha/references/orphan.md"] + .[2:]'
  _expect_violation "$sb" "never names references/orphan.md"
}

test_mention_without_resolver_fails() {
  local sb md
  sb=$(_sandbox)
  md="$(_skill "$sb" crit)/SKILL.md"
  sed -i 's#run `bash ~/.claude/skills/lib/skill-ref.sh crit references/bug.md`#read `references/bug.md`#' "$md"
  _expect_violation "$sb" "no conditional read line for references/bug.md"
}

test_plugin_root_path_fails() {
  local sb
  sb=$(_sandbox)
  printf '\nOr read ${CLAUDE_PLUGIN_ROOT}/skills/crit/references/bug.md.\n' >>"$(_skill "$sb" crit)/SKILL.md"
  _expect_violation "$sb" "crit SKILL.md reaches a reference without skill-ref.sh"
}

test_condition_after_moved_step_fails() {
  local sb md
  sb=$(_sandbox)
  md="$(_skill "$sb" alpha)/SKILL.md"
  cat >"$md" <<'MD'
---
name: alpha
description: fixture
---
## Step 2

Moved to `references/deep.md`, read per the Step 3 condition.

## Step 3

If not fast-path, run `bash ~/.claude/skills/lib/skill-ref.sh alpha references/deep.md`.
MD
  _expect_violation "$sb" "is after the first moved step"
}

test_unregistered_reference_fails() {
  local sb
  sb=$(_sandbox)
  _edit_table "$sb" '.prompt_manifests.alpha.files |= map(select(. != "plugin:skills/alpha/references/deep.md"))'
  _expect_violation "$sb" "lists plugin:skills/alpha/SKILL.md but not plugin:skills/alpha/references/deep.md"
}

test_host_manifest_must_register_hosted_reference() {
  local sb
  sb=$(_sandbox)
  _edit_table "$sb" '.prompt_manifests.alpha.files |= map(select(. != "plugin:skills/crit/references/bug.md"))'
  _expect_violation "$sb" "but not plugin:skills/crit/references/bug.md"
}

test_reference_not_directly_after_skill_md_fails() {
  local sb
  sb=$(_sandbox)
  _edit_table "$sb" '.prompt_manifests.alpha.files = [
    "plugin:skills/alpha/SKILL.md", "lib:skill-preamble-auto.md",
    "plugin:skills/alpha/references/deep.md",
    "plugin:skills/crit/SKILL.md", "plugin:skills/crit/references/bug.md"]'
  _expect_violation "$sb" "not in the reference run directly after"
}

test_reference_listed_before_skill_md_fails() {
  local sb
  sb=$(_sandbox)
  _edit_table "$sb" '.prompt_manifests.alpha.files = [
    "plugin:skills/alpha/references/deep.md", "plugin:skills/alpha/SKILL.md",
    "plugin:skills/crit/SKILL.md", "plugin:skills/crit/references/bug.md"]'
  _expect_violation "$sb" "before plugin:skills/alpha/SKILL.md"
}

test_unmanifested_plugin_needs_no_registration() {
  local sb
  sb=$(_sandbox)
  mv "$sb/ticket-auto-pipeline" "$sb/grill-me"
  _check_references "$sb" >/dev/null
}

# ticket-appraise (group 2): the load condition covers every way into the
# moved steps, and what the fast path needs stays in SKILL.md.
test_appraise_full_investigation_condition() {
  local md="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-appraise/SKILL.md"
  local rel="references/full-investigation.md" line tok h sec
  # shellcheck source=skill-text.sh
  source "$SCRIPT_DIR/skill-text.sh"
  line=$(grep -F -- "$rel" "$md" | grep -F 'skill-ref.sh' | head -1)
  [ -n "$line" ] || {
    echo "  no conditional line for $rel"
    return 1
  }
  for tok in 'FAST_PATH_ELIGIBLE=false' 'quick-scan' '--from-step' 'complexity-sweep' 'prior-art' \
    'Resume mode' 'Read the printed path in full' 'reference-missing'; do
    grep -qF -- "$tok" <<<"$line" || {
      echo "  conditional line lacks: $tok"
      return 1
    }
  done
  # Each moved step keeps its heading over a stub naming the reference.
  for h in '^## Step 2 — ' '^## Step 2\.5 ' '^## Step 2\.6 ' '^## Step 3 — ' '^## Step 3-Agent '; do
    sec=$(_section "$md" "$h" '^## ')
    grep -q "^Moved to \`$rel\`" <<<"$(sed 1d <<<"$sec")" || {
      echo "  no stub under $h"
      return 1
    }
  done
  # Fast path reads these from SKILL.md alone: the Step 2.5 rubric (1.3c
  # Reversibility judgement, 2.8 threshold) and the Step 2 tagging rule.
  sec=$(_section "$md" '^## Step 2\.5 ' '^## Step 2\.6 ')
  for tok in '| **Reversibility**' '**3 or more**' 'framework-migration'; do
    grep -qF -- "$tok" <<<"$sec" || {
      echo "  Step 2.5 rubric left SKILL.md: $tok"
      return 1
    }
  done
  sec=$(_section "$md" '^## Step 2 — ' '^## Step 2\.1 ')
  grep -qF '**Open Questions tagging.**' <<<"$sec" || {
    echo "  Step 2 tagging rule left SKILL.md"
    return 1
  }
  # quick-scan and Resume mode name the reference where they act.
  grep -F '| `quick-scan` |' "$md" | grep -qF -- "$rel" || {
    echo "  quick-scan row does not name $rel"
    return 1
  }
  _section "$md" '^## Resume mode' | grep -F 'Re-evaluate complexity' | grep -qF -- "$rel" || {
    echo "  Resume mode step 6 does not name $rel"
    return 1
  }
}

test_shared_section_ref_helper() {
  local out
  # shellcheck source=skill-text.sh
  source "$SCRIPT_DIR/skill-text.sh"
  _SKILL_TEXT_SKILLS_DIR="$(_sandbox)/ticket-auto-pipeline/skills"
  out=$(_section_ref alpha/references/deep.md '^## Step 2') || return 1
  grep -qx 'body' <<<"$out" || return 1
  # A missing reference is an error, not an empty slice.
  ! _section_ref alpha/references/gone.md '^## Step 2' 2>/dev/null || return 1
  ! _section_ref alpha/SKILL.md '^## Step 2' 2>/dev/null
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  _run "$t" "$t"
done

echo
echo "=== test-skill-references.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
