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


_REAL_LIB = (Path(__file__).resolve().parents[3] / 'ticket-auto-pipeline'
             / 'lib')
_FAKE_PW = 'Fake-Pw-1234!'
_SNAPSHOT = (
    '- generic [ref=e1]:\n'
    '  - textbox "Email" [ref=e5]: tester@example.test\n'
    f'  - textbox "Password" [ref=f6e26]: {_FAKE_PW}\n'
    '  - textbox "Search" [ref=e9]: password reset help\n'
)


class PlaywrightScrubTest(unittest.TestCase):
    """`router_step.playwright_scrub` (#819 follow-up). The real
    `playwright-scrub.sh` where it matters, stubs for the odd outputs. Fake
    credentials only; REPOS_ROOT points at a temp dir and the cwd is a temp
    project, so no real `.playwright-mcp` directory is ever read."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.project = self.root / 'project'
        (self.project / 'logs').mkdir(parents=True)
        self.log = self.project / 'logs' / 'S-1-pipeline.log'
        self.log.write_text('')
        self.repos_root = self.root / 'repos'
        self.repos_root.mkdir()
        env = mock.patch.dict(os.environ, {'REPOS_ROOT': str(self.repos_root)})
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop('UAT_TEST_PASSWORD', None)

    def tearDown(self):
        self._tmp.cleanup()

    def _snap(self, base):
        d = base / '.playwright-mcp'
        d.mkdir(parents=True, exist_ok=True)
        f = d / 'page-1.yml'
        f.write_text(_SNAPSHOT)
        return f

    def _scrub_lines(self):
        return [line for line in self.log.read_text().splitlines()
                if '|META|playwright-scrub|' in line]

    def _call(self, **kw):
        with tempfile.TemporaryFile('w+') as err:
            with mock.patch.object(sys, 'stderr', err):
                res = router_step.playwright_scrub(str(self.log), **kw)
            err.seek(0)
            return res, err.read()

    @unittest.skipUnless(_REAL_LIB.is_dir(), 'ticket-auto-pipeline lib')
    def test_redacts_both_dirs_and_logs_the_routers_line(self):
        cwd_snap = self._snap(self.project)
        root_snap = self._snap(self.repos_root)
        res, err = self._call(lib_dir=_REAL_LIB)
        self.assertEqual((res.ok, res.logged), (True, True), res.detail)
        for f in (cwd_snap, root_snap):
            text = f.read_text()
            self.assertNotIn(_FAKE_PW, text)
            self.assertIn('textbox "Password" [ref=f6e26]: [REDACTED]', text)
            self.assertIn('password reset help', text)
        lines = self._scrub_lines()
        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].endswith(
            '|META|playwright-scrub|info|files=2 redacted=2'), lines[0])
        self.assertNotIn(_FAKE_PW, self.log.read_text())
        self.assertNotIn(_FAKE_PW, err)

    @unittest.skipUnless(_REAL_LIB.is_dir(), 'ticket-auto-pipeline lib')
    def test_literal_password_from_env_is_redacted_and_never_printed(self):
        f = self.project / '.playwright-mcp' / 'page-2.yml'
        f.parent.mkdir()
        f.write_text(f'  - paragraph [ref=e11]: was {_FAKE_PW}\n')
        with mock.patch.dict(os.environ, {'UAT_TEST_PASSWORD': _FAKE_PW}):
            res, err = self._call(lib_dir=_REAL_LIB)
        self.assertTrue(res.logged, res.detail)
        self.assertNotIn(_FAKE_PW, f.read_text())
        self.assertNotIn(_FAKE_PW, self.log.read_text())
        self.assertNotIn(_FAKE_PW, err)

    @unittest.skipUnless(_REAL_LIB.is_dir(), 'ticket-auto-pipeline lib')
    def test_nothing_to_redact_logs_nothing_and_a_repeat_is_silent(self):
        res, _err = self._call(lib_dir=_REAL_LIB)
        self.assertEqual((res.ok, res.logged), (True, False))
        self.assertEqual(self._scrub_lines(), [])
        self._snap(self.project)
        self._call(lib_dir=_REAL_LIB)
        res, _err = self._call(lib_dir=_REAL_LIB)
        self.assertEqual((res.ok, res.logged), (True, False))
        self.assertEqual(len(self._scrub_lines()), 1)

    def _stub_lib(self, body):
        lib = self.root / 'stub-lib'
        lib.mkdir(exist_ok=True)
        (lib / 'playwright-scrub.sh').write_text('#!/usr/bin/env bash\n' + body)
        (lib / 'plog.sh').write_text(
            '#!/usr/bin/env bash\n'
            '[ "$1" = --log-file ] && { f=$2; shift 2; }\n'
            'printf "2026-01-01T00:00:00Z|%s|%s|%s|%s\\n" "$@" >>"$f"\n')
        return lib

    def test_non_zero_exit_still_uses_the_output_and_hides_stderr(self):
        # The shell step's `2>/dev/null || true`.
        lib = self._stub_lib(
            f'echo "{_FAKE_PW}" >&2\n'
            'echo "PLAYWRIGHT_SCRUB files=3 redacted=1"\nexit 1\n')
        res, err = self._call(lib_dir=lib)
        self.assertEqual((res.ok, res.logged), (True, True))
        self.assertEqual(self._scrub_lines(), [
            '2026-01-01T00:00:00Z|META|playwright-scrub|info|'
            'files=3 redacted=1'])
        self.assertNotIn(_FAKE_PW, err)

    def test_empty_output_logs_nothing(self):
        res, _err = self._call(lib_dir=self._stub_lib('exit 3\n'))
        self.assertEqual((res.ok, res.logged), (True, False))
        self.assertEqual(self._scrub_lines(), [])

    def test_missing_script_and_timeout_are_not_ok_and_never_raise(self):
        res, _err = self._call(lib_dir=self.root / 'nowhere')
        self.assertEqual((res.ok, res.logged), (False, False))
        lib = self._stub_lib('exit 0\n')
        with mock.patch.object(router_step, '_run',
                               side_effect=RouterStepError('timed out')):
            res, _err = self._call(lib_dir=lib)
        self.assertEqual((res.ok, res.logged), (False, False))

    def test_runs_from_the_project_dir(self):
        lib = self._stub_lib('exit 0\n')
        with mock.patch.object(router_step, '_run',
                               return_value=StepRun(0, '', '')) as run:
            router_step.playwright_scrub(str(self.log), lib_dir=lib)
        self.assertEqual(run.call_args[1]['cwd'], str(self.project))
        self.assertEqual(run.call_args[0][0],
                         ['bash', str(lib / 'playwright-scrub.sh')])


if __name__ == '__main__':
    unittest.main()
