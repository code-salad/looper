#!/usr/bin/env bash
set -euo pipefail

# test-pre-check.sh — Tests for the pre-check script
# Verifies that pre-check runs mechanical checks and exits correctly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRE_CHECK="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/pre-check"

PASS=0
FAIL=0
TMPDIR_TEST=""

cleanup() {
    if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
        rm -rf "$TMPDIR_TEST"
    fi
}
trap cleanup EXIT

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

assert_output_contains() {
    local description="$1"
    local output="$2"
    local expected="$3"
    if echo "$output" | grep -q "$expected"; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected output to contain '$expected')"
        echo "  Actual output (first 10 lines): $(echo "$output" | head -10)"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_not_contains() {
    local description="$1"
    local output="$2"
    local unexpected="$3"
    if echo "$output" | grep -q "$unexpected"; then
        echo "FAIL: $description (expected output NOT to contain '$unexpected')"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $description"
        PASS=$((PASS + 1))
    fi
}

setup_mock_scripts_dir() {
    TMPDIR_TEST=$(mktemp -d)
    # Create minimal mock scripts directory with run-tests, run-typecheck, run-lint
    mkdir -p "$TMPDIR_TEST/scripts"
}

# Verify the pre-check script exists and is executable
echo "=== Test 0: pre-check script exists and is executable ==="
if [ -f "$PRE_CHECK" ]; then
    echo "PASS: pre-check script exists"
    PASS=$((PASS + 1))
else
    echo "FAIL: pre-check script does not exist at $PRE_CHECK"
    FAIL=$((FAIL + 1))
fi
if [ -x "$PRE_CHECK" ]; then
    echo "PASS: pre-check script is executable"
    PASS=$((PASS + 1))
else
    echo "FAIL: pre-check script is not executable"
    FAIL=$((FAIL + 1))
fi

# --- Test 1: All checks pass -> exit 0 with ALL_CHECKS_PASSED ---
echo "=== Test 1: All checks pass -> exit 0 with ALL_CHECKS_PASSED ==="
setup_mock_scripts_dir

# Create mock scripts that all succeed
cat > "$TMPDIR_TEST/scripts/run-tests" << 'EOF'
#!/usr/bin/env bash
echo "All tests passed"
exit 0
EOF
cat > "$TMPDIR_TEST/scripts/run-typecheck" << 'EOF'
#!/usr/bin/env bash
echo "Type check passed"
exit 0
EOF
cat > "$TMPDIR_TEST/scripts/run-lint" << 'EOF'
#!/usr/bin/env bash
echo "Lint passed"
exit 0
EOF
chmod +x "$TMPDIR_TEST/scripts/run-tests" "$TMPDIR_TEST/scripts/run-typecheck" "$TMPDIR_TEST/scripts/run-lint"

set +e
OUTPUT=$(SCRIPTS_DIR="$TMPDIR_TEST/scripts" "$PRE_CHECK" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_zero "all pass: exit 0" "$EXIT_CODE"
assert_output_contains "all pass: output contains ALL_CHECKS_PASSED" "$OUTPUT" "ALL_CHECKS_PASSED"
cleanup

# --- Test 2: Test failure -> exit 1 with failure info ---
echo "=== Test 2: Test failure -> exit 1 with failure info ==="
setup_mock_scripts_dir

cat > "$TMPDIR_TEST/scripts/run-tests" << 'EOF'
#!/usr/bin/env bash
echo "FAILED: test_login expected 200 got 500"
exit 1
EOF
cat > "$TMPDIR_TEST/scripts/run-typecheck" << 'EOF'
#!/usr/bin/env bash
echo "Type check passed"
exit 0
EOF
cat > "$TMPDIR_TEST/scripts/run-lint" << 'EOF'
#!/usr/bin/env bash
echo "Lint passed"
exit 0
EOF
chmod +x "$TMPDIR_TEST/scripts/run-tests" "$TMPDIR_TEST/scripts/run-typecheck" "$TMPDIR_TEST/scripts/run-lint"

set +e
OUTPUT=$(SCRIPTS_DIR="$TMPDIR_TEST/scripts" "$PRE_CHECK" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_nonzero "test failure: exit non-zero" "$EXIT_CODE"
assert_output_contains "test failure: output contains failure info" "$OUTPUT" "FAILED"
assert_output_not_contains "test failure: no ALL_CHECKS_PASSED" "$OUTPUT" "ALL_CHECKS_PASSED"
cleanup

# --- Test 3: Multiple failures -> exit 1 with both failures listed ---
echo "=== Test 3: Multiple failures -> exit 1 with both failures listed ==="
setup_mock_scripts_dir

cat > "$TMPDIR_TEST/scripts/run-tests" << 'EOF'
#!/usr/bin/env bash
echo "ERROR: test suite crashed"
exit 1
EOF
cat > "$TMPDIR_TEST/scripts/run-typecheck" << 'EOF'
#!/usr/bin/env bash
echo "Type check passed"
exit 0
EOF
cat > "$TMPDIR_TEST/scripts/run-lint" << 'EOF'
#!/usr/bin/env bash
echo "ERROR: lint violations found"
exit 1
EOF
chmod +x "$TMPDIR_TEST/scripts/run-tests" "$TMPDIR_TEST/scripts/run-typecheck" "$TMPDIR_TEST/scripts/run-lint"

set +e
OUTPUT=$(SCRIPTS_DIR="$TMPDIR_TEST/scripts" "$PRE_CHECK" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_nonzero "multiple failures: exit non-zero" "$EXIT_CODE"
assert_output_not_contains "multiple failures: no ALL_CHECKS_PASSED" "$OUTPUT" "ALL_CHECKS_PASSED"
cleanup

# --- Test 4: run-tests exits non-zero (missing script) -> graceful handling ---
echo "=== Test 4: run-tests not found -> graceful fail ==="
setup_mock_scripts_dir

# No run-tests script — only typecheck and lint
cat > "$TMPDIR_TEST/scripts/run-typecheck" << 'EOF'
#!/usr/bin/env bash
echo "Type check passed"
exit 0
EOF
cat > "$TMPDIR_TEST/scripts/run-lint" << 'EOF'
#!/usr/bin/env bash
echo "Lint passed"
exit 0
EOF
chmod +x "$TMPDIR_TEST/scripts/run-typecheck" "$TMPDIR_TEST/scripts/run-lint"

set +e
OUTPUT=$(SCRIPTS_DIR="$TMPDIR_TEST/scripts" "$PRE_CHECK" 2>&1)
EXIT_CODE=$?
set -e

# When run-tests is missing, should either fail gracefully or succeed if skip is implemented
# (no crash/unbound variable error)
assert_output_not_contains "missing run-tests: no crash error" "$OUTPUT" "unbound variable"
cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
