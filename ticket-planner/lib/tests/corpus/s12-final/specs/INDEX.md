# Spec Index — INIT-0000000000-5856

| # | Spec | Title | Kind | Type | Affected service | Depends on |
|---|------|-------|------|------|------------------|------------|
| 1 | [backend-foundation](backend-foundation.md) | Scaffold the Conduit-lite backend with a seeded in-memory store and npm test | enabler | chore | app (backend) | — |
| 2 | [user-auth-api](user-auth-api.md) | Authors can register, sign in and fetch their account through the API | business (O2) | feature | app (backend) | backend-foundation |
| 3 | [articles-api](articles-api.md) | Authors can publish articles and anyone can read and list them through the API | business (O1, O3) | feature | app (backend) | backend-foundation, user-auth-api |
| 4 | [frontend-shell](frontend-shell.md) | The page header shows whether the visitor is signed in | business (O2) | feature | app (frontend) | backend-foundation, user-auth-api |
| 5 | [reader-pages](reader-pages.md) | Anonymous readers can browse the article list and open an article | business (O1) | feature | app (frontend) | backend-foundation, articles-api, frontend-shell |
| 6 | [auth-pages](auth-pages.md) | People can sign up and sign in from the web app | business (O2) | feature | app (frontend) | backend-foundation, user-auth-api, frontend-shell, reader-pages |
| 7 | [editor-page](editor-page.md) | Signed-in authors can publish an article from the editor | business (O3) | feature | app (frontend) | backend-foundation, user-auth-api, articles-api, frontend-shell, reader-pages, auth-pages |
| 8 | [repo-docs-conduit](repo-docs-conduit.md) | Replace the calculator description in the repository docs with Conduit-lite | enabler | chore | app (docs) | — |

Dependency order (a DAG): backend-foundation → user-auth-api → articles-api / frontend-shell → reader-pages → auth-pages → editor-page. repo-docs-conduit is independent.
