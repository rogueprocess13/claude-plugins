## Summary

Migrate the bom microservice from Java 11 and Spring Boot 2.2 to Java 17 and Spring Boot 3, removing its JHipster dependency.

## Enables

**Enables:** O3 — the platform stays on supported Java and Spring releases (Phase A of the Java 25 path).

Spring Boot 2.x is out of open-source support, and the later Java 21 and Java 25 phases cannot start until every core service builds on Java 17.

## Background / Motivation

bom is the core domain service and still runs Java 11, Spring Boot 2.2.5 and JHipster 3.6. JHipster pins old Spring versions and blocks the shared parent POM from managing them. Until bom moves, the rest of the platform cannot drop the old dependency line.

## Proposed Changes

Move bom onto the shared parent POM at Java 17 and Spring Boot 3.4, replace the JHipster pieces it still uses with plain Spring equivalents, and keep its public API unchanged.

## Technical Context

1. Run OpenRewrite: `mvn rewrite:run -pl microservices/bom`.
2. `javax.persistence.*` → `jakarta.persistence.*` across the 31 entity classes.
3. Spring Security 6: replace `WebSecurityConfigurerAdapter` with a `@Bean SecurityFilterChain`.
4. Remove `io.github.jhipster:jhipster-framework`; inline the two utilities still used.

## Acceptance Criteria

- [ ] `mvn clean verify -pl microservices/bom` exits 0 on Java 17
- [ ] The bom service starts and `GET /management/health` returns HTTP 200 with status "UP"
- [ ] `GET /api/products` returns HTTP 200 with the same JSON shape as before the migration
- [ ] The built artifact has no `jhipster` dependency in `mvn dependency:tree`

## Out of Scope

Java 21 or later. Changes to any other microservice.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE    | bom     | build, security config, entities |

## Test User

N/A — backend-only build and API check.

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Build passes on Java 17 | n/a | n/a | none | mvn exits 0 | ✓ |
| 2 | Health endpoint up | n/a | n/a | running service | HTTP 200 status "UP" | ✓ |
| 3 | Products API unchanged | n/a | n/a | seeded product catalogue | HTTP 200, same JSON shape | ✓ |
| 4 | No JHipster dependency | n/a | n/a | none | no jhipster in dependency tree | ✓ |

## Test Data Prerequisites

The standard seeded product catalogue in the local database.

## Related Tickets

Depends on the parent POM ticket.

## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-TEST
**Epic:** EPIC-1
**Confidence:** 0.86
**Strategy:** Conservative
**Decision:** OpenRewrite-driven migration onto the shared parent POM
**Affected Services:** bom
**Target Symbols:** SecurityConfiguration:microservices/bom/src/main/java/biz/network/credit/bom/config/SecurityConfiguration.java
**Pre-approved:** true
**Generated:** 2026-10-03T00:00:00Z
**Regenerate:** false
**Kind:** enabler
**Enables:** O3
