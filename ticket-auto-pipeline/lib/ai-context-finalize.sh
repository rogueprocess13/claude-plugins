#!/usr/bin/env bash
# ai-context-finalize.sh — ticket-document Steps 5-6 in one call
# (skill-deterministic-extraction 6a): count what the agent wrote into
# ai-context.md, record it, and emit the DOCUMENT_RESULT block.
#
# Usage:
#   ai-context-finalize.sh <TICKET-ID> --ticket-dir D
#
# The agent writes D/ai-context.md (Step 4); this script never writes it.
# With the file present it:
#   - counts `- ` entries under `## Patterns used` and `## Decisions`, and
#     the corrections in D/notes.md (corrections-parse.sh);
#   - significance = trivial when the file says `Trivial change — no
#     architectural impact.`, else non-trivial;
#   - appends `- ai-context.md written (N patterns, N decisions, C
#     corrections)` to the end of notes.md's `## Session Log` section (the
#     section is added at the end of the file when missing);
#   - logs MAINTENANCE|document|done|ai-context.md written (N patterns, N decisions);
#   - writes the ticket_document verifier result: trivial -> PASS 1/1;
#     non-trivial -> met = sections of What changed, Patterns used, Key files
#     for future agents, Watch out for, Decisions that have content, out of
#     5, PASS when all 5 have content, else WARN;
#   - writes the document-written heartbeat (no-op without HB_LOG_FILE);
#   - prints the DOCUMENT_RESULT block.
# With the file missing it logs MAINTENANCE|document|fail|ai-context.md not
# written (detect-resume routes document fail the same as done), writes a
# FAIL 0/5 verifier result and the document-failed heartbeat, prints the
# `file=none` block and exits 1.
#
# Exit codes: 0 recorded, 1 ai-context.md missing, 2 usage.

_AF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_af_usage() {
  sed -n '7,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
_tid="${1:-}"
[ -n "$_tid" ] && [ "${_tid#-}" = "$_tid" ] || _af_usage
shift
[ "${1:-}" = --ticket-dir ] && [ -n "${2:-}" ] && [ $# -eq 2 ] || _af_usage
_td="$2"
_ctx="$_td/ai-context.md"

# shellcheck source=verifier-result.sh
source "$_AF_DIR/verifier-result.sh"
set +eo pipefail # verifier-result.sh sets them at file scope

if [ ! -s "$_ctx" ]; then
  bash "$_AF_DIR/plog.sh" MAINTENANCE document fail "ai-context.md not written"
  write_verifier_result verifier=ticket_document verdict=FAIL criteria_met=0 criteria_total=5 phase=MAINTENANCE
  bash "$_AF_DIR/hb-wrap.sh" decision "document-failed" "warn" "ai-context.md generation failed" '{"error":"ai-context.md not written"}'
  printf '=== DOCUMENT_RESULT ===\nfile=none\npatterns=0\ndecisions=0\nsignificance=none\nerror=ai-context.md not written\n=== END DOCUMENT_RESULT ===\n'
  exit 1
fi

# Entries (`- ` lines) in section <heading> of ai-context.md.
_af_count() {
  awk -v h="## $1" '
    $0 == h { s = 1; next }
    s && /^## / { s = 0 }
    s && /^- / { n++ }
    END { print n + 0 }' "$_ctx"
}
# 1 when section <heading> has any non-blank line, else 0.
_af_has() {
  awk -v h="## $1" '
    $0 == h { s = 1; next }
    s && /^## / { s = 0 }
    s && NF { f = 1 }
    END { print f + 0 }' "$_ctx"
}

_patterns=$(_af_count "Patterns used")
_decisions=$(_af_count "Decisions")
# shellcheck source=corrections-parse.sh
source "$_AF_DIR/corrections-parse.sh"
set +eo pipefail # corrections-parse.sh sets them at file scope
_corr=$(get_corrections "$_td/notes.md" 2>/dev/null | sed -n 's/^CORRECTION_COUNT=//p')
_corr="${_corr:-0}"

if grep -q '^Trivial change — no architectural impact\.' "$_ctx"; then
  _sig=trivial _met=1 _total=1 _verdict=PASS
else
  _sig=non-trivial _met=0 _total=5
  for _s in "What changed" "Patterns used" "Key files for future agents" "Watch out for" "Decisions"; do
    _met=$((_met + $(_af_has "$_s")))
  done
  if [ "$_met" -eq "$_total" ]; then _verdict=PASS; else _verdict=WARN; fi
fi

_line="- ai-context.md written ($_patterns patterns, $_decisions decisions, $_corr corrections)"
_notes="$_td/notes.md"
if [ -f "$_notes" ] && grep -q '^## Session Log[[:space:]]*$' "$_notes"; then
  _tmp=$(mktemp "$_notes.XXXXXX") &&
    awk -v add="$_line" '
      /^## Session Log[[:space:]]*$/ { s = 1; print; next }
      s && /^## / { print add; print ""; s = 0 }
      { print }
      END { if (s) print add }' "$_notes" >"$_tmp" && mv "$_tmp" "$_notes"
else
  printf '\n## Session Log\n%s\n' "$_line" >>"$_notes"
fi

bash "$_AF_DIR/plog.sh" MAINTENANCE document done "ai-context.md written ($_patterns patterns, $_decisions decisions)"
write_verifier_result verifier=ticket_document verdict="$_verdict" criteria_met="$_met" criteria_total="$_total" phase=MAINTENANCE
bash "$_AF_DIR/hb-wrap.sh" decision "document-written" "fired" "ai-context.md generated" \
  "{\"patterns\":\"$_patterns\",\"decisions\":\"$_decisions\",\"significance\":\"$_sig\"}"
printf '=== DOCUMENT_RESULT ===\nfile=%s\npatterns=%s\ndecisions=%s\nsignificance=%s\n=== END DOCUMENT_RESULT ===\n' \
  "$_ctx" "$_patterns" "$_decisions" "$_sig"
exit 0
