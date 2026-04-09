---
name: subagents
description: Discover and spawn subagents via claude -p when the Agent tool is not available. Use this skill as a fallback to delegate work to specialized agents from subagent contexts or non-interactive sessions where the Agent tool is absent.
tools: Bash, Read, Glob
---

# Subagents Skill

Spawn subagents using `claude -p` when the **Agent tool is not available** — e.g. from within an Agent tool subagent, a `claude -p` session, or any context that lacks the Agent tool.

**When to use this skill:**
- You need to delegate work to a specialized agent but the Agent tool is not in your tool set
- You are running inside a subagent and need to spawn further subagents
- You want to run multiple agents in parallel from a non-interactive context

**When NOT to use this skill:**
- The Agent tool is available — use it directly instead (it's faster and cheaper)

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

Use the `spawn-agent` script to call a subagent. It handles nested-session detection bypass, JSON output, and permission skipping.

```
Scripts: ${CLAUDE_PLUGIN_ROOT}/skills/subagents/scripts/
```

### Basic usage

```bash
SPAWN="${CLAUDE_PLUGIN_ROOT}/skills/subagents/scripts/spawn-agent"

# spawn-agent <agent-name> <prompt> [extra-flags...]
$SPAWN "looper:checker" "Review the doer's work in the current worktree"
$SPAWN "looper:planner" "Plan the auth refactor" --max-turns 10
$SPAWN "general-purpose" "Summarize this: $(cat file.txt)" --max-budget-usd 0.50
```

The script:
- Unsets `CLAUDECODE`/`CLAUDE_CODE` env vars to bypass nested-session detection
- Runs with `--dangerously-skip-permissions` so the subagent isn't blocked on prompts
- Returns the text response directly (extracts `.result` from the JSON)

### Run in background

```bash
$SPAWN "looper:checker" "Review the doer's work in the current worktree" &

# Later, wait and get result
wait
```

### Run multiple subagents in parallel

```bash
$SPAWN "looper:planner" "Plan how to add rate limiting to the API" > /tmp/plan.txt &
$SPAWN "Explore" "Find all API endpoint definitions in this repo" > /tmp/explore.txt &

wait

echo "=== Plan ===" && cat /tmp/plan.txt
echo "=== Explore ===" && cat /tmp/explore.txt
```

### Pass extra context

```bash
# Pass file contents in the prompt
$SPAWN "Explore" "What does this code do: $(cat src/main.ts)"

# Pass a system prompt
$SPAWN "general-purpose" "Your prompt here" \
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
| Empty result | Check stderr: redirect `2>` to a file and inspect |
| Subagent hangs | Use `--max-turns` and `--max-budget-usd` to cap execution |
| Auth errors | Ensure Claude CLI is authenticated (`claude auth`) |
