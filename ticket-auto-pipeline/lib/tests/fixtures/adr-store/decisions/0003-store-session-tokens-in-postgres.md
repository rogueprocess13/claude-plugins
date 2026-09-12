---
id: ADR-0003
status: accepted
date: 2026-02-10
components: [auth-service]
manual: FIXTURE-3
deciders: [alice, carol]
supersedes: "ADR-0001"
superseded_by: ""
---

# ADR-0003: Store session tokens in Postgres instead of Redis

## Context

ADR-0001 put session tokens in Redis. Operating a second stateful datastore turned
out to cost more in on-call load than the latency Redis saved, and the auth service
already depends on Postgres for user records.

## Decision

We will store session tokens in the existing Postgres database, in a table with a
TTL enforced by a scheduled cleanup job, and retire the Redis session store.

## Considered Options

- Move sessions into the existing Postgres database
- Keep Redis and invest in better on-call tooling for it (rejected: does not remove
  the second datastore, only makes it more expensive to keep)
- Move to a managed Redis offering (rejected: cost, and still a second datastore to
  reason about)

## Consequences

Session lookups add read load to the primary database. The TTL cleanup job must run
reliably or expired sessions accumulate. The Redis dependency introduced by ADR-0001
is retired once this rolls out.

## Affected Components

auth-service
