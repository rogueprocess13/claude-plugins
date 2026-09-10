"""
Tests for fleetd's entry point (fleetd/__main__.py), scoped to
`_run_startup_env_check` — the process-start gate on `lib/fleet-env-check.sh`.

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_main.py -v

Covers issue #341 finding 3: a startup gate failure used to reach only
stderr, which nothing reads for an unattended cron/systemd restart. These
tests assert the Slack notify call fires (or doesn't) alongside the existing
stderr/exit behavior — never in place of it.
"""

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import __main__ as main_mod  # noqa: E402


class TestRunStartupEnvCheck(unittest.TestCase):

    def _run(self, returncode, state_dir='/tmp/fake-state-dir'):
        calls = []
        with mock.patch.object(main_mod, '_notify_gate_stop',
                               lambda *a, **kw: calls.append((a, kw))), \
             mock.patch.object(main_mod.subprocess, 'run') as run_mock, \
             mock.patch.object(sys, 'exit', side_effect=SystemExit) as exit_mock:
            run_mock.return_value = mock.Mock(
                returncode=returncode, stdout='NAME|FAIL|reason', stderr='')
            raised = False
            try:
                main_mod._run_startup_env_check(state_dir)
            except SystemExit:
                raised = True
        return calls, exit_mock.called, raised

    def test_failure_notifies_and_exits(self):
        calls, exited, raised = self._run(returncode=1)
        self.assertTrue(exited)
        self.assertTrue(raised)
        self.assertEqual(len(calls), 1)
        args, kwargs = calls[0]
        # (fleet_lib_dir, state_dir, tid, gate_stop_code, detail)
        self.assertEqual(args[2], main_mod._STARTUP_PSEUDO_TID)
        self.assertEqual(args[3], 'FLEETD_STARTUP_ENV_CHECK_FAILED')

    def test_success_does_not_notify_or_exit(self):
        calls, exited, raised = self._run(returncode=0)
        self.assertFalse(exited)
        self.assertFalse(raised)
        self.assertEqual(calls, [])

    def test_opt_out_skips_the_check_entirely(self):
        with mock.patch.dict('os.environ', {'FLEET_STARTUP_ENV_CHECK': 'false'}), \
             mock.patch.object(main_mod, '_notify_gate_stop') as notify, \
             mock.patch.object(main_mod.subprocess, 'run') as run_mock:
            main_mod._run_startup_env_check('/tmp/fake-state-dir')
        run_mock.assert_not_called()
        notify.assert_not_called()

    def test_missing_state_dir_falls_back_to_resolve_state_dir(self):
        with mock.patch.object(main_mod, '_resolve_state_dir',
                               return_value=Path('/tmp/resolved')) as resolve, \
             mock.patch.object(main_mod, '_notify_gate_stop') as notify, \
             mock.patch.object(main_mod.subprocess, 'run') as run_mock, \
             mock.patch.object(sys, 'exit', side_effect=SystemExit):
            run_mock.return_value = mock.Mock(returncode=1, stdout='', stderr='')
            try:
                main_mod._run_startup_env_check(None)
            except SystemExit:
                pass
        resolve.assert_called_once()
        notify.assert_called_once()
        self.assertEqual(notify.call_args[0][1], Path('/tmp/resolved'))


if __name__ == '__main__':
    unittest.main()
