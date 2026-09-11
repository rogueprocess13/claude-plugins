#!/usr/bin/env bash
# adr-store.sh — durable ADR store under {WIKI_ROOT}/decisions/.
#
# Deterministic bash primitive for the adr-store capability
# (openspec/changes/adr-governance-gate/specs/adr-store/spec.md). Owns
# numbering, per-source idempotency, concurrency-safe writes, and index
# generation for Architecture Decision Records — see docs/adr-schema.md for
# the file schema this writes.
#
# Sourceable lib (adr_write, adr_accept, adr_supersede, adr_query_by_component,
# _adr_exists_for, _next_adr_number) and standalone CLI. Reused (sourced) by
# lib/adr-check.sh for frontmatter/section extraction, and by lib/wiki-verify.sh
# for store-integrity checks — one frontmatter parser, not three.
#
# Authority model (docs/adr-schema.md § Authority model): agents may write a
# `proposed` ADR via adr_write; only adr_accept moves one to `accepted`, and
# adr_accept refuses to run when CLAUDE_CODE_SESSION_ID is set — the same env
# var lib/spawn-helper.sh already stamps into every agent-spawned shell, so
# this is a real signal, not a decorative check, not a promise the caller
# happens to keep.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention.
set -eo pipefail

ADR_STORE_SCHEMA_VERSION=1
ADR_LOCK_WAIT_SECS="${ADR_LOCK_WAIT_SECS:-10}"

_ADR_STATUSES="proposed accepted rejected superseded deprecated"
_ADR_SOURCE_KEYS="initiative ticket manual"

# ── small helpers ────────────────────────────────────────────────────────────

_adr_now_date() {
  date -u +%Y-%m-%d 2>/dev/null || echo "1970-01-01"
}

_adr_decisions_dir() {
  echo "${1%/}/decisions"
}

_adr_slug() {
  local title="$1"
  echo "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-60
}

# _adr_next_number's caller-visible name (task 2.2). Highest NNNN- prefix
# under decisions/, plus one, gap-tolerant (a store with 0001 and 0003
# returns 0004, not 0002 — the count of files is never the source of truth).
_next_adr_number() {
  local decisions_dir="$1"
  local max=0 n
  if [ -d "$decisions_dir" ]; then
    while IFS= read -r f; do
      n=$(basename "$f" | grep -oE '^[0-9]{4}' || true)
      [ -z "$n" ] && continue
      n=$((10#$n))
      [ "$n" -gt "$max" ] && max=$n
    done < <(find "$decisions_dir" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-*.md' 2>/dev/null)
  fi
  printf '%04d\n' "$((max + 1))"
}

# Single-line flow-style frontmatter reader, same convention as
# wiki-check.sh's _extract_frontmatter/_fm_get.
_adr_extract_frontmatter() {
  awk '
    NR==1 && $0 != "---" { exit }
    NR==1 { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm { print }
  ' "$1"
}

_adr_fm_get() {
  # _adr_fm_get <frontmatter-text> <key>
  echo "$1" | grep -m1 "^${2}:" | sed "s/^${2}: *//" | sed 's/^"//; s/"$//' || true
}

# Reads a bracket-list field (`components: [a, b]`) into newline-separated
# values. Empty brackets yield nothing.
_adr_fm_list() {
  local raw
  raw=$(_adr_fm_get "$1" "$2")
  raw="${raw#\[}"
  raw="${raw%\]}"
  [ -z "${raw//[[:space:]]/}" ] && return 0
  echo "$raw" | tr ',' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

# Returns the source key present in this frontmatter (initiative|ticket|manual)
# and its value, as "key<TAB>value". Empty if none found.
_adr_fm_source() {
  local fm="$1" k v
  for k in $_ADR_SOURCE_KEYS; do
    v=$(_adr_fm_get "$fm" "$k")
    if [ -n "$v" ]; then
      printf '%s\t%s\n' "$k" "$v"
      return 0
    fi
  done
}

# Extracts the content of one `## Section` heading, up to the next `## `
# heading or EOF. Trims leading/trailing blank lines.
_adr_extract_section() {
  local file="$1" heading="$2"
  awk -v h="## ${heading}" '
    $0 == h { in_s=1; next }
    in_s && /^## / { exit }
    in_s { print }
  ' "$file" | sed -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

_adr_title_line() {
  grep -m1 -E '^# ADR-[0-9]{4}:' "$1" || true
}

# Strips YAML frontmatter, printing everything from the title heading
# onward. Reads a file when given, stdin when given "-" (or nothing) — lets
# a caller pipe `git show <rev>:<path>` through the same stripping logic
# used on a working-tree file, so a body-content diff compares like with
# like. A file with no frontmatter (doesn't open with `---`) passes through
# unchanged.
_adr_strip_frontmatter() {
  awk '
    NR==1 && $0 != "---" { print; next }
    NR==1 { in_fm=1; next }
    in_fm && $0 == "---" { in_fm=0; next }
    in_fm { next }
    { print }
  ' "${1:--}"
}

# Locates a store file by id ("ADR-0007" or bare "0007"). Empty if not found.
_adr_find_by_id() {
  local decisions_dir="$1" id="$2" n file fm fid
  n="${id#ADR-}"
  n=$(printf '%04d' "$((10#$n))" 2>/dev/null) || return 0
  [ -d "$decisions_dir" ] || return 0
  while IFS= read -r file; do
    fm=$(_adr_extract_frontmatter "$file")
    fid=$(_adr_fm_get "$fm" "id")
    if [ "$fid" = "ADR-${n}" ]; then
      echo "$file"
      return 0
    fi
  done < <(find "$decisions_dir" -maxdepth 1 -name "${n}-*.md" 2>/dev/null)
}

_adr_lock() {
  local decisions_dir="$1"
  mkdir -p "$decisions_dir" 2>/dev/null || true
  exec 9>"$decisions_dir/.lock" || {
    echo "adr-store: cannot create lock file" >&2
    return 5
  }
  if ! flock -w "$ADR_LOCK_WAIT_SECS" 9 2>/dev/null; then
    echo "adr-store: lock timeout (${ADR_LOCK_WAIT_SECS}s) on ${decisions_dir}/.lock" >&2
    exec 9>&-
    return 5
  fi
  return 0
}

_adr_unlock() {
  exec 9>&- 2>/dev/null || true
}

# ── existence check (task 2.3) ──────────────────────────────────────────────

# _adr_exists_for <decisions_dir> <source-id>
# Matches initiative:/ticket:/manual: frontmatter across decisions/*.md — the
# idempotency key is the frontmatter value, never the filename/slug (a title
# rename between runs must not produce a duplicate). Prints the matching file
# on a hit. Exit 0 found, 1 not found.
_adr_exists_for() {
  local decisions_dir="$1" source_id="$2" file fm src
  [ -d "$decisions_dir" ] || return 1
  while IFS= read -r file; do
    fm=$(_adr_extract_frontmatter "$file")
    src=$(_adr_fm_source "$fm")
    [ -z "$src" ] && continue
    if [ "$(echo "$src" | cut -f2)" = "$source_id" ]; then
      echo "$file"
      return 0
    fi
  done < <(find "$decisions_dir" -maxdepth 1 -name '*.md' ! -name 'index.md' 2>/dev/null)
  return 1
}

# ── index generation (task 2.8) ─────────────────────────────────────────────

# Regenerates decisions/index.md wholesale from every ADR's frontmatter, the
# way knowledge-curator/lib/kc-index.sh regenerates its index — never a
# hand-maintained row, always derived. Must be called with the lock already
# held by the caller.
_adr_regen_index() {
  local decisions_dir="$1"
  local idx_tmp="$decisions_dir/index.md.tmp.$$"
  mkdir -p "$decisions_dir" 2>/dev/null || true
  {
    echo "# Decisions Index"
    echo
    echo "Generated by \`lib/adr-store.sh\`. Do not hand-edit — regenerated on every write."
    echo
    echo "| ADR | Title | Status | Date | Source |"
    echo "|---|---|---|---|---|"
    local file fm id status date src src_display title
    while IFS= read -r file; do
      fm=$(_adr_extract_frontmatter "$file")
      id=$(_adr_fm_get "$fm" "id")
      status=$(_adr_fm_get "$fm" "status")
      date=$(_adr_fm_get "$fm" "date")
      src=$(_adr_fm_source "$fm")
      # _adr_fm_source returns "key<TAB>value" for programmatic cut -f1/-f2
      # consumers (_adr_exists_for, adr-check.sh) — the index table wants the
      # human-readable "key:value" form instead of a raw tab.
      src_display=""
      [ -n "$src" ] && src_display="$(echo "$src" | tr '\t' ':')"
      title=$(_adr_title_line "$file" | sed -E "s/^# ${id}: //")
      [ -z "$id" ] && continue
      printf '| %s | %s | %s | %s | %s |\n' "$id" "$title" "$status" "$date" "${src_display:-}"
    done < <(find "$decisions_dir" -maxdepth 1 -name '*.md' ! -name 'index.md' 2>/dev/null | sort)
  } >"$idx_tmp"
  mv "$idx_tmp" "$decisions_dir/index.md"
}

# ── adr_write (task 2.4) ─────────────────────────────────────────────────────

_adr_write_usage() {
  cat >&2 <<'EOF'
Usage: adr-store.sh write --wiki-root <path> --title "<decision>"
         --components "a,b" (--initiative <id> | --ticket <id> | --manual <id>)
         --body-file <path> [--status <status>] [--supersedes <ADR-NNNN>]

--body-file must contain the ADR body starting at `## Context` — the store
assembles frontmatter and the `# ADR-NNNN: <title>` heading itself.

Exit: 0 written or already exists (idempotent skip, ADR_STORE_STATUS=exists
printed either way), 1 usage, 3 write/validation failure, 5 lock timeout.
EOF
}

adr_write() {
  local wiki_root="" title="" components="" initiative="" ticket="" manual=""
  local body_file="" status="proposed" supersedes=""

  while [ $# -gt 0 ]; do
    case "$1" in
    --wiki-root)
      wiki_root="${2:-}"
      shift 2
      ;;
    --title)
      title="${2:-}"
      shift 2
      ;;
    --components)
      components="${2:-}"
      shift 2
      ;;
    --initiative)
      initiative="${2:-}"
      shift 2
      ;;
    --ticket)
      ticket="${2:-}"
      shift 2
      ;;
    --manual)
      manual="${2:-}"
      shift 2
      ;;
    --body-file)
      body_file="${2:-}"
      shift 2
      ;;
    --status)
      status="${2:-}"
      shift 2
      ;;
    --supersedes)
      supersedes="${2:-}"
      shift 2
      ;;
    -h | --help)
      _adr_write_usage
      return 1
      ;;
    *)
      echo "adr-store write: unknown argument '$1'" >&2
      _adr_write_usage
      return 1
      ;;
    esac
  done

  if [ -z "$wiki_root" ] || [ -z "$title" ] || [ -z "$components" ] || [ -z "$body_file" ]; then
    echo "adr-store write: --wiki-root, --title, --components, --body-file are required" >&2
    _adr_write_usage
    return 1
  fi
  [ -f "$body_file" ] || {
    echo "adr-store write: --body-file not found: $body_file" >&2
    return 1
  }

  local source_count=0 source_key="" source_val=""
  [ -n "$initiative" ] && {
    source_count=$((source_count + 1))
    source_key="initiative"
    source_val="$initiative"
  }
  [ -n "$ticket" ] && {
    source_count=$((source_count + 1))
    source_key="ticket"
    source_val="$ticket"
  }
  [ -n "$manual" ] && {
    source_count=$((source_count + 1))
    source_key="manual"
    source_val="$manual"
  }
  if [ "$source_count" -ne 1 ]; then
    echo "adr-store write: exactly one of --initiative/--ticket/--manual is required (got ${source_count})" >&2
    return 1
  fi

  local decisions_dir
  decisions_dir=$(_adr_decisions_dir "$wiki_root")

  _adr_lock "$decisions_dir" || return 5

  local existing
  if existing=$(_adr_exists_for "$decisions_dir" "$source_val"); then
    local fm eid
    fm=$(_adr_extract_frontmatter "$existing")
    eid=$(_adr_fm_get "$fm" "id")
    echo "ADR_STORE_STATUS=exists"
    echo "ADR_ID=${eid}"
    echo "ADR_PATH=${existing}"
    _adr_unlock
    return 0
  fi

  local num id slug filename filepath tmpfile
  num=$(_next_adr_number "$decisions_dir")
  id="ADR-${num}"
  slug=$(_adr_slug "$title")
  filename="${num}-${slug}.md"
  filepath="${decisions_dir}/${filename}"
  tmpfile="${filepath}.tmp.$$"

  mkdir -p "$decisions_dir" 2>/dev/null || true

  {
    echo "---"
    echo "id: ${id}"
    echo "status: ${status}"
    echo "date: $(_adr_now_date)"
    echo "components: [${components}]"
    echo "${source_key}: ${source_val}"
    echo "deciders: []"
    echo "supersedes: \"${supersedes}\""
    echo "superseded_by: \"\""
    echo "---"
    echo
    echo "# ${id}: ${title}"
    echo
    cat "$body_file"
  } >"$tmpfile"

  if ! mv "$tmpfile" "$filepath"; then
    echo "adr-store write: atomic write failed for $filepath" >&2
    rm -f "$tmpfile"
    _adr_unlock
    return 3
  fi

  _adr_regen_index "$decisions_dir"
  _adr_unlock

  echo "ADR_STORE_STATUS=written"
  echo "ADR_ID=${id}"
  echo "ADR_PATH=${filepath}"
  return 0
}

# ── adr_accept (task 2.5) ────────────────────────────────────────────────────

_adr_accept_usage() {
  cat >&2 <<'EOF'
Usage: adr-store.sh accept --wiki-root <path> <ADR-id> --deciders "alice,bob"

A bare CLI a human runs (design.md, settled 2026-09-11) — no tracker
coupling. Refuses to run when CLAUDE_CODE_SESSION_ID is set, since that
means this shell is an agent-spawned session, not a human's own.

Exit: 0 accepted, 1 usage, 2 not found, 3 invalid transition, 4 refused
(agent context), 5 lock timeout.
EOF
}

adr_accept() {
  local wiki_root="" id="" deciders=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --wiki-root)
      wiki_root="${2:-}"
      shift 2
      ;;
    --deciders)
      deciders="${2:-}"
      shift 2
      ;;
    -h | --help)
      _adr_accept_usage
      return 1
      ;;
    *)
      if [ -z "$id" ]; then
        id="$1"
        shift
      else
        echo "adr-store accept: unknown argument '$1'" >&2
        _adr_accept_usage
        return 1
      fi
      ;;
    esac
  done

  if [ -z "$wiki_root" ] || [ -z "$id" ] || [ -z "$deciders" ]; then
    echo "adr-store accept: --wiki-root, an ADR id, and --deciders are required" >&2
    _adr_accept_usage
    return 1
  fi

  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    echo "adr-store accept: refused — running inside an agent session (CLAUDE_CODE_SESSION_ID set). Acceptance is a human action." >&2
    return 4
  fi

  local decisions_dir
  decisions_dir=$(_adr_decisions_dir "$wiki_root")
  _adr_lock "$decisions_dir" || return 5

  local file
  file=$(_adr_find_by_id "$decisions_dir" "$id")
  if [ -z "$file" ]; then
    echo "adr-store accept: no ADR found for id '$id'" >&2
    _adr_unlock
    return 2
  fi

  local fm status
  fm=$(_adr_extract_frontmatter "$file")
  status=$(_adr_fm_get "$fm" "status")
  if [ "$status" != "proposed" ]; then
    echo "adr-store accept: invalid transition '${status} -> accepted' (only proposed -> accepted is valid)" >&2
    _adr_unlock
    return 3
  fi

  local tmpfile="${file}.tmp.$$"
  awk -v deciders="[${deciders}]" '
    /^status: / { print "status: accepted"; next }
    /^deciders: / { print "deciders: " deciders; next }
    { print }
  ' "$file" >"$tmpfile"
  mv "$tmpfile" "$file"

  local supersedes real_id
  supersedes=$(_adr_fm_get "$fm" "supersedes")
  real_id=$(_adr_fm_get "$fm" "id")
  if [ -n "$supersedes" ]; then
    _adr_supersede_locked "$decisions_dir" "$supersedes" "$real_id" || {
      echo "adr-store accept: accepted ${real_id} but automatic supersession of ${supersedes} failed — run 'adr-store.sh supersede' manually" >&2
    }
  fi

  _adr_regen_index "$decisions_dir"
  _adr_unlock

  echo "ADR_STORE_STATUS=accepted"
  echo "ADR_ID=${real_id}"
  return 0
}

# ── adr_supersede (task 2.6) ─────────────────────────────────────────────────
# Internal, lock-already-held variant, called both by adr_accept (automatic
# supersession) and by the public adr_supersede CLI entry below.
_adr_supersede_locked() {
  local decisions_dir="$1" old_id="$2" new_id="$3"
  local old_file new_file
  old_file=$(_adr_find_by_id "$decisions_dir" "$old_id")
  new_file=$(_adr_find_by_id "$decisions_dir" "$new_id")
  [ -z "$old_file" ] && {
    echo "adr-store supersede: original '$old_id' not found" >&2
    return 2
  }
  [ -z "$new_file" ] && {
    echo "adr-store supersede: replacement '$new_id' not found" >&2
    return 2
  }

  local new_fm new_status old_fm old_status
  new_fm=$(_adr_extract_frontmatter "$new_file")
  new_status=$(_adr_fm_get "$new_fm" "status")
  old_fm=$(_adr_extract_frontmatter "$old_file")
  old_status=$(_adr_fm_get "$old_fm" "status")

  if [ "$new_status" != "accepted" ]; then
    echo "adr-store supersede: replacement '$new_id' is not accepted (status=${new_status}) — supersession is permitted only once the replacement is accepted" >&2
    return 3
  fi
  if [ "$old_status" != "accepted" ]; then
    echo "adr-store supersede: original '$old_id' is not accepted (status=${old_status})" >&2
    return 3
  fi

  local real_old_id tmpfile="${old_file}.tmp.$$"
  real_old_id=$(_adr_fm_get "$old_fm" "id")
  awk -v newid="$new_id" '
    /^status: / { print "status: superseded"; next }
    /^superseded_by: / { print "superseded_by: \"" newid "\""; next }
    { print }
  ' "$old_file" >"$tmpfile"
  mv "$tmpfile" "$old_file"
  return 0
}

_adr_supersede_usage() {
  cat >&2 <<'EOF'
Usage: adr-store.sh supersede --wiki-root <path> <old-ADR-id> <new-ADR-id>

Sets superseded_by on <old-ADR-id> and flips it to superseded. Only valid
once <new-ADR-id> is itself accepted — ordinarily this runs automatically
from `adr-store.sh accept` when the accepted ADR carries `supersedes:`.

Exit: 0 done, 1 usage, 2 not found, 3 replacement not yet accepted, 5 lock timeout.
EOF
}

adr_supersede() {
  local wiki_root="" old_id="" new_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --wiki-root)
      wiki_root="${2:-}"
      shift 2
      ;;
    -h | --help)
      _adr_supersede_usage
      return 1
      ;;
    *)
      if [ -z "$old_id" ]; then old_id="$1"; elif [ -z "$new_id" ]; then new_id="$1"; else
        echo "adr-store supersede: unexpected argument '$1'" >&2
        return 1
      fi
      shift
      ;;
    esac
  done
  if [ -z "$wiki_root" ] || [ -z "$old_id" ] || [ -z "$new_id" ]; then
    echo "adr-store supersede: --wiki-root, an old id, and a new id are required" >&2
    _adr_supersede_usage
    return 1
  fi

  local decisions_dir rc=0
  decisions_dir=$(_adr_decisions_dir "$wiki_root")
  _adr_lock "$decisions_dir" || return 5
  _adr_supersede_locked "$decisions_dir" "$old_id" "$new_id" || rc=$?
  [ "$rc" -eq 0 ] && _adr_regen_index "$decisions_dir"
  _adr_unlock
  [ "$rc" -eq 0 ] && echo "ADR_STORE_STATUS=superseded"
  return "$rc"
}

# ── adr_query_by_component (task 2.7) ────────────────────────────────────────

_adr_query_usage() {
  cat >&2 <<'EOF'
Usage: adr-store.sh query --wiki-root <path> --components "a,b"

Prints one "<ADR-id>\t<path>" line per ADR whose components: intersect the
given set. Exit 0 with output if any match, 1 if none (not an error).
EOF
}

adr_query_by_component() {
  local wiki_root="" components=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --wiki-root)
      wiki_root="${2:-}"
      shift 2
      ;;
    --components)
      components="${2:-}"
      shift 2
      ;;
    -h | --help)
      _adr_query_usage
      return 1
      ;;
    *)
      echo "adr-store query: unknown argument '$1'" >&2
      _adr_query_usage
      return 1
      ;;
    esac
  done
  [ -z "$wiki_root" ] || [ -z "$components" ] && {
    echo "adr-store query: --wiki-root and --components are required" >&2
    _adr_query_usage
    return 1
  }

  local decisions_dir file fm id fcomp found=1
  decisions_dir=$(_adr_decisions_dir "$wiki_root")
  [ -d "$decisions_dir" ] || return 1

  local want=",${components//, /,},"
  want=$(echo "$want" | tr -d ' ')

  while IFS= read -r file; do
    fm=$(_adr_extract_frontmatter "$file")
    id=$(_adr_fm_get "$fm" "id")
    while IFS= read -r fcomp; do
      [ -z "$fcomp" ] && continue
      case "$want" in
      *",${fcomp},"*)
        printf '%s\t%s\n' "$id" "$file"
        found=0
        break
        ;;
      esac
    done < <(_adr_fm_list "$fm" "components")
  done < <(find "$decisions_dir" -maxdepth 1 -name '*.md' ! -name 'index.md' 2>/dev/null | sort)

  return "$found"
}

# ── CLI dispatch ──────────────────────────────────────────────────────────────

_adr_store_cli_usage() {
  cat >&2 <<'EOF'
Usage: adr-store.sh <write|accept|supersede|query|exists> [args]

  write     --wiki-root <p> --title <t> --components <csv>
            (--initiative <id>|--ticket <id>|--manual <id>) --body-file <p>
            [--status <s>] [--supersedes <id>]
  accept    --wiki-root <p> <ADR-id> --deciders <csv>   (humans only)
  supersede --wiki-root <p> <old-id> <new-id>
  query     --wiki-root <p> --components <csv>
  exists    --wiki-root <p> <source-id>

Run 'adr-store.sh <subcommand> --help' for details on each.
EOF
}

_adr_store_cli_exists() {
  local wiki_root="" id=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --wiki-root)
      wiki_root="${2:-}"
      shift 2
      ;;
    *)
      id="$1"
      shift
      ;;
    esac
  done
  [ -z "$wiki_root" ] || [ -z "$id" ] && {
    echo "adr-store exists: --wiki-root and a source id are required" >&2
    return 1
  }
  local decisions_dir found
  decisions_dir=$(_adr_decisions_dir "$wiki_root")
  if found=$(_adr_exists_for "$decisions_dir" "$id"); then
    echo "ADR_STORE_EXISTS=true"
    echo "ADR_PATH=${found}"
    return 0
  fi
  echo "ADR_STORE_EXISTS=false"
  return 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
  write)
    adr_write "$@"
    exit $?
    ;;
  accept)
    adr_accept "$@"
    exit $?
    ;;
  supersede)
    adr_supersede "$@"
    exit $?
    ;;
  query)
    adr_query_by_component "$@"
    exit $?
    ;;
  exists)
    _adr_store_cli_exists "$@"
    exit $?
    ;;
  -h | --help | "")
    _adr_store_cli_usage
    exit 1
    ;;
  *)
    echo "adr-store.sh: unknown subcommand '$cmd'" >&2
    _adr_store_cli_usage
    exit 1
    ;;
  esac
fi
