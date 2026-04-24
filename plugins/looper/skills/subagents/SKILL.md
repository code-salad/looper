---
name: subagents
description: Fallback for spawning subagents — use ONLY when the built-in `Agent` tool is not in your tools list (e.g. inside a nested subagent whose frontmatter omits `Agent`, a `claude -p` session, or a shell script). Prefer `Agent` when available. Wraps `claude -p` via the `claude-spawn-agent` script.
tools: Bash, Read, Glob
---

# Subagents Skill

`claude-spawn-agent` is the **fallback** spawn mechanism for contexts
where the built-in `Agent` tool isn't in your tools list — nested
subagents, fresh `claude -p` sessions, or shell scripts. It spawns a
fresh `claude -p` subprocess and is a drop-in for `Agent`: the
subagent's text response is printed directly to stdout.

Prefer the built-in `Agent` tool whenever it's available in your tools
list. `Agent` is in-process, faster, and cheaper than a `claude -p`
subprocess.

**When to use this skill:**
- `Agent` is not in your tools list (e.g. you are a subagent whose
  frontmatter only lists `Bash, Read, Grep, Glob` etc.)
- You are running in a `claude -p` session or shell script
- You need to fan out several subagents in parallel from a non-interactive
  context

**When NOT to use this skill:**
- The built-in `Agent` tool is available — use that instead.

---

## Built-in agents reference

These agents are provided by the Claude Code harness and are always available for spawning:

| Agent | Model | Best for |
|-------|-------|----------|
| **Explore** | haiku | Fast, read-only codebase exploration. Use for finding files by pattern, searching code for keywords, understanding how subsystems work, or answering questions about the codebase. **Prefer this over manual Glob/Grep when the search requires multiple rounds or cross-cutting context** (e.g. "how does auth flow through the app", "find all callers of X"). Cheaper and faster than general-purpose. |
| **Plan** | inherit | Software architect agent. Use when you need to design an implementation strategy, identify critical files, and consider architectural trade-offs before writing code. Returns step-by-step plans. |
| **general-purpose** | inherit | General-purpose research and multi-step tasks. Use for complex questions that span the codebase, web searches, or tasks that don't fit a specialized agent. Has access to all tools. |
| **claude-code-guide** | haiku | Answers questions about Claude Code features, hooks, slash commands, MCP servers, settings, IDE integrations, the Agent SDK, and the Claude API. |
| **statusline-setup** | sonnet | Configures the Claude Code status line setting. Narrow use case. |

### When to spawn Explore vs. using Grep/Glob directly

- **Use Grep/Glob directly** when you know exactly what you're looking for (a specific symbol, file name, or pattern) and a single query will suffice.
- **Spawn Explore** when:
  - The search is open-ended or requires multiple rounds of searching
  - You need to understand how multiple files/modules relate to each other
  - You need to trace a flow across the codebase (e.g. request handling, data pipeline)
  - You're unfamiliar with the area of code and need orientation
  - You'd otherwise need 3+ sequential Grep/Glob calls to find what you need

---

## Phase 1: Discover available subagents

Run the discovery script:

```bash
# Try claude agents first (works when permissions allow)
claude agents 2>&1 || ${CLAUDE_PLUGIN_ROOT}/skills/subagents/scripts/list-agents
```

The `list-agents` script scans `~/.claude/plugins/cache` for agent definitions and lists all plugin and built-in agents. It works in any context, including non-interactive `claude -p` sessions where `claude agents` may be permission-denied.

Report the full list to the user before proceeding.

---

## Phase 2: Spawn a subagent

Use the `claude-spawn-agent` command to call a subagent. It handles nested-session detection bypass, JSON output, and permission skipping.

Claude Code puts every plugin's `bin/` directory on `PATH` in all contexts —
main session, Agent-tool subagents, and fresh `claude -p` subprocesses alike —
so `claude-spawn-agent` resolves without any caller-side configuration. The
underlying script self-locates its `CLAUDE_PLUGIN_ROOT` from its own path
(the plugin root is derived from `BASH_SOURCE`), so plugin-scoped agents like
`looper:checker` continue to resolve even when `CLAUDE_PLUGIN_ROOT` is unset
in the caller's environment. Callers never need to know the plugin's install
layout or export any env vars.

### Via the Bash tool with `run_in_background: true` (canonical single-spawn)

```bash
claude-spawn-agent "looper:checker" "Review the doer's work"
```

The Bash tool returns immediately with a task handle and the parent
receives an automatic completion notification when the subprocess exits.
At that point the completion notification's output contains the subagent's
text response directly — no file to read.

### Foreground capture

```bash
RESPONSE=$(claude-spawn-agent "Explore" "Find all API endpoints")
echo "$RESPONSE"
```

### Parallel fan-out

For parallel fan-out, redirect each subagent's stdout to a temp file, run
them in the background, then `wait`:

```bash
claude-spawn-agent "looper:planner" "Plan rate limiting" > /tmp/p1.txt &
claude-spawn-agent "Explore"        "Find API endpoints"  > /tmp/p2.txt &
wait
cat /tmp/p1.txt /tmp/p2.txt
```

### Extra flags

```bash
# Limit turns and budget
claude-spawn-agent "looper:planner" "Plan the auth refactor" --max-turns 10 --max-budget-usd 0.50

# Pass file contents in the prompt
claude-spawn-agent "Explore" "What does this code do: $(cat src/main.ts)"

# Pass a system prompt
claude-spawn-agent "general-purpose" "Your prompt" \
  --append-system-prompt "You are working on a Node.js backend."
```

---

## JSON response format

The `--output-format json` response contains:

```json
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "The subagent's text response",
  "duration_ms": 5000,
  "total_cost_usd": 0.05,
  "session_id": "uuid",
  "stop_reason": "end_turn"
}
```

Key fields:
- `result` — the subagent's final text response
- `is_error` — whether the subagent encountered an error
- `total_cost_usd` — cost of the subagent session
- `session_id` — can be used with `--resume` to continue the conversation

---

## Error handling

| Scenario | Action |
|----------|--------|
| Agent not found | Check agent name with `claude agents` or the fallback scan |
| Permission denied on `claude agents` | Use the filesystem fallback in Phase 1 |
| Empty result | stdout is empty; check stderr for error messages |
| Subagent hangs | Use `--max-turns` and `--max-budget-usd` to cap execution |
| Auth errors | Ensure Claude CLI is authenticated (`claude auth`) |
