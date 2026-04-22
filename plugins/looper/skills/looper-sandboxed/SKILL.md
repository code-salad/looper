---
name: looper-sandboxed
description: >-
  Use this skill when the user wants to run the Plan-Do-Check loop inside a
  local Docker sandbox (`sbx`) instead of directly on the host. Injects
  ANTHROPIC_API_KEY and GITHUB_TOKEN via sbx's host-side secret proxy so the
  agent inside the sandbox never sees plaintext credentials. Triggered by
  "/looper:looper-sandboxed <task>".
tools: Bash, Read
---

# Looper Sandboxed Skill

Thin wrapper around the main `looper` skill that runs the entire PDC loop
inside a containerised sandbox. The existing `/looper:loop` flow is unchanged
— users opt in per-invocation by running `/looper:looper-sandboxed` instead.

## Prerequisites

- Docker + `sbx` CLI installed on the host.
- `ANTHROPIC_API_KEY` exported in the current shell.
- `gh` authenticated (preferred) or `GITHUB_TOKEN` exported.

## Phase 0: Validate argument

If `$ARGUMENTS` is empty, print:

> Usage: /looper:looper-sandboxed <task description>

and exit.

## Phase 1: Verify `sbx` is installed

```bash
if ! command -v sbx >/dev/null 2>&1; then
    echo "Error: \`sbx\` is not installed." >&2
    echo "Install with: curl -fsSL https://sbx.sh/install | bash" >&2
    exit 127
fi
```

## Phase 2: Delegate to `run-sandboxed`

```bash
SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/looper}/skills/looper/scripts"
"$SCRIPTS_DIR/run-sandboxed" "$ARGUMENTS"
```

The wrapper script handles secret injection, sandbox lifecycle, and branch
push on success.

## Error Handling

| Scenario | Action |
|----------|--------|
| `sbx` missing | Abort with install hint (exit 127). |
| Empty argument | Print usage and exit. |
| `ANTHROPIC_API_KEY` unset | `run-sandboxed` exits 3 with a clear message. |
| Neither `GITHUB_TOKEN` nor `gh auth` available | Warn and continue (PR creation inside will fail but loop can run). |
| Inner `claude -p` exits non-zero | Wrapper surfaces the exit code; sandbox is removed; `.sbx/<name>/` worktree is preserved for inspection. |

## How this differs from `/looper:loop`

- `/looper:loop` — runs in the user's shell, creates a host worktree under
  `.worktrees/<name>/`, has full host network + env access.
- `/looper:looper-sandboxed` — runs inside a container with `sbx`'s network
  policy and sandboxed filesystem. The inner PDC loop is byte-identical; only
  the execution environment changes.
