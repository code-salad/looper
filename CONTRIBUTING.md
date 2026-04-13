# Contributing to Looper

Thank you for your interest in contributing to Looper. This document covers development setup, project structure, code style, commit conventions, and the PR process.

---

## Overview

Looper is a Claude Code plugin that orchestrates a Plan-Do-Check (PDC) loop using three AI agents. Contributions can be to agent prompts, shell scripts, MCP servers, documentation, or CI tooling.

---

## Development Setup

### Prerequisites

- [`claude` CLI](https://docs.anthropic.com/en/docs/claude-code) (Claude Code)
- `git`
- `jq`
- `gh` (GitHub CLI — required for PR creation and issue automation)
- `shellcheck` (for linting shell scripts)
- Rust toolchain (only if modifying the `looper-watch` binary)

### Cloning the Repo

```bash
git clone https://github.com/code-salad/looper.git
cd looper
```

No additional build step is required. The plugin is plain shell scripts and Markdown files (plus a Rust binary for looper-watch).

### Setting Up Git Hooks

The repo includes a pre-push hook that runs ShellCheck, `cargo clippy`, and `cargo test` before every push:

```bash
git config core.hooksPath scripts/
```

### Installing the Plugin Locally

To test your changes in Claude Code, install from a local path:

```bash
claude plugin install ./
```

---

## Project Structure

```
looper/
├── .claude-plugin/
│   ├── plugin.json          # Root plugin manifest
│   └── marketplace.json     # Multi-plugin marketplace definition
├── plugins/
│   ├── looper/              # Core PDC loop plugin
│   │   ├── agents/          # Agent prompt files (Markdown)
│   │   │   ├── planner.md
│   │   │   ├── doer.md
│   │   │   ├── checker.md
│   │   │   └── gh-issue-creator.md
│   │   ├── .mcp.json        # MCP server configuration
│   │   └── skills/          # Skill definitions
│   │       ├── looper/      # Main loop skill
│   │       │   ├── SKILL.md
│   │       │   └── scripts/ # Utility scripts (shell)
│   │       ├── create-github-pr/
│   │       ├── git-commit/
│   │       ├── initiate-worktree/
│   │       ├── looper-ee/
│   │       ├── looper-issue/
│   │       └── looper-watch/
│   └── webscraping/         # Web scraping plugin
│       ├── agents/
│       └── skills/
└── .github/
    └── workflows/
        └── ci.yml           # CI pipeline
```

---

## Code Style and Conventions

### Shell Scripts

- All scripts in `plugins/looper/skills/looper/scripts/` must be executable (`chmod +x`).
- Scripts must pass [ShellCheck](https://www.shellcheck.net/) — this is enforced by CI.
- Use `#!/usr/bin/env bash` as the shebang line.
- Prefer `local` for function-scoped variables.
- Use `set -euo pipefail` at the top of scripts.
- Common helpers are in `scripts/_helpers.sh` — source it where needed.

### Agent Prompts

- Agent prompts are Markdown files in `plugins/<plugin>/agents/`.
- Use clear section headers and keep instructions unambiguous.
- Avoid hard-coding file paths — use environment variables or relative paths.

### Skills

- Each skill lives in its own directory under `plugins/<plugin>/skills/<skill-name>/`.
- Every skill directory must contain a `SKILL.md` file with YAML frontmatter:

```yaml
---
name: skill-name
description: >-
  One-sentence description used in the Claude Code skill picker.
tools: Bash, Read, Glob, Grep
---
```

- The `tools` field lists all Claude tools the skill may invoke.

### Plugin Manifests

- `plugin.json` and `marketplace.json` must be valid JSON — CI validates this.
- Bump the `version` field in `plugin.json` for every release using semantic versioning.

---

## Commit Conventions

Looper uses [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): short description

Optional longer body explaining the why.
```

**Types:**

| Type | When to use |
|------|-------------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code restructuring without behavior change |
| `test` | Test additions or fixes |
| `chore` | Build, CI, dependency, or tooling changes |

**Scope** is optional but recommended — use the plugin name, skill name, or area (e.g., `looper`, `checker`, `scripts`).

### Loop Commits

Commits created by the PDC loop agents include structured trailers:

```
feat(my-task): implement feature X

Added feature X with tests.

Loop-Phase: do
Loop-Iteration: 2
Loop-Verdict: PASS
```

These trailers allow querying loop state with `git log --grep`.

---

## PR Process

1. **Branch from `main`:**
   ```bash
   git checkout -b feat/my-feature
   ```

2. **Make your changes** following the conventions above.

3. **Run CI checks locally** before pushing (automatic if you configured git hooks above):
   ```bash
   shellcheck plugins/looper/skills/looper/scripts/*
   cargo clippy --workspace -- -D warnings
   cargo test --workspace
   ```

4. **Push and open a PR** targeting `main`:
   ```bash
   git push -u origin feat/my-feature
   gh pr create --base main
   ```

   Or use the Looper skill for an auto-generated PR with architecture diagrams:
   ```
   /looper:create-github-pr
   ```

5. **CI must pass** — ShellCheck, JSON validation, executable permission checks, and required file existence checks.

6. PRs are reviewed and merged by maintainers. Keep PRs focused — one concern per PR.

---

## Testing and CI

The CI pipeline (`.github/workflows/ci.yml`) validates:

- **ShellCheck** — All shell scripts in `plugins/looper/skills/looper/scripts/` must pass without errors.
- **JSON validation** — `plugin.json` and `marketplace.json` must be parseable by `jq`.
- **Executable permissions** — All scripts in the `scripts/` directory must be executable.
- **Required files** — Key files like `SKILL.md` and `plugin.json` must exist.
- **Cargo Test** — All Rust unit tests across the workspace must pass.
- **Cargo Clippy** — Rust code must have zero clippy warnings.
- **Cargo Audit** — Dependencies must have no known security vulnerabilities.

There is no automated test suite for the agent prompts — correctness is validated by running the PDC loop against real tasks.

---

## Adding a New Skill

1. Create a directory: `plugins/looper/skills/<skill-name>/`
2. Add a `SKILL.md` with YAML frontmatter (see [Skills](#skills) above).
3. Add any supporting scripts in a `scripts/` subdirectory. Make them executable.
4. Register the skill in `marketplace.json` if needed.
5. Update the Skills table in `README.md`.

---

## Adding a New Agent

1. Create a Markdown file in `plugins/<plugin>/agents/<agent-name>.md`.
2. Write the agent prompt following the conventions of existing agents.
3. Reference the agent from the relevant skill or orchestrator.
4. Update the Agents table in `README.md`.

---

## Questions and Issues

Open a [GitHub issue](https://github.com/code-salad/looper/issues) for bugs, feature requests, or questions. When reporting a bug, include:

- The task description you passed to Looper
- The git log output (`git log --grep="Loop-Phase:" --oneline`)
- The full error message or unexpected behavior
