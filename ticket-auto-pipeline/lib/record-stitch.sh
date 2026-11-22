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
# Overlay (openspec change record-stitch-overlay): unless --no-overlay, every
# frame's `file` line is followed by
#   #overlay <elapsed_s> <tokens_total> <tokens_out> <agents> <idle|normal|fast>
# computed from the ticket's {TID}-pipeline.log (lib/log-dir.sh; read only),
# counting log lines at or before the frame's ts, to the second: seconds since
# the ticket's first log line, the sum of its META|tokens in+out+cache and of
# out, agent intervals open across every ticket named, and the animation tier
# (RECORD_ANIM_FAST_TPS output tokens/s, default 10). A ticket without a log
# gets none. render draws the text at the top right; with --anim it also
# loops the lib/record-assets/ coder sprite at the bottom left.
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
#   record-stitch.sh plan clip [--no-overlay] <TID>
#   record-stitch.sh plan video [--no-overlay] [--order time|given] <TID>...
#   record-stitch.sh render [--anim] <plan file | -> <out.mp4>
#   record-stitch.sh clip [--no-overlay] [--anim] <TID>
#       → <ticket dir>/artifacts/recordings/<TID>-verify.mp4
#   record-stitch.sh video [--no-overlay] [--anim] [--order time|given] [--out FILE] <TID>...
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
#   3  nothing to render: empty plan, a plan line that is not allowed, a
#      malformed #overlay line, or (--anim) a missing sprite PNG
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
declare -f ticket_log_dir >/dev/null 2>&1 ||
  source "$_RS_LIB_DIR/log-dir.sh"

_RS_TID_RE='^[A-Za-z][A-Za-z0-9]*-[0-9]+$'
_RS_FILE_RE='^(verify-a[0-9]+-[0-9]{3}|board-[0-9]+-[a-z0-9-]+)\.png$'
_RS_APP_SECS=1.5
_RS_BOARD_SECS=2
_RS_TITLE_SECS=2
_RS_BG=1b1f24
_RS_W=1280
_RS_H=800
_RS_FAST_TPS_DEFAULT=10
_RS_ASSET_DIR="$_RS_LIB_DIR/record-assets"

_rs_err() { echo "record-stitch: $*" >&2; }

_rs_usage() {
  cat >&2 <<'EOF'
Usage: record-stitch.sh plan clip [--no-overlay] <TID>
       record-stitch.sh plan video [--no-overlay] [--order time|given] <TID>...
       record-stitch.sh render [--anim] <plan file | -> <out.mp4>
       record-stitch.sh clip [--no-overlay] [--anim] <TID>
       record-stitch.sh video [--no-overlay] [--anim] [--order time|given] [--out FILE] <TID>...
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
    body+="#ovts $tid $ts"$'\n'
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

# _rs_fast_tps — RECORD_ANIM_FAST_TPS when it is a non-negative integer, else
# the default with one note on stderr.
_rs_fast_tps() {
  local v="${RECORD_ANIM_FAST_TPS:-}"
  if [ -z "$v" ]; then
    printf '%s\n' "$_RS_FAST_TPS_DEFAULT"
  elif [[ "$v" =~ ^[0-9]{1,9}$ ]]; then
    printf '%s\n' "$((10#$v))"
  else
    _rs_err "RECORD_ANIM_FAST_TPS='$v' is not a non-negative integer; using $_RS_FAST_TPS_DEFAULT"
    printf '%s\n' "$_RS_FAST_TPS_DEFAULT"
  fi
}

# _rs_overlay_fill <true|false> <TID>... — reads a plan carrying internal
# `#ovts <TID> <ts>` markers (one after every frame's `file` line) on stdin and
# prints it with each marker replaced by its `#overlay` line (design D1–D5),
# or dropped when overlay is off, the ticket has no pipeline log, or the
# frame's ts does not parse. Reads the pipeline logs only.
_rs_overlay_fill() {
  local overlay="$1" plan dir tid log seen=" " tps
  shift
  plan=$(
    cat
    printf x
  )
  plan="${plan%x}"
  if [ "$overlay" != "true" ]; then
    printf '%s' "$plan" | sed '/^#ovts /d'
    return 0
  fi
  tps=$(_rs_fast_tps)
  dir=$(REPOS_ROOT="$(record_field REPOS_ROOT)" ticket_log_dir 2>/dev/null) || dir=""
  {
    if [ -n "$dir" ]; then
      for tid in "$@"; do
        case "$seen" in *" $tid "*) continue ;; esac
        seen+="$tid "
        log="$dir/$tid-pipeline.log"
        if [ -f "$log" ] && [ -r "$log" ]; then
          awk -v t="$tid" '{ print t "\t" $0 }' "$log" 2>/dev/null || true
        fi
      done
    fi
  } | jq -R -s -j --rawfile plan <(printf '%s' "$plan") --argjson tps "$tps" '
    def isots: test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}");
    def epoch: try ((.[0:19] + "Z") | fromdateiso8601) catch null;
    def msg: .f[4:] | join("|");
    # Frame ts (ISO-8601 with optional fraction, or epoch milliseconds) ->
    # {s: whole seconds, ms: milliseconds}, or null.
    def frame_time:
      if test("^[0-9]+$") then (tonumber) as $m | {s: (($m / 1000) | floor), ms: $m}
      elif isots then
        (epoch) as $s
        | if $s == null then null
          else ((capture("^.{19}\\.(?<f>[0-9]+)").f // "0") + "00")[0:3] as $f
            | {s: $s, ms: ($s * 1000 + ($f | tonumber))} end
      else null end;

    [ split("\n")[] | select(length > 0)
      | index("\t") as $i | select($i != null)
      | {tid: .[0:$i], f: (.[$i + 1:] | split("|"))}
      | select(.f[0] | isots)
      | .t = (.f[0] | epoch) | select(.t != null) ] as $rows
    | ($rows | group_by(.tid)
       | map({key: .[0].tid, value: (
           . as $r
           | ([$r[] | select((.f[1] == "META" and .f[2] == "schema") | not)][0].t) as $start
           | ([$r[].t] | max) as $end
           | {start: $start,
              tokens: [ $r[] | select(.f[1] == "META" and .f[2] == "tokens")
                        | (msg | capture("^[^:|/]+:(?<i>[0-9]+)/(?<o>[0-9]+)/(?<c>[0-9]+)(\\|elapsed_ms=[0-9]+)?$")) as $m
                        | select($m != null)
                        | {t, total: (($m.i | tonumber) + ($m.o | tonumber) + ($m.c | tonumber)),
                           out: ($m.o | tonumber)} ],
              iv: (reduce $r[] as $x ({open: {}, iv: []};
                     ($x.f[1] + "|" + ($x.f[2] // "")) as $k
                     | if $x.f[3] == "waiting" and ($x | msg | startswith("Agent launched")) then
                         (if .open[$k] != null then .iv += [[.open[$k], $x.t]] else . end)
                         | .open[$k] = $x.t
                       elif ($x.f[3] == "done" or $x.f[3] == "fail") and .open[$k] != null then
                         .iv += [[.open[$k], $x.t]] | .open |= del(.[$k])
                       else . end)
                   | .iv + [.open[] | [., $end]])}
           | select(.start != null))})
       | from_entries) as $T
    | ([$T[].iv[]]) as $ivs
    | reduce ($plan | split("\n"))[] as $l ({out: [], prev: {}};
        if ($l | startswith("#ovts ")) then
          ($l | split(" ")) as $p
          | $p[1] as $tid
          | ($p[2:] | join(" ") | frame_time) as $ft
          | if $T[$tid] == null or $ft == null then .
            else $T[$tid] as $tk
              | ([$tk.tokens[] | select(.t <= $ft.s)]) as $seen
              | ([$seen[].total] | add // 0) as $total
              | ([$seen[].out] | add // 0) as $tout
              | ([$ivs[] | select(.[0] <= $ft.s and $ft.s < .[1])] | length) as $ag
              | (([$ft.s - $tk.start, 0] | max)) as $el
              | .prev[$tid] as $pv
              | (if $pv == null then false
                 else ($tout - $pv.out) as $d
                   | (($ft.ms - $pv.ms) / 1000) as $dt
                   | if $dt <= 0 then $d > 0 else ($d >= $tps * $dt) end end) as $hot
              | (if $ag == 0 then "idle"
                 elif $ag >= 2 or $hot or ($pv == null and $tps == 0) then "fast"
                 else "normal" end) as $tier
              | .out += ["#overlay \($el) \($total) \($tout) \($ag) \($tier)"]
              | .prev[$tid] = {ms: $ft.ms, out: $tout}
            end
        else .out += [$l] end)
    | .out | join("\n")
  '
}

# record_stitch_plan clip [--no-overlay] <TID>
#                  | video [--no-overlay] [--order time|given] <TID>...
record_stitch_plan() {
  local mode="${1:-}" order="time" overlay=true
  shift || true
  case "$mode" in
  clip | video) ;;
  *)
    _rs_usage
    return 2
    ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
    --no-overlay)
      overlay=false
      shift
      ;;
    --order)
      if [ "$mode" != "video" ] || [ $# -lt 2 ]; then
        _rs_usage
        return 2
      fi
      order="$2"
      shift 2
      ;;
    --*)
      _rs_usage
      return 2
      ;;
    *) break ;;
    esac
  done
  case "$order" in time | given) ;; *)
    _rs_usage
    return 2
    ;;
  esac
  if [ "$mode" = "clip" ] && [ $# -ne 1 ]; then
    _rs_usage
    return 2
  fi
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
  done | _rs_overlay_fill "$overlay" "$@"
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

# _rs_fmt_num <n> — 3 significant figures with K/M/B; below 1000 the integer.
_rs_fmt_num() {
  awk -v n="$1" 'BEGIN {
    if (n < 1000) { printf "%d", n; exit }
    split("K M B", u, " ")
    for (k = 1; k <= 3; k++) {
      v = n / (1000 ^ k)
      if (v >= 99.95) s = sprintf("%.0f", v)
      else if (v >= 9.995) s = sprintf("%.1f", v)
      else s = sprintf("%.2f", v)
      if (s + 0 < 1000 || k == 3) { printf "%s%s", s, u[k]; exit }
    }
  }'
}

# _rs_fmt_time <seconds> — HH:MM:SS, hours allowed past 99.
_rs_fmt_time() {
  awk -v s="$1" 'BEGIN { printf "%02d:%02d:%02d", int(s / 3600), int(s % 3600 / 60), s % 60 }'
}

# _rs_overlay_text <png> <elapsed_s> <tokens_total> <tokens_out> <agents>
# Draws the three overlay lines (design D6) onto a normalised frame in place.
# Values reach drawtext through textfile= in the PNG's own directory, never
# inside the filter string. Returns 1, the frame untouched, when drawtext fails.
_rs_overlay_text() {
  local png="$1" dir base
  dir=$(dirname -- "$png")
  base=$(basename -- "$png")
  (
    cd "$dir" || exit 1
    printf 'tokens %s  out %s' "$(_rs_fmt_num "$3")" "$(_rs_fmt_num "$4")" >"$base.ov1.txt"
    _rs_fmt_time "$2" >"$base.ov2.txt"
    printf 'agents %s' "$5" >"$base.ov3.txt"
    local box="fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=6:x=w-text_w-24"
    _rs_ffmpeg -i "$base" \
      -vf "drawtext=textfile=$base.ov1.txt:fontsize=30:$box:y=20,drawtext=textfile=$base.ov2.txt:fontsize=26:$box:y=58,drawtext=textfile=$base.ov3.txt:fontsize=26:$box:y=92,format=rgb24" \
      -frames:v 1 "ov-$base" >/dev/null 2>&1 && [ -s "ov-$base" ] &&
      mv -f -- "ov-$base" "$base" && exit 0
    rm -f -- "ov-$base"
    exit 1
  )
}

_RS_SPRITES="coder-work-01 coder-work-02 coder-work-03 coder-work-04 coder-work-05 coder-work-06 coder-work-07 coder-work-08 coder-idle-01 coder-idle-02 coder-idle-03 coder-idle-04"

# _rs_anim_segment <still png> <frames> <tier> <out.mp4> — one segment: the
# still for <frames> frames at 25 fps with the coder loop at the bottom left,
# at the tier's rate (design D7, D8).
_rs_anim_segment() {
  local still="$1" frames="$2" tier="$3" seg="$4" kind=work fps=8
  case "$tier" in
  idle)
    kind=idle
    fps=3
    ;;
  fast) fps=16 ;;
  esac
  _rs_ffmpeg -loop 1 -framerate 25 -i "$still" \
    -loop 1 -framerate "$fps" -i "$_RS_ASSET_DIR/coder-$kind-%02d.png" \
    -filter_complex "[1:v]fps=25[s];[0:v][s]overlay=24:H-h-24,format=yuv420p" \
    -frames:v "$frames" -r 25 -c:v libx264 -an -f mp4 "$seg" >/dev/null 2>&1 && [ -s "$seg" ]
}

# record_stitch_render [--anim] <plan file | -> <out.mp4>
record_stitch_render() {
  local anim=false
  if [ "${1:-}" = "--anim" ]; then
    anim=true
    shift
  fi
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
  local bad_ov
  bad_ov=$(grep '^#overlay' <<<"$plan" |
    grep -vE '^#overlay [0-9]{1,15} [0-9]{1,15} [0-9]{1,15} [0-9]{1,6} (idle|normal|fast)$' || true)
  if [ -n "$bad_ov" ]; then
    _rs_err "bad overlay line in the plan; nothing rendered"
    return 3
  fi
  if [ "$anim" = "true" ]; then
    local sprite
    for sprite in $_RS_SPRITES; do
      if [ ! -f "$_RS_ASSET_DIR/$sprite.png" ]; then
        _rs_err "sprite missing: $_RS_ASSET_DIR/$sprite.png; no video written"
        return 3
      fi
    done
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
  # the last entry's duration otherwise). How long that second naming lasts
  # differs between ffmpeg versions, so the encode is cut at the sum of the
  # plan's durations (-t).
  local line path last="" n=0 secs tid title card list="$tmp/list.ffconcat"
  local _RS_DEADLINE=$((SECONDS + ${RECORD_STITCH_TIMEOUT:-300}))
  # One entry per card or frame, for the overlay and the --anim path.
  local seg_png=() seg_dur=() seg_tier=() seg_kind=() seg_ov=() k dt_off=false
  local ov_el ov_tot ov_out ov_ag ov_tier
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
      seg_png+=("$card")
      seg_dur+=("$secs")
      seg_tier+=(idle)
      seg_kind+=(card)
      seg_ov+=(false)
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
      seg_png+=("$card")
      seg_dur+=("")
      seg_tier+=(idle)
      seg_kind+=(frame)
      seg_ov+=(false)
      ;;
    "#overlay "*)
      k=$((${#seg_png[@]} - 1))
      if [ "$k" -lt 0 ] || [ "${seg_kind[$k]}" != "frame" ] || [ "${seg_ov[$k]}" = "true" ]; then
        _rs_err "overlay line without a frame before it; nothing rendered"
        rc=3
        break
      fi
      read -r _ ov_el ov_tot ov_out ov_ag ov_tier <<<"$line"
      seg_ov[k]=true
      seg_tier[k]="$ov_tier"
      if [ "$dt_off" = "false" ] && ! _rs_overlay_text "${seg_png[$k]}" "$ov_el" "$ov_tot" "$ov_out" "$ov_ag"; then
        _rs_err "drawtext unavailable; overlay skipped"
        dt_off=true
      fi
      ;;
    "duration "*)
      if ! [[ "${line#duration }" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        _rs_err "bad duration line in the plan"
        rc=3
        break
      fi
      printf '%s\n' "$line" >>"$list"
      k=$((${#seg_png[@]} - 1))
      [ "$k" -ge 0 ] && seg_dur[k]="${line#duration }"
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
    local part="$tmp/out.mp4" total
    total=$(awk '$1 == "duration" { t += $2 } END { printf "%.3f", t }' "$list")
    if [ "$anim" = "true" ]; then
      # One segment per card or frame. Frame counts come from the running
      # sum, so the total stays the sum of the plan's durations.
      local cum=0 nf segs="$tmp/segs.ffconcat"
      echo "ffconcat version 1.0" >"$segs"
      for k in "${!seg_png[@]}"; do
        [ -n "${seg_dur[$k]}" ] || continue
        read -r nf cum < <(awk -v c="$cum" -v d="${seg_dur[$k]}" \
          'BEGIN { e = c + d; printf "%d %s\n", int(e * 25 + 0.5) - int(c * 25 + 0.5), e }')
        [ "$nf" -ge 1 ] || continue
        if ! _rs_anim_segment "${seg_png[$k]}" "$nf" "${seg_tier[$k]}" "$tmp/seg-$k.mp4"; then
          rc=5
          break
        fi
        printf "file '%s'\n" "$tmp/seg-$k.mp4" >>"$segs"
      done
      [ "$rc" -eq 0 ] && { _rs_ffmpeg -f concat -safe 0 -i "$segs" -c copy \
        -movflags +faststart -f mp4 "$part" >"$tmp/ffmpeg.log" 2>&1 || rc=5; }
    else
      _rs_ffmpeg -f concat -safe 0 -i "$list" \
        -vf "fps=25,format=yuv420p" -t "$total" \
        -c:v libx264 -an -movflags +faststart -f mp4 "$part" >"$tmp/ffmpeg.log" 2>&1 || rc=5
    fi
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

# record_stitch_clip [--no-overlay] [--anim] <TID>
record_stitch_clip() {
  local popts=() ropts=()
  while [ $# -gt 0 ]; do
    case "$1" in
    --no-overlay) popts+=(--no-overlay) ;;
    --anim) ropts+=(--anim) ;;
    *) break ;;
    esac
    shift
  done
  if [ $# -ne 1 ]; then
    _rs_usage
    return 2
  fi
  _rs_check_ids "$1" || return 2
  local tid="$1" plan tdir out rc=0
  plan=$(record_stitch_plan clip "${popts[@]}" "$tid") || return $?
  tdir=$(_rs_ticket_dir "$tid")
  if [ -z "$tdir" ] || ! grep -q '^file ' <<<"$plan"; then
    _rs_err "nothing to render for $tid"
    return 3
  fi
  out="$tdir/artifacts/recordings/$tid-verify.mp4"
  record_stitch_render "${ropts[@]}" - "$out" <<<"$plan" || rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out"
  return "$rc"
}

# record_stitch_video [--no-overlay] [--anim] [--order time|given] [--out FILE] <TID>...
record_stitch_video() {
  local order="time" out="" tids=() popts=() ropts=()
  while [ $# -gt 0 ]; do
    case "$1" in
    --no-overlay)
      popts+=(--no-overlay)
      shift
      ;;
    --anim)
      ropts+=(--anim)
      shift
      ;;
    --order | --out)
      if [ $# -lt 2 ]; then
        _rs_usage
        return 2
      fi
      if [ "$1" = "--order" ]; then order="$2"; else out="$2"; fi
      shift 2
      ;;
    --*)
      _rs_usage
      return 2
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
  plan=$(record_stitch_plan video "${popts[@]}" --order "$order" "${tids[@]}") || return $?
  record_stitch_render "${ropts[@]}" - "$out" <<<"$plan" || rc=$?
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
