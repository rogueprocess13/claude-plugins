#!/usr/bin/env bash
# fleet-features — inventory of every opt-in/opt-out feature flag in the
# marketplace, with the effective value on this host and where it came from.
#
# Deterministic half of /fleet-controller:fleet-features: this script reads the
# catalog (fleet-controller/features.json) and resolves values; the skill only
# presents and recommends. Read-only — never sources or executes fleet-start.sh
# (it is parsed as text) and never writes anything.
#
# Resolution precedence, first hit wins:
#   1. current process environment                (source: env)
#   2. `export NAME=value` in $WS/fleet-start.sh  (source: fleet-start.sh)
#   3. `.env.NAME` in $WS/.claude/settings.local.json (source: settings.local.json)
#   4. catalog default                            (source: default)
# A fleet-start.sh value built from `$(...)`/`${...}` cannot be resolved without
# executing the file; it is skipped (noted as "dynamic") and resolution falls
# through to settings.local.json, which is what such lines read in practice.
#
# WS = --workspace DIR, else $FLEETD_WORKSPACE, else the current directory.
#
# Usage: fleet-features.sh [--workspace DIR] [--json] [--no-env] [--catalog FILE]
#   --json      machine-readable output (one object; see the skill for the shape)
#   --no-env    skip layer 1 — show only what the workspace files configure
#   --catalog   catalog path (default: ../features.json next to this script,
#               then $CLAUDE_PLUGIN_ROOT/features.json, then the plugin cache)
#
# Secret safety: the value of any name matching KEY|TOKEN|SECRET|PASS|HEADERS is
# never printed — catalog flags are masked to "****", and prerequisite env vars
# are only ever reported as set/unset.
set -euo pipefail

WORKSPACE=""
JSON=false
NO_ENV=false
CATALOG=""

_usage() {
  sed -n '/^# Usage:/,/^#   --catalog/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
  --workspace)
    [ $# -ge 2 ] || {
      echo "fleet-features: --workspace requires a directory" >&2
      exit 12
    }
    WORKSPACE="$2"
    shift 2
    ;;
  --workspace=*)
    WORKSPACE="${1#*=}"
    shift
    ;;
  --catalog)
    [ $# -ge 2 ] || {
      echo "fleet-features: --catalog requires a file" >&2
      exit 12
    }
    CATALOG="$2"
    shift 2
    ;;
  --catalog=*)
    CATALOG="${1#*=}"
    shift
    ;;
  --json)
    JSON=true
    shift
    ;;
  --no-env)
    NO_ENV=true
    shift
    ;;
  -h | --help)
    _usage
    exit 0
    ;;
  *)
    echo "fleet-features: unexpected argument: $1" >&2
    _usage
    exit 12
    ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  echo "fleet-features: jq is required" >&2
  exit 1
}

WORKSPACE="${WORKSPACE:-${FLEETD_WORKSPACE:-$(pwd)}}"

if [ -z "$CATALOG" ]; then
  _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for _c in "$_self_dir/../features.json" "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/features.json"; do
    if [ -f "$_c" ]; then
      CATALOG="$_c"
      break
    fi
  done
  if [ -z "$CATALOG" ]; then
    # The SessionStart hook syncs lib/*.sh (not the catalog) to
    # ~/.claude/skills/lib/, so a synced copy finds the catalog in the cache.
    CATALOG=$(find "${HOME}/.claude/plugins/cache" -path "*/fleet-controller/*/features.json" 2>/dev/null |
      sort -V | tail -1) || true
  fi
fi
[ -n "$CATALOG" ] && [ -f "$CATALOG" ] || {
  echo "fleet-features: catalog features.json not found (pass --catalog)" >&2
  exit 1
}
jq -e '.flags | type == "array"' "$CATALOG" >/dev/null 2>&1 || {
  echo "fleet-features: $CATALOG is not a valid catalog" >&2
  exit 1
}

START_SH="$WORKSPACE/fleet-start.sh"
SETTINGS="$WORKSPACE/.claude/settings.local.json"
SETTINGS_OK=false
if [ -f "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
  SETTINGS_OK=true
fi

_is_secret_name() {
  [[ "$1" =~ (KEY|TOKEN|SECRET|PASS|HEADERS) ]]
}

# _start_sh_value NAME — prints "<kind>\t<value>" for the LAST uncommented
# `export NAME=...` line in fleet-start.sh; kind is "static" or "dynamic".
# Prints nothing when absent. Pure text parsing — the file is never executed.
_start_sh_value() {
  local name="$1" line rest val
  [ -f "$START_SH" ] || return 0
  line=$(grep -E "^[[:space:]]*export[[:space:]]+${name}=" "$START_SH" 2>/dev/null | tail -1) || true
  [ -n "$line" ] || return 0
  rest="${line#*"${name}="}"
  case "$rest" in
  \"*)
    rest="${rest#\"}"
    val="${rest%%\"*}"
    ;;
  \'*)
    rest="${rest#\'}"
    val="${rest%%\'*}"
    ;;
  *)
    val="${rest%%[[:space:];]*}"
    ;;
  esac
  if [[ "$val" == *'$'* || "$val" == *'`'* ]]; then
    printf 'dynamic\t\n'
  else
    printf 'static\t%s\n' "$val"
  fi
}

# _resolve NAME DEFAULT — prints "<value>\t<source>\t<set>" where set is true
# when some layer (not the default) supplied the value.
_resolve() {
  local name="$1" def="$2" sv kind val note=""
  if ! $NO_ENV && [ -n "${!name+x}" ]; then
    printf '%s\tenv\ttrue\n' "${!name}"
    return 0
  fi
  sv=$(_start_sh_value "$name")
  if [ -n "$sv" ]; then
    kind="${sv%%$'\t'*}"
    val="${sv#*$'\t'}"
    if [ "$kind" = "static" ]; then
      printf '%s\tfleet-start.sh\ttrue\n' "$val"
      return 0
    fi
    note=" (fleet-start.sh line is dynamic)"
  fi
  if $SETTINGS_OK && jq -e --arg n "$name" '(.env // {}) | has($n)' "$SETTINGS" >/dev/null 2>&1; then
    val=$(jq -r --arg n "$name" '.env[$n] | if type == "string" then . else tojson end' "$SETTINGS")
    printf '%s\tsettings.local.json%s\ttrue\n' "$val" "$note"
    return 0
  fi
  if [ -n "$note" ]; then
    printf '%s\tdefault%s\tfalse\n' "$def" "$note"
    return 0
  fi
  printf '%s\tdefault\tfalse\n' "$def"
}

# ── Pass 1: resolve every catalog flag ──────────────────────────────────────────
declare -A VAL SRC ENABLED
NAMES=()
while IFS=$'\x1f' read -r name def onv; do
  [ -n "$name" ] || continue
  NAMES+=("$name")
  r=$(_resolve "$name" "$def")
  v="${r%%$'\t'*}"
  r="${r#*$'\t'}"
  s="${r%%$'\t'*}"
  VAL[$name]="$v"
  SRC[$name]="$s"
  if [ "$v" = "$onv" ]; then ENABLED[$name]=true; else ENABLED[$name]=false; fi
done < <(jq -r '.flags[] | [.name, (.default | tostring), ((.on_value // "true") | tostring)] | join("\u001f")' "$CATALOG")

# ── Pass 2: requirements + record assembly ──────────────────────────────────────
# Each record is one compact JSON object; jq assembles the final document.
RECORDS_FILE=$(mktemp)
trap 'rm -f "$RECORDS_FILE"' EXIT

for name in "${NAMES[@]}"; do
  reqs="[]"
  while IFS=$'\x1f' read -r kind a b note; do
    [ -n "$kind" ] || continue
    case "$kind" in
    flag)
      if [ -n "${ENABLED[$a]+x}" ]; then
        met="${ENABLED[$a]}"
      else
        met=false
        note="${note:+$note; }not in catalog"
      fi
      reqs=$(jq -c --arg n "$a" --argjson m "$met" --arg note "$note" \
        '. + [{kind: "flag", name: $n, met: $m} + (if $note == "" then {} else {note: $note} end)]' <<<"$reqs")
      ;;
    env)
      met=false
      shown="$a"
      for e in $a $b; do
        r=$(_resolve "$e" "")
        if [ -n "${r%%$'\t'*}" ]; then met=true; fi
      done
      if [ -n "$b" ]; then shown="$a or $b"; fi
      reqs=$(jq -c --arg n "$shown" --argjson m "$met" --arg note "$note" \
        '. + [{kind: "env", name: $n, met: $m} + (if $note == "" then {} else {note: $note} end)]' <<<"$reqs")
      ;;
    step)
      reqs=$(jq -c --arg t "$a" '. + [{kind: "step", text: $t, met: null}]' <<<"$reqs")
      ;;
    esac
  done < <(jq -r --arg n "$name" '.flags[] | select(.name == $n) | (.requires // [])[] |
    if has("flag") then ["flag", .flag, "", (.note // "")]
    elif has("env") then ["env", .env, (.or_env // ""), (.note // "")]
    else ["step", (.step // ""), "", ""] end | join("\u001f")' "$CATALOG")

  value="${VAL[$name]}"
  if _is_secret_name "$name"; then
    value="****"
  fi
  jq -c --arg n "$name" --arg v "$value" --arg s "${SRC[$name]}" --argjson e "${ENABLED[$name]}" \
    --argjson reqs "$reqs" '
    .flags[] | select(.name == $n) |
    {name, plugin, category, value: $v, source: $s, default: (.default | tostring),
     on_value: ((.on_value // "true") | tostring), enabled: $e, recommend,
     summary, why, docs, requires: $reqs,
     requires_met: (if ([$reqs[] | select(.met != null)] | length) == 0 then null
                    else ([$reqs[] | select(.met == false)] | length) == 0 end),
     unmet: [$reqs[] | select(.met == false) | .name],
     manual_steps: [$reqs[] | select(.kind == "step") | .text]}
  ' "$CATALOG" >>"$RECORDS_FILE"
done

if $JSON; then
  jq -s --arg ws "$WORKSPACE" --arg cat "$CATALOG" \
    --argjson fs "$([ -f "$START_SH" ] && echo true || echo false)" \
    --argjson sl "$SETTINGS_OK" --argjson noenv "$NO_ENV" '
    {workspace: $ws, catalog: $cat,
     sources: {env: ($noenv | not), "fleet-start.sh": $fs, "settings.local.json": $sl},
     count: length, flags: .}' "$RECORDS_FILE"
  exit 0
fi

echo "Workspace: $WORKSPACE"
echo "Catalog:   $CATALOG"
printf 'Sources:   env=%s fleet-start.sh=%s settings.local.json=%s\n\n' \
  "$($NO_ENV && echo skipped || echo yes)" \
  "$([ -f "$START_SH" ] && echo found || echo absent)" \
  "$($SETTINGS_OK && echo found || echo absent)"
{
  printf 'NAME\tPLUGIN\tCATEGORY\tVALUE\tON\tSOURCE\tDEFAULT\tRECOMMEND\tREQUIRES\n'
  jq -r '[.name, .plugin, .category, (if .value == "" then "\"\"" else .value end),
          (if .enabled then "on" else "off" end), .source, .default, .recommend,
          (if .requires_met == false then "UNMET:" + (.unmet | join(","))
           elif .requires_met == true then "ok"
           elif (.manual_steps | length) > 0 then "manual" else "-" end)
          + (if (.manual_steps | length) > 0 and .requires_met != null then "+manual" else "" end)
         ] | @tsv' "$RECORDS_FILE"
} | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
