#!/usr/bin/env bash
# test-check-skill-size.sh — self-test for the skill-size drift gate. Each case
# builds a throwaway repo fixture (one skill, an agent, a preamble, a persona,
# a reference file, a decoy under fixtures/ and a minimal dispatch table),
# records its baseline with --regenerate, mutates it, and asserts the gate's
# exit code and message.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../check-skill-size.sh"

PASS=0
FAIL=0
D=""

_ok() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
_ko() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}
trap '[ -z "$D" ] || rm -rf "$D"' EXIT

# _skill <path> <name> <body-lines> — a valid SKILL.md with N short body lines.
_skill() {
  mkdir -p "$(dirname "$1")"
  {
    printf -- '---\nname: %s\ndescription: Does one small thing for the test fixture.\n---\n' "$2"
    for ((i = 1; i <= $3; i++)); do echo "line $i"; done
  } >"$1"
}

# _fence <n> [indent] — a bash fence with n body lines.
_fence() {
  echo "${2:-}\`\`\`bash"
  for ((i = 1; i <= $1; i++)); do echo "${2:-}echo $i"; done
  echo "${2:-}\`\`\`"
}

_mk_repo() {
  D="$(mktemp -d)"
  local p="$D/plugin-a"
  _skill "$p/skills/s1/SKILL.md" s1 10
  echo 'See `references/r.md` for detail.' >>"$p/skills/s1/SKILL.md"
  mkdir -p "$p/skills/s1/references" "$p/agents" "$p/lib" "$p/personas/base" \
    "$p/skills/fixtures" "$p/skills/ticket-flow"
  printf 'Reference text.\n' >"$p/skills/s1/references/r.md"
  printf -- '---\nname: x\ndescription: An agent.\ntools: Bash, Read\n---\nBody.\n' >"$p/agents/x.md"
  printf 'Preamble.\n' >"$p/lib/skill-preamble-auto.md"
  printf 'Persona.\n' >"$p/personas/base/p.md"
  printf '# no frontmatter, ignored\n' >"$p/skills/fixtures/SKILL.md"
  printf 'Doc.\n' >"$p/doc.md"
  cat >"$p/skills/ticket-flow/dispatch-table.json" <<'EOF'
{"prompt_manifests": {"s1": {"files": [
  "plugin:skills/s1/SKILL.md", "lib:skill-preamble-auto.md", "home:doc.md"]}}}
EOF
  _regen >/dev/null 2>&1
}

TABLE_REL="plugin-a/skills/ticket-flow/dispatch-table.json"
BL() { echo "$D/scripts/skill-size-baseline.tsv"; }
CBL() { echo "$D/scripts/skill-context-baseline.tsv"; }
_regen() { bash "$GATE" --root "$D" --table "$D/$TABLE_REL" --regenerate "$@"; }
_run() { # sets RC, OUT
  OUT="$(bash "$GATE" --root "$D" --table "$D/$TABLE_REL" "$@" 2>&1)"
  RC=$?
}
_has() { grep -qF -- "$1" <<<"$OUT"; }
_entry() { awk -F'\t' -v p="$1" '$1 == p' "$(BL)"; }
_set_entry() { # <path> <bytes> <lines>
  awk -F'\t' -v OFS='\t' -v p="$1" -v b="$2" -v l="$3" '$1 == p { $2 = b; $3 = l } { print }' \
    "$(BL)" >"$(BL).t" && mv "$(BL).t" "$(BL)"
}
S1="plugin-a/skills/s1/SKILL.md"

# ── Ratchet (1.2) ──────────────────────────────────────────────────────────
test_clean_repo_passes() {
  _mk_repo
  _run
  [ "$RC" -eq 0 ] && _has "check-skill-size: OK — 4 files within baseline"
}
test_fixtures_ignored() {
  _mk_repo
  _run
  [ "$RC" -eq 0 ] && ! _has "skills/fixtures"
}
test_byte_growth_fails() {
  _mk_repo
  sed -i 's/line 3$/line 33/' "$D/$S1"
  _run
  [ "$RC" -eq 1 ] && _has "GROWTH: $S1 bytes" && ! _has "GROWTH: $S1 lines"
}
test_line_growth_fails() {
  _mk_repo
  echo >>"$D/$S1"
  _run
  [ "$RC" -eq 1 ] && _has "GROWTH: $S1 lines 12 > 11"
}
test_unterminated_final_line_counts() {
  _mk_repo
  mkdir -p "$D/plugin-a/skills/s3"
  printf -- '---\nname: s3\ndescription: d.\n---\na\nb' >"$D/plugin-a/skills/s3/SKILL.md"
  _regen >/dev/null 2>&1
  _run
  [ "$RC" -eq 0 ] && [ "$(_entry plugin-a/skills/s3/SKILL.md | cut -f3)" = 2 ]
}
test_crlf_fails() {
  _mk_repo
  printf 'x\r\n' >>"$D/plugin-a/personas/base/p.md"
  _run
  [ "$RC" -eq 1 ] && _has "CRLF: plugin-a/personas/base/p.md"
}
test_preamble_growth_caught() {
  _mk_repo
  printf 'More preamble.\n' >>"$D/plugin-a/lib/skill-preamble-auto.md"
  _run
  [ "$RC" -eq 1 ] && _has "GROWTH: plugin-a/lib/skill-preamble-auto.md"
}

# ── Raises (1.3) ───────────────────────────────────────────────────────────
test_hand_raise_fails() {
  _mk_repo
  cp "$(BL)" "$D/base.tsv"
  _set_entry "$S1" 99999 11
  _run --base-file "$D/base.tsv"
  [ "$RC" -eq 1 ] && _has "RAISE: $S1"
}
test_annotated_raise_passes() {
  _mk_repo
  cp "$(BL)" "$D/base.tsv"
  _set_entry "$S1" 99999 11
  awk -v p="$S1" 'index($0, p "\t") == 1 { print "# allow-growth: router needs a new spawn site" } { print }' \
    "$(BL)" >"$(BL).t" && mv "$(BL).t" "$(BL)"
  _run --base-file "$D/base.tsv"
  [ "$RC" -eq 0 ] && ! _has "RAISE:"
}
test_hand_added_over_ceiling_entry_fails() {
  _mk_repo
  cp "$(BL)" "$D/base.tsv"
  _skill "$D/plugin-a/skills/big/SKILL.md" big 600
  printf 'plugin-a/skills/big/SKILL.md\t99999\t600\n' >>"$(BL)"
  _run --base-file "$D/base.tsv"
  [ "$RC" -eq 1 ] && _has "RAISE: plugin-a/skills/big/SKILL.md"
}
test_base_unavailable_warns() {
  _mk_repo
  _run
  [ "$RC" -eq 0 ] && _has "WARN: base baseline unavailable"
}

# ── Regenerator (1.4) ──────────────────────────────────────────────────────
test_regen_shrink_lowers() {
  _mk_repo
  sed -i '/^line 10$/d' "$D/$S1"
  _regen >/dev/null 2>&1
  [ "$(_entry "$S1" | cut -f3)" = 10 ]
}
test_regen_growth_keeps_old() {
  _mk_repo
  local before
  before="$(_entry "$S1")"
  echo "extra" >>"$D/$S1"
  _regen >/dev/null 2>&1
  _run
  [ "$(_entry "$S1")" = "$before" ] && [ "$RC" -eq 1 ] && _has "GROWTH: $S1"
}
test_regen_adds_new_in_ceiling() {
  _mk_repo
  _skill "$D/plugin-a/skills/s2/SKILL.md" s2 300
  _regen >/dev/null 2>&1
  [ -n "$(_entry plugin-a/skills/s2/SKILL.md)" ]
}
test_regen_skips_new_over_ceiling() {
  _mk_repo
  _skill "$D/plugin-a/skills/big/SKILL.md" big 600
  _regen >/dev/null 2>&1
  [ -z "$(_entry plugin-a/skills/big/SKILL.md)" ]
}
test_regen_drops_removed() {
  _mk_repo
  rm "$D/plugin-a/personas/base/p.md"
  _regen >/dev/null 2>&1
  [ -z "$(_entry plugin-a/personas/base/p.md)" ]
}
test_regen_preserves_comment() {
  _mk_repo
  awk -v p="$S1" 'index($0, p "\t") == 1 { print "# allow-growth: kept" } { print }' \
    "$(BL)" >"$(BL).t" && mv "$(BL).t" "$(BL)"
  _regen >/dev/null 2>&1
  grep -B1 -F "$S1" "$(BL)" | head -1 | grep -qx '# allow-growth: kept'
}

# ── Slack (1.5) ────────────────────────────────────────────────────────────
test_slack_warns() {
  _mk_repo
  sed -i '/^line 10$/d' "$D/$S1"
  _run
  [ "$RC" -eq 0 ] && _has "SLACK: $S1 lines 11 > 10"
}
test_slack_strict_fails() {
  _mk_repo
  sed -i '/^line 10$/d' "$D/$S1"
  _run --strict
  [ "$RC" -eq 1 ] && _has "SLACK: $S1"
}

# ── Ceiling and exceptions (1.6) ───────────────────────────────────────────
test_unlisted_small_skill_passes() {
  _mk_repo
  _skill "$D/plugin-a/skills/s2/SKILL.md" s2 300
  _run
  [ "$RC" -eq 0 ]
}
test_unlisted_long_skill_fails() {
  _mk_repo
  _skill "$D/plugin-a/skills/s2/SKILL.md" s2 600
  _run
  [ "$RC" -eq 1 ] && _has "CEILING: plugin-a/skills/s2/SKILL.md lines 600 > 500"
}
test_unlisted_heavy_skill_fails() {
  _mk_repo
  _skill "$D/plugin-a/skills/s2/SKILL.md" s2 1
  head -c 21000 /dev/zero | tr '\0' 'a' >>"$D/plugin-a/skills/s2/SKILL.md"
  echo >>"$D/plugin-a/skills/s2/SKILL.md"
  _run
  [ "$RC" -eq 1 ] && _has "CEILING: plugin-a/skills/s2/SKILL.md bytes"
}
test_agent_not_subject_to_ceiling() {
  _mk_repo
  {
    printf -- '---\nname: y\ndescription: Long agent.\ntools: Bash\n---\n'
    for ((i = 1; i <= 600; i++)); do echo "agent line $i"; done
  } >"$D/plugin-a/agents/y.md"
  _run
  [ "$RC" -eq 0 ] && ! _has "CEILING:"
}
test_exceptions_listed() {
  _mk_repo
  _skill "$D/plugin-a/skills/big/SKILL.md" big 600
  _regen --allow-over-ceiling >/dev/null 2>&1
  awk 'index($0, "plugin-a/skills/big/SKILL.md\t") == 1 { print "# exception: grandfathered router" } { print }' \
    "$(BL)" >"$(BL).t" && mv "$(BL).t" "$(BL)"
  _run
  [ "$RC" -eq 0 ] && _has "EXCEPTIONS: 1" && _has "plugin-a/skills/big/SKILL.md" && _has "grandfathered router"
}
test_exception_growth_fails() {
  _mk_repo
  _skill "$D/plugin-a/skills/big/SKILL.md" big 600
  _regen --allow-over-ceiling >/dev/null 2>&1
  echo more >>"$D/plugin-a/skills/big/SKILL.md"
  _run
  [ "$RC" -eq 1 ] && _has "GROWTH: plugin-a/skills/big/SKILL.md lines 601 > 600"
}

# ── Frontmatter (1.7) ──────────────────────────────────────────────────────
_new_skill_with_fm() { # <frontmatter-lines...>
  mkdir -p "$D/plugin-a/skills/s2"
  {
    printf -- '---\n'
    printf '%s\n' "$@"
    printf -- '---\nbody\n'
  } >"$D/plugin-a/skills/s2/SKILL.md"
}
test_frontmatter_missing_fails() {
  _mk_repo
  mkdir -p "$D/plugin-a/skills/s2" && printf '# Title\nbody\n' >"$D/plugin-a/skills/s2/SKILL.md"
  _run
  [ "$RC" -eq 1 ] && _has "FRONTMATTER: plugin-a/skills/s2/SKILL.md missing"
}
test_long_description_fails() {
  _mk_repo
  _new_skill_with_fm "name: s2" "description: $(head -c 1025 /dev/zero | tr '\0' d)"
  _run
  [ "$RC" -eq 1 ] && _has "FRONTMATTER: plugin-a/skills/s2/SKILL.md description exceeds 1024"
}
test_uppercase_name_fails() {
  _mk_repo
  _new_skill_with_fm "name: Ticket-Auto" "description: d."
  _run
  [ "$RC" -eq 1 ] && _has "FRONTMATTER: plugin-a/skills/s2/SKILL.md name invalid"
}
test_tag_in_description_fails() {
  _mk_repo
  _new_skill_with_fm "name: s2" "description: Uses <b>bold</b> text."
  _run
  [ "$RC" -eq 1 ] && _has "FRONTMATTER: plugin-a/skills/s2/SKILL.md description contains a tag"
}
test_unknown_key_fails() {
  _mk_repo
  _new_skill_with_fm "name: s2" "description: d." "allowed_tools: Bash"
  _run
  [ "$RC" -eq 1 ] && _has "FRONTMATTER: plugin-a/skills/s2/SKILL.md unknown key allowed_tools"
}
test_agent_tools_key_accepted() {
  _mk_repo
  _run
  [ "$RC" -eq 0 ] && ! _has "FRONTMATTER: plugin-a/agents/x.md"
}
test_folded_description_accepted() {
  _mk_repo
  _new_skill_with_fm "name: s2" "description: >" "  Folded across" "  two lines."
  _run
  [ "$RC" -eq 0 ] && ! _has "FRONTMATTER:"
}

# ── Fences (1.8) — on an unlisted skill so the ratchet stays quiet ─────────
_fence_skill() { # body appended after frontmatter
  _skill "$D/plugin-a/skills/s2/SKILL.md" s2 1
  cat >>"$D/plugin-a/skills/s2/SKILL.md"
}
test_unmarked_61_line_fence_fails() {
  _mk_repo
  _fence 61 | _fence_skill
  _run
  [ "$RC" -eq 1 ] && _has "FENCE: plugin-a/skills/s2/SKILL.md:6 61 lines > 60"
}
test_marked_fence_passes() {
  _mk_repo
  {
    echo '<!-- size-gate: template -->'
    _fence 61
  } | _fence_skill
  _run
  [ "$RC" -eq 0 ] && ! _has "FENCE"
}
test_marker_not_adjacent_fails() {
  _mk_repo
  {
    echo '<!-- size-gate: template -->'
    echo
    _fence 61
  } | _fence_skill
  _run
  [ "$RC" -eq 1 ] && _has "FENCE: plugin-a/skills/s2/SKILL.md"
}
test_indented_list_fence_detected() {
  _mk_repo
  {
    echo '1. Step one:'
    _fence 70 '  '
  } | _fence_skill
  _run
  [ "$RC" -eq 1 ] && _has "70 lines > 60"
}
test_info_string_line_does_not_close() {
  # A "```bash" line inside an open fence is content, not a closer.
  _mk_repo
  {
    echo '```markdown'
    for i in $(seq 30); do echo "t $i"; done
    echo '```bash'
    for i in $(seq 30); do echo "u $i"; done
    echo '```'
  } | _fence_skill
  _run
  [ "$RC" -eq 1 ] && _has "61 lines > 60"
}
test_26_line_fence_warns() {
  _mk_repo
  _fence 26 | _fence_skill
  _run
  [ "$RC" -eq 0 ] && _has "FENCE-WARN: plugin-a/skills/s2/SKILL.md:6 26 lines"
}

# ── Generated blocks (1.9) ─────────────────────────────────────────────────
_gen_block() { # <n-lines> <line-text>
  echo '<!-- GENERATED:tbl START -->'
  for ((i = 1; i <= $1; i++)); do echo "$2"; done
  echo '<!-- GENERATED:tbl END -->'
}
test_generated_growth_not_growth() {
  _mk_repo
  local s2="plugin-a/skills/s2/SKILL.md"
  _skill "$D/$s2" s2 2
  _gen_block 3 '| row |' >>"$D/$s2"
  _regen >/dev/null 2>&1
  sed -i 's/^<!-- GENERATED:tbl END -->$/| new row |\n&/' "$D/$s2"
  _run
  [ "$RC" -eq 0 ] && ! _has "GROWTH:" && _has "GENERATED: $s2 tbl 36 bytes"
}
test_generated_over_cap_fails() {
  _mk_repo
  _gen_block 200 '| a fairly long generated table row padding |' >>"$D/$S1"
  _regen >/dev/null 2>&1
  _run
  [ "$RC" -eq 1 ] && _has "> 6144"
}
test_generated_unterminated_fails() {
  _mk_repo
  echo '<!-- GENERATED:tbl START -->' >>"$D/$S1"
  _run
  [ "$RC" -eq 1 ] && _has "GENERATED: $S1 tbl unterminated"
}

# ── Reference files (1.10) ─────────────────────────────────────────────────
R="plugin-a/skills/s1/references"
test_orphan_reference_warns() {
  _mk_repo
  printf 'Extra.\n' >"$D/$R/extra.md"
  _run
  [ "$RC" -eq 0 ] && _has "REF-ORPHAN: $R/extra.md"
}
test_dead_link_fails() {
  _mk_repo
  sed -i 's#`references/r.md`#`references/missing.md`#' "$D/$S1"
  _run
  [ "$RC" -eq 1 ] && _has "REF-DEAD: s1 $R/missing.md"
}
test_chain_fails() {
  _mk_repo
  printf 'Extra.\n' >"$D/$R/b.md"
  printf 'See [b](references/b.md).\n' >>"$D/$R/r.md"
  _run
  [ "$RC" -eq 1 ] && _has "REF-CHAIN: $R/r.md -> references/b.md"
}
test_long_reference_without_toc_warns() {
  _mk_repo
  for i in $(seq 140); do echo "ref $i"; done >"$D/$R/r.md"
  _run
  [ "$RC" -eq 0 ] && _has "REF-TOC: $R/r.md 140 lines without ## Contents"
}
test_bare_positional_fails() {
  _mk_repo
  printf 'run with $1\n' >>"$D/$R/r.md"
  _run
  [ "$RC" -eq 1 ] && _has "REF-ARG: $R/r.md:2"
}
test_braced_positional_passes() {
  _mk_repo
  printf 'run with ${1}\n' >>"$D/$R/r.md"
  _run
  [ "$RC" -eq 0 ] && ! _has "REF-ARG"
}
test_templates_dir_treated_same() {
  _mk_repo
  mkdir -p "$D/plugin-a/skills/s1/templates"
  printf 'T $ARGUMENTS\n' >"$D/plugin-a/skills/s1/templates/t.md"
  _run
  [ "$RC" -eq 1 ] && _has "REF-ORPHAN: plugin-a/skills/s1/templates/t.md" &&
    _has "REF-ARG: plugin-a/skills/s1/templates/t.md:1"
}

# ── Context report (1.11) ──────────────────────────────────────────────────
test_context_sums_three_prefixes() {
  _mk_repo
  local want
  want=$(($(wc -c <"$D/$S1") + $(wc -c <"$D/plugin-a/lib/skill-preamble-auto.md") + $(wc -c <"$D/plugin-a/doc.md")))
  _run
  [ "$RC" -eq 0 ] && _has "CONTEXT: s1 $want"
}
test_context_unknown_prefix_warns() {
  _mk_repo
  sed -i 's#"home:doc.md"#"home:doc.md", "cache:foo.md"#' "$D/$TABLE_REL"
  _run
  [ "$RC" -eq 0 ] && _has "CONTEXT-WARN: s1 unresolved cache:foo.md"
}
test_context_growth_fails() {
  _mk_repo
  printf 'Always-loaded sibling grew.\n' >>"$D/plugin-a/doc.md"
  _run
  [ "$RC" -eq 1 ] && _has "CONTEXT-GROWTH: s1"
}
test_context_removed_manifest_dropped() {
  _mk_repo
  printf '{"prompt_manifests": {}}\n' >"$D/$TABLE_REL"
  _regen >/dev/null 2>&1
  ! grep -q '^s1' "$(CBL)"
}

# ── Usage (1.12) ───────────────────────────────────────────────────────────
test_unknown_flag_is_usage_error() {
  _mk_repo
  _run --bogus
  [ "$RC" -eq 2 ]
}
test_missing_root_is_usage_error() {
  OUT="$(bash "$GATE" --root /nonexistent/skill-size-root 2>&1)"
  RC=$?
  [ "$RC" -eq 2 ]
}
test_real_repo_is_clean() {
  OUT="$(bash "$GATE" --root "$SCRIPT_DIR/../.." 2>&1)"
  RC=$?
  [ "$RC" -eq 0 ]
}

for t in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
  RC="" OUT=""
  if "$t"; then _ok "$t"; else _ko "$t (rc=${RC:-?}) ${OUT:-}"; fi
  [ -z "$D" ] || rm -rf "$D"
  D=""
done

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
