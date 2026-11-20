# Notes (reduced copy: an edit-article ticket with API rows and page rows)

| \# | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
| -- | -- | -- | -- | -- | -- | -- |
| 1 | `PUT /api/articles/my-post` with the author's token returns 200. | Author | No screen. API only: `npm test` in `backend/` | seeded article | 200 | ✓ |
| 2 | The article page shows an `Edit Article` link to its author. | Author | Open the site > sign in > open the article | seeded article | the link is visible | ✓ |
| 3 | Saving the form returns to the article page with the new title. | Author | Open the article > click `Edit Article` > change the title > click the `Update Article` button | seeded article | the new title is visible | ✓ |
