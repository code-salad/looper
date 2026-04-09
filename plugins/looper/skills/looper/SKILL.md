---
name: looper
description: Use this skill when the user wants to run an iterative Plan-Do-Check agent loop. Three agents (Planner, Doer, Checker) cycle until the Checker passes the work. Triggered by "/looper" followed by a task description.
tools: Bash, Read, Edit, Write, Grep, Glob, Agent, Skill
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

Check if `$ARGUMENTS` contains a GitHub issue reference. Look for:
- A GitHub issue URL matching `https://github.com/.+/issues/(\d+)`
- A hash-prefixed issue number like `#123`
- A plain issue number at the start of the arguments (e.g., "42 fix the bug")

If an issue reference is found, extract the issue number and:

1. **Fetch the full issue metadata** for blocking checks and agent context:
   ```bash
   ISSUE_JSON=$(gh issue view <NUMBER> --json title,body,labels,state)
   # If the issue URL included a repo (owner/repo), add: --repo owner/repo
   ```
   - If fetch fails, set `ISSUE_BODY=""` and skip to step 5 (do not abort).

2. **Check for blocking dependencies** — apply the same three checks used by
   `looper-issue` and `looper-watch`. If any check triggers, **abort** with a
   clear message instead of assigning and working on a blocked issue.

   #### Label-based blocking

   Skip (block) the issue if any of its labels contain "blocked" or
   "dependencies" (case-insensitive match).

   #### Task-list dependency references

   Parse the issue body for lines matching either of these patterns:
   - `- [ ] Depends on #N`
   - `- [ ] #N`

   (where `N` is one or more digits)

   For each referenced issue number `N` found, check whether it is still open:

   ```bash
   gh issue view N --json state --jq '.state'
   ```

   If the result is `"OPEN"`, the issue is blocked.

   #### "Blocked by" references

   Parse the issue body for lines matching the pattern:
   - `Blocked by #N` (case-insensitive)

   For each referenced issue number `N`, check whether it is still open:

   ```bash
   gh issue view N --json state --jq '.state'
   ```

   If the result is `"OPEN"`, the issue is blocked.

   **If blocked:** Log "Issue #<NUMBER> is blocked by open dependencies. Aborting."
   and **abort** — do NOT assign or proceed with the loop.

3. **Assign the issue** (only after confirming it is not blocked):
   ```bash
   gh issue edit <NUMBER> --add-assignee @me
   # If the issue URL included a repo (owner/repo), add: --repo owner/repo
   ```
   - **Success:** Log "Assigned issue #<NUMBER> to current user." and continue.
   - **Failure:** Warn "Could not assign issue #<NUMBER>. Continuing anyway."
     Do NOT abort — the loop should proceed regardless.

4. **Format the issue body** for use as grounding context by all agents:
   ```bash
   ISSUE_BODY=$(gh issue view <NUMBER> --json title,body,labels --template '## Issue #{{.number}}: {{.title}}{{"\n\n"}}### Labels{{"\n"}}{{range .labels}}- {{.name}}{{"\n"}}{{end}}{{"\n"}}### Description{{"\n"}}{{.body}}')
   ```
   - If fetch fails, set `ISSUE_BODY=""` and continue.

If no issue reference is found in `$ARGUMENTS`, set `ISSUE_BODY=""` and skip this step silently.

### 5. Build project context (role-specific slices)

Read the following files (skip any that don't exist) and assemble role-specific
context slices. Each agent receives only the context it needs.

**Build config helpers** (read once, used in all slices):
- `package.json` — extract the `scripts` object
- `Makefile` — extract target names (lines matching `^[a-zA-Z_-]+:`)
- `pyproject.toml` — read entire file
- `Cargo.toml` — read entire file

Format each file as:
```
---
## File: <filename>

<contents>
```

**`PROJECT_CONTEXT_PLANNER`** — Full context for the Planner:
- All project docs: `CONTRIBUTING.md`, `AGENTS.md`, `README.md`,
  `.github/PULL_REQUEST_TEMPLATE.md`, `.editorconfig`
- All build config files (from above)

**`PROJECT_CONTEXT_DOER`** — Focused context for the Doer (build commands only):
- `CONTRIBUTING.md` — "Code Style" section only (skip other sections)
- `.editorconfig` — full file
- Build config files (from above) — scripts/targets only, not full config prose

**`PROJECT_CONTEXT_CHECKER`** — Minimal context for the Checker (test/lint commands):
- `CONTRIBUTING.md` — "Code Style" and "CI Checks" sections only
- Build config files (from above) — test/lint/build commands only

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

Build separate context strings for Planner, Doer, and Checker using the
role-specific context slices from step 5.

**For Planner** — full project context. On iteration > 1, prune to a brief:
```
<project-context>
${PROJECT_CONTEXT_PLANNER}
</project-context>

You MUST follow the conventions and instructions in <project-context>.
Pay special attention to CONTRIBUTING.md for build/test/lint/commit conventions.

---

## Task Variables

- **TASK_NAME:** ${TASK_NAME}
- **ITERATION:** ${ITERATION}
- **TASK_PROMPT:** ${TASK_PROMPT}
- **SCRIPTS_DIR:** ${SCRIPTS_DIR}
- **WORKTREE_DIR:** ${WORKTREE_DIR}
- **LOOPER_DEV_PORT:** ${LOOPER_DEV_PORT}
- **HAS_COMPOSE:** ${HAS_COMPOSE:-false}
- **COMPOSE_SERVICES:** ${COMPOSE_SERVICES:-none}

## Issue Context

${ISSUE_BODY:-No issue linked. Use the TASK_PROMPT above as the source of requirements.}

## Prior Loop Context

${LOOP_CONTEXT}
```

On iteration > 1, add this note to the Planner context:
```
NOTE: This is iteration ${ITERATION}. Project context is the same as iteration 1.
Spawn Explore subagents ONLY for the areas the Checker flagged — do not
re-explore the entire codebase. The action items above are your focus.
```

**For Doer** — focused build/style context only:
```
<project-context>
${PROJECT_CONTEXT_DOER}
</project-context>

You MUST follow the conventions and instructions in <project-context>.
Pay special attention to CONTRIBUTING.md for build/test/lint/commit conventions.

---

## Task Variables

- **TASK_NAME:** ${TASK_NAME}
- **ITERATION:** ${ITERATION}
- **TASK_PROMPT:** ${TASK_PROMPT}
- **SCRIPTS_DIR:** ${SCRIPTS_DIR}
- **WORKTREE_DIR:** ${WORKTREE_DIR}
- **LOOPER_DEV_PORT:** ${LOOPER_DEV_PORT}
- **HAS_COMPOSE:** ${HAS_COMPOSE:-false}
- **COMPOSE_SERVICES:** ${COMPOSE_SERVICES:-none}

## Issue Context

${ISSUE_BODY:-No issue linked. Use the TASK_PROMPT above as the source of requirements.}

## Prior Loop Context

${LOOP_CONTEXT}
```

**For Checker** — minimal test/lint context plus diff-only on iteration > 1:

First, compute the diff context (what changed this iteration):
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

Then build the Checker context:
```
<project-context>
${PROJECT_CONTEXT_CHECKER}
</project-context>

You MUST follow the conventions and instructions in <project-context>.
Pay special attention to CONTRIBUTING.md for build/test/lint/commit conventions.

---

## Task Variables

- **TASK_NAME:** ${TASK_NAME}
- **ITERATION:** ${ITERATION}
- **TASK_PROMPT:** ${TASK_PROMPT}
- **SCRIPTS_DIR:** ${SCRIPTS_DIR}
- **WORKTREE_DIR:** ${WORKTREE_DIR}
- **LOOPER_DEV_PORT:** ${LOOPER_DEV_PORT}
- **HAS_COMPOSE:** ${HAS_COMPOSE:-false}
- **COMPOSE_SERVICES:** ${COMPOSE_SERVICES:-none}

## Issue Context

${ISSUE_BODY:-No issue linked. Use the TASK_PROMPT above as the source of requirements.}

## Changes This Iteration (diff from last check)

${DIFF_CONTEXT}

## Prior Loop Context

${LOOP_CONTEXT}
```

#### 7d. Spawn agents

For each phase, print a progress header and spawn the agent. Wait for each
to complete before proceeding to the next.

1. `=== Iteration ${ITERATION}/${MAX_ITERATIONS}: PLAN phase ===`
   `Agent(subagent_type="looper:planner", prompt=<Planner context from 7c>)`

   After the Planner completes, compress the plan for the Doer:
   ```
   PLAN_BODY=$(git log --grep="Loop-Phase: plan" --grep="Loop-Iteration: ${ITERATION}" \
       --all-match --format="%B" -1)
   PLAN_SUMMARY=$(Agent(subagent_type="looper:summarizer",
       prompt="Compress this plan into a structured checklist for the Doer:\n\n${PLAN_BODY}"))
   ```
   Append `PLAN_SUMMARY` to the Doer's context under a "## Plan Summary" section.

2. `=== Iteration ${ITERATION}/${MAX_ITERATIONS}: DO phase (TDD: red→green) ===`
   `Agent(subagent_type="looper:doer", prompt=<Doer context from 7c with PLAN_SUMMARY appended>)`

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

   If pre-check passes, then:

   After the Doer completes (and pre-check passes), compress Doer work for the Checker:
   ```
   DOER_SUMMARIES=$(git log --grep="Loop-Phase: do-" --grep="Loop-Iteration: ${ITERATION}" \
       --all-match --format="%B" -1)
   DOER_SUMMARY=$(Agent(subagent_type="looper:summarizer",
       prompt="Compress this multi-commit Doer output into a review brief for the Checker:\n\n${DOER_SUMMARIES}"))
   ```
   Append `DOER_SUMMARY` to the Checker's context under a "## Doer Work Summary" section.

3. `=== Iteration ${ITERATION}/${MAX_ITERATIONS}: CHECK phase ===`
   `Agent(subagent_type="looper:checker", prompt=<Checker context from 7c with DOER_SUMMARY appended>)`

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
