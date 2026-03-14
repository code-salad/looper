#!/usr/bin/env bash
set -euo pipefail

# test-git-commit-loop.sh — Tests for branch guard in git-commit-loop
# Verifies that git-commit-loop refuses to commit on protected branches.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_COMMIT_LOOP="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/git-commit-loop"

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
    if echo "$output" | grep -qi "$expected"; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected output to contain '$expected')"
        echo "  Actual output: $output"
        FAIL=$((FAIL + 1))
    fi
}

setup_test_repo() {
    TMPDIR_TEST=$(mktemp -d)
    cd "$TMPDIR_TEST"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false
    git commit --allow-empty -q -m "initial commit"
}

# --- Test 1: Refuses to commit on main branch ---
echo "=== Test 1: Refuses to commit on main branch ==="
setup_test_repo

# Ensure we are on main
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
    # Some git versions create 'master' by default; rename to main
    git branch -m master main 2>/dev/null || true
fi

touch dummy-file.txt
set +e
OUTPUT=$("$GIT_COMMIT_LOOP" \
    --type "feat" \
    --scope "test" \
    --message "test commit on main" \
    --phase "do" \
    --iteration "1" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_nonzero "git-commit-loop exits non-zero on main branch" "$EXIT_CODE"
assert_output_contains "error message mentions protected branch" "$OUTPUT" "protected"

cleanup

# --- Test 2: Refuses to commit on master branch ---
echo "=== Test 2: Refuses to commit on master branch ==="
setup_test_repo

# Rename to master if needed
git branch -m "$(git branch --show-current)" master 2>/dev/null || true

touch dummy-file.txt
set +e
OUTPUT=$("$GIT_COMMIT_LOOP" \
    --type "feat" \
    --scope "test" \
    --message "test commit on master" \
    --phase "do" \
    --iteration "1" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_nonzero "git-commit-loop exits non-zero on master branch" "$EXIT_CODE"
assert_output_contains "error message mentions protected branch" "$OUTPUT" "protected"

cleanup

# --- Test 3: Succeeds on a loop/* branch ---
echo "=== Test 3: Succeeds on a loop/* branch ==="
setup_test_repo

git checkout -q -b loop/test-task
touch dummy-file.txt

set +e
OUTPUT=$("$GIT_COMMIT_LOOP" \
    --type "feat" \
    --scope "test" \
    --message "test commit on loop branch" \
    --phase "do" \
    --iteration "1" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_zero "git-commit-loop succeeds on loop/* branch" "$EXIT_CODE"

cleanup

# --- Test 4: Succeeds on a non-protected feature branch ---
echo "=== Test 4: Succeeds on an arbitrary feature branch ==="
setup_test_repo

git checkout -q -b feature/my-feature
touch dummy-file.txt

set +e
OUTPUT=$("$GIT_COMMIT_LOOP" \
    --type "feat" \
    --scope "test" \
    --message "test commit on feature branch" \
    --phase "do" \
    --iteration "1" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_zero "git-commit-loop succeeds on feature/* branch" "$EXIT_CODE"

cleanup

# --- Test 5: Error message instructs to use setup-worktree ---
echo "=== Test 5: Error message mentions worktree instructions ==="
setup_test_repo

touch dummy-file.txt
set +e
OUTPUT=$("$GIT_COMMIT_LOOP" \
    --type "feat" \
    --scope "test" \
    --message "test commit on main" \
    --phase "do" \
    --iteration "1" 2>&1)
EXIT_CODE=$?
set -e

assert_output_contains "error message mentions worktree" "$OUTPUT" "worktree"

cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
