---
id: ADR-0001
status: superseded
date: 2026-01-05
components: [auth-service]
manual: FIXTURE-1
deciders: [alice, bob]
supersedes: ""
superseded_by: "ADR-0003"
---

# ADR-0001: Store session tokens in Redis

## Context

The auth service needs a shared session store that multiple API instances can read
from. Sessions must survive an instance restart.

## Decision

We will store session tokens in Redis with a fixed TTL matching the session lifetime.

## Considered Options

- Redis
- In-process memory cache (rejected: not shared across instances)
- Database-backed sessions (rejected: adds write load to the primary database)

## Consequences

Adds an infrastructure dependency on Redis. Session lookups become a network call
instead of an in-process read.

## Affected Components

auth-service
