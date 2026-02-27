---
name: loop
description: Use this skill when the user wants to run an iterative Plan-Do-Check agent loop. Three agents (Planner, Doer, Checker) cycle until the Checker passes the work. Triggered by "/loop" followed by a task description.
tools: Bash, Read, Edit, Write, Grep, Glob, Task
---

# PDC Loop Skill

Executes the Plan-Do-Check loop for a given task. Three subagents
(Planner, Doer, Checker) iterate until the Checker issues a PASS verdict.

## Prerequisites

- Must be in a git repository
- `git` must be available

## Steps

### 1. Validate environment

```bash
git rev-parse --is-inside-work-tree
```

**Gate:** Abort if not in a git repo.

### 2. Validate argument

If `$ARGUMENTS` is empty, ask the user for a task description. Do not proceed without one.

### 3. Generate task name

Sanitize the task description into a kebab-case task name suitable for use as
a conventional commit scope:

- Lowercase
- Replace spaces and underscores with hyphens
- Remove non-alphanumeric characters (except hyphens)
- Truncate to 50 characters
- Remove leading/trailing hyphens

Example: "Add User Authentication Flow" -> "add-user-authentication-flow"

### 4. Create a worktree

Create an isolated worktree so the loop does not modify the current branch
directly. Use the task name as the worktree name.

1. **Ensure `.worktrees` is gitignored** -- Check if `.gitignore` at the repo
   root already contains `.worktrees`. If not, append it (create the file if
   needed), then stage and commit with message `chore: gitignore .worktrees`.
   Skip the commit if already up to date.

2. **Create the worktree:**

   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   git worktree add "$REPO_ROOT/.worktrees/$TASK_NAME"
   ```

   If the worktree already exists (e.g. resuming a previous run), just `cd`
   into it instead of recreating.

3. **Change into the worktree:**

   ```bash
   cd "$REPO_ROOT/.worktrees/$TASK_NAME"
   ```

### 5. Build project context

Before entering the loop, collect project context that agents need. Read the
following files (skip any that don't exist) and assemble them into a single
context block stored in a variable called `PROJECT_CONTEXT`:

**Project docs:**
- `CONTRIBUTING.md`
- `AGENTS.md`
- `README.md`
- `.github/PULL_REQUEST_TEMPLATE.md`
- `.editorconfig`

**Build/script config (extract relevant sections):**
- `package.json` -- extract the `scripts` object
- `Makefile` -- extract target names (lines matching `^[a-zA-Z_-]+:`)
- `pyproject.toml` -- read entire file
- `Cargo.toml` -- read entire file

Format each file's content as:

```
---
## File: <filename>

<contents>
```

Store the combined output as `PROJECT_CONTEXT` for use in step 7.

### 6. Detect resume iteration

Resolve the `SCRIPTS_DIR` path **before** using the worktree, using
`CLAUDE_PLUGIN_ROOT` or the original repo root:

```bash
SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT:-${REPO_ROOT}}/skills/loop/scripts"
```

Query git log for prior loop iterations to detect whether to resume:

```bash
# Find the last iteration number
LAST_ITERATION=$(git log --grep="Loop-Phase:" --grep="Loop-Iteration:" \
    --all-match --format="%B" -1 2>/dev/null \
    | grep -oP 'Loop-Iteration: \K[0-9]+' || echo "0")

# Find the last verdict
LAST_VERDICT=$(git log --grep="Loop-Verdict:" -1 --format="%B" 2>/dev/null \
    | grep -oP 'Loop-Verdict: \K(PASS|FAIL)' || echo "")
```

Determine the start iteration:
- If `LAST_VERDICT` is `FAIL`: start at `LAST_ITERATION + 1`
- If `LAST_ITERATION > 0` and no verdict: resume at `LAST_ITERATION` (mid-iteration)
- Otherwise: start at `1`

If resuming (start > 1), report: "Resuming from iteration N (prior iterations found in git log)"

### 7. Run the PDC loop

Set `MAX_ITERATIONS=10`. For each iteration from `START_ITERATION` to `MAX_ITERATIONS`:

#### 7a. Get loop context

Run the git-loop-context script to retrieve prior iteration history:

```bash
$SCRIPTS_DIR/git-loop-context --task "$TASK_NAME" --iteration $ITERATION
```

Store the output as `LOOP_CONTEXT`.

#### 7b. Build the agent context prompt

Construct a context string that will be passed to each subagent. It must contain:

```
<project-context>
${PROJECT_CONTEXT}
</project-context>

You MUST follow the conventions and instructions in <project-context>.
Pay special attention to CONTRIBUTING.md for build/test/lint/commit conventions.

---

## Task Variables

- **TASK_NAME:** ${TASK_NAME}
- **ITERATION:** ${ITERATION}
- **TASK_PROMPT:** ${TASK_PROMPT}
- **SCRIPTS_DIR:** ${SCRIPTS_DIR}

## Prior Loop Context

${LOOP_CONTEXT}
```

Where `TASK_PROMPT` is the original `$ARGUMENTS` text from the user.

#### 7c. Spawn Planner

Spawn the planner agent using the Task tool:

```
Task(subagent_type="looper:planner", prompt=<context from 7b>)
```

Wait for it to complete before proceeding.

#### 7d. Spawn Doer

Spawn the doer agent using the Task tool:

```
Task(subagent_type="looper:doer", prompt=<context from 7b>)
```

Wait for it to complete before proceeding.

#### 7e. Spawn Checker

Spawn the checker agent using the Task tool:

```
Task(subagent_type="looper:checker", prompt=<context from 7b>)
```

Wait for it to complete before proceeding.

#### 7f. Read verdict

After the checker completes, read the verdict from git log:

```bash
VERDICT=$(git log --grep="Loop-Verdict:" -1 --format="%B" \
    | grep -oP 'Loop-Verdict: \K(PASS|FAIL)' || echo "")
```

- If `VERDICT` is `PASS`: break out of the loop, proceed to step 8.
- If `VERDICT` is `FAIL`: report "FAIL -- Iteration N. Continuing to next iteration..." and continue.
- If no verdict found: treat as FAIL and continue.

### 8. Report results

After the loop exits, check the final state:

- **PASS:** Report success. Show the number of iterations it took.
  Automatically create a PR by invoking `/create-github-pr`.
- **FAIL (max iterations):** Report that max iterations were reached without PASS.
  Show the last checker verdict:
  ```bash
  git log --grep="Loop-Verdict: FAIL" -1 --format="%B"
  ```
- **Resumable:** If interrupted, the loop can be resumed by running `/loop`
  again with the same task -- step 6 will detect the prior progress.

## Components

This skill orchestrates the following components:

### Agents (`agents/`)

| Agent | File | Role |
|-------|------|------|
| `looper:planner` | `agents/planner.md` | Explores codebase, produces plan (read-only) |
| `looper:doer` | `agents/doer.md` | Implements the plan, commits changes |
| `looper:checker` | `agents/checker.md` | Reviews work, fixes issues, issues PASS/FAIL verdict |

### Scripts (`scripts/`)

All executable scripts live in `skills/loop/scripts/`:

| Script | Purpose |
|--------|---------|
| `detect-stack` | Auto-detect project tech stack (JSON output) |
| `run-tests` | Run test suite (`--file`, `--grep`) |
| `run-lint` | Run linter (`--fix`) |
| `run-typecheck` | Run type checker |
| `run-format` | Run formatter (`--fix`) |
| `run-build` | Build the project |
| `install-deps` | Install project dependencies |
| `security-scan` | Run security vulnerability scan |
| `git-loop-context` | Read prior loop iterations from git log |
| `git-commit-loop` | Create conventional commits with loop trailers |

The utility scripts auto-detect the project's tech stack via `detect-stack`
and dispatch to the right tool. Agents receive the `$SCRIPTS_DIR` path in
their dynamic context.

## Error Handling

| Scenario | Action |
|----------|--------|
| Not in a git repo | Abort: "Must be in a git repository." |
| No arguments | Ask user for task description |
| Worktree already exists | `cd` into it and continue (resume case) |
| No verdict after checker | Treat as FAIL, continue to next iteration |
| Max iterations reached | Report FAIL with last checker feedback |
