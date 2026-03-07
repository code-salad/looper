# Looper — PDC Loop System

## What This Is

A Plan-Do-Check loop orchestrator for Claude Code, installable as a plugin.
The SKILL.md entry point drives three Agent subagents (Planner, Doer,
Checker) in a loop until the Checker issues a PASS verdict.

## Installation

```bash
# From GitHub
claude plugin install code-salad/looper

# Local install from a checkout
claude plugin install /path/to/looper/plugins/looper

# Or use the skill directly if developing in this repo
/looper "task description"
```

## Project Structure

```
.claude-plugin/
  marketplace.json         Marketplace manifest (for GitHub install)
  plugin.json              Plugin manifest (repo-level)
plugins/
  looper/                  Installable plugin
    .claude-plugin/
      plugin.json          Plugin manifest
    agents/                Agent definitions (planner, doer, checker)
    skills/
      looper/              The loop skill
        SKILL.md           User-invocable entry point (/looper) and loop orchestrator
        scripts/           Helper scripts for agents
          detect-stack     Auto-detect project tech stack
          run-tests        Run test suite
          run-lint         Run linter
          run-typecheck    Run type checker
          run-format       Run formatter
          run-build        Build project
          install-deps     Install dependencies
          security-scan    Security vulnerability scan
          git-loop-context Read loop history from git
          git-commit-loop  Commit with loop trailers
          sync-with-remote Fetch & rebase onto default remote branch
          detect-issue-template  Detect bug report issue template
      git-commit/          Conventional commit skill
      create-github-pr/    PR creation skill
      github-bug-report/   GitHub bug report issue skill
      initiate-worktree/   Git worktree skill
docs/                      Design docs and flow diagrams
```

## Key Conventions

- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org/)
  with `Loop-Phase`, `Loop-Iteration`, and optionally `Loop-Verdict` trailers.
- **Skills** in `plugins/looper/skills/` include helper bash scripts that auto-detect the
  project's tech stack via `detect-stack` and dispatch to the right tool.
- **Loop orchestration** is handled by SKILL.md, which spawns Agent subagents
  (`looper:planner`, `looper:doer`, `looper:checker`) directly.

## Running the Loop

```
/loop "description of what to do"
```

The `/looper` skill handles worktree creation, context building, iteration
management, and agent orchestration automatically.

## Dependencies

- `claude` CLI (Claude Code)
- `git`
