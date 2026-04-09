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

### Sync mode (default)

Blocks until the subagent completes. Prints the path to the result file.
**Important:** Must be run via `run_in_background: true` in the Bash tool
(Claude Code's Bash tool suppresses stdout from nested Claude processes in
foreground mode).

```bash
SPAWN="${CLAUDE_PLUGIN_ROOT}/skills/subagents/scripts/spawn-agent"

# Run in background, then read result
$SPAWN "looper:checker" "Review the doer's work" # prints /tmp/subagent-response-<ts>-<pid>.txt
```

```bash
# Full pattern: launch in background Bash, read result file after
RESULT=$($SPAWN "Explore" "What language is this repo?")
cat "$RESULT"
```

### Async mode

Returns the result file path immediately, runs the subagent in background.
Ideal for parallel spawning — fire multiple agents, do other work, read later.

```bash
SPAWN="${CLAUDE_PLUGIN_ROOT}/skills/subagents/scripts/spawn-agent"

# Fire and get path back instantly
RESULT=$($SPAWN --async "Explore" "Find all API endpoints")
# ... do other work ...
# Poll until file is non-empty
cat "$RESULT"
```

### Run multiple subagents in parallel (async)

```bash
SPAWN="${CLAUDE_PLUGIN_ROOT}/skills/subagents/scripts/spawn-agent"

R1=$($SPAWN --async "looper:planner" "Plan how to add rate limiting")
R2=$($SPAWN --async "Explore" "Find all API endpoint definitions")

# Wait for both to finish (poll until files are non-empty)
while [ ! -s "$R1" ] || [ ! -s "$R2" ]; do sleep 2; done

echo "=== Plan ===" && cat "$R1"
echo "=== Explore ===" && cat "$R2"
```

### Extra flags

```bash
# Limit turns and budget
$SPAWN "looper:planner" "Plan the auth refactor" --max-turns 10 --max-budget-usd 0.50

# Pass file contents in the prompt
$SPAWN "Explore" "What does this code do: $(cat src/main.ts)"

# Pass a system prompt
$SPAWN "general-purpose" "Your prompt" \
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
