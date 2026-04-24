#!/usr/bin/env bash
set -euo pipefail

# test-spawn-agent-canonical.sh — Corner-case tests for the rewritten spawn-agent script.
# Uses PATH shims so no real Anthropic API calls are made.
# All 7 corner cases from plan issue #104.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPAWN_AGENT="$REPO_ROOT/plugins/looper/skills/subagents/scripts/spawn-agent"

PASS=0
FAIL=0
SHIMDIR=""

cleanup() {
    if [ -n "$SHIMDIR" ] && [ -d "$SHIMDIR" ]; then
        rm -rf "$SHIMDIR"
    fi
}
trap cleanup EXIT

assert_eq() {
    local description="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $description"; PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local description="$1" actual="$2" pattern="$3"
    if echo "$actual" | grep -qF -- "$pattern"; then
        echo "PASS: $description"; PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected '$pattern' in output, got: $actual)"; FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local description="$1" actual="$2" pattern="$3"
    if echo "$actual" | grep -qF -- "$pattern"; then
        echo "FAIL: $description (pattern '$pattern' found in output but should not be)"; FAIL=$((FAIL + 1))
    else
        echo "PASS: $description"; PASS=$((PASS + 1))
    fi
}

assert_exit_code() {
    local description="$1" actual_code="$2" expected_code="$3"
    if [ "$actual_code" -eq "$expected_code" ]; then
        echo "PASS: $description"; PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected exit $expected_code, got $actual_code)"; FAIL=$((FAIL + 1))
    fi
}

# Create a fresh shim dir for each test group
make_shimdir() {
    SHIMDIR="$(mktemp -d -t spawn-agent-test-XXXXXX)"
}

# ── Case 1: Sync mode prints response body on stdout (not a tempfile path) ─────

echo "=== Case 1: sync mode prints .result directly to stdout ==="
make_shimdir
cat > "$SHIMDIR/claude" << 'EOF'
#!/usr/bin/env bash
# Shim: write JSON result to stdout when invoked with -p --agent ... --output-format json
printf '{"result":"hello from shim","is_error":false}'
exit 0
EOF
chmod +x "$SHIMDIR/claude"

actual_stdout=$(PATH="$SHIMDIR:$PATH" bash "$SPAWN_AGENT" "Explore" "say hi" 2>/dev/null || true)
assert_contains "sync mode: stdout contains response text" "$actual_stdout" "hello from shim"
assert_not_contains "sync mode: stdout does not contain /tmp/ path" "$actual_stdout" "/tmp/"

# ── Case 2: Exit code propagates from claude ────────────────────────────────────

echo ""
echo "=== Case 2: exit code propagates from claude ==="
make_shimdir
cat > "$SHIMDIR/claude" << 'EOF'
#!/usr/bin/env bash
# Shim: exits 17 and writes nothing
exit 17
EOF
chmod +x "$SHIMDIR/claude"

actual_stderr_c2=$(PATH="$SHIMDIR:$PATH" bash "$SPAWN_AGENT" "Explore" "fail" 2>&1 >/dev/null || true)
actual_exit_c2=0
PATH="$SHIMDIR:$PATH" bash "$SPAWN_AGENT" "Explore" "fail" >/dev/null 2>/dev/null || actual_exit_c2=$?

assert_exit_code "exit code propagation: exits with 17" "$actual_exit_c2" 17
assert_contains "exit code propagation: stderr mentions no output" "$actual_stderr_c2" "no output"

# ── Case 3: --async is rejected ──────────────────────────────────────────────────

echo ""
echo "=== Case 3: --async is rejected (exit 2, stderr message) ==="
actual_stderr_c3=$(bash "$SPAWN_AGENT" --async "Explore" "anything" 2>&1 >/dev/null || true)
actual_exit_c3=0
bash "$SPAWN_AGENT" --async "Explore" "anything" >/dev/null 2>/dev/null || actual_exit_c3=$?

assert_exit_code "--async rejected: exit code is 2" "$actual_exit_c3" 2
assert_contains "--async rejected: stderr mentions 'no longer supported'" \
    "$actual_stderr_c3" "no longer supported"

# ── Case 4: Script passes ShellCheck ────────────────────────────────────────────

echo ""
echo "=== Case 4: spawn-agent passes ShellCheck ==="
if command -v shellcheck >/dev/null 2>&1; then
    sc_exit=0
    shellcheck "$SPAWN_AGENT" 2>/dev/null || sc_exit=$?
    assert_exit_code "ShellCheck: spawn-agent is clean" "$sc_exit" 0
else
    echo "SKIP: shellcheck not found on PATH"
fi

# ── Case 5: Missing-argument usage string does not mention --async ───────────────

echo ""
echo "=== Case 5: missing args yields Usage: without --async ==="
usage_stderr=$(bash "$SPAWN_AGENT" 2>&1 >/dev/null || true)
assert_contains "missing args: stderr contains 'Usage:'" "$usage_stderr" "Usage:"
assert_not_contains "missing args: stderr does not mention '--async'" "$usage_stderr" "--async"

# ── Case 6: Empty .result field from claude ──────────────────────────────────────

echo ""
echo "=== Case 6: empty .result field — script exits 0 and stdout is empty ==="
make_shimdir
cat > "$SHIMDIR/claude" << 'EOF'
#!/usr/bin/env bash
printf '{"result":"","is_error":false}'
exit 0
EOF
chmod +x "$SHIMDIR/claude"

empty_stdout=$(PATH="$SHIMDIR:$PATH" bash "$SPAWN_AGENT" "Explore" "empty" 2>/dev/null || true)
empty_exit=0
PATH="$SHIMDIR:$PATH" bash "$SPAWN_AGENT" "Explore" "empty" >/dev/null 2>/dev/null || empty_exit=$?

assert_exit_code "empty .result: exits 0" "$empty_exit" 0
assert_eq "empty .result: stdout is empty" "$empty_stdout" ""

# ── Case 7 (corner case 2): Non-JSON stdout from claude ─────────────────────────

echo ""
echo "=== Case 7: non-JSON stdout from claude falls through to cat ==="
make_shimdir
cat > "$SHIMDIR/claude" << 'EOF'
#!/usr/bin/env bash
printf 'not json'
exit 1
EOF
chmod +x "$SHIMDIR/claude"

nonjson_stdout=$(PATH="$SHIMDIR:$PATH" bash "$SPAWN_AGENT" "Explore" "nonjson" 2>/dev/null || true)
nonjson_exit=0
PATH="$SHIMDIR:$PATH" bash "$SPAWN_AGENT" "Explore" "nonjson" >/dev/null 2>/dev/null || nonjson_exit=$?

assert_contains "non-JSON: raw content appears on stdout" "$nonjson_stdout" "not json"
assert_exit_code "non-JSON: exit code propagates (1)" "$nonjson_exit" 1

# ── Case (corner 5): Agent name with colon (looper:checker) ─────────────────────

echo ""
echo "=== Case 8: agent name with colon forwarded correctly ==="
make_shimdir
cat > "$SHIMDIR/claude" << 'EOF'
#!/usr/bin/env bash
# Record argv and echo it back as the result
printf '{"result":"%s","is_error":false}' "$*"
exit 0
EOF
chmod +x "$SHIMDIR/claude"

colon_stdout=$(PATH="$SHIMDIR:$PATH" bash "$SPAWN_AGENT" "looper:checker" "my prompt" 2>/dev/null || true)
assert_contains "colon in agent name: stdout contains looper:checker" "$colon_stdout" "looper:checker"

# ── Case (corner 7): Extra flags forwarded via "$@" ─────────────────────────────

echo ""
echo "=== Case 9: extra flags forwarded after <prompt> ==="
make_shimdir
cat > "$SHIMDIR/claude" << 'EOF'
#!/usr/bin/env bash
printf '{"result":"%s","is_error":false}' "$*"
exit 0
EOF
chmod +x "$SHIMDIR/claude"

extra_stdout=$(PATH="$SHIMDIR:$PATH" bash "$SPAWN_AGENT" "Explore" "do stuff" --max-turns 3 2>/dev/null || true)
assert_contains "extra flags: --max-turns appears in forwarded argv" "$extra_stdout" "--max-turns"

# ────────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
