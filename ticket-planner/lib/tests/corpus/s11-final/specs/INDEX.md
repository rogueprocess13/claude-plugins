# Spec Index — INIT-0000000000-5252 (Conduit-lite)

| # | Spec | Title | Kind | Type | Affected service | Blocked by |
|---|------|-------|------|------|------------------|------------|
| 1 | [backend-scaffold](backend-scaffold.md) | Scaffold the Express backend with an in-memory store and Jest test runner | enabler (O1, O2, O3) | chore | app | none |
| 2 | [backend-auth](backend-auth.md) | Authors can register, sign in and fetch their account through the API | business (O1) | feature | app | backend-scaffold |
| 3 | [backend-articles-read](backend-articles-read.md) | Anyone can list articles and read one article through the API | business (O3) | feature | app | backend-scaffold, backend-auth |
| 4 | [backend-articles-publish](backend-articles-publish.md) | Signed-in authors can publish articles through the API | business (O2) | feature | app | backend-scaffold, backend-auth, backend-articles-read |
| 5 | [frontend-scaffold](frontend-scaffold.md) | Scaffold the Vite frontend shell with client-side routing and an API proxy | enabler (O1, O2, O3) | chore | app | backend-scaffold |
| 6 | [frontend-auth-pages](frontend-auth-pages.md) | Authors can sign up and sign in from the browser | business (O1) | feature | app | backend-scaffold, backend-auth, frontend-scaffold |
| 7 | [frontend-reading-pages](frontend-reading-pages.md) | Readers can browse the article list and open an article | business (O3) | feature | app | backend-scaffold, backend-articles-read, frontend-scaffold, frontend-auth-pages |
| 8 | [frontend-editor](frontend-editor.md) | Signed-in authors can publish a new article from the editor | business (O2) | feature | app | backend-scaffold, backend-auth, backend-articles-publish, frontend-scaffold, frontend-auth-pages, frontend-reading-pages |
| 9 | [repo-docs](repo-docs.md) | Describe app as the Conduit-lite app in CLAUDE.md and README | enabler (none) | chore | app | backend-scaffold |

Order: 1 → (2, 5, 9) → (3, 6) → (4, 7) → 8. The graph has no cycles. `frontend-reading-pages` waits for `frontend-auth-pages` so the two never edit `frontend/src/main.js` or `frontend/src/api.js` on parallel branches.
