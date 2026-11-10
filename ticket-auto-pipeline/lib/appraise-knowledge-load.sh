#!/usr/bin/env bash
# appraise-knowledge-load.sh — the deterministic half of ticket-appraise
# Step 3a / 3-Agent-a (references/full-investigation.md), skill-deterministic-
# extraction 5: which prescan docs and wiki files the investigation should
# load. Reading, verifying and judging them stays with the agent.
#
# Usage:
#   appraise-knowledge-load.sh --ticket-dir D --repos-root R [--wiki-root W]
#                              [--affected-services CSV]
#
# The ticket's title, labels and description come from D/context.md (the
# `# ID: title` line, the `**Labels:**` line, and the `## Description`
# section up to the next `---`), so no ticket text passes through argv.
#
# Composes, in the order the step ran them:
#   3a.0  prescan-route.sh --mode repos (every repo under R), then per repo
#         prescan-check.sh (PRESCAN_CHECK_SH overrides, as in prescan-run.sh)
#   3a.0b wiki_bootstrap W (when W is set), then wiki-route.sh
#   3a.1  per repo with status fresh|stale|decayed and a docs/INDEX.md:
#         prescan-route.sh --mode index with the first 500 description chars
#
# Output (lines; the WIKI_* block is eval-safe as wiki-route.sh prints it):
#   PRESCAN_REPO=<slug>|<status>|<routed doc count or ->|<repo path>
#   PRESCAN_DOC=<slug>|<doc path>               (one per routed doc)
#   WIKI_BOOTSTRAP_STATUS=... (wiki_bootstrap's own lines, when W is set)
#   WIKI_ROUTE=... WIKI_ROUTE_REASON=... ... WIKI_ROUTE_LINE=...
# A repo whose prescan-check could not run reports status `missing`, as the
# step treats it. Writes nothing to the pipeline log.
# Exit codes: 0 (routing is advisory and never fatal), 2 usage.
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_AKL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_akl_usage() {
  sed -n '8,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  return 2
}

# Ticket fields from context.md (ticket-setup's layout).
_akl_title() { sed -n '1s/^# [^:]*: //p' "$1"; }
_akl_labels() { sed -n 's/^\*\*Labels:\*\* *//p' "$1" | head -1; }
_akl_desc() { awk '/^## Description[[:space:]]*$/{on=1; next} on && /^---[[:space:]]*$/{exit} on' "$1" | sed '/./,$!d'; }

akl_main() {
  local td="" rr="" wr="" svc=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || {
      _akl_usage
      return 2
    }
    case "$1" in
    --ticket-dir) td="$2" ;;
    --repos-root) rr="$2" ;;
    --wiki-root) wr="$2" ;;
    --affected-services) svc="$2" ;;
    *)
      _akl_usage
      return 2
      ;;
    esac
    shift 2
  done
  if [ -z "$td" ] || [ -z "$rr" ] || [ ! -f "$td/context.md" ]; then
    _akl_usage
    return 2
  fi
  local ctx="$td/context.md" title labels desc desc500
  title=$(_akl_title "$ctx")
  labels=$(_akl_labels "$ctx")
  desc=$(_akl_desc "$ctx")
  desc500="${desc:0:500}"
  local check="${PRESCAN_CHECK_SH:-$_AKL_DIR/prescan-check.sh}"

  # 3a.0 — repos and freshness
  local repo slug status index routed n
  while IFS= read -r repo; do
    case "$repo" in "" | PRESCAN_ROUTE_COUNT=*) continue ;; esac
    slug=$(basename "$repo" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
    status=$(bash "$check" "$repo" --repos-root "$rr" 2>/dev/null | sed -n "s/^PRESCAN_STATUS=//p" | tr -d "'\"")
    case "$status" in fresh | stale | decayed | missing) ;; *) status=missing ;; esac
    n="-"
    index="$rr/.ticket-auto/$slug/docs/INDEX.md"
    routed=""
    if [ "$status" != missing ] && [ -f "$index" ]; then
      routed=$(bash "$_AKL_DIR/prescan-route.sh" --mode index --index "$index" \
        --ticket-title "$title" --ticket-labels "$labels" --ticket-desc "$desc500" 2>/dev/null) || true
      n=$(sed -n 's/^PRESCAN_ROUTE_COUNT=//p' <<<"$routed")
      n="${n:-0}"
    fi
    echo "PRESCAN_REPO=$slug|$status|$n|$repo"
    while IFS= read -r doc; do
      case "$doc" in "" | PRESCAN_ROUTE_COUNT=*) continue ;; esac
      echo "PRESCAN_DOC=$slug|$doc"
    done <<<"$routed"
  done < <(bash "$_AKL_DIR/prescan-route.sh" --mode repos --repos-root "$rr" 2>/dev/null || true)

  # 3a.0b — wiki index and routing
  if [ -n "$wr" ]; then
    (
      # shellcheck source=/dev/null
      source "$_AKL_DIR/wiki-bootstrap.sh" && wiki_bootstrap "$wr"
    ) 2>/dev/null || echo "WIKI_BOOTSTRAP_STATUS=error"
  fi
  bash "$_AKL_DIR/wiki-route.sh" --wiki-root "$wr" --repos-root "$rr" \
    --ticket-title "$title" --ticket-labels "$labels" --ticket-desc "$desc" \
    --affected-services "$svc" 2>/dev/null || true
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  akl_main "$@"
  exit $?
fi
