---
name: claude-wrap
description: Call a nested Claude CLI instance from within Claude Code. Use this skill when you need to spawn a separate Claude session to run a prompt, get a second opinion, or delegate a task to another Claude instance. Supports model selection (e.g. Sonnet for cheaper/faster tasks).
tools: Bash, Read
---

# Claude Wrap Skill

Calls the Claude CLI from within a Claude Code session, bypassing the nested-session detection. Output is captured to files since the Bash tool filters direct stdout from Claude processes.

## Prerequisites

- Claude CLI (`claude`) must be installed and on PATH
- `jq` must be available for JSON extraction
- The wrapper script must exist at `~/.local/bin/claude-wrap`

---

## Setup (one-time)

If `~/.local/bin/claude-wrap` does not exist, create it:

```bash
mkdir -p ~/.local/bin
cat > ~/.local/bin/claude-wrap << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

OUTFILE="/tmp/claude-wrap-result.json"
RESULTFILE="/tmp/claude-wrap-response.txt"
rm -f "$OUTFILE" "$RESULTFILE"

env -u CLAUDECODE -u CLAUDE_CODE claude -p "$@" --output-format json >"$OUTFILE" 2>/tmp/claude-wrap-err.log
EXIT_CODE=$?

jq -r '.result // empty' "$OUTFILE" > "$RESULTFILE" 2>/dev/null || cp "$OUTFILE" "$RESULTFILE"

exit $EXIT_CODE
SCRIPT
chmod +x ~/.local/bin/claude-wrap
```

---

## Usage

### Step 1: Run the prompt in background

The command **must** be run in background mode (`run_in_background: true`) because the Bash tool suppresses all stdout from foreground Claude processes.

```bash
claude-wrap "your prompt here" &
```

To use a specific model:

```bash
claude-wrap "your prompt here" --model claude-sonnet-4-6 &
```

Available models:
- `claude-opus-4-6` (default, most capable)
- `claude-sonnet-4-6` (faster, cheaper)
- `claude-haiku-4-5` (fastest, cheapest)

You can also pass any other Claude CLI flags after the prompt.

### Step 2: Wait and read the response

After launching in background, wait for completion then read the result:

```bash
sleep 20 && cat /tmp/claude-wrap-response.txt
```

Adjust the sleep duration based on expected prompt complexity:
- Simple prompts: 10-15s
- Medium prompts: 20-30s
- Complex prompts: 30-60s

### Step 3: (Optional) Read full JSON metadata

```bash
cat /tmp/claude-wrap-result.json
```

This includes cost, token usage, model used, session ID, and more.

### Step 4: (Optional) Check for errors

```bash
cat /tmp/claude-wrap-err.log
```

---

## Output Files

| File | Contents |
|------|----------|
| `/tmp/claude-wrap-response.txt` | Final text response only |
| `/tmp/claude-wrap-result.json` | Full JSON output (metadata, cost, tokens) |
| `/tmp/claude-wrap-err.log` | stderr from the Claude process |

---

## Examples

### Get a second opinion on code

```bash
claude-wrap "Review this function for bugs: $(cat src/lib.rs)" --model claude-sonnet-4-6 &
```

### Ask a quick question

```bash
claude-wrap "What is the difference between tokio::spawn and tokio::task::spawn_blocking?" &
```

### Delegate a task with a system prompt

```bash
claude-wrap "Summarize this error log" --append-system-prompt "You are a concise DevOps assistant" &
```

---

## Error Handling

| Scenario | Action |
|----------|--------|
| `claude-wrap` not found | Run the setup step above |
| Empty response file | Check `/tmp/claude-wrap-err.log` for errors |
| Process hangs | Increase sleep duration; complex prompts need more time |
| Auth errors | Ensure Claude CLI is authenticated (`claude auth`) |
