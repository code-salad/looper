#!/usr/bin/env bash
set -euo pipefail

if ! command -v sbx >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Error: `sbx` (Docker Sandboxes) is not installed.

Install it with:
    curl -fsSL https://sbx.sh/install | bash

Or see: https://github.com/docker/sandbox

Then re-run /looper:looper-sandboxed.
EOF
    exit 127
fi

sbx secret set ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY" >/dev/null
if [ -n "${GITHUB_TOKEN:-}" ]; then
    sbx secret set GITHUB_TOKEN "$GITHUB_TOKEN" >/dev/null
fi

cleanup() {
    local exit_code=$?
    if sbx ls 2>/dev/null | grep -q "^${LOOPER_SANDBOX_NAME}"; then
        sbx rm "$LOOPER_SANDBOX_NAME" >/dev/null 2>&1 || true
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

RUN_EXIT=0
sbx run "$LOOPER_SANDBOX_NAME" \
    --image "$LOOPER_SANDBOX_IMAGE" \
    --branch \
    --policy "$LOOPER_SANDBOX_POLICY" \
    -- claude -p "/looper:loop $LOOPER_SANDBOX_TASK" \
       --allowed-tools Bash,Read,Write,Edit,Grep,Glob,Agent,Skill \
    || RUN_EXIT=$?

if [ "$RUN_EXIT" -ne 0 ]; then
    echo "Error: inner claude -p exited with status $RUN_EXIT. Sandbox will be removed; branch is preserved under .sbx/${LOOPER_SANDBOX_NAME}/ for inspection." >&2
    exit "$RUN_EXIT"
fi

SBX_WORKTREE=".sbx/$LOOPER_SANDBOX_NAME"
if [ -d "$SBX_WORKTREE/.git" ] || [ -f "$SBX_WORKTREE/.git" ]; then
    (
        cd "$SBX_WORKTREE"
        git push origin HEAD
    )
else
    echo "Warning: expected worktree at $SBX_WORKTREE but none found. Skipping push." >&2
fi
