"""
Regression tests for GitHub #648: fleetd tests must run this checkout's
`flow.sh`, never the developer's installed `~/.claude/skills` copy, and must
write nothing under the real `~/.claude/skills`.

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_flow_sh_hermetic.py -v

Self-contained on purpose (no shared test helper), so it also fails against
the code from before the fix.
"""

import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import gate_hold, orchestration  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
CHECKOUT_FLOW_SH = (REPO_ROOT / 'ticket-auto-pipeline' / 'skills'
                    / 'ticket-flow' / 'flow.sh')
REAL_SKILLS = Path.home() / '.claude' / 'skills'
# Ticket ids the fleetd tests drive through flow.sh.
TEST_TIDS = ('CRE-9', 'TST-71', 'CRE-5')


class _Proc:
    def __init__(self, returncode=0):
        self.returncode = returncode
        self.stdout = ''
        self.stderr = ''


class TestFlowPathWithEmptyHome(unittest.TestCase):
    """With HOME pointed at an empty dir and a scratch lib dir that has no
    sibling `skills/`, the flow.sh the code runs is the checkout's."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        tmp = Path(self._tmp.name)
        (tmp / 'home').mkdir()
        (tmp / 'lib').mkdir()
        self.lib = tmp / 'lib'
        self._env = mock.patch.dict(os.environ, {
            'HOME': str(tmp / 'home'),
            'FLEET_TICKET_FLOW_SH': str(CHECKOUT_FLOW_SH),
        })
        self._env.start()
        self.calls = []

        def fake_run(argv, **kwargs):
            self.calls.append(list(argv))
            return _Proc(0)

        self._run = mock.patch.object(subprocess, 'run', fake_run)
        self._run.start()

    def tearDown(self):
        self._run.stop()
        self._env.stop()
        self._tmp.cleanup()

    def _flow_paths(self):
        return [Path(argv[1]) for argv in self.calls
                if len(argv) > 1 and argv[0] == 'bash'
                and argv[1].endswith('flow.sh')]

    def _assert_checkout(self, paths):
        self.assertTrue(paths, 'flow.sh was never run')
        for path in paths:
            self.assertTrue(
                path.resolve().is_relative_to(REPO_ROOT.resolve()),
                f'{path} is not under the checkout {REPO_ROOT}')

    def test_human_hold_comment_runs_the_checkout_flow_sh(self):
        gate_hold.post_human_hold_comment(
            'CRE-9', 'hold-x', 'notes.md#AC-1', [(1, 'q?')],
            lib_dir=self.lib)
        self._assert_checkout(self._flow_paths())

    def test_flow_trigger_runs_the_checkout_flow_sh(self):
        orchestration.run_flow_trigger(
            {'kind': 'flow_trigger', 'trigger': 'implement-outcome'},
            {'tid': 'CRE-5'}, lib_dir=self.lib)
        self._assert_checkout(self._flow_paths())


class TestNothingWrittenUnderRealSkills(unittest.TestCase):
    """Stamp check: running the gate-hold tests leaves nothing new under the
    real `~/.claude/skills` for the ticket ids those tests use."""

    def test_gate_hold_suite_leaves_no_files_in_real_skills(self):
        with tempfile.TemporaryDirectory() as tmp:
            stamp = Path(tmp) / 'stamp'
            stamp.touch()
            since = stamp.stat().st_mtime
            time.sleep(0.05)
            env = dict(os.environ)
            env.pop('FLEET_TICKET_FLOW_SH', None)
            proc = subprocess.run(
                [sys.executable, '-m', 'pytest', '-q', '-p',
                 'no:cacheprovider',
                 str(Path(__file__).with_name('test_gate_hold.py'))],
                cwd=str(REPO_ROOT), env=env, capture_output=True,
                text=True, timeout=300)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        touched = []
        for dirpath, _dirs, files in os.walk(REAL_SKILLS):
            for name in files:
                if not any(tid in name for tid in TEST_TIDS):
                    continue
                path = Path(dirpath) / name
                try:
                    if path.lstat().st_mtime >= since:
                        touched.append(str(path))
                except OSError:
                    continue
        self.assertEqual(touched, [])


if __name__ == '__main__':
    unittest.main()
