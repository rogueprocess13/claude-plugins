#!/usr/bin/env bash
# check-skill-size.sh — CI drift gate: prompt material (skills, agents, the
# skill preambles, personas) may only shrink, new skills must fit a fixed
# ceiling, and the structural rules that keep size creep visible must hold.
#
# A SKILL.md body is loaded into the agent's context on every invocation and
# stays there; after auto-compaction Claude Code re-attaches only its first
# 5,000 tokens. Nothing else measures it, so without this gate every later
# reduction would be undone by ordinary drift.
#
# What counts (repo-relative, .git/.claude/node_modules/fixtures pruned):
#   - */skills/*/SKILL.md            every rule below
#   - */agents/*.md                  ratchet + frontmatter
#   - */lib/skill-preamble*.md       ratchet only
#   - */personas/**/*.md             ratchet only
# Bytes are whole-file; lines are body lines after the frontmatter's closing
# "---" (a final unterminated line counts). Lines inside a
# <!-- GENERATED:<id> START --> / END pair are excluded from both.
#
# Rules (one "KIND: detail" line per finding; warnings never fail by default):
#   GROWTH / RAISE / SLACK / STALE   ratchet against scripts/skill-size-baseline.tsv
#                                    (RAISE: an entry above the base revision's
#                                    value without "# allow-growth: <reason>"
#                                    directly above it)
#   CEILING                          unlisted SKILL.md over 500 lines / 20,000 bytes
#   CRLF                             any \r in an in-scope file
#   FRONTMATTER                      presence, name/description limits, key allowlist
#   FENCE / FENCE-WARN               fenced block body > 60 (fail) / > 25 (warn) lines,
#                                    unless "<!-- size-gate: template -->" is directly above
#   GENERATED                        a generated block over 6,144 bytes or unterminated
#   REF-DEAD / REF-CHAIN / REF-ARG   references/ and templates/ link rules (fail)
#   REF-ORPHAN / REF-TOC             (warn)
#   CONTEXT / CONTEXT-GROWTH         per-manifest byte totals from prompt_manifests,
#                                    ratcheted in scripts/skill-context-baseline.tsv
#
# Usage:
#   check-skill-size.sh [--root DIR] [--baseline FILE] [--context-baseline FILE]
#                       [--base-file FILE] [--table FILE] [--strict]
#                       [--regenerate [--allow-over-ceiling]]
#   SKILL_SIZE_BASE      git ref the RAISE rule reads the baseline from
#                        (default origin/main; --base-file overrides it)
#   --strict             SLACK, STALE and CONTEXT-SLACK fail instead of warn
#   --regenerate         rewrite both baselines: min(actual, previous), add new
#                        paths within the ceiling, drop removed paths; never raises
#
# Exit codes:
#   0  within budget (warnings may have been printed)
#   1  violation(s)
#   2  usage error (bad flag, missing root)
set -euo pipefail

# Scan roots (ERE over repo-relative paths) and frontmatter allowlists.
SKILL_GLOBS=('^[^/]+/skills/[^/]+/SKILL\.md$')
AGENT_GLOBS=('^[^/]+/agents/[^/]+\.md$')
RATCHET_ONLY_GLOBS=('^[^/]+/lib/skill-preamble[^/]*\.md$' '^[^/]+/personas/.+\.md$')
SKILL_KEYS=(name description allowed-tools category tags)
AGENT_KEYS=(name description tools)

CEILING_LINES=500
CEILING_BYTES=20000
FENCE_FAIL=60
FENCE_WARN=25
GENERATED_CAP=6144
TOC_LINES=100
TEMPLATE_MARKER='<!-- size-gate: template -->'
REF_MENTION_RE='(^|\]\(|`|[[:space:]])(\./)?(references|templates)/[A-Za-z0-9._-]+\.md'
BARE_ARG_RE='(^|[^\\])\$([0-9]|ARGUMENTS)'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE=""
CONTEXT_BASELINE=""
BASE_FILE=""
TABLE=""
STRICT=0
REGENERATE=0
ALLOW_OVER_CEILING=0

_need_value() {
  [ "$1" -ge 2 ] || {
    echo "check-skill-size: $2 needs a value" >&2
    exit 2
  }
}

while [ $# -gt 0 ]; do
  case "$1" in
  --root)
    _need_value $# "$1"
    ROOT="$2"
    shift 2
    ;;
  --baseline)
    _need_value $# "$1"
    BASELINE="$2"
    shift 2
    ;;
  --context-baseline)
    _need_value $# "$1"
    CONTEXT_BASELINE="$2"
    shift 2
    ;;
  --base-file)
    _need_value $# "$1"
    BASE_FILE="$2"
    shift 2
    ;;
  --table)
    _need_value $# "$1"
    TABLE="$2"
    shift 2
    ;;
  --strict)
    STRICT=1
    shift
    ;;
  --regenerate)
    REGENERATE=1
    shift
    ;;
  --allow-over-ceiling)
    ALLOW_OVER_CEILING=1
    shift
    ;;
  *)
    echo "check-skill-size: unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

[ -d "$ROOT" ] || {
  echo "check-skill-size: root not found: $ROOT" >&2
  exit 2
}
ROOT="$(cd "$ROOT" && pwd)"
[ -n "$BASELINE" ] || BASELINE="$ROOT/scripts/skill-size-baseline.tsv"
[ -n "$CONTEXT_BASELINE" ] || CONTEXT_BASELINE="$ROOT/scripts/skill-context-baseline.tsv"
[ -n "$TABLE" ] || TABLE="$ROOT/ticket-auto-pipeline/skills/ticket-flow/dispatch-table.json"

drift=0
_fail() {
  echo "$1" >&2
  drift=1
}
_warn() { echo "$1" >&2; }
# A warning that --strict promotes to a failure.
_soft() { if [ "$STRICT" -eq 1 ]; then _fail "$1"; else _warn "$1"; fi; }

_matches_any() { # $1=path, rest=ERE list
  local p="$1" re
  shift
  for re in "$@"; do
    [[ "$p" =~ $re ]] && return 0
  done
  return 1
}

_kind() {
  if _matches_any "$1" "${SKILL_GLOBS[@]}"; then
    echo skill
  elif _matches_any "$1" "${AGENT_GLOBS[@]}"; then
    echo agent
  elif _matches_any "$1" "${RATCHET_ONLY_GLOBS[@]}"; then
    echo ratchet
  else
    echo none
  fi
}

# Frontmatter block (without the --- lines), only if line 1 is exactly ---.
# Returns 1 when there is no closed frontmatter.
_frontmatter() {
  awk 'NR == 1 { if ($0 != "---") exit 1; next }
       $0 == "---" { closed = 1; exit 0 }
       { print }
       END { if (!closed) exit 1 }' "$1"
}

# One pass: prints "BLOCK <id> <bytes>" / "UNTERM <id>" per generated block,
# then "METRICS <generated_bytes> <body_lines>" (body lines exclude the
# frontmatter and generated interiors; awk's NR counts an unterminated last line).
_metrics() {
  LC_ALL=C awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---" { infm = 0; fmend = NR; next }
    infm { next }
    gen != "" {
      if ($0 == "<!-- GENERATED:" gen " END -->") {
        print "BLOCK", gen, gbytes; gen = ""; next
      }
      gbytes += length($0) + 1; gtotal += length($0) + 1; glines++; next
    }
    match($0, /^<!-- GENERATED:[^ ]+ START -->$/) {
      gen = substr($0, 16, RLENGTH - 25); gbytes = 0
    }
    END {
      if (gen != "") print "UNTERM", gen
      if (infm) fmend = 0
      print "METRICS", gtotal + 0, NR - fmend - glines
    }' "$1"
}

_bytes() { wc -c <"$1" | tr -d ' '; }

# ── Scan ────────────────────────────────────────────────────────────────────
mapfile -t ALL_MD < <(
  cd "$ROOT" &&
    find . \( -name .git -o -name .claude -o -name node_modules -o -name fixtures \) -prune -o \
      -type f -name '*.md' -print | sed 's|^\./||' | LC_ALL=C sort
)

declare -A KIND=() A_BYTES=() A_LINES=()
FILES=()
for f in "${ALL_MD[@]}"; do
  k="$(_kind "$f")"
  [ "$k" != none ] || continue
  FILES+=("$f")
  KIND[$f]="$k"
done

for f in "${FILES[@]}"; do
  abs="$ROOT/$f"
  if grep -q $'\r' "$abs"; then
    _fail "CRLF: $f contains carriage returns"
  fi
  gen_total=0 body=0
  while read -r tag a b; do
    case "$tag" in
    BLOCK)
      if [ "$b" -gt "$GENERATED_CAP" ]; then
        _fail "GENERATED: $f $a $b > $GENERATED_CAP"
      else
        echo "GENERATED: $f $a $b bytes"
      fi
      ;;
    UNTERM) _fail "GENERATED: $f $a unterminated" ;;
    METRICS)
      gen_total="$a"
      body="$b"
      ;;
    esac
  done < <(_metrics "$abs")
  A_BYTES[$f]=$(($(_bytes "$abs") - gen_total))
  A_LINES[$f]="$body"
done

# ── Baseline parsing ────────────────────────────────────────────────────────
# Comment lines directly above an entry (no blank line between) attach to it.
declare -A B_BYTES=() B_LINES=() B_COMMENTS=() B_PREV=()
B_ORDER=()
_load_baseline() { # $1=file $2=bytes-array-name $3=lines-array-name ($3 may be "")
  local file="$1" line pending="" prev="" p v l
  local -n _bb="$2"
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    '') pending="" prev="" ;;
    '#'*)
      pending+="$line"$'\n'
      prev="$line"
      ;;
    *)
      IFS=$'\t' read -r p v l <<<"$line"
      _bb[$p]="$v"
      if [ -n "$3" ]; then
        local -n _bl="$3"
        _bl[$p]="${l:-0}"
      fi
      if [ "$2" = B_BYTES ]; then
        B_COMMENTS[$p]="$pending"
        B_PREV[$p]="$prev"
        B_ORDER+=("$p")
      fi
      pending="" prev=""
      ;;
    esac
  done <"$file"
}
_load_baseline "$BASELINE" B_BYTES B_LINES

_is_skill_path() { _matches_any "$1" "${SKILL_GLOBS[@]}"; }
_over_ceiling() { [ "$1" -gt "$CEILING_BYTES" ] || [ "$2" -gt "$CEILING_LINES" ]; }

# ── Context report inputs ───────────────────────────────────────────────────
# Manifest labels resolve to repo paths under the plugin that owns the table
# (<plugin>/skills/ticket-flow/dispatch-table.json), never through $HOME.
declare -A C_ACTUAL=()
C_ORDER=()
_resolve_label() { # $1=plugin-dir $2=label → repo path or nonzero
  local pd="$1" label="$2" cand
  case "$label" in
  plugin:*) cand=("$pd/${label#plugin:}") ;;
  lib:*) cand=("$pd/lib/${label#lib:}") ;;
  # home: is ~/.claude/skills/ on a host: top-level docs, lib/, and synced skills.
  home:*) cand=("$pd/${label#home:}" "$pd/lib/${label#home:}" "$pd/skills/${label#home:}") ;;
  *) return 1 ;;
  esac
  local c
  for c in "${cand[@]}"; do
    [ -f "$c" ] && {
      echo "$c"
      return 0
    }
  done
  return 1
}
if [ -f "$TABLE" ]; then
  plugin_dir="$(cd "$(dirname "$TABLE")/../.." && pwd)"
  while IFS=$'\t' read -r m label; do
    [ -n "$m" ] || continue
    if [ -z "${C_ACTUAL[$m]+x}" ]; then
      C_ACTUAL[$m]=0
      C_ORDER+=("$m")
    fi
    [ -n "$label" ] || continue
    if path="$(_resolve_label "$plugin_dir" "$label")"; then
      C_ACTUAL[$m]=$((C_ACTUAL[$m] + $(_bytes "$path")))
    else
      _warn "CONTEXT-WARN: $m unresolved $label"
    fi
  done < <(jq -r '(.prompt_manifests // {}) | to_entries[] | .key as $k |
    if (.value.files // []) == [] then $k else (.value.files[] | "\($k)\t\(.)") end' "$TABLE")
fi

# ── Regenerate ──────────────────────────────────────────────────────────────
_min() { if [ "$1" -lt "$2" ]; then echo "$1"; else echo "$2"; fi; }

if [ "$REGENERATE" -eq 1 ]; then
  tmp="$BASELINE.tmp"
  mkdir -p "$(dirname "$BASELINE")"
  : >"$tmp"
  n=0
  for f in "${FILES[@]}"; do
    ab="${A_BYTES[$f]}" al="${A_LINES[$f]}"
    if [ -n "${B_BYTES[$f]+x}" ]; then
      printf '%s' "${B_COMMENTS[$f]}" >>"$tmp"
      printf '%s\t%s\t%s\n' "$f" "$(_min "$ab" "${B_BYTES[$f]}")" "$(_min "$al" "${B_LINES[$f]}")" >>"$tmp"
    elif [ "${KIND[$f]}" = skill ] && _over_ceiling "$ab" "$al" && [ "$ALLOW_OVER_CEILING" -eq 0 ]; then
      _warn "CEILING: $f not added to baseline ($ab bytes, $al lines)"
      continue
    else
      printf '%s\t%s\t%s\n' "$f" "$ab" "$al" >>"$tmp"
    fi
    n=$((n + 1))
  done
  mv "$tmp" "$BASELINE"

  if [ -f "$TABLE" ]; then
    declare -A CB=()
    _load_baseline "$CONTEXT_BASELINE" CB ""
    ctmp="$CONTEXT_BASELINE.tmp"
    : >"$ctmp"
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      v="${C_ACTUAL[$m]}"
      [ -z "${CB[$m]+x}" ] || v="$(_min "$v" "${CB[$m]}")"
      printf '%s\t%s\n' "$m" "$v" >>"$ctmp"
    done < <(printf '%s\n' "${C_ORDER[@]}" | LC_ALL=C sort)
    mv "$ctmp" "$CONTEXT_BASELINE"
  fi
  echo "check-skill-size: regenerated $n entries in $(basename "$BASELINE")"
  exit 0
fi

# ── Ratchet, slack, ceiling ─────────────────────────────────────────────────
for f in "${FILES[@]}"; do
  ab="${A_BYTES[$f]}" al="${A_LINES[$f]}"
  if [ -n "${B_BYTES[$f]+x}" ]; then
    bb="${B_BYTES[$f]}" bl="${B_LINES[$f]}"
    [ "$ab" -le "$bb" ] || _fail "GROWTH: $f bytes $ab > $bb"
    [ "$al" -le "$bl" ] || _fail "GROWTH: $f lines $al > $bl"
    [ "$ab" -ge "$bb" ] || _soft "SLACK: $f bytes $bb > $ab"
    [ "$al" -ge "$bl" ] || _soft "SLACK: $f lines $bl > $al"
  elif [ "${KIND[$f]}" = skill ]; then
    [ "$al" -le "$CEILING_LINES" ] || _fail "CEILING: $f lines $al > $CEILING_LINES"
    [ "$ab" -le "$CEILING_BYTES" ] || _fail "CEILING: $f bytes $ab > $CEILING_BYTES"
  fi
done
for p in "${B_ORDER[@]}"; do
  [ -n "${KIND[$p]+x}" ] || _soft "STALE: $p is in the baseline but no longer exists"
done

# ── Raises against the base revision ────────────────────────────────────────
base_content=""
base_ok=0
if [ -n "$BASE_FILE" ]; then
  [ -f "$BASE_FILE" ] && base_content="$(cat "$BASE_FILE")" && base_ok=1
else
  rel="${BASELINE#"$ROOT"/}"
  if base_content="$(git -C "$ROOT" show "${SKILL_SIZE_BASE:-origin/main}:$rel" 2>/dev/null)"; then
    base_ok=1
  fi
fi
if [ "$base_ok" -eq 1 ]; then
  declare -A R_BYTES=() R_LINES=()
  _load_baseline <(printf '%s\n' "$base_content") R_BYTES R_LINES
  for p in "${B_ORDER[@]}"; do
    case "${B_PREV[$p]}" in '# allow-growth: '?*) continue ;; esac
    if [ -n "${R_BYTES[$p]+x}" ]; then
      if [ "${B_BYTES[$p]}" -gt "${R_BYTES[$p]}" ] || [ "${B_LINES[$p]}" -gt "${R_LINES[$p]}" ]; then
        _fail "RAISE: $p ${B_BYTES[$p]}/${B_LINES[$p]} > base ${R_BYTES[$p]}/${R_LINES[$p]} — add '# allow-growth: <reason>' above the entry"
      fi
    elif _is_skill_path "$p" && _over_ceiling "${B_BYTES[$p]}" "${B_LINES[$p]}"; then
      # A hand-added entry must not smuggle a new skill past the ceiling.
      _fail "RAISE: $p ${B_BYTES[$p]}/${B_LINES[$p]} added over the ceiling — add '# allow-growth: <reason>' above the entry"
    fi
  done
else
  _warn "WARN: base baseline unavailable (${BASE_FILE:-${SKILL_SIZE_BASE:-origin/main}}) — RAISE rule skipped"
fi

# ── Frontmatter ─────────────────────────────────────────────────────────────
# Scalar value of top-level key $1 from frontmatter on stdin. Folded/literal
# blocks join their indented continuation lines with single spaces;
# surrounding quotes are dropped.
_fm_val() {
  awk -v key="$1" '
    found && /^[[:space:]]+/ { sub(/^[[:space:]]+/, ""); out = out (out == "" ? "" : " ") $0; next }
    found { exit }
    index($0, key ":") == 1 {
      v = substr($0, length(key) + 2); sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      if (v ~ /^[>|][-+]?$/) v = ""
      out = v; found = 1
    }
    END {
      q = sprintf("%c", 39)
      if (out ~ /^".*"$/ || (substr(out, 1, 1) == q && substr(out, length(out)) == q)) out = substr(out, 2, length(out) - 2)
      printf "%s", out
    }'
}

_check_frontmatter() { # $1=path $2=kind
  local f="$1" fm key name="" desc="" allowed=() k ok
  if ! fm="$(_frontmatter "$ROOT/$f")"; then
    _fail "FRONTMATTER: $f missing"
    return
  fi
  if [ "$2" = skill ]; then allowed=("${SKILL_KEYS[@]}"); else allowed=("${AGENT_KEYS[@]}"); fi
  while IFS= read -r key; do
    ok=0
    for k in "${allowed[@]}"; do [ "$k" = "$key" ] && ok=1; done
    [ "$ok" -eq 1 ] || _fail "FRONTMATTER: $f unknown key $key"
  done < <(sed -nE 's/^([A-Za-z0-9_-]+):.*/\1/p' <<<"$fm")
  name="$(_fm_val name <<<"$fm")"
  desc="$(_fm_val description <<<"$fm")"
  if [ -z "$name" ]; then
    _fail "FRONTMATTER: $f name missing"
  elif [ "${#name}" -gt 64 ] || ! [[ "$name" =~ ^[a-z0-9-]+$ ]]; then
    _fail "FRONTMATTER: $f name invalid"
  fi
  if [ -z "$desc" ]; then
    _fail "FRONTMATTER: $f description missing"
  else
    [ "${#desc}" -le 1024 ] || _fail "FRONTMATTER: $f description exceeds 1024"
    if [[ "$desc" =~ \<[a-zA-Z/] ]]; then _fail "FRONTMATTER: $f description contains a tag"; fi
  fi
}
for f in "${FILES[@]}"; do
  case "${KIND[$f]}" in skill | agent) _check_frontmatter "$f" "${KIND[$f]}" ;; esac
done

# ── Fences (SKILL.md only) ──────────────────────────────────────────────────
_fences() {
  awk -v marker="$TEMPLATE_MARKER" -v fail="$FENCE_FAIL" -v warn="$FENCE_WARN" '
    function report() {
      if (marked) return
      if (n > fail) print "FAIL", start, n
      else if (n > warn) print "WARN", start, n
    }
    !open && match($0, /^[[:space:]]*(```+|~~~+)/) {
      run = substr($0, RSTART, RLENGTH); sub(/^[[:space:]]+/, "", run)
      ch = substr(run, 1, 1); len = length(run)
      open = 1; start = NR; n = 0; p = prev; gsub(/^[[:space:]]+|[[:space:]]+$/, "", p); marked = (p == marker); prev = $0; next
    }
    open {
      line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line ~ (ch == "`" ? "^`+$" : "^~+$") && length(line) >= len) {
        report(); open = 0; prev = $0; next
      }
      n++
    }
    { prev = $0 }
    END { if (open) report() }' "$1"
}
for f in "${FILES[@]}"; do
  [ "${KIND[$f]}" = skill ] || continue
  while read -r lvl line n; do
    case "$lvl" in
    FAIL) _fail "FENCE: $f:$line $n lines > $FENCE_FAIL" ;;
    WARN) _warn "FENCE-WARN: $f:$line $n lines" ;;
    esac
  done < <(_fences "$ROOT/$f")
done

# ── Reference files ─────────────────────────────────────────────────────────
_mentions() { # $1=file → "references/x.md" per mention, unique
  grep -oE "$REF_MENTION_RE" "$1" 2>/dev/null |
    sed -E 's#.*((references|templates)/[A-Za-z0-9._-]+\.md)$#\1#' | LC_ALL=C sort -u || true
}
for f in "${FILES[@]}"; do
  [ "${KIND[$f]}" = skill ] || continue
  sdir="$(dirname "$f")"
  skill="$(basename "$sdir")"
  mentions="$(_mentions "$ROOT/$f")"
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    [ -f "$ROOT/$sdir/$m" ] || _fail "REF-DEAD: $skill $sdir/$m"
  done <<<"$mentions"
  for r in "$ROOT/$sdir"/references/*.md "$ROOT/$sdir"/templates/*.md; do
    [ -f "$r" ] || continue
    rel="${r#"$ROOT/$sdir/"}"
    grep -qxF -- "$rel" <<<"$mentions" || _warn "REF-ORPHAN: $sdir/$rel"
    while IFS= read -r t; do
      [ -n "$t" ] && [ "$t" != "$rel" ] || continue
      _fail "REF-CHAIN: $sdir/$rel -> $t"
    done < <(_mentions "$r")
    lines="$(awk 'END{print NR}' "$r")"
    if [ "$lines" -gt "$TOC_LINES" ] && ! grep -q '^## Contents' "$r"; then
      _warn "REF-TOC: $sdir/$rel $lines lines without ## Contents"
    fi
    while IFS=: read -r ln _; do
      [ -n "$ln" ] && _fail "REF-ARG: $sdir/$rel:$ln"
    done < <(grep -nE "$BARE_ARG_RE" "$r" || true)
  done
done

# ── Effective context ───────────────────────────────────────────────────────
if [ "${#C_ORDER[@]}" -gt 0 ]; then
  declare -A CB=()
  _load_baseline "$CONTEXT_BASELINE" CB ""
  for m in "${C_ORDER[@]}"; do
    v="${C_ACTUAL[$m]}"
    echo "CONTEXT: $m $v"
    [ -n "${CB[$m]+x}" ] || continue
    [ "$v" -le "${CB[$m]}" ] || _fail "CONTEXT-GROWTH: $m $v > ${CB[$m]}"
    [ "$v" -ge "${CB[$m]}" ] || _soft "CONTEXT-SLACK: $m ${CB[$m]} > $v"
  done
fi

# ── Exceptions summary ──────────────────────────────────────────────────────
exc=()
for p in "${B_ORDER[@]}"; do
  _is_skill_path "$p" && _over_ceiling "${B_BYTES[$p]}" "${B_LINES[$p]}" || continue
  reason="$(sed -n 's/^# exception: //p' <<<"${B_COMMENTS[$p]}" | tail -1)"
  exc+=("  $p ${B_BYTES[$p]} bytes ${B_LINES[$p]} lines — ${reason:-(no reason recorded)}")
done
echo "EXCEPTIONS: ${#exc[@]}"
[ "${#exc[@]}" -eq 0 ] || printf '%s\n' "${exc[@]}"

if [ "$drift" -ne 0 ]; then
  echo "check-skill-size: FAIL — prompt material outside its budget (see lines above)" >&2
  exit 1
fi
echo "check-skill-size: OK — ${#FILES[@]} files within baseline"
