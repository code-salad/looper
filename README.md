# Looper

A Plan-Do-Check loop orchestrator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Three agents — Planner, Doer, Checker — iterate in a loop until the Checker issues a PASS verdict, then automatically create a PR.

## Installation

Install as a Claude Code plugin:

```bash
# From GitHub
claude plugin install vikyw89/looper

# From a local checkout
claude plugin install /path/to/looper
```

## Usage

Once installed, invoke the loop skill from any Claude Code session:

```
/looper:loop "add input validation to the login endpoint"
```

The loop runs entirely through Claude Code's skill system. It creates a git
worktree for isolation, iterates Plan-Do-Check until PASS, then creates a PR.

### Options

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `LOOPER_MAX_ITERATIONS` | `10` | Maximum PDC loop iterations before giving up |

To override max iterations:

```bash
LOOPER_MAX_ITERATIONS=5 claude
```

## How It Works

```
User invokes /looper:loop
       │
       ▼
  SKILL.md orchestrator
       │
       ├── Planner agent (Task subagent) → reads codebase, commits a plan
       ├── Doer agent    (Task subagent) → implements the plan, commits code
       └── Checker agent (Task subagent) → reviews, fixes, issues PASS/FAIL
       │
       ▼
  PASS? → create PR    FAIL? → next iteration
```

Each agent runs as a Task subagent. State is passed between iterations via git commits with structured trailers (`Loop-Phase`, `Loop-Iteration`, `Loop-Verdict`).

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
