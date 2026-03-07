---
name: looper
description: Use this skill when the user wants to run an iterative Plan-Do-Check agent loop. Three agents (Planner, Doer, Checker) cycle until the Checker passes the work. Triggered by "/looper" followed by a task description.
tools: Bash, Read, Edit, Write, Grep, Glob, Agent
---

# PDC Loop Skill

Three subagents (Planner, Doer, Checker) iterate until the Checker issues a PASS verdict.

## Steps

### 1. Validate environment

```bash
git rev-parse --is-inside-work-tree
```

**Gate:** Abort if not in a git repo.

Run `gh auth status`. If it fails, warn:
> "Warning: `gh` is not authenticated. PR creation will fail at the end. Run `gh auth login` to fix."

Continue anyway — do not abort.

### 2. Validate argument

If `$ARGUMENTS` is empty, ask the user for a task description. Do not proceed without one.

### 3. Generate task name

Sanitize `$ARGUMENTS` into a kebab-case task name: lowercase, replace spaces/underscores
with hyphens, remove non-alphanumeric characters (except hyphens), truncate to 50 characters,
strip leading/trailing hyphens.

### 4. Create worktree

Resolve `SCRIPTS_DIR` and `REPO_ROOT` before entering the worktree:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT:-${REPO_ROOT}}/skills/looper/scripts"
```

Create an isolated worktree (handles gitignore, create-or-resume, and dirty-state warnings):

```bash
WORKTREE_DIR=$($SCRIPTS_DIR/setup-worktree --task "$TASK_NAME")
cd "$WORKTREE_DIR"
```

### 4b. Sync worktree with remote

Fetch the latest remote and rebase the worktree branch onto the default remote branch.
This ensures the loop starts from an up-to-date base.

```bash
SYNC_OUTPUT=$($SCRIPTS_DIR/sync-with-remote) && SYNC_EXIT=0 || SYNC_EXIT=$?
eval "$SYNC_OUTPUT"   # sets DEFAULT_BRANCH, STATUS
```

- **`STATUS=up-to-date` or `STATUS=rebased` (exit 0):** Continue to step 5.
- **`STATUS=conflicts` (exit 1):** The rebase is paused with conflicts. Resolve them:
  1. List conflicted files: `git diff --name-only --diff-filter=U`
  2. Read each conflicted file, understand both sides of the conflict.
  3. Edit the file to resolve the conflict (remove conflict markers, keep correct code).
  4. Stage each resolved file: `git add <file>`
  5. Continue the rebase: `git rebase --continue`
  6. If new conflicts appear, repeat until the rebase completes.
- **Exit 2 (error):** Warn and continue — the loop can still proceed without sync.

### 5. Build project context

Read the following files (skip any that don't exist) and assemble them into `PROJECT_CONTEXT`:

**Project docs:** `CONTRIBUTING.md`, `AGENTS.md`, `README.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `.editorconfig`

**Build config (extract relevant sections):**
- `package.json` — extract the `scripts` object
- `Makefile` — extract target names (lines matching `^[a-zA-Z_-]+:`)
- `pyproject.toml` — read entire file
- `Cargo.toml` — read entire file

Format each as:

```
---
## File: <filename>

<contents>
```

### 6. Detect resume iteration

```bash
START_ITERATION=$($SCRIPTS_DIR/detect-resume)
```

### 7. Run the PDC loop

```bash
MAX_ITERATIONS="${LOOPER_MAX_ITERATIONS:-10}"
```

For each iteration from `START_ITERATION` to `MAX_ITERATIONS`:

#### 7a. Get loop context

```bash
LOOP_CONTEXT=$($SCRIPTS_DIR/git-loop-context --task "$TASK_NAME" --iteration $ITERATION)
```

#### 7b. Build the agent context prompt

Construct a context string passed to each subagent:

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

#### 7c. Spawn agents

For each phase, print a progress header and spawn the agent. Wait for each
to complete before proceeding to the next.

1. `=== Iteration ${ITERATION}/${MAX_ITERATIONS}: PLAN phase ===`
   `Agent(subagent_type="looper:planner", prompt=<context from 7b>)`

2. `=== Iteration ${ITERATION}/${MAX_ITERATIONS}: DO phase ===`
   `Agent(subagent_type="looper:doer", prompt=<context from 7b>)`

3. `=== Iteration ${ITERATION}/${MAX_ITERATIONS}: CHECK phase ===`
   `Agent(subagent_type="looper:checker", prompt=<context from 7b>)`

#### 7d. Read verdict

```bash
VERDICT=$(git log --grep="Loop-Verdict:" -1 --format="%B" \
    | grep -oE 'Loop-Verdict: (PASS|FAIL)' | sed 's/Loop-Verdict: //' || echo "")
```

- **PASS:** Break out of the loop, proceed to step 8.
- **FAIL** (or no verdict): Report and continue to next iteration.

### 7e. Sync with remote before PR

After the loop completes with PASS, sync one more time to ensure the PR will have
no merge conflicts with the default remote branch.

```bash
SYNC_OUTPUT=$($SCRIPTS_DIR/sync-with-remote) && SYNC_EXIT=0 || SYNC_EXIT=$?
eval "$SYNC_OUTPUT"   # sets DEFAULT_BRANCH, STATUS
```

- **`STATUS=up-to-date` or `STATUS=rebased` (exit 0):** Proceed to step 8.
- **`STATUS=conflicts` (exit 1):** The rebase is paused with conflicts. Resolve them:
  1. List conflicted files: `git diff --name-only --diff-filter=U`
  2. Read each conflicted file, understand both sides of the conflict.
  3. Edit the file to resolve the conflict (remove conflict markers, keep correct code).
  4. Stage each resolved file: `git add <file>`
  5. Continue the rebase: `git rebase --continue`
  6. If new conflicts appear, repeat until the rebase completes.
  7. After all conflicts are resolved, run the project's tests to verify nothing broke:
     ```bash
     $SCRIPTS_DIR/run-tests
     ```
  8. If tests fail after conflict resolution, fix the issues and commit before proceeding.
- **Exit 2 (error):** Warn but still attempt PR creation.

### 8. Report results

- **PASS:** Report success with iteration count. Invoke `/create-github-pr`.
  The worktree at `$WORKTREE_DIR` is **preserved** for manual inspection.
  Do NOT remove it — worktrees persist until the user explicitly cleans up
  (e.g. `git worktree remove <path>`).
- **FAIL (max iterations):** Report that max iterations were reached. Show
  the last checker verdict: `git log --grep="Loop-Verdict: FAIL" -1 --format="%B"`
- **Resumable:** Running `/looper` again with the same task resumes automatically
  via step 6.
