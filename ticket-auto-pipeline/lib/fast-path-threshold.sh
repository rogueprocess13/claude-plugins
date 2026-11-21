#!/usr/bin/env bash
# fast-path-threshold.sh — the one resolver of the appraise fast-path
# confidence threshold (GitHub #774).
#
# A planned ticket that is not Pre-approved takes the appraise fast path only
# when its Planner Context Confidence is at or above this threshold. The
# default (0.85) is unchanged. A project may set its own value on purpose,
# for example a sandbox whose one-repo greenfield tickets cannot score 0.85
# under the planner's confidence formula:
#
#   FAST_PATH_CONFIDENCE_THRESHOLD   environment first, then the
#                                    `FAST_PATH_CONFIDENCE_THRESHOLD = 0.75`
#                                    field of the project CLAUDE.md
#
# Allowed: a plain decimal from 0.60 to 1.00 inclusive.
#   - 0.60 is the floor because the planner's formula starts every ticket at
#     0.50 with no evidence at all, and the smallest evidence it can record
#     (one service, +0.05, and a standard exploration, +0.05) gives 0.60. A
#     lower threshold would admit a ticket the planner knew nothing about,
#     and 0 would turn the check off.
#   - 1.00 is allowed: raising the bar is always safe (only Pre-approved
#     tickets then take the fast path).
# A value that is set but not allowed is ignored with a warning and the next
# source is NOT consulted: the default applies. An invalid value never lowers
# the bar.
#
# Function definitions only — safe to source. Sets no shell options.

_FPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f claude_md_field >/dev/null 2>&1 ||
  source "$_FPT_LIB_DIR/claude-md-field.sh"

FAST_PATH_THRESHOLD_DEFAULT="0.85"
FAST_PATH_THRESHOLD_FLOOR="0.60"

# fast_path_threshold_valid <value>
# 0 when <value> is a plain decimal within [floor, 1].
fast_path_threshold_valid() {
  local v="${1:-}"
  [[ "$v" =~ ^(0\.[0-9]+|1|1\.0+)$ ]] || return 1
  LC_NUMERIC=C awk -v v="$v" -v f="$FAST_PATH_THRESHOLD_FLOOR" \
    'BEGIN { exit !(v + 0 >= f + 0 && v + 0 <= 1) }'
}

# fast_path_threshold_resolve [project_dir]
# Sets, and never fails:
#   FAST_PATH_THRESHOLD          the effective threshold
#   FAST_PATH_THRESHOLD_SOURCE   default | env | CLAUDE.md
#   FAST_PATH_THRESHOLD_REJECTED the set-but-invalid value that was ignored,
#                                else empty
#   FAST_PATH_THRESHOLD_REJECTED_SOURCE  env | CLAUDE.md, else empty
# project_dir defaults to $REPOS_ROOT; with neither, only the environment is
# read. An invalid value is reported once on stderr.
fast_path_threshold_resolve() {
  local dir="${1:-${REPOS_ROOT:-}}" raw="" src=""
  FAST_PATH_THRESHOLD="$FAST_PATH_THRESHOLD_DEFAULT"
  FAST_PATH_THRESHOLD_SOURCE="default"
  FAST_PATH_THRESHOLD_REJECTED=""
  FAST_PATH_THRESHOLD_REJECTED_SOURCE=""

  if [ -n "${FAST_PATH_CONFIDENCE_THRESHOLD:-}" ]; then
    raw="$FAST_PATH_CONFIDENCE_THRESHOLD"
    src="env"
  elif [ -n "$dir" ] && raw=$(claude_md_field "$dir/CLAUDE.md" FAST_PATH_CONFIDENCE_THRESHOLD); then
    src="CLAUDE.md"
  else
    return 0
  fi

  if fast_path_threshold_valid "$raw"; then
    FAST_PATH_THRESHOLD="$raw"
    FAST_PATH_THRESHOLD_SOURCE="$src"
  else
    FAST_PATH_THRESHOLD_REJECTED="$raw"
    FAST_PATH_THRESHOLD_REJECTED_SOURCE="$src"
    echo "fast-path-threshold: FAST_PATH_CONFIDENCE_THRESHOLD='$raw' ($src) is not a number from $FAST_PATH_THRESHOLD_FLOOR to 1.00 — ignored, using the default $FAST_PATH_THRESHOLD_DEFAULT" >&2
  fi
  return 0
}

# fast_path_threshold_lowered
# 0 when the resolved threshold is below the default. Call after resolve.
fast_path_threshold_lowered() {
  LC_NUMERIC=C awk -v t="${FAST_PATH_THRESHOLD:-$FAST_PATH_THRESHOLD_DEFAULT}" \
    -v d="$FAST_PATH_THRESHOLD_DEFAULT" 'BEGIN { exit !(t + 0 < d + 0) }'
}

# fast_path_threshold_describe
# One line for logs: `threshold=0.75 source=CLAUDE.md default=0.85`, plus
# ` rejected=<value>(<source>)` when an invalid value was ignored.
fast_path_threshold_describe() {
  local out="threshold=${FAST_PATH_THRESHOLD:-$FAST_PATH_THRESHOLD_DEFAULT} source=${FAST_PATH_THRESHOLD_SOURCE:-default} default=$FAST_PATH_THRESHOLD_DEFAULT"
  if [ -n "${FAST_PATH_THRESHOLD_REJECTED:-}" ]; then
    out="$out rejected=${FAST_PATH_THRESHOLD_REJECTED}(${FAST_PATH_THRESHOLD_REJECTED_SOURCE})"
  fi
  printf '%s\n' "$out"
}

# fast_path_threshold_env_check_row [project_dir]
# One `NAME|STATUS|VALUE|LOCATION|NOTE` row for /ticket-env-check, or nothing
# when the field is not set anywhere. Never an issue: ok, info or warn.
#   warn  the value lowers the bar, or is invalid and ignored
#   info  the value raises the bar
#   ok    the value equals the default
fast_path_threshold_env_check_row() {
  local dir="${1:-$PWD}" loc
  fast_path_threshold_resolve "$dir" 2>/dev/null
  if [ -n "$FAST_PATH_THRESHOLD_REJECTED" ]; then
    printf 'FAST_PATH_CONFIDENCE_THRESHOLD|warn|%s|%s|%s\n' \
      "${FAST_PATH_THRESHOLD_REJECTED//|/ }" "$FAST_PATH_THRESHOLD_REJECTED_SOURCE" \
      "invalid: not a number from $FAST_PATH_THRESHOLD_FLOOR to 1.00; ignored, the default $FAST_PATH_THRESHOLD_DEFAULT applies"
    return 0
  fi
  [ "$FAST_PATH_THRESHOLD_SOURCE" != "default" ] || return 0
  loc="$FAST_PATH_THRESHOLD_SOURCE"
  if fast_path_threshold_lowered; then
    printf 'FAST_PATH_CONFIDENCE_THRESHOLD|warn|%s|%s|%s\n' "$FAST_PATH_THRESHOLD" "$loc" \
      "below the default $FAST_PATH_THRESHOLD_DEFAULT: planned tickets at or above $FAST_PATH_THRESHOLD skip the full appraisal in this project"
  elif [ "$(LC_NUMERIC=C awk -v t="$FAST_PATH_THRESHOLD" -v d="$FAST_PATH_THRESHOLD_DEFAULT" 'BEGIN { print (t + 0 > d + 0) ? "above" : "same" }')" = "above" ]; then
    printf 'FAST_PATH_CONFIDENCE_THRESHOLD|info|%s|%s|%s\n' "$FAST_PATH_THRESHOLD" "$loc" \
      "above the default $FAST_PATH_THRESHOLD_DEFAULT: fewer planned tickets take the appraise fast path"
  else
    printf 'FAST_PATH_CONFIDENCE_THRESHOLD|ok|%s|%s|%s\n' "$FAST_PATH_THRESHOLD" "$loc" "same as the default"
  fi
  return 0
}
