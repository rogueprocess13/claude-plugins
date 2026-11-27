"""The router's independent plan review (STEP_2_2, GitHub #667) as fleetd's
phase dispatch sees it.

Phase dispatch does not run the step. These tests hold the three places that
must agree with the router about that:

- `plan_review_router` reads the per-ticket decision exactly as bash's
  `plan-review.sh mode` does (parity, run against the real script);
- `next_step` sends EXEC to STEP_2_2, never to the gate, for a ticket the
  router marked, because EXEC skipped its inline review there;
- the supervisor leaves such a ticket at STEP_2_2 with a logged reason and
  spawns nothing.

No worker is forked and no model runs.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

os.environ.setdefault('FLEET_STARTUP_ENV_CHECK', 'false')

from fleetd import phase_dispatch as phase_mod  # noqa: E402
from fleetd import supervisor as sup_mod  # noqa: E402
from fleetd.phase_dispatch import (  # noqa: E402
    NEXT_ADVANCE, DispatchTable, DispatchTableError, PhaseOutcome, next_step,
    plan_review_router,
)

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
PLAN_REVIEW_SH = REPO_ROOT / 'ticket-auto-pipeline' / 'lib' / 'plan-review.sh'
# This checkout's table, never an installed copy: DispatchTable.load() with
# no argument prefers ~/.claude/skills when it exists.
TABLE_PATH = (REPO_ROOT / 'ticket-auto-pipeline' / 'skills' / 'ticket-flow'
              / 'dispatch-table.json')

_TS = '2026-11-20T10:00:00Z'

# (name, log body lines without the timestamp, expected router mode)
_MODE_CASES = [
    ('no line', ['META|schema|info|1'], False),
    ('router', ['META|schema|info|1', 'META|plan-review|info|router'], True),
    ('router, every ticket (flag true)',
     ['META|plan-review|info|router — every ticket'], True),
    ('inline, fleetd phase dispatch',
     ['META|plan-review|info|inline — fleetd phase dispatch does not run '
      'STEP_2_2; the review stays in ticket-appraise-exec Step 3.6'], False),
    ('the last line decides',
     ['META|plan-review|info|router', 'META|plan-review|info|inline'], False),
    ('another status is not the decision',
     ['META|plan-review|warn|router'], False),
    ('a longer word is not router',
     ['META|plan-review|info|routerish'], False),
    ('an EXEC step of the same name is not the decision',
     ['EXEC|plan-review|done|router'], False),
]


def _lines(body):
    return [f'{_TS}|{line}' for line in body]


class ModeParityTest(unittest.TestCase):
    """`plan_review_router` and `plan-review.sh mode` on the same logs."""

    def test_python_and_bash_agree_on_every_case(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name, body, expected in _MODE_CASES:
                with self.subTest(case=name):
                    log = Path(tmp) / 'T-1-pipeline.log'
                    log.write_text('\n'.join(_lines(body)) + '\n')
                    bash = subprocess.run(
                        ['bash', str(PLAN_REVIEW_SH), 'mode',
                         '--log-file', str(log)],
                        capture_output=True, text=True, timeout=30)
                    self.assertEqual(bash.returncode, 0, bash.stderr)
                    self.assertEqual(bash.stdout.strip(),
                                     'router' if expected else 'inline')
                    self.assertIs(plan_review_router(_lines(body)), expected)


class NextStepTest(unittest.TestCase):

    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)
        self.done = PhaseOutcome('done', '', 'exit-code', 'test')

    def test_exec_goes_to_the_gate_without_the_router_mark(self):
        r = next_step(self.table, 'STEP_2', self.done, {})
        self.assertEqual((r.kind, r.step_id), (NEXT_ADVANCE, 'STEP_2_5'))

    def test_exec_goes_to_the_plan_review_with_the_router_mark(self):
        r = next_step(self.table, 'STEP_2', self.done, {}, plan_review=True)
        self.assertEqual((r.kind, r.step_id), (NEXT_ADVANCE, 'STEP_2_2'))

    def test_step_2_2_has_no_transition_under_phase_dispatch(self):
        with self.assertRaises(DispatchTableError):
            next_step(self.table, 'STEP_2_2', self.done, {})

    def test_the_table_says_phase_dispatch_does_not_run_it(self):
        step = self.table.get('STEP_2_2')
        self.assertEqual(step.get('phase_dispatch'), 'manual-pickup')
        self.assertEqual(self.table.phase_of('STEP_2_2'), 'EXEC')
        # Not one of evaluate_loop's loops: plan-review.sh counts its cap.
        self.assertNotIn('STEP_2_2', self.table.loop_steps())
        # No other step is marked: the skip is this step's alone.
        marked = [s for s in self.table.step_ids()
                  if self.table.get(s).get('phase_dispatch')]
        self.assertEqual(marked, ['STEP_2_2'])


class SupervisorTest(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.log_file = self.state_dir / 'T-1-pipeline.log'
        self.log_file.write_text('\n'.join(_lines(
            ['META|schema|info|1', 'META|plan-review|info|router',
             'EXEC|create-artifact|done|openspec'])) + '\n')
        env = mock.patch.dict(os.environ,
                              {'FLEET_DISPATCH_TABLE': str(TABLE_PATH)})
        env.start()
        self.addCleanup(env.stop)

    def tearDown(self):
        shutil.rmtree(self._tmp.name, ignore_errors=True)

    def _sup(self):
        return sup_mod.Supervisor(state_dir=str(self.state_dir),
                                  pidfile=str(self.state_dir / 'test.pid'))

    def test_step_2_2_is_left_for_the_router_with_a_logged_reason(self):
        sup = self._sup()
        table = phase_mod.DispatchTable.load(TABLE_PATH)
        with mock.patch.object(sup, 'spawn_phase') as spawn_phase, \
                mock.patch.object(phase_mod, 'run_gate_check') as gate:
            first = sup._dispatch_step_locked(
                'T-1', 'STEP_2_2', table, str(self.log_file), '', '', 'd')
            second = sup._dispatch_step_locked(
                'T-1', 'STEP_2_2', table, str(self.log_file), '', '', 'd')
        self.assertFalse(first)
        self.assertFalse(second)
        spawn_phase.assert_not_called()
        gate.assert_not_called()
        text = self.log_file.read_text()
        # Said once, however many passes find the ticket there.
        self.assertEqual(
            text.count('|META|phase-dispatch-skip|warn|STEP_2_2 is not run '
                       'by fleetd phase dispatch'), 1)
        position = sup_mod._store_get_position(str(self.state_dir), 'T-1')
        self.assertEqual(position['position'], 'STEP_2_2')

    def test_a_reaped_exec_advances_to_step_2_2_not_the_gate(self):
        sup = self._sup()
        entry = {'phase': 'EXEC', 'step_id': 'STEP_2',
                 'log_file': str(self.log_file), 'hb_log_file': '',
                 'env_file': '', 'reason': 'd', 'log_line_offset': 0,
                 'generation': 1}
        with mock.patch.object(sup, '_dispatch_step_locked') as dispatch:
            sup._advance_phase_dispatch_locked('T-1', entry, 0, 'exit')
        self.assertEqual(dispatch.call_args[0][1], 'STEP_2_2')

    def test_a_reaped_exec_goes_to_the_gate_when_the_review_is_inline(self):
        self.log_file.write_text('\n'.join(_lines(
            ['META|schema|info|1',
             'META|plan-review|info|inline — fleetd phase dispatch does not '
             'run STEP_2_2', 'EXEC|create-artifact|done|openspec'])) + '\n')
        sup = self._sup()
        entry = {'phase': 'EXEC', 'step_id': 'STEP_2',
                 'log_file': str(self.log_file), 'hb_log_file': '',
                 'env_file': '', 'reason': 'd', 'log_line_offset': 0,
                 'generation': 1}
        with mock.patch.object(sup, '_dispatch_step_locked') as dispatch:
            sup._advance_phase_dispatch_locked('T-1', entry, 0, 'exit')
        self.assertEqual(dispatch.call_args[0][1], 'STEP_2_5')


if __name__ == '__main__':
    unittest.main()
