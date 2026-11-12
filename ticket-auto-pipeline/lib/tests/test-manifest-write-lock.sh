#!/usr/bin/env bash
# test-manifest-write-lock.sh — every whole-file manifest writer in
# lib/manifest-write.sh serialises on one per-manifest lock (review ARCH-4).
#
# Before the fix only the readiness writers took a lock: set_ticket_transition
# read `rev` and rewrote the manifest unlocked, so parallel writers of different
# kinds lost each other's updates (a transition, a readiness verdict, an
# approval). This test runs N parallel writers of several kinds against one
# manifest and checks nothing is lost.
# Usage: bash test-manifest-write-lock.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LIB_DIR/manifest-write.sh"

PASS=0
FAIL=0
_pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_fail() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

WORKERS=8
PER_WORKER=6
TOTAL=$((WORKERS * PER_WORKER))

# ── N parallel writers of different kinds lose nothing ──────────────────────

write_ticket_manifest "LOCK-1" "INIT-L" "feature" '[]'
REVS_DIR="$TMP_ROOT/revs"
mkdir -p "$REVS_DIR"

pids=()
for w in $(seq 1 "$WORKERS"); do
  (
    for i in $(seq 1 "$PER_WORKER"); do
      MANIFEST_TRANSITION_REV=""
      set_ticket_transition "LOCK-1" "Ready" '["reviewed"]' "{\"event\":\"e\",\"data\":{\"w\":$w,\"i\":$i}}" >/dev/null || exit 1
      echo "${MANIFEST_TRANSITION_REV:-none}" >>"$REVS_DIR/w$w"
    done
  ) &
  pids+=($!)
done
# Readiness writer, approval writer, outcome writer, blocked_by writer and
# pending-event clearer, all hammering the same file at the same time.
(for i in $(seq 1 "$PER_WORKER"); do set_ticket_readiness "LOCK-1" "ready" '[]' '["ADV"]' || exit 1; done) &
pids+=($!)
(for i in $(seq 1 "$PER_WORKER"); do set_ticket_approval "LOCK-1" true human || exit 1; done) &
pids+=($!)
(for i in $(seq 1 "$PER_WORKER"); do write_ticket_outcome_label "LOCK-1" Rough || exit 1; done) &
pids+=($!)
(for i in $(seq 1 "$PER_WORKER"); do add_ticket_blocked_by "LOCK-1" "BLK-$i" || exit 1; done) &
pids+=($!)
(for i in $(seq 1 "$PER_WORKER"); do stamp_ticket_dispatch "LOCK-1" || true; done) &
pids+=($!)

writer_fail=0
for p in "${pids[@]}"; do
  wait "$p" || writer_fail=$((writer_fail + 1))
done
[ "$writer_fail" -eq 0 ] && _pass "parallel writers: every writer returned 0" ||
  _fail "parallel writers: $writer_fail writer(s) failed"

m="$TMP_ROOT/.ticket-auto/initiatives/INIT-L/tickets/LOCK-1/planner/manifest.json"
jq -e . "$m" >/dev/null 2>&1 && _pass "parallel writers: manifest is valid JSON" ||
  _fail "parallel writers: manifest is not valid JSON"

rev=$(jq -r '.rev // 0' "$m")
[ "$rev" = "$TOTAL" ] && _pass "parallel writers: rev equals the transition count ($TOTAL)" ||
  _fail "parallel writers: rev should be $TOTAL, got $rev (lost transitions)"

all_revs=$(cat "$REVS_DIR"/w* 2>/dev/null | sort -n)
n_revs=$(echo "$all_revs" | grep -c '^[0-9][0-9]*$' || true)
n_uniq=$(echo "$all_revs" | grep '^[0-9][0-9]*$' | sort -un | wc -l | tr -d ' ')
[ "$n_revs" = "$TOTAL" ] && [ "$n_uniq" = "$TOTAL" ] &&
  _pass "parallel writers: each transition reported a distinct written rev" ||
  _fail "parallel writers: expected $TOTAL distinct reported revs, got $n_revs reported / $n_uniq distinct"
[ "$(echo "$all_revs" | tail -1)" = "$TOTAL" ] && [ "$(echo "$all_revs" | head -1)" = "1" ] &&
  _pass "parallel writers: reported revs are exactly 1..$TOTAL" ||
  _fail "parallel writers: reported revs should span 1..$TOTAL"

[ "$(jq -r '.ready.status // empty' "$m")" = "ready" ] && [ "$(jq -c '.ready.advisory' "$m")" = '["ADV"]' ] &&
  _pass "parallel writers: readiness verdict survives" ||
  _fail "parallel writers: readiness verdict lost ($(jq -c '.ready' "$m"))"
[ "$(jq -r '.approved // empty' "$m")" = "true" ] && [ "$(jq -r '.approval_provenance // empty' "$m")" = "human" ] &&
  _pass "parallel writers: approval survives" ||
  _fail "parallel writers: approval lost"
[ "$(jq -r '.outcome_label // empty' "$m")" = "Rough" ] &&
  _pass "parallel writers: outcome_label survives" ||
  _fail "parallel writers: outcome_label lost"
[ "$(jq -r '.blocked_by | length' "$m")" = "$PER_WORKER" ] &&
  _pass "parallel writers: every blocked_by append survives" ||
  _fail "parallel writers: blocked_by should have $PER_WORKER entries, got $(jq -c '.blocked_by' "$m")"
[ "$(jq -r '.dispatch' "$m")" = "true" ] &&
  _pass "parallel writers: dispatch stamp survives" ||
  _fail "parallel writers: dispatch stamp lost"
[ "$(jq -r '.stage' "$m")" = "Ready" ] && [ "$(jq -c '.flags' "$m")" = '["reviewed"]' ] &&
  _pass "parallel writers: stage/flags survive" ||
  _fail "parallel writers: stage/flags lost"

# ── set_ticket_transition reports the rev it wrote ──────────────────────────

write_ticket_manifest "LOCK-2" "INIT-L" "bug" '[]'
MANIFEST_TRANSITION_REV=""
set_ticket_transition "LOCK-2" "Todo" '[]' ''
[ "$MANIFEST_TRANSITION_REV" = "1" ] && _pass "set_ticket_transition: MANIFEST_TRANSITION_REV is the written rev" ||
  _fail "set_ticket_transition: MANIFEST_TRANSITION_REV should be 1, got '${MANIFEST_TRANSITION_REV}'"
out=$(set_ticket_transition "LOCK-2" "Todo" '[]' '')
[ -z "$out" ] && _pass "set_ticket_transition: prints nothing on stdout (flow.sh's stdout is its JSON result)" ||
  _fail "set_ticket_transition: should print nothing, printed '$out'"

# ── clear_pending_event only clears the pending event of the expected rev ───

write_ticket_manifest "LOCK-3" "INIT-L" "bug" '[]'
set_ticket_transition "LOCK-3" "Todo" '[]' '{"event":"a","data":{}}'
set_ticket_transition "LOCK-3" "Todo" '[]' '{"event":"b","data":{}}'
clear_pending_event "LOCK-3" 1
[ "$(get_ticket_manifest_field LOCK-3 pending_event | jq -r .event)" = "b" ] &&
  _pass "clear_pending_event: a stale expected rev leaves a newer pending_event alone" ||
  _fail "clear_pending_event: should not clear rev 2's pending_event when asked for rev 1"
clear_pending_event "LOCK-3" 2
[ -z "$(get_ticket_manifest_field LOCK-3 pending_event)" ] &&
  _pass "clear_pending_event: the matching expected rev clears it" ||
  _fail "clear_pending_event: should clear with the matching rev"

# ── Lock is re-entrant on the same manifest, refuses a different one ────────

write_ticket_manifest "LOCK-4" "INIT-L" "bug" '[]'
p4=$(get_ticket_manifest_path LOCK-4)
p1=$(get_ticket_manifest_path LOCK-1)
rc=0
(
  _manifest_lock "$p4" || exit 2
  # A writer called while the lock is already held on the same manifest
  # must not deadlock (flock on a new open file description would wait on
  # our own lock) and must not release the outer lock on its way out.
  write_ticket_outcome_label "LOCK-4" Hard || exit 3
  flock -n "${p4}.lock" true 2>/dev/null && exit 4 # outer lock still held?
  _manifest_unlock
  flock -n "${p4}.lock" true 2>/dev/null || exit 5 # released at depth 0
  exit 0
) || rc=$?
[ "$rc" = "0" ] && _pass "lock: re-entrant on the same manifest, released only at depth 0" ||
  _fail "lock: re-entrancy check failed (rc $rc)"
[ "$(get_ticket_manifest_field LOCK-4 outcome_label)" = "Hard" ] &&
  _pass "lock: nested writer's update landed" ||
  _fail "lock: nested writer's update missing"

rc=0
(
  _manifest_lock "$p4" || exit 2
  _manifest_lock "$p1" 2>/dev/null && exit 3
  _manifest_unlock
  exit 0
) || rc=$?
[ "$rc" = "0" ] && _pass "lock: refuses a second manifest while one is held (would steal FD 200)" ||
  _fail "lock: should refuse a different manifest while held (rc $rc)"

# A held lock blocks another process's writer until released.
rc=0
(
  _manifest_lock "$p4" || exit 2
  MANIFEST_LOCK_TIMEOUT_SECS=1 bash -c "source '$LIB_DIR/manifest-write.sh'; write_ticket_outcome_label LOCK-4 Smooth" 2>/dev/null && exit 3
  _manifest_unlock
  exit 0
) || rc=$?
[ "$rc" = "0" ] && [ "$(get_ticket_manifest_field LOCK-4 outcome_label)" = "Hard" ] &&
  _pass "lock: another process's writer waits on (and times out behind) a held lock" ||
  _fail "lock: another process wrote through a held lock (rc $rc)"

# ── A forked subshell does not inherit the parent's hold ────────────────────
# `( writer ) &` copies the depth counter, so without a pid check the child
# skipped flock and wrote while the parent still held the lock.

write_ticket_manifest "LOCK-5" "INIT-L" "bug" '[]'
p5=$(get_ticket_manifest_path LOCK-5)
_manifest_lock "$p5"
(MANIFEST_LOCK_TIMEOUT_SECS=10 write_ticket_outcome_label "LOCK-5" Smooth) &
fork_pid=$!
sleep 1
early=$(jq -r '.outcome_label // "absent"' "$p5")
_manifest_unlock
wait "$fork_pid" || true
[ "$early" = "absent" ] && _pass "lock: a forked writer waits while the parent holds the lock" ||
  _fail "lock: a forked writer wrote through the parent's lock (saw '$early')"
[ "$(jq -r '.outcome_label // "absent"' "$p5")" = "Smooth" ] &&
  _pass "lock: the forked writer lands once the parent releases" ||
  _fail "lock: the forked writer's update is missing"

# ── Re-running creation keeps lifecycle fields ──────────────────────────────
# A planner resume calls write_ticket_manifest/write_epic_manifest again on an
# existing manifest. Replacing the whole file restarted rev at 1, so the next
# `{tid}:1` idem key collided with an event already in the outbox.

write_ticket_manifest "LOCK-6" "INIT-L" "bug" '[]'
set_ticket_transition "LOCK-6" "Todo" '[]' ''
set_ticket_transition "LOCK-6" "Approve" '["needs-info"]' '{"event":"x","data":{}}'
set_ticket_approval "LOCK-6" true human
stamp_ticket_dispatch "LOCK-6"
write_ticket_manifest "LOCK-6" "INIT-L" "feature" '["LOCK-1"]'
m6=$(get_ticket_manifest_path LOCK-6)
jq -e '.rev == 2 and .stage == "Approve" and .flags == ["needs-info"] and .pending_event.event == "x"
       and .approved == true and .dispatch == true' "$m6" >/dev/null &&
  _pass "write_ticket_manifest: re-run keeps rev/stage/flags/pending_event/approved/dispatch" ||
  _fail "write_ticket_manifest: re-run dropped lifecycle fields ($(jq -c . "$m6"))"
jq -e '.type == "feature" and .blocked_by == ["LOCK-1"] and .initiative == "INIT-L"' "$m6" >/dev/null &&
  _pass "write_ticket_manifest: re-run refreshes the creation fields" ||
  _fail "write_ticket_manifest: re-run should refresh type/blocked_by ($(jq -c . "$m6"))"

write_epic_manifest "EPIC-L" "epic/a" "per-ticket" "manual" '["C-1"]'
stamp_epic_dispatch "EPIC-L"
set_epic_transition "EPIC-L" "Review" '[]' ''
write_epic_manifest "EPIC-L" "epic/b" "epic" "manual"
me=$(get_epic_manifest_path EPIC-L)
jq -e '.rev == 1 and .stage == "Review" and .dispatch == true and .children == ["C-1"]
       and .branch == "epic/b" and .uat_policy == "epic"' "$me" >/dev/null &&
  _pass "write_epic_manifest: re-run keeps rev/stage/dispatch/children, refreshes branch/policy" ||
  _fail "write_epic_manifest: re-run lost fields ($(jq -c . "$me"))"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
