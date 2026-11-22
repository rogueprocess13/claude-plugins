# Spec Index — INIT-0000000000-2767 (Conduit-lite)

| # | Spec | Title | Affected service | Kind | Type | Dependencies |
|---|------|-------|------------------|------|------|--------------|
| 1 | [backend-scaffold](backend-scaffold.md) | Scaffold the Express backend with a node:test runner | app backend | enabler | chore | none |
| 2 | [user-accounts-api](user-accounts-api.md) | Authors can register, sign in and fetch their account through the API | app backend | business | feature | backend-scaffold |
| 3 | [articles-api](articles-api.md) | Authors can publish articles and anyone can read them through the API | app backend | business | feature | backend-scaffold, user-accounts-api |
| 4 | [frontend-shell](frontend-shell.md) | Set up the Vite frontend shell with routing, session check and header | app frontend | enabler | chore | backend-scaffold, user-accounts-api |
| 5 | [sign-up-and-sign-in-pages](sign-up-and-sign-in-pages.md) | Authors can sign up and sign in from the browser | app frontend | business | feature | backend-scaffold, frontend-shell, user-accounts-api |
| 6 | [reader-pages](reader-pages.md) | Anyone can browse and read published articles | app frontend | business | feature | backend-scaffold, frontend-shell, articles-api |
| 7 | [article-editor-page](article-editor-page.md) | Authors can publish a new article from the editor | app frontend | business | feature | backend-scaffold, frontend-shell, articles-api, sign-up-and-sign-in-pages, reader-pages |
| 8 | [conduit-repo-docs](conduit-repo-docs.md) | Describe Conduit-lite in the app README and CLAUDE.md | app docs | enabler | chore | backend-scaffold, frontend-shell |

<!-- planner:testdata-synth index begin -->
## Test data specs (synthesized by Crosscheck)

- `backend-scaffold-test-data` — synthesized test data (single) for `backend-scaffold`
<!-- planner:testdata-synth index end -->
