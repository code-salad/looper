---
name: loop
description: Runs a Plan-Do-Check agent loop to implement a task iteratively. Three agents (Planner, Doer, Checker) cycle until the Checker passes the work.
argument-hint: "<task description>"
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob
---

# PDC Loop Skill

Executes the Plan-Do-Check loop for a given task. Three `claude -p` agents
iterate until the Checker issues a PASS verdict.

## Prerequisites

- Must be in a git repository
- Must NOT be on `main` or `master` branch
- `claude` CLI must be available
- `jq` must be installed
- `git` must be available

## Steps

### 1. Validate environment

```bash
# Must be in a git repo
git rev-parse --is-inside-work-tree

# Must not be on main/master
BRANCH=$(git branch --show-current)
```

**Gate:** Abort if:
- Not in a git repo
- Current branch is `main` or `master` — tell the user to create a feature branch first

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

### 4. Find loop.sh

Locate `loop.sh` relative to this skill. It should be at the repository root.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
LOOP_SCRIPT="${REPO_ROOT}/loop.sh"
```

**Gate:** Abort if `loop.sh` is not found.

### 5. Execute the loop

```bash
bash "$LOOP_SCRIPT" \
    --task "$TASK_NAME" \
    --prompt "$ARGUMENTS"
```

Let the script run. It will output progress for each iteration.

### 6. Report results

After `loop.sh` exits:

- **Exit code 0 (PASS):** Report success. Show the number of iterations it took.
  Suggest creating a PR with `/create-github-pr`.
- **Exit code 1 (FAIL):** Report that max iterations were reached without PASS.
  Show the last checker verdict:
  ```bash
  git log --grep="Loop-Verdict: FAIL" -1 --format="%B"
  ```
- **Exit code 130 (interrupted):** Report that the loop was interrupted and can
  be resumed by running `/loop` again with the same task.

## Error Handling

| Scenario | Action |
|----------|--------|
| Not in a git repo | Abort: "Must be in a git repository." |
| On main/master | Abort: "Create a feature branch first." |
| No arguments | Ask user for task description |
| loop.sh not found | Abort: "loop.sh not found at repo root." |
| claude CLI not found | Abort: "Claude CLI not installed." |
| jq not found | Abort: "jq not installed." |
