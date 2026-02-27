# Looper — PDC Loop System

## What This Is

A Plan-Do-Check loop orchestrator for Claude Code, installable as a plugin.
The bash script `loop.sh` drives three `claude -p` agents (Planner, Doer,
Checker) in a loop until the Checker issues a PASS verdict.

## Installation

```bash
# Local install from a checkout
claude plugin install /path/to/looper

# Or use the skill directly if developing in this repo
/loop "task description"
```

## Project Structure

```
.claude-plugin/
  plugin.json              Plugin manifest
agents/                    Agent definitions (planner, doer, checker)
skills/
  loop/                    The loop skill
    SKILL.md               User-invocable entry point (/loop)
    scripts/               All executable scripts
      loop.sh              Main PDC loop orchestrator
      detect-stack         Auto-detect project tech stack
      run-tests            Run test suite
      run-lint             Run linter
      run-typecheck        Run type checker
      run-format           Run formatter
      run-build            Build project
      install-deps         Install dependencies
      security-scan        Security vulnerability scan
      git-loop-context     Read loop history from git
      git-commit-loop      Commit with loop trailers
  git-commit/              Conventional commit skill
  create-github-pr/        PR creation skill
  initiate-worktree/       Git worktree skill
docs/                      Design docs and flow diagrams
```

## Key Conventions

- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org/)
  with `Loop-Phase`, `Loop-Iteration`, and optionally `Loop-Verdict` trailers.
- **Skills** in `skills/` are executable bash scripts. They auto-detect the
  project's tech stack via `skills/detect-stack` and dispatch to the right tool.
- **`claude -p` invocations** must include `--setting-sources user,project` to
  load CLAUDE.md (it is NOT auto-loaded in `-p` mode).

## Running the Loop

```bash
./skills/loop/scripts/loop.sh --task <task-name> --prompt "description of what to do"
```

Optional flags: `--context <extra-context>`, `--model <model>`, `--max-iterations <N>`.

## Dependencies

- `claude` CLI (Claude Code)
- `jq` (JSON processing)
- `git`
