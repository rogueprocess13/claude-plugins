#!/usr/bin/env bash
# test-plan-binding.sh — unit tests for lib/plan-binding.sh: a person's
# approval is bound to the plan they approved (hashing, checkbox
# normalization, the append-only check, legacy approvals, what clears it).
# Usage: bash test-plan-binding.sh
set -eo pipefail

# The fixtures record a person's approval in-process; the writer refuses
# that in an agent or fleetd-worker session.
unset CLAUDE_CODE_SESSION_ID FLEET_WORKER_PID FLEET_GENERATION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export CLAUDE_SKILLS_LIB="$LIB_DIR"

PASS=0
FAIL=0
_check() {
  if "$@"; then
    echo "PASS: $1"
    ((PASS++)) || true
  else
    echo "FAIL: $1"
    ((FAIL++)) || true
  fi
}

TID="PB-1"
ROOT=""
CHANGE=""
SIMPLE=""

# _fresh <simple-fix|openspec> — a tickets root (cwd) with one plan and a
# manifest holding a person's approval bound to it.
_fresh() {
  [ -z "$ROOT" ] || rm -rf "$ROOT"
  ROOT=$(mktemp -d)
  cd "$ROOT"
  export REPOS_ROOT="$ROOT/repos"
  mkdir -p repos "$TID--plan"
  SIMPLE="$ROOT/$TID--plan/simple-fix.md"
  CHANGE="$ROOT/openspec/changes/pb-1-change"
  if [ "$1" = "simple-fix" ]; then
    printf '# Fix\n- [ ] one\n- [x] two\n' >"$SIMPLE"
  else
    mkdir -p "$CHANGE/specs/cap"
    printf '# Proposal\n' >"$CHANGE/proposal.md"
    printf '# Design\nline\n' >"$CHANGE/design.md"
    printf '## 1. Tasks\n- [ ] 1.1 first\n  - [ ] 1.2 nested\n1. [ ] numbered\n' >"$CHANGE/tasks.md"
    printf '## Requirement\n' >"$CHANGE/specs/cap/spec.md"
    printf 'schema: spec-driven\n' >"$CHANGE/.openspec.yaml"
  fi
  ensure_ticket_manifest "$TID" >/dev/null
  set_ticket_approval "$TID" true human >/dev/null
  set_ticket_approved_plan "$TID" "$(plan_binding_compute "$TID")" >/dev/null
}

# _fresh_rebind — a person approves the plan as it stands now.
_fresh_rebind() {
  set_ticket_approval "$TID" true human >/dev/null
  set_ticket_approved_plan "$TID" "$(plan_binding_compute "$TID")" >/dev/null
}

source "$LIB_DIR/manifest-write.sh"
source "$LIB_DIR/plan-binding.sh"

# _is <status> — runs the check in this shell (PB_DETAIL kept for the test).
_is() {
  plan_binding_check "$TID" --log-file "$ROOT/log" >/dev/null 2>&1 || true
  [ "$PB_STATUS" = "$1" ]
}

test_simple_fix_record() {
  _fresh simple-fix
  local rec
  rec=$(plan_binding_compute "$TID")
  [ "$(jq -r '.type' <<<"$rec")" = "simple-fix" ] &&
    [ "$(jq -c '[.files[] | .path]' <<<"$rec")" = '["simple-fix.md"]' ] &&
    [ "$(jq -r '.files[0].size' <<<"$rec")" = "$(wc -c <"$SIMPLE" | tr -d ' ')" ] &&
    [[ "$(jq -r '.id' <<<"$rec")" =~ ^[0-9a-f]{64}$ ]] &&
    [ "$(jq -r '.normalization' <<<"$rec")" = "task-checkbox-v1" ] &&
    _is match
}

test_openspec_record_lists_every_file_sorted() {
  _fresh openspec
  local rec
  rec=$(plan_binding_compute "$TID")
  [ "$(jq -r '.type' <<<"$rec")" = "openspec" ] &&
    [ "$(jq -c '[.files[] | .path]' <<<"$rec")" = '[".openspec.yaml","design.md","proposal.md","specs/cap/spec.md","tasks.md"]' ] &&
    _is match
}

# The id is a function of the content: same plan, same id; one byte, another.
test_id_is_deterministic() {
  _fresh openspec
  local a b c
  a=$(plan_binding_compute "$TID" | jq -r .id)
  b=$(plan_binding_compute "$TID" | jq -r .id)
  printf '# Design\nlinf\n' >"$CHANGE/design.md"
  c=$(plan_binding_compute "$TID" | jq -r .id)
  [ "$a" = "$b" ] && [ "$a" != "$c" ]
}

test_ticking_checkboxes_still_matches() {
  _fresh openspec
  sed -i 's/- \[ \] 1.1/- [x] 1.1/; s/- \[ \] 1.2/- [X] 1.2/; s/1\. \[ \] numbered/1. [x] numbered/' "$CHANGE/tasks.md"
  grep -q '\[x\] 1.1' "$CHANGE/tasks.md" && _is match &&
    _fresh simple-fix && sed -i 's/- \[x\] two/- [ ] two/' "$SIMPLE" && _is match
}

# A checkbox that is not a list item's is content, not progress.
test_bracket_x_outside_a_list_item_is_content() {
  _fresh simple-fix
  printf '# Fix\n- [ ] one\n- [x] two\n' >"$SIMPLE"
  sed -i 's/# Fix/# [x]x/' "$SIMPLE"
  _is changed
}

test_append_passes_and_logs_once() {
  _fresh openspec
  printf '\n## Amendment #1\nanswer\n' >>"$CHANGE/tasks.md"
  _is appended && _is appended &&
    [ "$(grep -c '|META|plan-binding|info|appended to approved plan [0-9a-f]\{12\}: tasks.md:+' "$ROOT/log")" = "1" ] &&
    plan_binding_check "$TID" && ! plan_binding_matches_exactly "$TID"
}

# Only gate-reconcile's shape is accepted after the approved bytes: an
# `## Amendment #<N>` section. The accepted headings are logged.
test_amendment_headings_logged() {
  _fresh simple-fix
  printf '\n\n## Amendment #1\nanswer\n\n## Amendment #2\nmore\n' >>"$SIMPLE"
  _is appended && [[ "$PB_APPENDED" == "simple-fix.md:+"*" (## Amendment #1, ## Amendment #2)" ]] &&
    grep -q '|META|plan-binding|info|appended to approved plan [0-9a-f]\{12\}: simple-fix.md:+[0-9]* (## Amendment #1, ## Amendment #2)$' "$ROOT/log"
}

test_appended_task_line_fails() {
  _fresh simple-fix
  printf -- '- [ ] also delete the audit table\n' >>"$SIMPLE"
  _is changed && [[ "$PB_DETAIL" == *"simple-fix.md (appended text that is not an ## Amendment section)"* ]]
}

test_appended_other_heading_fails() {
  local h
  for h in '## Notes' '### Amendment #1' '## Amendment' '## Amendment #x' '# Amendment #1'; do
    _fresh openspec
    printf '\n%s\ntext\n' "$h" >>"$CHANGE/tasks.md"
    _is changed && [[ "$PB_DETAIL" == *"tasks.md (appended text that is not an ## Amendment section)"* ]] || {
      echo "  heading '$h' was accepted"
      return 1
    }
  done
}

# Appended text that runs on the last approved line is not a new section.
test_amendment_must_start_a_line() {
  _fresh simple-fix
  printf '# Fix' >"$SIMPLE"
  _fresh_rebind
  printf ' and more\n## Amendment #1\n' >>"$SIMPLE"
  _is changed
}

# An amendment holding a control character is not plain text.
test_amendment_with_control_character_fails() {
  _fresh simple-fix
  printf '\n## Amendment #1\nhidden \033[2J text\n' >>"$SIMPLE"
  _is changed
}

# The pipeline log is agent-written: a forged artifact record pointing at an
# unchanged copy of the plan never stands in for the ticket's own plan.
test_forged_log_record_pointing_at_a_copy_fails() {
  _fresh openspec
  cp -r "$CHANGE" "$ROOT/copy-of-change"
  printf '# Design\nrewritten\n' >"$CHANGE/design.md"
  printf '2026-01-01T00:00:00Z|META|artifact|info|plan:%s\n' "$ROOT/copy-of-change/tasks.md" >>"$ROOT/log"
  _is changed && [[ "$PB_DETAIL" == *"the pipeline log names another plan"*"copy-of-change"* ]] &&
    _fresh simple-fix && cp "$SIMPLE" "$ROOT/simple-fix.md" && printf 'rewritten\n' >"$SIMPLE" &&
    printf '2026-01-01T00:00:00Z|META|artifact|info|plan:%s\n' "$ROOT/simple-fix.md" >>"$ROOT/log" &&
    _is changed && [[ "$PB_DETAIL" == *"the pipeline log names another plan"* ]]
}

# A forged record naming a symlinked simple-fix.md (pointing at an unchanged
# copy) is a mismatch too, never "no record".
test_forged_log_record_to_symlinked_plan_fails() {
  _fresh simple-fix
  mkdir -p "$ROOT/forged"
  cp "$SIMPLE" "$ROOT/copy.md"
  ln -s "$ROOT/copy.md" "$ROOT/forged/simple-fix.md"
  printf 'rewritten\n' >"$SIMPLE"
  printf '2026-01-01T00:00:00Z|META|artifact|info|plan:%s\n' "$ROOT/forged/simple-fix.md" >>"$ROOT/log"
  _is changed && [[ "$PB_DETAIL" == *"the pipeline log names another plan"*"forged/simple-fix.md"* ]] || return 1
  # The ticket's own plan replaced by a symlink to the copy: not a regular file.
  _fresh simple-fix
  cp "$SIMPLE" "$ROOT/copy.md"
  rm "$SIMPLE"
  ln -s "$ROOT/copy.md" "$SIMPLE"
  printf '2026-01-01T00:00:00Z|META|artifact|info|plan:%s\n' "$SIMPLE" >>"$ROOT/log"
  _is changed && [[ "$PB_DETAIL" == *"simple-fix.md (replaced: not a regular file)"* ]]
}

# A symlinked plan is refused at approval (rc 3), with or without a log.
test_symlinked_plan_refused_at_approval() {
  _fresh simple-fix
  cp "$SIMPLE" "$ROOT/copy.md"
  rm "$SIMPLE"
  ln -s "$ROOT/copy.md" "$SIMPLE"
  local rc=0 rc2=0
  plan_binding_compute "$TID" >/dev/null || rc=$?
  printf '2026-01-01T00:00:00Z|META|artifact|info|plan:%s\n' "$SIMPLE" >"$ROOT/log"
  plan_binding_compute "$TID" --log-file "$ROOT/log" >/dev/null || rc2=$?
  [ "$rc" -eq 3 ] && [ "$rc2" -eq 3 ]
}

# A log record naming the ticket's own plan is fine.
test_log_record_naming_the_own_plan_passes() {
  _fresh openspec
  printf '2026-01-01T00:00:00Z|META|artifact|info|plan:%s\n' "$CHANGE/tasks.md" >>"$ROOT/log"
  _is match
}

# The plan is bound to its location: a copy elsewhere is another plan.
test_moved_plan_fails() {
  _fresh openspec
  mv "$CHANGE" "$ROOT/openspec/changes/pb-1-renamed"
  _is changed && [[ "$PB_DETAIL" == *"the plan moved: approved "*"pb-1-change, now "*"pb-1-renamed"* ]]
}

# The approval script refuses a plan whose log record disagrees (rc 4).
test_compute_refuses_a_disagreeing_log_record() {
  _fresh simple-fix
  printf 'x\n' >"$ROOT/other.md"
  mv "$ROOT/other.md" "$ROOT/simple-fix.md"
  printf '2026-01-01T00:00:00Z|META|artifact|info|plan:%s\n' "$ROOT/simple-fix.md" >"$ROOT/log"
  local rc=0
  plan_binding_compute "$TID" --log-file "$ROOT/log" >/dev/null || rc=$?
  [ "$rc" -eq 4 ]
}

test_edit_fails_naming_the_file() {
  _fresh openspec
  printf '# Design\nchanged\n' >"$CHANGE/design.md"
  _is changed && [[ "$PB_DETAIL" == *"design.md (edited)"* ]] &&
    [[ "$(plan_binding_hold_message "$TID")" == "PLAN_CHANGED_SINCE_APPROVAL — the plan changed after a person approved it: design.md (edited). Read the plan, then a person runs, in their own terminal from the tickets root: bash ~/.claude/skills/ticket-approve/approve.sh $TID" ]]
}

# An edit that only adds bytes in the middle is an edit, not an append.
test_insert_in_the_middle_fails() {
  _fresh simple-fix
  printf '# Fix\nNEW\n- [ ] one\n- [x] two\n' >"$SIMPLE"
  _is changed && [[ "$PB_DETAIL" == *"simple-fix.md (edited)"* ]]
}

test_truncation_fails() {
  _fresh simple-fix
  printf '# Fix\n- [ ] one\n' >"$SIMPLE"
  _is changed && [[ "$PB_DETAIL" == *"simple-fix.md (shortened)"* ]]
}

test_removed_file_fails() {
  _fresh openspec
  rm "$CHANGE/specs/cap/spec.md"
  _is changed && [[ "$PB_DETAIL" == *"specs/cap/spec.md (removed)"* ]]
}

test_new_file_fails() {
  _fresh openspec
  printf 'more\n' >"$CHANGE/specs/cap/extra.md"
  _is changed && [[ "$PB_DETAIL" == *"specs/cap/extra.md (new file, not approved)"* ]]
}

test_replaced_by_symlink_fails() {
  _fresh openspec
  cp "$CHANGE/design.md" "$ROOT/elsewhere.md"
  rm "$CHANGE/design.md"
  ln -s "$ROOT/elsewhere.md" "$CHANGE/design.md"
  _is changed && [[ "$PB_DETAIL" == *"design.md (replaced: not a regular file)"* ]]
}

test_plan_type_change_fails() {
  _fresh openspec
  printf '# Fix\n' >"$ROOT/$TID--plan/simple-fix.md"
  _is changed && [[ "$PB_DETAIL" == *"approved openspec, now simple-fix"* ]]
}

test_missing_plan_fails() {
  _fresh simple-fix
  rm "$SIMPLE"
  _is changed && [[ "$PB_DETAIL" == *"no longer found"* ]]
}

test_legacy_unbound_approval_fails() {
  _fresh simple-fix
  local m
  m=$(get_ticket_manifest_path "$TID")
  jq 'del(.approved_plan)' "$m" >"$m.t" && mv "$m.t" "$m"
  _is unbound && [[ "$PB_DETAIL" == *"predates plan binding"* ]] &&
    ! plan_binding_check "$TID" >/dev/null
}

test_malformed_record_fails() {
  _fresh simple-fix
  local m
  m=$(get_ticket_manifest_path "$TID")
  jq '.approved_plan.files[0].sha256 = "nope"' "$m" >"$m.t" && mv "$m.t" "$m"
  _is changed && [[ "$PB_DETAIL" == *"malformed"* ]]
}

# A recorded path that leaves the plan dir is never followed.
test_recorded_path_outside_plan_fails() {
  _fresh simple-fix
  local m
  m=$(get_ticket_manifest_path "$TID")
  jq '.approved_plan.files[0].path = "../x.md"' "$m" >"$m.t" && mv "$m.t" "$m"
  _is changed && [[ "$PB_DETAIL" == *"not a path inside the plan"* ]]
}

# Every new approval, and every clear, drops the binding: a policy
# approval is never bound, and re-claim / reject / implement-complete /
# cancel (set_ticket_approval false) leave nothing behind.
test_approval_writes_drop_the_binding() {
  _fresh simple-fix
  local m
  m=$(get_ticket_manifest_path "$TID")
  set_ticket_approval "$TID" true policy >/dev/null
  jq -e 'has("approved_plan") | not' "$m" >/dev/null || return 1
  set_ticket_approval "$TID" true human >/dev/null
  set_ticket_approved_plan "$TID" "$(plan_binding_compute "$TID")" >/dev/null
  jq -e '.approved_plan.id | length == 64' "$m" >/dev/null || return 1
  set_ticket_approval "$TID" false >/dev/null
  jq -e 'has("approved_plan") or has("approved") | not' "$m" >/dev/null
}

# A policy approval is never checked, wherever it is read: the implement
# guard lets a simple auto ticket's own approval through over a rewritten plan.
test_policy_approval_unaffected() {
  _fresh simple-fix
  set_ticket_approval "$TID" true policy >/dev/null
  set_ticket_stage "$TID" Ready >/dev/null
  printf '## Complexity\n**Score:** simple\n' >"$ROOT/$TID--plan/notes.md"
  printf '2026-01-01T00:00:00Z|META|autonomy|info|auto\n' >"$ROOT/log"
  printf 'rewritten\n' >"$SIMPLE"
  local out
  out=$(TAP_LOG="$ROOT/log" bash "$LIB_DIR/gate-check.sh" "$TID" - - --mode implement 2>/dev/null) &&
    [ "$out" = "IMPLEMENT_AUTH=approved" ]
}

# The CLI prints the verdict and the detail, exit 0 only on match/appended.
test_cli_check() {
  _fresh simple-fix
  local out rc=0
  out=$(bash "$LIB_DIR/plan-binding.sh" check "$TID") || rc=$?
  [ "$rc" -eq 0 ] && grep -qx 'PLAN_BINDING=match' <<<"$out" || return 1
  printf 'x\n' >"$SIMPLE"
  rc=0
  out=$(bash "$LIB_DIR/plan-binding.sh" check "$TID") || rc=$?
  [ "$rc" -eq 1 ] && grep -qx 'PLAN_BINDING=changed' <<<"$out" &&
    grep -q '^PLAN_BINDING_DETAIL=the plan changed after a person approved it: simple-fix.md' <<<"$out"
}

test_display_name_never_passes_control_characters() {
  [ "$(plan_binding_display_name 'tasks.md')" = "tasks.md" ] &&
    [ "$(plan_binding_display_name $'a\033[2Jb.md')" = "(a file whose name is not plain text)" ] &&
    [ "$(plan_binding_display_name 'a|b.md')" = "(a file whose name is not plain text)" ] &&
    [ "$(plan_binding_display_name $'a\tb')" = "(a file whose name is not plain text)" ]
}

for fn in \
  test_simple_fix_record \
  test_openspec_record_lists_every_file_sorted \
  test_id_is_deterministic \
  test_ticking_checkboxes_still_matches \
  test_bracket_x_outside_a_list_item_is_content \
  test_append_passes_and_logs_once \
  test_amendment_headings_logged \
  test_appended_task_line_fails \
  test_appended_other_heading_fails \
  test_amendment_must_start_a_line \
  test_amendment_with_control_character_fails \
  test_forged_log_record_pointing_at_a_copy_fails \
  test_forged_log_record_to_symlinked_plan_fails \
  test_symlinked_plan_refused_at_approval \
  test_log_record_naming_the_own_plan_passes \
  test_moved_plan_fails \
  test_compute_refuses_a_disagreeing_log_record \
  test_edit_fails_naming_the_file \
  test_insert_in_the_middle_fails \
  test_truncation_fails \
  test_removed_file_fails \
  test_new_file_fails \
  test_replaced_by_symlink_fails \
  test_plan_type_change_fails \
  test_missing_plan_fails \
  test_legacy_unbound_approval_fails \
  test_malformed_record_fails \
  test_recorded_path_outside_plan_fails \
  test_approval_writes_drop_the_binding \
  test_policy_approval_unaffected \
  test_cli_check \
  test_display_name_never_passes_control_characters; do
  _check "$fn"
done

cd /
[ -z "$ROOT" ] || rm -rf "$ROOT"
echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
