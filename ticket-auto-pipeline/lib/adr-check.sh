#!/usr/bin/env bash
# adr-check.sh — deterministic ADR validation.
#
# Implements every check in the adr-validation capability
# (openspec/changes/adr-governance-gate/specs/adr-validation/spec.md): schema,
# id validity/uniqueness, required fields, status validity and transition
# validity, `supersedes` target validity, supersession reciprocity, required
# sections non-empty, new-ADRs-are-proposed, Accepted-ADRs-unmodified, and the
# `## Decision` hedging-modal check. Zero model involvement — mirrors
# gate-check.sh's philosophy and wiki-check.sh's output/exit conventions.
#
# Accepted-ADR immutability is checked against git history: a file whose
# status is `accepted` in the working tree is compared to its state at the
# last commit that had it `accepted`. Outside a git repo (or for an
# uncommitted new ADR) this check is skipped, not failed — there is no prior
# accepted revision to compare against yet.
#
# Sources lib/adr-store.sh for frontmatter/section extraction — one parser,
# not two, matching how verdict-recompute.sh reuses phase-result-parse.sh.
#
# -u intentionally omitted — see adr-store.sh's header for why.
set -eo pipefail

_ADR_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./adr-store.sh
source "${_ADR_CHECK_DIR}/adr-store.sh"

_ADR_VALID_STATUSES="proposed accepted rejected superseded deprecated"
_ADR_REQUIRED_FM="id status date components"
_ADR_REQUIRED_SECTIONS="Context Decision Considered Options Consequences Affected Components"
_ADR_HEDGES="should would may might could"

VIOLATIONS=0

_ac_finding() {
  # _ac_finding <file> <code> <detail>
  echo "ADR_CHECK|${1}|${2}|${3}"
  VIOLATIONS=$((VIOLATIONS + 1))
}

_ac_in_list() {
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# ── per-file checks (no store context needed) ───────────────────────────────

_ac_check_schema() {
  local file="$1" fm="$2"
  local f missing=()
  for f in $_ADR_REQUIRED_FM; do
    [ -z "$(_adr_fm_get "$fm" "$f")" ] && missing+=("$f")
  done
  local src
  src=$(_adr_fm_source "$fm")
  [ -z "$src" ] && missing+=("initiative|ticket|manual")
  if [ "${#missing[@]}" -gt 0 ]; then
    _ac_finding "$file" "MISSING_FIELDS" "$(
      IFS=,
      echo "${missing[*]}"
    )"
  fi
}

_ac_check_id_format() {
  local file="$1" fm="$2" id
  id=$(_adr_fm_get "$fm" "id")
  [ -z "$id" ] && return 0
  if ! [[ "$id" =~ ^ADR-[0-9]{4}$ ]]; then
    _ac_finding "$file" "INVALID_ID_FORMAT" "id=${id}"
  fi
}

_ac_check_title() {
  local file="$1" fm="$2" id title_line
  id=$(_adr_fm_get "$fm" "id")
  [ -z "$id" ] && return 0
  title_line=$(_adr_title_line "$file")
  if [ -z "$title_line" ]; then
    _ac_finding "$file" "MISSING_TITLE" "expected '# ${id}: <decision>'"
  elif [[ "$title_line" != "# ${id}:"* ]]; then
    _ac_finding "$file" "TITLE_ID_MISMATCH" "$title_line"
  fi
}

_ac_check_status_validity() {
  local file="$1" fm="$2" status
  status=$(_adr_fm_get "$fm" "status")
  [ -z "$status" ] && return 0
  if ! _ac_in_list "$status" "$_ADR_VALID_STATUSES"; then
    _ac_finding "$file" "INVALID_STATUS" "status=${status}"
  fi
}

_ac_check_deciders() {
  local file="$1" fm="$2" status deciders_raw
  status=$(_adr_fm_get "$fm" "status")
  [ "$status" = "accepted" ] || return 0
  deciders_raw=$(_adr_fm_list "$fm" "deciders")
  if [ -z "$deciders_raw" ]; then
    _ac_finding "$file" "ACCEPTED_WITHOUT_DECIDERS" "status=accepted requires a non-empty deciders list"
  fi
}

_ac_check_superseded_deprecated_shape() {
  local file="$1" fm="$2" status superseded_by
  status=$(_adr_fm_get "$fm" "status")
  superseded_by=$(_adr_fm_get "$fm" "superseded_by")
  case "$status" in
  superseded)
    if [ -z "$superseded_by" ]; then
      _ac_finding "$file" "SUPERSEDED_WITHOUT_REPLACEMENT" "status=superseded requires a non-empty superseded_by"
    fi
    ;;
  deprecated)
    if [ -n "$superseded_by" ]; then
      _ac_finding "$file" "DEPRECATED_WITH_REPLACEMENT" "status=deprecated must not carry superseded_by (got ${superseded_by})"
    fi
    ;;
  esac
  return 0
}

_ac_check_sections() {
  local file="$1" content
  local sec missing=()
  for sec in "Context" "Decision" "Considered Options" "Consequences" "Affected Components"; do
    content=$(_adr_extract_section "$file" "$sec")
    [ -z "${content//[[:space:]]/}" ] && missing+=("$sec")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    _ac_finding "$file" "MISSING_SECTIONS" "$(
      IFS='; '
      echo "${missing[*]}"
    )"
  fi
}

_ac_check_hedging() {
  local file="$1" decision hedge
  decision=$(_adr_extract_section "$file" "Decision")
  [ -z "$decision" ] && return 0
  local lc
  lc=$(echo "$decision" | tr '[:upper:]' '[:lower:]')
  for hedge in $_ADR_HEDGES; do
    if echo "$lc" | grep -qE "(^|[^a-z])${hedge}([^a-z]|\$)"; then
      _ac_finding "$file" "HEDGED_DECISION" "contains hedging modal '${hedge}'"
      return 0
    fi
  done
}

# `git log --follow` walks renames; the most recent commit whose committed
# blob has status=accepted is the last-known-good accepted revision. A file
# never committed with status=accepted (a brand-new proposed→accepted-in-one-
# commit case, or a non-git wiki root) has nothing to compare — skip, not fail.
_ac_check_immutability() {
  local file="$1" fm="$2" status repo_dir rel
  status=$(_adr_fm_get "$fm" "status")
  [ "$status" = "accepted" ] || return 0

  repo_dir=$(cd "$(dirname "$file")" && git rev-parse --show-toplevel 2>/dev/null) || return 0
  rel="${file#"$repo_dir"/}"

  local commits commit prior_fm prior_status
  commits=$(git -C "$repo_dir" log --follow --format=%H -- "$rel" 2>/dev/null) || return 0
  [ -z "$commits" ] && return 0

  for commit in $commits; do
    prior_fm=$(git -C "$repo_dir" show "${commit}:${rel}" 2>/dev/null | awk '
      NR==1 && $0 != "---" { exit }
      NR==1 { in_fm=1; next }
      in_fm && $0 == "---" { exit }
      in_fm { print }
    ') || continue
    prior_status=$(_adr_fm_get "$prior_fm" "status")
    if [ "$prior_status" = "accepted" ]; then
      local prior_body cur_body
      prior_body=$(git -C "$repo_dir" show "${commit}:${rel}" 2>/dev/null | _adr_strip_frontmatter -)
      cur_body=$(_adr_strip_frontmatter "$file")
      if [ "$prior_body" != "$cur_body" ]; then
        _ac_finding "$file" "ACCEPTED_ADR_MODIFIED" "body differs from the last commit where status=accepted (${commit:0:8})"
      fi
      return 0
    fi
  done
  return 0
}

# ── store-wide checks ────────────────────────────────────────────────────────

_ac_check_store() {
  local decisions_dir="$1"
  local -A id_seen=()
  local -A id_file=()
  local -A file_status=()
  local -A file_superseded_by=()
  local -A file_supersedes=()
  local -A file_source=()
  local file fm id status src

  while IFS= read -r file; do
    fm=$(_adr_extract_frontmatter "$file")
    id=$(_adr_fm_get "$fm" "id")
    status=$(_adr_fm_get "$fm" "status")
    [ -n "$id" ] || continue

    if [ -n "${id_seen[$id]+x}" ]; then
      _ac_finding "$file" "DUPLICATE_ID" "id=${id} also used by ${id_file[$id]}"
    else
      id_seen[$id]=1
      id_file[$id]="$file"
    fi

    file_status["$id"]="$status"
    file_superseded_by["$id"]=$(_adr_fm_get "$fm" "superseded_by")
    file_supersedes["$id"]=$(_adr_fm_get "$fm" "supersedes")

    src=$(_adr_fm_source "$fm")
    if [ -n "$src" ]; then
      if [ -n "${file_source[$src]+x}" ]; then
        _ac_finding "$file" "DUPLICATE_SOURCE" "source=${src} also used by ${file_source[$src]}"
      else
        file_source["$src"]="$file"
      fi
    fi
  done < <(find "$decisions_dir" -maxdepth 1 -name '*.md' ! -name 'index.md' 2>/dev/null | sort)

  local sid supersedes target_status
  for sid in "${!file_supersedes[@]}"; do
    supersedes="${file_supersedes[$sid]}"
    [ -z "$supersedes" ] && continue
    if [ -z "${id_file[$supersedes]+x}" ]; then
      _ac_finding "${id_file[$sid]}" "SUPERSEDES_TARGET_MISSING" "supersedes=${supersedes} does not exist"
      continue
    fi
    if [ "${file_status[$sid]}" = "superseded" ] || [ "${file_status[$sid]:-}" = "accepted" ]; then
      target_status="${file_status[$supersedes]:-}"
      if [ "$target_status" = "superseded" ] && [ "${file_superseded_by[$supersedes]}" != "$sid" ]; then
        _ac_finding "${id_file[$supersedes]}" "SUPERSESSION_NOT_RECIPROCAL" "${supersedes} is superseded but superseded_by != ${sid} (got '${file_superseded_by[$supersedes]}')"
      fi
    fi
  done
  return 0
}

# ── transition validity (requires git history for the "from" state) ─────────

_ac_check_transition() {
  local file="$1" fm="$2" status repo_dir rel
  status=$(_adr_fm_get "$fm" "status")
  [ -z "$status" ] && return 0

  repo_dir=$(cd "$(dirname "$file")" && git rev-parse --show-toplevel 2>/dev/null) || return 0
  rel="${file#"$repo_dir"/}"

  # The caller (wiki-maintenance Step 4) runs this against a dirty working
  # tree BEFORE staging: disk holds the proposed new status, and the most
  # recent commit (skip=0, i.e. plain `-n 1`) is the true "from" state. A
  # `--skip=1` here would instead compare against the commit before that,
  # misattributing the from-state one transition too far back — e.g. a
  # legitimate accepted->superseded edit would be checked against whatever
  # status preceded "accepted", not "accepted" itself.
  local prev_commit prev_status
  prev_commit=$(git -C "$repo_dir" log --follow --format=%H -n 1 -- "$rel" 2>/dev/null) || return 0
  [ -z "$prev_commit" ] && return 0

  prev_status=$(git -C "$repo_dir" show "${prev_commit}:${rel}" 2>/dev/null | awk '
    NR==1 && $0 != "---" { exit }
    NR==1 { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm { print }
  ' | grep -m1 '^status:' | sed 's/^status: *//') || return 0
  [ -z "$prev_status" ] && return 0
  [ "$prev_status" = "$status" ] && return 0

  local valid=""
  case "$prev_status" in
  proposed) valid="accepted rejected" ;;
  accepted) valid="superseded deprecated" ;;
  rejected | superseded | deprecated) valid="" ;;
  esac

  if ! _ac_in_list "$status" "$valid"; then
    _ac_finding "$file" "INVALID_TRANSITION" "${prev_status} -> ${status}"
  fi
}

# ── new-ADR-is-proposed (uncommitted / first-commit files only) ─────────────

_ac_check_new_is_proposed() {
  local file="$1" fm="$2" status repo_dir rel is_new=0
  status=$(_adr_fm_get "$fm" "status")
  [ -z "$status" ] && return 0

  repo_dir=$(cd "$(dirname "$file")" && git rev-parse --show-toplevel 2>/dev/null) || is_new=1
  if [ "$is_new" -eq 0 ]; then
    rel="${file#"$repo_dir"/}"
    if ! git -C "$repo_dir" log -n 1 --format=%H -- "$rel" >/dev/null 2>&1 ||
      [ -z "$(git -C "$repo_dir" log -n 1 --format=%H -- "$rel" 2>/dev/null)" ]; then
      is_new=1
    fi
  fi

  [ "$is_new" -eq 1 ] && [ "$status" != "proposed" ] && {
    _ac_finding "$file" "NEW_ADR_NOT_PROPOSED" "status=${status}, expected proposed for a newly created ADR"
  }
  return 0
}

# ── one-file check runner ────────────────────────────────────────────────────

_ac_check_file() {
  local file="$1" fm
  fm=$(_adr_extract_frontmatter "$file")
  _ac_check_schema "$file" "$fm"
  _ac_check_id_format "$file" "$fm"
  _ac_check_title "$file" "$fm"
  _ac_check_status_validity "$file" "$fm"
  _ac_check_deciders "$file" "$fm"
  _ac_check_superseded_deprecated_shape "$file" "$fm"
  _ac_check_sections "$file"
  _ac_check_hedging "$file"
  _ac_check_immutability "$file" "$fm"
  _ac_check_transition "$file" "$fm"
  _ac_check_new_is_proposed "$file" "$fm"
  return 0
}

# ── main ──────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: adr-check.sh --file <path>
       adr-check.sh --wiki-root <path>

Validates one ADR file, or an entire {wiki-root}/decisions/ store (adds
uniqueness, supersession-reciprocity, and duplicate-source checks that need
store-wide context — reported as unevaluated, never as a silent pass, when
run in single-file mode).

Emits one ADR_CHECK|<file>|<code>|<detail> line per violation, followed by
ADR_CHECK_SUMMARY|files=<n>|violations=<n>.

Exit: 0 clean, 1 violations found, 2 usage/setup error.
EOF
  exit 2
}

main() {
  local single_file="" wiki_root=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --file)
      single_file="${2:-}"
      shift 2
      ;;
    --wiki-root)
      wiki_root="${2:-}"
      shift 2
      ;;
    -h | --help) usage ;;
    *)
      echo "adr-check.sh: unknown argument '$1'" >&2
      usage
      ;;
    esac
  done

  if [ -n "$single_file" ]; then
    [ -f "$single_file" ] || {
      echo "ERROR: file not found: $single_file" >&2
      exit 2
    }
    _ac_check_file "$single_file"
    echo "ADR_CHECK|${single_file}|UNEVALUATED|store-wide checks (id uniqueness, supersession reciprocity, duplicate source) require --wiki-root"
    echo "ADR_CHECK_SUMMARY|files=1|violations=${VIOLATIONS}"
    [ "$VIOLATIONS" -eq 0 ] && exit 0
    exit 1
  fi

  [ -z "$wiki_root" ] && {
    echo "ERROR: --file or --wiki-root is required" >&2
    usage
  }
  local decisions_dir
  decisions_dir=$(_adr_decisions_dir "$wiki_root")
  [ -d "$decisions_dir" ] || {
    echo "ERROR: decisions dir not found: $decisions_dir" >&2
    exit 2
  }

  local total=0 file
  while IFS= read -r file; do
    total=$((total + 1))
    _ac_check_file "$file"
  done < <(find "$decisions_dir" -maxdepth 1 -name '*.md' ! -name 'index.md' 2>/dev/null | sort)

  _ac_check_store "$decisions_dir"

  echo "ADR_CHECK_SUMMARY|files=${total}|violations=${VIOLATIONS}"
  [ "$VIOLATIONS" -eq 0 ] && exit 0
  exit 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
