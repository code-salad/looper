---
name: loop
description: Use this skill when the user wants to run an iterative Plan-Do-Check agent loop. Three agents (Planner, Doer, Checker) cycle until the Checker passes the work. Triggered by "/loop" followed by a task description.
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
SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT:-${REPO_ROOT}}/skills/loop/scripts"
```

Create an isolated worktree (handles gitignore, create-or-resume, and dirty-state warnings):

```bash
WORKTREE_DIR=$($SCRIPTS_DIR/setup-worktree --task "$TASK_NAME")
cd "$WORKTREE_DIR"
```

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

### 8. Report results

- **PASS:** Report success with iteration count. Invoke `/create-github-pr`.
  The worktree at `$WORKTREE_DIR` is **preserved** for manual inspection.
  Do NOT remove it — worktrees persist until the user explicitly cleans up
  (e.g. `git worktree remove <path>`).
- **FAIL (max iterations):** Report that max iterations were reached. Show
  the last checker verdict: `git log --grep="Loop-Verdict: FAIL" -1 --format="%B"`
- **Resumable:** Running `/loop` again with the same task resumes automatically
  via step 6.
