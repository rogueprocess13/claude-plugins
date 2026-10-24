#!/usr/bin/env bash
# wiki-route.sh — ticket-appraise Step 3a.0b wiki routing decision (DET-AP-8).
#
# Replaces two broken/by-eye steps in the SKILL:
#   1. The multi-repo signal used `${#REPOS[@]}` on a scalar (always 1, so it
#      never fired) over an unfiltered list of every repo under REPOS_ROOT (so
#      a naive "fix" would route every ticket in a multi-repo workspace to the
#      wiki). Here the count comes from `prescan-route.sh --mode repos` WITH
#      the ticket's text, i.e. only repos the ticket names, or from more than
#      one entry in the Planner Context `Affected Services` field.
#   2. The topic signal was matched by the LLM "the same way prescan-route.sh
#      does". Here it IS prescan-route.sh --mode index on WIKI_ROOT/index.md.
#
# Usage:
#   wiki-route.sh [--wiki-root P] [--repos-root P] [--ticket-title S]
#                 [--ticket-labels S] [--ticket-desc S]
#                 [--affected-services CSV]
#
# Output (eval-safe, printf %q):
#   WIKI_ROUTE=true|false
#   WIKI_ROUTE_REASON=multi-repo(N)|multi-service(N)|topic|none|no-wiki|no-index
#   WIKI_ROUTE_REPO_COUNT=<repos the ticket names>
#   WIKI_ROUTE_SERVICE_COUNT=<Affected Services entries>
#   WIKI_ROUTE_TOPIC_FILES=<newline-separated wiki files matched by topic>
#   WIKI_ROUTE_LINE=<the **Wiki routing:** line for notes.md>
# Exit: always 0 (routing is advisory input to the investigation, never fatal).
set -eo pipefail

_WR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTE="$_WR_DIR/prescan-route.sh"

WIKI_ROOT_ARG=""
REPOS_ROOT_ARG=""
TITLE=""
LABELS=""
DESC=""
SERVICES=""
while [ $# -gt 0 ]; do
  case "$1" in
  --wiki-root) WIKI_ROOT_ARG="${2:-}" ;;
  --repos-root) REPOS_ROOT_ARG="${2:-}" ;;
  --ticket-title) TITLE="${2:-}" ;;
  --ticket-labels) LABELS="${2:-}" ;;
  --ticket-desc) DESC="${2:-}" ;;
  --affected-services) SERVICES="${2:-}" ;;
  *)
    echo "wiki-route: unknown argument: $1" >&2
    shift
    continue
    ;;
  esac
  shift 2 || shift $#
done

ticket_args=()
[ -n "$TITLE" ] && ticket_args+=(--ticket-title "$TITLE")
[ -n "$LABELS" ] && ticket_args+=(--ticket-labels "$LABELS")
[ -n "$DESC" ] && ticket_args+=(--ticket-desc "$DESC")

# ── Multi-repo signal: repos the ticket names ────────────────────────────────
repo_count=0
if [ -n "$REPOS_ROOT_ARG" ] && [ ${#ticket_args[@]} -gt 0 ]; then
  out=$(bash "$ROUTE" --mode repos --repos-root "$REPOS_ROOT_ARG" "${ticket_args[@]}" 2>/dev/null || true)
  rc_line=$(printf '%s\n' "$out" | grep '^PRESCAN_ROUTE_COUNT=' | tail -1 || true)
  repo_count="${rc_line#PRESCAN_ROUTE_COUNT=}"
  [[ "$repo_count" =~ ^[0-9]+$ ]] || repo_count=0
fi

# ── Multi-service signal: Affected Services entries ──────────────────────────
service_count=0
if [ -n "$SERVICES" ]; then
  service_count=$(printf '%s\n' "$SERVICES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
    grep -cv '^$' || true)
fi

# ── Topic signal: wiki index Lookup by Topic/Service ─────────────────────────
topic_files=""
index_state="ok"
if [ -z "$WIKI_ROOT_ARG" ]; then
  index_state="no-wiki"
elif [ ! -f "$WIKI_ROOT_ARG/index.md" ]; then
  index_state="no-index"
elif [ ${#ticket_args[@]} -gt 0 ]; then
  out=$(bash "$ROUTE" --mode index --index "$WIKI_ROOT_ARG/index.md" "${ticket_args[@]}" 2>/dev/null || true)
  topic_files=$(printf '%s\n' "$out" | grep -v '^PRESCAN_ROUTE_COUNT=' | grep -v '^$' || true)
fi

route=false
reason="none"
if [ "$index_state" = "no-wiki" ]; then
  reason="no-wiki"
elif [ "$repo_count" -gt 1 ]; then
  route=true
  reason="multi-repo($repo_count)"
elif [ "$service_count" -gt 1 ]; then
  route=true
  reason="multi-service($service_count)"
elif [ -n "$topic_files" ]; then
  route=true
  reason="topic"
elif [ "$index_state" = "no-index" ]; then
  reason="no-index"
fi

case "$reason" in
multi-repo*) line="**Wiki routing:** multi-repo ($repo_count repos)" ;;
multi-service*) line="**Wiki routing:** multi-repo ($service_count affected services)" ;;
topic) line="**Wiki routing:** topic match: $(printf '%s\n' "$topic_files" | xargs -r -n1 basename | paste -sd, -)" ;;
no-wiki) line="**Wiki routing:** not routed — WIKI_ROOT unset" ;;
*) line="**Wiki routing:** not routed — per-repo ticket" ;;
esac

printf 'WIKI_ROUTE=%q\n' "$route"
printf 'WIKI_ROUTE_REASON=%q\n' "$reason"
printf 'WIKI_ROUTE_REPO_COUNT=%q\n' "$repo_count"
printf 'WIKI_ROUTE_SERVICE_COUNT=%q\n' "$service_count"
printf 'WIKI_ROUTE_TOPIC_FILES=%q\n' "$topic_files"
printf 'WIKI_ROUTE_LINE=%q\n' "$line"
exit 0
