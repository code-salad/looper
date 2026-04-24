# Looper

**Plan-Do-Check loop orchestrator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code)**

Three AI agents — Planner, Doer, Checker — iterate in a loop until your code passes all checks, then automatically create a PR.

[![Version](https://img.shields.io/badge/version-0.35.0-blue)](.claude-plugin/plugin.json)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![CI](https://img.shields.io/badge/CI-passing-brightgreen)](.github/workflows/ci.yml)

---

## What is Looper?

Looper is a Claude Code plugin that automates the full development cycle. Give it a task description, and it will:

1. **Plan** — Explore your codebase and produce a detailed implementation plan
2. **Do** — Write the code, tests, and run all checks
3. **Check** — Review the work, fix issues, and issue a PASS/FAIL verdict
4. **Repeat** — If FAIL, iterate with feedback until it passes
5. **Ship** — On PASS, automatically create a GitHub PR with architecture diagrams

No manual intervention required. Just describe what you want, and Looper handles the rest.

---

## Key Features

- **Automated PDC Loop** — Plan-Do-Check agents iterate until quality passes
- **Auto Tech Stack Detection** — Supports Node.js, Python, Go, Rust, .NET, and more
- **Automated Quality Gates** — Tests, linting, type checking, formatting, security scanning
- **Git-Based State** — All progress tracked via conventional commits with structured trailers
- **Auto PR Creation** — PRs with Mermaid architecture diagrams and test results
- **Isolated Worktrees** — Each task runs in its own git worktree
- **Resume Support** — Pick up interrupted loops from the last iteration
- **Issue Automation** — Auto-pick GitHub issues and work on them end-to-end
- **Multi-Plugin Marketplace** — Modular plugin architecture with MCP server integration

---

## Quick Start

### 1. Install

```bash
claude plugin install code-salad/looper
```

### 2. Run your first loop

```
/looper:loop "add input validation to the login endpoint"
```

### 3. Watch it work

Looper creates a git worktree, runs the PDC loop, and creates a PR when done. Each iteration produces conventional commits you can inspect:

```bash
git log --grep="Loop-Phase:" --oneline
```

---

## Use Cases

### Automate Feature Development

> "Build a complete feature from a single prompt."

```
/looper:loop "add OAuth2 login with Google and GitHub providers"
```

The Planner agent explores your codebase, identifies the auth module, and produces a step-by-step plan. The Doer implements routes, middleware, and tests. The Checker verifies everything works end-to-end.

### Automate Bug Fixes

> "Describe the bug, get a tested fix."

```
/looper:loop "fix memory leak in the worker pool when connections timeout"
```

Looper analyzes the bug, identifies root cause, implements the fix, writes regression tests, and verifies all existing tests still pass.

### Automate Refactoring

> "Restructure code with confidence."

```
/looper:loop "refactor auth module from callbacks to async/await with proper error handling"
```

The Planner maps all affected files, the Doer refactors systematically, and the Checker ensures no regressions.

### Auto-Generate PRs with Architecture Diagrams

> "Professional PRs with visual documentation."

```
/looper:create-github-pr
```

Creates a comprehensive PR with:
- Problem statement
- Before/After Mermaid architecture diagrams
- Key changes walkthrough
- Test results and CI status

### Automated Code Review

> "AI-powered review with 5 specialized reviewers."

Every iteration, the Checker agent spawns 5 parallel review subagents:
- **Type Checker** — Verifies type safety and build success
- **Test Checker** — Validates test coverage (missing tests = BLOCKER)
- **Logic Reviewer** — Checks correctness and edge cases
- **Code Quality** — Lint, format, security scan, conventions
- **Integration Tester** — Starts dev server and tests endpoints

### Automated Issue Processing

> "Point Looper at your GitHub repo and let it work issues automatically."

```
/looper:looper-issue
```

Looper finds an open, unassigned issue, assigns it to you, runs the full PDC loop, and opens a PR — all without manual intervention. Use `looper-watch` to poll continuously:

```
/looper:looper-watch owner/repo 30
```

### Multi-Language Project Support

Looper auto-detects your tech stack and uses the right tools:

| Language | Test Runner | Linter | Formatter | Type Checker | Build |
|----------|-------------|--------|-----------|-------------|-------|
| TypeScript/JS | vitest, jest, mocha | eslint, biome | prettier, biome | tsc | vite, webpack, esbuild |
| Python | pytest | ruff, flake8 | black, ruff | mypy, pyright | — |
| Go | go test | golangci-lint | gofmt | go vet | go build |
| Rust | cargo test | clippy | rustfmt | cargo check | cargo build |
| C#/.NET | dotnet test | dotnet format | dotnet format | dotnet build | dotnet build |

---

## How It Works

```mermaid
flowchart TD
    A["User: /looper:loop 'task description'"] --> B["SKILL.md Orchestrator"]
    B --> C["Create Git Worktree"]
    C --> D["Sync with Remote"]
    D --> E["Build Project Context"]
    E --> F["PDC Loop"]

    subgraph F ["PDC Loop (max 10 iterations)"]
        direction TB
        P["Planner Agent"] -->|"commits plan"| DO["Doer Agent"]
        DO -->|"commits code + tests"| CH["Checker Agent"]
        CH --> V{"Verdict?"}
        V -->|"FAIL + feedback"| P
        V -->|"PASS"| EXIT["Exit Loop"]
    end

    EXIT --> PR["Create GitHub PR"]
    PR --> CI["Wait for CI"]
```

### Modes

Looper supports two execution modes. Pick one per invocation.

| Mode | Command | Isolation | Use when |
|------|---------|-----------|----------|
| **Worktree** (default) | `/looper:loop "<task>"` | Git worktree at `.worktrees/<name>/`. Host env, host network, host creds. | Single-developer, single-task, trusted environment. |
| **Sandboxed** (opt-in) | `/looper:looper-sandboxed "<task>"` | `docker` backend (default): `docker run` + bind-mount + `/var/run/docker.sock` for nested Docker. `sbx` backend (opt-in): microVM + host-side secret proxy. | Concurrent loops, defense-in-depth, or preparing for remote fleet execution. |

Both modes run the same PDC loop — only the execution environment differs.
Sandboxed mode requires the selected backend (see Backends below).

### Backends

The sandboxed mode supports a pluggable backend via the
`LOOPER_SANDBOX_BACKEND` env var.

| Backend | Command | When to use | Security tradeoff |
|---------|---------|-------------|-------------------|
| `docker` (default) | `docker run` + bind-mount + `/var/run/docker.sock` | Hyper-V, WSL2, cloud VMs without KVM. Any host that can run Docker. | **DooD:** the sandbox has full access to the host Docker daemon via the socket mount — trivial container escape. Acceptable for single-user local use; not for untrusted agents. |
| `sbx` (opt-in) | `sbx run --branch --policy balanced` | Hosts with KVM; want stronger isolation. | microVM + host-side secret proxy. Per-sandbox daemon — no socket mount, no host-exposure tradeoff. |
| Future (`e2b`, `runloop`, ...) | TBD | Remote fleet execution. | TBD. |

Select the backend per-invocation:

```bash
# Default
/looper:looper-sandboxed "add input validation"

# Opt in to sbx
LOOPER_SANDBOX_BACKEND=sbx /looper:looper-sandboxed "add input validation"
```

Why nested Docker? Looper's integration-test helpers (`compose-isolate`,
`compose-lifecycle`) run `docker compose up/down`. The sandbox must reach
a Docker daemon.
- `docker` backend: DooD via socket mount — compose services spawn as
  *siblings* on the host.
- `sbx` backend: native nested Docker — each sandbox has its own daemon.

Rejected alternatives: `--privileged` DinD (security-hostile, slow) and
rootless Docker-inside-sandbox (parked for a future hardened mode).

### State Management

All state is stored in git commits with structured trailers:

```
feat(add-auth): implement OAuth2 login flow

Added Google and GitHub OAuth providers with session management.

Loop-Phase: do
Loop-Iteration: 2
```

Query loop progress with git:

```bash
# All plan commits
git log --grep="Loop-Phase: plan" --oneline

# Specific iteration
git log --grep="Loop-Iteration: 2" --oneline

# Find the PASS verdict
git log --grep="Loop-Verdict: PASS" --format="%B" -1
```

---

## Architecture

### Architecture Diagrams

Looper ships a [LikeC4](https://likec4.dev) model of its own architecture under [`likec4/`](likec4/). Rendered views:

**Landscape — who talks to Looper**

![Landscape](likec4/exports/index.png)

**Inside Looper — the two plugins and the watcher binary**

![Looper internals](likec4/exports/looper_internals.png)

**Plan-Do-Check loop — one iteration**

![PDC loop](likec4/exports/pdc_loop.png)

Browse the full set of views (landscape, internals, `looper` plugin detail, `looper-watch` detail, PDC loop, watcher dispatch flow) with:

```bash
npx likec4@latest serve -i likec4
```

See [`likec4/`](likec4/) for the `.c4` sources and [CONTRIBUTING.md](CONTRIBUTING.md#architecture-diagrams-likec4) for how to update them.

### Plugins

Looper uses a multi-plugin marketplace architecture. Three plugins ship together:

| Plugin | Description |
|--------|-------------|
| **looper** | Core PDC loop — agents, skills, and scripts |
| **webscraping** | Web scraping agents and skills for gathering context from URLs |

Each plugin lives under `plugins/<name>/` and can be installed independently.

### Agents

| Agent | Model | Role | Tools |
|-------|-------|------|-------|
| **Planner** | Opus | Explores codebase, produces actionable plan | Read, Glob, Grep, Bash (read-only) |
| **Doer** | Sonnet | Implements plan, writes tests, runs checks | Read, Write, Edit, Bash, Glob, Grep |
| **Checker** | Opus | Reviews work, issues PASS/FAIL verdict | Read, Bash, Glob, Grep |
| **GH Issue Creator** | Haiku | Creates structured GitHub issues (bugs, features, tasks) with dependencies, blockers, and subtasks | Bash, Read, Grep, Glob |

### Skills

| Skill | Command | Description |
|-------|---------|-------------|
| Loop | `/looper:loop "task"` | Main PDC loop orchestrator |
| Git Commit | `/looper:git-commit` | Conventional commit helper |
| Create PR | `/looper:create-github-pr` | PR with architecture diagrams |
| Worktree | `/looper:initiate-worktree "name"` | Git worktree helper |
| Looper EE | `/looper:looper-ee <issue_url>` | Work on a GitHub issue from an external repo |
| Looper Issue | `/looper:looper-issue` | Auto-pick an open GitHub issue and work on it |
| Looper Watch | `/looper:looper-watch <owner/repo> [interval]` | Poll a GitHub repo and work issues automatically |
| Looper Sandboxed | `/looper:looper-sandboxed "task"` | Run the PDC loop inside a sandbox (`docker` default via DooD; `sbx` opt-in via `LOOPER_SANDBOX_BACKEND=sbx`) |

### Utility Scripts

All scripts live in `plugins/looper/skills/looper/scripts/` and auto-detect your tech stack:

| Script | Purpose |
|--------|---------|
| `detect-stack` | Auto-detect project tech stack (JSON) |
| `detect-resume` | Detect and resume interrupted loops |
| `git-commit-loop` | Create commits with loop trailers |
| `git-loop-context` | Read prior loop iterations from git log |
| `list-ready-issues` | List open, unassigned, non-blocked issues (`--repo`, `--label`, `--limit`, `--json`) |
| `validate-issue-body` | Validate issue body has canonical `## Dependencies` / `## Blockers` markers when cross-issue refs are present |
| `run-tests` | Run test suite |
| `run-lint` | Run linter (with `--fix`) |
| `run-typecheck` | Run type checker |
| `run-format` | Run formatter (with `--fix`) |
| `run-build` | Build the project |
| `install-deps` | Install dependencies |
| `security-scan` | Security vulnerability scan |
| `setup-worktree` | Create or resume a git worktree for a task |
| `sync-with-remote` | Sync worktree with remote branch |

---

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `LOOPER_MAX_ITERATIONS` | `10` | Maximum PDC loop iterations |
| `CLAUDE_STREAM_IDLE_TIMEOUT_MS` | `300000` (Claude Code default, 5 min) | Stream idle timer that fires on stalled model streams (no tokens flowing from the API). Set to `7200000` (2 h) for longer loops — productive subagents actively generating tokens do not trip it, but this provides belt-and-suspenders headroom for rare model stalls. |

```bash
LOOPER_MAX_ITERATIONS=5 claude
CLAUDE_STREAM_IDLE_TIMEOUT_MS=7200000 claude   # recommended for longer loops
```

---

## Requirements

- [`claude` CLI](https://docs.anthropic.com/en/docs/claude-code) (Claude Code)
- `git`
- `jq`
- `gh` (GitHub CLI, optional — required for PR creation and issue automation)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style, and PR process.

## License

MIT
