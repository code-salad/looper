#!/usr/bin/env bash
set -euo pipefail

if ! command -v claude >/dev/null 2>&1; then
    echo "Error: claude CLI is not installed (LOOPER_SANDBOX_BACKEND=null)." >&2
    echo "Install: https://docs.anthropic.com/en/docs/claude-code" >&2
    exit 127
fi

exec claude -p "/looper:loop $LOOPER_SANDBOX_TASK" \
    --allowed-tools Bash,Read,Write,Edit,Grep,Glob,Agent,Skill
