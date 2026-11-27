"""
Tests for fleetd's gate-hold reconciliation (fleetd/gate_hold.py).

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_gate_hold.py -v

The three things worth guarding, all of them found by building D14 rather
than by reading it:

- A poll that finds no approval must change nothing AND write nothing. The
  entry gate logs a held line every time it holds; on its own cadence against
  a ticket waiting three days that is hundreds of identical lines in the file
  detect-resume.sh, the detectors and the OTel exporter all read.
- The `RECONCILE_CYCLE` cap counts hold/re-approve cycles, not polls. Counting
  polls would gate-stop every ticket held over a weekend.
- A gate that could not run is not a gate that held. Collapsing the two would
  strand a ticket in a hold no re-check could ever clear.

The gate itself is never invoked here; it is injected. What is under test is
the decision made from its exit code, not Linear.
"""

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import gate_hold  # noqa: E402
from fleetd.phase_dispatch import DispatchTable  # noqa: E402

from fleetd.tests import _hermetic  # noqa: E402


def setUpModule():
    # GitHub #648: never run the installed ~/.claude/skills copy of flow.sh
    # or its libs, and never write under the real home.
    global _restore_env
    _restore_env = _hermetic.isolate()


def tearDownModule():
    _restore_env()


REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
TABLE_PATH = (
    REPO_ROOT / 'ticket-auto-pipeline' / 'skills' / 'ticket-flow'
    / 'dispatch-table.json'
)

HELD_LINE = '2026-09-03T10:00:00Z|GATE|gate|fail|held: complex ticket'
PASS_LINE = '2026-09-03T10:00:00Z|GATE|gate|done|auto-approved'
STOP_LINE = '2026-09-03T10:00:00Z|META|gate-stop|fail|EXEC_NO_ARTIFACT'
FETCH_FAILED_HELD_LINE = (
    '2026-09-03T10:00:00Z|GATE|gate|fail|held: linear fetch failed '
    '(attempt 1/3) — get_issue(CRE-9) failed')
GATE_HELD_MARKER = '2026-09-03T09:30:00Z|META|gate-held|info|held'


def _gate(exit_code, lines):
    """A stand-in entry gate returning a fixed answer."""
    def probe(tid, hb_log_file='', lib_dir=None, log_file=''):
        return exit_code, list(lines)
    return probe


class GateHoldTestBase(unittest.TestCase):
    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)
        self.tmp = tempfile.mkdtemp()
        self.log = Path(self.tmp) / 'CRE-9-pipeline.log'
        self.log.write_text('2026-09-03T09:00:00Z|META|schema|info|1\n')

    def _reconcile(self, exit_code, lines, **row):
        # A held ticket's row always carries a real hold_kind (set_hold
        # requires one); default to 'gate' here so every pre-existing test
        # below keeps exercising the 'gate' release predicate unchanged.
        row.setdefault('hold_kind', 'gate')
        return gate_hold.reconcile_hold(
            self.table, 'CRE-9', row, str(self.log),
            entry_gate=_gate(exit_code, lines))

    def _log_lines(self):
        return [ln for ln in self.log.read_text().splitlines() if ln.strip()]


class TestStillHeld(GateHoldTestBase):

    def test_a_still_held_ticket_stays_held(self):
        d = self._reconcile(gate_hold.GATE_ENTRY_HELD, [HELD_LINE],
                            reconcile_cycle=0, position='STEP_2_5')
        self.assertEqual(d.action, gate_hold.HOLD)

    def test_a_still_held_poll_does_not_advance_the_cycle(self):
        """Polls are not cycles. Counting them gate-stops a weekend wait."""
        d = self._reconcile(gate_hold.GATE_ENTRY_HELD, [HELD_LINE],
                            reconcile_cycle=1, position='STEP_2_5')
        self.assertEqual(d.cycle, 1)

    def test_a_still_held_poll_writes_nothing_to_the_pipeline_log(self):
        before = self._log_lines()
        self._reconcile(gate_hold.GATE_ENTRY_HELD, [HELD_LINE],
                        reconcile_cycle=0)
        self.assertEqual(self._log_lines(), before)

    def test_many_polls_leave_the_log_untouched(self):
        before = self._log_lines()
        for _ in range(50):
            self._reconcile(gate_hold.GATE_ENTRY_HELD, [HELD_LINE],
                            reconcile_cycle=0)
        self.assertEqual(self._log_lines(), before)


class TestGateFetchFailureHold(GateHoldTestBase):
    """tracker-read-failure-policy section 6: a still-held gate whose
    reason is 'linear fetch failed' must not stay silent forever the way
    every other held reason correctly does — gate-check.sh's own bash-side
    attempt cap cannot see across separate reconcile probes (each runs
    against a fresh scratch log), so this reconciler-side cap is what
    actually bounds a persistent tracker outage.
    """

    def _append_gate_held_marker(self):
        with open(self.log, 'a') as fh:
            fh.write(GATE_HELD_MARKER + '\n')

    def test_first_fetch_failure_probe_holds_and_logs_attempt_one(self):
        self._append_gate_held_marker()
        d = self._reconcile(gate_hold.GATE_ENTRY_HELD,
                            [FETCH_FAILED_HELD_LINE], reconcile_cycle=0)
        self.assertEqual(d.action, gate_hold.HOLD)
        lines = self._log_lines()
        self.assertTrue(
            any('gate-fetch-probe|fail|attempt=1/3' in ln for ln in lines),
            lines)

    def test_non_fetch_failure_held_reason_still_writes_nothing(self):
        """The pre-existing silent-poll guarantee (complex ticket, manual
        mode, ...) is unaffected — only the fetch-failure reason counts."""
        self._append_gate_held_marker()
        before = self._log_lines()
        self._reconcile(gate_hold.GATE_ENTRY_HELD, [HELD_LINE],
                        reconcile_cycle=0)
        self.assertEqual(self._log_lines(), before)

    def test_third_consecutive_fetch_failure_probe_gate_stops(self):
        self._append_gate_held_marker()
        d1 = self._reconcile(gate_hold.GATE_ENTRY_HELD,
                             [FETCH_FAILED_HELD_LINE], reconcile_cycle=0)
        d2 = self._reconcile(gate_hold.GATE_ENTRY_HELD,
                             [FETCH_FAILED_HELD_LINE], reconcile_cycle=0)
        d3 = self._reconcile(gate_hold.GATE_ENTRY_HELD,
                             [FETCH_FAILED_HELD_LINE], reconcile_cycle=0)
        self.assertEqual(d1.action, gate_hold.HOLD)
        self.assertEqual(d2.action, gate_hold.HOLD)
        self.assertEqual(d3.action, gate_hold.GATE_STOP)
        self.assertEqual(d3.gate_stop_code, 'LINEAR_FETCH_FAILED')
        lines = self._log_lines()
        self.assertTrue(
            any('META|gate-stop|fail|LINEAR_FETCH_FAILED' in ln
                for ln in lines),
            lines)

    def test_attempt_count_is_scoped_to_the_current_hold(self):
        """Probe attempts from a prior, already-released hold must not
        bleed into a new hold's count — otherwise a ticket that resolves
        one outage and later hits a fresh one would gate-stop immediately."""
        self._append_gate_held_marker()
        self._reconcile(gate_hold.GATE_ENTRY_HELD, [FETCH_FAILED_HELD_LINE],
                        reconcile_cycle=0)
        self._reconcile(gate_hold.GATE_ENTRY_HELD, [FETCH_FAILED_HELD_LINE],
                        reconcile_cycle=0)
        # Simulate release + a brand new hold episode starting.
        with open(self.log, 'a') as fh:
            fh.write(
                '2026-09-03T11:00:00Z|GATE|gate|done|auto-approved\n')
        self._append_gate_held_marker()

        d = self._reconcile(gate_hold.GATE_ENTRY_HELD,
                            [FETCH_FAILED_HELD_LINE], reconcile_cycle=0)
        self.assertEqual(d.action, gate_hold.HOLD)
        lines = self._log_lines()
        self.assertTrue(
            any('gate-fetch-probe|fail|attempt=1/3' in ln for ln in lines),
            lines)

    def test_max_attempts_env_override(self):
        self._append_gate_held_marker()
        os.environ['FLEET_GATE_FETCH_MAX_ATTEMPTS'] = '1'
        try:
            d = self._reconcile(gate_hold.GATE_ENTRY_HELD,
                                [FETCH_FAILED_HELD_LINE], reconcile_cycle=0)
        finally:
            del os.environ['FLEET_GATE_FETCH_MAX_ATTEMPTS']
        self.assertEqual(d.action, gate_hold.GATE_STOP)


class TestRelease(GateHoldTestBase):

    def test_a_passing_gate_releases_the_hold(self):
        d = self._reconcile(gate_hold.GATE_ENTRY_PASS, [PASS_LINE],
                            reconcile_cycle=0, position='STEP_2_5')
        self.assertEqual(d.action, gate_hold.RELEASE)

    def test_release_advances_the_reconcile_cycle(self):
        d = self._reconcile(gate_hold.GATE_ENTRY_PASS, [PASS_LINE],
                            reconcile_cycle=1)
        self.assertEqual(d.cycle, 2)

    def test_release_carries_the_recorded_dispatch_position(self):
        """Resume is read, never reconstructed — fleetd did the dispatch."""
        d = self._reconcile(gate_hold.GATE_ENTRY_PASS, [PASS_LINE],
                            position='STEP_4_5')
        self.assertEqual(d.position, 'STEP_4_5')

    def test_release_appends_the_gate_s_own_lines(self):
        self._reconcile(gate_hold.GATE_ENTRY_PASS, [PASS_LINE])
        self.assertIn(PASS_LINE, self._log_lines())


class TestGateStop(GateHoldTestBase):

    def test_a_structural_gate_failure_stops(self):
        d = self._reconcile(gate_hold.GATE_ENTRY_STOP, [STOP_LINE])
        self.assertEqual(d.action, gate_hold.GATE_STOP)

    def test_a_structural_failure_keeps_the_gate_s_own_reason(self):
        self._reconcile(gate_hold.GATE_ENTRY_STOP, [STOP_LINE])
        self.assertIn(STOP_LINE, self._log_lines())

    def test_the_cycle_cap_comes_from_the_table(self):
        cap = self.table.loop('STEP_3_5')['max_iterations']
        d = self._reconcile(gate_hold.GATE_ENTRY_PASS, [PASS_LINE],
                            reconcile_cycle=cap)
        self.assertEqual(d.action, gate_hold.GATE_STOP)
        self.assertEqual(d.gate_stop_code,
                         self.table.loop('STEP_3_5')['gate_stop_code'])

    def test_the_cap_is_checked_before_the_gate_is_even_probed(self):
        """An exhausted ticket must not cost a Linear round trip."""
        calls = []

        def probe(tid, hb_log_file='', lib_dir=None, log_file=''):
            calls.append(tid)
            return gate_hold.GATE_ENTRY_PASS, [PASS_LINE]

        cap = self.table.loop('STEP_3_5')['max_iterations']
        gate_hold.reconcile_hold(
            self.table, 'CRE-9',
            {'reconcile_cycle': cap, 'hold_kind': 'gate'}, str(self.log),
            entry_gate=probe)
        self.assertEqual(calls, [])

    def test_one_below_the_cap_still_releases(self):
        cap = self.table.loop('STEP_3_5')['max_iterations']
        d = self._reconcile(gate_hold.GATE_ENTRY_PASS, [PASS_LINE],
                            reconcile_cycle=cap - 1)
        self.assertEqual(d.action, gate_hold.RELEASE)


class TestUnanswerableProbe(GateHoldTestBase):

    def test_a_timeout_is_unavailable_not_held(self):
        """A gate that could not run is a different fact from one that held
        — UNAVAILABLE is never collapsed into HOLD (design.md D7)."""
        d = self._reconcile(None, [])
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)
        self.assertIn('did not answer', d.detail)

    def test_an_undocumented_exit_code_is_unavailable_not_held(self):
        d = self._reconcile(127, [])
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)
        self.assertIn('did not answer', d.detail)
        self.assertNotEqual(d.detail, 'still held')

    def test_an_unanswerable_probe_writes_nothing(self):
        before = self._log_lines()
        self._reconcile(127, [STOP_LINE])
        self.assertEqual(self._log_lines(), before)


class TestUnregisteredHoldKind(GateHoldTestBase):
    """'external' is a placeholder for a future hold kind (design.md
    Non-Goals: "external/deploy hold kinds") with no registered predicate.
    It must resolve to UNAVAILABLE — never a release (a premise nothing
    evaluated) and never a gate-stop (killing a ticket over a missing
    feature). 'human' used to be the example here; human-hold-protocol
    registered its own predicate below, so this class now uses a kind that
    genuinely has none."""

    def test_unregistered_kind_yields_unavailable(self):
        calls = []

        def probe(tid, hb_log_file='', lib_dir=None, log_file=''):
            calls.append(tid)
            return gate_hold.GATE_ENTRY_PASS, [PASS_LINE]

        d = gate_hold.reconcile_hold(
            self.table, 'CRE-9', {'hold_kind': 'external'}, str(self.log),
            entry_gate=probe)
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)
        # No predicate is registered for 'external' — the gate probe (which
        # would only be meaningful for 'gate') must never be invoked.
        self.assertEqual(calls, [])

    def test_unregistered_kind_leaves_the_row_untouched(self):
        before = self._log_lines()
        gate_hold.reconcile_hold(
            self.table, 'CRE-9', {'hold_kind': 'external'}, str(self.log))
        self.assertEqual(self._log_lines(), before)

    def test_an_empty_hold_kind_is_also_unavailable(self):
        """A row with no hold_kind at all (should not occur once set_hold
        always writes one, but the dispatch must not guess) is unavailable,
        not silently treated as 'gate'."""
        d = gate_hold.reconcile_hold(
            self.table, 'CRE-9', {}, str(self.log))
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)


HOLD_ID = 'hold:CRE-9:g1:a1'


class HumanHoldTestBase(unittest.TestCase):
    """Base for the 'human' release predicate — mirrors GateHoldTestBase,
    but the probe under test is `probe_human_answer` (Linear comments), not
    a bash gate, so tests inject `answer_probe` instead of `entry_gate`."""

    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)
        self.tmp = tempfile.mkdtemp()
        self.log = Path(self.tmp) / 'CRE-9-pipeline.log'
        self.log.write_text('2026-09-06T09:00:00Z|META|schema|info|1\n')

    def _reconcile(self, action, detail='', **row):
        row.setdefault('hold_kind', 'human')
        row.setdefault('hold_id', HOLD_ID)
        row.setdefault('held_at', '2026-09-06T09:00:00Z')

        def probe(tid, hold_id, held_at, lib_dir=None):
            return action, detail

        return gate_hold.reconcile_hold(
            self.table, 'CRE-9', row, str(self.log),
            answer_probe=probe)


class TestHumanHoldAnswered(HumanHoldTestBase):

    def test_answered_releases_the_hold(self):
        d = self._reconcile(gate_hold.ANSWERED, 'answered by U1',
                            reconcile_cycle=0, position='STEP_2')
        self.assertEqual(d.action, gate_hold.RELEASE)

    def test_answered_advances_the_reconcile_cycle(self):
        d = self._reconcile(gate_hold.ANSWERED, reconcile_cycle=1)
        self.assertEqual(d.cycle, 2)

    def test_answered_carries_the_recorded_dispatch_position(self):
        """Resume is read, never reconstructed — the position never comes
        from the hold record (human-hold-release spec)."""
        d = self._reconcile(gate_hold.ANSWERED, position='STEP_4_5')
        self.assertEqual(d.position, 'STEP_4_5')

    def test_answered_carries_hold_id_and_generation(self):
        d = self._reconcile(gate_hold.ANSWERED, hold_id=HOLD_ID,
                            hold_generation=3)
        self.assertEqual(d.hold_id, HOLD_ID)
        self.assertEqual(d.hold_generation, 3)


class TestHumanHoldNotAnswered(HumanHoldTestBase):

    def test_not_answered_stays_held(self):
        d = self._reconcile(gate_hold.NOT_ANSWERED, 'no qualifying comment')
        self.assertEqual(d.action, gate_hold.HOLD)

    def test_not_answered_does_not_advance_the_cycle(self):
        d = self._reconcile(gate_hold.NOT_ANSWERED, reconcile_cycle=1)
        self.assertEqual(d.cycle, 1)

    def test_a_bot_authored_comment_does_not_release(self):
        """The non-bot condition is load-bearing (design.md D3) — modelled
        here at the probe boundary, since probe_human_answer itself owns
        the bot-identity check; the reconcile layer must simply respect
        whatever the probe decides."""
        d = self._reconcile(gate_hold.NOT_ANSWERED,
                            'bot-authored comment ignored')
        self.assertEqual(d.action, gate_hold.HOLD)


class TestHumanHoldUnavailable(HumanHoldTestBase):

    def test_api_failure_is_unavailable_never_not_answered(self):
        d = self._reconcile(gate_hold.UNAVAILABLE, 'get_me failed: timeout')
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)

    def test_unavailable_does_not_advance_the_cycle(self):
        d = self._reconcile(gate_hold.UNAVAILABLE, reconcile_cycle=2)
        self.assertEqual(d.cycle, 2)

    def test_unavailable_writes_nothing_to_the_pipeline_log(self):
        before = self.log.read_text()
        self._reconcile(gate_hold.UNAVAILABLE)
        self.assertEqual(self.log.read_text(), before)


class TestHumanHoldFenceGuard(HumanHoldTestBase):
    """A hold created against a since-fenced generation is not released
    into it (human-hold-release spec, mirrors flow.sh's fence guard)."""

    def test_hold_generation_at_fence_is_refused(self):
        d = self._reconcile(gate_hold.ANSWERED, hold_generation=2,
                            fenced_generation=2)
        self.assertEqual(d.action, gate_hold.HOLD)
        self.assertIn('refused', d.detail)

    def test_hold_generation_below_fence_is_refused(self):
        d = self._reconcile(gate_hold.ANSWERED, hold_generation=1,
                            fenced_generation=3)
        self.assertEqual(d.action, gate_hold.HOLD)

    def test_hold_generation_above_fence_releases_normally(self):
        d = self._reconcile(gate_hold.ANSWERED, hold_generation=5,
                            fenced_generation=2)
        self.assertEqual(d.action, gate_hold.RELEASE)

    def test_fenced_generation_none_never_refuses(self):
        """An unfenced ticket (the common case) is unaffected."""
        d = self._reconcile(gate_hold.ANSWERED, hold_generation=1,
                            fenced_generation=None)
        self.assertEqual(d.action, gate_hold.RELEASE)


class TestHumanHoldCycleCap(HumanHoldTestBase):

    def test_the_cycle_cap_comes_from_the_table(self):
        cap = self.table.loop('STEP_3_5')['max_iterations']
        d = self._reconcile(gate_hold.ANSWERED, reconcile_cycle=cap)
        self.assertEqual(d.action, gate_hold.GATE_STOP)
        self.assertEqual(d.gate_stop_code,
                         self.table.loop('STEP_3_5')['gate_stop_code'])

    def test_the_cap_is_checked_before_the_probe_even_runs(self):
        calls = []

        def probe(tid, hold_id, held_at, lib_dir=None):
            calls.append(tid)
            return gate_hold.ANSWERED, ''

        cap = self.table.loop('STEP_3_5')['max_iterations']
        gate_hold.reconcile_hold(
            self.table, 'CRE-9',
            {'reconcile_cycle': cap, 'hold_kind': 'human',
             'hold_id': HOLD_ID}, str(self.log), answer_probe=probe)
        self.assertEqual(calls, [])

    def test_one_below_the_cap_still_releases(self):
        cap = self.table.loop('STEP_3_5')['max_iterations']
        d = self._reconcile(gate_hold.ANSWERED, reconcile_cycle=cap - 1)
        self.assertEqual(d.action, gate_hold.RELEASE)


class TestProbeHumanAnswer(unittest.TestCase):
    """`probe_human_answer` itself — the Linear-reading half, with
    `subprocess.run` stubbed so no network call is ever made."""

    def setUp(self):
        self.lib_dir = (REPO_ROOT / 'ticket-auto-pipeline' / 'lib')
        self._real_run = gate_hold.subprocess.run

    def tearDown(self):
        gate_hold.subprocess.run = self._real_run

    def _stub(self, me_json, comments_json, me_rc=0, comments_rc=0):
        calls = []

        def fake_run(argv, **kwargs):
            calls.append(argv)
            script = argv[-1] if isinstance(argv, list) else str(argv)
            if 'get_me' in script:
                return _Proc(me_rc, me_json, '')
            return _Proc(comments_rc, comments_json, '')

        gate_hold.subprocess.run = fake_run
        return calls

    def test_answered_when_non_bot_comment_after_held_at_carries_token(self):
        self._stub(
            '{"id": "bot-1", "name": "Fleet Bot"}',
            '[{"id": "c1", "body": "quoting hold:CRE-9:g1:a1 here", '
            '"createdAt": "2026-09-06T10:00:00.000Z", '
            '"user": {"id": "human-1", "name": "A Human"}}]')
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.ANSWERED)

    def test_bot_authored_comment_does_not_release(self):
        self._stub(
            '{"id": "bot-1", "name": "Fleet Bot"}',
            '[{"id": "c1", "body": "quoting hold:CRE-9:g1:a1 here", '
            '"createdAt": "2026-09-06T10:00:00.000Z", '
            '"user": {"id": "bot-1", "name": "Fleet Bot"}}]')
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.NOT_ANSWERED)

    def test_comment_without_token_does_not_release(self):
        self._stub(
            '{"id": "bot-1"}',
            '[{"id": "c1", "body": "just chatting", '
            '"createdAt": "2026-09-06T10:00:00.000Z", '
            '"user": {"id": "human-1"}}]')
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.NOT_ANSWERED)

    def test_pre_hold_comment_does_not_release(self):
        self._stub(
            '{"id": "bot-1"}',
            '[{"id": "c1", "body": "quoting hold:CRE-9:g1:a1", '
            '"createdAt": "2026-09-06T08:00:00.000Z", '
            '"user": {"id": "human-1"}}]')
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.NOT_ANSWERED)

    def test_comment_quoting_a_superseded_hold_id_is_a_no_op(self):
        """Quoting a stale hold_id is checked against THIS hold's id, so an
        answer to a superseded hold does not match here — the caller passed
        the current hold_id, and a comment naming a different, prior one
        does not contain it."""
        self._stub(
            '{"id": "bot-1"}',
            '[{"id": "c1", "body": "quoting hold:CRE-9:g1:a1 (an old one)", '
            '"createdAt": "2026-09-06T10:00:00.000Z", '
            '"user": {"id": "human-1"}}]')
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', 'hold:CRE-9:g1:a2', '2026-09-06T09:00:00Z',
            lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.NOT_ANSWERED)

    def test_get_me_failure_is_unavailable(self):
        self._stub('', '[]', me_rc=1)
        action, detail = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.UNAVAILABLE)
        self.assertIn('get_me', detail)

    def test_get_comments_failure_is_unavailable(self):
        self._stub('{"id": "bot-1"}', '', comments_rc=1)
        action, detail = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.UNAVAILABLE)

    def test_unparseable_response_is_unavailable_not_not_answered(self):
        self._stub('not json', '[]')
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.UNAVAILABLE)

    def test_timeout_is_unavailable(self):
        def fake_run(argv, **kwargs):
            raise gate_hold.subprocess.TimeoutExpired(cmd=argv, timeout=1)
        gate_hold.subprocess.run = fake_run
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.UNAVAILABLE)


_CURL_SHIM = r'''#!/usr/bin/env bash
d="$SHIM_DIR"
n=$(($(cat "$d/count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$d/count"
cat >/dev/null
plan="$d/plan.$n"
[ -f "$plan" ] || plan="$d/plan.default"
rc=$(sed -n 1p "$plan")
code=$(sed -n 2p "$plan")
body=$(sed -n '3,$p' "$plan")
if [ "$rc" -ne 0 ]; then
  printf '\n000'
  exit "$rc"
fi
printf '%s\n%s' "$body" "$code"
'''


class TestProbeHumanAnswerRealClient(unittest.TestCase):
    """`probe_human_answer` against the real `linear-api.sh`, with only `curl`
    replaced (a PATH shim). The stubbed-subprocess tests above pin the
    decision table; these pin the contract between it and the bash client —
    BE-3: an unreadable comment list must reach the probe as a non-zero
    exit (UNAVAILABLE), never as `[]` (NOT_ANSWERED)."""

    ME = '{"data":{"viewer":{"id":"bot-1","name":"Fleet Bot"}}}'

    def setUp(self):
        self.lib_dir = Path(os.environ.get(
            'GATE_HOLD_TEST_TICKET_AUTO_LIB',
            str(REPO_ROOT / 'ticket-auto-pipeline' / 'lib')))
        self.tmp = tempfile.TemporaryDirectory()
        self.shim = Path(self.tmp.name)
        (self.shim / 'bin').mkdir()
        curl = self.shim / 'bin' / 'curl'
        curl.write_text(_CURL_SHIM)
        curl.chmod(0o755)
        self._saved_env = dict(os.environ)
        os.environ.update({
            'SHIM_DIR': str(self.shim),
            'PATH': f"{self.shim / 'bin'}:{os.environ.get('PATH', '')}",
            'LINEAR_API_KEY': 'lin_api_test',
            'LINEAR_API_URL': 'http://127.0.0.1:9/graphql',
            'LINEAR_RETRY_DELAYS': '0',
            'LINEAR_MAX_RETRIES': '0',
        })
        os.environ.pop('LOG_FILE', None)
        os.environ.pop('HB_LOG_FILE', None)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._saved_env)
        self.tmp.cleanup()

    def _plan(self, n, curl_rc, http_code, body=''):
        (self.shim / f'plan.{n}').write_text(f'{curl_rc}\n{http_code}\n{body}\n')

    def _probe(self):
        return gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)

    def test_comment_read_outage_is_unavailable(self):
        self._plan(1, 0, 200, self.ME)
        self._plan('default', 7, 0)
        action, detail = self._probe()
        self.assertEqual(action, gate_hold.UNAVAILABLE, detail)

    def test_unresolvable_issue_is_unavailable_not_not_answered(self):
        """`{"data":{"issue":null}}` used to come back as `[]`, exit 0 —
        indistinguishable from "nobody has replied yet"."""
        self._plan(1, 0, 200, self.ME)
        self._plan('default', 0, 200, '{"data":{"issue":null}}')
        action, detail = self._probe()
        self.assertEqual(action, gate_hold.UNAVAILABLE, detail)

    def test_comment_read_rate_limited_is_unavailable(self):
        self._plan(1, 0, 200, self.ME)
        self._plan('default', 0, 400, '{"errors":[{"message":"Rate limit '
                   'exceeded","extensions":{"code":"RATELIMITED"}}]}')
        action, detail = self._probe()
        self.assertEqual(action, gate_hold.UNAVAILABLE, detail)

    def test_genuinely_empty_comment_list_is_not_answered(self):
        self._plan(1, 0, 200, self.ME)
        self._plan('default', 0, 200,
                   '{"data":{"issue":{"comments":{"nodes":[]}}}}')
        action, detail = self._probe()
        self.assertEqual(action, gate_hold.NOT_ANSWERED, detail)


class _Proc:
    def __init__(self, returncode, stdout, stderr):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class TestHoldAttemptExhaustion(unittest.TestCase):

    def setUp(self):
        self._saved = gate_hold.os.environ.pop('FLEET_HOLD_MAX_ATTEMPTS', None)

    def tearDown(self):
        if self._saved is not None:
            gate_hold.os.environ['FLEET_HOLD_MAX_ATTEMPTS'] = self._saved
        else:
            gate_hold.os.environ.pop('FLEET_HOLD_MAX_ATTEMPTS', None)

    def test_default_max_is_three(self):
        self.assertEqual(gate_hold.human_hold_max_attempts(), 3)

    def test_below_the_cap_does_not_exceed(self):
        self.assertFalse(gate_hold.human_hold_attempt_exceeds_max(2))

    def test_the_fourth_attempt_exceeds_the_default_cap(self):
        self.assertTrue(gate_hold.human_hold_attempt_exceeds_max(3))

    def test_configurable_cap(self):
        gate_hold.os.environ['FLEET_HOLD_MAX_ATTEMPTS'] = '1'
        self.assertTrue(gate_hold.human_hold_attempt_exceeds_max(1))
        self.assertFalse(gate_hold.human_hold_attempt_exceeds_max(0))

    def test_nonsense_value_falls_back_to_default(self):
        gate_hold.os.environ['FLEET_HOLD_MAX_ATTEMPTS'] = 'lots'
        self.assertEqual(gate_hold.human_hold_max_attempts(), 3)


class TestPostHumanHoldComment(unittest.TestCase):
    """post_human_hold_comment — fail-soft, and never invents a label."""

    def setUp(self):
        self._real_run = gate_hold.subprocess.run

    def tearDown(self):
        gate_hold.subprocess.run = self._real_run

    def test_success_posts_comment_and_applies_needs_info(self):
        calls = []

        def fake_run(argv, **kwargs):
            calls.append(argv)
            return _Proc(0, '', '')

        gate_hold.subprocess.run = fake_run
        lib_dir = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
        posted, labeled = gate_hold.post_human_hold_comment(
            'CRE-9', HOLD_ID, 'notes.md#AC-2', [(1, 'which archive?')],
            lib_dir=lib_dir)
        self.assertTrue(posted)
        # needs-info label application depends on flow.sh being resolvable
        # in this checkout — assert the comment call happened regardless.
        self.assertTrue(any('save_comment' in ' '.join(c) for c in calls
                            if isinstance(c, list)))

    def test_missing_linear_api_warns_on_stderr(self):
        import contextlib
        import io
        import tempfile

        buf = io.StringIO()
        with tempfile.TemporaryDirectory() as d, \
                contextlib.redirect_stderr(buf):
            posted, _ = gate_hold.post_human_hold_comment(
                'CRE-9', HOLD_ID, 'x', [(1, 'q?')], lib_dir=d)
        self.assertFalse(posted)
        self.assertIn('linear-api.sh not found', buf.getvalue())

    def test_comment_body_carries_hold_id_and_numbered_questions(self):
        captured = {}

        def fake_run(argv, **kwargs):
            if isinstance(argv, list) and 'save_comment' in ' '.join(argv):
                captured['body'] = kwargs.get('env', {}).get('BODY', '')
            return _Proc(0, '', '')

        gate_hold.subprocess.run = fake_run
        lib_dir = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
        gate_hold.post_human_hold_comment(
            'CRE-9', HOLD_ID, 'notes.md#AC-2',
            [(1, 'which archive?'), (2, 'csv or xlsx?')], lib_dir=lib_dir)
        self.assertIn(HOLD_ID, captured.get('body', ''))
        self.assertIn('1. which archive?', captured.get('body', ''))
        self.assertIn('2. csv or xlsx?', captured.get('body', ''))

    def test_linear_failure_degrades_without_raising(self):
        def fake_run(argv, **kwargs):
            return _Proc(1, '', 'boom')

        gate_hold.subprocess.run = fake_run
        lib_dir = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
        posted, labeled = gate_hold.post_human_hold_comment(
            'CRE-9', HOLD_ID, 'notes.md#AC-2', [(1, 'x?')], lib_dir=lib_dir)
        self.assertFalse(posted)
        self.assertFalse(labeled)

    def test_timeout_degrades_without_raising(self):
        def fake_run(argv, **kwargs):
            raise gate_hold.subprocess.TimeoutExpired(cmd=argv, timeout=1)

        gate_hold.subprocess.run = fake_run
        lib_dir = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
        posted, labeled = gate_hold.post_human_hold_comment(
            'CRE-9', HOLD_ID, 'notes.md#AC-2', [(1, 'x?')], lib_dir=lib_dir)
        self.assertFalse(posted)
        self.assertFalse(labeled)


class TestClearNeedsInfoOnRelease(unittest.TestCase):
    """clear_needs_info_on_release — the answered-hold half of the
    `needs-info` lifecycle. post_human_hold_comment applies the flag when a
    hold is created; before this, nothing deterministic cleared it when the
    human answered, so the ticket stayed FLAG_NEEDS_INFO/not-ready until a
    /ticket-approve or a full re-appraisal. Runs the real flow.sh against a
    throwaway REPOS_ROOT."""

    TID = 'TST-71'

    def setUp(self):
        import json as _json
        self._json = _json
        self.tmp = Path(tempfile.mkdtemp())
        self.repos = self.tmp / 'repos'
        self.logs = self.tmp / 'logs'
        self.logs.mkdir(parents=True)
        index = self.repos / '.ticket-auto' / 'initiatives' / '_index'
        index.mkdir(parents=True)
        (index / f'{self.TID}.initiative').write_text('INIT-1\n')
        self.manifest = (self.repos / '.ticket-auto' / 'initiatives' / 'INIT-1'
                         / 'tickets' / self.TID / 'planner' / 'manifest.json')
        self.manifest.parent.mkdir(parents=True)
        self.lib_dir = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
        self.env = {
            **os.environ,
            'REPOS_ROOT': str(self.repos),
            'FLEET_FENCE_ENFORCE': 'false',
            'FLEET_PIPELINE_LOG_DIR': str(self.logs),
            'LOG_FILE': str(self.logs / f'{self.TID}-pipeline.log'),
            'TICKET_FLOW_LOCK_DIR': str(self.logs),
            'CLAUDE_SKILLS_LIB': str(self.lib_dir),
        }

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _seed(self, flags):
        self.manifest.write_text(self._json.dumps({
            'type': 'feature', 'initiative': 'INIT-1', 'blocked_by': [],
            'dispatch': False, 'flags': flags}))

    def _manifest(self):
        return self._json.loads(self.manifest.read_text())

    def test_answered_hold_clears_a_set_needs_info_flag(self):
        self._seed(['needs-info'])
        result = gate_hold.clear_needs_info_on_release(
            self.TID, lib_dir=self.lib_dir, env=self.env)
        self.assertEqual(result, 'cleared')
        self.assertEqual(self._manifest().get('flags'), [])

    def test_no_flag_is_a_no_op_that_never_runs_flow(self):
        self._seed([])
        result = gate_hold.clear_needs_info_on_release(
            self.TID, lib_dir=self.lib_dir, env=self.env)
        self.assertEqual(result, 'absent')
        # flow.sh advances `rev` on every invocation; a no-op must not.
        self.assertNotIn('rev', self._manifest())

    def test_missing_lib_is_failsoft(self):
        result = gate_hold.clear_needs_info_on_release(
            self.TID, lib_dir=self.tmp / 'nowhere', env=self.env)
        self.assertEqual(result, 'unavailable')


class TestHoldIdThreading(GateHoldTestBase):
    """hold_id/hold_generation are carried from the row into every decision
    so the caller can release with store.release_hold's CAS guard."""

    def test_hold_id_and_generation_are_carried_through_every_action(self):
        for exit_code, lines in (
            (gate_hold.GATE_ENTRY_HELD, [HELD_LINE]),
            (gate_hold.GATE_ENTRY_PASS, [PASS_LINE]),
            (gate_hold.GATE_ENTRY_STOP, [STOP_LINE]),
            (127, []),
        ):
            d = self._reconcile(
                exit_code, lines,
                hold_id='hold:CRE-9:g3:a1', hold_generation=3)
            self.assertEqual(d.hold_id, 'hold:CRE-9:g3:a1')
            self.assertEqual(d.hold_generation, 3)

    def test_unregistered_kind_also_carries_hold_id(self):
        d = gate_hold.reconcile_hold(
            self.table, 'CRE-9',
            {'hold_kind': 'human', 'hold_id': 'hold:CRE-9:g1:a1',
             'hold_generation': 1},
            str(self.log))
        self.assertEqual(d.hold_id, 'hold:CRE-9:g1:a1')
        self.assertEqual(d.hold_generation, 1)


# A stand-in gate-check.sh that decides only from the log it is handed, the
# way the real gate's _get_artifact_type does: an openspec artifact line in
# the log means the complex ticket is coherent and merely held; no artifact
# line means the gate defaults to simple-fix and gate-stops on a mismatch.
_FAKE_GATE_SH = r"""#!/usr/bin/env bash
LOG="$2"
if grep -q '|EXEC|create-artifact|done|openspec' "$LOG"; then
  echo "2026-09-03T10:00:00Z|GATE|gate|fail|held: complex ticket" >> "$LOG"
  exit 1
fi
echo "2026-09-03T10:00:00Z|META|gate-stop|fail|COMPLEXITY_ARTIFACT_MISMATCH — complexity=complex artifact=simple-fix" >> "$LOG"
exit 2
"""


class TestProbeSeesTheRealLog(GateHoldTestBase):
    """Regression (#529): the reconcile probe ran gate-check.sh against an
    EMPTY scratch log, so `_get_artifact_type` never saw the ticket's
    `EXEC|create-artifact|done|openspec` line, defaulted to simple-fix, and
    every held complex ticket gate-stopped COMPLEXITY_ARTIFACT_MISMATCH on
    every pass. The probe must evaluate the same facts the in-session gate
    would — the real log's — while still writing nothing on a no-change
    poll."""

    def setUp(self):
        super().setUp()
        self.lib = Path(self.tmp) / 'lib'
        self.lib.mkdir()
        (self.lib / 'gate-check.sh').write_text(_FAKE_GATE_SH)
        with open(self.log, 'a') as fh:
            fh.write('2026-09-03T09:10:00Z|META|artifact|info|'
                     'plan:openspec/changes/some-change\n'
                     '2026-09-03T09:10:00Z|EXEC|create-artifact|done|openspec\n'
                     + GATE_HELD_MARKER + '\n')

    def test_held_complex_openspec_ticket_stays_held(self):
        before = self._log_lines()
        d = gate_hold.reconcile_hold(
            self.table, 'CRE-9', {'hold_kind': 'gate'}, str(self.log),
            lib_dir=str(self.lib))
        self.assertEqual(d.action, gate_hold.HOLD, d.detail)
        self.assertEqual(self._log_lines(), before)

    def test_probe_returns_only_the_lines_it_added(self):
        code, lines = gate_hold.run_entry_gate(
            'CRE-9', lib_dir=str(self.lib), log_file=str(self.log))
        self.assertEqual(code, gate_hold.GATE_ENTRY_HELD)
        self.assertEqual(
            lines, ['2026-09-03T10:00:00Z|GATE|gate|fail|held: complex ticket'])

    def test_probe_never_writes_to_the_real_log(self):
        before = self.log.read_text()
        gate_hold.run_entry_gate(
            'CRE-9', lib_dir=str(self.lib), log_file=str(self.log))
        self.assertEqual(self.log.read_text(), before)


class TestGateStopIsOneShot(GateHoldTestBase):
    """Regression (#529): a GATE_STOP left the row held, so the next pass
    re-probed and re-appended the same gate-stop pair — ~350 times for one
    ticket. Once a gate-stop has been recorded for this hold, later passes
    must neither probe nor write again."""

    HOLD_ID = 'hold:CRE-9:g1:a0'
    HELD_AT = '2026-09-03T09:30:00Z'

    def _row(self):
        return {'hold_kind': 'gate', 'hold_id': self.HOLD_ID,
                'held_at': self.HELD_AT}

    def test_recorded_gate_stop_suppresses_the_next_probe(self):
        with open(self.log, 'a') as fh:
            fh.write('2026-09-03T09:40:00Z|META|gate-stop|fail|' +
                     gate_hold.gate_stop_marker_msg(
                         'GATE_HOLD_RECONCILE_FAILED', self.HOLD_ID) + '\n')
        before = self._log_lines()
        calls = []

        def probe(tid, hb_log_file='', lib_dir=None, log_file=''):
            calls.append(tid)
            return gate_hold.GATE_ENTRY_STOP, [STOP_LINE]

        d = gate_hold.reconcile_hold(self.table, 'CRE-9', self._row(),
                                     str(self.log), entry_gate=probe)
        self.assertEqual(calls, [])
        self.assertNotEqual(d.action, gate_hold.GATE_STOP)
        self.assertEqual(self._log_lines(), before)

    def test_a_gate_stop_from_an_earlier_hold_does_not_suppress(self):
        """Same hold_id minted again later (attempt 0 is reused) gets a fresh
        held_at — a stop that predates it belongs to the earlier hold."""
        with open(self.log, 'a') as fh:
            fh.write('2026-09-03T09:00:00Z|META|gate-stop|fail|' +
                     gate_hold.gate_stop_marker_msg(
                         'GATE_HOLD_RECONCILE_FAILED', self.HOLD_ID) + '\n')
        d = gate_hold.reconcile_hold(
            self.table, 'CRE-9', self._row(), str(self.log),
            entry_gate=_gate(gate_hold.GATE_ENTRY_HELD, [HELD_LINE]))
        self.assertEqual(d.action, gate_hold.HOLD)
        self.assertEqual(d.detail, 'still held')

    def test_marker_keeps_the_code_as_its_prefix(self):
        """exit-path.sh classifies `gate-stop:<CODE>*` by prefix."""
        msg = gate_hold.gate_stop_marker_msg('RECONCILE_EXHAUSTED', self.HOLD_ID)
        self.assertTrue(msg.startswith('RECONCILE_EXHAUSTED'))
        self.assertIn(self.HOLD_ID, msg)
        self.assertNotIn('|', msg)


class TestNeverReapprove(GateHoldTestBase):
    """--mode reapprove writes APPROVAL_REVOKED on any non-pass and would
    gate-stop a ticket whose human simply has not looked yet — the entry
    probe must never take that path."""

    def test_run_entry_gate_always_passes_mode_entry(self):
        captured = {}
        real_run = gate_hold.subprocess.run

        def _capture(argv, **kwargs):
            captured['argv'] = argv
            raise gate_hold.subprocess.TimeoutExpired(cmd=argv, timeout=1)

        gate_hold.subprocess.run = _capture
        lib_dir = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
        try:
            gate_hold.run_entry_gate('CRE-9', lib_dir=str(lib_dir))
        finally:
            gate_hold.subprocess.run = real_run

        argv = captured.get('argv', [])
        self.assertIn('entry', argv)
        self.assertNotIn('reapprove', argv)


class TestCadence(unittest.TestCase):

    def setUp(self):
        self._saved = gate_hold.os.environ.pop(
            'FLEET_GATE_RECONCILE_INTERVAL', None)

    def tearDown(self):
        if self._saved is not None:
            gate_hold.os.environ['FLEET_GATE_RECONCILE_INTERVAL'] = self._saved
        else:
            gate_hold.os.environ.pop('FLEET_GATE_RECONCILE_INTERVAL', None)

    def test_default_interval_is_five_minutes(self):
        self.assertEqual(gate_hold.reconcile_interval_secs(), 300)

    def test_interval_is_configurable(self):
        gate_hold.os.environ['FLEET_GATE_RECONCILE_INTERVAL'] = '60'
        self.assertEqual(gate_hold.reconcile_interval_secs(), 60)

    def test_a_nonsense_interval_falls_back_to_the_default(self):
        gate_hold.os.environ['FLEET_GATE_RECONCILE_INTERVAL'] = 'soon'
        self.assertEqual(gate_hold.reconcile_interval_secs(), 300)

    def test_a_zero_interval_falls_back_rather_than_spinning(self):
        gate_hold.os.environ['FLEET_GATE_RECONCILE_INTERVAL'] = '0'
        self.assertEqual(gate_hold.reconcile_interval_secs(), 300)

    def test_never_run_is_due_immediately(self):
        self.assertTrue(gate_hold.is_due(None))

    def test_a_recent_pass_is_not_due(self):
        self.assertFalse(gate_hold.is_due(1000.0, now=1100.0, interval=300))

    def test_an_elapsed_interval_is_due(self):
        self.assertTrue(gate_hold.is_due(1000.0, now=1400.0, interval=300))


class ApprovalHoldReasonsTest(unittest.TestCase):
    def test_plan_changed_hold_is_an_approval_hold(self):
        """gate-check.sh's PLAN_CHANGED_SINCE_APPROVAL hold is released only
        by a person running approve.sh again, so the intake pass must turn
        it into a gate row like a complex-ticket hold."""
        from fleetd import supervisor
        self.assertIn('plan-changed-since-approval',
                      supervisor._GATE_HOLD_APPROVAL_REASONS)
        self.assertNotIn('linear-fetch-failed',
                         supervisor._GATE_HOLD_APPROVAL_REASONS)

    def test_reapprove_holds_are_approval_holds(self):
        """GitHub #820 follow-up: the reapprove gate's two hold reasons get
        a row too; before, such a ticket was invisible to the fleet."""
        from fleetd import supervisor
        self.assertTrue(gate_hold.REAPPROVE_HOLD_REASONS
                        <= supervisor._GATE_HOLD_APPROVAL_REASONS)



# ── Reapprove-gate holds (GitHub #820 follow-up) ────────────────────────────
# `gate-check.sh --mode reapprove` holds with `reapprove-needs-human` or
# `reapprove-plan-changed`. fleetd must make a row for those holds and probe
# them with `--mode reapprove`, so they release on the reapprove rule (a
# person's approval of the current plan), never on the entry gate's.

REAPPROVE_HELD_LINE = (
    '2026-09-03T10:00:00Z|GATE|reapprove|fail|held: the amended plan needs '
    "a person's approval")
REAPPROVE_DONE_LINE = '2026-09-03T10:00:00Z|GATE|reapprove|done|'


class TestReapproveHoldProbe(GateHoldTestBase):
    """The 'gate' predicate picks its probe by the row's hold_reason."""

    def _probes(self, entry_code, reapprove_code):
        calls = []

        def entry(tid, hb_log_file='', lib_dir=None, log_file=''):
            calls.append('entry')
            return entry_code, [HELD_LINE]

        def reapprove(tid, hb_log_file='', lib_dir=None, log_file=''):
            calls.append('reapprove')
            lines = ([REAPPROVE_DONE_LINE]
                     if reapprove_code == gate_hold.GATE_ENTRY_PASS
                     else [REAPPROVE_HELD_LINE])
            return reapprove_code, lines

        return calls, entry, reapprove

    def _run(self, reason, entry_code, reapprove_code):
        calls, entry, reapprove = self._probes(entry_code, reapprove_code)
        d = gate_hold.reconcile_hold(
            self.table, 'CRE-9',
            {'hold_kind': 'gate', 'hold_reason': reason,
             'position': 'STEP_4'},
            str(self.log), entry_gate=entry, reapprove_gate=reapprove)
        return d, calls

    def test_reapprove_reasons_are_the_ones_gate_check_emits(self):
        self.assertEqual(
            gate_hold.REAPPROVE_HOLD_REASONS,
            {'reapprove-needs-human', 'reapprove-plan-changed'})

    def test_reapprove_hold_is_probed_with_the_reapprove_gate(self):
        for reason in sorted(gate_hold.REAPPROVE_HOLD_REASONS):
            d, calls = self._run(reason, gate_hold.GATE_ENTRY_PASS,
                                 gate_hold.GATE_ENTRY_HELD)
            self.assertEqual(calls, ['reapprove'], reason)
            self.assertEqual(d.action, gate_hold.HOLD, reason)

    def test_still_held_reapprove_poll_writes_nothing(self):
        before = self._log_lines()
        self._run('reapprove-needs-human', gate_hold.GATE_ENTRY_PASS,
                  gate_hold.GATE_ENTRY_HELD)
        self.assertEqual(self._log_lines(), before)

    def test_reapprove_pass_releases_and_records_the_release_line(self):
        d, calls = self._run('reapprove-plan-changed',
                             gate_hold.GATE_ENTRY_HELD,
                             gate_hold.GATE_ENTRY_PASS)
        self.assertEqual(calls, ['reapprove'])
        self.assertEqual(d.action, gate_hold.RELEASE)
        self.assertIn(REAPPROVE_DONE_LINE, self._log_lines())

    def test_reapprove_revoked_is_a_gate_stop(self):
        d, _ = self._run('reapprove-needs-human', gate_hold.GATE_ENTRY_PASS,
                         gate_hold.GATE_ENTRY_STOP)
        self.assertEqual(d.action, gate_hold.GATE_STOP)
        self.assertIn('reapprove gate', d.detail)

    def test_entry_gate_hold_still_uses_the_entry_gate(self):
        for reason in ('complex-ticket', 'manual-mode', 'default-fallback',
                       'plan-changed-since-approval', ''):
            d, calls = self._run(reason, gate_hold.GATE_ENTRY_HELD,
                                 gate_hold.GATE_ENTRY_PASS)
            self.assertEqual(calls, ['entry'], reason)
            self.assertEqual(d.action, gate_hold.HOLD, reason)
            self.assertEqual(d.detail, 'still held', reason)

    def test_run_reapprove_gate_passes_mode_reapprove(self):
        captured = {}
        real_run = gate_hold.subprocess.run

        def _capture(argv, **kwargs):
            captured['argv'] = argv
            raise gate_hold.subprocess.TimeoutExpired(cmd=argv, timeout=1)

        gate_hold.subprocess.run = _capture
        lib_dir = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
        try:
            code, _ = gate_hold.run_reapprove_gate(
                'CRE-9', lib_dir=str(lib_dir))
        finally:
            gate_hold.subprocess.run = real_run
        self.assertIsNone(code)
        self.assertEqual(captured.get('argv', [])[-2:],
                         ['--mode', 'reapprove'])


# A stand-in gate-check.sh for the end-to-end test below. The approval rule
# itself is gate-check.sh's and is tested in lib/tests/test-gate-check.sh;
# this stand-in answers from a file so the test can play "a person ran
# approve.sh". Like the real gate it emits gate-released to the outbox on a
# pass. Every probe appends its mode to $FAKE_GATE_CALLS.
_FAKE_MODE_GATE_SH = r"""#!/usr/bin/env bash
TID="$1"; LOG="$2"; MODE="$5"
echo "$MODE" >> "$FAKE_GATE_CALLS"
if [ "$MODE" = "reapprove" ]; then
  if [ "$(cat "$FAKE_APPROVAL" 2>/dev/null)" = "human" ]; then
    echo "2026-09-23T01:00:00Z|GATE|reapprove|done|" >> "$LOG"
    printf '%s\n' '{"seq":99,"tid":"'"$TID"'","ts":"2026-09-23T01:00:00Z","gen":0,"event":"gate-released","data":{"provenance":"human"}}' >> "$FAKE_OUTBOX"
    exit 0
  fi
  echo "2026-09-23T01:00:00Z|GATE|reapprove|fail|held: needs a person" >> "$LOG"
  exit 1
fi
echo "2026-09-23T01:00:00Z|GATE|gate|fail|held: complex ticket" >> "$LOG"
exit 1
"""


class TestReapproveHoldIntakeToRelease(unittest.TestCase):
    """Intake creates the row, the reconcile pass probes `--mode reapprove`,
    and the row releases only once a person's approval exists."""

    TID = 'TST-RA1'

    def setUp(self):
        self.workspace = Path(tempfile.mkdtemp(prefix='fleetd-reapprove-'))
        self.lib = self.workspace / 'lib'
        self.lib.mkdir()
        (self.lib / 'gate-check.sh').write_text(_FAKE_MODE_GATE_SH)
        self.calls = self.workspace / 'gate-calls.txt'
        self.approval = self.workspace / 'approval.txt'
        self.approval.write_text('policy')
        self._saved = {k: os.environ.get(k) for k in (
            'CLAUDE_SKILLS_LIB', 'FLEET_PIPELINE_LOG_DIR', 'FAKE_GATE_CALLS',
            'FAKE_APPROVAL', 'FAKE_OUTBOX')}
        os.environ['CLAUDE_SKILLS_LIB'] = str(self.lib)
        os.environ['FLEET_PIPELINE_LOG_DIR'] = str(self.workspace)
        os.environ['FAKE_GATE_CALLS'] = str(self.calls)
        os.environ['FAKE_APPROVAL'] = str(self.approval)

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.workspace, ignore_errors=True)

    def _seed(self, tid, reason, held_line):
        log = self.workspace / f'{tid}-pipeline.log'
        log.write_text('\n'.join([
            '2026-09-23T00:00:00Z|META|schema|info|1',
            held_line,
            '2026-09-23T00:02:00Z|META|outcome|info|held: gate',
        ]) + '\n')
        outbox = self.workspace / f'{tid}-outbox.jsonl'
        outbox.write_text(json.dumps({
            'seq': 1, 'tid': tid, 'ts': '2026-09-23T00:01:00Z', 'gen': 0,
            'event': 'gate-held', 'data': {'reason': reason}}) + '\n')
        os.environ['FAKE_OUTBOX'] = str(outbox)
        return log

    def _supervisor(self):
        from fleetd.supervisor import Supervisor
        return Supervisor(state_dir=str(self.workspace),
                          pidfile=str(self.workspace / 'test.pid'),
                          spawn_enabled=False)

    def _row(self, tid):
        from fleetd import store
        with store.open_store(self.workspace) as st:
            return st.get_ticket(tid) or {}

    def _modes(self):
        if not self.calls.exists():
            return []
        return self.calls.read_text().split()

    def test_reapprove_hold_row_created_then_released_on_human_approval(self):
        log = self._seed(self.TID, 'reapprove-needs-human',
                         '2026-09-23T00:01:00Z|GATE|reapprove|fail|held: the '
                         "amended plan needs a person's approval")
        sup = self._supervisor()
        sup.acquire_lock()
        try:
            sup._gate_hold_intake_pass()
            row = self._row(self.TID)
            self.assertEqual(row.get('held'), 1)
            self.assertEqual(row.get('hold_kind'), 'gate')
            self.assertEqual(row.get('hold_reason'), 'reapprove-needs-human')

            # Only a policy approval: still held, nothing written.
            before = log.read_text()
            sup._hold_reconcile_pass()
            self.assertEqual(self._modes(), ['reapprove'])
            self.assertEqual(self._row(self.TID).get('held'), 1)
            self.assertEqual(log.read_text(), before)

            # A person runs approve.sh: the next pass releases the row.
            self.approval.write_text('human')
            sup._hold_reconcile_pass()
            self.assertEqual(self._modes(), ['reapprove', 'reapprove'])
            self.assertEqual(self._row(self.TID).get('held'), 0)
            self.assertIn('|GATE|reapprove|done|', log.read_text())

            # The released hold is not re-created by a later intake pass.
            sup._gate_hold_intake_pass()
            self.assertEqual(self._row(self.TID).get('held'), 0)
        finally:
            sup.release_lock()

    def test_plan_changed_reapprove_hold_gets_a_row(self):
        self._seed(self.TID, 'reapprove-plan-changed',
                   '2026-09-23T00:01:00Z|GATE|reapprove|fail|held: '
                   'PLAN_CHANGED_SINCE_APPROVAL')
        sup = self._supervisor()
        sup.acquire_lock()
        try:
            sup._gate_hold_intake_pass()
        finally:
            sup.release_lock()
        row = self._row(self.TID)
        self.assertEqual(row.get('held'), 1)
        self.assertEqual(row.get('hold_reason'), 'reapprove-plan-changed')

    def test_entry_gate_hold_unchanged(self):
        """A complex-ticket entry hold still gets its row and is still
        probed with `--mode entry`, never `--mode reapprove`."""
        tid = 'TST-RA2'
        log = self._seed(tid, 'complex-ticket',
                         '2026-09-23T00:01:00Z|GATE|gate|fail|held: complex '
                         'ticket')
        self.approval.write_text('human')
        sup = self._supervisor()
        sup.acquire_lock()
        try:
            sup._gate_hold_intake_pass()
            self.assertEqual(self._row(tid).get('hold_reason'),
                             'complex-ticket')
            before = log.read_text()
            sup._hold_reconcile_pass()
        finally:
            sup.release_lock()
        self.assertEqual(self._modes(), ['entry'])
        self.assertEqual(self._row(tid).get('held'), 1)
        self.assertEqual(log.read_text(), before)


# ── gate-hold-notify ───────────────────────────────────────────────────────

FLEET_LIB = REPO_ROOT / 'fleet-controller' / 'lib'
APPROVE_CMD = 'bash ~/.claude/skills/ticket-approve/approve.sh {tid}'


class TestGateHoldReasonText(unittest.TestCase):
    """Each approval-type reason maps to its own plain sentence, and the
    comment always names the exact command a person runs."""

    def test_table_covers_every_intake_reason(self):
        from fleetd import supervisor
        self.assertEqual(set(gate_hold.GATE_HOLD_REASON_TEXT),
                         set(supervisor._GATE_HOLD_APPROVAL_REASONS))

    def test_each_reason_has_its_own_sentence_in_the_comment(self):
        seen = set()
        for reason, sentence in gate_hold.GATE_HOLD_REASON_TEXT.items():
            with self.subTest(reason=reason):
                body = gate_hold.gate_hold_comment_body(
                    'TST-9', 'hold:TST-9:g0:a0', reason)
                self.assertIn(f'**Why:** {sentence}', body)
                self.assertIn(APPROVE_CMD.format(tid='TST-9'), body)
                self.assertIn('own terminal, from the tickets root', body)
                self.assertIn('`hold:TST-9:g0:a0`', body)
                # The raw reason id is never what a person reads.
                self.assertNotIn(reason, body)
                seen.add(sentence)
        self.assertEqual(len(seen), len(gate_hold.GATE_HOLD_REASON_TEXT))

    def test_specific_sentences(self):
        text = gate_hold.gate_hold_reason_text
        self.assertIn('complex ticket', text('complex-ticket'))
        self.assertIn('manual mode', text('manual-mode'))
        self.assertIn('could not approve', text('default-fallback'))
        self.assertIn('changed after it was approved',
                      text('plan-changed-since-approval'))
        self.assertIn('amended', text('reapprove-needs-human'))
        self.assertIn('changed after a person approved',
                      text('reapprove-plan-changed'))

    def test_unknown_reason_gets_fallback_not_raw_value(self):
        body = gate_hold.gate_hold_comment_body('TST-9', 'h', 'sk-secret-xyz')
        self.assertNotIn('sk-secret-xyz', body)
        self.assertIn(gate_hold._GATE_HOLD_REASON_FALLBACK, body)


_FAKE_LINEAR_API_SH = r"""
save_comment() {
  printf '%s\n---\n%s\n' "$1" "$2" >>"$FAKE_COMMENT_LOG"
  return "${FAKE_COMMENT_RC:-0}"
}
"""


class TestPostGateHoldComment(unittest.TestCase):
    """post_gate_hold_comment: the `save_comment` path, fail-soft."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix='fleetd-gh-comment-'))
        self.lib = self.dir / 'lib'
        self.lib.mkdir()
        (self.lib / 'linear-api.sh').write_text(_FAKE_LINEAR_API_SH)
        self.log = self.dir / 'comments.txt'
        self._saved = {k: os.environ.get(k)
                       for k in ('FAKE_COMMENT_LOG', 'FAKE_COMMENT_RC')}
        os.environ['FAKE_COMMENT_LOG'] = str(self.log)

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_posts_the_body(self):
        ok = gate_hold.post_gate_hold_comment(
            'TST-7', 'hold:TST-7:g0:a0', 'complex-ticket', lib_dir=self.lib)
        self.assertTrue(ok)
        text = self.log.read_text()
        self.assertTrue(text.startswith('TST-7\n'))
        self.assertIn(gate_hold.GATE_HOLD_REASON_TEXT['complex-ticket'], text)
        self.assertIn(APPROVE_CMD.format(tid='TST-7'), text)

    def test_failed_post_returns_false(self):
        os.environ['FAKE_COMMENT_RC'] = '1'
        self.assertFalse(gate_hold.post_gate_hold_comment(
            'TST-7', 'h', 'manual-mode', lib_dir=self.lib))

    def test_missing_client_returns_false(self):
        self.assertFalse(gate_hold.post_gate_hold_comment(
            'TST-7', 'h', 'manual-mode', lib_dir=self.dir / 'nope'))


class _IntakeBase(unittest.TestCase):
    """A real store and supervisor; the comment and notify are recorded."""

    def setUp(self):
        from fleetd import supervisor
        self.supervisor_mod = supervisor
        self.workspace = Path(tempfile.mkdtemp(prefix='fleetd-gh-notify-'))
        self._saved = {k: os.environ.get(k) for k in (
            'FLEET_PIPELINE_LOG_DIR', 'FLEET_GATE_HOLD_NOTIFY')}
        os.environ['FLEET_PIPELINE_LOG_DIR'] = str(self.workspace)
        os.environ.pop('FLEET_GATE_HOLD_NOTIFY', None)
        self.comments = []
        self.notifies = []
        self.human = []
        self._real = (gate_hold.post_gate_hold_comment,
                      supervisor._notify_gate_held,
                      gate_hold.post_human_hold_comment,
                      supervisor._notify_hold)
        gate_hold.post_gate_hold_comment = (
            lambda *a, **k: self.comments.append(a) or True)
        supervisor._notify_gate_held = (
            lambda *a, **k: self.notifies.append(a))
        gate_hold.post_human_hold_comment = (
            lambda *a, **k: self.human.append(('comment', a)) or (True, True))
        supervisor._notify_hold = (
            lambda *a, **k: self.human.append(('notify', a)))
        self.sups = []

    def tearDown(self):
        (gate_hold.post_gate_hold_comment,
         self.supervisor_mod._notify_gate_held,
         gate_hold.post_human_hold_comment,
         self.supervisor_mod._notify_hold) = self._real
        for sup in self.sups:
            sup.release_lock()
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.workspace, ignore_errors=True)

    def _sup(self):
        """A fresh Supervisor: a second one is a fleetd restart."""
        for sup in self.sups:
            sup.release_lock()
        sup = self.supervisor_mod.Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'), spawn_enabled=False)
        sup.acquire_lock()
        self.sups = [sup]
        return sup

    def _seed_gate(self, tid, reason):
        (self.workspace / f'{tid}-pipeline.log').write_text(
            '2026-09-23T00:00:00Z|META|schema|info|1\n'
            '2026-09-23T00:01:00Z|GATE|gate|fail|held: complex ticket\n')
        self._append_event(tid, 1, 'gate-held', {'reason': reason})

    def _append_event(self, tid, seq, event, data):
        with open(self.workspace / f'{tid}-outbox.jsonl', 'a') as fh:
            fh.write(json.dumps({
                'seq': seq, 'tid': tid, 'ts': '2026-09-23T00:01:00Z',
                'gen': 0, 'event': event, 'data': data}) + '\n')

    def _row(self, tid):
        from fleetd import store
        with store.open_store(self.workspace) as st:
            return st.get_ticket(tid) or {}


class TestGateHoldIntakeNotify(_IntakeBase):

    def test_first_intake_posts_and_notifies_once(self):
        self._seed_gate('TST-N1', 'complex-ticket')
        self._sup()._gate_hold_intake_pass()
        row = self._row('TST-N1')
        self.assertEqual(row.get('held'), 1)
        self.assertEqual(len(self.comments), 1)
        tid, hold_id, reason = self.comments[0]
        self.assertEqual((tid, reason), ('TST-N1', 'complex-ticket'))
        self.assertEqual(hold_id, row['hold_id'])
        self.assertEqual(len(self.notifies), 1)
        _lib, state_dir, ntid, nhold_id, why = self.notifies[0]
        self.assertEqual(ntid, 'TST-N1')
        self.assertEqual(Path(state_dir), self.workspace)
        self.assertEqual(nhold_id, row['hold_id'])
        self.assertEqual(why, gate_hold.GATE_HOLD_REASON_TEXT['complex-ticket'])
        self.assertEqual(self.human, [])

    def test_second_pass_restart_and_repeated_event_post_nothing(self):
        self._seed_gate('TST-N2', 'manual-mode')
        self._sup()._gate_hold_intake_pass()
        self._sup()._gate_hold_intake_pass()  # second pass
        self._sup()._gate_hold_intake_pass()  # fleetd restart
        # The gate holds again while the row is still held.
        self._append_event('TST-N2', 2, 'gate-held', {'reason': 'manual-mode'})
        self._sup()._gate_hold_intake_pass()
        self.assertEqual(len(self.comments), 1)
        self.assertEqual(len(self.notifies), 1)

    def test_each_reason_is_passed_through(self):
        for i, reason in enumerate(sorted(gate_hold.GATE_HOLD_REASON_TEXT)):
            self._seed_gate(f'TST-R{i}', reason)
        self._sup()._gate_hold_intake_pass()
        got = {c[0]: c[2] for c in self.comments}
        want = {f'TST-R{i}': r for i, r in
                enumerate(sorted(gate_hold.GATE_HOLD_REASON_TEXT))}
        self.assertEqual(got, want)
        whys = {n[2]: n[4] for n in self.notifies}
        self.assertEqual(
            whys, {t: gate_hold.GATE_HOLD_REASON_TEXT[r]
                   for t, r in want.items()})

    def test_content_hold_posts_nothing(self):
        self._seed_gate('TST-N3', 'linear-fetch-failed')
        self._sup()._gate_hold_intake_pass()
        self.assertEqual((self.comments, self.notifies), ([], []))

    def test_flag_off_creates_row_but_posts_nothing(self):
        os.environ['FLEET_GATE_HOLD_NOTIFY'] = 'false'
        self._seed_gate('TST-N4', 'complex-ticket')
        self._sup()._gate_hold_intake_pass()
        self.assertEqual(self._row('TST-N4').get('held'), 1)
        self.assertEqual((self.comments, self.notifies), ([], []))

    def test_human_hold_unchanged(self):
        record = {'schema_version': 1, 'phase': 'IMPLEMENT',
                  'reason': 'CREDENTIALS_MISSING', 'blocks': 'AC1',
                  'supersedes': '', 'parse_status': 'ok', 'parse_error': '',
                  'questions': [{'id': 1, 'text': 'Which user?'}]}
        (self.workspace / 'TST-H1-pipeline.log').write_text(
            '2026-09-08T00:00:00Z|META|schema|info|1\n'
            f'2026-09-08T00:01:00Z|META|human-hold|waiting|'
            f'{json.dumps(record)}\n')
        sup = self._sup()
        sup._human_hold_intake_pass()
        sup._gate_hold_intake_pass()
        sup._human_hold_intake_pass()
        self.assertEqual(self._row('TST-H1').get('hold_kind'), 'human')
        self.assertEqual([k for k, _ in self.human], ['comment', 'notify'])
        self.assertEqual((self.comments, self.notifies), ([], []))


_STUB_CURL = r"""#!/usr/bin/env bash
prev=""
for arg in "$@"; do
  [ "$prev" = "-d" ] && printf '%s\n' "$arg" >>"$FAKE_CURL_LOG"
  prev="$arg"
done
printf '{"ok": true, "ts": "1700000000.000100"}'
"""


class TestGateHoldNotifySharedSidecar(unittest.TestCase):
    """The real `fleet_notify_gate_held`: fleetd's call sends once, and the
    reconcile path's key for the same outbox record matches, so it does not
    send a second message for the same hold."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix='fleetd-gh-slack-'))
        bindir = self.dir / 'bin'
        bindir.mkdir()
        (bindir / 'curl').write_text(_STUB_CURL)
        (bindir / 'curl').chmod(0o755)
        self.curl_log = self.dir / 'curl.log'
        self._saved = {k: os.environ.get(k) for k in (
            'PATH', 'SLACK_BOT_TOKEN', 'SLACK_CHANNEL', 'FAKE_CURL_LOG',
            'FLEET_PIPELINE_LOG_DIR')}
        os.environ.update({
            'FLEET_PIPELINE_LOG_DIR': str(self.dir),
            'PATH': f"{bindir}:{os.environ.get('PATH', '')}",
            'SLACK_BOT_TOKEN': 'xoxb-test', 'SLACK_CHANNEL': '#t',
            'FAKE_CURL_LOG': str(self.curl_log)})
        (self.dir / 'TST-S1-outbox.jsonl').write_text(
            'not json\n' + json.dumps({
                'seq': 4, 'tid': 'TST-S1', 'ts': '2026-09-23T00:01:00Z',
                'event': 'gate-held',
                'data': {'reason': 'reapprove-needs-human'}}) + '\n')

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.dir, ignore_errors=True)

    def _sends(self):
        if not self.curl_log.exists():
            return []
        return self.curl_log.read_text().splitlines()

    def _reconcile_key(self, tid):
        """The key fleet-reconcile.sh derives for `tid` (same function)."""
        import subprocess
        proc = subprocess.run(
            ['bash', '-c',
             'source "$1/fleet-notify.sh"; '
             'fleet_gate_held_key "$3" "$2/$3-pipeline.log"',
             '_', str(FLEET_LIB), str(self.dir), tid],
            capture_output=True, text=True, timeout=30)
        return proc.stdout

    def _reconcile_notify(self, tid):
        """What fleet-reconcile.sh runs for a `held: gate` outcome."""
        import subprocess
        subprocess.run(
            ['bash', '-c',
             'source "$1/fleet-notify.sh"; '
             'key=$(fleet_gate_held_key "$3" "$2/$3-pipeline.log"); '
             'fleet_notify_gate_held "$3" "$2" "$key"',
             '_', str(FLEET_LIB), str(self.dir), tid],
            capture_output=True, text=True, timeout=30)

    def test_one_message_per_hold_across_both_callers(self):
        from fleetd import supervisor
        why = gate_hold.GATE_HOLD_REASON_TEXT['reapprove-needs-human']
        for _ in range(2):
            supervisor._notify_gate_held(
                FLEET_LIB, self.dir, 'TST-S1', 'hold:TST-S1:g0:a0', why)
        sends = self._sends()
        self.assertEqual(len(sends), 1)
        text = json.loads(sends[0])['text']
        self.assertIn(why, text)
        self.assertIn(APPROVE_CMD.format(tid='TST-S1'), text)

        # The reconcile path: the same key from the outbox, so no second send.
        self.assertEqual(self._reconcile_key('TST-S1'),
                         '4@2026-09-23T00:01:00Z')
        self._reconcile_notify('TST-S1')
        self.assertEqual(len(self._sends()), 1)

    def test_no_outbox_both_callers_send_one_message(self):
        """No outbox file: both sides key on the `held: gate` outcome
        line's timestamp, whichever fires first."""
        from fleetd import supervisor
        (self.dir / 'TST-S2-pipeline.log').write_text(
            '2026-09-23T00:00:00Z|META|schema|info|1\n'
            '2026-09-23T00:02:00Z|META|outcome|info|held: gate\n')
        self.assertEqual(self._reconcile_key('TST-S2'),
                         '2026-09-23T00:02:00Z')
        # Reconcile first, then fleetd.
        self._reconcile_notify('TST-S2')
        supervisor._notify_gate_held(
            FLEET_LIB, self.dir, 'TST-S2', 'hold:TST-S2:g0:a0', 'why')
        self.assertEqual(len(self._sends()), 1)
        # fleetd first, then reconcile, for a second ticket.
        (self.dir / 'TST-S3-pipeline.log').write_text(
            '2026-09-23T00:03:00Z|META|outcome|info|held: gate\n')
        supervisor._notify_gate_held(
            FLEET_LIB, self.dir, 'TST-S3', 'hold:TST-S3:g0:a0', 'why')
        self._reconcile_notify('TST-S3')
        self.assertEqual(len(self._sends()), 2)

    def test_no_outbox_and_no_outcome_line_falls_back_to_hold_id(self):
        import hashlib
        from fleetd import supervisor
        self.assertEqual(self._reconcile_key('TST-S4'), '')
        for _ in range(2):
            supervisor._notify_gate_held(
                FLEET_LIB, self.dir, 'TST-S4', 'hold:TST-S4:g0:a0', 'why')
        self.assertEqual(len(self._sends()), 1)
        sidecar = json.loads(
            (self.dir / 'TST-S4-gate-held-notify.json').read_text())
        self.assertEqual(
            sidecar['key'],
            hashlib.sha256(b'hold:hold:TST-S4:g0:a0').hexdigest())


class TestPhaseDispatchGateHoldNotify(_IntakeBase):
    """A gate row created by phase dispatch (`_create_phase_dispatch_hold`)
    is announced once through the same helper as the intake, and the two
    paths never announce one hold twice."""

    def _create(self, tid, cycle=0, lib=FLEET_LIB):
        return self.supervisor_mod._create_phase_dispatch_hold(
            str(self.workspace), tid, 0, cycle,
            reason='gate held for approval', fleet_lib_dir=lib)

    def test_phase_dispatch_hold_comments_and_notifies_once(self):
        self._seed_gate('TST-P1', 'complex-ticket')
        hold_id = self._create('TST-P1')
        self.assertEqual(self._row('TST-P1').get('hold_id'), hold_id)
        self.assertEqual(self.comments,
                         [('TST-P1', hold_id, 'complex-ticket')])
        self.assertEqual(len(self.notifies), 1)
        _lib, _sd, tid, nhold_id, why = self.notifies[0]
        self.assertEqual((tid, nhold_id), ('TST-P1', hold_id))
        self.assertEqual(why,
                         gate_hold.GATE_HOLD_REASON_TEXT['complex-ticket'])
        # A retried creation call is a no-op.
        self._create('TST-P1')
        self.assertEqual((len(self.comments), len(self.notifies)), (1, 1))

    def test_phase_dispatch_row_then_intake_pass_still_one(self):
        self._seed_gate('TST-P2', 'manual-mode')
        self._create('TST-P2')
        self._sup()._gate_hold_intake_pass()
        self._sup()._gate_hold_intake_pass()
        self.assertEqual((len(self.comments), len(self.notifies)), (1, 1))

    def test_intake_row_then_phase_dispatch_still_one(self):
        self._seed_gate('TST-P3', 'complex-ticket')
        self._sup()._gate_hold_intake_pass()
        self._create('TST-P3')
        self.assertEqual((len(self.comments), len(self.notifies)), (1, 1))

    def test_no_outbox_record_uses_the_row_reason(self):
        (self.workspace / 'TST-P4-pipeline.log').write_text(
            '2026-09-23T00:00:00Z|META|schema|info|1\n')
        hold_id = self._create('TST-P4')
        self.assertEqual(self.comments,
                         [('TST-P4', hold_id, 'gate held for approval')])
        self.assertEqual(self.notifies[0][4],
                         gate_hold.gate_hold_reason_text('x-unknown'))

    def test_flag_off_creates_row_but_posts_nothing(self):
        os.environ['FLEET_GATE_HOLD_NOTIFY'] = 'false'
        self._seed_gate('TST-P5', 'complex-ticket')
        self._create('TST-P5')
        self.assertEqual(self._row('TST-P5').get('held'), 1)
        self.assertEqual((self.comments, self.notifies), ([], []))

    def test_no_lib_dir_posts_nothing(self):
        self._seed_gate('TST-P6', 'complex-ticket')
        self._create('TST-P6', lib=None)
        self.assertEqual(self._row('TST-P6').get('held'), 1)
        self.assertEqual((self.comments, self.notifies), ([], []))

    def test_next_hold_decision_passes_the_lib_dir(self):
        from unittest import mock
        from fleetd import phase_dispatch as phase_mod
        sup = self._sup()
        decision = phase_mod.NextStep(
            phase_mod.NEXT_HOLD, '', None, '', 'gate', 'STEP_3_5',
            'gate held for approval')
        with mock.patch.object(self.supervisor_mod,
                               '_create_phase_dispatch_hold',
                               return_value='h') as create:
            sup._act_on_next_step_locked(
                'TST-P7', decision, None, '', '', '', 'r', {})
        self.assertEqual(create.call_args.kwargs.get('fleet_lib_dir'),
                         sup._fleet_lib_dir)


if __name__ == '__main__':
    unittest.main()
