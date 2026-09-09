#!/usr/bin/env bash
# wiki-check.sh — deterministic freshness + completeness lint for WIKI_ROOT.
#
# Implements the freshness contract from the wiki-cross-repo-knowledge-layer
# change (#335, §5): per-file frontmatter (verified_at, verified_against
# {repo, sha}, stale_after, verified), broken `related:` links, backticked
# class names that don't resolve to any known repo (best-effort), and a
# freshness classification (fresh|stale|decayed) derived from commit activity
# since verified_against plus stale_after.
#
# The wiki-side contract this implements was written from the issue's own
# prose spec — the external reference commit
# (credit-network-biz/wiki@38fdc17) was not accessible when this was built.
#
# Zero LLM involvement — pure bash, modeled on prescan-check.sh's freshness
# gate. Fast by design: exactly one `git rev-list --count` per file (not per
# line), and the class-name check is capped and short-circuits per identifier.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

# ── Defaults (env-overridable, mirrors prescan-check.sh's convention) ──────────

DECAY_COMMIT_LIMIT="${WIKI_CHECK_DECAY_COMMIT_LIMIT:-10}"
MAX_CLASS_CHECKS="${WIKI_CHECK_MAX_CLASS_CHECKS:-40}"

usage() {
  cat >&2 <<'EOF'
Usage: wiki-check.sh --wiki-root <path> [options]

Lints every markdown file under WIKI_ROOT (excluding index.md) against the
freshness contract: frontmatter completeness, broken `related:` links,
backticked class names unresolved against any repo under --repos-root, and a
fresh|stale|decayed classification.

Options:
  --wiki-root <path>    Path to the wiki root (required)
  --repos-root <path>   REPOS_ROOT, for resolving verified_against.repo and
                         checking backticked class names. Optional — when
                         omitted, freshness falls back to age-only and the
                         class-name check is skipped entirely.
  --file <path>         Check exactly one file instead of scanning the tree
                         (path relative to --wiki-root, or absolute).
  --changed-only        Only check files with uncommitted changes in
                         WIKI_ROOT's own git repo (git status --porcelain).
                         Falls back to a full scan if WIKI_ROOT isn't a git
                         repo.
  --help, -h            Show this message

Output: one `WIKI_CHECK|...` line per file, then one `WIKI_CHECK_SUMMARY|...`
line. See the field list in each line — this is a flat, greppable format, not
JSON, to match this plugin's other lib scripts.

Exit: 0 no issues found, 1 issues found (incomplete frontmatter, broken
related links, or a decayed file), 2 usage/setup error.
EOF
  exit 2
}

# ── Repo resolution (best-effort, mirrors ticket-prescan's slug derivation) ────

_derive_slug() {
  basename "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'
}

# Resolves a verified_against.repo value to a repo directory under
# --repos-root. Tries an exact directory name match first, then falls back to
# comparing derived slugs against every repo found under --repos-root
# (maxdepth 3, same as ticket-prescan's own enumeration). Emits the resolved
# path on stdout, or nothing if unresolved.
_resolve_repo_path() {
  local repos_root="$1" repo="$2"
  [ -z "$repos_root" ] || [ -z "$repo" ] && return 0
  [ -d "$repos_root/$repo" ] && {
    echo "$repos_root/$repo"
    return 0
  }
  local want
  want=$(_derive_slug "$repo")
  local dir
  while IFS= read -r -d '' dir; do
    if [ "$(_derive_slug "$dir")" = "$want" ]; then
      echo "$dir"
      return 0
    fi
  done < <(find "$repos_root" -maxdepth 3 -name ".git" -printf '%h\0' 2>/dev/null || true)
  return 0
}

# ── Frontmatter extraction ──────────────────────────────────────────────────────
# Frontmatter is expected as single-line flow-style YAML between the first two
# `---` lines (matches the schema wiki-maintenance's SKILL.md writes). No YAML
# parser dependency — this is an internal contract, not user-authored YAML.

_extract_frontmatter() {
  local file="$1"
  awk '
    NR==1 && $0 != "---" { exit }
    NR==1 { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm { print }
  ' "$file"
}

_fm_get() {
  # _fm_get <frontmatter-text> <key>
  # `|| true` on the whole pipe is load-bearing under `set -eo pipefail`: grep
  # exiting 1 on "key not present" (the normal, expected case for an
  # incomplete-frontmatter file — the thing this script exists to detect)
  # would otherwise abort the caller via the pipefail-computed exit status.
  echo "$1" | grep -m1 "^${2}:" | sed "s/^${2}: *//" | sed 's/^"//; s/"$//' || true
}

# ── Per-file check ───────────────────────────────────────────────────────────

_check_file() {
  local file="$1" wiki_root="$2" repos_root="$3"
  local rel="${file#"$wiki_root"/}"

  local lines
  lines=$(wc -l <"$file" | tr -d ' ')

  local fm
  fm=$(_extract_frontmatter "$file")

  local verified_at verified_against stale_after verified
  verified_at=$(_fm_get "$fm" "verified_at")
  verified_against=$(_fm_get "$fm" "verified_against")
  stale_after=$(_fm_get "$fm" "stale_after")
  verified=$(_fm_get "$fm" "verified")

  local va_repo="" va_sha=""
  if [ -n "$verified_against" ]; then
    # `|| true` guards each pipe the same way as _fm_get above.
    va_repo=$(echo "$verified_against" | grep -oE 'repo: *"?[A-Za-z0-9_.-]+"?' | head -1 | sed 's/repo: *"\{0,1\}//; s/"$//' || true)
    va_sha=$(echo "$verified_against" | grep -oE 'sha: *"?[0-9a-fA-F]+"?' | head -1 | sed 's/sha: *"\{0,1\}//; s/"$//' || true)
  fi

  # ── Frontmatter completeness ──
  local missing=()
  if [ -z "$verified_at" ]; then missing+=("verified_at"); fi
  if [ -z "$va_repo" ] || [ -z "$va_sha" ]; then missing+=("verified_against"); fi
  if [ -z "$stale_after" ]; then missing+=("stale_after"); fi
  case "$verified" in
  unverified | machine-verified | human-reviewed) ;;
  *) missing+=("verified") ;;
  esac

  local fm_status="complete"
  if [ "${#missing[@]}" -gt 0 ]; then
    fm_status="incomplete:$(
      IFS=,
      echo "${missing[*]}"
    )"
  fi

  # ── related: link check ──
  local related_raw related_broken=() related_count=0
  related_raw=$(_fm_get "$fm" "related")
  if [ -n "$related_raw" ]; then
    while IFS= read -r rel_path; do
      [ -z "$rel_path" ] && continue
      related_count=$((related_count + 1))
      [ -f "$wiki_root/$rel_path" ] || related_broken+=("$rel_path")
    done < <(echo "$related_raw" | grep -oE '"[^"]+"' | sed 's/^"//; s/"$//')
  fi
  local broken_field="0"
  if [ "${#related_broken[@]}" -gt 0 ]; then
    broken_field="${#related_broken[@]}:$(
      IFS=,
      echo "${related_broken[*]}"
    )"
  fi

  # ── Backticked class names unresolved against any repo (best-effort) ──
  # Backtick spans are captured broadly (any non-backtick content) since real
  # wiki content backticks whole expressions — `BomFeignClient.charge(reserve=true, usage)`,
  # not bare class names — and narrowing the capture regex would just make
  # the check silently see nothing on exactly the content it exists to check.
  # Filtering to plausible class-name candidates happens after capture:
  # every dot-separated segment that looks CamelCase is a candidate (covers
  # both `Class.method()` and `pkg.sub.Class` shapes), meaningless args/method
  # names are dropped by the CamelCase test itself.
  local unknown_field="0" unknown_classes=() checked=0
  if [ -n "$repos_root" ] && [ -d "$repos_root" ]; then
    local seen=","
    while IFS= read -r span; do
      [ -z "$span" ] && continue
      span="${span%%(*}" # drop call args
      local IFS_OLD="$IFS" segment
      IFS='.'
      for segment in $span; do
        IFS="$IFS_OLD"
        [ "$checked" -ge "$MAX_CLASS_CHECKS" ] && break 2
        case "$segment" in
        [A-Z][A-Za-z0-9][A-Za-z0-9]*) ;;
        *) continue ;;
        esac
        case "$seen" in
        *",$segment,"*) continue ;;
        esac
        seen="${seen}${segment},"
        checked=$((checked + 1))
        if ! grep -rlwF -m1 "$segment" "$repos_root" \
          --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=target \
          --exclude-dir=dist --exclude-dir=build >/dev/null 2>&1; then
          unknown_classes+=("$segment")
        fi
      done
      IFS="$IFS_OLD"
    done < <(grep -oE '`[^`]+`' "$file" 2>/dev/null | sed 's/^`//; s/`$//')
  fi
  if [ "${#unknown_classes[@]}" -gt 0 ]; then
    unknown_field="${#unknown_classes[@]}:$(
      IFS=,
      echo "${unknown_classes[*]}"
    )"
  fi

  # ── Freshness ──
  # One git call total (rev-list --count) — not one per line/commit.
  local freshness="decayed" commits_since="" age_days=""
  if [ -n "$verified_at" ] && [ -n "$va_repo" ] && [ -n "$va_sha" ] && [ -n "$stale_after" ]; then
    local repo_path
    repo_path=$(_resolve_repo_path "$repos_root" "$va_repo")
    local now_epoch va_epoch
    now_epoch=$(date -u +%s)
    va_epoch=$(date -u -d "$verified_at" +%s 2>/dev/null || date -u -jf "%Y-%m-%d" "$verified_at" +%s 2>/dev/null || echo "")
    if [ -n "$va_epoch" ]; then
      age_days=$(((now_epoch - va_epoch) / 86400))
    fi
    if [ -n "$repo_path" ] && [ -d "$repo_path/.git" ]; then
      commits_since=$(git -C "$repo_path" rev-list --count "${va_sha}..HEAD" 2>/dev/null || echo "")
    fi
    # Hard expiry: past stale_after regardless of how quiet the repo's been.
    if [ -n "$age_days" ] && [ "$age_days" -gt "$stale_after" ] 2>/dev/null; then
      freshness="decayed"
    # Heavy churn since verification: treat as decayed even inside the age budget.
    elif [ -n "$commits_since" ] && [ "$commits_since" -ge "$DECAY_COMMIT_LIMIT" ] 2>/dev/null; then
      freshness="decayed"
    # Some commits landed since verification, but under the churn threshold —
    # plausibly still accurate, but not confirmed.
    elif [ "$commits_since" = "0" ]; then
      freshness="fresh"
    elif [ -n "$age_days" ]; then
      # commits_since is either >0 (churn, below the decay threshold) or
      # unresolvable (repo not found under --repos-root) — either way, this
      # file's accuracy since verified_at can't be confirmed as unchanged, so
      # it doesn't get to claim "fresh". age_days being known is what makes
      # this branch reachable at all; without it freshness stays "decayed"
      # (the conservative default set above).
      freshness="stale"
    fi
  fi

  echo "WIKI_CHECK|${rel}|lines=${lines}|frontmatter=${fm_status}|broken_related=${broken_field}|unknown_classes=${unknown_field}|freshness=${freshness}"

  # Return non-zero (caller tallies) if anything is flagged.
  if [ "$fm_status" != "complete" ] || [ "$broken_field" != "0" ] || [ "$freshness" = "decayed" ]; then
    return 1
  fi
  return 0
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  local wiki_root="" repos_root="" single_file="" changed_only="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --wiki-root)
      wiki_root="${2:-}"
      shift 2
      ;;
    --repos-root)
      repos_root="${2:-}"
      shift 2
      ;;
    --file)
      single_file="${2:-}"
      shift 2
      ;;
    --changed-only)
      changed_only="true"
      shift
      ;;
    --help | -h) usage ;;
    *)
      echo "Unknown flag: $1" >&2
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

  local files=()

  if [ -n "$single_file" ]; then
    local f="$single_file"
    [ -f "$f" ] || f="$wiki_root/$single_file"
    [ -f "$f" ] || {
      echo "ERROR: file not found: $single_file" >&2
      exit 2
    }
    files=("$f")
  elif [ "$changed_only" = "true" ] && [ -d "$wiki_root/.git" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      case "$f" in
      *index.md) continue ;;
      esac
      [ -f "$wiki_root/$f" ] && files+=("$wiki_root/$f")
    done < <(git -C "$wiki_root" status --porcelain 2>/dev/null | awk '{print $NF}' | grep '\.md$' || true)
    # No changes found is not an error — nothing to lint this run.
  else
    while IFS= read -r -d '' f; do
      files+=("$f")
    done < <(find "$wiki_root" -name "*.md" ! -name "index.md" -print0 2>/dev/null | sort -z)
  fi

  local total=0 decayed=0 stale=0 fresh=0 incomplete=0 broken=0 unknown_total=0
  local any_issue=0

  for f in "${files[@]}"; do
    total=$((total + 1))
    local out rc=0
    out=$(_check_file "$f" "$wiki_root" "$repos_root") || rc=$?
    echo "$out"
    [ "$rc" -ne 0 ] && any_issue=1

    case "$out" in
    *"freshness=decayed"*) decayed=$((decayed + 1)) ;;
    *"freshness=stale"*) stale=$((stale + 1)) ;;
    *"freshness=fresh"*) fresh=$((fresh + 1)) ;;
    esac
    case "$out" in
    *"frontmatter=incomplete"*) incomplete=$((incomplete + 1)) ;;
    esac
    if [[ "$out" != *"broken_related=0|"* ]]; then
      broken=$((broken + 1))
    fi
    local uc
    uc=$(echo "$out" | grep -oE 'unknown_classes=[0-9]+' | head -1 | cut -d= -f2 || true)
    unknown_total=$((unknown_total + ${uc:-0}))
  done

  echo "WIKI_CHECK_SUMMARY|files=${total}|decayed=${decayed}|stale=${stale}|fresh=${fresh}|incomplete_frontmatter=${incomplete}|broken_links=${broken}|unknown_classes_total=${unknown_total}"

  [ "$any_issue" -eq 0 ]
}

# ── Dispatch ───────────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
