# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

A minimal calculator application used as an end-to-end test harness for the user `ticket-auto-pipeline`. Tickets in the `user Sandbox` Linear project drive feature development here — the codebase is intentionally empty at the start and grows as the pipeline processes tickets.

## Codebase Projects

All source repositories live as siblings under `~/work/e2e-conduit/`:

| Directory         | Layer | Purpose                                    | CLAUDE.md |
| ----------------- | ----- | ------------------------------------------ | --------- |
| `app/` | FE+BE | Calculator app — Express backend + Vite FE | yes       |

When a ticket touches code, read files directly using their absolute paths under `~/work/e2e-conduit/`. Always read this `CLAUDE.md` before making changes.

## Stack

- **Backend (BE):** Node.js / Express — serves REST API on port 3000
- **Frontend (FE):** Vite + vanilla JS — dev server on port 5173

## Linear Integration

- **Team:** `TKT`
- **Project:** `user Sandbox`
- **Issue prefix:** `TKT`

Ticket IDs follow the pattern `TKT-\d+`. All state transitions go through `/ticket-flow`.

## Environment URLs

`LOCAL_URL` = `http://localhost:5173`

`UAT_URL` = `http://localhost:5173`

## Build & Test

| Context | Command |
|---------|---------|
| BE unit tests | `npm test` (run from `backend/`) |
| FE dev server | `npm run dev` (run from `frontend/`) |
| FE type check | `npm run build` |

`BE_TEST_CMD` = `npm test`

`REPOS_ROOT` = `~/work/e2e-conduit`

## Conventions

- Issue IDs follow the pattern `TKT-\d+` (project key + number).
- Backend code lives in `backend/`, frontend in `frontend/`.
- This repo is empty at the start — the pipeline creates the initial structure.
