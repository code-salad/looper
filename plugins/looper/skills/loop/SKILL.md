---
name: loop
description: Use this skill when the user wants to run an iterative Plan-Do-Check agent loop. Three agents (Planner, Doer, Checker) cycle until the Checker passes the work. Triggered by "/loop" followed by a task description.
tools: Bash, Read, Edit, Write, Grep, Glob
---

# PDC Loop Skill

Executes the Plan-Do-Check loop for a given task. Three `claude -p` agents
iterate until the Checker issues a PASS verdict.

## Prerequisites

- Must be in a git repository
- `claude` CLI must be available
- `jq` must be installed
- `git` must be available

## Steps

### 1. Validate environment

```bash
# Must be in a git repo
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

Example: "Add User Authentication Flow" → "add-user-authentication-flow"

### 4. Create a worktree

Create an isolated worktree so the loop does not modify the current branch
directly. Use the task name as the worktree name.

1. **Ensure `.worktrees` is gitignored** — Check if `.gitignore` at the repo
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

### 5. Execute the loop

`loop.sh` lives in the `scripts/` subdirectory alongside the other utility scripts.
Resolve the script path **before** changing into the worktree, using
`CLAUDE_PLUGIN_ROOT` or the original repo root.

```bash
LOOP_SCRIPT="${CLAUDE_PLUGIN_ROOT:-${REPO_ROOT}}/skills/loop/scripts/loop.sh"

bash "$LOOP_SCRIPT" \
    --task "$TASK_NAME" \
    --prompt "$ARGUMENTS"
```

Let the script run. It will output progress for each iteration.

### 6. Report results

After `loop.sh` exits:

- **Exit code 0 (PASS):** Report success. Show the number of iterations it took.
  Automatically create a PR by invoking `/create-github-pr`.
- **Exit code 1 (FAIL):** Report that max iterations were reached without PASS.
  Show the last checker verdict:
  ```bash
  git log --grep="Loop-Verdict: FAIL" -1 --format="%B"
  ```
- **Exit code 130 (interrupted):** Report that the loop was interrupted and can
  be resumed by running `/loop` again with the same task.

## Components

This skill orchestrates the following components:

### Agents (`agents/`)

| Agent | File | Role |
|-------|------|------|
| `planner` | `agents/planner.md` | Explores codebase, produces plan (read-only) |
| `doer` | `agents/doer.md` | Implements the plan, commits changes |
| `checker` | `agents/checker.md` | Reviews work, fixes issues, issues PASS/FAIL verdict |

### Scripts (`scripts/`)

All executable scripts live in `skills/loop/scripts/`:

| Script | Purpose |
|--------|---------|
| `loop.sh` | Main PDC loop orchestrator |
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
| loop.sh not found | Abort: "loop.sh not found at expected path." |
| claude CLI not found | Abort: "Claude CLI not installed." |
| jq not found | Abort: "jq not installed." |
