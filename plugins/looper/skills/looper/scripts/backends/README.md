# Sandbox Backend Adapters

This directory contains pluggable backend scripts for `run-sandboxed`. Each
file `<name>.sh` is a self-contained adapter that the dispatcher selects via
`LOOPER_SANDBOX_BACKEND=<name>`.

## Backend contract

### Environment variables (guaranteed set by the dispatcher before `exec`)

| Variable | Description |
|---|---|
| `LOOPER_SANDBOX_TASK` | Full task string from `$*`, spaces preserved |
| `LOOPER_SANDBOX_NAME` | Unique per invocation: `loop-$(date +%s)-$$` |
| `LOOPER_SANDBOX_BACKEND` | Resolved backend name (always set explicitly) |
| `LOOPER_SANDBOX_IMAGE` | Container image ref (default: `ghcr.io/code-salad/looper-sandbox:latest`) |
| `LOOPER_SANDBOX_POLICY` | Isolation policy (default: `balanced`; used by sbx only) |
| `ANTHROPIC_API_KEY` | Required; already validated by the dispatcher |
| `GITHUB_TOKEN` | May be empty string (warn-only; dispatcher emits the warning) |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Inner command succeeded |
| `127` | Required backend CLI is not installed on PATH |
| `*` | Inner command exit code passed through verbatim |

### Each backend MUST

- Check its required CLI is present; exit 127 with an install hint if not.
- Install a cleanup trap on `INT`/`TERM`/`EXIT` that removes its own resources
  (container, sandbox, worktree) — the trap must be idempotent.
- Stream `stdout`/`stderr` from the inner `claude` invocation through unmodified.
- Exit with the inner command's exit code.

### Each backend MUST NOT

- Read positional arguments — everything arrives via environment variables.
- Touch files outside `$(pwd)` or its own scratch area.
- Print banner or progress output on `stderr` that would clobber the loop's own output.
- Redefine `LOOPER_SANDBOX_*` or `ANTHROPIC_API_KEY` — treat them as read-only.

## Backends shipped in v1

| File | Backend name | Notes |
|---|---|---|
| `docker.sh` | `docker` | Default; DooD via `/var/run/docker.sock` |
| `sbx.sh` | `sbx` | microVM via `sbx` CLI; requires KVM |
| `null.sh` | `null` | Runs `claude -p` directly on the host; reference implementation |

The `null` backend is intentionally not exposed through the
`/looper:looper-sandboxed` skill (which gates on `docker|sbx` in Phase 1).
It is reachable only via direct `run-sandboxed` invocation, making it useful
for CI test harnesses and local development without a container runtime.

## How to add a backend

1. Create `backends/<name>.sh` with `#!/usr/bin/env bash` and `set -euo pipefail`.
2. Read `LOOPER_SANDBOX_TASK`, `LOOPER_SANDBOX_NAME`, and any other contract
   variables you need from the environment — do not accept positional args.
3. Check that your required CLI is on PATH; emit an install hint and exit 127
   if it is not.
4. Install a cleanup trap (EXIT INT TERM) that removes any resources your
   backend creates, keyed on `LOOPER_SANDBOX_NAME` so parallel runs stay
   isolated.
5. Run `claude -p "/looper:loop $LOOPER_SANDBOX_TASK"` (or equivalent) inside
   your isolation environment, forwarding `ANTHROPIC_API_KEY` and
   `GITHUB_TOKEN`.
6. Exit with the inner command's exit code.
7. Make the script executable (`chmod +x`) and run `shellcheck` on it — CI
   enforces both.
8. Add a row to the table above in this README.
