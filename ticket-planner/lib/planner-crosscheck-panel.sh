#!/usr/bin/env bash
# planner-crosscheck-panel.sh — the Crosscheck panel family
# (planner-persona-panel, design D6).
#
# Consensus settles the review panel's findings under its own heading in
# consensus.md:
#
#   ## Panel
#   Panel product-owner (PO): ran — 2 finding(s), see panel/review-product-owner.md
#   Panel security (SEC): NOT RUN — no-result. Its findings are unknown, not zero.
#   ### PO-1 — blocker — <title> — accepted
#   ### QA-1 — major — <title> — rejected (… spec <slug>)
#   Minor/nit QA-2, QA-3: deferred
#   ### Conflicts
#
# This family checks that bookkeeping against the latest panel run in the
# state log (planner_panel_results):
#
#   PANEL_UNADDRESSED (PLANNER_CROSSCHECK_WARN_CODES) — at most one per run:
#   each blocker or major finding id with no `### <ID> … — <disposition>`
#   heading in the section, and each seat with no `Panel <seat> (` status line.
#
#   PANEL_STOP_SKIPPED (blocking) — at most one per run: each blocker of the
#   security or product-owner seat that Consensus settled on its own. Such a
#   blocker passes only when its disposition is `accepted` (read from the last
#   part of its heading; several headings must all say so), or when
#   proposal.md's `## Parameters` table carries a `panel.<ID>` row that bash
#   can verify (planner_panel_stop_rows): open and about to be asked, or
#   answered by a person, as the answers file of that round shows, with
#   anything but `uphold`. A row Consensus closed on its own counts as no row.
#   An upheld objection that is still not `accepted` is listed too. Release
#   with the existing
#   `resume <INIT> --accept PANEL_STOP_SKIPPED:"reason"`.
#
# Silent when the panel did not run for this initiative (no seat line: flag
# off, personas not available, a legacy initiative). Findings of every other
# seat never block: the family judges Consensus's bookkeeping there.
#
# Usage:
#   planner_crosscheck_panel <initiative_id>
#     stdout: `planner-crosscheck-panel: <CODE> <message>` per finding, or
#     nothing. Always returns 0.
#
# Sourceable library — no set -euo pipefail.

# Units judged (planner-halt-recall): planner_crosscheck_units_add is a no-op
# unless planner_crosscheck_run set PLANNER_CROSSCHECK_UNITS_FILE.
if ! declare -f planner_crosscheck_units_add >/dev/null 2>&1; then
  # shellcheck source=planner-crosscheck-units.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/planner-crosscheck-units.sh"
fi

_PLANNER_CROSSCHECK_PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f planner_panel_results >/dev/null 2>&1 ||
  source "${_PLANNER_CROSSCHECK_PANEL_DIR}/planner-panel.sh"

_PLANNER_XCP_PREFIX="planner-crosscheck-panel:"

planner_crosscheck_panel() {
  local init="$1" dir res disp rows seat prefix status n bm bl reason id state
  local missing="" nostatus="" skipped="" parts=""
  planner_panel_ran "$init" || return 0
  dir=$(planner_initiative_dir "$init" 2>/dev/null) || return 0
  res=$(planner_panel_results "$init")
  disp=$(planner_panel_dispositions "${dir}/artifacts/consensus.md")
  rows=$(planner_panel_stop_rows "$init")

  while IFS=$'\t' read -r seat prefix status n bm bl reason; do
    [ -n "$seat" ] || continue
    grep -qxF "status ${seat}" <<<"$disp" || nostatus="${nostatus:+${nostatus}, }${seat}"
    [ "$status" = "done" ] || continue
    planner_crosscheck_units_add panel
    if [ "$bm" != "-" ]; then
      for id in ${bm//,/ }; do
        grep -qE "^disp ${id} " <<<"$disp" || missing="${missing:+${missing}, }${id}"
      done
    fi
    case " ${PLANNER_PANEL_STOP_PREFIXES} " in *" ${prefix} "*) ;; *) continue ;; esac
    [ "$bl" != "-" ] || continue
    for id in ${bl//,/ }; do
      grep -qxF "disp ${id} accepted" <<<"$disp" && continue
      state=$(awk -F'\t' -v id="$id" '$1 == id { print $2; exit }' <<<"$rows")
      case "$state" in
      open | overrule | other) continue ;;
      uphold) skipped="${skipped:+${skipped}, }${id} (upheld by the owner, not accepted)" ;;
      *) skipped="${skipped:+${skipped}, }${id}" ;;
      esac
    done
  done <<<"$res"

  if [ -n "$skipped" ]; then
    printf '%s PANEL_STOP_SKIPPED consensus.md ## Panel: %s\n' \
      "$_PLANNER_XCP_PREFIX" "$(printf '%s' "$skipped" | tr -d '|\r\n')"
  fi
  [ -n "$missing" ] && parts="no disposition for ${missing}"
  [ -n "$nostatus" ] && parts="${parts:+${parts}; }status line missing for ${nostatus}"
  if [ -n "$parts" ]; then
    printf '%s PANEL_UNADDRESSED consensus.md ## Panel: %s\n' \
      "$_PLANNER_XCP_PREFIX" "$(printf '%s' "$parts" | tr -d '|\r\n')"
  fi
  return 0
}
