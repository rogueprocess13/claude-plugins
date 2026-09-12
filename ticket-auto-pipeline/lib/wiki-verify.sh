#!/usr/bin/env bash
# wiki-verify.sh — deterministic post-edit wiki and ADR-store integrity check.
#
# Implements the wiki-verify capability
# (openspec/changes/adr-governance-gate/specs/wiki-verify/spec.md): registry
# completeness, `related:` link integrity, ADR store integrity (schema,
# index consistency, duplicate-source, supersession reciprocity), and
# glossary term-drift/entry-rot. Zero model involvement, non-blocking
# (D13, design.md) — this is a structural-integrity warn, not a governance
# gate-stop.
#
# Composes the existing checkers rather than re-implementing them: shells
# out to lib/wiki-check.sh (link integrity) and lib/adr-check.sh (ADR
# schema, duplicate-source, supersession reciprocity) the same way
# wiki-maintenance's own Step 3/Step 4 already do, and sources
# lib/adr-store.sh (frontmatter helpers, for the decisions-index
# consistency check) and lib/wiki-bootstrap.sh (wiki_term_drift_check, task
# 3.5) rather than duplicating their parsers. One frontmatter parser, one
# term-drift scanner — not three.
#
# Net-new here: registry completeness (index.md File Registry vs the
# filesystem, both directions), decisions-index consistency
# (decisions/index.md vs the store, both directions), and glossary
# entry-rot (a term with zero usages anywhere).
#
# Sourceable lib (wiki_verify) and standalone CLI, output/exit conventions
# matching wiki-check.sh and adr-check.sh: flat `WIKI_VERIFY|<code>|<loc>|
# <detail>` lines, a summary line, exit 0 clean / 1 violations / 2
# usage-or-setup error — setup failure is distinguishable from a clean
# violation-free result, never conflated with it.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention.
set -eo pipefail

_WV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./adr-store.sh
source "${_WV_SCRIPT_DIR}/adr-store.sh"
# shellcheck source=./wiki-bootstrap.sh
source "${_WV_SCRIPT_DIR}/wiki-bootstrap.sh"

WIKI_VERIFY_SCHEMA_VERSION=1

WV_VIOLATIONS=0
WV_CHECKS=0

_wv_finding() {
  # _wv_finding <code> <location> <detail>
  echo "WIKI_VERIFY|${1}|${2}|${3}"
  WV_VIOLATIONS=$((WV_VIOLATIONS + 1))
}

# ── registry completeness (task 8.2) ────────────────────────────────────────
# Checks index.md's File Registry table against the filesystem in both
# directions. Excludes index.md, glossary.md, and decisions/** — those carry
# their own indices/checks (decisions-index consistency, below) rather than
# a File Registry row.

_wv_registry_rows() {
  local index_path="$1" in_table=false line path
  [ -f "$index_path" ] || return 0
  while IFS= read -r line; do
    case "$line" in
    "## File Registry"*)
      in_table=true
      continue
      ;;
    "## "*)
      in_table=false
      continue
      ;;
    esac
    [ "$in_table" = "true" ] || continue
    echo "$line" | grep -qE '^\|.*\|.*\|' || continue
    echo "$line" | grep -qE '^\|[- ]+\|' && continue
    path=$(echo "$line" | cut -d'|' -f2 | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^`//; s/`$//')
    [ -z "$path" ] && continue
    [ "$path" = "File" ] && continue
    [ "$path" = "(no entries yet)" ] && continue
    echo "$path"
  done <"$index_path"
}

_wv_check_registry() {
  local wiki_root="$1"
  WV_CHECKS=$((WV_CHECKS + 1))
  local index_path="$wiki_root/index.md"
  local registered=() f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    registered+=("$f")
  done < <(_wv_registry_rows "$index_path")

  local reg_joined=","
  for f in "${registered[@]}"; do reg_joined="${reg_joined}${f},"; done

  local fs_files=() rel
  while IFS= read -r f; do
    rel="${f#"$wiki_root"/}"
    fs_files+=("$rel")
  done < <(find "$wiki_root" -type f -name '*.md' \
    ! -name 'index.md' ! -name 'glossary.md' ! -path '*/decisions/*' 2>/dev/null | sort)

  local fs_joined=","
  for f in "${fs_files[@]}"; do fs_joined="${fs_joined}${f},"; done

  for f in "${registered[@]}"; do
    case "$fs_joined" in
    *",${f},"*) ;;
    *) _wv_finding "ORPHANED_REGISTRY_ROW" "$index_path" "registry names '${f}', which does not exist" ;;
    esac
  done

  for f in "${fs_files[@]}"; do
    case "$reg_joined" in
    *",${f},"*) ;;
    *) _wv_finding "UNREGISTERED_FILE" "$wiki_root/$f" "no File Registry row in index.md" ;;
    esac
  done
}

# ── related: link integrity (task 8.3) ──────────────────────────────────────
# wiki-check.sh already implements this exact check (broken_related field) —
# reused as a subprocess rather than re-parsed here.

_wv_check_links() {
  local wiki_root="$1"
  WV_CHECKS=$((WV_CHECKS + 1))
  local wc_out
  wc_out=$(bash "${_WV_SCRIPT_DIR}/wiki-check.sh" --wiki-root "$wiki_root" 2>/dev/null) || true
  [ -z "$wc_out" ] && return 0

  local line rel broken_field targets t _t
  while IFS= read -r line; do
    case "$line" in
    "WIKI_CHECK|"*) ;;
    *) continue ;;
    esac
    rel=$(echo "$line" | cut -d'|' -f2)
    broken_field=$(echo "$line" | cut -d'|' -f5)
    broken_field="${broken_field#broken_related=}"
    [ "$broken_field" = "0" ] && continue
    targets="${broken_field#*:}"
    IFS=',' read -r -a _t <<<"$targets"
    for t in "${_t[@]}"; do
      [ -z "$t" ] && continue
      _wv_finding "LINK_INTEGRITY" "$wiki_root/$rel" "related: target '${t}' does not exist"
    done
  done <<<"$wc_out"
}

# ── ADR store integrity: schema, duplicate-source, supersession (tasks 8.4, 8.6, 8.7)
# adr-check.sh's --wiki-root mode already implements all three as store-wide
# checks (MISSING_FIELDS/MISSING_SECTIONS, DUPLICATE_SOURCE,
# SUPERSESSION_NOT_RECIPROCAL, among others) — forwarded here as a backstop
# layer rather than re-implemented.

_wv_check_adr_store() {
  local wiki_root="$1" decisions_dir
  decisions_dir=$(_adr_decisions_dir "$wiki_root")
  [ -d "$decisions_dir" ] || return 0
  WV_CHECKS=$((WV_CHECKS + 1))

  local ac_out
  ac_out=$(bash "${_WV_SCRIPT_DIR}/adr-check.sh" --wiki-root "$wiki_root" 2>/dev/null) || true
  [ -z "$ac_out" ] && return 0

  local line file code detail
  while IFS= read -r line; do
    case "$line" in
    "ADR_CHECK|"*) ;;
    *) continue ;;
    esac
    file=$(echo "$line" | cut -d'|' -f2)
    code=$(echo "$line" | cut -d'|' -f3)
    detail=$(echo "$line" | cut -d'|' -f4-)
    _wv_finding "ADR_CHECK:${code}" "$file" "$detail"
  done <<<"$ac_out"
}

# ── decisions-index consistency (task 8.5) ──────────────────────────────────
# decisions/index.md is regenerated wholesale on every adr_write/accept/
# supersede (_adr_regen_index) — in a healthy store it always matches the
# filesystem. This catches drift a hand-edit or a dropped regen would cause.

_wv_decisions_index_ids() {
  local index_path="$1" line id
  [ -f "$index_path" ] || return 0
  while IFS= read -r line; do
    echo "$line" | grep -qE '^\|.*\|.*\|' || continue
    echo "$line" | grep -qE '^\|[- ]+\|' && continue
    id=$(echo "$line" | cut -d'|' -f2 | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    [ -z "$id" ] && continue
    [ "$id" = "ADR" ] && continue
    echo "$id"
  done <"$index_path"
}

_wv_check_decisions_index() {
  local wiki_root="$1" decisions_dir
  decisions_dir=$(_adr_decisions_dir "$wiki_root")
  [ -d "$decisions_dir" ] || return 0
  WV_CHECKS=$((WV_CHECKS + 1))

  local index_path="$decisions_dir/index.md"
  if [ ! -f "$index_path" ]; then
    _wv_finding "INDEX_MISSING" "$index_path" "decisions/index.md does not exist"
    return 0
  fi

  local indexed_ids=() id
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    indexed_ids+=("$id")
  done < <(_wv_decisions_index_ids "$index_path")
  local idx_joined=","
  for id in "${indexed_ids[@]}"; do idx_joined="${idx_joined}${id},"; done

  local file_ids=() f fm fid
  while IFS= read -r f; do
    fm=$(_adr_extract_frontmatter "$f")
    fid=$(_adr_fm_get "$fm" "id")
    [ -z "$fid" ] && continue
    file_ids+=("$fid")
    case "$idx_joined" in
    *",${fid},"*) ;;
    *) _wv_finding "UNINDEXED_ADR" "$f" "id '${fid}' has no row in decisions/index.md" ;;
    esac
  done < <(find "$decisions_dir" -maxdepth 1 -name '*.md' ! -name 'index.md' 2>/dev/null | sort)

  local files_joined=","
  for id in "${file_ids[@]}"; do files_joined="${files_joined}${id},"; done
  for id in "${indexed_ids[@]}"; do
    case "$files_joined" in
    *",${id},"*) ;;
    *) _wv_finding "INDEX_ORPHAN_ROW" "$index_path" "index names '${id}', which does not exist in the store" ;;
    esac
  done
}

# ── glossary: term-drift + entry-rot (task 8.8) ─────────────────────────────
# Term-drift reuses wiki_term_drift_check (wiki-bootstrap.sh, task 3.5)
# verbatim. Entry-rot is net-new: a glossary entry whose own preferred term
# has zero usages anywhere is a stale entry, invisible without this check.

_wv_check_glossary() {
  local wiki_root="$1"
  local glossary="$wiki_root/glossary.md"
  [ -f "$glossary" ] || return 0
  WV_CHECKS=$((WV_CHECKS + 1))

  local td_out
  td_out=$(wiki_term_drift_check "$wiki_root") || true
  if [ -n "$td_out" ]; then
    local line file avoided term
    while IFS= read -r line; do
      case "$line" in
      "TERM_DRIFT|"*) ;;
      *) continue ;;
      esac
      file=$(echo "$line" | cut -d'|' -f2)
      avoided=$(echo "$line" | cut -d'|' -f3)
      term=$(echo "$line" | cut -d'|' -f4)
      _wv_finding "TERM_DRIFT" "$file" "uses avoided synonym '${avoided}' for preferred term '${term}'"
    done <<<"$td_out"
  fi

  local files=() f
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$wiki_root" -type f -name '*.md' ! -name 'glossary.md' ! -name 'index.md' 2>/dev/null)

  local term=""
  while IFS= read -r line; do
    case "$line" in
    "### "*)
      term="${line#"### "}"
      [ -z "$term" ] && continue
      local used=1
      for f in "${files[@]}"; do
        if grep -niqw -F -- "$term" "$f" 2>/dev/null; then
          used=0
          break
        fi
      done
      if [ "$used" -eq 1 ]; then
        _wv_finding "GLOSSARY_ROT" "$glossary" "term '${term}' has no usages in any wiki file or ADR"
      fi
      ;;
    esac
  done <"$glossary"
}

# ── main ─────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: wiki-verify.sh --wiki-root <path>

Verifies wiki and ADR-store integrity: registry completeness, related: link
integrity, ADR store integrity (schema, duplicate-source, supersession
reciprocity — via adr-check.sh), decisions-index consistency, and glossary
term-drift/entry-rot. No model involvement, non-blocking — this is a warn,
not a gate-stop (design.md D13).

Emits one WIKI_VERIFY|<code>|<location>|<detail> line per violation,
followed by WIKI_VERIFY_SUMMARY|checks=<n>|violations=<n>.

Exit: 0 clean, 1 violations found, 2 usage/setup error (distinguishable from
a clean result — a missing/unreadable wiki root is not "0 violations").
EOF
  exit 2
}

wiki_verify() {
  local wiki_root="$1"
  WV_VIOLATIONS=0
  WV_CHECKS=0

  _wv_check_registry "$wiki_root"
  _wv_check_links "$wiki_root"
  _wv_check_adr_store "$wiki_root"
  _wv_check_decisions_index "$wiki_root"
  _wv_check_glossary "$wiki_root"

  echo "WIKI_VERIFY_SUMMARY|checks=${WV_CHECKS}|violations=${WV_VIOLATIONS}"
  [ "$WV_VIOLATIONS" -eq 0 ]
}

main() {
  local wiki_root=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --wiki-root)
      wiki_root="${2:-}"
      shift 2
      ;;
    -h | --help) usage ;;
    *)
      echo "wiki-verify.sh: unknown argument '$1'" >&2
      usage
      ;;
    esac
  done

  [ -z "$wiki_root" ] && {
    echo "ERROR: --wiki-root is required" >&2
    usage
  }
  [ -d "$wiki_root" ] || {
    echo "ERROR: --wiki-root not found: $wiki_root" >&2
    exit 2
  }
  wiki_root="$(cd "$wiki_root" && pwd)"

  if wiki_verify "$wiki_root"; then
    exit 0
  else
    exit 1
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
