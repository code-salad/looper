#!/usr/bin/env bash
set -euo pipefail

# test-bare-repo-guard.sh — Tests for bare-repo guard (ensure_not_bare helper)
# Verifies that looper scripts detect and fix core.bare=true on the main repo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_SH="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/_helpers.sh"
SETUP_WORKTREE="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/setup-worktree"

PASS=0
FAIL=0
TMPDIR_TEST=""

cleanup() {
    if [ -n "${TMPDIR_TEST:-}" ] && [ -d "${TMPDIR_TEST:-}" ]; then
        # Remove any nested worktrees first
        git -C "$TMPDIR_TEST" worktree prune 2>/dev/null || true
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

assert_eq() {
    local description="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_eq() {
    local description="$1"
    local actual="$2"
    local unexpected="$3"
    if [ "$actual" != "$unexpected" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (value should not be '$unexpected', but it was)"
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

assert_output_not_contains() {
    local description="$1"
    local output="$2"
    local unexpected="$3"
    if ! echo "$output" | grep -qi "$unexpected"; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected output NOT to contain '$unexpected')"
        echo "  Actual output: $output"
        FAIL=$((FAIL + 1))
    fi
}

setup_test_repo() {
    TMPDIR_TEST=$(mktemp -d)
    git init -q "$TMPDIR_TEST"
    git -C "$TMPDIR_TEST" config user.email "test@test.com"
    git -C "$TMPDIR_TEST" config user.name "Test User"
    git -C "$TMPDIR_TEST" config commit.gpgsign false
    git -C "$TMPDIR_TEST" commit --allow-empty -q -m "initial commit"
}

# --- Test 1: ensure_not_bare fixes core.bare=true ---
echo "=== Test 1: ensure_not_bare fixes core.bare=true ==="
setup_test_repo

git -C "$TMPDIR_TEST" config core.bare true
BARE_BEFORE=$(git -C "$TMPDIR_TEST" config --get core.bare 2>/dev/null || echo "unset")
assert_eq "core.bare is true before fix" "$BARE_BEFORE" "true"

# Source helpers and call ensure_not_bare
set +e
OUTPUT=$(bash -c "
    set -euo pipefail
    SCRIPT_DIR='$(dirname "$HELPERS_SH")'
    source '$HELPERS_SH'
    ensure_not_bare '$TMPDIR_TEST'
" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_zero "ensure_not_bare exits 0 when fixing bare repo" "$EXIT_CODE"
BARE_AFTER=$(git -C "$TMPDIR_TEST" config --get core.bare 2>/dev/null || echo "unset")
assert_not_eq "core.bare is no longer true after fix" "$BARE_AFTER" "true"
assert_output_contains "ensure_not_bare emits a warning when fixing" "$OUTPUT" "warn\|bare\|fix"

cleanup

# --- Test 2: ensure_not_bare is a no-op when core.bare is not set ---
echo "=== Test 2: ensure_not_bare is a no-op when core.bare is false/unset ==="
setup_test_repo

# core.bare should not be set (or false) for a freshly init'd repo
BARE_BEFORE=$(git -C "$TMPDIR_TEST" config --get core.bare 2>/dev/null || echo "unset")
assert_not_eq "core.bare is not true before test" "$BARE_BEFORE" "true"

set +e
OUTPUT=$(bash -c "
    set -euo pipefail
    SCRIPT_DIR='$(dirname "$HELPERS_SH")'
    source '$HELPERS_SH'
    ensure_not_bare '$TMPDIR_TEST'
" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_zero "ensure_not_bare exits 0 for normal repo" "$EXIT_CODE"
assert_output_not_contains "ensure_not_bare emits no warning for normal repo" "$OUTPUT" "warn"

cleanup

# --- Test 3: setup-worktree succeeds even when core.bare=true ---
echo "=== Test 3: setup-worktree succeeds and fixes core.bare=true ==="
setup_test_repo

git -C "$TMPDIR_TEST" config core.bare true
BARE_BEFORE=$(git -C "$TMPDIR_TEST" config --get core.bare 2>/dev/null || echo "unset")
assert_eq "core.bare is true before setup-worktree" "$BARE_BEFORE" "true"

set +e
OUTPUT=$(cd "$TMPDIR_TEST" && "$SETUP_WORKTREE" --task "test-bare-fix" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_zero "setup-worktree exits 0 even when core.bare was true" "$EXIT_CODE"

BARE_AFTER=$(git -C "$TMPDIR_TEST" config --get core.bare 2>/dev/null || echo "unset")
assert_not_eq "core.bare is no longer true after setup-worktree" "$BARE_AFTER" "true"

WORKTREE_PATH="$TMPDIR_TEST/.worktrees/test-bare-fix"
if [ -d "$WORKTREE_PATH" ]; then
    echo "PASS: setup-worktree created the worktree directory"
    PASS=$((PASS + 1))
else
    echo "FAIL: setup-worktree did not create the worktree directory at $WORKTREE_PATH"
    FAIL=$((FAIL + 1))
fi

cleanup

# --- Test 4: After creating a worktree, core.bare stays false ---
echo "=== Test 4: After creating a worktree, core.bare stays false on main repo ==="
setup_test_repo

set +e
OUTPUT=$(cd "$TMPDIR_TEST" && "$SETUP_WORKTREE" --task "test-stays-false" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_zero "setup-worktree succeeds on normal repo" "$EXIT_CODE"

BARE_AFTER=$(git -C "$TMPDIR_TEST" config --get core.bare 2>/dev/null || echo "unset")
assert_not_eq "core.bare stays not-true after worktree creation" "$BARE_AFTER" "true"

cleanup

# --- Test 5: After removing a worktree, core.bare stays false ---
echo "=== Test 5: After removing a worktree, core.bare stays false ==="
setup_test_repo

# Create a worktree
cd "$TMPDIR_TEST"
git -C "$TMPDIR_TEST" worktree add "$TMPDIR_TEST/.worktrees/temp-wt" -b "loop/temp-task" HEAD >/dev/null 2>&1

BARE_AFTER_ADD=$(git -C "$TMPDIR_TEST" config --get core.bare 2>/dev/null || echo "unset")
assert_not_eq "core.bare stays not-true after worktree add" "$BARE_AFTER_ADD" "true"

# Remove the worktree
git -C "$TMPDIR_TEST" worktree remove "$TMPDIR_TEST/.worktrees/temp-wt" --force >/dev/null 2>&1 || true

BARE_AFTER_REMOVE=$(git -C "$TMPDIR_TEST" config --get core.bare 2>/dev/null || echo "unset")
assert_not_eq "core.bare stays not-true after worktree removal" "$BARE_AFTER_REMOVE" "true"

cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
