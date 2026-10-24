# Persona System

Self-contained role guidance for ticket-auto-pipeline skills. Plain markdown reference files — no skill activation dependency.

## How it works

1. A pipeline skill calls `TICKET_TEXT_FILE=<file> lib/persona-select.sh --repo <path> [--layer FE|BE|infra] [--phase appraise|implement|review|audit|prescan] [--type bug|feature|improvement|security|chore|refactor] [--remediation]`
2. The helper emits `PERSONA_BASE`, `PERSONA_SPECIALIZER`, `PERSONA_AUTO_INCLUDE`, `PERSONA_TESTDATA`, `PERSONA_TESTDATA_SPECIALIZERS`, `PERSONA_DEBUG` and `PERSONA_DEBUG_SPECIALIZER` as `KEY=value` lines, in that order. Every key is always printed; an empty value means "none".
3. The skill reads the persona files at those paths and injects their content as role context

### Ticket text input (`TICKET_TEXT_FILE`)

The keyword triggers below (security auto-include, test-data signals, migration/refactor specializers) read the ticket text from the file named by `TICKET_TEXT_FILE`. Before `debugger-persona-overlay` no skill set this variable, so those triggers never fired in production. Every skill invocation now sets it:

| Skill | `TICKET_TEXT_FILE` |
|-------|--------------------|
| ticket-appraise, ticket-implement, ticket-pr-review | the ticket's `context.md` |
| ticket-audit (both selector calls) | a tmp file holding the ticket text the skill already has |
| ticket-prescan | `""` on purpose: prescan docs are shared by every ticket, so one ticket's wording must not choose the specializer |

## Selection logic

### Base persona (from Layer/phase)

| Variable | Base persona |
|----------|-------------|
| Test-data ticket (strong signal, see below) (implement) | `test-data-engineer` |
| Layer = FE (implement) | `frontend-developer` |
| Layer = BE / infra (implement) | `backend-developer` |
| phase = appraise | `analyzer` |
| phase = review | `analyzer` |
| phase = audit | `product-owner` |

### Specializer (from stack signals)

| Signal | Specializer |
|--------|------------|
| `pyproject.toml` / `requirements.txt` / `pyenv`/`pipenv` in BE_TEST_RUNNER | `backend/python` |
| `pom.xml` / `build.gradle` | `backend/java` |
| `pom.xml` / `build.gradle` + ticket has upgrade/migration keywords | `backend/java-migration` |
| `pom.xml` / `build.gradle` + ticket has refactor/restructure keywords | `backend/java-refactor` |
| `pyproject.toml` / `requirements.txt` + ticket has refactor/restructure keywords | `backend/python-refactor` |
| `package.json` (Node backend) + ticket has refactor/restructure keywords | `backend/node-refactor` |
| `package.json` w/o FE framework markers | `backend/node` |
| `angular.json` | `frontend/angular` |
| `react`/`react-dom` in `package.json` | `frontend/react` |
| `vue` in `package.json` | `frontend/vue` |
| QA phase + UAT_URL present | `qa/playwright-web` |
| QA phase + no UAT_URL | `qa/api-testing` |
| Multi-service repo structure | `architect/microservices` |
| Single-service repo structure | `architect/monolith` |

### Debugger overlay

`debugger` is an overlay, not a base. It is emitted as `PERSONA_DEBUG` (plus `PERSONA_DEBUG_SPECIALIZER`) next to the normal base and specializer. `PERSONA_BASE` and the other keys do not change.

| Input | Overlay |
|-------|---------|
| `--remediation` | on, **for any type** (the verify rework path in ticket-implement passes it) |
| `--type bug` | on |
| `--type <other known type>` | off (an explicit type wins over the manifest) |
| `--type ""` | treated as absent |
| `--type <unknown>` | exit 1, message lists the known types |
| No `--type`, `TICKET_ID` and `REPOS_ROOT` set, planner manifest `type` = `bug` | on (manifest fallback via `lib/manifest-read.sh`) |
| No `--type`, no manifest or manifest `type` is not `bug` | off |
| `--phase prescan` | both keys always empty |

The known types mirror `KNOWN_TYPES` in `lib/template-select.sh`. The skills derive `--type` from the manifest `type` (dropping any value outside that list, so a new planner type cannot make the selector exit 1), else `bug` when the ticket's labels contain `bug`. Keep the skills' list in sync with `template-select.sh`. A hand-filed bug with neither a manifest type nor a `bug` label gets no overlay.

`PERSONA_DEBUG_SPECIALIZER` picks a `debug/*` file from the same stack detection as the specializer (`detect_stack`; an empty layer tries BE, then FE):

| Stack signal | Debug specializer |
|--------------|-------------------|
| Python markers, or `pyenv`/`pipenv` in BE_TEST_RUNNER (BE/infra) | `debug/python` |
| `pom.xml` / `build.gradle` (BE/infra) | `debug/jvm` |
| `package.json` without FE framework markers (BE/infra) | `debug/node` |
| `angular.json`, or `react`/`vue` in `package.json` (FE) | `debug/browser` |
| None | empty (debugger alone) |

The `debug/*` files are **evidence procedures** (which command or artifact to collect on that runtime), layered on top of the stack persona. They do not repeat stack idioms or list failure causes; those stay in `backend/*` and `frontend/*`.

Skills that read the overlay: ticket-implement (Step 2, and the Part B verify rework, which re-runs the selector with `--remediation`), ticket-pr-review (adds root-cause and regression-test requirements). ticket-appraise does not read the file; when the overlay is set it writes a `### Root cause hypothesis` subsection instead. ticket-implement logs `META|persona-select|info|base=…;spec=…;debug=…`.

### Auto-include (keyword triggers)

When ticket title/description contains: auth, authentication, login, password, credential, token, payment, billing, PII, personal data, encryption, vulnerability → auto-include `security`.

### Test-data persona

`test-data-engineer` covers tickets whose deliverable is test data (seed scripts, fixtures, import files, data loaded through an API or a form). It is emitted as `PERSONA_TESTDATA`, separately from the single-valued `PERSONA_AUTO_INCLUDE`.

| Signal | Effect |
|--------|--------|
| **Strong** — ticket text has a `## Test Data Provided` heading, a `Seed command:` line, or `<!-- planner:testdata-synth v1 -->` | `PERSONA_TESTDATA` set; on `--phase implement` `PERSONA_BASE` also becomes `test-data-engineer`, whatever the layer |
| **Weak** — seed data, test data, fixture(s), sample data, demo data, mock data, synthetic data, generate data, data load, bulk import | `PERSONA_TESTDATA` set; `PERSONA_BASE` unchanged (added alongside the layer persona, like `security`) |
| Neither | both keys empty |

`PERSONA_TESTDATA_SPECIALIZERS` lists up to 3 `specializers/testdata/<channel>.md` paths, colon-separated, chosen in this order:

1. An explicit `Seed channel: <list>` line (the planner writes one on every test-data ticket).
2. Keyword families in the ticket text — `sql` (SQL, insert, upsert, seed script, migration), `api` (endpoint, POST/PUT request, curl, REST API, GraphQL, via the API), `ui-forms` (form, screen, through/via the UI or app), `files` (CSV, XLSX, JSON fixture, upload, import file), `factories` (factory, builder, faker).
3. Repo probes — `sql` for a `db/migration` directory, `*.sql` files or Flyway/Liquibase; `api` for an OpenAPI/Swagger file; `factories` for factory_boy, factory_bot, Fishery, @faker-js/faker or Instancio; `ui-forms` only when `UAT_URL` is set and nothing else matched.

## Composition rule

Read `base/<role>.md`, then read the matching `specializers/<group>/<stack>.md`. The specializer **refines, never contradicts** the base. No match → specializer empty; base persona alone is sufficient. When set, the debugger overlay and its `debug/*` file are read after the stack persona.

**Size budget**: the worst-case implement bundle (backend-developer + backend/java + security + test-data-engineer + debugger + debug/jvm) must stay at or under 12288 bytes (12 KB). `lib/test-persona-select.sh` enforces this, plus ≤ 2560 B for `debugger.md` and ≤ 2048 B for each `debug/*` file.

## File inventory

### Base roles (10)

| File | Role | What it covers | Used by |
|------|------|----------------|---------|
| `base/architect.md` | Systems architecture specialist | System-wide impact analysis, coupling assessment, pattern consistency, scalability planning, architecture decision records | appraise, implement, pr-review |
| `base/backend-developer.md` | API and server-side specialist | API contract design, data integrity, error handling, performance optimization, idempotency, observability | implement (BE), audit |
| `base/frontend-developer.md` | UI/UX and accessibility specialist | Component architecture, UX consistency, responsive design, accessibility (WCAG 2.1 AA), bundle impact, cross-browser compatibility | implement (FE), audit |
| `base/qa-engineer.md` | Quality advocate and testing specialist | Coverage analysis, reproduction steps, regression risk, test quality, accessibility validation, performance regression detection | implement, pr-review, prescan (fan-out lens, `--with-qa`) |
| `base/analyzer.md` | Root cause specialist and systematic investigator | Complexity assessment, risk surface mapping, dependency analysis, appraisal quality, PR review depth, pattern recognition | appraise, pr-review, prescan (fan-out lens) |
| `base/product-owner.md` | Product requirement specialist | Business value assessment, requirement clarity, duplicate detection, merge opportunities, goal alignment, scope assessment | audit, appraise |
| `base/security.md` | Threat modeler and vulnerability specialist | Threat surface analysis, input validation, authn/authz checks, data handling, secrets management, dependency audit. Auto-includes on auth/payment/credential/PII keywords. | implement, pr-review, audit (auto-include) |
| `base/test-data-engineer.md` | Test data specialist | Given-clause data derivation, idempotent namespaced seeds, builders over shared fixtures, referential integrity, synthetic or masked data only, reset + README key map, needs-info on unknown sources | implement (base on test-data tickets), appraise, pr-review (added on test-data signals) |
| `base/debugger.md` | Root-cause debugging overlay | Reproduction first, one falsifiable hypothesis ("X because Y" plus what would disprove it), failing test before the fix, one change at a time; last-rework rule (evidence or `HUMAN_HOLD` before `VERIFY_EXHAUSTED`); stop after the third failed fix | implement (bug tickets, verify rework), pr-review (bug tickets) — overlay, see above |
| `base/technical-writer.md` | Documentation and technical writing specialist | Changelog quality, API documentation, README updates, commit message conventions, retro documentation, wiki maintenance | prescan (fan-out lens) |

### Specializers (23)

| Group | Stack | Extends | What it adds | Triggers |
|-------|-------|---------|--------------|----------|
| `backend` | `python.md` | backend-developer | Type hints (mypy), async/await patterns, pytest, virtual environments (pyenv/poetry), PEP 8/ruff formatting | `pyproject.toml`, `requirements.txt`, `pyenv`/`pipenv` in BE_TEST_RUNNER |
| `backend` | `python-refactor.md` | backend/python | Behavior-preserving restructure: extract function/class, replace conditional with polymorphism, context managers, generators. Safety: test suite as contract, mypy baseline, no new deps | Python stack + ticket has refactor/restructure keywords |
| `backend` | `node.md` | backend-developer | TypeScript strict mode, ESM vs CommonJS, Zod/Joi validation, Jest/Vitest, supertest, nock mocking, event loop awareness | `package.json` without FE framework markers |
| `backend` | `node-refactor.md` | backend/node | Guard clauses, async/await over callbacks, extract function/module, eliminate dead code (ts-prune). Safety: tsc --noEmit baseline, no new deps | Node stack + ticket has refactor/restructure keywords |
| `backend` | `java.md` | backend-developer | Spring Boot conventions, constructor injection, Maven/Gradle lifecycle, JUnit 5 + Mockito, TestContainers, Flyway/Liquibase migrations | `pom.xml`, `build.gradle` |
| `backend` | `java-migration.md` | backend/java | JDK version upgrade: deprecated API scan (jdeps/jdeprscan), library compatibility matrix, javax→jakarta, module system, incremental strategy, rollback safety | Java stack + ticket has upgrade/migration keywords |
| `backend` | `java-refactor.md` | backend/java | Extract method/class, replace conditional with polymorphism, interface segregation, dependency inversion. Safety: test suite as contract, Checkstyle/SpotBugs baseline, Lombok awareness | Java stack + ticket has refactor/restructure keywords |
| `frontend` | `angular.md` | frontend-developer | Standalone components, RxJS + async pipe, OnPush change detection, lazy loading, Karma/Jasmine or Jest, SCSS conventions | `angular.json` |
| `frontend` | `react.md` | frontend-developer | Hooks (useState/useReducer/useContext), React.memo, code splitting (lazy+Suspense), Jest + RTL + msw, stale closure awareness | `react`/`react-dom` in `package.json` |
| `frontend` | `vue.md` | frontend-developer | Composition API (<script setup>), Pinia stores, ref/reactive/computed, Vitest + @vue/test-utils, scoped styles, SSR hydration (Nuxt) | `vue` in `package.json` |
| `qa` | `playwright-web.md` | qa-engineer | Page Object Model, accessibility snapshots, user-flow-first verification, getByRole/getByLabel selectors, waitFor assertions, multi-viewport testing | UAT_URL present (web flow) |
| `qa` | `api-testing.md` | qa-engineer | Contract testing (OpenAPI/JSON Schema), status code assertions, auth token handling (valid/expired/malformed), idempotency verification, error message leakage detection | No UAT_URL (API-only) |
| `architect` | `microservices.md` | architect | Bounded contexts, event-driven communication, API Gateway, Saga pattern, distributed tracing (OpenTelemetry), independent deployability | Multi-service directory structure |
| `testdata` | `sql.md` | test-data-engineer | Upserts (`ON CONFLICT`/`MERGE`), FK-ordered inserts, deterministic ids, Flyway/Liquibase seed locations kept out of production, reset by key prefix | `Seed channel: sql`, SQL keywords, migrations dir / `*.sql` / Flyway / Liquibase |
| `testdata` | `api.md` | test-data-engineer | Seeding through the app's own API, GET-before-POST / PUT-by-key idempotency, contract-shaped payloads, async side effects, env-var credentials | `Seed channel: api`, endpoint keywords, OpenAPI/Swagger file |
| `testdata` | `ui-forms.md` | test-data-engineer | Playwright form-fill as last resort, role/label selectors, wait for persistence, re-run safety, no captcha/MFA workarounds | `Seed channel: ui-forms`, form/UI keywords, UAT_URL fallback |
| `testdata` | `files.md` | test-data-engineer | CSV/XLSX/JSON golden files, header contract, edge-case rows (BOM, encoding, delimiters), generated large files, idempotent import | `Seed channel: files`, CSV/XLSX/upload/import keywords |
| `testdata` | `factories.md` | test-data-engineer | factory_boy / factory_bot / Fishery+faker / Java builders / Instancio, fixed faker seed, builders over Object Mother, test-scope wiring | `Seed channel: factories`, factory/builder/faker keywords, factory library in the repo |
| `debug` | `jvm.md` | debugger | `Caused by:` chain bottom-up, `jstack`/`jcmd Thread.print` and `GC.heap_info` snapshots, boundary logging with the correlation id, local-only `jdwp` attach | JVM stack + debugger overlay |
| `debug` | `python.md` | debugger | Tracebacks bottom-up, `breakpoint()`, boundary `logging`, `asyncio` debug mode | Python stack + debugger overlay |
| `debug` | `node.md` | debugger | `--inspect`/`--inspect-brk`, `--trace-uncaught`, source maps, event-loop lag check | Node backend + debugger overlay |
| `debug` | `browser.md` | debugger | Playwright snapshot, `browser_console_messages`, network capture, Angular `ng.getComponent`/zone trace, RxJS subscription count | FE stack + debugger overlay |
| `architect` | `monolith.md` | architect | Modular monolith patterns, layered architecture, feature-based packaging, module boundary enforcement (ArchUnit/dep-cruiser), extraction-ready design | Single-service structure |

## Versioning

Each persona file carries `version` (integer) and `last-reviewed` (ISO date) in its YAML frontmatter. `personas/CHANGELOG.md` records all changes.

## Refreshing personas

Run `/ticket-persona-refresh persona=<name>` to check a persona against current best practices. The skill:

1. Reads the persona to identify its tech stack (libraries, frameworks, tools, versions)
2. Fetches current docs via Context7 and web search
3. Compares persona guidance against current recommendations
4. Proposes a diff showing outdated, missing, and confirmed items
5. Waits for approval before applying changes

Use `persona=all` to refresh all personas. Use `persona=backend/python` for a single specializer.

**Executors**: `lib/persona-refresh.sh` handles the mechanical mutations (version bump, changelog append, file write). The skill handles the research and reasoning. This follows the same determinism boundary as `ticket-flow` → `flow.sh`.
