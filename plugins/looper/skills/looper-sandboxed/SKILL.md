---
name: looper-sandboxed
description: >-
  Use this skill when the user wants to run the Plan-Do-Check loop inside
  an isolated sandbox instead of directly on the host. Defaults to the
  `docker` backend (plain `docker run` with a bind-mounted worktree and a
  bind-mounted /var/run/docker.sock for nested Docker); opt in to the
  `sbx` backend (microVM + host-side secret proxy) via
  `LOOPER_SANDBOX_BACKEND=sbx`. Triggered by
  "/looper:looper-sandboxed <task>".
tools: Bash, Read
---

# Looper Sandboxed Skill

Thin wrapper around the main `looper` skill that runs the entire PDC loop
inside an isolated sandbox. Supports two backends: `docker` (default, DooD via
socket mount) and `sbx` (microVM, opt-in). The existing `/looper:loop` flow is
unchanged — users opt in per-invocation by running `/looper:looper-sandboxed`
instead.

## Prerequisites

- Selected backend installed on the host:
  - `docker` (default) — `docker` CLI + running daemon accessible via
    `/var/run/docker.sock`. Works on Hyper-V, WSL2, and cloud VMs
    without KVM.
  - `sbx` (opt-in) — `sbx` CLI + KVM.
- `ANTHROPIC_API_KEY` exported in the current shell.
- `gh` authenticated (preferred) or `GITHUB_TOKEN` exported.

## Phase 0: Validate argument

If `$ARGUMENTS` is empty, print:

> Usage: /looper:looper-sandboxed <task description>

and exit.

## Phase 1: Verify selected backend

```bash
BACKEND="${LOOPER_SANDBOX_BACKEND:-docker}"
case "$BACKEND" in
  docker)
    if ! command -v docker >/dev/null 2>&1; then
        echo "Error: 'docker' is not installed (LOOPER_SANDBOX_BACKEND=docker)." >&2
        echo "Install: https://docs.docker.com/engine/install/" >&2
        exit 127
    fi
    ;;
  sbx)
    if ! command -v sbx >/dev/null 2>&1; then
        echo "Error: 'sbx' is not installed (LOOPER_SANDBOX_BACKEND=sbx)." >&2
        echo "Install: curl -fsSL https://sbx.sh/install | bash" >&2
        exit 127
    fi
    ;;
  *)
    echo "Error: unknown LOOPER_SANDBOX_BACKEND: '$BACKEND' (expected: docker | sbx)" >&2
    exit 4
    ;;
esac
```

## Phase 2: Delegate to `run-sandboxed`

```bash
SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/looper}/skills/looper/scripts"
"$SCRIPTS_DIR/run-sandboxed" "$ARGUMENTS"
```

The wrapper script handles secret injection, sandbox lifecycle, and (for sbx)
branch push on success.

## Error Handling

| Scenario | Action |
|----------|--------|
| Selected backend binary missing | Abort with install hint (exit 127). |
| Unknown `LOOPER_SANDBOX_BACKEND` | Exit 4 with "expected docker or sbx". |
| Empty argument | Print usage and exit 2. |
| `ANTHROPIC_API_KEY` unset | `run-sandboxed` exits 3. |
| Neither `GITHUB_TOKEN` nor `gh auth` available | Warn and continue. |
| Inner `claude -p` / `docker run` exits non-zero | Wrapper surfaces the exit code. |

## How this differs from `/looper:loop`

- `/looper:loop` — runs in the user's shell, creates a host worktree under
  `.worktrees/<name>/`, has full host network + env access.
- `/looper:looper-sandboxed` — runs inside a container. The inner PDC loop is
  byte-identical; only the execution environment changes.

**Backend-specific differences:**
- `docker` backend — bind-mount (no separate push needed); compose services
  spawn as siblings on the host daemon via DooD socket mount.
- `sbx` backend — `--branch` + `.sbx/<name>/` worktree; push required on
  success; per-sandbox daemon (no socket mount, no host-exposure tradeoff).
