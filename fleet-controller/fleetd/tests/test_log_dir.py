"""
Tests for fleetd/log_dir.py and fleetd's use of it (state-root-anchor, PR B).

The resolver cases come from ticket-auto-pipeline's shared table
`lib/tests/fixtures/log-dir-cases.tsv`, which bash's test-log-dir.sh reads
too, so `resolve_log_dir` and `ticket_log_dir` answer every row the same way.
The table is read here, never copied.

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_log_dir.py -v
"""

import io
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

try:
    from fleetd import log_dir  # noqa: E402
except ImportError:  # red at the branch base: fail each case, never crash
    log_dir = None

from fleetd import supervisor as sup_mod  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
CASES = REPO / 'ticket-auto-pipeline' / 'lib' / 'tests' / 'fixtures' / 'log-dir-cases.tsv'
BASH_LOG_DIR = REPO / 'ticket-auto-pipeline' / 'lib' / 'log-dir.sh'

_ENV_KEYS = ('REPOS_ROOT', 'FLEET_PIPELINE_LOG_DIR', 'STATE_ROOT_STRICT',
             'STATE_ROOT_LOG')


def _need(test, *names):
    if log_dir is None:
        test.fail('fleetd/log_dir.py missing')
    for name in names:
        if not hasattr(log_dir, name):
            test.fail(f'log_dir.{name} missing')


def _load_cases():
    rows = []
    for line in CASES.read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) != 6:
            raise AssertionError(f'bad case row: {line!r}')
        rows.append(fields)
    return rows


def _tree(root):
    return sorted(str(p.relative_to(root)) for p in Path(root).rglob('*'))


class _EnvTest(unittest.TestCase):
    """Saves and restores the keys the resolver reads; starts with none set."""

    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in _ENV_KEYS}
        for k in _ENV_KEYS:
            os.environ.pop(k, None)
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name).resolve()

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self._tmp.cleanup()

    def anchor(self, value, repos_root=None):
        repos_root = Path(repos_root or self.root)
        path = repos_root / '.ticket-auto' / 'log-dir'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f'{value}\n')
        return path


class SharedCaseTableTest(unittest.TestCase):
    """Parity with bash: every row of log-dir-cases.tsv, `expect` column."""

    def test_case_table_is_read(self):
        self.assertGreaterEqual(len(_load_cases()), 14)

    def test_every_row(self):
        _need(self, 'resolve_log_dir')
        for case_id, repos_root, env_val, anchor, expect, _legacy in _load_cases():
            with self.subTest(case=case_id), tempfile.TemporaryDirectory() as tmp:
                root = str(Path(tmp).resolve())
                env = {}
                if repos_root == 'set':
                    env['REPOS_ROOT'] = root
                if env_val == '<empty>':
                    env['FLEET_PIPELINE_LOG_DIR'] = ''
                elif env_val != '-':
                    env['FLEET_PIPELINE_LOG_DIR'] = env_val.replace('@ROOT@', root)
                if anchor != '-':
                    path = Path(root) / '.ticket-auto' / 'log-dir'
                    path.parent.mkdir(parents=True)
                    if anchor == '<empty>':
                        content = ''
                    elif anchor.startswith('<nonl>'):
                        content = anchor[len('<nonl>'):]
                    else:
                        content = anchor + '\n'
                    content = content.replace('\\n', '\n').replace('@ROOT@', root)
                    path.write_text(content)
                before = _tree(root)
                got = log_dir.resolve_log_dir(env=env)
                want = None if expect == 'UNRESOLVED' else expect.replace('@ROOT@', root)
                self.assertEqual(got, want)
                self.assertEqual(_tree(root), before, 'resolver created a file')

    def test_fallback_only_when_unresolved(self):
        _need(self, 'resolve_log_dir')
        self.assertEqual(log_dir.resolve_log_dir(fallback='/x', env={}), '/x')
        self.assertEqual(
            log_dir.resolve_log_dir(
                fallback='/x', env={'FLEET_PIPELINE_LOG_DIR': '/env'}),
            '/env')

    def test_reads_os_environ_by_default(self):
        _need(self, 'resolve_log_dir')
        with mock.patch.dict(os.environ, {'FLEET_PIPELINE_LOG_DIR': '/from-env'}):
            self.assertEqual(log_dir.resolve_log_dir(), '/from-env')


class AnchorWriteTest(_EnvTest):

    def test_writes_when_absent(self):
        _need(self, 'write_anchor')
        os.environ['REPOS_ROOT'] = str(self.root)
        got = log_dir.write_anchor('/srv/p/logs')
        self.assertEqual(got, '/srv/p/logs')
        self.assertEqual(
            (self.root / '.ticket-auto' / 'log-dir').read_text(), '/srv/p/logs\n')
        leftovers = [p.name for p in (self.root / '.ticket-auto').iterdir()
                     if p.name != 'log-dir']
        self.assertEqual(leftovers, [])

    def test_never_replaces_an_existing_anchor(self):
        _need(self, 'write_anchor')
        os.environ['REPOS_ROOT'] = str(self.root)
        self.anchor('/first/logs')
        self.assertEqual(log_dir.write_anchor('/second/logs'), '/first/logs')
        self.assertEqual(
            (self.root / '.ticket-auto' / 'log-dir').read_text(), '/first/logs\n')

    def test_an_unusable_anchor_is_not_replaced(self):
        _need(self, 'write_anchor')
        os.environ['REPOS_ROOT'] = str(self.root)
        self.anchor('relative/logs')
        self.assertIsNone(log_dir.write_anchor('/srv/p/logs'))
        self.assertEqual(
            (self.root / '.ticket-auto' / 'log-dir').read_text(), 'relative/logs\n')

    def test_relative_path_is_refused(self):
        _need(self, 'write_anchor')
        os.environ['REPOS_ROOT'] = str(self.root)
        with self.assertRaises(ValueError):
            log_dir.write_anchor('logs')
        self.assertFalse((self.root / '.ticket-auto').exists())

    def test_no_repos_root_is_refused(self):
        _need(self, 'write_anchor')
        with self.assertRaises(ValueError):
            log_dir.write_anchor('/srv/p/logs', env={})

    def test_race_leaves_one_value_and_every_writer_agrees(self):
        _need(self, 'write_anchor')
        env = {'REPOS_ROOT': str(self.root)}
        results = []
        barrier = threading.Barrier(8)

        def writer(i):
            barrier.wait()
            results.append(log_dir.write_anchor(f'/w{i}/logs', env=env))

        threads = [threading.Thread(target=writer, args=(i,)) for i in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        stored = (self.root / '.ticket-auto' / 'log-dir').read_text().strip()
        self.assertEqual(set(results), {stored})

    def test_bash_reads_what_python_wrote_and_python_keeps_what_bash_wrote(self):
        _need(self, 'write_anchor', 'resolve_log_dir')
        env = {**os.environ, 'REPOS_ROOT': str(self.root)}
        env.pop('FLEET_PIPELINE_LOG_DIR', None)
        log_dir.write_anchor('/py/logs', env=env)
        out = subprocess.run(['bash', str(BASH_LOG_DIR), 'resolve'], env=env,
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(out.stdout.strip(), '/py/logs')

        other = self.root / 'other'
        other.mkdir()
        env['REPOS_ROOT'] = str(other)
        subprocess.run(['bash', str(BASH_LOG_DIR), 'anchor-write', '/sh/logs'],
                       env=env, capture_output=True, text=True, timeout=30,
                       check=True)
        self.assertEqual(log_dir.write_anchor('/py/logs', env=env), '/sh/logs')
        self.assertEqual(log_dir.resolve_log_dir(env=env), '/sh/logs')


class WorkerEnvTest(_EnvTest):
    """D6: every worker gets an absolute FLEET_PIPELINE_LOG_DIR."""

    def _worker_log_dir(self, state_dir):
        out = Path(state_dir) / 'TST-LD-gen1.json'
        pid, _ = sup_mod.spawn_worker(
            tid='TST-LD', generation=1, state_dir=str(state_dir),
            cmd_override=[
                sys.executable, '-c',
                'import os; print(os.environ.get("FLEET_PIPELINE_LOG_DIR"))'],
        )
        os.waitpid(pid, 0)
        deadline = time.time() + 5
        while time.time() < deadline and not (
                out.is_file() and out.stat().st_size > 0):
            time.sleep(0.05)
        return out.read_text().strip()

    def test_worker_gets_the_anchor(self):
        os.environ['REPOS_ROOT'] = str(self.root)
        self.anchor(str(self.root / 'anchored'))
        state = self.root / 'state'
        state.mkdir()
        self.assertEqual(self._worker_log_dir(state), str(self.root / 'anchored'))

    def test_relative_env_loses_to_the_anchor(self):
        os.environ['REPOS_ROOT'] = str(self.root)
        os.environ['FLEET_PIPELINE_LOG_DIR'] = './logs'
        self.anchor(str(self.root / 'anchored'))
        state = self.root / 'state'
        state.mkdir()
        self.assertEqual(self._worker_log_dir(state), str(self.root / 'anchored'))

    def test_unresolved_falls_back_to_the_absolute_state_dir(self):
        state = self.root / 'state'
        state.mkdir()
        cwd = os.getcwd()
        os.chdir(self.root)
        try:
            got = self._worker_log_dir(Path('state'))
        finally:
            os.chdir(cwd)
        self.assertEqual(got, str(state))


class BootAnchorTest(_EnvTest):
    """D3: fleetd writes the anchor at boot when absent, with its own dir."""

    def _sup(self, state):
        return sup_mod.Supervisor(state_dir=str(state),
                                  pidfile=str(self.root / 'test.pid'), port=0)

    def test_writes_its_own_log_dir_when_absent(self):
        if not hasattr(sup_mod.Supervisor, 'ensure_log_dir_anchor'):
            self.fail('Supervisor.ensure_log_dir_anchor missing')
        os.environ['REPOS_ROOT'] = str(self.root)
        state = self.root / 'ws' / 'logs'
        state.mkdir(parents=True)
        got = self._sup(state).ensure_log_dir_anchor()
        self.assertEqual(got, str(state))
        self.assertEqual(
            (self.root / '.ticket-auto' / 'log-dir').read_text(), f'{state}\n')

    def test_absolute_env_is_its_own_log_dir(self):
        if not hasattr(sup_mod.Supervisor, 'ensure_log_dir_anchor'):
            self.fail('Supervisor.ensure_log_dir_anchor missing')
        os.environ['REPOS_ROOT'] = str(self.root)
        os.environ['FLEET_PIPELINE_LOG_DIR'] = str(self.root / 'env-logs')
        state = self.root / 'state'
        state.mkdir()
        self._sup(state).ensure_log_dir_anchor()
        self.assertEqual(
            (self.root / '.ticket-auto' / 'log-dir').read_text(),
            f'{self.root / "env-logs"}\n')

    def test_keeps_an_existing_anchor(self):
        if not hasattr(sup_mod.Supervisor, 'ensure_log_dir_anchor'):
            self.fail('Supervisor.ensure_log_dir_anchor missing')
        os.environ['REPOS_ROOT'] = str(self.root)
        self.anchor('/already/logs')
        state = self.root / 'state'
        state.mkdir()
        with redirect_stderr(io.StringIO()):
            self.assertEqual(self._sup(state).ensure_log_dir_anchor(),
                             '/already/logs')
        self.assertEqual(
            (self.root / '.ticket-auto' / 'log-dir').read_text(), '/already/logs\n')

    def test_no_repos_root_skips_with_a_log_line(self):
        if not hasattr(sup_mod.Supervisor, 'ensure_log_dir_anchor'):
            self.fail('Supervisor.ensure_log_dir_anchor missing')
        state = self.root / 'state'
        state.mkdir()
        err = io.StringIO()
        with redirect_stderr(err):
            self.assertIsNone(self._sup(state).ensure_log_dir_anchor())
        self.assertIn('REPOS_ROOT', err.getvalue())
        self.assertFalse((self.root / '.ticket-auto').exists())

    def test_tickets_host_layout(self):
        """cwd = workspace, FLEETD_WORKSPACE = workspace, --state-dir
        workspace/logs, REPOS_ROOT exported, FLEET_PIPELINE_LOG_DIR unset; the
        router anchored workspace/logs. fleetd resolves the same dir, its boot
        check passes the same dir, and its anchor write accepts it."""
        if not hasattr(sup_mod.Supervisor, 'ensure_log_dir_anchor'):
            self.fail('Supervisor.ensure_log_dir_anchor missing')
        _need(self, 'resolve_log_dir')
        ws = self.root / 'tickets'
        (ws / 'logs').mkdir(parents=True)
        os.environ['REPOS_ROOT'] = str(self.root)
        self.anchor(str(ws / 'logs'))  # what the router preamble wrote
        cwd = os.getcwd()
        os.chdir(ws)
        try:
            with mock.patch.dict(os.environ, {'FLEETD_WORKSPACE': str(ws)}):
                self.assertEqual(sup_mod.fleetd_own_log_dir(str(ws / 'logs')),
                                 str(ws / 'logs'))
                sup = self._sup(ws / 'logs')
                err = io.StringIO()
                with redirect_stderr(err):
                    self.assertEqual(sup.ensure_log_dir_anchor(), str(ws / 'logs'))
                self.assertNotIn('differs', err.getvalue())
                for accessor in (sup._board_pusher_log_dir, sup._otel_log_dir,
                                 sup._observer_log_dir):
                    self.assertEqual(accessor(), str(ws / 'logs'))
        finally:
            os.chdir(cwd)


class StartupEnvCheckLogDirTest(_EnvTest):
    """The boot gate is told fleetd's own log dir, so the env check can
    compare it with the anchor (fleet-env-check.sh log-dir-anchor-mismatch)."""

    def test_env_check_receives_fleetd_log_dir(self):
        from fleetd import __main__ as main_mod
        state = self.root / 'state'
        state.mkdir()
        seen = {}

        def fake_run(argv, **kw):
            seen.update(kw.get('env') or {})
            return subprocess.CompletedProcess(argv, 0, '', '')

        with mock.patch.dict(os.environ, {'FLEET_STARTUP_ENV_CHECK': 'true'}), \
                mock.patch.object(main_mod.subprocess, 'run', fake_run):
            main_mod._run_startup_env_check(str(state))
        self.assertEqual(seen.get('FLEET_ENV_CHECK_LOG_DIR'), str(state))


class SidecarDefaultsTest(_EnvTest):
    """pusher / otel / observer with no env and an anchor use the anchor."""

    def setUp(self):
        super().setUp()
        os.environ['REPOS_ROOT'] = str(self.root)
        self.anchor(str(self.root / 'anchored'))
        self._cwd = os.getcwd()
        os.chdir(self.root)

    def tearDown(self):
        os.chdir(self._cwd)
        super().tearDown()

    def test_pusher(self):
        from fleetd import pusher
        self.assertEqual(pusher._pipeline_log_dir(), self.root / 'anchored')
        os.environ['FLEET_PIPELINE_LOG_DIR'] = 'rel'
        self.assertEqual(pusher._pipeline_log_dir(), self.root / 'anchored')
        self.assertEqual(pusher._pipeline_log_dir('given'), self.root / 'given')

    def test_otel(self):
        from fleetd import otel
        self.assertEqual(otel.ExporterConfig.from_env().log_dir,
                         str(self.root / 'anchored'))
        self.assertEqual(otel.ExporterConfig.from_env('given').log_dir, 'given')

    def test_observer(self):
        from fleetd import observer
        self.assertEqual(observer.ObserverConfig.from_env().log_dir,
                         str(self.root / 'anchored'))
        self.assertEqual(observer.ObserverConfig.from_env('given').log_dir,
                         'given')

    def test_unanchored_keeps_todays_default(self):
        from fleetd import observer, otel, pusher
        (self.root / '.ticket-auto' / 'log-dir').unlink()
        os.environ['FLEET_PIPELINE_LOG_DIR'] = 'rel'
        self.assertEqual(otel.ExporterConfig.from_env().log_dir, 'rel')
        self.assertEqual(observer.ObserverConfig.from_env().log_dir, 'rel')
        self.assertEqual(pusher._pipeline_log_dir(), self.root / 'rel')
        os.environ.pop('FLEET_PIPELINE_LOG_DIR')
        self.assertEqual(otel.ExporterConfig.from_env().log_dir, './logs')

    def test_standalone_scripts_import_the_resolver(self):
        """otel.py / observer.py run as plain scripts (no package on sys.path)."""
        for name in ('otel.py', 'observer.py'):
            script = REPO / 'fleet-controller' / 'fleetd' / name
            env = {**os.environ}
            env.pop('PYTHONPATH', None)
            proc = subprocess.run(
                [sys.executable, str(script), '--help'], cwd=str(self.root),
                env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_supervisor_accessors_use_the_anchor(self):
        state = self.root / 'state'
        state.mkdir()
        sup = sup_mod.Supervisor(state_dir=str(state),
                                 pidfile=str(self.root / 'test.pid'), port=0)
        for accessor in (sup._board_pusher_log_dir, sup._otel_log_dir,
                         sup._observer_log_dir):
            self.assertEqual(accessor(), str(self.root / 'anchored'))


class RouterStepProjectDirTest(_EnvTest):
    """project_dir_for stays; a `logs` that differs from the resolved dir is
    logged, never raised (dispatch must not crash on it)."""

    def test_mismatch_is_logged_not_raised(self):
        from fleetd import router_step
        os.environ['REPOS_ROOT'] = str(self.root)
        self.anchor(str(self.root / 'anchored' / 'logs'))
        log_file = self.root / 'elsewhere' / 'logs' / 'T-1-pipeline.log'
        err = io.StringIO()
        with redirect_stderr(err):
            got = router_step.project_dir_for(str(log_file))
        self.assertEqual(got, str(self.root / 'elsewhere'))
        self.assertIn('differs', err.getvalue())

    def test_match_is_silent(self):
        from fleetd import router_step
        os.environ['REPOS_ROOT'] = str(self.root)
        self.anchor(str(self.root / 'p' / 'logs'))
        err = io.StringIO()
        with redirect_stderr(err):
            got = router_step.project_dir_for(
                str(self.root / 'p' / 'logs' / 'T-1-pipeline.log'))
        self.assertEqual(got, str(self.root / 'p'))
        self.assertEqual(err.getvalue(), '')


if __name__ == '__main__':
    unittest.main()
