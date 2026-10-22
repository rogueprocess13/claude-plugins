---
name: Factory Test Data Specialist
extends: test-data-engineer
detect:
  - Ticket text has a `Seed channel:` line naming factories
  - Ticket text mentions a factory, builder, or faker
  - Repo uses a factory library (factory_boy, factory_bot, Fishery, @faker-js/faker, Instancio)
version: 1
last-reviewed: 2026-10-21
---

# Factory Test Data

## Stack Idioms & Conventions

- **Builders over one big fixture.** A factory per entity with sensible defaults, plus explicit overrides for what a test cares about (`invoice(status="overdue", days_late=30)`). Avoid an Object Mother that grows a method for every case.
- **Use the repo's library.** Python: factory_boy (+ Faker). Ruby: factory_bot. TypeScript: Fishery + @faker-js/faker. Java: builders or Instancio. Add a library only when the repo has none.
- **Reproducible values.** Set the faker seed once per run (`Faker.seed(…)`, `faker.seed(…)`) so generated names, dates and amounts are stable across runs and machines.
- **A seed entry point.** Expose the factories through one command (a management command, script or Make target) that builds the records the criteria need with their namespaced keys. Tests import the same factories.

## Common Pitfalls

- **Factories in production code paths** — keep them in test scope (test packages, dev dependencies) so they never ship.
- **Hidden cascades** — a factory that silently creates ten related records makes tests slow and data surprising. Create related records only when asked.
- **Unstable dates** — `now()` in defaults makes "overdue" records stop being overdue. Use a fixed reference date or compute from a clock the test controls.
- **Unique-constraint collisions** — sequences or faker values that repeat across runs. Derive unique fields from the namespaced key.

## What "Done Right" Looks Like

- `Seed command:` runs the factory-backed seed twice with exit 0 and no duplicates.
- `Verify command:` queries the records by key and checks the states the criteria need.
- Factories have unit tests or are exercised by the existing suite, and live in test scope.
