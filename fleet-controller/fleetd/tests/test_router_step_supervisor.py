"""Supervisor wiring for FLEET_ROUTER_STEP_SHELL (fleetd-shared-router-steps
task 4). Kept out of test_supervisor.py on purpose (design.md decision 7):
every router_step call is stubbed and no worker is ever forked.
"""

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

os.environ.setdefault('FLEET_STARTUP_ENV_CHECK', 'false')

from fleetd import phase_dispatch as phase_mod  # noqa: E402
from fleetd import router_step  # noqa: E402
from fleetd import supervisor as sup_mod  # noqa: E402


def _phase_result_line(phase, verdict):
    payload = {'schema_version': 1, 'phase': phase, 'verifier': 'x',
               'claimed_verdict': verdict, 'parse_status': 'ok',
               'parse_error': ''}
    return f'2026-11-11T10:00:00Z|META|phase-result|info|{json.dumps(payload)}\n'


class _Base(unittest.TestCase):

    flag = 'true'

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.log_file = self.state_dir / 'T-1-pipeline.log'
        self.log_file.write_text('')
        env = mock.patch.dict(os.environ, {router_step.FLAG: self.flag})
        env.start()
        self.addCleanup(env.stop)

    def tearDown(self):
        shutil.rmtree(self._tmp.name, ignore_errors=True)

    def _sup(self):
        return sup_mod.Supervisor(state_dir=str(self.state_dir),
                                  pidfile=str(self.state_dir / 'test.pid'))

    def _table(self):
        return phase_mod.DispatchTable.load()

    def _entry(self, step_id, phase, **extra):
        entry = {'phase': phase, 'step_id': step_id,
                 'log_file': str(self.log_file), 'hb_log_file': '',
                 'env_file': '', 'reason': 'dispatched', 'log_line_offset': 0,
                 'generation': 1}
        entry.update(extra)
        return entry


_SKIP = router_step.Inspector(True, 'skip', '', '')


class RetroCheckWiringTest(_Base):

    def test_flag_on_uses_the_script_not_the_port(self):
        decision = router_step.RetroCheck(True, ('VERIFY fail',), False, True, '')
        sup = self._sup()
        with mock.patch.object(router_step, 'retro_check',
                               return_value=decision) as rc, \
                mock.patch.object(phase_mod, 'needs_retro') as port, \
                mock.patch.object(sup, 'spawn_phase') as spawn_phase:
            self.assertTrue(sup._dispatch_step_locked(
                'T-1', 'STEP_6', self._table(), str(self.log_file), 'hb', '',
                'dispatched'))
        rc.assert_called_once_with(str(self.log_file), 'hb')
        port.assert_not_called()
        self.assertEqual(spawn_phase.call_args[0][1], 'STEP_6')

    def test_drift_line_is_the_routers_text(self):
        decision = router_step.RetroCheck(False, (), True, True, '')
        sup = self._sup()
        with mock.patch.object(router_step, 'retro_check',
                               return_value=decision), \
                mock.patch.object(sup_mod._orchestration_mod,
                                  'finalize_terminal'):
            sup._dispatch_step_locked('T-1', 'STEP_6', self._table(),
                                      str(self.log_file), '', '', 'd')
        self.assertIn(f'|META|drift|warn|{sup_mod.RETRO_DRIFT_MSG}',
                      self.log_file.read_text())

    def test_script_missing_finalizes_without_retro(self):
        sup = self._sup()
        with tempfile.TemporaryDirectory() as empty, \
                mock.patch.object(router_step, 'lib_dir_path',
                                  return_value=Path(empty)), \
                mock.patch.object(sup_mod._orchestration_mod,
                                  'finalize_terminal') as fin, \
                mock.patch.object(sup, 'spawn_phase') as spawn_phase:
            sup._dispatch_step_locked('T-1', 'STEP_6', self._table(),
                                      str(self.log_file), '', '', 'd')
        spawn_phase.assert_not_called()
        self.assertEqual(fin.call_args[0][2], 0)


class PostSpawnAndInspectorWiringTest(_Base):

    def test_post_spawn_runs_before_classification(self):
        # The script's META|phase-result line is what classify_phase reads:
        # a VERIFY PASS claim advances despite a non-zero worker exit.
        def _post_spawn(phase, tid, log_file, text, **kw):
            with open(log_file, 'a') as fh:
                fh.write(_phase_result_line('VERIFY', 'PASS'))
            return router_step.PostSpawn(True, '', '')

        sup = self._sup()
        with mock.patch.object(router_step, 'post_spawn',
                               side_effect=_post_spawn) as ps, \
                mock.patch.object(router_step, 'inspector',
                                  return_value=_SKIP), \
                mock.patch.object(sup, 'spawn_phase') as spawn_phase:
            sup._advance_phase_dispatch_locked(
                'T-1', self._entry('STEP_4_5', 'VERIFY'), 1, 'exit')
        self.assertEqual(ps.call_args[0][0], 'VERIFY')
        self.assertEqual(ps.call_args[1]['attempt'], 1)
        self.assertEqual(spawn_phase.call_args[0][1], 'STEP_4_6')

    def test_post_spawn_failure_falls_back_to_the_exit_code_rung(self):
        sup = self._sup()
        with mock.patch.object(
                router_step, 'post_spawn',
                return_value=router_step.PostSpawn(False, '', 'timed out')), \
                mock.patch.object(router_step, 'inspector',
                                  return_value=_SKIP), \
                mock.patch.object(sup, 'spawn_phase') as spawn_phase:
            sup._advance_phase_dispatch_locked(
                'T-1', self._entry('STEP_4_5', 'VERIFY'), 1, 'exit')
        # No phase-result, exit 1 → fail → retry implement.
        self.assertEqual(spawn_phase.call_args[0][1], 'STEP_4')

    def test_inspector_ready_defers_the_decision_to_the_inspector_reap(self):
        instructions = self.state_dir / 'insp.txt'
        instructions.write_text('inspect it')
        ready = router_step.Inspector(True, 'IMPLEMENT', str(instructions), '')
        sup = self._sup()
        with mock.patch.object(router_step, 'post_spawn',
                               return_value=router_step.PostSpawn(True, 'complete', '')), \
                mock.patch.object(router_step, 'inspector', return_value=ready), \
                mock.patch.object(sup, 'spawn_router_aux') as aux_spawn, \
                mock.patch.object(sup, 'spawn_phase') as spawn_phase:
            sup._advance_phase_dispatch_locked(
                'T-1', self._entry('STEP_4', 'IMPLEMENT'), 0, 'exit')
        spawn_phase.assert_not_called()
        spawn = aux_spawn.call_args[0][1]
        self.assertEqual(spawn.step_id, router_step.INSPECTOR_STEP_ID)
        self.assertIn('inspect it', spawn.prompt)
        aux = aux_spawn.call_args[1]['aux']
        self.assertEqual(aux['decision'].step_id, 'STEP_4_5')
        # A restart mid-inspector resumes at the next step, not IMPLEMENT.
        position = sup_mod._store_get_position(str(self.state_dir), 'T-1')
        self.assertEqual(position['position'], 'STEP_4_5')

        # The inspector worker is reaped: inspector-done, then the decision.
        entry = self._entry(router_step.INSPECTOR_STEP_ID, 'IMPLEMENT', aux=aux)
        with mock.patch.object(router_step, 'inspector_done') as done, \
                mock.patch.object(sup, 'spawn_phase') as spawn_phase:
            sup._advance_phase_dispatch_locked('T-1', entry, 0, 'exit')
        self.assertEqual(done.call_args[0][:2], ('IMPLEMENT', 'T-1'))
        self.assertEqual(spawn_phase.call_args[0][1], 'STEP_4_5')

    def test_inspector_spawn_failure_does_not_block_the_advance(self):
        instructions = self.state_dir / 'insp.txt'
        instructions.write_text('x')
        ready = router_step.Inspector(True, 'VERIFY', str(instructions), '')
        sup = self._sup()
        with mock.patch.object(router_step, 'post_spawn',
                               return_value=router_step.PostSpawn(True, '', '')), \
                mock.patch.object(router_step, 'inspector', return_value=ready), \
                mock.patch.object(sup, 'spawn_router_aux',
                                  side_effect=sup_mod.SpawnError('no claude')), \
                mock.patch.object(sup, 'spawn_phase') as spawn_phase:
            sup._advance_phase_dispatch_locked(
                'T-1', self._entry('STEP_4_5', 'VERIFY'), 1, 'exit')
        # Decision from the verify outcome alone (no phase-result, exit 1).
        self.assertEqual(spawn_phase.call_args[0][1], 'STEP_4')

    def test_non_inspected_phase_runs_no_router_step(self):
        sup = self._sup()
        with mock.patch.object(router_step, 'post_spawn') as ps, \
                mock.patch.object(router_step, 'inspector') as insp, \
                mock.patch.object(sup, 'spawn_phase'):
            sup._advance_phase_dispatch_locked(
                'T-1', self._entry('STEP_2', 'EXEC'), 0, 'exit')
        ps.assert_not_called()
        insp.assert_not_called()


class PrescanWiringTest(_Base):

    def test_stale_repo_spawns_prescan_then_dispatches_the_pending_step(self):
        gates = [router_step.PrescanGate(True, '/r/a', 'a', 'stale', ''),
                 router_step.PrescanGate(True, '', '', '', '')]
        sup = self._sup()
        with mock.patch.object(router_step, 'prescan_gate',
                               side_effect=gates) as gate, \
                mock.patch.object(sup, 'spawn_router_aux') as aux_spawn:
            spawned = sup._router_step_prescan_locked(
                'T-1', 'STEP_1', self._table(), str(self.log_file), '', '',
                'd', '/r', 'develop')
        self.assertTrue(spawned)
        self.assertEqual(gate.call_args[1]['resume_step'], 'STEP_1')
        aux = aux_spawn.call_args[1]['aux']
        self.assertEqual((aux['kind'], aux['pending_step_id']),
                         ('prescan', 'STEP_1'))

        entry = self._entry(router_step.PRESCAN_STEP_ID, 'MAINTENANCE', aux=aux)
        with mock.patch.object(router_step, 'prescan_gate',
                               side_effect=gates[1:]) as gate2, \
                mock.patch.object(router_step, 'prescan_done') as done, \
                mock.patch.object(sup, '_dispatch_step_locked') as dispatch:
            sup._advance_phase_dispatch_locked('T-1', entry, 0, 'exit')
        self.assertEqual(done.call_args[0][:3], ('T-1', 'a', 'stale'))
        self.assertEqual(gate2.call_args[1]['after'], '/r/a')
        self.assertEqual(dispatch.call_args[0][1], 'STEP_1')

    def test_nothing_stale_spawns_nothing(self):
        sup = self._sup()
        with mock.patch.object(router_step, 'prescan_gate',
                               return_value=router_step.PrescanGate(
                                   False, '', '', '', 'failed')), \
                mock.patch.object(sup, 'spawn_router_aux') as aux_spawn:
            self.assertFalse(sup._router_step_prescan_locked(
                'T-1', 'STEP_1', self._table(), str(self.log_file), '', '',
                'd', '/r', ''))
        aux_spawn.assert_not_called()


class FlagOffTest(_Base):

    flag = 'false'

    def test_flag_off_invokes_no_router_step(self):
        sup = self._sup()
        decision = phase_mod.RetroDecision(False, (), False)
        with mock.patch.object(router_step, '_run') as run, \
                mock.patch.object(phase_mod, 'needs_retro',
                                  return_value=decision) as port, \
                mock.patch.object(sup_mod._orchestration_mod,
                                  'finalize_terminal'), \
                mock.patch.object(sup, 'spawn_phase'):
            sup._dispatch_step_locked('T-1', 'STEP_6', self._table(),
                                      str(self.log_file), '', '', 'd')
            sup._advance_phase_dispatch_locked(
                'T-1', self._entry('STEP_4_5', 'VERIFY'), 1, 'exit')
        port.assert_called_once()
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
