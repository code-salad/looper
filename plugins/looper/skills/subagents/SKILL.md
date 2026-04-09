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

Run the discovery script to get the list of available agents:

```bash
claude agents 2>&1
```

If that fails (permission denied in non-interactive mode), fall back to scanning plugin files:

```bash
for f in $(find ~/.claude/plugins/cache -name "*.md" -path "*/agents/*" 2>/dev/null | sort); do
  plugin=$(echo "$f" | sed 's|.*cache/[^/]*/\([^/]*\)/[^/]*/.*|\1|')
  agent=$(basename "$f" .md)
  model=$(grep -m1 '^model:' "$f" 2>/dev/null | sed 's/model: *//' || echo "inherit")
  desc=$(grep -m1 '^description:' "$f" 2>/dev/null | sed 's/description: *//' | head -c 80 || echo "")
  echo "  ${plugin}:${agent} · ${model} — ${desc}"
done

echo ""
echo "Built-in agents:"
echo "  claude-code-guide · haiku — Answer questions about Claude Code, Agent SDK, Claude API"
echo "  Explore · haiku — Fast codebase exploration"
echo "  general-purpose · inherit — General-purpose research and multi-step tasks"
echo "  Plan · inherit — Software architect for implementation plans"
echo "  statusline-setup · sonnet — Configure status line settings"
```

Report the full list to the user before proceeding.

---

## Phase 2: Spawn a subagent

Use `claude -p` with `--output-format json` to call a subagent and capture structured output.

### Basic pattern

```bash
OUTFILE="/tmp/subagent-result-$(date +%s).json"

env -u CLAUDECODE -u CLAUDE_CODE claude -p \
  --agent "<agent-name>" \
  --output-format json \
  --max-turns 30 \
  "Your prompt here" \
  > "$OUTFILE" 2>/dev/null

# Extract the text response
jq -r '.result // empty' "$OUTFILE"
```

**Important flags:**
- `env -u CLAUDECODE -u CLAUDE_CODE` — bypasses nested-session detection
- `--output-format json` — returns structured JSON with result, cost, token usage
- `--agent "<name>"` — selects the subagent (e.g. `looper:planner`, `fallback-agent:code-reviewer`)
- `--max-turns 30` — limits how many tool-use turns the subagent can take
- `--max-budget-usd 0.50` — optional spending cap

### Run in background

For long-running tasks, run in background and read the result later:

```bash
OUTFILE="/tmp/subagent-result-$(date +%s).json"

env -u CLAUDECODE -u CLAUDE_CODE claude -p \
  --agent "fallback-agent:code-reviewer" \
  --output-format json \
  "Review src/main.ts for bugs" \
  > "$OUTFILE" 2>/dev/null &

# Later, read the result
jq -r '.result // empty' "$OUTFILE"
```

### Run multiple subagents in parallel

```bash
TASK1="/tmp/subagent-task1-$(date +%s).json"
TASK2="/tmp/subagent-task2-$(date +%s).json"

env -u CLAUDECODE -u CLAUDE_CODE claude -p \
  --agent "fallback-agent:code-reviewer" \
  --output-format json \
  "Review src/auth.ts for security issues" \
  > "$TASK1" 2>/dev/null &

env -u CLAUDECODE -u CLAUDE_CODE claude -p \
  --agent "fallback-agent:plan" \
  --output-format json \
  "Plan how to add rate limiting to the API" \
  > "$TASK2" 2>/dev/null &

wait

echo "=== Review ===" && jq -r '.result // empty' "$TASK1"
echo "=== Plan ===" && jq -r '.result // empty' "$TASK2"
```

### Pass context to subagent

```bash
# Pass file contents
env -u CLAUDECODE -u CLAUDE_CODE claude -p \
  --agent "fallback-agent:code-reviewer" \
  --output-format json \
  "Review this code: $(cat src/main.ts)" \
  > "$OUTFILE" 2>/dev/null

# Pass with system prompt
env -u CLAUDECODE -u CLAUDE_CODE claude -p \
  --agent "general-purpose" \
  --output-format json \
  --append-system-prompt "You are working on a Node.js backend." \
  "Your prompt here" \
  > "$OUTFILE" 2>/dev/null
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
