# api-server

## Description

Server fixture spec whose numbers are ports, costs, limits, passwords and frontend handlers, not uncovered responses.

## Proposed Behaviour

- The server listens on port 3000 and hashes passwords with bcryptjs at cost 10.
- The list endpoint caps `limit` at 100 and returns at most 100 entries.
- The seeded author has password `Pass-123`.
- A missing token returns 401 `{"errors":{"token":["is missing or invalid"]}}`.

## Technical Context

- The page handles the response: on 401, clear the stored token and show the sign-in link.

```
// fenced: return res.status(503).json({})
```

## Acceptance Criteria

- [ ] A request with no token returns 401 `{"errors":{"token":["is missing or invalid"]}}`

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| A request with no token returns 401 `{"errors":{"token":["is missing or invalid"]}}` | anonymous | none | — | as stated | yes |
