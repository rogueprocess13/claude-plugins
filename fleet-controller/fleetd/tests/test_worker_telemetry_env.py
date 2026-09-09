"""
Tests for the worker telemetry environment stamp (worker-telemetry-env,
langfuse-evidence-layer §5, task 6.10).

`_worker_otel_resource_attributes` is a pure function — no fork, no I/O — so
these tests exercise it directly rather than through a real spawn. The one
spawn-level assertion (a phase spawn actually carries these vars) lives in
`test_supervisor.py::WorkerSpawnEnvironmentTest` alongside the existing
FLEET_GENERATION/FLEET_VERSION/TICKET_RUN_ID coverage.
"""

import os
import unittest

from fleetd import supervisor as sup_mod


class ResourceAttributeBuilderTest(unittest.TestCase):
    def test_a_phase_spawn_carries_environment_session_ticket_and_phase(self):
        attrs = sup_mod._worker_otel_resource_attributes(
            'CRE-1-2026-01-01T00:00:00Z-1', 'CRE-1', phase='IMPLEMENT',
            environment='pipeline')
        self.assertIn('langfuse.session.id=CRE-1-2026-01-01T00%3A00%3A00Z-1', attrs)
        self.assertIn('langfuse.trace.metadata.ticket_id=CRE-1', attrs)
        self.assertIn('langfuse.trace.metadata.phase=IMPLEMENT', attrs)
        self.assertIn('deployment.environment=pipeline', attrs)

    def test_a_ticket_level_spawn_omits_phase_rather_than_emitting_empty(self):
        attrs = sup_mod._worker_otel_resource_attributes(
            'CRE-2-2026-01-01T00:00:00Z-1', 'CRE-2', phase='',
            environment='pipeline')
        self.assertNotIn('phase=', attrs)

    def test_a_value_with_reserved_characters_stays_parseable(self):
        attrs = sup_mod._worker_otel_resource_attributes(
            'RID-1', 'TID, with comma', phase='IMPLEMENT=X', environment='pipeline')
        # No raw reserved character escapes the intended key=value,key=value
        # shape: every remaining top-level split on ',' still has exactly one
        # '=' per pair once percent-encoding is accounted for.
        for pair in attrs.split(','):
            self.assertEqual(pair.count('='), 1, f'unparseable pair: {pair!r}')
        self.assertIn('langfuse.trace.metadata.ticket_id=TID%2C%20with%20comma', attrs)
        self.assertIn('langfuse.trace.metadata.phase=IMPLEMENT%3DX', attrs)

    def test_an_unencodable_value_is_omitted_not_raised(self):
        from unittest import mock

        with mock.patch.object(sup_mod, '_otel_pct_encode', return_value=None):
            attrs = sup_mod._worker_otel_resource_attributes(
                'RID-2', 'TID-2', phase='IMPLEMENT', environment='pipeline')
        self.assertEqual(attrs, '')

    def test_default_environment_comes_from_config(self):
        from unittest import mock

        with mock.patch.object(sup_mod, 'FLEET_OTEL_WORKER_ENVIRONMENT', 'custom-env'):
            attrs = sup_mod._worker_otel_resource_attributes('RID-3', 'TID-3')
        self.assertIn('deployment.environment=custom-env', attrs)

    def test_no_run_id_omits_session_key_but_keeps_the_rest(self):
        attrs = sup_mod._worker_otel_resource_attributes(
            None, 'TID-4', phase='VERIFY', environment='pipeline')
        self.assertNotIn('langfuse.session.id=', attrs)
        self.assertIn('langfuse.trace.metadata.ticket_id=TID-4', attrs)


class PctEncodeTest(unittest.TestCase):
    def test_encodes_reserved_characters(self):
        self.assertEqual(sup_mod._otel_pct_encode('a,b=c d'), 'a%2Cb%3Dc%20d')

    def test_plain_value_round_trips_unchanged(self):
        self.assertEqual(sup_mod._otel_pct_encode('CRE-123'), 'CRE-123')


if __name__ == '__main__':
    unittest.main()
