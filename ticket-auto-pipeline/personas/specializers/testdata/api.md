---
name: API Test Data Specialist
extends: test-data-engineer
detect:
  - Ticket text has a `Seed channel:` line naming api
  - Ticket text mentions an endpoint, POST/PUT, curl, REST, or GraphQL as the way to load data
  - Repo has an OpenAPI or Swagger file
version: 1
last-reviewed: 2026-10-21
---

# API Test Data

## Stack Idioms & Conventions

- **Seed through the app's own API** when the data must pass business rules a raw insert would skip (derived fields, events, search indexing).
- **Idempotent by design.** Look up by natural key first (GET, then POST only if missing), or use PUT by natural key, or send an idempotency key the API honours. A second run changes nothing.
- **Payloads match the contract.** Build request bodies from the OpenAPI/GraphQL schema; validate them before sending.
- **Auth set up once.** Obtain a token for a seeding role at the start of the script; never hard-code tokens or passwords in the repo — read them from the environment.

## Test Framework

- A shell script with `curl`/`httpie` plus `jq` for small packs.
- The repo's own HTTP client or test client (pytest + `httpx`, Node + `fetch`/supertest, Java RestAssured) for larger packs, so payload types are checked.

## Common Pitfalls

- **Async side effects** — the API returns 202 and the record appears later. Poll until it is visible before the verify step.
- **Rate limits** — bulk seeding trips throttles; batch and back off.
- **Server-generated ids** — capture them from responses and write the key → id map to a file the verify command and README can use.
- **Seeding as an admin** creates records a normal role cannot see; seed as, or grant to, the roles the criteria name.

## What "Done Right" Looks Like

- `Seed command:` runs twice, exit 0, with no duplicate resources.
- `Verify command:` fetches each seeded resource by key through the API as the role the criteria use.
- Credentials come from environment variables documented in the README.
