#!/usr/bin/env bash
# planner-ownership-edges.sh — the reader of artifacts/ownership-edges.json
# (planner-crosscheck-ownership, design D6).
#
# Crosscheck's edges step (planner_ownership_edges_write in
# planner-spec-ownership.sh) writes the sidecar:
#
#   { "version": 1,
#     "edges": [ { "consumer": "<slug>", "blocked_by": "<slug>",
#                  "keys": ["<key>", …], "frozen": <bool> } ] }
#
# This file only reads it, and sources nothing, so planner-ticket-body.sh can
# source it without pulling in the ownership family. planner_ticketgen_spec_deps
# appends these edges after the test-data synthesis edges; every reader of the
# dependency set (deps_json, order, the DEPENDENCY_CYCLE check, draft
# readiness, planner_uat_policy_resolve) then sees them.
#
# Functions:
#   _planner_tb_own_sidecar <specs_dir>
#       the sidecar governing <specs_dir> (artifacts/specs →
#       artifacts/ownership-edges.json); a sibling of _planner_tb_sidecar.
#   _planner_own_edges_of <sidecar> <specs_dir>
#       `<consumer>\x1f<blocked_by>` per edge, sorted and unique under
#       LC_ALL=C. An edge whose consumer or target spec file is missing, a
#       self-edge and a slug that is not `[A-Za-z0-9][A-Za-z0-9_-]*` are
#       dropped. No sidecar, or an unreadable one, prints nothing.
#
# Sourceable library — no set -euo pipefail.

_planner_tb_own_sidecar() {
  printf '%s' "$(dirname "$1")/ownership-edges.json"
}

_planner_own_edges_of() {
  local sc="$1" specs_dir="$2" c b
  [ -f "$sc" ] || return 0
  while IFS=$'\037' read -r c b; do
    [[ "$c" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || continue
    [[ "$b" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || continue
    [ "$c" != "$b" ] || continue
    [ -f "${specs_dir}/${c}.md" ] && [ -f "${specs_dir}/${b}.md" ] || continue
    printf '%s\037%s\n' "$c" "$b"
  done < <(jq -r '.edges[]? | [(.consumer // ""), (.blocked_by // "")] | join("\u001f")' "$sc" 2>/dev/null) |
    LC_ALL=C sort -u
}
