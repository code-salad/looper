#!/usr/bin/env bash
set -euo pipefail

# test-git-commit-loop-validation.sh — Corner-case tests for git-commit-loop
# argument validation, phase handling, verdict handling, commit format, and trailers.

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
    if echo "$output" | grep -q "$expected"; then
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
    git checkout -q -b feature/test-branch
}

# --- Test 1: Missing --type -> exit 1 ---
echo "=== Test 1: Missing --type ==="
setup_test_repo
set +e
OUTPUT=$("$GIT_COMMIT_LOOP" \
    --scope "test" \
    --message "some message" \
    --phase "plan" \
    --iteration "1" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_nonzero "missing --type: exits non-zero" "$EXIT_CODE"
cleanup

# --- Test 2: Missing --scope -> exit 1 ---
echo "=== Test 2: Missing --scope ==="
setup_test_repo
set +e
OUTPUT=$("$GIT_COMMIT_LOOP" \
    --type "feat" \
    --message "some message" \
    --phase "plan" \
    --iteration "1" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_nonzero "missing --scope: exits non-zero" "$EXIT_CODE"
cleanup

# --- Test 3: Missing --message -> exit 1 ---
echo "=== Test 3: Missing --message ==="
setup_test_repo
set +e
OUTPUT=$("$GIT_COMMIT_LOOP" \
    --type "feat" \
    --scope "test" \
    --phase "plan" \
    --iteration "1" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_nonzero "missing --message: exits non-zero" "$EXIT_CODE"
cleanup

# --- Test 4: Missing --phase -> exit 1 ---
echo "=== Test 4: Missing --phase ==="
setup_test_repo
set +e
OUTPUT=$("$GIT_COMMIT_LOOP" \
    --type "feat" \
    --scope "test" \
    --message "some message" \
    --iteration "1" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_nonzero "missing --phase: exits non-zero" "$EXIT_CODE"
cleanup

# --- Test 5: Missing --iteration -> exit 1 ---
echo "=== Test 5: Missing --iteration ==="
setup_test_repo
set +e
OUTPUT=$("$GIT_COMMIT_LOOP" \
    --type "feat" \
    --scope "test" \
    --message "some message" \
    --phase "plan" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_nonzero "missing --iteration: exits non-zero" "$EXIT_CODE"
cleanup

# --- Test 6: Invalid --phase value -> exit 1 with error message ---
echo "=== Test 6: Invalid --phase value ==="
setup_test_repo
set +e
OUTPUT=$("$GIT_COMMIT_LOOP" \
    --type "feat" \
    --scope "test" \
    --message "some message" \
    --phase "invalid" \
    --iteration "1" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_nonzero "invalid --phase: exits non-zero" "$EXIT_CODE"
assert_output_contains "invalid --phase: error message mentions phase" "$OUTPUT" "phase"
cleanup

# --- Test 7: Invalid --verdict value -> exit 1 with error message ---
echo "=== Test 7: Invalid --verdict value ==="
setup_test_repo
set +e
OUTPUT=$("$GIT_COMMIT_LOOP" \
    --type "chore" \
    --scope "test" \
    --message "check message" \
    --phase "check" \
    --iteration "1" \
    --verdict "MAYBE" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_nonzero "invalid --verdict: exits non-zero" "$EXIT_CODE"
assert_output_contains "invalid --verdict: error message mentions verdict" "$OUTPUT" "verdict"
cleanup

# --- Test 8: Valid --verdict PASS -> commit includes Loop-Verdict: PASS ---
echo "=== Test 8: Valid --verdict PASS ==="
setup_test_repo
set +e
"$GIT_COMMIT_LOOP" \
    --type "chore" \
    --scope "test" \
    --message "check message" \
    --phase "check" \
    --iteration "1" \
    --verdict "PASS" >/dev/null 2>&1
EXIT_CODE=$?
set -e
assert_exit_zero "valid --verdict PASS: exits zero" "$EXIT_CODE"
COMMIT_MSG=$(git log --format="%B" -1)
assert_output_contains "PASS verdict: commit has Loop-Verdict: PASS" "$COMMIT_MSG" "Loop-Verdict: PASS"
cleanup

# --- Test 9: Valid --verdict FAIL -> commit includes Loop-Verdict: FAIL ---
echo "=== Test 9: Valid --verdict FAIL ==="
setup_test_repo
set +e
"$GIT_COMMIT_LOOP" \
    --type "chore" \
    --scope "test" \
    --message "check message" \
    --phase "check" \
    --iteration "1" \
    --verdict "FAIL" >/dev/null 2>&1
EXIT_CODE=$?
set -e
assert_exit_zero "valid --verdict FAIL: exits zero" "$EXIT_CODE"
COMMIT_MSG=$(git log --format="%B" -1)
assert_output_contains "FAIL verdict: commit has Loop-Verdict: FAIL" "$COMMIT_MSG" "Loop-Verdict: FAIL"
cleanup

# --- Test 10: plan phase creates --allow-empty commit even with no staged changes ---
echo "=== Test 10: plan phase allows empty commit ==="
setup_test_repo
# No files added/changed
set +e
"$GIT_COMMIT_LOOP" \
    --type "chore" \
    --scope "test" \
    --message "plan message" \
    --phase "plan" \
    --iteration "1" >/dev/null 2>&1
EXIT_CODE=$?
set -e
assert_exit_zero "plan phase: empty commit succeeds" "$EXIT_CODE"
cleanup

# --- Test 11: check phase creates --allow-empty commit even with no staged changes ---
echo "=== Test 11: check phase allows empty commit ==="
setup_test_repo
# No files added/changed
set +e
"$GIT_COMMIT_LOOP" \
    --type "chore" \
    --scope "test" \
    --message "check message" \
    --phase "check" \
    --iteration "1" >/dev/null 2>&1
EXIT_CODE=$?
set -e
assert_exit_zero "check phase: empty commit succeeds" "$EXIT_CODE"
cleanup

# --- Test 12: do phase fails if no changes to commit ---
echo "=== Test 12: do-red phase fails with no changes ==="
setup_test_repo
# No files added/changed
set +e
"$GIT_COMMIT_LOOP" \
    --type "test" \
    --scope "test" \
    --message "red tests" \
    --phase "do-red" \
    --iteration "1" >/dev/null 2>&1
EXIT_CODE=$?
set -e
assert_exit_nonzero "do-red phase: fails with no changes" "$EXIT_CODE"
cleanup

# --- Test 13: Body with \n is properly expanded in commit message ---
echo "=== Test 13: Body newline expansion ==="
setup_test_repo
touch dummy.txt
set +e
"$GIT_COMMIT_LOOP" \
    --type "feat" \
    --scope "test" \
    --message "test message" \
    --body "Line one\nLine two\nLine three" \
    --phase "do-green" \
    --iteration "1" >/dev/null 2>&1
EXIT_CODE=$?
set -e
assert_exit_zero "body with newlines: exits zero" "$EXIT_CODE"
COMMIT_MSG=$(git log --format="%B" -1)
assert_output_contains "body newlines: Line one present" "$COMMIT_MSG" "Line one"
assert_output_contains "body newlines: Line two present" "$COMMIT_MSG" "Line two"
cleanup

# --- Test 14: Commit message has correct conventional format type(scope): message ---
echo "=== Test 14: Conventional commit format ==="
setup_test_repo
touch myfile.txt
set +e
"$GIT_COMMIT_LOOP" \
    --type "feat" \
    --scope "myscope" \
    --message "my feature" \
    --phase "do-green" \
    --iteration "1" >/dev/null 2>&1
EXIT_CODE=$?
set -e
assert_exit_zero "conventional format: exits zero" "$EXIT_CODE"
COMMIT_SUBJECT=$(git log --format="%s" -1)
assert_output_contains "conventional format: subject matches pattern" "$COMMIT_SUBJECT" "feat(myscope): my feature"
cleanup

# --- Test 15: Loop trailers Loop-Phase and Loop-Iteration present ---
echo "=== Test 15: Loop trailers present ==="
setup_test_repo
touch anotherfile.txt
set +e
"$GIT_COMMIT_LOOP" \
    --type "feat" \
    --scope "test" \
    --message "test message" \
    --phase "do-red" \
    --iteration "5" >/dev/null 2>&1
EXIT_CODE=$?
set -e
assert_exit_zero "loop trailers: exits zero" "$EXIT_CODE"
COMMIT_MSG=$(git log --format="%B" -1)
assert_output_contains "loop trailers: Loop-Phase present" "$COMMIT_MSG" "Loop-Phase: do-red"
assert_output_contains "loop trailers: Loop-Iteration present" "$COMMIT_MSG" "Loop-Iteration: 5"
cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
