# Personas Changelog

## 2026-10-24 — Debugger overlay

### Added
- `base/debugger.md` (v1) — root-cause debugging overlay: reproduction, one falsifiable hypothesis, failing test first, one change at a time, last-rework rule before `VERIFY_EXHAUSTED`, stop after the third failed fix
- `specializers/debug/jvm.md` (v1)
- `specializers/debug/python.md` (v1)
- `specializers/debug/node.md` (v1)
- `specializers/debug/browser.md` (v1)

Selected by `lib/persona-select.sh` on `--type bug`, `--remediation` (any type) or a planner manifest `type` of `bug`, and emitted as `PERSONA_DEBUG` / `PERSONA_DEBUG_SPECIALIZER`. The `debug/*` files are evidence procedures layered on the stack persona, not stack idioms (debugger-persona-overlay).

### Changed
- `base/analyzer.md`, `base/qa-engineer.md`, `base/technical-writer.md` — `used-by` frontmatter corrected. It listed skills that have never loaded a persona (ticket-critique; ticket-verify; ticket-document, ticket-retro, wiki-maintenance). Replaced with `ticket-prescan (fan-out lens)`, which is where these roles are actually loaded. Content, `version` and `last-reviewed` unchanged. `lib/tests/test-persona-injection.sh` now cross-checks `used-by` against real selector calls.

## 2026-10-22 — Test data engineer v2

### Changed
- `base/test-data-engineer.md` (v2) — `Seed command:` / `Verify command:` must be `make <target>` (or `make -C <relpath> <target>`) targets the ticket creates; VERIFY's seed-apply refuses any other command shape (planner-test-data-derivation)

## 2026-10-21 — Test data engineer

### Added
- `base/test-data-engineer.md` (v1) — role for tickets whose deliverable is test data
- `specializers/testdata/sql.md` (v1)
- `specializers/testdata/api.md` (v1)
- `specializers/testdata/ui-forms.md` (v1)
- `specializers/testdata/files.md` (v1)
- `specializers/testdata/factories.md` (v1)

Selected by `lib/persona-select.sh` (strong/weak test-data signal, channel precedence) and emitted as `PERSONA_TESTDATA` / `PERSONA_TESTDATA_SPECIALIZERS`.

## 2026-06-26 — Initial versioning

### Added
- `version` and `last-reviewed` fields to all 22 persona YAML frontmatter blocks
- This CHANGELOG.md file

### Base roles (v1)
- `base/analyzer.md`
- `base/architect.md`
- `base/backend-developer.md`
- `base/frontend-developer.md`
- `base/product-owner.md`
- `base/qa-engineer.md`
- `base/security.md`
- `base/technical-writer.md`

### Specializers (v1)
- `specializers/backend/java.md`
- `specializers/backend/java-migration.md`
- `specializers/backend/java-refactor.md`
- `specializers/backend/node.md`
- `specializers/backend/node-refactor.md`
- `specializers/backend/python.md`
- `specializers/backend/python-refactor.md`
- `specializers/frontend/angular.md`
- `specializers/frontend/react.md`
- `specializers/frontend/vue.md`
- `specializers/qa/api-testing.md`
- `specializers/qa/playwright-web.md`
- `specializers/architect/microservices.md`
- `specializers/architect/monolith.md`
