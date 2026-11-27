"""Parity: `router-step.sh` against the Python port it replaces
(fleetd-shared-router-steps, design.md decision 8).

Runs each fixture log through the real bash script and through the retained
Python function and asserts the same answer. A failure names the fixture and
prints both sides. Delete this file together with the port (task 6.1).

* retro-check: `router-step.sh retro-check` vs `phase_dispatch.needs_retro`
  — needed flag, reasons and drift flag; with the drift write on, the
  emitted `META|drift|warn` line against the supervisor's own write.
* post-spawn: the script does not classify (the router's RESULT/VERDICT is
  the agent's judgement, and design.md was amended to match). What it shares
  with the port is the capture file and the `META|phase-result` record
  `classify_phase` rung 2 reads. So post-spawn parity is (a) the capture is
  byte-identical to `capture_phase_return`'s, and (b) `classify_phase` over
  the line the script wrote gives the same outcome as over the hand-built
  record the port's own tests use.
* playwright scrub (#819 follow-up): post-spawn VERIFY step 2b against
  `router_step.playwright_scrub`, which fleetd runs when post-spawn did not.
  Same redacted files, same `META|playwright-scrub` line. Both sides are
  live code, so move this class out before deleting the file with the port.
"""

import json
import os
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import phase_dispatch  # noqa: E402
from fleetd import router_step  # noqa: E402
from fleetd import supervisor as sup_mod  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[3]
LIB = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
TABLE_PATH = (REPO_ROOT / 'ticket-auto-pipeline' / 'skills' / 'ticket-flow'
              / 'dispatch-table.json')

_ISO = re.compile(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ')

_SUCCESS = [
    '2026-09-06T10:00:00Z|VERIFY|verify|done|PASS (1 attempts)',
    '2026-09-06T10:01:00Z|PR-REVIEW|pr-review|done|OK',
]
_FALLBACK_HB = ('2026-09-06T10:00:30Z|fallback|uat-url|warn|no CLAUDE.md '
                'UAT_URL, falling back to localhost\n')

# (name, pipeline-log lines or None for a missing file, heartbeat text or None)
RETRO_FIXTURES = [
    ('clean-success', _SUCCESS, None),
    ('gate-stop', _SUCCESS + [
        '2026-09-06T10:02:00Z|META|gate-stop|fail|VERIFY_EXHAUSTED'], None),
    ('missing-verify-pass', [_SUCCESS[1]], None),
    ('missing-pr-review-ok', [_SUCCESS[0]], None),
    ('pr-review-warn', [_SUCCESS[0],
                        '2026-09-06T10:01:00Z|PR-REVIEW|pr-review|done|WARN'],
     None),
    ('pr-review-na', [_SUCCESS[0],
                      '2026-09-06T10:01:00Z|PR-REVIEW|pr-review|done|N/A no diff'],
     None),
    ('heartbeat-fallback', _SUCCESS, _FALLBACK_HB),
    ('heartbeat-missing-file', _SUCCESS, ''),
    ('verify-exhausted-mid-message', [
        '2026-09-06T10:02:00Z|META|note|info|VERIFY_EXHAUSTED mentioned'],
     None),
    ('verify-fail', ['2026-09-06T10:00:00Z|VERIFY|verify|fail|no UI to test'],
     None),
    ('missing-log', None, None),
    ('multiple', [
        '2026-09-06T10:00:00Z|META|gate-stop|fail|VERIFY_EXHAUSTED',
        '2026-09-06T10:01:00Z|VERIFY|verify|fail|timeout',
    ], None),
]


def _block(phase, verdict, verifier):
    return (
        'summary prose before the block\n'
        '=== PHASE_RESULT ===\n'
        'SCHEMA_VERSION: 1\n'
        f'PHASE: {phase}\n'
        f'VERIFIER: {verifier}\n'
        f'VERDICT: {verdict}\n'
        '=== END PHASE_RESULT ===\n'
    )


# (name, phase, return text, the record the port's own tests hand-build)
POST_SPAWN_FIXTURES = [
    ('verify-pass', 'VERIFY', _block('VERIFY', 'PASS', 'playwright_uat'),
     ('PASS', 'ok')),
    ('verify-fail', 'VERIFY', _block('VERIFY', 'FAIL', 'playwright_uat'),
     ('FAIL', 'ok')),
    ('pr-review-pass', 'PR-REVIEW', _block('PR-REVIEW', 'PASS', 'pr_review'),
     ('PASS', 'ok')),
    ('pr-review-warn', 'PR-REVIEW', _block('PR-REVIEW', 'WARN', 'pr_review'),
     ('WARN', 'ok')),
    ('pr-review-block', 'PR-REVIEW', _block('PR-REVIEW', 'BLOCK', 'pr_review'),
     ('BLOCK', 'ok')),
    ('no-block', 'VERIFY', 'the agent forgot its block\n',
     ('UNKNOWN', 'absent')),
    ('malformed-block', 'PR-REVIEW',
     '=== PHASE_RESULT ===\nVERDICT: MAYBE\n=== END PHASE_RESULT ===\n',
     ('UNKNOWN', 'invalid')),
]


def _hand_built(phase, verdict, parse_status):
    payload = {'schema_version': 1, 'phase': phase, 'verifier': 'x',
               'claimed_verdict': verdict, 'parse_status': parse_status,
               'parse_error': ''}
    return f'2026-09-03T10:00:00Z|META|phase-result|info|{json.dumps(payload)}'


def _norm(lines):
    return [_ISO.sub('<ISO>', line) for line in lines]


@unittest.skipUnless(shutil.which('bash'), 'bash required')
class RetroCheckParityTest(unittest.TestCase):

    def setUp(self):
        self.table = phase_dispatch.DispatchTable.load(TABLE_PATH)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _write(self, name, lines, hb):
        log = self.tmp / f'{name}-pipeline.log'
        if lines is not None:
            log.write_text('\n'.join(lines) + ('\n' if lines else ''))
        hb_path = ''
        if hb is not None:
            hb_path = str(self.tmp / f'{name}-heartbeat.log')
            if hb:
                Path(hb_path).write_text(hb)
        return str(log), hb_path

    def test_decisions_are_identical(self):
        for name, lines, hb in RETRO_FIXTURES:
            with self.subTest(fixture=name):
                log, hb_path = self._write(name, lines, hb)
                py = phase_dispatch.needs_retro(self.table, log, hb_path)
                sh = router_step.retro_check(log, hb_path, lib_dir=LIB)
                self.assertTrue(sh.ok, f'{name}: script failed: {sh.detail}')
                self.assertEqual(
                    (py.needed, py.reasons, py.drift_detected),
                    (sh.needed, sh.reasons, sh.drift_detected),
                    f'fixture {name!r} diverged\n  python: {py}\n  bash:   {sh}')

    def test_emitted_drift_line_is_identical(self):
        # Bash side: the script writing its own line (the manual router).
        # Python side: what the supervisor writes for needs_retro's drift.
        log_sh, hb = self._write('sh', _SUCCESS, _FALLBACK_HB)
        router_step._call(
            'router-step.sh',
            ['retro-check', '--log-file', log_sh, '--hb-log-file', hb],
            30, ('NEEDS_RETRO',), lib_dir=LIB)
        before = len(_SUCCESS)
        sh_lines = Path(log_sh).read_text().splitlines()[before:]

        sup_mod._append_pipeline_log_line(
            str(self.tmp), 'py', 'META', 'drift', 'warn',
            sup_mod.RETRO_DRIFT_MSG)
        py_lines = (self.tmp / 'py-pipeline.log').read_text().splitlines()

        self.assertEqual(_norm(sh_lines), _norm(py_lines))


@unittest.skipUnless(shutil.which('bash') and shutil.which('jq'),
                     'bash and jq required')
class PostSpawnParityTest(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.project = Path(self._tmp.name)
        (self.project / 'logs').mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def test_classification_over_the_script_record_matches_the_hand_built_one(self):
        for name, phase, text, (verdict, status) in POST_SPAWN_FIXTURES:
            with self.subTest(fixture=name):
                log = self.project / 'logs' / f'P-{name}-pipeline.log'
                log.write_text('')
                result = router_step.post_spawn(
                    phase, f'P-{name}', str(log), text, attempt=1,
                    lib_dir=LIB)
                self.assertTrue(result.ok, f'{name}: {result.detail}')
                written = log.read_text().splitlines()
                records = [line for line in written
                           if '|META|phase-result|' in line]
                self.assertEqual(len(records), 1, f'{name}: {written}')
                payload = json.loads(records[0].split('|', 4)[4])
                self.assertEqual(
                    (payload['claimed_verdict'], payload['parse_status']),
                    (verdict, status), f'fixture {name!r}: {payload}')

                for exit_code in (0, 1):
                    from_script = phase_dispatch.classify_phase(
                        phase, written, exit_code=exit_code)
                    from_port = phase_dispatch.classify_phase(
                        phase, [_hand_built(phase, verdict, status)],
                        exit_code=exit_code)
                    self.assertEqual(
                        from_script, from_port,
                        f'fixture {name!r} exit {exit_code} diverged\n'
                        f'  script record: {from_script}\n'
                        f'  port record:   {from_port}')

    def test_capture_is_byte_identical_to_capture_phase_return(self):
        for attempt in (None, 2):
            with self.subTest(attempt=attempt):
                text = _block('VERIFY', 'PASS', 'playwright_uat')
                py_dir = self.project / f'py-{attempt}'
                (py_dir / 'logs').mkdir(parents=True)
                cwd = os.getcwd()
                os.chdir(py_dir)
                try:
                    self.assertTrue(phase_dispatch.capture_phase_return(
                        'C-1', 'VERIFY', text, attempt=attempt, lib_dir=LIB))
                finally:
                    os.chdir(cwd)

                sh_dir = self.project / f'sh-{attempt}'
                (sh_dir / 'logs').mkdir(parents=True)
                log = sh_dir / 'logs' / 'C-1-pipeline.log'
                log.write_text('')
                self.assertTrue(router_step.post_spawn(
                    'VERIFY', 'C-1', str(log), text, attempt=attempt,
                    lib_dir=LIB).ok)

                self.assertEqual(
                    (py_dir / 'logs' / 'C-1-verify-agent.log').read_bytes(),
                    (sh_dir / 'logs' / 'C-1-verify-agent.log').read_bytes())


_FAKE_PW = 'Fake-Pw-1234!'
_SNAPSHOT = (
    '- generic [ref=e1]:\n'
    '  - textbox "Email" [ref=e5]: tester@example.test\n'
    f'  - textbox "Password" [ref=f6e26]: {_FAKE_PW}\n'
    f'  - paragraph [ref=e11]: was {_FAKE_PW}\n'
)

# (name, snapshot files under ./.playwright-mcp, under $REPOS_ROOT/..., env)
SCRUB_FIXTURES = [
    ('nothing', 0, 0, {}),
    ('cwd-only', 1, 0, {}),
    ('both-dirs', 2, 1, {}),
    ('literal-env', 1, 1, {'UAT_TEST_PASSWORD': _FAKE_PW}),
]

# Stubbed playwright-scrub.sh bodies: the shell step's output handling
# (`2>/dev/null || true`, `*" redacted=0" | ""`, `#PLAYWRIGHT_SCRUB `).
SCRUB_STUBS = [
    ('exit-1-with-output',
     'echo "PLAYWRIGHT_SCRUB files=3 redacted=1"; exit 1', True),
    ('empty-exit-2', 'exit 2', False),
    ('redacted-0', 'echo "PLAYWRIGHT_SCRUB files=4 redacted=0"', False),
    ('no-prefix', 'echo "files=1 redacted=1"', True),
    ('stderr-only', f'echo "{_FAKE_PW}" >&2', False),
    ('trailing-newlines',
     'printf "PLAYWRIGHT_SCRUB files=1 redacted=1\\n\\n\\n"', True),
]


@unittest.skipUnless(shutil.which('bash'), 'bash required')
class PlaywrightScrubParityTest(unittest.TestCase):
    """#819 follow-up: `router-step.sh post-spawn VERIFY` step 2b against
    `router_step.playwright_scrub`, which fleetd runs when post-spawn did
    not. Same redacted files, same `META|playwright-scrub` line. Fake
    credentials only; REPOS_ROOT is a temp dir."""

    @classmethod
    def setUpClass(cls):
        cls._lib_tmp = tempfile.TemporaryDirectory()
        cls.stub_lib = Path(cls._lib_tmp.name) / 'lib'
        shutil.copytree(LIB, cls.stub_lib, symlinks=True)

    @classmethod
    def tearDownClass(cls):
        cls._lib_tmp.cleanup()

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        env = mock.patch.dict(os.environ, {})
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop('UAT_TEST_PASSWORD', None)

    def tearDown(self):
        self._tmp.cleanup()

    def _side(self, label, n_cwd, n_root):
        project = self.root / label / 'project'
        (project / 'logs').mkdir(parents=True)
        repos = self.root / label / 'repos'
        repos.mkdir()
        for base, n in ((project, n_cwd), (repos, n_root)):
            for i in range(n):
                d = base / '.playwright-mcp'
                d.mkdir(exist_ok=True)
                (d / f'page-{i}.yml').write_text(_SNAPSHOT)
        log = project / 'logs' / 'W-1-pipeline.log'
        log.write_text('')
        return project, repos, log

    def _run_both(self, n_cwd, n_root, env, lib):
        self._n = getattr(self, '_n', 0) + 1
        results = {}
        for label in (f'sh{self._n}', f'py{self._n}'):
            project, repos, log = self._side(label, n_cwd, n_root)
            with mock.patch.dict(os.environ,
                                 {'REPOS_ROOT': str(repos), **env}):
                if label == 'sh':
                    self.assertTrue(router_step.post_spawn(
                        'VERIFY', 'W-1', str(log), 'no block\n', attempt=1,
                        lib_dir=lib).ok)
                else:
                    router_step.playwright_scrub(str(log), lib_dir=lib)
            lines = [line for line in log.read_text().splitlines()
                     if '|playwright-scrub|' in line]
            files = sorted(
                (str(p.relative_to(self.root / label)), p.read_bytes())
                for p in (self.root / label).rglob('.playwright-mcp/*'))
            results[label[:2]] = (_norm(lines), files, log.read_text())
        return results

    def test_real_script_parity(self):
        for name, n_cwd, n_root, env in SCRUB_FIXTURES:
            with self.subTest(fixture=name):
                r = self._run_both(n_cwd, n_root, env, LIB)
                self.assertEqual(r['sh'][0], r['py'][0],
                                 f'{name}: log lines diverged')
                self.assertEqual(r['sh'][1], r['py'][1],
                                 f'{name}: snapshot files diverged')
                for side in ('sh', 'py'):
                    self.assertNotIn(_FAKE_PW, r[side][2])
                    for _path, data in r[side][1]:
                        self.assertIn(b'[ref=f6e26]: [REDACTED]', data)
                        if 'UAT_TEST_PASSWORD' in env:
                            # The literal rule needs the configured value.
                            self.assertNotIn(_FAKE_PW.encode(), data)
                if n_cwd + n_root:
                    self.assertEqual(len(r['py'][0]), 1, r['py'][0])

    def test_stubbed_output_parity(self):
        script = self.stub_lib / 'playwright-scrub.sh'
        for name, body, logs in SCRUB_STUBS:
            with self.subTest(stub=name):
                script.write_text(f'#!/usr/bin/env bash\n{body}\n')
                r = self._run_both(0, 0, {}, self.stub_lib)
                self.assertEqual(r['sh'][0], r['py'][0],
                                 f'{name}: log lines diverged')
                self.assertEqual(len(r['py'][0]), 1 if logs else 0,
                                 f'{name}: {r["py"][0]}')
                self.assertNotIn(_FAKE_PW, r['py'][2])


if __name__ == '__main__':
    unittest.main()
