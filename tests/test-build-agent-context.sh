#!/usr/bin/env bash
set -euo pipefail

# test-build-agent-context.sh — Tests for build-agent-context script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CTX="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/build-agent-context"

PASS=0
FAIL=0
TMPDIR_TEST=""

cleanup() {
    if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
        rm -rf "$TMPDIR_TEST"
    fi
}
trap cleanup EXIT

assert_output_contains() {
    local description="$1"
    local output="$2"
    local expected="$3"
    if echo "$output" | grep -q "$expected"; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected output to contain '$expected')"
        echo "  Actual output snippet (first 5 lines): $(echo "$output" | head -5)"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_not_contains() {
    local description="$1"
    local output="$2"
    local unexpected="$3"
    if ! echo "$output" | grep -q "$unexpected"; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected output NOT to contain '$unexpected')"
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

setup_fixture_dir() {
    TMPDIR_TEST=$(mktemp -d)

    # Create fixture CONTRIBUTING.md with known sections
    cat > "$TMPDIR_TEST/CONTRIBUTING.md" << 'EOF'
# Contributing Guide

## Getting Started

Clone the repo and run npm install.

## Code Style

Follow existing code patterns. Use 2-space indentation.
Scripts must pass ShellCheck.

## Testing and CI

Run tests with `npm test`. CI runs on GitHub Actions.
All tests must pass before merging.

## Deployment

Deploy via GitHub Actions on merge to main.
EOF

    # Create fixture README.md
    cat > "$TMPDIR_TEST/README.md" << 'EOF'
# My Project

A cool project description.
EOF

    # Create fixture .editorconfig
    cat > "$TMPDIR_TEST/.editorconfig" << 'EOF'
root = true

[*]
indent_size = 2
EOF

    # Create fixture package.json with scripts
    cat > "$TMPDIR_TEST/package.json" << 'EOF'
{
  "name": "test-project",
  "scripts": {
    "test": "jest",
    "build": "tsc",
    "dev": "next dev"
  },
  "dependencies": {
    "next": "14.0.0"
  }
}
EOF
}

COMMON_FLAGS="--task my-task --iteration 1 --task-prompt 'Fix the bug' --scripts-dir /tmp/scripts --dev-port 9876 --compose false --compose-services none"

# --- Test 1: --role planner: output contains <project-context> tags with CONTRIBUTING.md ---
echo "=== Test 1: Planner role has project-context and CONTRIBUTING.md ==="
setup_fixture_dir
OUTPUT=$(eval "$BUILD_CTX --role planner $COMMON_FLAGS --worktree-dir $TMPDIR_TEST" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "planner: exit 0" "$EXIT_CODE"
assert_output_contains "planner: has <project-context> open tag" "$OUTPUT" "<project-context>"
assert_output_contains "planner: has </project-context> close tag" "$OUTPUT" "</project-context>"
assert_output_contains "planner: has CONTRIBUTING.md content" "$OUTPUT" "Code Style"
cleanup

# --- Test 2: --role planner: output contains README.md content ---
echo "=== Test 2: Planner includes README.md ==="
setup_fixture_dir
OUTPUT=$(eval "$BUILD_CTX --role planner $COMMON_FLAGS --worktree-dir $TMPDIR_TEST" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_output_contains "planner: has README.md content" "$OUTPUT" "My Project"
cleanup

# --- Test 3: --role doer: output contains only Code Style section of CONTRIBUTING.md ---
echo "=== Test 3: Doer role has Code Style section only ==="
setup_fixture_dir
OUTPUT=$(eval "$BUILD_CTX --role doer $COMMON_FLAGS --worktree-dir $TMPDIR_TEST" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "doer: exit 0" "$EXIT_CODE"
assert_output_contains "doer: has Code Style content" "$OUTPUT" "ShellCheck"
assert_output_not_contains "doer: does NOT have Deployment section" "$OUTPUT" "Deploy via GitHub"
cleanup

# --- Test 4: --role doer: output contains .editorconfig content ---
echo "=== Test 4: Doer includes .editorconfig ==="
setup_fixture_dir
OUTPUT=$(eval "$BUILD_CTX --role doer $COMMON_FLAGS --worktree-dir $TMPDIR_TEST" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_output_contains "doer: has .editorconfig content" "$OUTPUT" "indent_size"
cleanup

# --- Test 5: --role checker: output contains Code Style and Testing sections ---
echo "=== Test 5: Checker has Code Style and Testing sections ==="
setup_fixture_dir
OUTPUT=$(eval "$BUILD_CTX --role checker $COMMON_FLAGS --worktree-dir $TMPDIR_TEST" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "checker: exit 0" "$EXIT_CODE"
assert_output_contains "checker: has Code Style" "$OUTPUT" "ShellCheck"
assert_output_contains "checker: has Testing section" "$OUTPUT" "GitHub Actions"
cleanup

# --- Test 6: --role checker with --diff-context: has Changes This Iteration section ---
echo "=== Test 6: Checker with diff-context has Changes section ==="
setup_fixture_dir
OUTPUT=$(eval "$BUILD_CTX --role checker $COMMON_FLAGS --worktree-dir $TMPDIR_TEST --diff-context 'src/foo.ts | 5 ++'" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_output_contains "checker: has Changes This Iteration section" "$OUTPUT" "Changes This Iteration"
assert_output_contains "checker: diff content included" "$OUTPUT" "src/foo.ts"
cleanup

# --- Test 7: All roles: output contains Task Variables block ---
echo "=== Test 7: Task Variables block present in all roles ==="
setup_fixture_dir
for role in planner doer checker; do
    OUTPUT=$(eval "$BUILD_CTX --role $role $COMMON_FLAGS --worktree-dir $TMPDIR_TEST" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
    assert_output_contains "$role: has TASK_NAME" "$OUTPUT" "TASK_NAME.*my-task"
    assert_output_contains "$role: has ITERATION" "$OUTPUT" "ITERATION.*1"
    assert_output_contains "$role: has LOOPER_DEV_PORT" "$OUTPUT" "LOOPER_DEV_PORT.*9876"
done
cleanup

# --- Test 8: --issue-body provided: output contains Issue Context section ---
echo "=== Test 8: Issue body provided ==="
setup_fixture_dir
ISSUE_BODY="## Issue #42: Fix the login bug"
OUTPUT=$(eval "$BUILD_CTX --role planner $COMMON_FLAGS --worktree-dir $TMPDIR_TEST --issue-body \"$ISSUE_BODY\"" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_output_contains "issue body: has Issue Context section" "$OUTPUT" "Issue Context"
assert_output_contains "issue body: body content present" "$OUTPUT" "Issue #42"
cleanup

# --- Test 9: --issue-body empty/omitted: has "No issue linked" fallback ---
echo "=== Test 9: No issue body -> fallback text ==="
setup_fixture_dir
OUTPUT=$(eval "$BUILD_CTX --role planner $COMMON_FLAGS --worktree-dir $TMPDIR_TEST" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_output_contains "no issue: has fallback text" "$OUTPUT" "No issue linked"
cleanup

# --- Test 10: --loop-context provided: has Prior Loop Context section ---
echo "=== Test 10: Loop context provided ==="
setup_fixture_dir
LOOP_CTX="Previous iteration: fixed typo in README"
OUTPUT=$(eval "$BUILD_CTX --role planner $COMMON_FLAGS --worktree-dir $TMPDIR_TEST --loop-context \"$LOOP_CTX\"" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_output_contains "loop ctx: has Prior Loop Context section" "$OUTPUT" "Prior Loop Context"
assert_output_contains "loop ctx: content present" "$OUTPUT" "fixed typo"
cleanup

# --- Test 11: --role planner with --iteration > 1: has pruning note ---
echo "=== Test 11: Planner with iteration > 1 has pruning note ==="
setup_fixture_dir
OUTPUT=$(eval "$BUILD_CTX --role planner --task my-task --iteration 2 --task-prompt 'Fix the bug' --scripts-dir /tmp/scripts --worktree-dir $TMPDIR_TEST --dev-port 9876 --compose false --compose-services none" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_output_contains "planner iter>1: has pruning note" "$OUTPUT" "Spawn Explore subagents ONLY\|re-explore\|action items"
cleanup

# --- Test 12: --role planner with --iteration 1: NO pruning note ---
echo "=== Test 12: Planner with iteration 1 has no pruning note ==="
setup_fixture_dir
OUTPUT=$(eval "$BUILD_CTX --role planner $COMMON_FLAGS --worktree-dir $TMPDIR_TEST" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_output_not_contains "planner iter=1: no pruning note" "$OUTPUT" "re-explore the entire codebase"
cleanup

# --- Test 13: Missing required flags -> exit nonzero ---
echo "=== Test 13: Missing required flags ==="
OUTPUT=$("$BUILD_CTX" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_nonzero "missing flags: non-zero exit" "$EXIT_CODE"
assert_output_contains "missing flags: usage message" "$OUTPUT" "usage\|--role\|required"

# --- Test 14: Missing CONTRIBUTING.md -> gracefully skips, no error ---
echo "=== Test 14: Missing CONTRIBUTING.md -> graceful skip ==="
TMPDIR_TEST=$(mktemp -d)
# No CONTRIBUTING.md created
OUTPUT=$(eval "$BUILD_CTX --role doer $COMMON_FLAGS --worktree-dir $TMPDIR_TEST" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_zero "no CONTRIBUTING.md: exit 0" "$EXIT_CODE"
assert_output_contains "no CONTRIBUTING.md: still has task vars" "$OUTPUT" "TASK_NAME"
cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
