"""`fleetd/router_step.py` — the call, the parse and the failure mapping
(fleetd-shared-router-steps tasks 3.1/3.2).

Most cases stub `router_step._run` (the one subprocess seam) so no script
runs. The process-group kill test runs a real sleeping stub script, because
what it proves is that nothing the script started outlives the timeout.
"""

import os
import signal
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import router_step  # noqa: E402
from fleetd.router_step import StepRun, RouterStepError  # noqa: E402


class _LibDir:
    """A temp lib dir holding empty router-step.sh / prescan-run.sh files."""

    def __init__(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name)
        for name in ('router-step.sh', 'prescan-run.sh'):
            (self.path / name).write_text('#!/usr/bin/env bash\n')

    def cleanup(self):
        self._tmp.cleanup()


class FlagTest(unittest.TestCase):

    def test_off_by_default_and_read_per_call(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop(router_step.FLAG, None)
            self.assertFalse(router_step.enabled())
            os.environ[router_step.FLAG] = 'true'
            self.assertTrue(router_step.enabled())
            os.environ[router_step.FLAG] = 'false'
            self.assertFalse(router_step.enabled())

    def test_timeout_override(self):
        with mock.patch.dict(os.environ, {router_step.TIMEOUT_ENV: '7'}):
            self.assertEqual(router_step._timeout(30), 7)
        with mock.patch.dict(os.environ, {router_step.TIMEOUT_ENV: 'x'}):
            self.assertEqual(router_step._timeout(30), 30)


class ParseTest(unittest.TestCase):

    def test_shell_quoted_values(self):
        fields = router_step.parse_assignments(
            "NEEDS_RETRO=true\nRETRO_REASONS=gate-stop\\ fired,VERIFY\\ fail\n"
            "EMPTY=''\nnoise line\n")
        self.assertEqual(fields['NEEDS_RETRO'], 'true')
        self.assertEqual(fields['RETRO_REASONS'], 'gate-stop fired,VERIFY fail')
        self.assertEqual(fields['EMPTY'], '')
        self.assertNotIn('noise line', fields)


class MappingTest(unittest.TestCase):

    def setUp(self):
        self.lib = _LibDir()

    def tearDown(self):
        self.lib.cleanup()

    def _stub(self, run=None, exc=None):
        if exc is not None:
            return mock.patch.object(router_step, '_run', side_effect=exc)
        return mock.patch.object(router_step, '_run', return_value=run)

    # ── ok ──
    def test_retro_check_ok(self):
        out = ("NEEDS_RETRO=true\nDRIFT=true\n"
               "RETRO_REASONS=heartbeat\\ fallback\\ event\n")
        with self._stub(StepRun(0, out, '')) as run:
            r = router_step.retro_check('/x/logs/T-1-pipeline.log', 'hb.log',
                                        lib_dir=self.lib.path)
        self.assertEqual(r, router_step.RetroCheck(
            True, ('heartbeat fallback event',), True, True, ''))
        argv = run.call_args[0][0]
        self.assertIn('--no-drift-log', argv)
        self.assertIn('retro-check', argv)

    def test_post_spawn_ok_passes_flags_and_runs_from_the_project_dir(self):
        with self._stub(StepRun(0, 'RETURN_COMPLETENESS_STATUS=complete\n',
                                '')) as run:
            r = router_step.post_spawn(
                'implement', 'T-1', '/p/logs/T-1-pipeline.log', 'text',
                repos_root='/repos', lib_dir=self.lib.path)
        self.assertEqual(r, router_step.PostSpawn(True, 'complete', ''))
        argv = run.call_args[0][0]
        self.assertEqual(argv[2:4], ['post-spawn', 'IMPLEMENT'])
        self.assertIn('--result-file', argv)
        self.assertEqual(run.call_args[1]['cwd'], '/p')

    def test_inspector_ready_resolves_a_relative_instructions_file(self):
        out = ('PHASE_INSPECTOR_READY=VERIFY\n'
               'INSPECTOR_INSTRUCTIONS_FILE=./logs/T-1-verify-inspector.txt\n')
        with self._stub(StepRun(0, out, '')):
            r = router_step.inspector('VERIFY', 'T-1', '/p/logs/T-1-pipeline.log',
                                      lib_dir=self.lib.path)
        self.assertTrue(r.ok)
        self.assertEqual(r.ready, 'VERIFY')
        self.assertEqual(r.instructions_file, '/p/logs/T-1-verify-inspector.txt')

    def test_prescan_gate_ok(self):
        out = "PRESCAN_REPO=/r/a\nPRESCAN_SLUG=a\nPRESCAN_STATUS=stale\n"
        with self._stub(StepRun(0, out, '')):
            r = router_step.prescan_gate('/p/logs/L', '/r',
                                         lib_dir=self.lib.path)
        self.assertEqual((r.ok, r.repo, r.slug, r.status),
                         (True, '/r/a', 'a', 'stale'))

    # ── exit 2 ──
    def test_exit_2_fails_closed_for_every_step(self):
        with self._stub(StepRun(2, '', 'usage')):
            self.assertEqual(
                router_step.retro_check('L', lib_dir=self.lib.path)[:3],
                (False, (), False))
            self.assertFalse(router_step.post_spawn(
                'VERIFY', 'T', 'L', 't', lib_dir=self.lib.path).ok)
            insp = router_step.inspector('VERIFY', 'T', 'L',
                                         lib_dir=self.lib.path)
            self.assertEqual((insp.ok, insp.ready), (False, 'skip'))
            self.assertEqual(router_step.prescan_gate(
                'L', '/r', lib_dir=self.lib.path).repo, '')
            self.assertFalse(router_step.inspector_done(
                'VERIFY', 'T', 'L', 't', lib_dir=self.lib.path))
            self.assertFalse(router_step.prescan_done(
                'T', 's', 'stale', 'L', 't', lib_dir=self.lib.path))

    # ── timeout ──
    def test_timeout_reads_as_failure(self):
        with self._stub(exc=RouterStepError('timed out after 30s')):
            r = router_step.retro_check('L', lib_dir=self.lib.path)
        self.assertFalse(r.ok)
        self.assertFalse(r.needed)
        self.assertIn('timed out', r.detail)

    # ── missing script ──
    def test_missing_script_reports_not_needed_without_running(self):
        with tempfile.TemporaryDirectory() as empty, \
                mock.patch.object(router_step, '_run') as run:
            r = router_step.retro_check('L', lib_dir=empty)
        run.assert_not_called()
        self.assertEqual((r.ok, r.needed), (False, False))
        self.assertIn('not found', r.detail)

    # ── unparseable output ──
    def test_exit_0_without_result_keys_is_a_failure(self):
        with self._stub(StepRun(0, 'something else\n', '')):
            r = router_step.retro_check('L', lib_dir=self.lib.path)
            p = router_step.post_spawn('IMPLEMENT', 'T', 'L', 't',
                                       lib_dir=self.lib.path)
            i = router_step.inspector('PR-REVIEW', 'T', 'L',
                                      lib_dir=self.lib.path)
        self.assertFalse(r.ok)
        self.assertIn('unparseable', r.detail)
        self.assertFalse(p.ok)
        self.assertFalse(i.ok)

    def test_post_spawn_for_verify_needs_no_keys(self):
        # The script prints nothing for VERIFY / PR-REVIEW.
        with self._stub(StepRun(0, '', '')):
            self.assertTrue(router_step.post_spawn(
                'VERIFY', 'T', 'L', 't', lib_dir=self.lib.path).ok)

    def test_inspector_ready_without_instructions_is_a_skip(self):
        with self._stub(StepRun(0, 'PHASE_INSPECTOR_READY=VERIFY\n', '')):
            r = router_step.inspector('VERIFY', 'T', 'L',
                                      lib_dir=self.lib.path)
        self.assertEqual((r.ok, r.ready), (False, 'skip'))

    def test_return_text_file_is_removed_after_the_call(self):
        seen = []

        def _fake(argv, timeout, cwd=None, lib_dir=None):
            path = argv[argv.index('--result-file') + 1]
            seen.append(path)
            self.assertEqual(Path(path).read_text(), 'agent said')
            return StepRun(0, '', '')

        with mock.patch.object(router_step, '_run', side_effect=_fake):
            router_step.post_spawn('VERIFY', 'T', 'L', 'agent said',
                                   lib_dir=self.lib.path)
        self.assertFalse(Path(seen[0]).exists())


class SpawnBuildTest(unittest.TestCase):

    def test_inspector_spawn(self):
        spawn = router_step.build_inspector_spawn(
            'T-1', 'pr-review', 'do this', '/p/logs/L', env_file='/e')
        self.assertEqual(spawn.step_id, router_step.INSPECTOR_STEP_ID)
        self.assertEqual(spawn.phase, 'PR-REVIEW')
        self.assertEqual(spawn.step, 'phase-inspector-pr-review')
        self.assertEqual(spawn.agent,
                         'ticket-auto-pipeline:guidance-extractor-agent')
        self.assertTrue(spawn.prompt.startswith(
            '/ticket-auto-pipeline:guidance-extractor T-1 --from-auto '
            '--mode extract. do this'))
        self.assertEqual(spawn.env['FLEET_TICKET_ENV_FILE'], '/e')

    def test_prescan_spawn(self):
        spawn = router_step.build_prescan_spawn(
            'T-1', '/r/a', 'a', 'stale', '/p/logs/L')
        self.assertEqual(spawn.step_id, router_step.PRESCAN_STEP_ID)
        self.assertEqual(spawn.phase, 'MAINTENANCE')
        self.assertIn('Repo slug: a. Cadence: stale.', spawn.prompt)
        self.assertEqual(spawn.agent, 'ticket-auto-pipeline:ticket-prescan-agent')


class ProcessGroupKillTest(unittest.TestCase):
    """A timeout kills the whole process group, grandchildren included."""

    def test_timeout_kills_the_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            pid_file = Path(tmp) / 'grandchild.pid'
            script = Path(tmp) / 'router-step.sh'
            script.write_text(
                '#!/usr/bin/env bash\n'
                f'sleep 60 & echo $! > "{pid_file}"\n'
                'sleep 60\n')
            start = time.monotonic()
            with self.assertRaises(RouterStepError):
                router_step._run(['bash', str(script), 'retro-check'], 1,
                                 lib_dir=tmp)
            self.assertLess(time.monotonic() - start, 15)
            grandchild = int(pid_file.read_text().strip())
            deadline = time.monotonic() + 5
            alive = True
            while time.monotonic() < deadline:
                try:
                    os.kill(grandchild, 0)
                except ProcessLookupError:
                    alive = False
                    break
                # A zombie still answers kill(0); it is dead for our purpose.
                try:
                    stat = Path(f'/proc/{grandchild}/stat').read_text()
                    if stat.split(')')[-1].split()[0] == 'Z':
                        alive = False
                        break
                except OSError:
                    alive = False
                    break
                time.sleep(0.05)
            if alive:
                os.kill(grandchild, signal.SIGKILL)
            self.assertFalse(alive, 'grandchild outlived the timeout')


if __name__ == '__main__':
    unittest.main()
