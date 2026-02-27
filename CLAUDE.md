# Looper — PDC Loop System

## What This Is

A Plan-Do-Check loop orchestrator for Claude Code. The bash script `loop.sh`
drives three `claude -p` agents (Planner, Doer, Checker) in a loop until the
Checker issues a PASS verdict.

## Project Structure

```
skills/            Bash scripts that abstract tech-stack operations
loop.sh            Main orchestrator — runs the PDC loop
docs/              Design docs and flow diagrams
.claude/agents/    Agent definitions (planner, doer, checker)
.claude/skills/    Claude Code user-invocable skills
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
./loop.sh --task <task-name> --prompt "description of what to do"
```

Optional flags: `--context <extra-context>`, `--model <model>`, `--max-iterations <N>`.

## Dependencies

- `claude` CLI (Claude Code)
- `jq` (JSON processing)
- `git`
