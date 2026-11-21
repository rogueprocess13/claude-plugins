# Spec Index — INIT-0000000000-9899

| # | Spec | Title | Affected service | Kind | Type | Dependencies |
|---|------|-------|------------------|------|------|--------------|
| 1 | backend-foundation | Scaffold the Express backend with a seeded in-memory store and test runner | app | enabler | chore | — |
| 2 | api-article-reads | Anyone can list and read articles through the API | app | business | feature | backend-foundation |
| 3 | api-user-auth | Authors can register, sign in and fetch their account through the API | app | business | feature | backend-foundation |
| 4 | api-article-create | Signed-in authors can publish an article through the API | app | business | feature | backend-foundation, api-user-auth, api-article-reads |
| 5 | frontend-shell | The app header shows whether a person is signed in | app | enabler | feature | backend-foundation, api-user-auth |
| 6 | frontend-read-pages | Readers can browse the article list and open an article | app | business | feature | frontend-shell, api-article-reads |
| 7 | frontend-auth-pages | Authors can sign up and sign in from the app | app | business | feature | frontend-shell, api-user-auth |
| 8 | frontend-editor | Signed-in authors can publish an article from the editor | app | business | feature | frontend-shell, frontend-auth-pages, frontend-read-pages, api-article-create |
| 9 | docs-conduit-description | Replace the calculator description in CLAUDE.md and README.md with Conduit-lite | app | enabler | chore | api-user-auth, frontend-editor |
