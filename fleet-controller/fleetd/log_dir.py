"""
fleetd's resolver for a ticket's per-ticket state directory
(state-root-anchor, review ARCH-5).

Python twin of ticket-auto-pipeline's `lib/log-dir.sh` (`ticket_log_dir`).
Both resolve in the same order, and `fleetd/tests/test_log_dir.py` holds
them to the same shared case table
(`ticket-auto-pipeline/lib/tests/fixtures/log-dir-cases.tsv`):

  1. `FLEET_PIPELINE_LOG_DIR` when it starts with "/"
  2. the first line of `$REPOS_ROOT/.ticket-auto/log-dir` (the anchor), when
     it starts with "/"
  3. unresolved: `fallback` (None when not given)

A relative `FLEET_PIPELINE_LOG_DIR` is ignored at step 1, as in bash.
Resolving creates nothing. `write_anchor` is write-once, with the same
semantics as `ticket_log_dir_anchor_write`: a process-unique tmp file
created exclusively, hard-linked into place (link(2) never replaces an
existing file), and the loser of a race returns the winner's value.

Stdlib only, no package imports, so otel.py and observer.py can import it
when they run as plain scripts.
"""

import os
import secrets
import sys
from pathlib import Path

ANCHOR_RELPATH = os.path.join('.ticket-auto', 'log-dir')


def _env(env):
    return os.environ if env is None else env


def _debug(env, msg):
    if _env(env).get('STATE_ROOT_LOG') == '1':
        print(f'resolve_log_dir: {msg}', file=sys.stderr)


def anchor_file(env=None):
    """`$REPOS_ROOT/.ticket-auto/log-dir`, or None when REPOS_ROOT is unset."""
    root = _env(env).get('REPOS_ROOT') or ''
    if not root:
        return None
    return os.path.join(root.rstrip('/') or '/', ANCHOR_RELPATH)


def read_anchor(path):
    """The anchor's first line when it is absolute, else None."""
    try:
        with open(path, 'r', encoding='utf-8', errors='surrogateescape') as fh:
            first = fh.readline()
    except OSError:
        return None
    first = first[:-1] if first.endswith('\n') else first
    return first if first.startswith('/') else None


def resolve_log_dir(fallback=None, env=None):
    """The per-ticket log dir (a str), else `fallback` (str) or None."""
    env_val = _env(env).get('FLEET_PIPELINE_LOG_DIR') or ''
    if env_val.startswith('/'):
        _debug(env, f'env FLEET_PIPELINE_LOG_DIR={env_val}')
        return env_val
    path = anchor_file(env)
    if path is not None:
        value = read_anchor(path)
        if value is not None:
            _debug(env, f'anchor {path} -> {value}')
            return value
    _debug(env, 'unresolved')
    return None if fallback is None else str(fallback)


def write_anchor(path, env=None):
    """Write `path` as the anchor unless one exists; return the value now
    anchored (the winner's on a race), or None when the anchor cannot be
    written or holds an unusable (relative/empty) line, which is never
    replaced. Raises ValueError for a relative `path` or no REPOS_ROOT."""
    path = str(path)
    if not path.startswith('/'):
        raise ValueError(f'an absolute path is required (got {path!r})')
    anchor = anchor_file(env)
    if anchor is None:
        raise ValueError('REPOS_ROOT is not set')
    value = read_anchor(anchor)
    if value is not None:
        return value
    try:
        os.makedirs(os.path.dirname(anchor), exist_ok=True)
    except OSError:
        return None
    tmp = f'{anchor}.tmp.{os.getpid()}.{secrets.token_hex(4)}'
    try:
        with open(tmp, 'x', encoding='utf-8') as fh:
            fh.write(path + '\n')
    except OSError:
        return None
    try:
        os.link(tmp, anchor)
    except FileExistsError:
        pass
    except OSError:
        # No hard links on this filesystem: exclusive create, never replace.
        try:
            fd = os.open(anchor, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except OSError:
            fd = None
        if fd is not None:
            with os.fdopen(fd, 'w', encoding='utf-8') as fh:
                fh.write(path + '\n')
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    return read_anchor(anchor)


def same_dir(a, b):
    """True when two directory paths name the same place (realpath both)."""
    return Path(a).resolve() == Path(b).resolve()
