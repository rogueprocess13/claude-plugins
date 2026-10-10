#!/usr/bin/env bash
# fleet-plugin-cache.sh — Version-aware lookup of a file inside an installed
# plugin's marketplace cache (issue #468).
#
# Same contract as ticket-auto-pipeline's lib/plugin-cache.sh and
# ticket-planner's lib/planner-plugin-cache.sh (#454). fleet-controller keeps
# its own copy because it must find ticket-auto-pipeline's files *through*
# this lookup — it cannot source that plugin's helper before finding it.
#
# A plain `find ... | sort | tail -1` is a text sort: 0.9.4 sorts after 0.62.7,
# so a cache holding both resolves to the stale 0.9.4 copy.
#
# Lookup order:
#   1. The installPath(s) recorded in ~/.claude/plugins/installed_plugins.json
#      for <plugin>. This is the version Claude Code actually installed.
#   2. A scan of ~/.claude/plugins/cache/{marketplace}/<plugin>/{version}/,
#      ordered by the numeric value of each version segment (0.62.7 > 0.9.4).
#
# Both steps only return a path whose <relpath> file exists.
#
# Sourceable library — no set -euo pipefail. No jq dependency.

# Read paths on stdin ({anything}/<plugin>/{version}/{rest}) and print the one
# with the highest numeric major.minor.patch version; ties break on path text.
# Usage: ... | _fleet_pick_newest_version <plugin>
_fleet_pick_newest_version() {
  local plugin="$1"
  awk -v plg="$plugin" '
    {
      n = split($0, c, "/")
      ver = ""
      for (i = 1; i < n; i++) if (c[i] == plg) ver = c[i + 1]
      if (ver == "") next
      split(ver, v, ".")
      printf "%010d.%010d.%010d\t%s\n", v[1] + 0, v[2] + 0, v[3] + 0, $0
    }' | LC_ALL=C sort | tail -1 | cut -f2-
}

# Find <relpath> inside the installed (else newest cached) copy of <plugin>.
# Usage: fleet_cache_find <plugin> <relpath>
#   e.g. fleet_cache_find ticket-auto-pipeline lib/pipeline-postmortem.sh
# Output: absolute file path on stdout, or nothing when no copy exists.
# Returns: always 0 — callers test the output, and a non-zero status would
# abort a `var=$(...)` under set -e.
fleet_cache_find() {
  local plugin="$1" rel="${2#/}" found p
  local cache="${HOME}/.claude/plugins/cache"
  local installed="${HOME}/.claude/plugins/installed_plugins.json"

  if [ -f "$installed" ]; then
    found=$(
      sed -n 's/.*"installPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$installed" 2>/dev/null |
        while IFS= read -r p; do
          p="${p%/}"
          case "$p" in */"${plugin}"/*) ;; *) continue ;; esac
          if [ -f "${p}/${rel}" ]; then echo "${p}/${rel}"; fi
        done | _fleet_pick_newest_version "$plugin"
    ) || true
    if [ -n "$found" ]; then
      echo "$found"
      return 0
    fi
  fi

  found=$(find "$cache" -path "*/${plugin}/*/${rel}" -type f 2>/dev/null |
    _fleet_pick_newest_version "$plugin") || true
  if [ -n "$found" ] && [ -f "$found" ]; then
    echo "$found"
  fi
  return 0
}
