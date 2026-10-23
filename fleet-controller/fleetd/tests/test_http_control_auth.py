"""
Tests for the CSRF/auth guard on fleetd's state-changing HTTP routes (BE-13).

POST /dispatch and POST /stop must reject a request that
- carries no (or a wrong) X-Fleetd-Token header        -> 401
- carries an Origin header (a browser, cross-site)     -> 403
- uses a CORS "simple" content type such as text/plain -> 415
and accept a local caller that sends the token from the 0600 token file
with Content-Type: application/json -> 200. GET routes stay open.

Run:
    python -m pytest fleet-controller/fleetd/tests/test_http_control_auth.py -v
"""

import http.client
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

from fleetd.tests.test_worker_status_api import (
    _write_queue_entry,
    _write_stub_dispatch,
    _write_stub_feedback,
)

TOKEN_HEADER = 'X-Fleetd-Token'


class TestHttpControlAuth(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state = Path(self._tmp.name) / 'state'
        self.state.mkdir()
        self.lib = Path(self._tmp.name) / 'lib'
        self.lib.mkdir()
        _write_stub_dispatch(self.lib)
        _write_stub_feedback(self.lib)

        from fleetd.supervisor import Supervisor, HealthServer
        self.sup = Supervisor(
            state_dir=str(self.state),
            pidfile=str(self.state / 'test.pid'),
            port=0,
            fleet_lib_dir=str(self.lib),
            spawn_enabled=False,
        )
        self.server = HealthServer('127.0.0.1', 0)
        self.server.start(self.sup)
        self.port = self.server._httpd.server_address[1]
        self.token_file = self.state / 'fleetd-default-http.token'
        self.queue = self.state / 'fleet-default-spawn-queue.jsonl'
        self.stop_file = self.state / 'stop-INIT-42.json'

    def tearDown(self):
        self.server.shutdown()
        self._tmp.cleanup()

    def _token(self):
        return self.token_file.read_text().strip()

    def _request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        try:
            return resp.status, json.loads(data)
        except (json.JSONDecodeError, ValueError):
            return resp.status, None

    def _post(self, path, payload, headers):
        return self._request('POST', path, json.dumps(payload).encode(),
                             headers)

    # ── token file ──────────────────────────────────────────────────────

    def test_token_file_created_owner_only(self):
        self.assertTrue(self.token_file.exists())
        mode = stat.S_IMODE(os.stat(self.token_file).st_mode)
        self.assertEqual(mode, 0o600)
        self.assertGreaterEqual(len(self._token()), 32)

    def test_token_kept_across_restart(self):
        first = self._token()
        from fleetd.supervisor import ensure_control_token
        self.assertEqual(ensure_control_token(self.state), first)

    # ── rejections ──────────────────────────────────────────────────────

    def test_dispatch_without_token_rejected(self):
        status, payload = self._post(
            '/dispatch', {'epic_id': 'INIT-42'},
            {'Content-Type': 'application/json'})
        self.assertEqual(status, 401)
        self.assertIn(TOKEN_HEADER, payload['error'])
        self.assertFalse(self.queue.exists())

    def test_dispatch_wrong_token_rejected(self):
        status, _ = self._post(
            '/dispatch', {'epic_id': 'INIT-42'},
            {'Content-Type': 'application/json', TOKEN_HEADER: 'nope'})
        self.assertEqual(status, 401)
        self.assertFalse(self.queue.exists())

    def test_stop_without_token_rejected(self):
        _write_queue_entry(self.state, 'CRE-101', 'INIT-42')
        status, _ = self._post(
            '/stop', {'epic_id': 'INIT-42'},
            {'Content-Type': 'application/json'})
        self.assertEqual(status, 401)
        self.assertFalse(self.stop_file.exists())

    def test_cross_origin_rejected_even_with_token(self):
        status, payload = self._post(
            '/stop', {'epic_id': 'INIT-42'},
            {'Content-Type': 'application/json', TOKEN_HEADER: self._token(),
             'Origin': 'https://evil.example'})
        self.assertEqual(status, 403)
        self.assertIn('cross-origin', payload['error'])
        self.assertFalse(self.stop_file.exists())

    def test_browser_simple_request_rejected(self):
        # The exact CSRF shape from the review: fetch(..., {mode: 'no-cors',
        # body: '{"epic_id":...}'}) -> text/plain, Origin set, no token.
        status, _ = self._request(
            'POST', '/stop', b'{"epic_id":"INIT-42"}',
            {'Content-Type': 'text/plain;charset=UTF-8',
             'Origin': 'https://evil.example'})
        self.assertIn(status, (401, 403))
        self.assertFalse(self.stop_file.exists())

    def test_text_plain_rejected_even_with_token(self):
        status, _ = self._request(
            'POST', '/dispatch', b'{"epic_id":"INIT-42"}',
            {'Content-Type': 'text/plain', TOKEN_HEADER: self._token()})
        self.assertEqual(status, 415)
        self.assertFalse(self.queue.exists())

    def test_unavailable_token_fails_closed(self):
        from fleetd.supervisor import HealthHandler
        saved = HealthHandler.control_token
        HealthHandler.control_token = None
        try:
            status, _ = self._post(
                '/dispatch', {'epic_id': 'INIT-42'},
                {'Content-Type': 'application/json', TOKEN_HEADER: ''})
        finally:
            HealthHandler.control_token = saved
        self.assertEqual(status, 503)
        self.assertFalse(self.queue.exists())

    # ── accepted ────────────────────────────────────────────────────────

    def test_dispatch_with_token_accepted(self):
        status, payload = self._post(
            '/dispatch', {'epic_id': 'INIT-42'},
            {'Content-Type': 'application/json', TOKEN_HEADER: self._token()})
        self.assertEqual(status, 200)
        self.assertEqual(payload['queued'], ['CRE-101'])

    def test_stop_with_token_accepted(self):
        _write_queue_entry(self.state, 'CRE-101', 'INIT-42')
        status, payload = self._post(
            '/stop', {'epic_id': 'INIT-42', 'reason': 'operator'},
            {'Content-Type': 'application/json; charset=utf-8',
             TOKEN_HEADER: self._token()})
        self.assertEqual(status, 200)
        self.assertEqual(payload['purged'], ['CRE-101'])

    def test_get_health_needs_no_token(self):
        status, _ = self._request('GET', '/health')
        self.assertEqual(status, 200)


if __name__ == '__main__':
    unittest.main()
