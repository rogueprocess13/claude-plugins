---
name: SQL Test Data Specialist
extends: test-data-engineer
detect:
  - Ticket text has a `Seed channel:` line naming sql
  - Ticket text mentions SQL, insert, upsert, seed script, or migration
  - Repo has a migrations directory, *.sql files, Flyway or Liquibase
version: 1
last-reviewed: 2026-10-21
---

# SQL Test Data

## Stack Idioms & Conventions

- **Upsert, never blind insert.** PostgreSQL `INSERT … ON CONFLICT (key) DO UPDATE`, MySQL `INSERT … ON DUPLICATE KEY UPDATE`, SQL Server/Oracle `MERGE`. The conflict target is the namespaced natural key, not a generated id.
- **Order by foreign keys.** Insert parents before children; delete in reverse. One transaction per pack, so a failure leaves nothing half-loaded.
- **Deterministic ids.** Fixed UUIDs or keys derived from `td-<initiative>-<n>`, so other seeds and tests can reference them.
- **Keep seeds out of production.** Flyway: a separate location (e.g. `db/testdata`) enabled only in test/dev profiles. Liquibase: `context="test"` on seed changesets. Never put test data in a versioned schema migration that runs everywhere.

## Common Pitfalls

- **Sequence drift** — inserting explicit ids without resetting the sequence (`setval`) breaks the app's next insert.
- **Triggers and defaults** — seeds that bypass application logic can produce rows the app could never create; set every column the app would set (timestamps, status, audit fields).
- **Reset that is too broad** — `TRUNCATE` wipes other tickets' data. Reset by key prefix: `DELETE … WHERE key LIKE 'td-<initiative>-%'`, children first.
- **Database-specific SQL** in a repo that runs a different engine in tests (H2 vs PostgreSQL).

## What "Done Right" Looks Like

- `Seed command:` runs the seed twice with exit 0 and no duplicate rows.
- `Verify command:` counts the expected rows per key and fails on a mismatch.
- Seed files sit next to the migrations, run after them, and are excluded from production profiles.
