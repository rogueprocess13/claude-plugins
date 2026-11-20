#!/usr/bin/env bash
# record-env-check.sh — the Recording rows of ticket-env-check (openspec change
# ticket-auto-record, design D7).
#
# record_env_check_rows <project dir>
#   Prints one `NAME|STATUS|VALUE|LOCATION|NOTE` row per check, STATUS only
#   `ok` or `warn` (recording never fails an environment check). Prints
#   nothing when RECORD_ALLOWED is not set (environment, then the project's
#   CLAUDE.md). Rows:
#     RECORD_ALLOWED          field validity, the uat rule
#     RECORD_BOARD_DRIVERS    recorder after linear in FLEET_BOARD_DRIVERS
#     RECORD_BOARD_URL        https://linear.app/…/project|view/…
#     RECORD_FFMPEG           ffmpeg on PATH (what record-stitch.sh render needs)
#     RECORD_BROWSER          Playwright and Chromium (recorder.sh check)
#     RECORD_SESSION          the saved Linear session still logs in
#     RECORD_SESSION_MODE     session file 0600, its directory 0700
#     RECORD_SESSION_IGNORED  the session file is git-ignored
#   RECORD_BROWSER and RECORD_SESSION start a headless browser once, bounded
#   by a 30 s timeout. The session's contents are never read or printed.
#
# Sourceable: sets no shell options. Always returns 0.

_REC_EC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f record_allowed_parse >/dev/null 2>&1 ||
  source "$_REC_EC_DIR/record.sh"

_rec_ec_field() {
  local dir="$1" name="$2" val
  val="${!name:-}"
  if [ -z "$val" ] && [ -f "$dir/CLAUDE.md" ]; then
    val=$(claude_md_field "$dir/CLAUDE.md" "$name" 2>/dev/null) || val=""
  fi
  printf '%s\n' "$val"
}

_rec_ec_row() {
  # No pipe may reach a cell: the table is pipe-delimited.
  local IFS='|'
  local cells=("${@//|/ }")
  printf '%s\n' "${cells[*]}"
}

record_env_check_rows() {
  local dir="${1:-$PWD}" allowed syn parsed
  allowed=$(_rec_ec_field "$dir" RECORD_ALLOWED)
  [ -n "$allowed" ] || return 0

  syn=$(_rec_ec_field "$dir" RECORD_UAT_SYNTHETIC)
  parsed=$(record_allowed_parse "$allowed" "$syn" 2>/dev/null | tr '\n' ' ')
  if [ -n "$parsed" ]; then
    _rec_ec_row RECORD_ALLOWED ok "${parsed% }" "CLAUDE.md" "synthetic data only"
  else
    _rec_ec_row RECORD_ALLOWED warn "$allowed" "CLAUDE.md" \
      "allows nothing: use local and/or uat (uat needs RECORD_UAT_SYNTHETIC=true); --record is refused"
  fi

  local drivers="${FLEET_BOARD_DRIVERS:-linear}"
  drivers="${drivers//[[:space:]]/}"
  case ",${drivers}," in
  *,linear,*recorder,*)
    _rec_ec_row RECORD_BOARD_DRIVERS ok "$drivers" "settings.local.json" ""
    ;;
  *)
    _rec_ec_row RECORD_BOARD_DRIVERS warn "$drivers" "settings.local.json" \
      "no board frames: set FLEET_BOARD_DRIVERS=linear,recorder (here and in fleetd's environment)"
    ;;
  esac

  local url
  url=$(_rec_ec_field "$dir" RECORD_BOARD_URL)
  if [ -z "$url" ]; then
    _rec_ec_row RECORD_BOARD_URL warn "" "CLAUDE.md" \
      "not set: no board frames. Use a filtered Linear project or view URL"
  elif [[ "$url" =~ ^https://linear\.app/[^[:space:]]*/(project|view)/ ]]; then
    _rec_ec_row RECORD_BOARD_URL ok "present" "CLAUDE.md" ""
  else
    _rec_ec_row RECORD_BOARD_URL warn "present" "CLAUDE.md" \
      "not an https://linear.app URL with /project/ or /view/ in its path: board frames fail bad-board-url"
  fi

  if command -v ffmpeg >/dev/null 2>&1; then
    _rec_ec_row RECORD_FFMPEG ok "$(command -v ffmpeg)" "PATH" ""
  else
    _rec_ec_row RECORD_FFMPEG warn "" "PATH" "ffmpeg not installed: /ticket-record-stitch cannot render"
  fi

  local root word=""
  root=$(_rec_ec_field "$dir" REPOS_ROOT)
  # The lib sync copies lib/*.sh only, so a synced copy of this file has no
  # driver beside it: take the installed plugin's.
  local drv="$_REC_EC_DIR/board-drivers/recorder.sh"
  if [ ! -f "$drv" ]; then
    declare -f tap_cache_find >/dev/null 2>&1 ||
      source "$_REC_EC_DIR/plugin-cache.sh" 2>/dev/null || true
    drv=$(tap_cache_find ticket-auto-pipeline lib/board-drivers/recorder.sh 2>/dev/null || true)
  fi
  if [ -n "$root" ] && [ -d "$root" ] && [ -n "$drv" ] && [ -f "$drv" ]; then
    word=$(cd "$dir" 2>/dev/null && REPOS_ROOT="$root" RECORD_BOARD_URL="$url" \
      timeout -k 2 30 bash "$drv" check </dev/null 2>/dev/null | tail -1) || true
  fi
  local login="run recorder.sh login from the tickets root"
  case "$word" in
  ok)
    _rec_ec_row RECORD_BROWSER ok "playwright + chromium" ".ticket-auto/record" ""
    _rec_ec_row RECORD_SESSION ok "logged in" ".ticket-auto/record" ""
    ;;
  expired)
    _rec_ec_row RECORD_BROWSER ok "playwright + chromium" ".ticket-auto/record" ""
    _rec_ec_row RECORD_SESSION warn "expired" ".ticket-auto/record" "the Linear session lands on the login page: $login"
    ;;
  no-session)
    _rec_ec_row RECORD_BROWSER ok "playwright + chromium" ".ticket-auto/record" ""
    _rec_ec_row RECORD_SESSION warn "" ".ticket-auto/record" "no saved Linear session: $login"
    ;;
  browser-missing)
    _rec_ec_row RECORD_BROWSER warn "" ".ticket-auto/record" \
      "node, Playwright or Chromium missing: in \$REPOS_ROOT/.ticket-auto/record run npm i playwright, then npx playwright install chromium"
    _rec_ec_row RECORD_SESSION warn "" ".ticket-auto/record" "not checked (no browser)"
    ;;
  *)
    _rec_ec_row RECORD_BROWSER warn "" ".ticket-auto/record" "check did not finish (${word:-no answer}); REPOS_ROOT set? network?"
    _rec_ec_row RECORD_SESSION warn "" ".ticket-auto/record" "not checked"
    ;;
  esac

  local rdir="${root:+$root/.ticket-auto/record}"
  local sess="${rdir:+$rdir/linear-session.json}"
  if [ -z "$sess" ] || [ ! -e "$sess" ]; then
    _rec_ec_row RECORD_SESSION_MODE warn "" ".ticket-auto/record" "no session file"
    _rec_ec_row RECORD_SESSION_IGNORED warn "" ".ticket-auto/record" "no session file"
    return 0
  fi
  local fmode dmode
  fmode=$(stat -c %a "$sess" 2>/dev/null) || fmode="?"
  dmode=$(stat -c %a "$rdir" 2>/dev/null) || dmode="?"
  if [ -L "$sess" ] || [ -L "$rdir" ]; then
    _rec_ec_row RECORD_SESSION_MODE warn "symlink" ".ticket-auto/record" "the session file or its directory is a symlink"
  elif [ "$fmode" = 600 ] && [ "$dmode" = 700 ]; then
    _rec_ec_row RECORD_SESSION_MODE ok "file $fmode, dir $dmode" ".ticket-auto/record" ""
  else
    _rec_ec_row RECORD_SESSION_MODE warn "file $fmode, dir $dmode" ".ticket-auto/record" \
      "the session is a full Linear login: chmod 600 the file and 700 its directory"
  fi
  local grc=0
  git -C "$rdir" check-ignore -q -- "$sess" 2>/dev/null || grc=$?
  case "$grc" in
  0) _rec_ec_row RECORD_SESSION_IGNORED ok "git-ignored" ".ticket-auto/record" "" ;;
  1)
    _rec_ec_row RECORD_SESSION_IGNORED warn "not ignored" ".ticket-auto/record" \
      "git would track the session file: add .ticket-auto/record/ to .gitignore"
    ;;
  *) _rec_ec_row RECORD_SESSION_IGNORED ok "not in a git repository" ".ticket-auto/record" "" ;;
  esac
  return 0
}
