"""Router-step caller for fleetd (fleetd-shared-router-steps).

The manual router (`skills/ticket-auto/SKILL.md`) runs four deterministic
tails around its agent spawns through two scripts:
`ticket-auto-pipeline/lib/router-step.sh` (`post-spawn`, `inspector`,
`inspector-done`, `retro-check`) and `ticket-auto-pipeline/lib/prescan-run.sh`
(`gate`, `done`). This module lets fleetd call the same scripts instead of
keeping a Python port, for the reason `preamble.py` gave: a second
implementation would drift silently because both would look correct in
isolation. What lives here is the call, the result parse, and the
fail-closed/advisory mapping. No decision logic.

Gated by `FLEET_ROUTER_STEP_SHELL` (default `false`), read on every call so
unsetting it is a complete rollback (`enabled()`).

**Failure mapping (design.md decision 4).** A missing script, `OSError`, a
timeout, a non-zero exit or stdout without the step's result keys all come
back as a result with `ok=False` and a `detail`; nothing here raises to the
supervisor. Each caller turns `ok=False` into the value the replaced path
would have produced: retro-check reads as not needed, post-spawn leaves
`classify_phase` to its exit-code rung, inspector and prescan are skipped.
None of them synthesizes a pass.

**Timeouts (decision 5).** 30s for post-spawn, retro-check and
inspector-done, 60s for the inspector prelude, 180s for the prescan gate
(it runs `prescan-check.sh` per repo). `FLEET_ROUTER_STEP_TIMEOUT` (seconds)
overrides all of them. The child runs in its own session and a timeout
kills its whole process group, so a hung `git` under `prescan-check.sh`
cannot outlive the call.

**Working directory.** Both scripts write `./logs/<TID>-<phase>-agent.log`
captures relative to the current directory, exactly as `spawn_capture`
does on the manual path. The call runs from the directory that holds the
pipeline log's `logs/` directory, so the capture lands next to the log
`phase-result-parse.sh` and the inspector expect.

Stdlib only.
"""

import os
import shlex
import signal
import subprocess
import sys
import tempfile
from collections import namedtuple
from pathlib import Path

from fleetd import phase_dispatch

FLAG = 'FLEET_ROUTER_STEP_SHELL'
TIMEOUT_ENV = 'FLEET_ROUTER_STEP_TIMEOUT'

TIMEOUT_POST_SPAWN = 30
TIMEOUT_RETRO_CHECK = 30
TIMEOUT_INSPECTOR = 60
TIMEOUT_INSPECTOR_DONE = 30
TIMEOUT_PRESCAN_GATE = 180
TIMEOUT_PRESCAN_DONE = 30

# The three phases the router runs post-spawn and the inspector after.
INSPECTED_PHASES = frozenset({'IMPLEMENT', 'VERIFY', 'PR-REVIEW'})

INSPECTOR_SKIP = 'skip'


def enabled():
    """`FLEET_ROUTER_STEP_SHELL=true`, read per call (spec: rollback by unset)."""
    return os.environ.get('FLEET_ROUTER_STEP_SHELL', 'false') == 'true'


class RouterStepError(RuntimeError):
    """The script could not be run to completion (missing, OSError, timeout)."""


StepRun = namedtuple('StepRun', 'returncode stdout stderr')

RetroCheck = namedtuple('RetroCheck', 'needed reasons drift_detected ok detail')
RetroCheck.__doc__ = """`router-step.sh retro-check`'s answer.

Same first three fields as `phase_dispatch.RetroDecision`, so a caller reads
either one the same way. `ok=False` means the script failed; `needed` is then
False (retro is advisory, decision 4).
"""

PostSpawn = namedtuple('PostSpawn', 'ok completeness_status detail')
PostSpawn.__doc__ = """`router-step.sh post-spawn`'s answer.

completeness_status — `RETURN_COMPLETENESS_STATUS` for IMPLEMENT, '' for the
                      other phases (the script prints it only for IMPLEMENT).
"""

Inspector = namedtuple('Inspector', 'ok ready instructions_file detail')
Inspector.__doc__ = """`router-step.sh inspector`'s answer.

ready — `skip` (no verifier results: the script already wrote its own
        `META|phase-inspector` skip line) or the phase name, in which case
        `instructions_file` holds the guidance-extractor agent's
        instructions and the caller spawns it.
"""

PrescanGate = namedtuple('PrescanGate', 'ok repo slug status detail')
PrescanGate.__doc__ = """`prescan-run.sh gate`'s answer. `repo` empty: nothing to
spawn, go on to dispatch."""


def lib_dir_path(lib_dir=None):
    return Path(lib_dir) if lib_dir else phase_dispatch.ticket_auto_lib_dir()


def _timeout(default):
    raw = os.environ.get(TIMEOUT_ENV, '')
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def project_dir_for(log_file):
    """The directory whose `./logs` holds `log_file`, else None (inherit cwd)."""
    if not log_file:
        return None
    parent = Path(log_file).parent
    if parent.name == 'logs':
        return str(parent.parent)
    return None


def _run(argv, timeout, cwd=None, lib_dir=None):
    """Run one script call. Raises RouterStepError on anything but an exit.

    `start_new_session=True` puts the child in its own process group; a
    timeout SIGKILLs that whole group and reaps the child, so nothing the
    script started is left behind.
    """
    env = {
        **os.environ,
        'CLAUDE_SKILLS_LIB': os.environ.get('CLAUDE_SKILLS_LIB',
                                            str(lib_dir_path(lib_dir))),
        'TICKET_RUN_TRIGGER': 'fleetd',
    }
    try:
        proc = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            cwd=cwd, env=env, start_new_session=True)
    except OSError as exc:
        raise RouterStepError(f'could not run {argv[1]}: {exc}') from exc
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            proc.communicate(timeout=5)
        except (subprocess.TimeoutExpired, OSError):
            pass
        raise RouterStepError(
            f'{Path(argv[1]).name} {argv[2]} timed out after {timeout}s'
        ) from exc
    return StepRun(proc.returncode, out or '', err or '')


def parse_assignments(text):
    """Parse the scripts' eval-safe `KEY=value` lines (`%q`-quoted values).

    The last assignment of a key wins, as it would under `eval`. A line whose
    value does not shell-split to one word is skipped.
    """
    fields = {}
    for line in (text or '').splitlines():
        key, sep, value = line.partition('=')
        if not sep or not key or not key.replace('_', '').isalnum():
            continue
        try:
            words = shlex.split(value)
        except ValueError:
            continue
        if len(words) > 1:
            continue
        fields[key] = words[0] if words else ''
    return fields


def _warn(detail):
    print(f'fleetd[{os.getpid()}]: router-step: {detail}', file=sys.stderr)


def _call(script_name, args, timeout, required_keys, cwd=None, lib_dir=None):
    """Run a script and return `(fields, None)` or `(None, failure detail)`."""
    script = lib_dir_path(lib_dir) / script_name
    if not script.is_file():
        return None, f'{script_name} not found at {script}'
    try:
        run = _run(['bash', str(script), *args], timeout, cwd=cwd,
                   lib_dir=lib_dir)
    except RouterStepError as exc:
        return None, str(exc)
    if run.returncode != 0:
        tail = (run.stderr.strip().splitlines() or [''])[-1]
        return None, (f'{script_name} {args[0]} exited {run.returncode}'
                      + (f': {tail}' if tail else ''))
    fields = parse_assignments(run.stdout)
    missing = [k for k in required_keys if k not in fields]
    if missing:
        return None, (f'{script_name} {args[0]} printed no '
                      f'{", ".join(missing)} (unparseable output)')
    return fields, None


def _with_return_file(tid, text, fn):
    """Write `text` to a private temp file, call `fn(path)`, then delete it."""
    with tempfile.NamedTemporaryFile('w', prefix=f'fleetd-return-{tid}-',
                                     suffix='.txt', delete=False) as fh:
        fh.write(text or '')
        path = fh.name
    try:
        return fn(path)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


# ── retro-check ─────────────────────────────────────────────────────────────

def retro_check(log_file, hb_log_file='', lib_dir=None, timeout=None):
    """STEP_6's five-condition retro trigger, from `router-step.sh retro-check`.

    Passes `--no-drift-log`: the `META|drift|warn` write stays with the
    caller (the supervisor's evaluator/actor split), as it did for
    `phase_dispatch.needs_retro`.
    """
    args = ['retro-check', '--log-file', str(log_file or ''), '--no-drift-log']
    if hb_log_file:
        args += ['--hb-log-file', str(hb_log_file)]
    fields, failure = _call(
        'router-step.sh', args,
        timeout or _timeout(TIMEOUT_RETRO_CHECK),
        ('NEEDS_RETRO', 'DRIFT', 'RETRO_REASONS'), lib_dir=lib_dir)
    if failure:
        _warn(f'retro-check failed, treating retro as not needed: {failure}')
        return RetroCheck(False, (), False, False, failure)
    reasons = tuple(r for r in fields['RETRO_REASONS'].split(',') if r)
    return RetroCheck(fields['NEEDS_RETRO'] == 'true', reasons,
                      fields['DRIFT'] == 'true', True, '')


# ── post-spawn ──────────────────────────────────────────────────────────────

def post_spawn(phase, tid, log_file, return_text, attempt=None,
               ticket_dir='', repos_root='', lib_dir=None, timeout=None):
    """Capture, phase-result parse, verdict recompute and completeness check.

    The same tail the router runs before `spawn_agent_post`. Every part is
    advisory inside the script; this only reports whether the script ran.
    """
    phase = (phase or '').upper()

    def _go(result_file):
        args = ['post-spawn', phase, str(tid), '--log-file', str(log_file),
                '--result-file', result_file]
        if attempt is not None:
            args += ['--attempt', str(attempt)]
        if ticket_dir:
            args += ['--ticket-dir', str(ticket_dir)]
        if repos_root:
            args += ['--repos-root', str(repos_root)]
        required = ('RETURN_COMPLETENESS_STATUS',) if phase == 'IMPLEMENT' else ()
        return _call('router-step.sh', args,
                     timeout or _timeout(TIMEOUT_POST_SPAWN), required,
                     cwd=project_dir_for(log_file), lib_dir=lib_dir)

    fields, failure = _with_return_file(tid, return_text, _go)
    if failure:
        _warn(f'post-spawn {phase} failed for {tid}: {failure}')
        return PostSpawn(False, '', failure)
    return PostSpawn(True, fields.get('RETURN_COMPLETENESS_STATUS', ''), '')


# ── inspector ───────────────────────────────────────────────────────────────

def inspector(phase, tid, log_file, hb_log_file='', out=None, lib_dir=None,
              timeout=None):
    """RLVR Phase 1 inspector prelude (`router-step.sh inspector`)."""
    phase = (phase or '').upper()
    args = ['inspector', phase, str(tid), '--log-file', str(log_file)]
    if hb_log_file:
        args += ['--hb-log-file', str(hb_log_file)]
    if out:
        args += ['--out', str(out)]
    fields, failure = _call(
        'router-step.sh', args, timeout or _timeout(TIMEOUT_INSPECTOR),
        ('PHASE_INSPECTOR_READY',), cwd=project_dir_for(log_file),
        lib_dir=lib_dir)
    if failure:
        _warn(f'inspector {phase} failed for {tid} (advisory, skipped): '
              f'{failure}')
        return Inspector(False, INSPECTOR_SKIP, '', failure)
    ready = fields['PHASE_INSPECTOR_READY'] or INSPECTOR_SKIP
    instructions = fields.get('INSPECTOR_INSTRUCTIONS_FILE', '')
    if ready != INSPECTOR_SKIP and instructions:
        cwd = project_dir_for(log_file)
        path = Path(instructions)
        if not path.is_absolute() and cwd:
            path = Path(cwd) / path
        instructions = str(path)
    if ready != INSPECTOR_SKIP and not instructions:
        return Inspector(False, INSPECTOR_SKIP, '',
                         'inspector ready but printed no instructions file')
    return Inspector(True, ready, instructions, '')


def inspector_done(phase, tid, log_file, return_text, lib_dir=None,
                   timeout=None):
    """`router-step.sh inspector-done`: capture the inspector's return and
    close its bracket. Returns True when the script ran."""
    phase = (phase or '').upper()

    def _go(result_file):
        return _call('router-step.sh',
                     ['inspector-done', phase, str(tid),
                      '--result-file', result_file],
                     timeout or _timeout(TIMEOUT_INSPECTOR_DONE), (),
                     cwd=project_dir_for(log_file), lib_dir=lib_dir)

    _fields, failure = _with_return_file(tid, return_text, _go)
    if failure:
        _warn(f'inspector-done {phase} failed for {tid}: {failure}')
        return False
    return True


# ── prescan ─────────────────────────────────────────────────────────────────

def prescan_gate(log_file, repos_root, branch='', resume_step='', after='',
                 lib_dir=None, timeout=None):
    """`prescan-run.sh gate`: the next stale repo to refresh, if any."""
    args = ['gate', '--log-file', str(log_file),
            '--repos-root', str(repos_root or '')]
    if branch:
        args += ['--branch', str(branch)]
    if resume_step:
        args += ['--resume-step', str(resume_step)]
    if after:
        args += ['--after', str(after)]
    fields, failure = _call(
        'prescan-run.sh', args, timeout or _timeout(TIMEOUT_PRESCAN_GATE),
        ('PRESCAN_REPO', 'PRESCAN_SLUG', 'PRESCAN_STATUS'),
        cwd=project_dir_for(log_file), lib_dir=lib_dir)
    if failure:
        _warn(f'prescan gate failed (advisory, skipped): {failure}')
        return PrescanGate(False, '', '', '', failure)
    return PrescanGate(True, fields['PRESCAN_REPO'], fields['PRESCAN_SLUG'],
                       fields['PRESCAN_STATUS'], '')


def prescan_done(tid, slug, status, log_file, return_text, lib_dir=None,
                 timeout=None):
    """`prescan-run.sh done`: capture the prescan agent's return and write
    its done/fail terminal. Returns True when the script ran."""

    def _go(result_file):
        return _call('prescan-run.sh',
                     ['done', str(tid), '--slug', str(slug),
                      '--status', str(status), '--log-file', str(log_file),
                      '--result-file', result_file],
                     timeout or _timeout(TIMEOUT_PRESCAN_DONE), (),
                     cwd=project_dir_for(log_file), lib_dir=lib_dir)

    _fields, failure = _with_return_file(tid, return_text, _go)
    if failure:
        _warn(f'prescan done failed for {tid}: {failure}')
        return False
    return True


# ── Auxiliary spawns (inspector, prescan) ───────────────────────────────────
#
# The router spawns the guidance-extractor and ticket-prescan agents itself;
# under fleetd the dispatch loop owns spawning, so these build a
# `PhaseSpawn` the supervisor forks exactly like `build_pr_iterate_spawn`'s.

INSPECTOR_STEP_ID = 'INSPECTOR'
PRESCAN_STEP_ID = 'PRESCAN'


def build_inspector_spawn(tid, phase, instructions, log_file, hb_log_file='',
                          env_file=''):
    """The guidance-extractor spawn the router's `### Phase inspector`
    section describes (`--from-auto --mode extract`, instructions verbatim)."""
    phase = (phase or '').upper()
    step = f'phase-inspector-{phase.lower()}'
    skill = '/ticket-auto-pipeline:guidance-extractor'
    env = {
        phase_dispatch.PIPELINE_LOG_ENV: str(log_file or ''),
        'HB_LOG_FILE': str(hb_log_file or ''),
        'HUSKY': '0',
        'FLEET_TICKET_ID': str(tid),
        'FLEET_PHASE': phase,
        'FLEET_STEP': step,
        'FLEET_DISPATCH_STEP_ID': INSPECTOR_STEP_ID,
    }
    if env_file:
        env['FLEET_TICKET_ENV_FILE'] = str(env_file)
    prompt = f'{skill} {tid} --from-auto --mode extract'
    if instructions:
        prompt = f'{prompt}. {instructions}'
    return phase_dispatch.PhaseSpawn(
        step_id=INSPECTOR_STEP_ID, step=step, phase=phase, skill=skill,
        prompt=prompt, env=env, attempt=None, loop_bearing=False,
        next_phase=phase,
        agent='ticket-auto-pipeline:guidance-extractor-agent',
    )


def build_prescan_spawn(tid, repo, slug, status, log_file, hb_log_file='',
                        env_file=''):
    """The ticket-prescan-agent spawn of the router's prescan gate, with the
    same instructions line."""
    skill = '/ticket-auto-pipeline:ticket-prescan'
    env = {
        phase_dispatch.PIPELINE_LOG_ENV: str(log_file or ''),
        'HB_LOG_FILE': str(hb_log_file or ''),
        'HUSKY': '0',
        'FLEET_TICKET_ID': str(tid),
        'FLEET_PHASE': 'MAINTENANCE',
        'FLEET_STEP': 'prescan',
        'FLEET_DISPATCH_STEP_ID': PRESCAN_STEP_ID,
    }
    if env_file:
        env['FLEET_TICKET_ENV_FILE'] = str(env_file)
    prompt = (f'{skill} --from-auto. Run {skill} --from-auto on {repo}. '
              f'Repo slug: {slug}. Cadence: {status}.')
    return phase_dispatch.PhaseSpawn(
        step_id=PRESCAN_STEP_ID, step='prescan', phase='MAINTENANCE',
        skill=skill, prompt=prompt, env=env, attempt=None,
        loop_bearing=False, next_phase='APPRAISE',
        agent='ticket-auto-pipeline:ticket-prescan-agent',
    )
