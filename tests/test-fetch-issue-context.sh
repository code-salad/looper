#!/usr/bin/env bash
set -euo pipefail

# test-fetch-issue-context.sh — Corner-case tests for fetch-issue-context script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_ISSUE="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/fetch-issue-context"
CHECK_BLOCKED_REAL="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/check-blocked"

PASS=0
FAIL=0
TMPDIR_TEST=""

cleanup() {
    if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
        rm -rf "$TMPDIR_TEST"
    fi
}
trap cleanup EXIT

assert_exit_zero() {
    local description="$1"
    local exit_code="$2"
    if [ "$exit_code" -eq 0 ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected exit 0, got $exit_code)"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_one() {
    local description="$1"
    local exit_code="$2"
    if [ "$exit_code" -eq 1 ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected exit 1, got $exit_code)"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_nonzero() {
    local description="$1"
    local exit_code="$2"
    if [ "$exit_code" -ne 0 ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected non-zero exit, got 0)"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_contains() {
    local description="$1"
    local output="$2"
    local expected="$3"
    if echo "$output" | grep -qi "$expected"; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected output to contain '$expected')"
        echo "  Actual output: $output"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_empty() {
    local description="$1"
    local output="$2"
    if [ -z "$output" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected empty output, got: $output)"
        FAIL=$((FAIL + 1))
    fi
}

make_test_env() {
    local mock_dir="$1"

    # Mock gh: handles issue view calls
    cat > "$mock_dir/gh" << 'GHEOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    issue_num="$3"
    shift 3
    # full json fetch
    if echo "$*" | grep -q "\-\-json"; then
        echo "{\"number\":$issue_num,\"title\":\"Test Issue $issue_num\",\"body\":\"Issue body for #$issue_num\",\"labels\":[]}"
        exit 0
    fi
    # template fetch for formatting
    if echo "$*" | grep -q "\-\-template"; then
        echo "## Issue #$issue_num: Test Issue $issue_num"
        echo ""
        echo "### Description"
        echo "Issue body for #$issue_num"
        exit 0
    fi
fi
exit 1
GHEOF
    chmod +x "$mock_dir/gh"

    # Mock check-blocked: default to not blocked (exit 0)
    cat > "$mock_dir/check-blocked" << 'CBEOF'
#!/usr/bin/env bash
# Default mock: issue is not blocked
exit 0
CBEOF
    chmod +x "$mock_dir/check-blocked"
}

make_blocked_env() {
    local mock_dir="$1"
    make_test_env "$mock_dir"

    # Override check-blocked to signal blocked
    cat > "$mock_dir/check-blocked" << 'CBEOF'
#!/usr/bin/env bash
# Mock: issue is blocked
echo "Issue is blocked by open dependencies." >&2
exit 1
CBEOF
    chmod +x "$mock_dir/check-blocked"
}

make_failing_gh_env() {
    local mock_dir="$1"

    cat > "$mock_dir/gh" << 'GHEOF'
#!/usr/bin/env bash
# Mock gh that always fails
exit 2
GHEOF
    chmod +x "$mock_dir/gh"

    cat > "$mock_dir/check-blocked" << 'CBEOF'
#!/usr/bin/env bash
exit 0
CBEOF
    chmod +x "$mock_dir/check-blocked"
}

# --- Test 1: Args containing "#123" -> extracts issue 123, outputs formatted body ---
echo "=== Test 1: Args with '#123' hash reference ==="
TMPDIR_TEST=$(mktemp -d)
make_test_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#123 do something" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "hash ref: exit 0" "$EXIT_CODE"
FIRST_LINE=$(echo "$OUTPUT" | head -1)
REST=$(echo "$OUTPUT" | tail -n +2)
if echo "$FIRST_LINE" | grep -q "NUMBER=123"; then
    echo "PASS: hash ref: first line is NUMBER=123"
    PASS=$((PASS + 1))
else
    echo "FAIL: hash ref: expected first line NUMBER=123, got: $FIRST_LINE"
    FAIL=$((FAIL + 1))
fi
assert_output_contains "hash ref: body contains issue content" "$REST" "Issue"
cleanup

# --- Test 2: GitHub URL -> extracts number and repo ---
echo "=== Test 2: GitHub URL reference ==="
TMPDIR_TEST=$(mktemp -d)
make_test_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "https://github.com/foo/bar/issues/42" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "github url: exit 0" "$EXIT_CODE"
FIRST_LINE=$(echo "$OUTPUT" | head -1)
if echo "$FIRST_LINE" | grep -q "NUMBER=42"; then
    echo "PASS: github url: first line is NUMBER=42"
    PASS=$((PASS + 1))
else
    echo "FAIL: github url: expected first line NUMBER=42, got: $FIRST_LINE"
    FAIL=$((FAIL + 1))
fi
cleanup

# --- Test 3: Plain number at start "42 fix bug" -> extracts issue 42 ---
echo "=== Test 3: Plain number at start ==="
TMPDIR_TEST=$(mktemp -d)
make_test_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "42 fix the navbar bug" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "plain number: exit 0" "$EXIT_CODE"
FIRST_LINE=$(echo "$OUTPUT" | head -1)
if echo "$FIRST_LINE" | grep -q "NUMBER=42"; then
    echo "PASS: plain number: first line is NUMBER=42"
    PASS=$((PASS + 1))
else
    echo "FAIL: plain number: expected first line NUMBER=42, got: $FIRST_LINE"
    FAIL=$((FAIL + 1))
fi
cleanup

# --- Test 4: Args with no issue reference -> empty output, exit 0 ---
echo "=== Test 4: No issue reference in args ==="
TMPDIR_TEST=$(mktemp -d)
make_test_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "fix the navbar" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "no ref: exit 0" "$EXIT_CODE"
assert_output_empty "no ref: empty output" "$OUTPUT"
cleanup

# --- Test 5: gh issue view fails -> empty output, exit 0 ---
echo "=== Test 5: gh fails -> graceful degradation ==="
TMPDIR_TEST=$(mktemp -d)
make_failing_gh_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#99" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "gh fails: exit 0" "$EXIT_CODE"
assert_output_empty "gh fails: empty output" "$OUTPUT"
cleanup

# --- Test 6: Issue is blocked -> exit 1 ---
echo "=== Test 6: Issue is blocked -> exit 1 ==="
TMPDIR_TEST=$(mktemp -d)
make_blocked_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "#50" 2>/tmp/fetch_stderr_test6) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_one "blocked issue: exit 1" "$EXIT_CODE"
STDERR_OUT=$(cat /tmp/fetch_stderr_test6 2>/dev/null || echo "")
if echo "$STDERR_OUT" | grep -qi "blocked\|dependencies\|open"; then
    echo "PASS: blocked issue: stderr contains blocking reason"
    PASS=$((PASS + 1))
else
    echo "FAIL: blocked issue: expected blocking reason in stderr, got: $STDERR_OUT"
    FAIL=$((FAIL + 1))
fi
cleanup

# --- Test 7: Missing --args flag -> exit nonzero with usage message ---
echo "=== Test 7: Missing --args flag ==="
TMPDIR_TEST=$(mktemp -d)
make_test_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" "$FETCH_ISSUE" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_nonzero "missing --args: non-zero exit" "$EXIT_CODE"
assert_output_contains "missing --args: usage message" "$OUTPUT" "usage\|--args\|required"
cleanup

# --- Test 8: Malformed GitHub URL (no /issues/ path) -> treated as no issue ref ---
echo "=== Test 8: Malformed GitHub URL ==="
TMPDIR_TEST=$(mktemp -d)
make_test_env "$TMPDIR_TEST"
OUTPUT=$(PATH="$TMPDIR_TEST:$PATH" \
    CHECK_BLOCKED_PATH="$TMPDIR_TEST/check-blocked" \
    "$FETCH_ISSUE" --args "https://github.com/foo/bar/pulls/42" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "malformed url: exit 0" "$EXIT_CODE"
assert_output_empty "malformed url: empty output" "$OUTPUT"
cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
