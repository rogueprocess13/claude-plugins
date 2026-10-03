#!/usr/bin/env bash
# ticket-create: the one deterministic path for logging a single Linear
# ticket (ticket-create-skill). The agent authors the title and body; this
# script decides whether they are good enough and performs every write:
#
#   1. validate arguments (type, kind, title, body file)
#   2. body section check     (check_planned_body)
#   3. readiness check        (check_ticket_ready --no-fetch; hard codes block)
#   4. duplicate check        (search_issues + title-term Jaccard)
#   5. create_issue           (no labels — type lives in the manifest)
#   6. _adhoc ticket manifest (write_ticket_manifest <ID> _adhoc <type>)
#
# Exit codes:
#   0 created (or --dry-run passed)   3 duplicate found
#   1 usage / configuration error     4 Linear API failure
#   2 body or readiness check failed  5 manifest write failed after creation
#                                       (the issue exists — JSON still printed)
#
# Usage:
#   create.sh --type <bug|feature|improvement|security|chore>
#             --kind <business|enabler> --title <s> --body-file <path>
#             [--team <key|name|uuid>] [--parent <ID>] [--dry-run]
#             [--duplicate-ok "<reason>"]
#
# -u (nounset) intentionally omitted — same reason as ticket-approve/approve.sh.
set -eo pipefail

CREATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Lib resolution: CLAUDE_SKILLS_LIB (tests) → synced copy → plugin-relative ─
if [ -n "${CLAUDE_SKILLS_LIB:-}" ]; then
  LIB_DIR="$CLAUDE_SKILLS_LIB"
elif [ -f "$HOME/.claude/skills/lib/linear-api.sh" ]; then
  LIB_DIR="$HOME/.claude/skills/lib"
else
  LIB_DIR="$(cd "$CREATE_DIR/../../lib" && pwd)"
fi

usage() {
  [ -n "${1:-}" ] && echo "ticket-create: $1" >&2
  cat >&2 <<'USAGE'
Usage: create.sh --type <bug|feature|improvement|security|chore>
                 --kind <business|enabler> --title <s> --body-file <path>
                 [--team <key|name|uuid>] [--parent <ID>] [--dry-run]
                 [--duplicate-ok "<reason>"]
USAGE
  exit 1
}

TYPE="" KIND="" TITLE="" BODY_FILE="" TEAM="" PARENT="" DRY_RUN="false" DUP_OK="" DUP_OK_SET="false"
while [ $# -gt 0 ]; do
  case "$1" in
  --type) TYPE="${2:-}" && shift 2 || usage "--type needs a value" ;;
  --kind) KIND="${2:-}" && shift 2 || usage "--kind needs a value" ;;
  --title) TITLE="${2:-}" && shift 2 || usage "--title needs a value" ;;
  --body-file) BODY_FILE="${2:-}" && shift 2 || usage "--body-file needs a value" ;;
  --team) TEAM="${2:-}" && shift 2 || usage "--team needs a value" ;;
  --parent) PARENT="${2:-}" && shift 2 || usage "--parent needs a value" ;;
  --duplicate-ok)
    DUP_OK="${2:-}" DUP_OK_SET="true"
    shift 2 || usage "--duplicate-ok needs a reason"
    ;;
  --dry-run)
    DRY_RUN="true"
    shift
    ;;
  -h | --help) usage ;;
  *) usage "unknown argument: $1" ;;
  esac
done

# ── 1. Argument validation ───────────────────────────────────────────────────
case "$TYPE" in
bug | feature | improvement | security | chore) ;;
"") usage "--type is required" ;;
*) usage "unknown type '$TYPE' (bug|feature|improvement|security|chore)" ;;
esac
case "$KIND" in
business | enabler) ;;
"") usage "--kind is required" ;;
*) usage "unknown kind '$KIND' (business|enabler)" ;;
esac
TITLE="$(echo "$TITLE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -n "$TITLE" ] || usage "--title is required and must not be blank"
[ -n "$BODY_FILE" ] || usage "--body-file is required"
[ -r "$BODY_FILE" ] || usage "body file not readable: $BODY_FILE"
[ -s "$BODY_FILE" ] || usage "body file is empty: $BODY_FILE"
if [ "$DUP_OK_SET" = "true" ]; then
  DUP_OK="$(echo "$DUP_OK" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$DUP_OK" ] || usage "--duplicate-ok needs a non-blank reason"
fi

# REPOS_ROOT locates the manifest. Fall back to the project CLAUDE.md the same
# way ticket-preamble.sh reads project context, and refuse up-front rather
# than create an issue whose manifest write is already known to fail.
if [ -z "${REPOS_ROOT:-}" ] && [ -f "$PWD/CLAUDE.md" ]; then
  REPOS_ROOT=$(grep -oP '^`?REPOS_ROOT`?\s*[=:]\s*`?\K[^`]+' "$PWD/CLAUDE.md" 2>/dev/null |
    head -1 | sed 's/[[:space:]]*$//' || true)
fi
if [ -z "${REPOS_ROOT:-}" ] && [ "$DRY_RUN" != "true" ]; then
  usage "REPOS_ROOT is not set (env or project CLAUDE.md) — needed for the ticket manifest"
fi
export REPOS_ROOT

source "$LIB_DIR/linear-api.sh"
source "$LIB_DIR/planned-ticket-body-check.sh"
source "$LIB_DIR/dor-check.sh"
source "$LIB_DIR/audit-title-similarity.sh"
source "$LIB_DIR/manifest-write.sh"

BODY="$(cat "$BODY_FILE")"
CHECK_ID="TICKET-CREATE"

# ── 2. Body section check ────────────────────────────────────────────────────
_rc=0
check_planned_body "$CHECK_ID" "$TYPE" "$BODY" "false" || _rc=$?
if [ "$_rc" -ne 0 ]; then
  echo "BODY_CHECK_MISSING=${BODY_CHECK_MISSING}"
  echo "ticket-create: body is missing required sections for type=$TYPE — fill them from templates/$TYPE.md and retry" >&2
  exit 2
fi

# ── 3. Readiness check ───────────────────────────────────────────────────────
_rc=0
check_ticket_ready "$CHECK_ID" --body "$BODY_FILE" --type "$TYPE" --no-fetch || _rc=$?
if [ "$DOR_ADVISORY" != "[]" ] && [ -n "$DOR_ADVISORY" ]; then
  echo "DOR_ADVISORY=${DOR_ADVISORY}"
fi
case "$DOR_STATUS" in
ready) ;;
not-ready)
  echo "DOR_MISSING=${DOR_MISSING}"
  echo "ticket-create: readiness check failed (hard codes above) — fix the body and retry" >&2
  exit 2
  ;;
*)
  echo "DOR_STATUS=${DOR_STATUS:-unavailable}"
  echo "ticket-create: readiness check unavailable (rc=$_rc) — no body could be resolved from $BODY_FILE" >&2
  exit 2
  ;;
esac

# ── 4. Duplicate check ───────────────────────────────────────────────────────

# _resolve_team <key|name|uuid|empty> → team uuid on stdout.
_resolve_team() {
  local want="$1" teams count id
  if [[ "$want" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "$want"
    return 0
  fi
  teams=$( (linear_graphql '{"query":"query { teams { nodes { id key name } } }"}') 2>/dev/null) || return 4
  _jq_guard "$teams" ".data.teams.nodes" "array" || return 4
  if [ -z "$want" ]; then
    count=$(echo "$teams" | jq '.data.teams.nodes | length')
    if [ "$count" -ne 1 ]; then
      echo "ticket-create: $count Linear teams visible — pass --team or set LINEAR_TEAM_ID" >&2
      return 1
    fi
    echo "$teams" | jq -r '.data.teams.nodes[0].id'
    return 0
  fi
  id=$(echo "$teams" | jq -r --arg w "$want" \
    '[.data.teams.nodes[] | select((.key|ascii_downcase) == ($w|ascii_downcase) or (.name|ascii_downcase) == ($w|ascii_downcase))][0].id // empty')
  if [ -z "$id" ]; then
    echo "ticket-create: no Linear team matches '$want'" >&2
    return 1
  fi
  echo "$id"
}

_rc=0
TEAM_ID=$(_resolve_team "${TEAM:-${LINEAR_TEAM_ID:-}}") || _rc=$?
if [ "$_rc" -ne 0 ]; then
  [ "$_rc" -eq 4 ] && echo "ticket-create: Linear teams query failed" >&2
  exit "$_rc"
fi

CANDIDATES=$( (search_issues "$TEAM_ID" "$TITLE") 2>/dev/null) || {
  echo "ticket-create: duplicate search failed (Linear API)" >&2
  exit 4
}

THRESHOLD="${TICKET_CREATE_DUP_THRESHOLD:-60}"
NEW_TERMS="$(_title_terms "$TITLE" | tr '\n' ' ')"
MATCHES=()
while IFS=$'\t' read -r _ident _title; do
  [ -n "$_ident" ] || continue
  _score=$(audit_title_similarity "$NEW_TERMS" "$(_title_terms "$_title" | tr '\n' ' ')")
  if [ "$_score" -ge "$THRESHOLD" ]; then
    MATCHES+=("${_ident}"$'\t'"${_score}"$'\t'"${_title}")
  fi
done < <(echo "$CANDIDATES" | jq -r '.[] | [.identifier, .title] | @tsv')

if [ "${#MATCHES[@]}" -gt 0 ]; then
  for _m in "${MATCHES[@]}"; do
    IFS=$'\t' read -r _ident _score _title <<<"$_m"
    echo "DUPLICATE|${_ident}|${_score}|${_title}"
  done
  if [ -z "$DUP_OK" ]; then
    echo "ticket-create: possible duplicate(s) above (threshold $THRESHOLD) — inspect them, or rerun with --duplicate-ok \"<reason>\"" >&2
    exit 3
  fi
  # Record the accepted override in the body under ## Related Tickets.
  _note=""
  for _m in "${MATCHES[@]}"; do
    IFS=$'\t' read -r _ident _score _title <<<"$_m"
    _note+="- Possible duplicate of ${_ident} — accepted: ${DUP_OK}"$'\n'
  done
  if grep -q '^## Related Tickets[[:space:]]*$' <<<"$BODY"; then
    BODY=$(TC_NOTE="${_note%$'\n'}" awk '
      { print }
      /^## Related Tickets[[:space:]]*$/ && !done { print ""; print ENVIRON["TC_NOTE"]; done = 1 }
    ' <<<"$BODY")
  else
    BODY="${BODY}"$'\n\n'"## Related Tickets"$'\n\n'"${_note%$'\n'}"
  fi
fi

# ── 5. Dry run ───────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = "true" ]; then
  jq -cn --arg title "$TITLE" --arg type "$TYPE" --arg kind "$KIND" \
    --arg team "$TEAM_ID" --arg parent "$PARENT" \
    '{dry_run: true, title: $title, type: $type, kind: $kind, team: $team, parent: (if $parent == "" then null else $parent end)}'
  exit 0
fi

# ── 6. Create ────────────────────────────────────────────────────────────────
PARENT_ID=""
if [ -n "$PARENT" ]; then
  PARENT_ID=$( (get_issue "$PARENT" | jq -r '.id // empty') 2>/dev/null) || PARENT_ID=""
  if [ -z "$PARENT_ID" ]; then
    echo "ticket-create: parent '$PARENT' could not be resolved" >&2
    exit 4
  fi
fi

_rc=0
CREATED=$( (create_issue "$TEAM_ID" "$TITLE" "$BODY" "" "$PARENT_ID")) || _rc=$?
if [ "$_rc" -ne 0 ] || ! echo "$CREATED" | jq -e '.identifier' >/dev/null 2>&1; then
  echo "ticket-create: Linear issue creation failed (rc=$_rc)" >&2
  exit 4
fi

IDENT=$(echo "$CREATED" | jq -r '.identifier')
MANIFEST="true"
write_ticket_manifest "$IDENT" "_adhoc" "$TYPE" || MANIFEST="false"

echo "$CREATED" | jq -c --arg type "$TYPE" --arg kind "$KIND" --argjson manifest "$MANIFEST" \
  '{identifier, id, url, type: $type, kind: $kind, manifest: $manifest}'

if [ "$MANIFEST" != "true" ]; then
  echo "ticket-create: $IDENT was created but its _adhoc manifest could not be written — do NOT retry creation; run ensure_ticket_manifest $IDENT once REPOS_ROOT is fixed" >&2
  exit 5
fi
exit 0
