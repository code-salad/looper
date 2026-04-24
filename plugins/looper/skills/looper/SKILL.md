---
name: looper
description: Use this skill when the user wants to run an iterative Plan-Do-Check agent loop. Three agents (Planner, Doer, Checker) cycle until the Checker passes the work. Triggered by "/looper" followed by a task description.
tools: Bash, Read, Edit, Write, Grep, Glob, Agent, Skill
---

# PDC Loop Skill

Three subagents (Planner, Doer, Checker) iterate until the Checker issues a PASS verdict.

## Agent spawning mode

**Never run the PDC loop inline.** If `claude-spawn-agent` is unavailable and step 0 did not abort, ABORT — inline execution defeats the loop's isolation, commit trail, and worktree guarantees.

Spawn subagents with `claude-spawn-agent <agent-name> <prompt>` invoked via
the Bash tool with `run_in_background: true`. The Bash tool returns
immediately; the parent receives an automatic completion notification when
the subprocess exits — read the result-file path printed on stdout then.
No polling is required.

- Sync: `Bash(command="claude-spawn-agent X Y", run_in_background=true)` → completion notification → read result file.
- Parallel fan-out: several `Bash(run_in_background=true, ...)` calls in one message, or `claude-spawn-agent --async` with `& ... wait`.

`claude-spawn-agent` is on `PATH` in every context and self-locates its
plugin root — no env-var setup is required.

Stream-idle watchdog (`CLAUDE_STREAM_IDLE_TIMEOUT_MS`, v2.1.84+) fires only
on **stalled model streams** (no tokens flowing from the API), NOT from lack
of tool-call activity in the parent. A productive subagent does not trip it
regardless of runtime. Looper recommends `7200000` ms (2 h) — see README.

## Steps

### 0. Verify subagent dispatch is available

Before ANY side effect (no worktree creation, no issue fetching, no commits),
verify that `claude-spawn-agent` is reachable on `PATH`. This command is
provided by the looper plugin's `bin/` directory, which Claude Code puts on
`PATH` in every context (including subagents). If it is not reachable, the
loop cannot spawn planner / doer / checker subagents and must abort — see
"Never run the PDC loop inline" above.

```bash
command -v claude-spawn-agent >/dev/null 2>&1 || {
    echo "ERROR: claude-spawn-agent not found on PATH — the looper plugin's bin/ directory is either not installed or not registered with Claude Code. Cannot run /looper." >&2
    exit 1
}
```

**Gate:** If this check fails, abort immediately. Do NOT attempt to locate
the script manually, do NOT fall through to step 1, and do NOT run any
planner/doer/checker work inline in this session (see rule above).

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

**Gate:** If `setup-worktree` exits non-zero or `WORKTREE_DIR` is empty, abort immediately.
**CRITICAL:** All work MUST happen inside the worktree. NEVER commit directly to the default branch.
Verify you are on a `loop/` branch:

```bash
git branch --show-current | grep -q '^loop/' || { echo "ERROR: not on a loop/ branch"; exit 1; }
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

### 4c. Fetch issue body and check blocking deps (if referenced)

```bash
FETCH_OUTPUT=$($SCRIPTS_DIR/fetch-issue-context --args "$ARGUMENTS") \
    && FETCH_EXIT=0 || FETCH_EXIT=$?
if [ "$FETCH_EXIT" -eq 1 ]; then
    echo "Issue is blocked. Aborting."
    exit 1
fi
# First line is NUMBER=<num>, rest is formatted body
ISSUE_NUMBER=$(echo "$FETCH_OUTPUT" | head -1 | sed 's/^NUMBER=//')
ISSUE_BODY=$(echo "$FETCH_OUTPUT" | tail -n +2)
if [ -n "$ISSUE_NUMBER" ]; then
    gh issue edit "$ISSUE_NUMBER" --add-assignee @me 2>/dev/null \
        && echo "Assigned issue #$ISSUE_NUMBER to current user." \
        || echo "Warning: Could not assign issue #$ISSUE_NUMBER. Continuing."
fi
```

### 5. Project context assembly

Role-specific project context is assembled by `build-agent-context` in step 7c.
No manual file reading is needed here.

### 6. Detect resume iteration

```bash
START_ITERATION=$($SCRIPTS_DIR/detect-resume)
```

### 7. Run the PDC loop

```bash
MAX_ITERATIONS="${LOOPER_MAX_ITERATIONS:-10}"
```

For each iteration from `START_ITERATION` to `MAX_ITERATIONS`:

#### 7a. Get loop context (per-role, inside `build-agent-context`)

Loop context is fetched per-role inside `build-agent-context` in step 7c.
No upstream shared fetch is needed.

#### 7b. Generate isolated dev port

To avoid port conflicts with the user's main development server (since the loop
runs in a worktree), generate an isolated port for this loop's dev server:

```bash
# Pick a deterministic but isolated port: hash the task name into 10000-60000 range
LOOPER_DEV_PORT=$(( ( $(echo "$TASK_NAME" | cksum | cut -d' ' -f1) % 50000 ) + 10000 ))
```

This port is passed to agents so the Checker's integration tests don't collide
with the user's running dev server.

#### 7b2. Isolate docker-compose services (if applicable)

If the project uses docker-compose, generate a port isolation override so
backing services (databases, caches, queues) don't collide between worktrees
or with the user's own dev environment.

```bash
COMPOSE_INFO=$($SCRIPTS_DIR/detect-compose)
HAS_COMPOSE=$(echo "$COMPOSE_INFO" | jq -r 'if .compose_file != "none" then "true" else "false" end')
COMPOSE_SERVICES="none"
if [ "$HAS_COMPOSE" = "true" ]; then
    $SCRIPTS_DIR/compose-isolate --task "$TASK_NAME" >&2
    COMPOSE_SERVICES=$(echo "$COMPOSE_INFO" | jq -r '[.services | keys[]] | join(", ")')
    echo "Docker-compose detected. Isolated services: $COMPOSE_SERVICES"
fi
```

The override file (`docker-compose.looper.yml`) and connection string file
(`.env.looper`) are generated in the worktree root. Scripts like
`run-integration-tests` and `compose-lifecycle` use these automatically.

#### 7c. Build the agent context prompts (role-specific)

First, compute the diff context for the Checker:

```bash
if [ "$ITERATION" -gt 1 ]; then
    LAST_CHECK_HASH=$(git log --grep="Loop-Phase: check" \
        --grep="Loop-Iteration: $((ITERATION - 1))" \
        --all-match --format="%H" -1 2>/dev/null || echo "")
    if [ -n "$LAST_CHECK_HASH" ]; then
        DIFF_CONTEXT=$(git diff --stat "$LAST_CHECK_HASH" HEAD 2>/dev/null | head -50)
    else
        DIFF_CONTEXT="First review — full review required."
    fi
else
    DIFF_CONTEXT="First iteration — full review required."
fi
```

Then build role-specific context using `build-agent-context`:

```bash
CTX_COMMON=(
    --task "$TASK_NAME" --iteration "$ITERATION"
    --task-prompt "$TASK_PROMPT" --scripts-dir "$SCRIPTS_DIR"
    --worktree-dir "$WORKTREE_DIR" --dev-port "$LOOPER_DEV_PORT"
    --compose "${HAS_COMPOSE:-false}" --compose-services "${COMPOSE_SERVICES:-none}"
    --issue-body "$ISSUE_BODY"
)

PLANNER_CONTEXT=$($SCRIPTS_DIR/build-agent-context --role planner "${CTX_COMMON[@]}")
DOER_CONTEXT=$($SCRIPTS_DIR/build-agent-context --role doer "${CTX_COMMON[@]}")
CHECKER_CONTEXT=$($SCRIPTS_DIR/build-agent-context --role checker "${CTX_COMMON[@]}" \
    --diff-context "$DIFF_CONTEXT")
```

#### 7d. Spawn agents

For each phase, print a progress header and spawn the agent. Wait for each
to complete before proceeding to the next.

1. `=== Iteration ${ITERATION}/${MAX_ITERATIONS}: PLAN phase ===`
   `Agent(subagent_type="looper:planner", prompt=<Planner context from 7c>)`
   (If the Agent tool is unavailable, spawn via `claude-spawn-agent` per "Agent spawning mode".)

2. `=== Iteration ${ITERATION}/${MAX_ITERATIONS}: DO phase (TDD: red→green) ===`
   `Agent(subagent_type="looper:doer", prompt=<Doer context from 7c>)`
   (If the Agent tool is unavailable, spawn via `claude-spawn-agent` per "Agent spawning mode".)

   Before spawning the Checker, run mechanical pre-checks:
   ```bash
   PRE_CHECK_OUTPUT=$($SCRIPTS_DIR/pre-check 2>&1)
   PRE_CHECK_EXIT=$?
   ```
   If pre-check fails (exit non-zero), skip the Checker entirely. Instead,
   commit a synthetic FAIL verdict:
   ```bash
   $SCRIPTS_DIR/git-commit-loop --type "test" --scope "$TASK_NAME" \
       --message "check iteration ${ITERATION} — FAIL (pre-check)" \
       --body "Pre-check failed before Checker spawn.\n\n${PRE_CHECK_OUTPUT}\n\n## Action items for next iteration\n1. Fix the failing checks listed above." \
       --phase "check" --iteration ${ITERATION} --verdict "FAIL"
   ```
   Then continue to the next iteration without spawning the Checker.

3. `=== Iteration ${ITERATION}/${MAX_ITERATIONS}: CHECK phase ===`
   `Agent(subagent_type="looper:checker", prompt=<Checker context from 7c>)`
   (If the Agent tool is unavailable, spawn via `claude-spawn-agent` per "Agent spawning mode".)

#### 7e. Read verdict

```bash
VERDICT=$(git log --grep="Loop-Verdict:" -1 --format="%B" \
    | grep -oE 'Loop-Verdict: (PASS|FAIL)' | sed 's/Loop-Verdict: //' || echo "")
```

- **PASS:** Break out of the loop, proceed to step 8.
- **FAIL** (or no verdict): Report and continue to next iteration.

### 7f. Sync with remote before PR

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

- **PASS:** Report success with iteration count, then **you MUST invoke
  `/create-github-pr`** to push the branch and open a pull request against
  the default branch. The PR skill will wait for CI, then squash-merge if
  no DB migrations are detected. If DB migration files are present in the
  changeset, the PR is left open for manual review (no auto-merge).
  The worktree is cleaned up automatically after merge or PR creation.
  If CI fails or merge fails, the worktree is preserved for manual inspection.

  **CRITICAL — never merge locally:** Do NOT run `git merge`, `git checkout
  <default-branch>`, or any command that merges the loop branch into the
  local default branch. All merging happens via the GitHub PR.

- **FAIL (max iterations):** Report that max iterations were reached. Show
  the last checker verdict: `git log --grep="Loop-Verdict: FAIL" -1 --format="%B"`
  The worktree at `$WORKTREE_DIR` is **preserved** for debugging.
- **Resumable:** Running `/looper` again with the same task resumes automatically
  via step 6.
