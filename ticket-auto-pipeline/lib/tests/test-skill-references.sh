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

# ticket-verify (group 3): each mode reference is read only for its mode, on
# every way into the moved steps; browser mode reads neither; the report
# templates load at report time; the inline contracts stay inline.
test_verify_mode_reference_condition() {
  local md="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-verify/SKILL.md"
  local rel line tok h sec cond1e
  # shellcheck source=skill-text.sh
  source "$SCRIPT_DIR/skill-text.sh"
  for rel in references/build-only.md references/live-backend.md; do
    line=$(grep -F -- "$rel" "$md" | grep -F 'skill-ref.sh' | head -1)
    [ -n "$line" ] || {
      echo "  no conditional line for $rel"
      return 1
    }
    for tok in 'VERIFY_MODE=build-only' 'VERIFY_MODE=live-backend' 'before Step 2' \
      '--from-step' 'build-plan' 'execute-steps' 'Read the printed path in full' \
      'reference-missing' 'In `browser` mode, read neither'; do
      grep -qF -- "$tok" <<<"$line" || {
        echo "  conditional line for $rel lacks: $tok"
        return 1
      }
    done
  done
  # The condition sits right after Step 1e's detection, before Step 1.5.
  cond1e=$(_section "$md" '^### 1f ' '^## Step 1[.]5')
  grep -qF 'references/build-only.md' <<<"$cond1e" || {
    echo "  Step 1f does not hold the mode condition"
    return 1
  }
  # A resume skips Step 1e, so 1f recovers the mode from the log.
  grep -qF '|VERIFY|load-context|done|' <<<"$cond1e" || {
    echo "  Step 1f does not say how a resume recovers VERIFY_MODE"
    return 1
  }
  # Each moved section keeps its heading over a stub.
  for h in '^### 2 [(]build-only variant[)]' '^## Step 4c — '; do
    sec=$(_section "$md" "$h" '^##')
    grep -q '^Moved to `references/build-only.md`' <<<"$(sed 1d <<<"$sec")" || {
      echo "  no build-only stub under $h"
      return 1
    }
  done
  for h in '^### 2 [(]live-backend variant[)]' '^## Step 4c-live '; do
    sec=$(_section "$md" "$h" '^##')
    grep -q '^Moved to `references/live-backend.md`' <<<"$(sed 1d <<<"$sec")" || {
      echo "  no live-backend stub under $h"
      return 1
    }
  done
  # The resume row names both mode references.
  grep -F '| `execute-steps` |' "$md" | grep -F 'references/build-only.md' |
    grep -qF 'references/live-backend.md' || {
    echo "  execute-steps dispatch row does not name the mode references"
    return 1
  }
  # Templates load at report time (Step 5), not at skill start.
  line=$(grep -nF 'references/templates.md' "$md" | grep -F 'skill-ref.sh' | head -1 | cut -d: -f1)
  sec=$(_section "$md" '^## Step 5 ' '^## Step 6 ' | grep -F 'skill-ref.sh' | grep -cF 'references/templates.md' || true)
  [ -n "$line" ] && [ "$sec" -ge 1 ] || {
    echo "  templates.md is not read under a Step 5 condition"
    return 1
  }
  # Inline contracts (design D4).
  for h in '^## Step 4 ' '^## Step 4b ' '^## Step 6 ' '^### 7f '; do
    grep -qE "$h" "$md" || {
      echo "  heading left SKILL.md: $h"
      return 1
    }
  done
  for tok in 'No test user found' 'Checkpoint resume (deterministic)' 'verify_record_verdict "{VERIFY_MODE}" PASS' \
    'verify_record_verdict "{VERIFY_MODE}" FAIL' '`build-only` → `build_only`' '`live-backend` → `live_backend`' 'record_pr_created --new' 'flow-run.sh --log-file "{LOG_FILE}" {TICKET-ID} uat-pass'; do
    grep -qF -- "$tok" "$md" || {
      echo "  inline contract left SKILL.md: $tok"
      return 1
    }
  done
  # The mode references hold no browser-mode material.
  for rel in build-only live-backend; do
    rel="$(dirname "$md")/references/$rel.md"
    [ -f "$rel" ] || {
      echo "  missing $rel"
      return 1
    }
    ! grep -q 'mcp__playwright__' "$rel" || {
      echo "  ${rel##*/} names a Playwright tool"
      return 1
    }
  done
}

# ticket-appraise-exec (group 4): a simple ticket reads only the simple-fix
# template, a complex ticket only the adversarial prompt and the verification
# plan derivation. Explicit paths: _SKILL_TEXT_SKILLS_DIR may point at a
# sandbox left by an earlier test.
test_appraise_exec_complexity_condition() {
  local md="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-appraise-exec/SKILL.md"
  local refs line tok h sec rel
  refs="$(dirname "$md")/references"
  # shellcheck source=skill-text.sh
  source "$SCRIPT_DIR/skill-text.sh"
  line=$(grep -F 'references/simple-fix-template.md' "$md" | grep -F 'skill-ref.sh' | head -1)
  [ -n "$line" ] || {
    echo "  no conditional line"
    return 1
  }
  for tok in '`{COMPLEXITY}` = simple' '`{COMPLEXITY}` = complex' 'references/adversarial-review.md' \
    'references/verification-plan.md' 'before Step 3.6' 'before Step 3.7' '--from-step' \
    'create-artifact' 'verify-plan-derived' 'reference-missing' 'Read each printed path in full'; do
    grep -qF -- "$tok" <<<"$line" || {
      echo "  conditional line lacks: $tok"
      return 1
    }
  done
  # The condition sits in Step 3, before Step 3-Simple.
  sec=$(_section "$md" '^## Step 3 — ' '^### Step 3-Simple')
  grep -qF 'skill-ref.sh ticket-appraise-exec references/verification-plan.md' <<<"$sec" || {
    echo "  Step 3 does not hold the complexity condition"
    return 1
  }
  # Each moved section keeps its heading over a stub.
  for h in '^### Step 3-Simple:references/simple-fix-template.md' \
    '^## Step 3[.]6 :references/adversarial-review.md' \
    '^## Step 3[.]7 :references/verification-plan.md'; do
    rel=${h#*:}
    sec=$(_section "$md" "${h%%:*}" '^## ')
    grep -q "^Moved to \`$rel\`" <<<"$sec" || {
      echo "  no stub for $rel under ${h%%:*}"
      return 1
    }
  done
  # Resume rows that skip Step 3 name the references.
  grep -F '| `create-artifact` |' "$md" | grep -F 'references/adversarial-review.md' |
    grep -qF 'references/verification-plan.md' || {
    echo "  create-artifact dispatch row does not name the complex references"
    return 1
  }
  grep -F '| `verify-plan-derived` |' "$md" | grep -qF 'references/verification-plan.md' || {
    echo "  verify-plan-derived dispatch row does not name verification-plan.md"
    return 1
  }
  # Inline contracts: the notes.md schema read by vplan-parse.sh / gate-check,
  # the Step 5 comment, the ADVERSARIAL_BLOCKED prefix and the round counter.
  for tok in '**Derived by:** ticket-appraise-exec Step 3.7' '### Per-Criterion Verification' \
    '<!-- ticket-auto:appraisal -->' '## Role Scope Registry' 'adversarial_round_count' \
    'ADVERSARIAL_BLOCKED — round {ADV_ROUND}' 'write_verifier_result verifier=adversarial_review' \
    'Keep going — do not stop here' 'EXEC_NO_ARTIFACT' 'COMPLEXITY_ARTIFACT_MISMATCH'; do
    grep -qiF -- "$tok" "$md" || {
      echo "  inline contract left SKILL.md: $tok"
      return 1
    }
  done
  # Each reference holds what it is named for, and nothing of the others.
  grep -qF '## Completion Checklist' "$refs/simple-fix-template.md" &&
    grep -qF 'You are an adversarial reviewer' "$refs/adversarial-review.md" &&
    grep -qF '### 8. Approach review' "$refs/adversarial-review.md" &&
    grep -qF 'VERIFY_PLAN_NO_ROLE_SCOPE' "$refs/verification-plan.md" || {
    echo "  a reference lost its moved text"
    return 1
  }
  ! grep -qF -- '**Derived by:**' "$refs/verification-plan.md" || {
    echo "  verification-plan.md carries the notes.md schema"
    return 1
  }
}

test_implement_feedback_rework_condition() {
  local md="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-implement/SKILL.md"
  local refs line tok h sec rel
  refs="$(dirname "$md")/references"
  # shellcheck source=skill-text.sh
  source "$SCRIPT_DIR/skill-text.sh"
  line=$(grep -F 'references/rework.md' "$md" | grep -F 'skill-ref.sh' | head -1)
  for tok in '`FAIL_COUNT` > `SECTION_COUNT`' '--from-step' 'detect-path' 'checkout-branch' '`implement`'; do
    grep -qF -- "$tok" <<<"$line" || {
      echo "  rework conditional line lacks: $tok"
      return 1
    }
  done
  line=$(grep -F 'references/feedback.md' "$md" | grep -F 'skill-ref.sh' | head -1)
  for tok in 'Step 4c' 'complexity mismatch' 'wiki gap'; do
    grep -qF -- "$tok" <<<"$line" || {
      echo "  feedback conditional line lacks: $tok"
      return 1
    }
  done
  sec=$(_section "$md" '^### Reference files [(]load condition[)]' '^## Step 0[.]6')
  for tok in 'REWORK_OPEN=' 'reference-missing' 'Read each printed path in full'; do
    grep -qF -- "$tok" <<<"$sec" || {
      echo "  load condition lacks: $tok"
      return 1
    }
  done
  # Each moved section keeps its heading over a stub.
  for h in '^## Step 2[.]5 :references/rework.md' '^### Part B :references/rework.md' \
    '^### Post-implement:references/feedback.md' '^### Part 3 :references/feedback.md' \
    '^### Part 4 :references/feedback.md'; do
    rel=${h#*:}
    sec=$(_section "$md" "${h%%:*}" '^##')
    grep -q "^Moved to \`$rel\`" <<<"$sec" || {
      echo "  no stub for $rel under ${h%%:*}"
      return 1
    }
  done
  # Resume rows that skip Step 2.5 name the rework reference.
  for tok in detect-path checkout-branch implement; do
    grep -F "| \`$tok\` |" "$md" | grep -qF 'references/rework.md' || {
      echo "  $tok dispatch row does not name rework.md"
      return 1
    }
  done
  # Inline contracts every path needs: the verifier id, the outcome trigger,
  # the mismatch definition, the Part 3 wiki check and the no-halt rule.
  for tok in 'write_verifier_result verifier=implement_tests' 'implement-outcome --data outcome=' \
    '`simple` + `Rough`/`Hard`, or `complex` + `Smooth`' 'Wiki bootstrap:' \
    'META|wiki-check|info|wiki consulted, no gap found' 'never halts' \
    'Keep the `PERSONA_TYPE` value printed above'; do
    grep -qF -- "$tok" "$md" || {
      echo "  inline contract left SKILL.md: $tok"
      return 1
    }
  done
  # Each reference holds what it is named for.
  grep -qF 'REMEDIATION_BRIEF_TRUNCATED' "$refs/rework.md" &&
    grep -qF '## UAT Rework Context' "$refs/rework.md" &&
    grep -qF -- '--remediation' "$refs/rework.md" &&
    grep -qF '**Complexity mismatch**' "$refs/feedback.md" &&
    grep -qF '**Gap:**' "$refs/feedback.md" &&
    grep -qF 'append_correction wiki failed' "$refs/feedback.md" || {
    echo "  a reference lost its moved text"
    return 1
  }
}

# The REMEDIATION_BRIEF block (Step 7c) is parsed by ticket-implement and fix
# skills; skill-progressive-disclosure keeps it inline and byte-identical.
# Changing the block on purpose means updating this hash in the same PR.
test_verify_remediation_brief_unchanged() {
  local md="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-verify/SKILL.md" got
  got=$(awk '/^### 7c /{f=1} f&&/^```/{c++; if(c==2){print; exit}} f&&c>=1' "$md" | sha256sum | cut -d' ' -f1)
  [ "$got" = 950059a48475453c27de838df726990f3a214142ea9e9a26f18bc3647eb6c1aa ] || {
    echo "  Step 7c REMEDIATION_BRIEF block changed (sha256 $got)"
    return 1
  }
}

test_setup_project_init_condition() {
  local md="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-setup/SKILL.md"
  local ref line tok
  ref="$(dirname "$md")/references/project-init.md"
  line=$(grep -F 'references/project-init.md' "$md" | grep -F 'skill-ref.sh' | head -1)
  for tok in 'Only if `CLAUDE.md` is missing' 'Step 0.5' 'never initialize CLAUDE.md from memory'; do
    grep -qF -- "$tok" <<<"$line" || {
      echo "  project-init conditional line lacks: $tok"
      return 1
    }
  done
  # Steps every run takes stay inline: env check, root detection, the
  # CLAUDE.md-exists skip, GitNexus indexing and the readiness heartbeat.
  for tok in 'env-check.sh --mode=validate' '### Step 0.2 ' 'Skip to Step 0.5' \
    '### Step 0.5 ' 'heartbeat|project-init|ok|project ready' '--from-auto'; do
    grep -qF -- "$tok" "$md" || {
      echo "  inline contract left SKILL.md: $tok"
      return 1
    }
  done
  for tok in '#### Step 0.4a ' '#### Step 0.4b ' '#### Step 0.4c ' 'claude init'; do
    grep -qF -- "$tok" "$ref" || {
      echo "  project-init.md lost: $tok"
      return 1
    }
    ! grep -qF -- "$tok" "$md" || {
      echo "  moved text still in SKILL.md: $tok"
      return 1
    }
  done
}

test_retro_github_issues_condition() {
  local md="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-retro/SKILL.md"
  local ref line tok
  ref="$(dirname "$md")/references/github-issues.md"
  line=$(grep -F 'references/github-issues.md' "$md" | grep -F 'skill-ref.sh' | head -1)
  for tok in 'Only with `--post-to-github`' 'skip Step 5.5' 'never post issues from memory'; do
    grep -qF -- "$tok" <<<"$line" || {
      echo "  github-issues conditional line lacks: $tok"
      return 1
    }
  done
  # The conditional line sits under Step 4, before the Step 5.5 stub.
  _section "$md" '^### Section: GitHub Issues' '^## Step 5 ' | grep -qF 'skill-ref.sh' || {
    echo "  github-issues.md is not read under the Step 4 GitHub Issues section"
    return 1
  }
  # Text every run needs stays inline: the flag, the 3b.5 severity pointer,
  # the proposal verify and the completion summary line rules.
  for tok in '--post-to-github`: if present' '### 3b.5 ' '**Proposal verify**' \
    'If `--post-to-github` was not used: omitted entirely'; do
    grep -qF -- "$tok" "$md" || {
      echo "  inline contract left SKILL.md: $tok"
      return 1
    }
  done
  for tok in '### 5.5a ' '### 5.5c ' 'github_retro_process' 'GitHub posting skipped'; do
    grep -qF -- "$tok" "$ref" || {
      echo "  github-issues.md lost: $tok"
      return 1
    }
    ! grep -qF -- "$tok" "$md" || {
      echo "  moved text still in SKILL.md: $tok"
      return 1
    }
  done
}

test_wiki_errata_adr_conditions() {
  local md="$REPO_ROOT/ticket-auto-pipeline/skills/wiki-maintenance/SKILL.md"
  local dir ref line tok
  # shellcheck source=skill-text.sh
  source "$SCRIPT_DIR/skill-text.sh"
  dir="$(dirname "$md")/references"
  # Step 2b: read only with errata or a source=wiki/prescan correction.
  line=$(_section "$md" '^### 2b ' '^### 2c ' | grep -F 'references/errata-fix.md' | grep -F 'skill-ref.sh')
  for tok in 'Only when Step 1 found unresolved errata' 'source=prescan' \
    'reference-missing fail "references/errata-fix.md"' 'never apply a fix from memory'; do
    grep -qF -- "$tok" <<<"$line" || {
      echo "  errata-fix conditional line (under 2b) lacks: $tok"
      return 1
    }
  done
  # 2.5c Decisions: read only for a surviving Decisions-section finding.
  line=$(_section "$md" '^#### Decisions-section findings' '^#### Ordinary prose path' |
    grep -F 'references/adr-decisions.md' | grep -F 'skill-ref.sh')
  for tok in 'Only when a surviving finding comes from the Decisions section' \
    'reference-missing fail "references/adr-decisions.md"' 'from memory'; do
    grep -qF -- "$tok" <<<"$line" || {
      echo "  adr-decisions conditional line (under 2.5c) lacks: $tok"
      return 1
    }
  done
  # Every-run text stays inline: Step 2c, the 2.5c idempotency check and
  # prose path, Step 2.6 and the Step 0/Step 4 lock wiring.
  for tok in '### 2c — Mark resolved' 'Idempotency check (task 6.3)' \
    '#### Ordinary prose path' '## Step 2.6 ' 'wiki-lock.sh" acquire' \
    '"$_wlock" commit' '"$_wlock" release'; do
    grep -qF -- "$tok" "$md" || {
      echo "  inline contract left SKILL.md: $tok"
      return 1
    }
  done
  for ref in errata-fix.md:'| Gap type |' errata-fix.md:'verified: machine-verified' \
    errata-fix.md:'Lookup by Service' adr-decisions.md:'**`GOVERNED`**' \
    adr-decisions.md:'ARCH_COMMITMENT' adr-decisions.md:'gate-stop per § 8'; do
    tok="${ref#*:}"
    grep -qF -- "$tok" "$dir/${ref%%:*}" || {
      echo "  ${ref%%:*} lost: $tok"
      return 1
    }
    ! grep -qF -- "$tok" "$md" || {
      echo "  moved text still in SKILL.md: $tok"
      return 1
    }
  done
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
