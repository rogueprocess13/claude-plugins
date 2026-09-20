"""
Tests for fleetd's tracker event-board pusher (fleetd/pusher.py),
tracker-event-board-pusher Phase B2 Section 5.

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_pusher.py -v

Module-level tests (drain/ordering/failure-isolation) exercise pusher.py
directly against the real bash cursor/driver scripts in
ticket-auto-pipeline/lib — the same scripts outbox-drain.sh uses, so a
passing test here is evidence about the real cross-language contract, not a
mock of it. The Supervisor wiring test at the bottom reuses
test_supervisor.py's HoldReconcilePassTest stub-and-SystemExit pattern to
prove the ENABLE gate at the run_observe call site itself.
"""

import json
import os
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import pusher  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
TICKET_AUTO_LIB = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
FIXTURES_DRIVER_DIR = TICKET_AUTO_LIB / 'tests' / 'fixtures' / 'board-drivers'


def _write_outbox(log_dir, tid, events):
    """events: list of (event, data) tuples. Writes seq 1..N in order,
    matching events.sh's record shape closely enough for pusher.py's own
    reader (seq, event, data are the only fields it consumes)."""
    outbox = Path(log_dir) / f'{tid}-outbox.jsonl'
    with open(outbox, 'w') as f:
        for i, (event, data) in enumerate(events, start=1):
            rec = {
                'seq': i, 'tid': tid, 'ts': '2026-09-20T00:00:00Z',
                'gen': 0, 'event': event, 'data': data, 'from_hint': None,
            }
            f.write(json.dumps(rec) + '\n')


class DrainTicketTest(unittest.TestCase):
    """5.4: a ticket with unconsumed entries is drained; cursor advances."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_drain_ticket_advances_cursor_past_every_entry(self):
        _write_outbox(self.ws, 'T-1', [
            ('gate-held', {'reason': 'a'}),
            ('gate-released', {'provenance': 'human'}),
        ])
        ok = pusher.drain_ticket('T-1', log_dir=self.ws,
                                  lib_dir=TICKET_AUTO_LIB, drivers=['linear'])
        self.assertTrue(ok)
        cursor_file = self.ws / '.T-1-cursor-linear.json'
        self.assertTrue(cursor_file.is_file())
        cursor = json.loads(cursor_file.read_text())
        self.assertEqual(cursor['seq'], 2)

    def test_drain_ticket_with_no_outbox_is_a_noop(self):
        ok = pusher.drain_ticket('T-NONE', log_dir=self.ws,
                                  lib_dir=TICKET_AUTO_LIB, drivers=['linear'])
        self.assertTrue(ok)


class PusherPassOrderingTest(unittest.TestCase):
    """5.5: concurrent multi-ticket pushes preserve per-ticket seq order,
    verified against the jsonl-audit test fixture's recorded dispatch
    order (never the production linear driver, which is a no-op and
    records nothing observable)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _audit_records(self, tid):
        path = self.ws / f'{tid}-board-dispatch-jsonl-audit.jsonl'
        if not path.is_file():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()
                if line.strip()]

    def test_two_tickets_each_stay_internally_ordered(self):
        _write_outbox(self.ws, 'T-A', [
            ('gate-held', {}), ('gate-released', {}), ('blocked', {}),
        ])
        _write_outbox(self.ws, 'T-B', [
            ('gate-held', {}), ('unblocked', {}),
        ])
        results = pusher.pusher_pass(
            log_dir=self.ws, lib_dir=TICKET_AUTO_LIB,
            driver_dir_override=FIXTURES_DRIVER_DIR, drivers=['jsonl-audit'])
        self.assertEqual(results, {'T-A': True, 'T-B': True})

        a_seqs = [r['seq'] for r in self._audit_records('T-A')]
        b_seqs = [r['seq'] for r in self._audit_records('T-B')]
        self.assertEqual(a_seqs, [1, 2, 3])
        self.assertEqual(b_seqs, [1, 2])


class PusherPassFailureIsolationTest(unittest.TestCase):
    """5.6: a driver failure for one ticket does not prevent other tickets
    from draining in the same cycle."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self._tmp.name)
        self._driver_tmp = tempfile.TemporaryDirectory()
        self.driver_dir = Path(self._driver_tmp.name)
        # A driver that fails only for TID "T-FAIL", succeeds (no-op) for
        # everything else — simulates one ticket's dispatch failing while
        # the driver itself is healthy for the rest of the fleet.
        script = self.driver_dir / 'flaky.sh'
        script.write_text(
            '#!/usr/bin/env bash\n'
            'tid="$2"\n'
            'if [ "$tid" = "T-FAIL" ]; then exit 1; else exit 0; fi\n'
        )
        script.chmod(script.stat().st_mode | stat.S_IEXEC)

    def tearDown(self):
        self._tmp.cleanup()
        self._driver_tmp.cleanup()

    def test_one_tickets_driver_failure_does_not_block_another(self):
        _write_outbox(self.ws, 'T-FAIL', [('gate-held', {})])
        _write_outbox(self.ws, 'T-OK', [('gate-held', {})])

        results = pusher.pusher_pass(
            log_dir=self.ws, lib_dir=TICKET_AUTO_LIB,
            driver_dir_override=self.driver_dir, drivers=['flaky'])

        self.assertEqual(results, {'T-FAIL': False, 'T-OK': True})

        fail_cursor = self.ws / '.T-FAIL-cursor-flaky.json'
        ok_cursor = self.ws / '.T-OK-cursor-flaky.json'
        self.assertFalse(fail_cursor.is_file())
        self.assertTrue(ok_cursor.is_file())
        self.assertEqual(json.loads(ok_cursor.read_text())['seq'], 1)


class DiscoverOutboxTicketsTest(unittest.TestCase):
    """The pusher discovers work by glob, not a registry (design.md
    Decision 4) — this is what makes a from-cold-start sweep total."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_discovers_every_outbox_file_by_glob(self):
        _write_outbox(self.ws, 'T-1', [('gate-held', {})])
        _write_outbox(self.ws, 'T-2', [('gate-held', {})])
        (self.ws / 'not-an-outbox.log').write_text('irrelevant')
        tids = pusher._discover_outbox_tickets(self.ws)
        self.assertEqual(sorted(tids), ['T-1', 'T-2'])

    def test_empty_directory_discovers_nothing(self):
        self.assertEqual(pusher._discover_outbox_tickets(self.ws), [])


class BoardPusherEnableGateTest(unittest.TestCase):
    """5.7: with FLEET_BOARD_PUSHER_ENABLE unset (the default),
    run_observe never invokes the pusher pass — proven at the actual
    run_observe call site, not merely by checking the flag's default
    value, using the same stub-and-SystemExit pattern
    test_supervisor.py's HoldReconcilePassTest uses for the analogous
    hold-reconcile pass."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _stubbed_supervisor(self, calls):
        from fleetd.supervisor import Supervisor
        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            port=_find_free_port(),
            cycle_interval=0.05,
        )

        def record(name):
            def _fn(*args, **kwargs):
                calls.append(name)
                return None
            return _fn

        sup.scan_workers = record('scan_workers')
        sup.reconcile_orphaned_tickets = record('reconcile_orphaned_tickets')
        sup.run_detection_cycle = record('run_detection_cycle')
        sup._reap_children = record('_reap_children')
        sup._process_kill_requests = record('_process_kill_requests')
        sup._consume_queue = record('_consume_queue')
        sup._hold_reconcile_pass = record('_hold_reconcile_pass')
        sup._human_hold_intake_pass = record('_human_hold_intake_pass')

        def _board_pusher_pass():
            calls.append('_board_pusher_pass')
            raise SystemExit(0)

        sup._board_pusher_pass = _board_pusher_pass
        return sup

    def test_disabled_by_default_never_calls_board_pusher_pass(self):
        import fleetd.supervisor as sup_mod
        self.assertFalse(sup_mod.FLEET_BOARD_PUSHER_ENABLE,
                         'FLEET_BOARD_PUSHER_ENABLE must default to false')

        calls = []
        sup = self._stubbed_supervisor(calls)

        # The loop would otherwise run forever with nothing to raise
        # SystemExit — bound it via cycle_interval + a stop after one pass
        # by making _consume_queue itself raise once recorded, mirroring
        # HoldReconcilePassTest's own bound-the-loop trick applied to a
        # pass that (correctly) never fires here.
        call_count = {'n': 0}
        orig_consume = sup._consume_queue

        def _consume_queue_then_exit(*args, **kwargs):
            orig_consume(*args, **kwargs)
            call_count['n'] += 1
            if call_count['n'] >= 1:
                raise SystemExit(0)

        sup._consume_queue = _consume_queue_then_exit

        with self.assertRaises(SystemExit):
            sup.run_observe()

        self.assertNotIn('_board_pusher_pass', calls,
                         'run_observe must not call _board_pusher_pass '
                         'while FLEET_BOARD_PUSHER_ENABLE is false/unset')

    def test_enabled_calls_board_pusher_pass(self):
        import fleetd.supervisor as sup_mod
        old = sup_mod.FLEET_BOARD_PUSHER_ENABLE
        sup_mod.FLEET_BOARD_PUSHER_ENABLE = True
        try:
            calls = []
            sup = self._stubbed_supervisor(calls)
            with self.assertRaises(SystemExit):
                sup.run_observe()
            self.assertIn('_board_pusher_pass', calls,
                          'run_observe must call _board_pusher_pass when '
                          'FLEET_BOARD_PUSHER_ENABLE is true')
        finally:
            sup_mod.FLEET_BOARD_PUSHER_ENABLE = old


def _find_free_port(start=21101):
    import socket
    port = start
    while port < start + 100:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(('127.0.0.1', port))
                return port
            except OSError:
                port += 1
    raise RuntimeError(f"no free port found in range {start}-{start + 100}")


if __name__ == '__main__':
    unittest.main()
