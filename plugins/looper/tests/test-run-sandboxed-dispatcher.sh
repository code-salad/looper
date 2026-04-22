#!/usr/bin/env bash
set -euo pipefail

# test-run-sandboxed-dispatcher.sh — Smoke-test the run-sandboxed dispatcher contract.
# Does NOT test real docker or sbx runtimes; uses a claude shim for the null backend.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/skills/looper/scripts"
BACKENDS_DIR="$SCRIPTS_DIR/backends"
DISPATCHER="$SCRIPTS_DIR/run-sandboxed"

PASS=0
FAIL=0

check() {
    local label="$1"
    local result="$2"

    if [ "$result" = "true" ]; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label"
        FAIL=$((FAIL + 1))
    fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Write a claude shim that logs its environment and args, then exits 0.
cat > "$TMPDIR/claude" << 'SHIM'
#!/usr/bin/env bash
LOG="${TMPDIR:-/tmp}/claude.log"
{
    echo "ARGS=$*"
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
    echo "LOOPER_SANDBOX_TASK=${LOOPER_SANDBOX_TASK:-}"
    echo "LOOPER_SANDBOX_BACKEND=${LOOPER_SANDBOX_BACKEND:-}"
    echo "LOOPER_SANDBOX_NAME=${LOOPER_SANDBOX_NAME:-}"
} >> "$LOG"
exit 0
SHIM
chmod +x "$TMPDIR/claude"

# Write a gh shim that suppresses auth-status side-effects.
cat > "$TMPDIR/gh" << 'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod +x "$TMPDIR/gh"

# --- Case 1: No args -> exit 2, stderr contains "Usage:" ---

stderr_out=$("$DISPATCHER" 2>&1 >/dev/null || true)
exit_code=$(ANTHROPIC_API_KEY=k "$DISPATCHER" 2>&1 >/dev/null; echo $?) || true
# Use a subshell to capture exit code properly
set +e
output=$(ANTHROPIC_API_KEY=k "$DISPATCHER" 2>&1); code=$?
set -e
check "no args: exit code is 2" "$([ "$code" -eq 2 ] && echo true || echo false)"
check "no args: stderr contains Usage:" "$(echo "$output" | grep -q 'Usage:' && echo true || echo false)"

# --- Case 2: ANTHROPIC_API_KEY unset, LOOPER_SANDBOX_BACKEND=null, task provided -> exit 3 ---

set +e
output=$(PATH="$TMPDIR:$PATH" LOOPER_SANDBOX_BACKEND=null unset_ANTHROPIC_API_KEY=1 \
    env -u ANTHROPIC_API_KEY "$DISPATCHER" "some task" 2>&1); code=$?
set -e
check "no ANTHROPIC_API_KEY: exit code is 3" "$([ "$code" -eq 3 ] && echo true || echo false)"

# --- Case 3: Unknown backend -> exit 4, stderr lists docker, sbx, null ---

set +e
output=$(ANTHROPIC_API_KEY=k LOOPER_SANDBOX_BACKEND=frobnicate \
    PATH="$TMPDIR:$PATH" "$DISPATCHER" "some task" 2>&1); code=$?
set -e
check "unknown backend: exit code is 4" "$([ "$code" -eq 4 ] && echo true || echo false)"
check "unknown backend: stderr lists docker" "$(echo "$output" | grep -q 'docker' && echo true || echo false)"
check "unknown backend: stderr lists sbx" "$(echo "$output" | grep -q 'sbx' && echo true || echo false)"
check "unknown backend: stderr lists null" "$(echo "$output" | grep -q 'null' && echo true || echo false)"

# --- Case 4: null backend with claude shim, task "add logging" -> exit 0, claude.log correct ---

rm -f "$TMPDIR/claude.log"
set +e
TMPDIR="$TMPDIR" PATH="$TMPDIR:$PATH" ANTHROPIC_API_KEY=k LOOPER_SANDBOX_BACKEND=null \
    "$DISPATCHER" "add logging" >/dev/null 2>&1; code=$?
set -e
check "null backend shim: exit code is 0" "$([ "$code" -eq 0 ] && echo true || echo false)"
check "null backend shim: claude.log has /looper:loop add logging" \
    "$(grep -q '/looper:loop add logging' "$TMPDIR/claude.log" && echo true || echo false)"
check "null backend shim: claude.log has ANTHROPIC_API_KEY=k" \
    "$(grep -q 'ANTHROPIC_API_KEY=k' "$TMPDIR/claude.log" && echo true || echo false)"
check "null backend shim: claude.log has LOOPER_SANDBOX_BACKEND=null" \
    "$(grep -q 'LOOPER_SANDBOX_BACKEND=null' "$TMPDIR/claude.log" && echo true || echo false)"
check "null backend shim: LOOPER_SANDBOX_NAME starts with loop-" \
    "$(grep 'LOOPER_SANDBOX_NAME=' "$TMPDIR/claude.log" | grep -q 'LOOPER_SANDBOX_NAME=loop-' && echo true || echo false)"

# --- Case 5: Multi-word task "add logging and tracing" -> claude.log preserves full string ---

rm -f "$TMPDIR/claude.log"
set +e
TMPDIR="$TMPDIR" PATH="$TMPDIR:$PATH" ANTHROPIC_API_KEY=k LOOPER_SANDBOX_BACKEND=null \
    "$DISPATCHER" "add logging and tracing" >/dev/null 2>&1; code=$?
set -e
check "multi-word task: claude.log contains full string" \
    "$(grep -q '/looper:loop add logging and tracing' "$TMPDIR/claude.log" && echo true || echo false)"

# --- Case 6: Default backend (docker) with no docker on PATH -> exit 127 ---

CLEAN_PATH="$TMPDIR"
set +e
output=$(ANTHROPIC_API_KEY=k PATH="$CLEAN_PATH" \
    env -u LOOPER_SANDBOX_BACKEND "$DISPATCHER" "some task" 2>&1); code=$?
set -e
check "default docker, no docker on PATH: exit code is 127" "$([ "$code" -eq 127 ] && echo true || echo false)"
check "default docker, no docker on PATH: stderr mentions docker" \
    "$(echo "$output" | grep -q 'docker' && echo true || echo false)"

# --- Case 7: Grep-based extraction-fidelity assertions ---

# docker.sh must use contract variable names, not old bare names
check "docker.sh uses LOOPER_SANDBOX_TASK" \
    "$(grep -q 'LOOPER_SANDBOX_TASK' "$BACKENDS_DIR/docker.sh" && echo true || echo false)"
check "docker.sh does not use bare \$TASK (unquoted)" \
    "$(! grep -qE '"\$TASK"' "$BACKENDS_DIR/docker.sh" && echo true || echo false)"
check "docker.sh uses LOOPER_SANDBOX_NAME" \
    "$(grep -q 'LOOPER_SANDBOX_NAME' "$BACKENDS_DIR/docker.sh" && echo true || echo false)"
check "docker.sh does not use bare \$SANDBOX_NAME" \
    "$(! grep -q '\$SANDBOX_NAME' "$BACKENDS_DIR/docker.sh" && echo true || echo false)"
check "docker.sh uses LOOPER_SANDBOX_IMAGE" \
    "$(grep -q 'LOOPER_SANDBOX_IMAGE' "$BACKENDS_DIR/docker.sh" && echo true || echo false)"
check "docker.sh does not use bare \$IMAGE" \
    "$(! grep -qE '"\$IMAGE"' "$BACKENDS_DIR/docker.sh" && echo true || echo false)"
check "docker.sh retains socket mount" \
    "$(grep -q '/var/run/docker.sock:/var/run/docker.sock' "$BACKENDS_DIR/docker.sh" && echo true || echo false)"
check "docker.sh retains --allowed-tools" \
    "$(grep -q '\-\-allowed-tools' "$BACKENDS_DIR/docker.sh" && echo true || echo false)"
check "docker.sh does NOT contain dropped GH_TOKEN export" \
    "$(! grep -q 'export GITHUB_TOKEN=.*GH_TOKEN' "$BACKENDS_DIR/docker.sh" && echo true || echo false)"

check "sbx.sh uses LOOPER_SANDBOX_POLICY" \
    "$(grep -q 'LOOPER_SANDBOX_POLICY' "$BACKENDS_DIR/sbx.sh" && echo true || echo false)"
check "sbx.sh does not use bare \$POLICY" \
    "$(! grep -qE '"\$POLICY"' "$BACKENDS_DIR/sbx.sh" && echo true || echo false)"
check "sbx.sh retains --branch" \
    "$(grep -q '\-\-branch' "$BACKENDS_DIR/sbx.sh" && echo true || echo false)"
check "sbx.sh retains sbx secret set ANTHROPIC_API_KEY" \
    "$(grep -q 'sbx secret set ANTHROPIC_API_KEY' "$BACKENDS_DIR/sbx.sh" && echo true || echo false)"
check "sbx.sh retains push-on-success path .sbx/\$LOOPER_SANDBOX_NAME" \
    "$(grep -q '\.sbx/\$LOOPER_SANDBOX_NAME' "$BACKENDS_DIR/sbx.sh" && echo true || echo false)"

# --- Case 8: backends/README.md exists and contains "How to add a backend" ---

check "backends/README.md exists" \
    "$([ -f "$BACKENDS_DIR/README.md" ] && echo true || echo false)"
check "backends/README.md contains 'How to add a backend'" \
    "$(grep -qi 'how to add a backend' "$BACKENDS_DIR/README.md" && echo true || echo false)"

# --- Summary ---

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
