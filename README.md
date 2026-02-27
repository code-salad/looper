# Looper

A Plan-Do-Check loop orchestrator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Three agents — Planner, Doer, Checker — iterate in a loop until the Checker issues a PASS verdict. The loop controller is a bash script that drives `claude -p` subprocesses, sidestepping the constraint that Claude Code subagents cannot spawn subagents.

## Installation

Install as a Claude Code plugin:

```bash
# From a local checkout
claude plugin install /path/to/looper
```

## Usage

Once installed, invoke the loop skill from any Claude Code session:

```
/looper:loop "add input validation to the login endpoint"
```

Or run the orchestrator script directly:

```bash
./skills/loop/scripts/loop.sh \
    --task "add-input-validation" \
    --prompt "Add input validation to the login endpoint"
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--task` | *(required)* | Kebab-case task name (used as commit scope) |
| `--prompt` | *(required)* | Task description for agents |
| `--context` | | Extra context (e.g., CI failure details) |
| `--model` | `sonnet` | Claude model to use |
| `--max-iterations` | `10` | Max PDC loop iterations |
| `--max-turns` | `50` | Max turns per agent phase |

## How It Works

```
User invokes /loop
       │
       ▼
    loop.sh  (bash orchestrator)
       │
       ├── Planner agent (claude -p) → reads codebase, commits a plan
       ├── Doer agent    (claude -p) → implements the plan, commits code
       └── Checker agent (claude -p) → reviews, fixes, issues PASS/FAIL
       │
       ▼
  PASS? → exit    FAIL? → next iteration
```

Each agent runs as an independent `claude -p` subprocess. State is passed between iterations via git commits with structured trailers (`Loop-Phase`, `Loop-Iteration`, `Loop-Verdict`).

## Components

### Agents (`agents/`)

| Agent | File | Role |
|-------|------|------|
| Planner | `agents/planner.md` | Explores codebase, produces actionable plan (read-only) |
| Doer | `agents/doer.md` | Implements the plan, runs tests, commits changes |
| Checker | `agents/checker.md` | Reviews work, fixes issues, issues PASS/FAIL verdict |

### Skills (`skills/`)

| Skill | Description |
|-------|-------------|
| `loop` | Main PDC loop entry point (`/loop`) |
| `git-commit` | Conventional commit helper (`/git-commit`) |
| `create-github-pr` | PR creation with architecture diagrams (`/create-github-pr`) |
| `initiate-worktree` | Git worktree helper (`/initiate-worktree`) |

### Utility Scripts (`skills/loop/scripts/`)

| Script | Purpose |
|--------|---------|
| `loop.sh` | Main PDC loop orchestrator |
| `detect-stack` | Auto-detect project tech stack (JSON output) |
| `run-tests` | Run test suite |
| `run-lint` | Run linter |
| `run-typecheck` | Run type checker |
| `run-format` | Run formatter |
| `run-build` | Build the project |
| `install-deps` | Install project dependencies |
| `security-scan` | Security vulnerability scan |
| `git-loop-context` | Read loop history from git |
| `git-commit-loop` | Commit with loop trailers |

The utility scripts auto-detect the project's tech stack and dispatch to the appropriate tool (e.g., `vitest`/`jest`/`pytest` for tests, `eslint`/`ruff`/`clippy` for linting).

## Requirements

- `claude` CLI ([Claude Code](https://docs.anthropic.com/en/docs/claude-code))
- `jq`
- `git`

## License

MIT
