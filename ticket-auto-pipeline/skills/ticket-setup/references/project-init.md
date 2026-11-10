# ticket-setup — Step 0.4 Initialize CLAUDE.md

Read only under the condition in SKILL.md Step 0.4: `CLAUDE.md` is missing at the project root. Steps 0.1–0.3 and 0.5 stay in SKILL.md.

## Step 0.4 — Initialize CLAUDE.md (if missing)

If `CLAUDE.md` is missing, determine the project state and initialize:

#### Step 0.4a — Check GitNexus for existing codebase knowledge

Call `mcp__gitnexus__list_repos` to check if any repo under the project root is already indexed. If GitNexus has data on this project, use `mcp__gitnexus__context` or `mcp__gitnexus__query` to gather:

- Architecture: service names, key modules, directory layout
- Entry points: API routes, main functions, build targets
- Dependencies: external services, databases, frameworks

With this context, run `/claude-md-management:revise-claude-md` (or invoke `claude-md-improver` skill) to create the initial CLAUDE.md. Pass the GitNexus findings as context so the generated CLAUDE.md reflects the actual codebase structure.

#### Step 0.4b — Check for existing code (no GitNexus)

If GitNexus has no data on this project, check if the project directory has code:
- Check for common project files: `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Makefile`, `justfile`, `docker-compose.yml`, source directories (`src/`, `lib/`, `app/`)
- Check if `.git` exists and has commits

If code exists: run `/claude-md-management:revise-claude-md` to create the initial CLAUDE.md. Claude will analyze the codebase naturally through file reads and project structure detection.

#### Step 0.4c — Empty project fallback

If the project directory has no code, no `.git` (or empty repo with no commits), and no GitNexus data:

1. Extract project context from the ticket:
   - **Project name**: from `{PROJECT_NAME}` in the ticket (Linear project field)
   - **Epic context**: from `{EPIC_TITLE}` if the ticket belongs to an epic
   - **Ticket title and description**: from `{TITLE}` and `{DESCRIPTION}` — these describe what the project needs to do
   - **Labels**: from `{LABEL_NAMES}` — may indicate tech stack (e.g., `frontend`, `backend`, `api`)

2. Run `claude init` on the project root. When prompted for the project description, provide:
   > "Project: {PROJECT_NAME}. Epic: {EPIC_TITLE}. First task: {TITLE} — {DESCRIPTION}"

3. Claude init will analyze the directory (even if empty), prompt for key details, and generate CLAUDE.md with the project description, build instructions, and architecture. The ticket context seeds the project's purpose and initial scope.

4. After `claude init` completes, verify `CLAUDE.md` was created at the project root.
