# PDC Loop — Plan, Do, Check

An orchestrated agent loop that iterates through three phases (Plan → Do → Check)
until the Checker agent returns PASS. The SKILL.md entry point acts as the loop
controller, spawning Task subagents directly from the main Claude Code session.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  Main Agent (user's Claude Code session)                │
│                                                         │
│  1. User invokes /loop skill                            │
│  2. SKILL.md builds project context                     │
│  3. SKILL.md runs PDC loop via Task subagents           │
│  4. Reads verdict from git log after each iteration     │
└────────────────────┬────────────────────────────────────┘
                     │
          ┌──────────┼──────────┐
          ▼          ▼          ▼
       Planner    Doer      Checker
       Agent      Agent      Agent
     (Task)      (Task)     (Task)
```

---

## Flow Diagram (Mermaid)

```mermaid
flowchart TD
    A["Main Agent"] -->|"Invokes /loop skill"| B["SKILL.md orchestrator"]
    B --> P

    subgraph LOOP ["PDC Loop (managed by SKILL.md)"]
        direction TB
        P["Planner Agent (Task subagent)"]
        P -->|"chore(task): plan ..."| D["Doer Agent (Task subagent)"]
        D -->|"feat/fix(task): ..."| CH["Checker Agent (Task subagent)"]
        CH -->|"fix/refactor(task): review fixes"| V["Verdict Commit"]
        V -->|"test(task): check — PASS/FAIL"| DECIDE{Verdict?}
        DECIDE -->|"FAIL"| P
        DECIDE -->|"PASS"| EXIT["Exit loop"]
    end

    EXIT --> PR["Main Agent: Create PR"]
    PR --> CI{CI checks pass?}
    CI -->|"Yes"| DONE["Done"]
    CI -->|"No"| RESUME["Re-run /loop with CI failure context"]
    RESUME --> P
```

---

## Project Context Bootstrap

Task subagents inherit settings from the main session, but project docs that
agents routinely ignore — `CONTRIBUTING.md`, `README.md`, etc. — contain
critical information (how to build, test, lint, commit, file structure
conventions) that agents need to follow.

The SKILL.md orchestrator collects these **once before the loop starts** and
injects them into every subagent prompt as a preamble.

### What gets collected

Only files that `claude -p` does NOT already handle:

| File | Why |
|------|-----|
| `CONTRIBUTING.md` | How to build, test, lint, commit, PR conventions |
| `AGENTS.md` | Agent-specific instructions (if the project has them) |
| `README.md` | Project overview, architecture, getting started |
| `.github/PULL_REQUEST_TEMPLATE.md` | PR format expectations |
| `.editorconfig` | Indentation, line endings, charset |
| `package.json` → `scripts` | Available npm/pnpm/yarn scripts |
| `Makefile` → targets | Available make targets |
| `pyproject.toml` | Linter/formatter/build config |
| `Cargo.toml` → `[workspace]` | Workspace structure |

### What gets collected

The SKILL.md orchestrator reads each file with the Read tool and assembles
the context. See SKILL.md step 5 for the full list.

### How it's injected

The `PROJECT_CONTEXT` is passed to every Task subagent in its prompt:

```
<project-context>
${PROJECT_CONTEXT}
</project-context>

You MUST follow the conventions and instructions in <project-context>.
Pay special attention to CONTRIBUTING.md for build/test/lint/commit conventions.

---

## Task Variables

- **TASK_NAME:** ...
- **ITERATION:** ...
- **TASK_PROMPT:** ...
- **SCRIPTS_DIR:** ...

## Prior Loop Context

<output from git-loop-context>
```

`CLAUDE.md` is inherited by Task subagents from the main session.

### Checker verification against project context

The checker prompt explicitly includes:

```
When reviewing, verify that all changes comply with the project conventions
in <project-context>. Specifically check:
- Code style matches .editorconfig and linter config
- Test patterns match existing test conventions
- File organization matches project structure
- Dependencies installed using the project's package manager
If any convention is violated, fix it or flag it in your verdict.
```

---

## Components

### 1. Skill Entry Point & Orchestrator (`/loop` → SKILL.md)

The SKILL.md file serves as both the entry point and the loop orchestrator.
When invoked from the main Claude Code session, it:

- Accepts the user's task description
- Generates a sanitized task name (used as scope in commits)
- Creates a worktree for isolation
- Builds project context by reading key project files
- Detects resume point from git log
- Runs the PDC loop by spawning Task subagents sequentially
- Reads the verdict from git log after each iteration

**Pseudocode:**

```
MAX_ITERATIONS = 10
PROJECT_CONTEXT = read(CONTRIBUTING.md, README.md, package.json, ...)
START_ITERATION = detect_resume_from_git_log()

for ITERATION in START_ITERATION..MAX_ITERATIONS:
    LOOP_CONTEXT = run("git-loop-context --task $TASK --iteration $ITERATION")
    CONTEXT = format(PROJECT_CONTEXT, TASK_NAME, ITERATION, LOOP_CONTEXT)

    # --- PLAN PHASE ---
    Task(subagent_type="looper:planner", prompt=CONTEXT)
    # Agent commits with: chore(task): plan iteration N

    # --- DO PHASE ---
    Task(subagent_type="looper:doer", prompt=CONTEXT)
    # Agent commits with: feat(task): implement ... (iteration N)

    # --- CHECK PHASE ---
    Task(subagent_type="looper:checker", prompt=CONTEXT)
    # Checker may produce 0+ fix commits then 1 verdict commit

    # --- EVALUATE VERDICT ---
    VERDICT = git log --grep="Loop-Verdict:" → PASS or FAIL
    if VERDICT == "PASS": break

if VERDICT == "PASS": create PR
else: report FAIL
```

### 2. Planner Agent

Spawned as `Task(subagent_type="looper:planner")`.

Agent definition: `agents/planner.md`

**Responsibilities:**
- Read prior iteration context from `git log`
- Explore the codebase using Explore subagents
- Produce a concrete, actionable plan
- Commit the plan (no code changes — plan lives in the commit message body)

**Allowed tools:** Read, Glob, Grep, Task, Bash (Write/Edit/NotebookEdit disallowed)

### 3. Doer Agent

Spawned as `Task(subagent_type="looper:doer")`.

Agent definition: `agents/doer.md`

**Responsibilities:**
- Read the plan from the latest planner commit (`git log`)
- Implement the plan — write code, edit files, run commands
- Use Explore subagents if needed to understand the codebase
- Commit all changes with a summary in the commit message body

**Allowed tools:** Read, Write, Edit, Bash, Glob, Grep, Task, NotebookEdit

### 4. Checker Agent (also: Reviewer)

Spawned as `Task(subagent_type="looper:checker")`.

Agent definition: `agents/checker.md`

The checker doubles as a **code reviewer**. It doesn't just evaluate — it fixes
what it can. Only issues it cannot resolve itself get escalated back to the
Planner as FAIL feedback.

**Responsibilities:**
- Read the full context from `git log` (plan + doer changes)
- Review the diff from the doer's commit(s)
- Run tests, linting, type checking as appropriate
- **Fix issues it finds** — style, lint, small bugs, missing edge cases, test gaps
- Commit each fix with the appropriate conventional commit type
- After all fixes, commit a **verdict** (PASS or FAIL) as the final commit
- PASS = task is complete, all issues either passed review or were fixed in-place
- FAIL = issues remain that the checker couldn't resolve itself; commit body
  contains actionable feedback for the next Planner iteration

**Allowed tools:** Read, Write, Edit, Bash, Glob, Grep, Task, NotebookEdit

---

## Commit Convention

All commits follow [Conventional Commits](https://www.conventionalcommits.org/)
with git trailers for loop metadata. The **type** reflects the nature of the
change, the **scope** is the task name, and trailers encode loop coordinates.

### Format

```
<type>(<scope>): <description>

<body>

Loop-Phase: plan|do|check
Loop-Iteration: <N>
Loop-Verdict: PASS|FAIL        # checker commits only
```

### Type Selection by Phase

| Phase   | Typical type | When to use |
|---------|-------------|-------------|
| Planner | `chore`     | Always — planning produces no code changes |
| Doer    | `feat`      | New functionality added |
| Doer    | `fix`       | Bug fix or correcting previous iteration |
| Doer    | `refactor`  | Restructuring without behavior change |
| Doer    | `test`      | Adding or updating tests |
| Doer    | `docs`      | Documentation only changes |
| Checker | `fix`       | Bug fix found during review |
| Checker | `style`     | Formatting, naming, code style cleanup |
| Checker | `refactor`  | Structural improvement found during review |
| Checker | `test`      | Adding missing test coverage |
| Checker | `test`      | **Verdict commit** — always the last checker commit |

The checker may produce **multiple commits**: zero or more fix/style/refactor/test
commits followed by exactly one verdict commit. The verdict commit is always last
and always uses type `test`.

### Examples

**Planner — iteration 1:**
```
chore(add-auth): plan input validation strategy

## Goal
Add server-side validation for login endpoint.

## Steps
1. Add zod schema for login request body
2. Add validation middleware to POST /auth/login
3. Add unit tests for edge cases (empty, malformed)

## Files to modify
- src/routes/auth.ts — add validation
- src/schemas/auth.ts — new file, zod schema
- tests/auth.test.ts — new test cases

Loop-Phase: plan
Loop-Iteration: 1
```

**Doer — iteration 1:**
```
feat(add-auth): add zod validation to login endpoint

- Created src/schemas/auth.ts with loginRequestSchema
- Added validation middleware in src/routes/auth.ts
- Added 4 unit tests in tests/auth.test.ts
- All tests passing (14/14)

Loop-Phase: do
Loop-Iteration: 1
```

**Checker review fix — iteration 1 (commit 1 of 3):**
```
style(add-auth): rename validateInput to validateLoginRequest

Renamed for clarity — function specifically validates login payloads,
not generic input.

- src/schemas/auth.ts — renamed export
- src/routes/auth.ts — updated import and usage
- tests/auth.test.ts — updated test descriptions

Loop-Phase: check
Loop-Iteration: 1
```

**Checker review fix — iteration 1 (commit 2 of 3):**
```
test(add-auth): add missing edge case tests

- Added test for empty string email
- Added test for email without @ symbol
- Added test for password shorter than minimum length

Loop-Phase: check
Loop-Iteration: 1
```

**Checker verdict — iteration 1 (commit 3 of 3, FAIL):**
```
test(add-auth): check iteration 1 — FAIL

## What passed
- Unit tests pass (17/17, including 3 new edge case tests)
- Lint clean
- Type check clean

## What I fixed
- Renamed validateInput → validateLoginRequest (clarity)
- Added 3 missing edge case tests

## What I could not fix
- No rate limiting on login endpoint (architectural decision needed)
- No SQL injection test (need to decide on sanitization strategy)

## Action items for next iteration
1. Decide on rate limiting approach (middleware vs per-route)
2. Add SQL injection sanitization + test

Loop-Phase: check
Loop-Iteration: 1
Loop-Verdict: FAIL
```

**Checker verdict — iteration 2 (single commit, PASS):**
```
test(add-auth): check iteration 2 — PASS

## What passed
- All tests pass (22/22)
- Rate limiting middleware working (tested with 100+ rapid requests)
- SQL injection payloads rejected by zod schema
- Lint and type check clean

## What I fixed
- Nothing — implementation is clean

## Summary
All action items from iteration 1 resolved.
Task is complete and ready for PR.

Loop-Phase: check
Loop-Iteration: 2
Loop-Verdict: PASS
```

### Querying Loop History via Git

```bash
# ── By trailer (git's native trailer support) ──

# All commits for a specific phase
git log --grep="Loop-Phase: plan"
git log --grep="Loop-Phase: do"
git log --grep="Loop-Phase: check"

# All commits for a specific iteration
git log --grep="Loop-Iteration: 3"

# Find the verdict
git log --grep="Loop-Verdict: PASS" -1
git log --grep="Loop-Verdict: FAIL"

# ── By conventional commit scope ──

# All commits for a specific task
git log --grep="(add-auth)"

# ── Combined queries ──

# Checker verdict for iteration 2 of add-auth
git log --grep="Loop-Phase: check" --grep="Loop-Iteration: 2" --all-match --format="%B" -1

# Full plan from latest planner commit
git log --grep="Loop-Phase: plan" --format="%B" -1

# Diff of what the doer changed in iteration 1
git log --grep="Loop-Phase: do" --grep="Loop-Iteration: 1" --all-match --format="%H" -1 | xargs git show --stat

# All loop commits in chronological order
git log --grep="Loop-Phase:" --reverse --oneline
```

---

## Agent Skills

Since the loop is project-agnostic, agents need a shared skill toolkit that
abstracts away tech-stack specifics. Skills are bash scripts in `./skills/`
that agents invoke via the Bash tool. Each skill auto-detects the project
environment and runs the right command.

### Skill Design Principles

1. **Auto-detect, don't configure** — skills inspect `package.json`, `Cargo.toml`,
   `pyproject.toml`, `go.mod`, etc. to determine the right tool to run
2. **Structured output** — every skill exits with a code (0 = success) and writes
   machine-readable output (JSON or grep-friendly text) to stdout
3. **Idempotent** — safe to run multiple times without side effects
4. **No interactive prompts** — everything runs non-interactively (`--yes`, `--ci`, etc.)

### Skill Catalog

#### `skills/detect-stack`
Detects the project's tech stack and outputs a JSON summary.

```bash
$ ./skills/detect-stack
{
  "language": "typescript",
  "runtime": "node",
  "package_manager": "pnpm",
  "test_runner": "vitest",
  "linter": "eslint",
  "formatter": "prettier",
  "type_checker": "tsc",
  "build_tool": "vite",
  "framework": "react",
  "ci": "github-actions"
}
```

Used by all agents on first run to understand how to interact with the project.

#### `skills/run-tests`
Runs the project's test suite.

```bash
$ ./skills/run-tests              # run all tests
$ ./skills/run-tests --file src/auth.test.ts   # run specific file
$ ./skills/run-tests --grep "login"            # run matching tests
```

Auto-detects: `vitest`, `jest`, `pytest`, `go test`, `cargo test`, `dotnet test`, etc.

Output: test results + exit code. Stdout includes pass/fail counts.

#### `skills/run-lint`
Runs the project's linter.

```bash
$ ./skills/run-lint               # check mode (report only)
$ ./skills/run-lint --fix         # auto-fix mode
```

Auto-detects: `eslint`, `ruff`, `golangci-lint`, `clippy`, `dotnet format`, etc.

#### `skills/run-typecheck`
Runs the project's type checker.

```bash
$ ./skills/run-typecheck
```

Auto-detects: `tsc`, `mypy`, `pyright`, `go vet`, etc.

#### `skills/run-format`
Runs the project's code formatter.

```bash
$ ./skills/run-format             # check mode (report only)
$ ./skills/run-format --fix       # format in place
```

Auto-detects: `prettier`, `black`, `gofmt`, `rustfmt`, `dotnet format`, etc.

#### `skills/run-build`
Builds the project.

```bash
$ ./skills/run-build
```

Auto-detects: `vite build`, `tsc`, `go build`, `cargo build`, `dotnet build`, etc.

#### `skills/install-deps`
Installs project dependencies.

```bash
$ ./skills/install-deps
```

Auto-detects: `pnpm install`, `npm install`, `yarn`, `uv sync`, `pip install`,
`go mod download`, `cargo fetch`, `dotnet restore`, etc.

#### `skills/git-loop-context`
Reads loop history from git log and outputs structured context for the current
iteration.

```bash
$ ./skills/git-loop-context --task "add-auth" --iteration 2
```

Output:
```
## Loop Context: add-auth, Iteration 2

### Previous Plan (Iteration 1)
<plan body from git log>

### Previous Changes (Iteration 1)
<doer summary from git log>
<stat diff of doer commits>

### Previous Verdict (Iteration 1)
FAIL
<checker feedback from git log>
```

This is the primary mechanism agents use to understand what happened in prior
iterations without needing a separate progress file.

#### `skills/security-scan`
Runs basic security checks on the codebase.

```bash
$ ./skills/security-scan
```

Auto-detects: `npm audit`, `pip-audit`, `cargo audit`, `gosec`, `dotnet list package --vulnerable`, etc.

#### `skills/git-commit-loop`
Creates a conventional commit with loop trailers. Used by all agents to commit
their work consistently.

```bash
$ ./skills/git-commit-loop \
    --type "feat" \
    --scope "add-auth" \
    --message "add zod validation to login endpoint" \
    --body "- Created src/schemas/auth.ts\n- Added validation middleware" \
    --phase "do" \
    --iteration 1

# For verdict commits:
$ ./skills/git-commit-loop \
    --type "test" \
    --scope "add-auth" \
    --message "check iteration 1 — FAIL" \
    --body "## What failed\n- Missing edge case" \
    --phase "check" \
    --iteration 1 \
    --verdict "FAIL"
```

Handles staging, commit message formatting, and trailer injection. Agents don't
need to manually construct commit messages.

### Skill Access by Phase

| Skill               | Planner | Doer | Checker |
|---------------------|---------|------|---------|
| `detect-stack`      | yes     | yes  | yes     |
| `run-tests`         | —       | yes  | yes     |
| `run-lint`          | —       | yes (--fix) | yes (both) |
| `run-typecheck`     | —       | yes  | yes     |
| `run-format`        | —       | yes (--fix) | yes (both) |
| `run-build`         | —       | yes  | yes     |
| `install-deps`      | —       | yes  | —       |
| `git-loop-context`  | yes     | yes  | yes     |
| `security-scan`     | —       | —    | yes     |
| `git-commit-loop`   | yes     | yes  | yes     |

### Adding Custom Skills

Projects can add domain-specific skills by dropping scripts into `./skills/`.
The loop agents will discover and invoke them if instructed in the prompt.

```
./skills/
├── detect-stack          # built-in
├── run-tests             # built-in
├── run-lint              # built-in
├── run-typecheck         # built-in
├── run-format            # built-in
├── run-build             # built-in
├── install-deps          # built-in
├── git-loop-context      # built-in
├── security-scan         # built-in
├── git-commit-loop       # built-in
├── seed-database         # custom: project-specific
├── run-e2e               # custom: playwright/cypress wrapper
└── deploy-preview        # custom: deploy to staging
```

---

## PR Creation & CI Recovery

After the loop exits with PASS:

1. **Main agent creates a PR** using `gh pr create`
2. **Main agent monitors CI** using `gh run watch` or `gh pr checks`
3. **If CI fails:**
   - Extract the failure details
   - Re-invoke `/loop` with the same task description
   - The loop detects prior iterations via git log and resumes
   - The Planner receives the CI failure as prior context
   - Loop resumes until Checker passes again
4. **If CI passes:** Done

---

## Constraints & Design Decisions

| Decision | Rationale |
|---|---|
| SKILL.md as orchestrator | The main agent runs the loop directly, spawning Task subagents. No nested `claude -p` needed. |
| Task subagent per phase | Each agent gets a fresh context with only git log as shared state. |
| Git commits as progress log | No separate progress file — commits are atomically tied to code state. Impossible to desync. |
| Conventional commits + trailers | Human-readable subject line + machine-queryable metadata. Works with existing tooling (changelogs, CI filters). |
| Type reflects actual change | `feat`/`fix`/`refactor` for doer, `chore` for planner, `fix`/`style`/`refactor`/`test` for checker fixes, `test` for verdict — stays true to conventional commits semantics. |
| Checker as reviewer | Checker fixes what it can (style, lint, small bugs, test gaps) before issuing verdict. FAIL means "issues I couldn't resolve myself." Reduces iteration count. |
| Verdict is always last commit | Bash orchestrator can reliably read the verdict by checking the most recent `Loop-Verdict:` trailer. |
| Git trailers for loop metadata | Native git feature (`git interpret-trailers`). Queryable with `git log --grep`. No custom parsing needed. |
| Max iteration cap | Safety valve — prevents infinite loops (default: 10). |
| Explore subagents only | Agents can't spawn doer/planner/checker subagents — only Explore for read-only codebase search. |
