---
id: ADR-0002
status: proposed
date: 2026-01-06
components: [api-gateway]
ticket: FIXTURE-2
deciders: []
supersedes: ""
superseded_by: ""
---

# ADR-0002: Rate-limit the public API by API key

## Context

The public API has no rate limiting. A single misbehaving client can degrade
service for everyone else on the same gateway instance.

## Decision

We will rate-limit requests per API key using a token-bucket algorithm enforced at
the gateway.

## Considered Options

- Per-API-key token bucket at the gateway
- Per-IP rate limiting (rejected: penalizes clients behind shared NAT)
- No rate limiting, rely on downstream service timeouts (rejected: does not stop the
  degradation, only moves it downstream)

## Consequences

Legitimate high-volume clients need a documented path to request a higher bucket
size. The gateway must track bucket state, adding a small amount of shared state.

## Affected Components

api-gateway
