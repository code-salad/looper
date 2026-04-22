#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Error: 'docker' is not installed (LOOPER_SANDBOX_BACKEND=docker).
Install docker from https://docs.docker.com/engine/install/
and ensure your user has access to /var/run/docker.sock.
EOF
    exit 127
fi

trap 'docker kill "$LOOPER_SANDBOX_NAME" >/dev/null 2>&1 || true' INT TERM

RUN_EXIT=0
docker run --rm --name "$LOOPER_SANDBOX_NAME" \
    -v "$(pwd)":/repo \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -w /repo \
    -e ANTHROPIC_API_KEY \
    -e GITHUB_TOKEN \
    -e LOOPER_SANDBOX_BACKEND=docker \
    "$LOOPER_SANDBOX_IMAGE" \
    claude -p "/looper:loop $LOOPER_SANDBOX_TASK" \
      --allowed-tools Bash,Read,Write,Edit,Grep,Glob,Agent,Skill \
    || RUN_EXIT=$?
exit "$RUN_EXIT"
