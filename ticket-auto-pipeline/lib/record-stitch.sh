#!/usr/bin/env bash
# record-stitch.sh — turn recording manifests into a video (openspec change
# ticket-auto-record, design D5).
#
# Two halves:
#
#   plan    pure bash/jq. Reads <ticket dir>/artifacts/recordings/manifest.jsonl
#           and prints a plan. Never runs ffmpeg, never writes a file.
#   render  runs ffmpeg over a plan. The only code here that needs ffmpeg.
#
# A plan is an ffmpeg concat list (ffconcat 1.0) plus title-card lines that
# ffmpeg reads as comments:
#
#   ffconcat version 1.0
#   #title 2 CRE-12 Total shows the right amount
#   file '/abs/…/CRE-12--total/artifacts/recordings/board-7-human-approved.png'
#   duration 2
#   file '/abs/…/CRE-12--total/artifacts/recordings/verify-a2-001.png'
#   duration 1.5
#
# `#title <seconds> <TID> <title>` stands for one title card at that place.
# A plan with no `file` line is empty.
#
# What the planner lets in (nothing here is the caller's or an agent's choice):
#   - entries with status "ok" only; lines that do not parse are skipped
#   - an app entry only when its env is allowed by the *current* RECORD_ALLOWED
#     (a board entry carries no env; a board entry that does carry one is held
#     to the same rule). Nothing is planned when RECORD_ALLOWED allows nothing
#   - VERIFY frames of the latest attempt only: the highest `attempt` any
#     verify entry of that ticket has, whatever its status, so an attempt that
#     recorded nothing gives no frames, never an older attempt's
#   - `file` must be a basename matching _RS_FILE_RE, a regular file, not a
#     symlink, and resolve (realpath) to exactly
#     <realpath of the ticket dir>/artifacts/recordings/<file>
#   - nothing is globbed; the per-criterion artifacts/verify-*.png evidence
#     files are never read
#   - order: ts, then manifest line order. Output is the same on every run
#
# Usage:
#   record-stitch.sh plan clip <TID>
#   record-stitch.sh plan video [--order time|given] <TID>...
#   record-stitch.sh render <plan file | -> <out.mp4>
#   record-stitch.sh clip <TID>
#       → <ticket dir>/artifacts/recordings/<TID>-verify.mp4
#   record-stitch.sh video [--order time|given] [--out FILE] <TID>...
#       → FILE, default ./recording-<TID>.mp4 (./recording-<TID>-plus<N>.mp4)
#
# clip: the latest VERIFY attempt's app frames, 1.5 s each.
# video: per ticket a 2 s title card (id and title from context.md), then
#   every ok entry in ts order (board 2 s, app 1.5 s). Tickets come in the
#   order of their first frame (--order time, default) or as given
#   (--order given). A ticket with nothing to show is left out, with a note on
#   stderr.
# clip and video print the output path on stdout.
#
# Exit codes:
#   0  done (plan: also for an empty plan)
#   2  usage, or a ticket id that is not one (nothing on stdout)
#   3  nothing to render: empty plan, or a plan line that is not allowed
#   4  ffmpeg is not installed
#   5  ffmpeg failed or timed out (RECORD_STITCH_TIMEOUT seconds for one
#      render, default 300)
# On 3, 4 and 5 no output file is written and an existing one is left alone.
#
# Never writes to the pipeline log, the manifest or any input file.
# Needs REPOS_ROOT (environment; the CLI also reads it from ./CLAUDE.md) and
# RECORD_ALLOWED (environment first, then $REPOS_ROOT/CLAUDE.md), jq, and for
# render ffmpeg with libx264.
#
# Sourceable: sets no shell options.

_RS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f record_field >/dev/null 2>&1 ||
  source "$_RS_LIB_DIR/record.sh"
declare -f resolve_ticket_dir >/dev/null 2>&1 ||
  source "$_RS_LIB_DIR/ticket-dir.sh"

_RS_TID_RE='^[A-Za-z][A-Za-z0-9]*-[0-9]+$'
_RS_FILE_RE='^(verify-a[0-9]+-[0-9]{3}|board-[0-9]+-[a-z0-9-]+)\.png$'
_RS_APP_SECS=1.5
_RS_BOARD_SECS=2
_RS_TITLE_SECS=2
_RS_BG=1b1f24
_RS_W=1280
_RS_H=800

_rs_err() { echo "record-stitch: $*" >&2; }

_rs_usage() {
  cat >&2 <<'EOF'
Usage: record-stitch.sh plan clip <TID>
       record-stitch.sh plan video [--order time|given] <TID>...
       record-stitch.sh render <plan file | -> <out.mp4>
       record-stitch.sh clip <TID>
       record-stitch.sh video [--order time|given] [--out FILE] <TID>...
EOF
}

# _rs_ticket_dir <TID> — the ticket workspace's real path, or nothing.
_rs_ticket_dir() {
  local tid="$1" root dir
  root=$(record_field REPOS_ROOT)
  [ -n "$root" ] && [ -d "$root" ] || return 0
  # CLAUDE_LOG_FILE= : "not found" must not reach any log (error_return).
  dir=$(CLAUDE_LOG_FILE='' resolve_ticket_dir "$tid" "$root" 2>/dev/null) || dir=""
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  realpath -e -- "$dir" 2>/dev/null || true
}

# _rs_title <ticket dir> — the ticket title from context.md's first line
# (`# <ID>: <title>`, ticket-setup's layout), on one line, at most 80 chars.
_rs_title() {
  local f="$1/context.md"
  [ -f "$f" ] || return 0
  sed -n '1s/^# [^:]*: *//p' "$f" 2>/dev/null |
    tr -d '\000-\037\177' | cut -c1-80
}

# _rs_allowed_csv — the environments RECORD_ALLOWED allows now, comma-joined.
_rs_allowed_csv() {
  record_allowed_parse "$(record_field RECORD_ALLOWED)" 2>/dev/null | paste -sd, -
}

# _rs_entries <ticket dir> <clip|video> <allowed csv>
# Prints `<ts>\t<source>\t<file>` for every manifest entry that may be
# stitched, in ts order. File safety is checked by the caller.
_rs_entries() {
  local manifest="$1/artifacts/recordings/manifest.jsonl" mode="$2" allowed="$3"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 0
  jq -R -r -s --arg mode "$mode" --arg allowed "$allowed" '
    ($allowed | split(",") | map(select(. != ""))) as $envs
    | [ split("\n")[] | (try fromjson catch null) | select(type == "object") ] as $all
    | ([ $all[] | select(.phase == "verify") | .attempt | select(type == "number") ]
       | max) as $latest
    | [ $all[]
        | select(.status == "ok")
        | select(.source == "app" or .source == "board")
        | select(.file | type == "string")
        | select(if .source == "app"
                 then (.env | type == "string") and ((.env as $e | $envs | index($e)) != null)
                 else (.env == null) or ((.env as $e | $envs | index($e)) != null) end)
        | select(.source != "app" or (.phase == "verify" and .attempt == $latest))
        | select($mode != "clip" or .source == "app")
      ]
    | sort_by(.ts | tostring)
    | .[]
    | [(.ts | tostring), .source, .file] | @tsv
  ' "$manifest" 2>/dev/null || true
}

# _rs_safe_file <ticket dir (real)> <file> — print the frame's absolute path
# when it passes the whitelist, else nothing.
_rs_safe_file() {
  local tdir="$1" name="$2" want real
  [[ "$name" =~ $_RS_FILE_RE ]] || return 0
  want="$tdir/artifacts/recordings/$name"
  [ -f "$want" ] && [ ! -L "$want" ] || return 0
  real=$(realpath -e -- "$want" 2>/dev/null) || return 0
  [ "$real" = "$want" ] || return 0
  printf '%s\n' "$real"
}

# _rs_quote <path> — the path as an ffconcat single-quoted string.
_rs_quote() {
  local p="$1" q="'\\''"
  printf "'%s'" "${p//\'/$q}"
}

# _rs_ticket_lines <TID> <clip|video> <allowed csv>
# Prints the plan body for one ticket: first line is the first frame's ts
# (for ordering), then the `file`/`duration` pairs. Prints nothing when the
# ticket has nothing to show.
_rs_ticket_lines() {
  local tid="$1" mode="$2" allowed="$3" tdir ts source name path first="" body=""
  tdir=$(_rs_ticket_dir "$tid")
  [ -n "$tdir" ] || {
    _rs_err "$tid: no ticket directory under REPOS_ROOT; left out"
    return 0
  }
  while IFS=$'\t' read -r ts source name; do
    [ -n "$name" ] || continue
    path=$(_rs_safe_file "$tdir" "$name")
    [ -n "$path" ] || continue
    [ -n "$first" ] || first="$ts"
    body+="file $(_rs_quote "$path")"$'\n'
    if [ "$source" = "board" ]; then
      body+="duration $_RS_BOARD_SECS"$'\n'
    else
      body+="duration $_RS_APP_SECS"$'\n'
    fi
  done < <(_rs_entries "$tdir" "$mode" "$allowed")
  [ -n "$body" ] || {
    _rs_err "$tid: no recordable frames; left out"
    return 0
  }
  printf '%s\n' "$first"
  if [ "$mode" = "video" ]; then
    printf '#title %s %s %s\n' "$_RS_TITLE_SECS" "$tid" "$(_rs_title "$tdir")" |
      sed 's/[[:space:]]*$//'
  fi
  printf '%s' "$body"
}

# _rs_check_ids <TID>... — 0 when every argument is a ticket id.
_rs_check_ids() {
  local tid
  [ $# -gt 0 ] || return 1
  for tid in "$@"; do
    if ! [[ "$tid" =~ $_RS_TID_RE ]]; then
      _rs_err "'$tid' is not a ticket id"
      return 1
    fi
  done
}

# record_stitch_plan clip <TID> | video [--order time|given] <TID>...
record_stitch_plan() {
  local mode="${1:-}" order="time"
  shift || true
  case "$mode" in
  clip)
    [ $# -eq 1 ] || {
      _rs_usage
      return 2
    }
    ;;
  video)
    if [ "${1:-}" = "--order" ]; then
      order="${2:-}"
      shift 2 || true
    fi
    case "$order" in time | given) ;; *)
      _rs_usage
      return 2
      ;;
    esac
    ;;
  *)
    _rs_usage
    return 2
    ;;
  esac
  _rs_check_ids "$@" || return 2

  local allowed tid seen=" " i=0 lines first work
  allowed=$(_rs_allowed_csv)
  [ -n "$allowed" ] ||
    _rs_err "RECORD_ALLOWED allows no environment; nothing can be stitched"

  # One block per ticket, sorted by (first frame ts | nothing, argument index).
  work=""
  for tid in "$@"; do
    case "$seen" in *" $tid "*) continue ;; esac
    seen+="$tid "
    i=$((i + 1))
    [ -n "$allowed" ] || continue
    lines=$(_rs_ticket_lines "$tid" "$mode" "$allowed")
    [ -n "$lines" ] || continue
    first=$(printf '%s\n' "$lines" | head -1)
    # "-" for --order given: every key equal, so the argument index decides.
    # (Never an empty key: read would fold the leading tab away.)
    [ "$order" = "given" ] && first="-"
    work+=$(printf '%s\t%05d\t%s' "${first:--}" "$i" \
      "$(printf '%s\n' "$lines" | tail -n +2 | base64 -w0)")$'\n'
  done

  echo "ffconcat version 1.0"
  [ -n "$work" ] || return 0
  printf '%s' "$work" | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 | while IFS=$'\t' read -r _ _ lines; do
    printf '%s' "$lines" | base64 -d
  done
  return 0
}

# _rs_plan_file_ok <path> — a plan `file` line may name only a recording
# frame: whitelisted basename, inside an artifacts/recordings dir, regular,
# not a symlink, and already in real-path form.
_rs_plan_file_ok() {
  local p="$1" real
  [[ "$(basename -- "$p")" =~ $_RS_FILE_RE ]] || return 1
  case "$(dirname -- "$p")" in /*/artifacts/recordings) ;; *) return 1 ;; esac
  [ -f "$p" ] && [ ! -L "$p" ] || return 1
  real=$(realpath -e -- "$p" 2>/dev/null) || return 1
  [ "$real" = "$p" ]
}

# _rs_ffmpeg <args>... — ffmpeg, quiet, bounded by what is left of the render's
# time budget (_RS_DEADLINE, in $SECONDS).
_rs_ffmpeg() {
  local left=$((${_RS_DEADLINE:-0} - SECONDS))
  [ "$left" -ge 1 ] || left=1
  timeout -k 5 "$left" ffmpeg -nostdin -hide_banner -loglevel error -y "$@"
}

# _rs_frame <src png> <dst png> — one frame scaled and padded to the output
# size. Every frame is normalised on its own first: the concat demuxer drops
# frames whose size differs from the first one's.
_rs_frame() {
  _rs_ffmpeg -i "$1" \
    -vf "scale=${_RS_W}:${_RS_H}:force_original_aspect_ratio=decrease,pad=${_RS_W}:${_RS_H}:(ow-iw)/2:(oh-ih)/2:color=0x$_RS_BG,format=rgb24" \
    -frames:v 1 "$2" >/dev/null 2>&1 && [ -s "$2" ]
}

# _rs_card <png> <tid> <title> — one title-card PNG. Text through drawtext
# when this ffmpeg has it; a plain card otherwise. Runs in the PNG's own
# directory so no path has to be escaped inside the filter.
_rs_card() {
  local png="$1" tid="$2" title="$3" dir base
  dir=$(dirname -- "$png")
  base=$(basename -- "$png")
  (
    cd "$dir" || exit 1
    printf '%s' "$tid" >"$base.id.txt"
    printf '%s' "${title:- }" >"$base.title.txt"
    _rs_ffmpeg -f lavfi -i "color=c=0x$_RS_BG:s=${_RS_W}x${_RS_H}" \
      -vf "drawtext=textfile=$base.id.txt:fontcolor=white:fontsize=64:x=(w-text_w)/2:y=h/2-90,drawtext=textfile=$base.title.txt:fontcolor=0xc9d1d9:fontsize=34:x=(w-text_w)/2:y=h/2+10,format=rgb24" \
      -frames:v 1 "$base" >/dev/null 2>&1 && [ -s "$base" ] && exit 0
    rm -f -- "$base"
    _rs_ffmpeg -f lavfi -i "color=c=0x$_RS_BG:s=${_RS_W}x${_RS_H}" \
      -vf "format=rgb24" -frames:v 1 "$base" >/dev/null 2>&1 && [ -s "$base" ]
  )
}

# record_stitch_render <plan file | -> <out.mp4>
record_stitch_render() {
  local plan_src="${1:-}" out="${2:-}"
  if [ -z "$plan_src" ] || [ -z "$out" ] || [ $# -ne 2 ]; then
    _rs_usage
    return 2
  fi
  local plan
  if [ "$plan_src" = "-" ]; then
    plan=$(cat)
  elif [ -f "$plan_src" ]; then
    plan=$(cat -- "$plan_src")
  else
    _rs_err "no plan file at $plan_src"
    return 2
  fi
  if ! grep -q '^file ' <<<"$plan"; then
    _rs_err "nothing to render: the plan has no frames"
    return 3
  fi
  if ! command -v ffmpeg >/dev/null 2>&1; then
    _rs_err "ffmpeg is not installed; no video written"
    return 4
  fi

  local out_dir tmp rc=0
  out_dir=$(dirname -- "$out")
  if [ ! -d "$out_dir" ] || [ -d "$out" ]; then
    _rs_err "cannot write $out"
    return 2
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/record-stitch.XXXXXX") || {
    _rs_err "cannot create a work directory"
    return 5
  }

  # The real concat list: title cards become PNGs, every frame is re-checked
  # and normalised into the work directory, and the last file is named twice (the concat demuxer ignores
  # the last entry's duration otherwise).
  local line path last="" n=0 secs tid title card list="$tmp/list.ffconcat"
  local _RS_DEADLINE=$((SECONDS + ${RECORD_STITCH_TIMEOUT:-300}))
  echo "ffconcat version 1.0" >"$list"
  while IFS= read -r line; do
    case "$line" in
    "#title "*)
      read -r _ secs tid title <<<"$line"
      if ! [[ "$secs" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! [[ "$tid" =~ $_RS_TID_RE ]]; then
        _rs_err "bad title line in the plan"
        rc=3
        break
      fi
      n=$((n + 1))
      card="$tmp/card-$n.png"
      if ! _rs_card "$card" "$tid" "$title"; then
        _rs_err "ffmpeg could not draw the title card for $tid"
        rc=5
        break
      fi
      last="file '$card'"
      printf '%s\nduration %s\n' "$last" "$secs" >>"$list"
      ;;
    "file '"*"'")
      path="${line#file \'}"
      path="${path%\'}"
      path="${path//\'\\\'\'/\'}"
      if ! _rs_plan_file_ok "$path"; then
        _rs_err "plan names a file that is not a recording frame; nothing rendered"
        rc=3
        break
      fi
      n=$((n + 1))
      card="$tmp/frame-$n.png"
      if ! _rs_frame "$path" "$card"; then
        _rs_err "ffmpeg could not read $(basename -- "$path"); no video written"
        rc=5
        break
      fi
      last="file '$card'"
      printf '%s\n' "$last" >>"$list"
      ;;
    "duration "*)
      if ! [[ "${line#duration }" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        _rs_err "bad duration line in the plan"
        rc=3
        break
      fi
      printf '%s\n' "$line" >>"$list"
      ;;
    "ffconcat version 1.0" | "" | "#"*) ;;
    *)
      _rs_err "plan line not understood; nothing rendered"
      rc=3
      break
      ;;
    esac
  done <<<"$plan"

  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$last" >>"$list"
    local part="$tmp/out.mp4"
    _rs_ffmpeg -f concat -safe 0 -i "$list" \
      -vf "fps=25,format=yuv420p" \
      -c:v libx264 -an -movflags +faststart -f mp4 "$part" >"$tmp/ffmpeg.log" 2>&1 || rc=5
    if [ "$rc" -eq 0 ] && [ ! -s "$part" ]; then
      rc=5
    fi
    if [ "$rc" -ne 0 ]; then
      _rs_err "ffmpeg failed; no video written"
      tail -5 "$tmp/ffmpeg.log" >&2 2>/dev/null || true
    elif ! mv -f -- "$part" "$out" 2>/dev/null; then
      _rs_err "cannot write $out"
      rc=5
    fi
  fi
  rm -rf -- "$tmp"
  return "$rc"
}

# record_stitch_clip <TID>
record_stitch_clip() {
  if [ $# -ne 1 ]; then
    _rs_usage
    return 2
  fi
  _rs_check_ids "$1" || return 2
  local tid="$1" plan tdir out rc=0
  plan=$(record_stitch_plan clip "$tid") || return $?
  tdir=$(_rs_ticket_dir "$tid")
  if [ -z "$tdir" ] || ! grep -q '^file ' <<<"$plan"; then
    _rs_err "nothing to render for $tid"
    return 3
  fi
  out="$tdir/artifacts/recordings/$tid-verify.mp4"
  record_stitch_render - "$out" <<<"$plan" || rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out"
  return "$rc"
}

# record_stitch_video [--order time|given] [--out FILE] <TID>...
record_stitch_video() {
  local order="time" out="" tids=()
  while [ $# -gt 0 ]; do
    case "$1" in
    --order | --out)
      if [ $# -lt 2 ]; then
        _rs_usage
        return 2
      fi
      if [ "$1" = "--order" ]; then order="$2"; else out="$2"; fi
      shift 2
      ;;
    *)
      tids+=("$1")
      shift
      ;;
    esac
  done
  _rs_check_ids "${tids[@]}" || return 2
  if [ -z "$out" ]; then
    out="./recording-${tids[0]}"
    [ "${#tids[@]}" -gt 1 ] && out+="-plus$((${#tids[@]} - 1))"
    out+=".mp4"
  fi
  local plan rc=0
  plan=$(record_stitch_plan video --order "$order" "${tids[@]}") || return $?
  record_stitch_render - "$out" <<<"$plan" || rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out"
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # A person runs this from the tickets root; REPOS_ROOT may only be in the
  # project CLAUDE.md there.
  if [ -z "${REPOS_ROOT:-}" ] && [ -f ./CLAUDE.md ]; then
    _rs_root=$(claude_md_field ./CLAUDE.md REPOS_ROOT 2>/dev/null) || _rs_root=""
    [ -n "$_rs_root" ] && [ -d "$_rs_root" ] && export REPOS_ROOT="$_rs_root"
  fi
  case "${1:-}" in
  plan)
    shift
    record_stitch_plan "$@"
    exit $?
    ;;
  render)
    shift
    record_stitch_render "$@"
    exit $?
    ;;
  clip)
    shift
    record_stitch_clip "$@"
    exit $?
    ;;
  video)
    shift
    record_stitch_video "$@"
    exit $?
    ;;
  *)
    _rs_usage
    exit 2
    ;;
  esac
fi
