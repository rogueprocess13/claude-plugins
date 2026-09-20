"""fleetd/pusher.py — tracker event-board pusher (tracker-event-board-pusher,
Phase B2 of the tracker-decoupling programme, Track B).

Glob-scans `{FLEET_PIPELINE_LOG_DIR}/*-outbox.jsonl` each due cycle
(design.md Decision 4 — a total scan, no separate ticket registry, so a
from-cold-start fleetd sweep re-discovers every outbox with unconsumed
entries with no separate "did we miss this ticket" bookkeeping) and, for
each ticket and each board named in `FLEET_BOARD_DRIVERS`, drains that
ticket's outbox against the shared cursor/driver contract also used by
`skills/ticket-flow/outbox-drain.sh` — subprocess calls to
`lib/board-cursor.sh`'s `get`/`advance` CLI and to the driver script's own
`apply` CLI, so there is exactly one implementation of the locking/
read/write sequence, not a second one reimplemented per language
(design.md Decision 3).

Locking is taken in-process via Python's `fcntl.flock` on the identical
lock-file path `board-cursor.sh` itself locks — this correctly excludes
bash callers (`outbox-drain.sh`) too, because flock contention is
per-inode, not per-process (design.md Decision 2). Blocking, with the same
kind of bound bash's `flock -w` uses, implemented here as a bounded poll
since `fcntl.flock`'s blocking mode has no timeout parameter of its own.

Cadence and the `FLEET_BOARD_PUSHER_ENABLE` gate are the caller's concern
(`supervisor.py`'s `run_observe`, following the `_hold_reconcile_pass`
shape) — this module has no opinion on whether or how often it should run,
only on how one drain cycle behaves once invoked.

Stdlib only.
"""

import fcntl
import json
import os
import subprocess
import time
from pathlib import Path

from fleetd import phase_dispatch

DEFAULT_DRIVERS = 'linear'
DEFAULT_LOCK_TIMEOUT_SECS = 30


def _pipeline_log_dir(log_dir=None):
    if log_dir:
        return Path(log_dir)
    env = os.environ.get('FLEET_PIPELINE_LOG_DIR')
    if env:
        return Path(env)
    return Path('./logs')


def _configured_drivers():
    raw = os.environ.get('FLEET_BOARD_DRIVERS', DEFAULT_DRIVERS)
    return [d.strip() for d in raw.split(',') if d.strip()]


def _driver_script(name, lib_dir=None, driver_dir_override=None):
    """Resolves a configured driver name to its script path.

    `driver_dir_override` (tests only, never production config) is checked
    FIRST and wins if it holds a script by that name — mirrors
    outbox-drain.sh's `_outbox_drain_driver_script` exactly, so a test can
    mix a real production driver (whose own BASH_SOURCE-anchored path
    resolution only works from its real location) alongside a test-only
    fixture driver named in the same override directory. Anything not
    found in the override falls back to the production directory.
    """
    if driver_dir_override:
        candidate = Path(driver_dir_override) / f'{name}.sh'
        if candidate.is_file():
            return candidate
    lib = Path(lib_dir) if lib_dir else phase_dispatch.ticket_auto_lib_dir()
    return lib / 'board-drivers' / f'{name}.sh'


def _board_cursor_script(lib_dir=None):
    lib = Path(lib_dir) if lib_dir else phase_dispatch.ticket_auto_lib_dir()
    return lib / 'board-cursor.sh'


def _discover_outbox_tickets(log_dir):
    """Every ticket with an outbox file, discovered by glob — never a
    registry (design.md Decision 4)."""
    tids = []
    suffix = '-outbox.jsonl'
    try:
        for p in sorted(Path(log_dir).glob(f'*{suffix}')):
            if p.name.endswith(suffix):
                tids.append(p.name[:-len(suffix)])
    except OSError:
        return []
    return tids


def _read_outbox_entries(log_dir, tid, after_seq):
    """Entries with seq > after_seq, in ascending seq order."""
    outbox = Path(log_dir) / f'{tid}-outbox.jsonl'
    if not outbox.is_file():
        return []
    entries = []
    try:
        with open(outbox, 'r') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                seq = rec.get('seq')
                if not isinstance(seq, int) or seq <= after_seq:
                    continue
                entries.append(rec)
    except OSError:
        return []
    entries.sort(key=lambda r: r['seq'])
    return entries


def _cursor_get(env, lib_dir, tid, board_id):
    script = _board_cursor_script(lib_dir)
    try:
        proc = subprocess.run(
            ['bash', str(script), 'get', tid, board_id],
            capture_output=True, text=True, timeout=30, env=env,
        )
    except (subprocess.TimeoutExpired, OSError):
        return 0
    try:
        return int(proc.stdout.strip())
    except (TypeError, ValueError):
        return 0


def _cursor_advance(env, lib_dir, tid, board_id, new_seq):
    script = _board_cursor_script(lib_dir)
    try:
        proc = subprocess.run(
            ['bash', str(script), 'advance', tid, board_id, str(new_seq)],
            capture_output=True, text=True, timeout=30, env=env,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    return proc.returncode == 0


def _driver_apply(env, driver_script, tid, event, seq, data):
    try:
        proc = subprocess.run(
            ['bash', str(driver_script), 'apply', tid, event, str(seq),
             json.dumps(data if data is not None else {})],
            capture_output=True, text=True, timeout=60, env=env,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    return proc.returncode == 0


class _CursorLock:
    """A blocking flock on the same lock-file path `board-cursor.sh`'s own
    `board_cursor_lock` uses, taken via Python's `fcntl.flock` in-process —
    see module docstring for why this, not a subprocess call, is correct
    here (a lock acquired inside a subprocess releases the instant that
    subprocess exits, which cannot span read -> apply -> write).
    """

    def __init__(self, log_dir, tid, board_id,
                 timeout_secs=DEFAULT_LOCK_TIMEOUT_SECS):
        self._path = Path(log_dir) / f'.{tid}-cursor-{board_id}.lock'
        self._timeout_secs = timeout_secs
        self._fd = None

    def __enter__(self):
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._fd = os.open(str(self._path), os.O_CREAT | os.O_RDWR, 0o644)
        deadline = time.monotonic() + self._timeout_secs
        while True:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError:
                if time.monotonic() >= deadline:
                    os.close(self._fd)
                    self._fd = None
                    raise TimeoutError(
                        f'pusher: lock timeout acquiring cursor lock for '
                        f'{self._path}')
                time.sleep(0.05)

    def __exit__(self, exc_type, exc, tb):
        if self._fd is not None:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_UN)
            finally:
                os.close(self._fd)
                self._fd = None
        return False


def drain_ticket(tid, log_dir=None, lib_dir=None, driver_dir_override=None,
                  drivers=None, extra_env=None):
    """Drains one ticket's outbox against every configured driver,
    independently — one driver's cursor is untouched by another driver's
    failure (`tracker-board-pusher` spec's "one board's cursor does not
    affect another board's cursor" requirement).

    Returns True if every configured driver's pending backlog (as of the
    start of this call) drained cleanly, False if any driver failed on some
    entry (that driver's cursor is left at the last successful entry, to
    retry next cycle). Never raises for an ordinary driver failure — only a
    lock-acquisition timeout is treated as this ticket/driver's own
    failure, same fail-soft shape as every other fleetd pass.
    """
    log_dir = _pipeline_log_dir(log_dir)
    driver_names = drivers if drivers is not None else _configured_drivers()
    env = {**os.environ, **(extra_env or {}),
           'FLEET_PIPELINE_LOG_DIR': str(log_dir)}

    overall_ok = True
    for board_id in driver_names:
        driver_script = _driver_script(
            board_id, lib_dir=lib_dir, driver_dir_override=driver_dir_override)
        if not driver_script.is_file():
            continue
        try:
            with _CursorLock(log_dir, tid, board_id):
                cursor = _cursor_get(env, lib_dir, tid, board_id)
                entries = _read_outbox_entries(log_dir, tid, cursor)
                for rec in entries:
                    seq = rec['seq']
                    event = rec.get('event')
                    data = rec.get('data') or {}
                    if not event:
                        continue
                    if _driver_apply(env, driver_script, tid, event, seq, data):
                        _cursor_advance(env, lib_dir, tid, board_id, seq)
                    else:
                        overall_ok = False
                        break
        except TimeoutError:
            overall_ok = False
            continue

    return overall_ok


def pusher_pass(log_dir=None, lib_dir=None, driver_dir_override=None,
                 drivers=None, extra_env=None):
    """One full cycle: discover every ticket with an outbox, drain each
    independently. A single ticket's failure never stops the pass from
    reaching the rest — the same `try/except: continue` shape
    `Supervisor._hold_reconcile_pass` uses.

    Returns {tid: bool} — whether that ticket's drain (across every
    configured driver) was fully clean this cycle.
    """
    log_dir = _pipeline_log_dir(log_dir)
    tids = _discover_outbox_tickets(log_dir)
    results = {}
    for tid in tids:
        try:
            results[tid] = drain_ticket(
                tid, log_dir=log_dir, lib_dir=lib_dir,
                driver_dir_override=driver_dir_override, drivers=drivers,
                extra_env=extra_env)
        except Exception:  # noqa: BLE001 - one ticket must not sink the pass
            results[tid] = False
    return results
