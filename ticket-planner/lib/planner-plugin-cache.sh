#!/usr/bin/env bash
# planner-plugin-cache.sh — Version-aware lookup of a file inside an installed
# plugin's marketplace cache (issue #454).
#
# Why this exists
# ───────────────
# Every resolver in this plugin used to pick the "newest" cached install with
#
#   find ~/.claude/plugins/cache -path "*/<plugin>/*/<file>" | sort | tail -1
#
# That is a *text* sort, so 0.9.0 sorts after 0.15.1 and a cache holding
# 0.9.0 0.14.0 0.15.0 0.15.1 resolved to the stale 0.9.0 — silently, for every
# phase of a run, even though installed_plugins.json recorded 0.15.1.
#
# Lookup order:
#   1. The installPath(s) recorded in ~/.claude/plugins/installed_plugins.json
#      for <plugin>. This is the version Claude Code actually installed.
#   2. A scan of ~/.claude/plugins/cache/{marketplace}/<plugin>/{version}/,
#      ordered by the numeric value of each version segment (0.15.1 > 0.9.0).
#
# Both steps only return a path whose <relpath> file exists.
#
# Sourceable library — no set -euo pipefail. No jq dependency.

# Read lines of "<path>" on stdin, each of the form
# {anything}/<plugin>/{version}/{rest}, and print the one with the highest
# version. Ordering is numeric per dot-separated segment (major.minor.patch);
# any pre-release suffix on a segment is ignored. Ties break on the path text,
# so the result is deterministic.
# Usage: ... | _planner_pick_newest_version <plugin>
_planner_pick_newest_version() {
  local plugin="$1"
  awk -v plg="$plugin" '
    {
      n = split($0, c, "/")
      ver = ""
      # Last "<plugin>/<version>" pair in the path wins, so a HOME that happens
      # to contain the plugin name cannot shift the version segment.
      for (i = 1; i < n; i++) if (c[i] == plg) ver = c[i + 1]
      if (ver == "") next
      split(ver, v, ".")
      printf "%010d.%010d.%010d\t%s\n", v[1] + 0, v[2] + 0, v[3] + 0, $0
    }' | LC_ALL=C sort | tail -1 | cut -f2-
}

# Find <relpath> inside the newest installed copy of <plugin>.
# Usage: planner_cache_find <plugin> <relpath>
#   e.g. planner_cache_find ticket-auto-pipeline lib/manifest-write.sh
# Output: absolute file path on stdout, or nothing when no copy exists.
# Returns: always 0, like the `find | sort | tail -1` it replaces — callers test
# the output, and a non-zero status would abort a `var=$(...)` under set -e.
planner_cache_find() {
  local plugin="$1" rel="${2#/}" found p
  local cache="${HOME}/.claude/plugins/cache"
  local installed="${HOME}/.claude/plugins/installed_plugins.json"

  # 1. installed_plugins.json — the authoritative installed version(s).
  if [ -f "$installed" ]; then
    found=$(
      sed -n 's/.*"installPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$installed" 2>/dev/null |
        while IFS= read -r p; do
          p="${p%/}"
          case "$p" in */"${plugin}"/*) ;; *) continue ;; esac
          if [ -f "${p}/${rel}" ]; then echo "${p}/${rel}"; fi
        done | _planner_pick_newest_version "$plugin"
    ) || true
    if [ -n "$found" ]; then
      echo "$found"
      return 0
    fi
  fi

  # 2. Version-aware cache scan.
  found=$(find "$cache" -path "*/${plugin}/*/${rel}" -type f 2>/dev/null |
    _planner_pick_newest_version "$plugin") || true
  if [ -n "$found" ] && [ -f "$found" ]; then
    echo "$found"
  fi
  return 0
}
