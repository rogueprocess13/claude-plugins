"""OpenTelemetry exporter for the ticket-auto pipeline.

Derives OTel GenAI-convention spans by tailing the pipeline log
(`ISO|PHASE|STEP|STATUS|MSG`) and the agent-activity log
(`ISO|PHASE|TOOL_NAME`), and ships them to an OTLP collector.

Two properties are load-bearing, and both are structural rather than tested-in:

**Derived, never hand-instrumented (D5).** No phase skill, hook, or fleetd
module emits a span at the point of action. A log `printf` and an OTel SDK call
placed side by side will eventually disagree — a new phase gets one and not the
other — and then there are two authorities about what happened. There is one
writer of truth (the log) and one reader that translates it.

**Downstream, never authoritative (D5).** `detect-resume.sh`, the gate scripts,
`fleet-detect.sh` and `dashboard.py --fleet` all read the pipeline log directly.
Nothing in the pipeline waits on this process, reads its output, or notices its
absence. Stopping the exporter or unplugging the collector costs traces and
nothing else.

**The SDK dependency is quarantined here (D11).** `opentelemetry-sdk` is the
repository's first third-party Python dependency. `supervisor.py` and `store.py`
remain pure-stdlib and must stay that way. The import below is lazy and inside
the exporter process, so fleetd starts, supervises, dispatches and detects
normally when the SDK is absent — it says so once and carries on. Everything
above the emitter in this file is pure stdlib, which is also what makes it
testable in an environment (like CI) that has no SDK installed.

Run standalone (a plain script — it imports nothing but the standard library
at module level, so it needs no package on sys.path):
    python3 fleet-controller/fleetd/otel.py --log-dir ./logs

Normally fleetd spawns and supervises it; see supervisor.py's exporter
lifecycle.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

# ── Configuration ───────────────────────────────────────────────────────────
# Same FLEET_* convention as every other knob in fleet-config.sh.

DEFAULT_ENDPOINT = 'http://localhost:4318'
DEFAULT_SERVICE_NAME = 'ticket-auto-pipeline'
DEFAULT_POLL_SECS = 5
DEFAULT_MAX_TOOL_EVENTS = 100
#: How long a completed span waits before it is emitted, so enrichment written
#: *after* the phase terminal can still attach to it. `META|tokens` is the
#: reason this exists: the SubagentStop hook writes it a moment after the
#: router writes the terminal line, so a span emitted the instant its bracket
#: closes always loses its token counts. 30s is generous against a hook that
#: normally lands within one poll interval.
DEFAULT_SPAN_GRACE_SECS = 30

#: Fixed run-registry identifier fleetd supervises this process under. Not a
#: ticket id — the reap path branches on it precisely so exporter exits are not
#: mistaken for a ticket worker dying.
SERVICE_ID = 'otel-exporter'


def _env_int(name, default):
    try:
        return int(os.environ.get(name, '') or default)
    except (TypeError, ValueError):
        return default


def _parse_headers(value):
    """`key1=val1,key2=val2` → dict, tolerant of blanks. Never raises.

    Same shape as the standard OTEL_EXPORTER_OTLP_HEADERS env var (task 4.11)
    — kept as an explicit dict here rather than relying on the SDK reading
    that env var itself, so a malformed value degrades to "no extra headers"
    instead of the SDK's own (unspecified) parse behaviour.
    """
    headers = {}
    for pair in (value or '').split(','):
        pair = pair.strip()
        if not pair or '=' not in pair:
            continue
        k, v = pair.split('=', 1)
        k = k.strip()
        if k:
            headers[k] = v.strip()
    return headers


@dataclass
class ExporterConfig:
    log_dir: str = './logs'
    endpoint: str = DEFAULT_ENDPOINT
    service_name: str = DEFAULT_SERVICE_NAME
    poll_secs: int = DEFAULT_POLL_SECS
    max_tool_events: int = DEFAULT_MAX_TOOL_EVENTS
    span_grace_secs: int = DEFAULT_SPAN_GRACE_SECS
    headers: str = ''

    @classmethod
    def from_env(cls, log_dir=None):
        return cls(
            log_dir=log_dir or os.environ.get('FLEET_PIPELINE_LOG_DIR') or './logs',
            endpoint=os.environ.get('FLEET_OTEL_ENDPOINT') or DEFAULT_ENDPOINT,
            service_name=os.environ.get('FLEET_OTEL_SERVICE_NAME') or DEFAULT_SERVICE_NAME,
            poll_secs=_env_int('FLEET_OTEL_POLL_SECS', DEFAULT_POLL_SECS),
            max_tool_events=_env_int('FLEET_OTEL_MAX_TOOL_EVENTS', DEFAULT_MAX_TOOL_EVENTS),
            span_grace_secs=_env_int('FLEET_OTEL_SPAN_GRACE_SECS', DEFAULT_SPAN_GRACE_SECS),
            headers=os.environ.get('FLEET_OTEL_HEADERS', ''),
        )


def exporter_enabled():
    """Opt-in, not opt-out.

    A telemetry exporter that starts by default would have every fleetd install
    attempting OTLP connections to a collector nobody configured.
    """
    return os.environ.get('FLEET_OTEL_ENABLE', 'false').lower() == 'true'


# ── Trace-context derivation (trace-context-propagation, TP1) ───────────────
# One function, used by both the spawning path (fleetd/supervisor.py, before
# a phase worker is spawned) and this exporter (when adopting a recorded
# context) — no second implementation. Pure and deterministic: both sides
# compute identical identifiers from facts already known to each, with no
# shared state and no ordering requirement, which is the only way a tailing
# exporter and a spawn-time environment can agree at all.
#
# Both return lowercase hex strings (the W3C traceparent shape) — 32 hex
# chars / 128 bits for a trace id, 16 hex chars / 64 bits for a span id.
# Callers feeding an OTel SDK IdGenerator (which wants integers) convert with
# int(value, 16); callers building a TRACEPARENT header or a log line use the
# hex string directly.

def derive_trace_id_hex(run_id):
    return hashlib.sha256(f'trace:{run_id}'.encode('utf-8')).hexdigest()[:32]


def derive_span_id_hex(run_id, phase, generation):
    key = f'span:{run_id}:{phase}:{generation}'
    return hashlib.sha256(key.encode('utf-8')).hexdigest()[:16]


def derive_trace_context(run_id, phase, generation):
    """(trace_id_hex, span_id_hex) for one phase of one run."""
    return derive_trace_id_hex(run_id), derive_span_id_hex(run_id, phase, generation)


def build_queued_id_generator():
    """Constructs a fresh queued `IdGenerator` (task 7.6/TP1), or raises
    `ImportError` if the SDK is not installed.

    A module-level function rather than a module-level class: the class body
    subclasses the SDK's `IdGenerator`, which does not exist until the SDK
    does, and D11 requires this whole file to stay importable without it.
    Used both by `OtlpEmitter.start()` and directly by tests exercising the
    real SDK (`TestRealSdk`), so both wire the identical generator.
    """
    from opentelemetry.sdk.trace.id_generator import IdGenerator, RandomIdGenerator

    class _QueuedIdGenerator(IdGenerator):
        """Adopts a caller-queued id for exactly the next call, then falls
        back to the wrapped generator.

        A root span's own creation calls both `generate_trace_id` (queued
        when propagation is on, so the trace id equals the one the worker
        was told) and `generate_span_id` (never queued for a root — its own
        span id doesn't need to match anything). A phase span's creation
        calls only `generate_span_id` (queued to the exact id exported to
        that phase's worker); its trace id is inherited from the root's
        context, not generated here at all.
        """

        def __init__(self, fallback):
            self._fallback = fallback
            self._next_trace_id = None
            self._next_span_id = None

        def queue_trace_id(self, trace_id_int):
            self._next_trace_id = trace_id_int

        def queue_span_id(self, span_id_int):
            self._next_span_id = span_id_int

        def generate_span_id(self):
            if self._next_span_id is not None:
                value, self._next_span_id = self._next_span_id, None
                return value
            return self._fallback.generate_span_id()

        def generate_trace_id(self):
            if self._next_trace_id is not None:
                value, self._next_trace_id = self._next_trace_id, None
                return value
            return self._fallback.generate_trace_id()

    return _QueuedIdGenerator(RandomIdGenerator())


# ── Log parsing (pure stdlib) ───────────────────────────────────────────────

LINE_RE = re.compile(r'^([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)$')
ACTIVITY_RE = re.compile(r'^([^|]*)\|([^|]*)\|(.*)$')
#: `META|tokens|info|IMPLEMENT:1234/567/890|elapsed_ms=12345`
TOKENS_RE = re.compile(r'^([A-Z-]+):(\d+)/(\d+)/(\d+)(?:\|elapsed_ms=(\d+))?')

TERMINAL_STATUSES = ('done', 'fail', 'skip')


def parse_iso(value):
    try:
        return datetime.strptime(value.strip(), '%Y-%m-%dT%H:%M:%SZ').replace(
            tzinfo=timezone.utc)
    except (ValueError, AttributeError):
        return None


def _nanos(ts):
    return int(ts.timestamp() * 1_000_000_000)


@dataclass
class DerivedSpan:
    """One completed phase/step bracket, ready to become an OTel span."""

    ticket: str
    phase: str
    step: str
    start: datetime
    end: datetime
    ok: bool
    msg: str = ''
    attributes: dict = field(default_factory=dict)
    events: list = field(default_factory=list)

    @property
    def name(self):
        # GenAI convention: `<operation> <target>`. The step is the agent-ish
        # unit of work here, so it is the target.
        return f'invoke_agent {self.phase.lower()}.{self.step}'

    def duration_secs(self):
        return (self.end - self.start).total_seconds()


class TicketTranslator:
    """Turns one ticket's pipeline-log lines into completed spans.

    Deliberately stateful and incremental: the exporter tails a live log, so
    lines arrive one at a time and a span is only complete once its terminal
    line shows up. Feeding the same lines in order to a fresh translator
    reproduces the same spans, which is what makes a restart harmless.
    """

    def __init__(self, ticket):
        self.ticket = ticket
        self.open_brackets = {}  # (phase, step) -> (start_ts, msg)
        self.phase_models = {}   # phase -> model name
        self.pending_tokens = {}  # phase -> dict of usage attributes
        self.first_ts = None
        self.outcome = None
        self.outcome_ts = None
        self.gate_stops = []
        # Execution identity (otel-span-identity, langfuse-evidence-layer).
        # Populated from META lines already written by run-identity.sh and
        # the router — no new evidence, only new reading (design.md fact 1).
        self.run_id = None
        self.run_id_ts = None
        self.generation = None
        self.trigger = None
        self.pipeline_version = None
        self.fleet_version = None
        self.skill_versions = None
        self.complexity = None
        self.autonomy = None
        self.worker_sessions = {}  # phase -> runtime session id (SI5, 4.10)
        self.propagate_phases = {}  # phase -> span_id hex, only when propagate:true (task 7.6)
        self.propagate = False  # true once any META|trace-context reports propagate:true

    def feed(self, line):
        """Consume one raw log line. Returns a list of newly completed spans."""
        m = LINE_RE.match(line.rstrip('\n'))
        if not m:
            return []
        iso, phase, step, status, msg = (g.strip() for g in m.groups())
        ts = parse_iso(iso)
        if ts is None:
            return []
        if self.first_ts is None:
            self.first_ts = ts

        if phase == 'META':
            return self._feed_meta(step, status, msg, ts)

        key = (phase, step)
        if status in ('waiting', 'start'):
            # A second open for the same key replaces the first. The log's own
            # bracket-uniqueness guarantee says this should not happen; when it
            # does, the newer bracket is the live one — the same rule
            # fleet-detect.sh's position-scoped matching applies.
            self.open_brackets[key] = (ts, msg)
            return []

        if status in TERMINAL_STATUSES:
            opened = self.open_brackets.pop(key, None)
            start_ts = opened[0] if opened else ts
            span = DerivedSpan(
                ticket=self.ticket,
                phase=phase,
                step=step,
                start=start_ts,
                end=ts,
                ok=(status != 'fail'),
                msg=msg,
                attributes=self._span_attributes(phase, step, status, opened is None),
            )
            return [span]

        return []

    def _feed_meta(self, step, status, msg, ts):
        if step == 'model':
            try:
                payload = json.loads(msg)
                if payload.get('phase') and payload.get('model'):
                    self.phase_models[payload['phase']] = payload['model']
            except (ValueError, TypeError):
                pass
        elif step == 'run-id':
            try:
                payload = json.loads(msg)
            except (ValueError, TypeError):
                payload = {}
            new_run_id = payload.get('run_id') or None
            if new_run_id:
                self.run_id = new_run_id
                self.run_id_ts = ts
            if 'gen' in payload:
                self.generation = payload.get('gen')
            if payload.get('trigger'):
                self.trigger = payload['trigger']
        elif step == 'version':
            try:
                payload = json.loads(msg)
            except (ValueError, TypeError):
                payload = {}
            if payload.get('ticket_auto'):
                self.pipeline_version = payload['ticket_auto']
            if payload.get('fleet'):
                self.fleet_version = payload['fleet']
            skills = payload.get('skills')
            if isinstance(skills, dict) and skills:
                self.skill_versions = skills
        elif step == 'complexity':
            if msg:
                self.complexity = msg
        elif step == 'autonomy':
            if msg:
                self.autonomy = msg
        elif step == 'trace-context':
            try:
                payload = json.loads(msg)
            except (ValueError, TypeError):
                payload = {}
            phase = payload.get('phase')
            session_id = payload.get('session_id')
            if phase and session_id:
                self.worker_sessions[phase] = session_id
            if phase and payload.get('propagate') and payload.get('span_id'):
                # Recorded only when the flag was on at spawn time (TP2/TP3) —
                # absent (and thus never set here) whenever propagation is
                # off, which keeps `self.propagate_phases` empty and the
                # exporter's adoption path (task 7.6) untouched by default.
                self.propagate_phases[phase] = payload['span_id']
                self.propagate = True
        elif step == 'tokens':
            m = TOKENS_RE.match(msg)
            if m:
                phase, inp, out, cache, elapsed = m.groups()
                usage = {
                    'gen_ai.usage.input_tokens': int(inp),
                    'gen_ai.usage.output_tokens': int(out),
                    'pipeline.tokens.cache': int(cache),
                }
                if elapsed:
                    usage['pipeline.elapsed_ms'] = int(elapsed)
                self.pending_tokens[phase] = usage
        elif step == 'gate-stop':
            self.gate_stops.append(msg)
        elif step == 'outcome':
            self.outcome = msg
            self.outcome_ts = ts
        return []

    def take_tokens(self, phase):
        """Consume token usage recorded for `phase` since its span closed.

        Called at flush time rather than at span-completion time, because
        `META|tokens|info|` is written by the SubagentStop hook *after* the
        router writes the phase's terminal line.
        """
        return self.pending_tokens.pop(phase, None)

    def tags(self, outcome=None):
        """Trace-level tags (task 4.6). Only known dimensions — no empty tag
        for a value never observed (WE3's "absent beats empty" applies here
        as much as it does to a spawn attribute)."""
        tags = [f'ticket:{self.ticket}']
        if self.trigger:
            tags.append(f'trigger:{self.trigger}')
        if self.complexity:
            tags.append(f'complexity:{self.complexity}')
        if self.autonomy:
            tags.append(f'autonomy:{self.autonomy}')
        if outcome:
            tags.append(f'outcome:{outcome}')
        return tags

    def identity_attributes(self, phase=None, step=None, run_id=None, generation=None):
        """Filterable-metadata identity attached to a span at flush time
        (otel-span-identity, SI3: repeated on every span, not just the root).

        Applied at flush rather than at span creation for the same reason
        token usage is (`take_tokens`): `META|run-id` can be read *after* the
        phase bracket that will carry it closes, and by flush time — after
        the grace window — the translator has had the best chance to see it.

        `run_id`/`generation` override the translator's current value when
        given — the pinned hint `Exporter._flush` captured when the span was
        completed. Without the override, a span still pending when a *later*
        run supersedes this one (task 6.2) would pick up the new run's
        identity instead of the one it actually ran under.
        """
        run_id = run_id if run_id is not None else self.run_id
        generation = generation if generation is not None else self.generation
        attrs = {'langfuse.trace.metadata.ticket_id': self.ticket}
        if run_id:
            attrs['langfuse.session.id'] = run_id
            attrs['langfuse.trace.metadata.run_id'] = run_id
        if generation is not None:
            attrs['langfuse.trace.metadata.generation'] = generation
        if phase:
            attrs['langfuse.trace.metadata.phase'] = phase
        if step:
            attrs['langfuse.trace.metadata.step'] = step
        model = phase and self.phase_models.get(phase)
        if model:
            attrs['langfuse.trace.metadata.model'] = model
        if self.pipeline_version:
            attrs['langfuse.trace.metadata.pipeline_version'] = self.pipeline_version
        if self.fleet_version:
            attrs['langfuse.trace.metadata.fleet_version'] = self.fleet_version
        if self.skill_versions:
            attrs['langfuse.trace.metadata.skill_versions'] = json.dumps(self.skill_versions)
        if phase and self.worker_sessions.get(phase):
            attrs['langfuse.trace.metadata.worker_session_id'] = self.worker_sessions[phase]
        tags = self.tags()
        if tags:
            attrs['langfuse.trace.tags'] = tags
        return attrs

    def _span_attributes(self, phase, step, status, orphaned):
        attrs = {
            'gen_ai.system': 'anthropic',
            'gen_ai.operation.name': 'invoke_agent',
            'gen_ai.agent.name': f'{phase.lower()}.{step}',
            # Backend-specific (WE2/otel-span-identity task 4.7), emitted
            # alongside — never instead of — the vendor-neutral GenAI
            # attributes above, so the span stays meaningful to any OTLP
            # backend even without this key.
            'langfuse.observation.type': 'agent',
            'ticket.id': self.ticket,
            'pipeline.phase': phase,
            'pipeline.step': step,
            'pipeline.status': status,
        }
        model = self.phase_models.get(phase)
        if model:
            attrs['gen_ai.request.model'] = model
        usage = self.pending_tokens.pop(phase, None)
        if usage:
            attrs.update(usage)
        # No token line yet is the normal case, not an error — the hook writes
        # it just after the terminal. take_tokens() picks it up at flush time.
        if orphaned:
            # A terminal with no opening bracket in this translator's view:
            # either the exporter started mid-run, or the log genuinely lost
            # its `waiting` line. Recorded rather than silently back-dated to
            # the terminal's own timestamp with no explanation.
            attrs['pipeline.bracket_incomplete'] = True
        return attrs


# ── Activity log (second derivation input, task 8.3) ────────────────────────

class ActivityIndex:
    """The agent's own tool calls, queryable by time window.

    Not emitted as spans of their own: one span per tool call would swamp a
    trace whose useful unit is the phase. They attach to the phase span that
    contains them — a count attribute always, and the first N as span events,
    bounded by FLEET_OTEL_MAX_TOOL_EVENTS. The count is the part that answers
    "was the agent doing anything in there", which is exactly what a phase
    span's duration alone cannot say.
    """

    def __init__(self, max_events=DEFAULT_MAX_TOOL_EVENTS):
        self.max_events = max_events
        self.entries = {}  # ticket -> list of (ts, phase, tool)

    def feed(self, ticket, line):
        m = ACTIVITY_RE.match(line.rstrip('\n'))
        if not m:
            return
        iso, phase, tool = (g.strip() for g in m.groups())
        ts = parse_iso(iso)
        if ts is None:
            return
        self.entries.setdefault(ticket, []).append((ts, phase, tool))

    def decorate(self, span):
        """Attach tool-call count and bounded events to a completed span."""
        rows = self.entries.get(span.ticket)
        if not rows:
            return span
        window = [r for r in rows if span.start <= r[0] <= span.end]
        if not window:
            return span
        span.attributes['pipeline.tool_calls'] = len(window)
        for ts, _phase, tool in window[: self.max_events]:
            span.events.append((tool or 'unknown', ts, {'gen_ai.tool.name': tool}))
        if len(window) > self.max_events:
            span.attributes['pipeline.tool_calls_truncated'] = True
        return span

    def prune(self, ticket, before):
        """Drop entries older than a completed span so memory stays bounded."""
        rows = self.entries.get(ticket)
        if rows:
            self.entries[ticket] = [r for r in rows if r[0] >= before]


# ── Incremental file reading ────────────────────────────────────────────────

class TailReader:
    """Byte-offset tail of an append-only log.

    Stops at the last complete line. An agent is appending while this reads;
    a half-written line consumed now would be recorded permanently wrong,
    and an append-only log never corrects it. Same rule as the state store's
    ingester, for the same reason.
    """

    def __init__(self, path):
        self.path = path
        self.offset = 0

    def read_new_lines(self):
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return []
        if size < self.offset:
            # Truncated or rotated underneath us — start over rather than
            # reading from a meaningless offset into different content.
            self.offset = 0
        if size == self.offset:
            return []
        try:
            with open(self.path, 'rb') as fh:
                fh.seek(self.offset)
                chunk = fh.read(size - self.offset)
        except OSError:
            return []
        cut = chunk.rfind(b'\n')
        if cut == -1:
            return []
        self.offset += cut + 1
        text = chunk[:cut].decode('utf-8', errors='replace')
        return [ln for ln in text.split('\n') if ln.strip()]


# ── OTLP emission (the only part that needs the SDK) ────────────────────────

class OtlpEmitter:
    """Wraps the OTel SDK. Import is lazy; absence is not an error.

    `available` is False when the SDK is not installed, and every method is a
    no-op. That is what keeps D11's promise: fleetd runs identically without
    the dependency, and this file is importable and testable without it.
    """

    def __init__(self, config, stderr=sys.stderr):
        self.config = config
        self.stderr = stderr
        self.available = False
        self._tracer = None
        self._provider = None
        self._roots = {}  # ticket -> (span, context)
        self._trace = None
        self._id_generator = None  # set in start(); adopts queued ids (task 7.6)

    def start(self):
        try:
            from opentelemetry import trace
            from opentelemetry.sdk.resources import Resource
            from opentelemetry.sdk.trace import TracerProvider
            from opentelemetry.sdk.trace.export import BatchSpanProcessor
            from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
                OTLPSpanExporter,
            )
        except ImportError as exc:
            print(
                f'otel-exporter: opentelemetry SDK unavailable ({exc}) — '
                f'no spans will be emitted. Install opentelemetry-sdk and '
                f'opentelemetry-exporter-otlp-proto-http to enable.',
                file=self.stderr,
            )
            return False

        id_generator = build_queued_id_generator()
        resource = Resource.create({'service.name': self.config.service_name})
        provider = TracerProvider(resource=resource, id_generator=id_generator)
        self._id_generator = id_generator
        headers = _parse_headers(self.config.headers) or None
        provider.add_span_processor(
            BatchSpanProcessor(
                OTLPSpanExporter(
                    endpoint=f'{self.config.endpoint}/v1/traces',
                    headers=headers,
                )
            )
        )
        self._provider = provider
        self._trace = trace
        self._tracer = provider.get_tracer('fleetd.otel')
        self.available = True
        return True

    def _root_context(self, ticket, run_id, start_ts, propagate=False):
        """One root span per **execution** — `(ticket, run_id)` — not per
        ticket (SI1/otel-span-identity: the run is the trace, the ticket is a
        dimension). Created on first sight and left open until the ticket's
        `META|outcome` or until a differently-run-id'd `META|run-id` line
        supersedes it (`Exporter.poll_once`, task 4.3).

        `run_id` may be unknown at root-creation time (the first phase
        bracket can precede its `META|run-id` line) — the root opens under a
        provisional identity and is re-keyed on first sight (SI1's
        "provisional key" scenario): a still-open root whose run id was
        unknown gets it retroactively via `set_attribute`, which OTel permits
        any time before `end()`. **Known limitation**: if propagation is
        enabled and the root had to open provisionally, its trace id was
        already randomly assigned before `run_id` became known and cannot be
        changed after creation — the derived trace id is only adopted when
        `run_id` is known at the moment the root is first created.
        """
        entry = self._roots.get(ticket)
        if entry is not None:
            root, ctx, existing_run_id = entry
            if existing_run_id is None and run_id:
                try:
                    root.set_attribute('langfuse.session.id', run_id)
                    root.set_attribute('langfuse.trace.metadata.run_id', run_id)
                except Exception:
                    pass
                self._roots[ticket] = (root, ctx, run_id)
            return ctx

        attrs = {
            'ticket.id': ticket,
            'gen_ai.system': 'anthropic',
            'gen_ai.operation.name': 'invoke_agent',
            'langfuse.trace.metadata.ticket_id': ticket,
        }
        if run_id:
            attrs['langfuse.session.id'] = run_id
            attrs['langfuse.trace.metadata.run_id'] = run_id
        if propagate and run_id and self._id_generator is not None:
            try:
                self._id_generator.queue_trace_id(
                    int(derive_trace_id_hex(run_id), 16))
            except Exception:
                pass
        root = self._tracer.start_span(
            name=f'pipeline {ticket}',
            start_time=_nanos(start_ts),
            attributes=attrs,
        )
        ctx = self._trace.set_span_in_context(root)
        self._roots[ticket] = (root, ctx, run_id)
        return ctx

    def emit(self, span, run_id=None, propagate=False, span_id_hex=None):
        if not self.available:
            return
        ctx = self._root_context(span.ticket, run_id, span.start, propagate=propagate)
        if propagate and span_id_hex and self._id_generator is not None:
            try:
                self._id_generator.queue_span_id(int(span_id_hex, 16))
            except Exception:
                pass
        otel_span = self._tracer.start_span(
            name=span.name,
            context=ctx,
            start_time=_nanos(span.start),
            attributes=span.attributes,
        )
        for name, ts, attrs in span.events:
            otel_span.add_event(name, attributes=attrs, timestamp=_nanos(ts))
        if not span.ok:
            from opentelemetry.trace import Status, StatusCode

            otel_span.set_status(Status(StatusCode.ERROR, span.msg[:200]))
        otel_span.end(end_time=_nanos(span.end))

    def close_ticket(self, ticket, outcome, end_ts, tags=None):
        if not self.available:
            return
        entry = self._roots.pop(ticket, None)
        if entry is None:
            return
        root, _ctx, _run_id = entry
        root.set_attribute('pipeline.outcome', outcome)
        if tags:
            root.set_attribute('langfuse.trace.tags', list(tags))
        # A superseded root (task 4.3 — a resumed run's fresh META|run-id
        # closed this one to open its own) is not a failure: it never reached
        # a real pipeline outcome, so it must not read as an error trace.
        if outcome and outcome != 'complete' and not str(outcome).startswith('superseded'):
            from opentelemetry.trace import Status, StatusCode

            root.set_status(Status(StatusCode.ERROR, outcome[:200]))
        root.end(end_time=_nanos(end_ts))

    def shutdown(self):
        # End any still-open root spans so a clean stop does not strand
        # traces mid-flight, then flush the batch processor.
        for ticket, entry in list(self._roots.items()):
            root = entry[0]
            try:
                root.set_attribute('pipeline.outcome', 'exporter-stopped')
                root.end()
            except Exception:
                pass
        self._roots.clear()
        if self._provider is not None:
            try:
                self._provider.shutdown()
            except Exception:
                pass


# ── The exporter loop ───────────────────────────────────────────────────────

class Exporter:
    def __init__(self, config, emitter=None):
        self.config = config
        self.emitter = emitter if emitter is not None else OtlpEmitter(config)
        self.translators = {}
        self.pipeline_readers = {}
        self.activity_readers = {}
        self.activity = ActivityIndex(config.max_tool_events)
        # [(span, translator, run_id_hint, generation_hint)] awaiting the
        # grace window. The hints pin the identity known when the span
        # completed — see the comment in poll_once.
        self.pending = []
        self.spans_emitted = 0
        # Per-phase cost (task 4.8), lazily indexed from runs.jsonl. Rebuilt
        # only when the file's mtime changes — polled once per cycle at most,
        # never re-read per span.
        self._runs_jsonl_path = os.path.join(config.log_dir, 'runs.jsonl')
        self._cost_index = {}
        self._cost_index_mtime = None

    def _ticket_of(self, path, suffix):
        return os.path.basename(path)[: -len(suffix)]

    def _refresh_cost_index(self):
        """Rebuild the `(tid, gen, phase) -> usd` index from runs.jsonl.

        A missing file, an unreadable line, or a cost-less event are all
        silently skipped (task 4.8: absence is never a zero, never an error).
        """
        try:
            mtime = os.path.getmtime(self._runs_jsonl_path)
        except OSError:
            return
        if mtime == self._cost_index_mtime:
            return
        self._cost_index_mtime = mtime
        index = {}
        try:
            with open(self._runs_jsonl_path) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if event.get('kind') != 'cost':
                        continue
                    usd = event.get('usd')
                    if usd is None:
                        continue
                    index[(event.get('tid'), event.get('gen'), event.get('phase'))] = usd
        except OSError:
            return
        self._cost_index = index

    def _cost_for(self, tid, generation, phase):
        self._refresh_cost_index()
        return self._cost_index.get((tid, generation, phase))

    def poll_once(self):
        """One pass over every log in the directory. Returns spans emitted."""
        emitted = 0

        # Activity first: a span is decorated with the tool calls inside it, so
        # those calls must already be indexed when the span completes.
        for path in sorted(glob.glob(os.path.join(self.config.log_dir, '*-activity.log'))):
            ticket = self._ticket_of(path, '-activity.log')
            reader = self.activity_readers.setdefault(path, TailReader(path))
            for line in reader.read_new_lines():
                self.activity.feed(ticket, line)

        for path in sorted(glob.glob(os.path.join(self.config.log_dir, '*-pipeline.log'))):
            ticket = self._ticket_of(path, '-pipeline.log')
            if not ticket:
                continue
            reader = self.pipeline_readers.setdefault(path, TailReader(path))
            translator = self.translators.setdefault(ticket, TicketTranslator(ticket))
            prev_run_id = translator.run_id
            for line in reader.read_new_lines():
                for span in translator.feed(line):
                    # Pin the run id/generation known *now* — the moment this
                    # span's bracket closed — so a later run superseding this
                    # one (task 6.2) cannot relabel a span that already
                    # finished. `None` here (unknown yet) is not pinned: it
                    # still resolves against the translator's current value
                    # at flush time, which is how a run id arriving after the
                    # first bracket (task 6.3) still gets attributed.
                    self.pending.append(
                        (span, translator, translator.run_id, translator.generation))
                if (translator.run_id and prev_run_id
                        and translator.run_id != prev_run_id):
                    # SI1 "a new run closes the previous root": a resumed
                    # spawn stamped a fresh META|run-id while this ticket's
                    # root was still open. Flush what's pending — it was
                    # produced before this line, so it belongs to the run
                    # that is closing — then close that root before any span
                    # from the new run can attach to it.
                    emitted += self._flush(force_ticket=ticket)
                    self.emitter.close_ticket(
                        ticket, 'superseded-by-new-run', translator.run_id_ts)
                    prev_run_id = translator.run_id
                elif translator.run_id != prev_run_id:
                    prev_run_id = translator.run_id

            if translator.outcome is not None:
                # The ticket is finished, so nothing more can arrive to enrich
                # its spans: flush them immediately rather than making the root
                # span wait out a grace window for enrichment that will never
                # come.
                emitted += self._flush(force_ticket=ticket)
                self.emitter.close_ticket(
                    ticket, translator.outcome, translator.outcome_ts,
                    tags=translator.tags(outcome=translator.outcome))
                # Keep the reader (the log may still gain trailing lines) but
                # drop the translator so a re-run of the same ticket id starts
                # from a clean bracket state.
                self.translators.pop(ticket, None)

        emitted += self._flush()
        self.spans_emitted += emitted
        return emitted

    def _flush(self, force_ticket=None, now=None):
        """Emit pending spans whose grace window has elapsed.

        `force_ticket` flushes one ticket's spans regardless of age, used when
        the ticket reaches its outcome.
        """
        now = now or datetime.now(timezone.utc)
        grace = self.config.span_grace_secs
        still_pending = []
        emitted = 0
        for span, translator, run_id_hint, gen_hint in self.pending:
            ready = (
                force_ticket is not None and span.ticket == force_ticket
            ) or (now - span.end).total_seconds() >= grace
            if not ready:
                still_pending.append((span, translator, run_id_hint, gen_hint))
                continue
            usage = translator.take_tokens(span.phase)
            if usage:
                span.attributes.update(usage)
            self.activity.decorate(span)
            run_id = run_id_hint if run_id_hint is not None else translator.run_id
            generation = gen_hint if gen_hint is not None else translator.generation
            span.attributes.update(translator.identity_attributes(
                phase=span.phase, step=span.step, run_id=run_id, generation=generation))
            cost = self._cost_for(span.ticket, generation, span.phase)
            if cost is not None:
                span.attributes['pipeline.cost.usd'] = cost
            self.emitter.emit(
                span, run_id,
                propagate=translator.propagate,
                span_id_hex=translator.propagate_phases.get(span.phase),
            )
            self.activity.prune(span.ticket, span.end)
            emitted += 1
        self.pending = still_pending
        return emitted

    def run(self, max_cycles=None):
        cycles = 0
        try:
            while max_cycles is None or cycles < max_cycles:
                self.poll_once()
                cycles += 1
                if max_cycles is None or cycles < max_cycles:
                    time.sleep(self.config.poll_secs)
        except KeyboardInterrupt:
            pass
        finally:
            # Buffered spans are real completed work — emit them rather than
            # dropping them because the process is stopping.
            self._flush(now=datetime.max.replace(tzinfo=timezone.utc))
            self.emitter.shutdown()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='OTel exporter for the ticket-auto pipeline')
    parser.add_argument('--log-dir', default=None,
                        help='Pipeline log directory (default: $FLEET_PIPELINE_LOG_DIR, else ./logs)')
    parser.add_argument('--once', action='store_true',
                        help='Run a single poll and exit (for testing)')
    args = parser.parse_args(argv)

    config = ExporterConfig.from_env(args.log_dir)
    if not os.path.isdir(config.log_dir):
        print(f'otel-exporter: log directory not found: {config.log_dir}',
              file=sys.stderr)
        return 2

    emitter = OtlpEmitter(config)
    emitter.start()  # absence of the SDK is reported, not fatal
    exporter = Exporter(config, emitter)
    print(
        f'otel-exporter: watching {config.log_dir} → {config.endpoint} '
        f'(sdk={"up" if emitter.available else "absent"})',
        file=sys.stderr,
    )
    exporter.run(max_cycles=1 if args.once else None)
    return 0


if __name__ == '__main__':
    sys.exit(main())
