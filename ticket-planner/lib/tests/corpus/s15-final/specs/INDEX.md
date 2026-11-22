# Spec index: INIT-0000000000-5702

Conduit-lite sign-up, login and articles. Eight ticket specs, in dependency order. All of them change one service, `app`.

| # | Spec file | Title | Type | Kind | Affected service | Depends on |
|---|-----------|-------|------|------|------------------|------------|
| 1 | `scaffold-packages.md` | Scaffold the backend and frontend packages for Conduit-lite | chore | enabler (O1, O2) | app (FE+BE) | none |
| 2 | `store-and-seed.md` | Add the in-memory store with the seeded authors and articles | chore | enabler (O1, O2) | app (BE) | scaffold-packages |
| 3 | `auth-endpoints.md` | Authors can register, sign in and fetch their account through the API | feature | business (O1) | app (BE) | scaffold-packages, store-and-seed |
| 4 | `article-endpoints.md` | Authors can publish articles and anyone can read and list them through the API | feature | business (O1, O2) | app (BE) | scaffold-packages, store-and-seed, auth-endpoints |
| 5 | `frontend-shell.md` | The site header shows sign-in links or the signed-in author's name | feature | business (O1, O2) | app (FE) | scaffold-packages, store-and-seed, auth-endpoints |
| 6 | `read-pages.md` | Anonymous readers can browse the article list and open an article | feature | business (O2) | app (FE) | scaffold-packages, store-and-seed, article-endpoints, frontend-shell |
| 7 | `sign-in-and-sign-up-pages.md` | Authors can sign up and sign in from the browser | feature | business (O1) | app (FE) | scaffold-packages, store-and-seed, auth-endpoints, frontend-shell, read-pages |
| 8 | `editor-page.md` | Authors can publish a new article from the browser | feature | business (O1) | app (FE) | scaffold-packages, store-and-seed, auth-endpoints, article-endpoints, frontend-shell, read-pages, sign-in-and-sign-up-pages |

Test data: `store-and-seed` seeds the two authors and two articles and carries the `## Test Data Provided` section. Every other spec cites it as `seeded-by:store-and-seed`. No row uses `generate`.

Acceptance check 1 of the intent (`npm test` in `backend/` covers every endpoint and each error case) is complete after `article-endpoints`. Acceptance check 2 (the browser walk) is complete after `editor-page`.
