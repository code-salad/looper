---
name: git-commit
description: Stages and commits changes using conventional commit format. Analyzes the diff to determine the correct type, scope, and message.
argument-hint: "[optional: commit description or context]"
user-invocable: true
allowed-tools: Bash(git), Read, Grep, Glob
---

# Git Commit Skill

Analyzes staged/unstaged changes, determines the appropriate conventional commit type and scope, and creates a well-formed commit.

## Prerequisites

- Must be in a git repository
- Must have uncommitted changes (staged or unstaged)

---

## Phase 1: Gather Changes

Run these in parallel:

```bash
# Check repo status
git status

# See unstaged changes
git diff

# See staged changes
git diff --cached

# Recent commits for style reference
git log --oneline -10
```

**Gate:** Abort with "Nothing to commit." if there are no staged or unstaged changes and no untracked files.

---

## Phase 2: Analyze Changes

### 2a. Read changed files

Use `git diff --name-only` and `git diff --cached --name-only` to identify changed files. Read the most important ones to understand what changed and why.

### 2b. Determine commit type

Classify the changes into exactly ONE of these types:

| Type | When to use |
|------|-------------|
| `feat` | A new feature or capability for the user |
| `fix` | A bug fix |
| `refactor` | Code restructuring with no behavior change |
| `test` | Adding or updating tests only |
| `docs` | Documentation-only changes |
| `chore` | Maintenance tasks (deps, config, tooling) |
| `perf` | Performance improvements |
| `style` | Formatting, whitespace, linting — no logic change |
| `ci` | CI/CD pipeline changes |
| `build` | Build system or dependency changes |

If changes span multiple types, use the **most significant** type. For example, a feature that also adds tests → `feat`. A refactor that also fixes a bug → `fix`.

### 2c. Determine scope (optional)

Infer a short scope from the area of the codebase affected:

- Module or directory name (e.g., `auth`, `api`, `db`, `ui`)
- Feature area (e.g., `login`, `search`, `payments`)
- File or component (e.g., `Button`, `router`)

Omit scope if the change is broad or no single scope fits well.

### 2d. Write the summary

- Use **imperative mood** ("add feature" not "added feature" or "adds feature")
- Keep it under 50 characters (the type/scope prefix does NOT count toward this)
- Do not capitalize the first word
- Do not end with a period
- Be specific — "fix null pointer in user lookup" not "fix bug"

### 2e. Write the body (optional)

Add a body only when the summary alone does not explain **why** the change was made. The body should:

- Explain motivation or context, not restate the diff
- Be 1-3 sentences max
- Be separated from the summary by a blank line

### 2f. Note breaking changes

If this commit introduces a breaking change:

- Add `!` after the type/scope: `feat(api)!: remove legacy endpoint`
- Add a `BREAKING CHANGE:` footer explaining what breaks and how to migrate

---

## Phase 3: Stage and Commit

### 3a. Stage files

```bash
# Stage specific files — be explicit
git add <files>
```

**NEVER stage files matching these patterns:**
- `.env*`
- `*.pem`, `*.key`, `*.cert`
- `credentials*`, `secrets*`, `*.secret`
- `node_modules/`, `__pycache__/`, `.venv/`
- `*.sqlite`, `*.db` (unless intentional)

If any sensitive files are detected, warn the user and exclude them.

### 3b. Commit

```bash
git commit -m "$(cat <<'EOF'
<type>[optional scope][optional !]: <summary>

[optional body]

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

**Concrete examples:**

```
feat(auth): add OAuth2 login flow
```

```
fix: resolve null pointer in user lookup

The user object was not being checked for null after the database
query when the session had expired.
```

```
refactor(api)!: remove legacy v1 endpoints

BREAKING CHANGE: All /api/v1/* routes have been removed.
Consumers must migrate to /api/v2/*.
```

```
chore: update dependencies to latest versions
```

```
test(payments): add integration tests for refund flow
```

---

## Phase 4: Confirm

After the commit succeeds, run:

```bash
git log --oneline -1
```

Report the commit hash and message to the user.

---

## Error Handling

| Scenario | Action |
|----------|--------|
| No changes to commit | Abort: "Nothing to commit." |
| Sensitive files in working tree | Warn user, exclude from staging, list them |
| Pre-commit hook fails | Report the failure, do NOT retry with `--no-verify`. Fix the issue and create a NEW commit. |
| Merge conflict markers in files | Abort: "Resolve merge conflicts before committing." |
