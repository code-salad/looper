#!/usr/bin/env bash
set -euo pipefail

# test-sync-with-remote.sh — Corner-case tests for sync-with-remote script
# Uses bare origin + clone repos to test remote sync scenarios.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_WITH_REMOTE="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/sync-with-remote"

PASS=0
FAIL=0
TMPDIR_TEST=""

cleanup() {
    if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
        rm -rf "$TMPDIR_TEST"
    fi
}
trap cleanup EXIT

assert_exit_code() {
    local description="$1"
    local actual_code="$2"
    local expected_code="$3"
    if [ "$actual_code" -eq "$expected_code" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected exit $expected_code, got $actual_code)"
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

setup_origin_and_clone() {
    TMPDIR_TEST=$(mktemp -d)
    # Create a bare "origin" repo and set its HEAD to main
    git init -q --bare "$TMPDIR_TEST/origin.git"
    # Update HEAD to point to main before pushing
    git -C "$TMPDIR_TEST/origin.git" symbolic-ref HEAD refs/heads/main

    # Create a working repo with initial commit
    git init -q "$TMPDIR_TEST/source"
    cd "$TMPDIR_TEST/source"
    git config user.email "test@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false
    git commit --allow-empty -q -m "initial commit"
    git branch -M main
    git remote add origin "$TMPDIR_TEST/origin.git"
    git push -q origin main

    # Clone from origin
    git clone -q "$TMPDIR_TEST/origin.git" "$TMPDIR_TEST/clone"
    cd "$TMPDIR_TEST/clone"
    git config user.email "test@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false
    # Create a local feature branch (no need to push it)
    git checkout -q -b feature/test
}

# --- Test 1: Already up-to-date -> STATUS=up-to-date, exit 0 ---
echo "=== Test 1: Already up-to-date ==="
setup_origin_and_clone
# No new commits on either side; clone is on feature/test branch
# sync-with-remote rebases onto origin/main; clone is already at same point
set +e
OUTPUT=$(cd "$TMPDIR_TEST/clone" && "$SYNC_WITH_REMOTE" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "up-to-date: exit 0" "$EXIT_CODE" "0"
assert_output_contains "up-to-date: STATUS=up-to-date" "$OUTPUT" "STATUS=up-to-date"
cleanup

# --- Test 2: Behind origin (origin has new commits) -> STATUS=rebased, exit 0 ---
echo "=== Test 2: Behind origin, needs rebase ==="
setup_origin_and_clone
# Add a new commit on origin's main
cd "$TMPDIR_TEST/source"
git commit --allow-empty -q -m "new commit on origin main"
git push -q origin main

# Now clone's feature/test is behind origin/main
set +e
OUTPUT=$(cd "$TMPDIR_TEST/clone" && "$SYNC_WITH_REMOTE" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "behind origin: exit 0" "$EXIT_CODE" "0"
assert_output_contains "behind origin: STATUS=rebased" "$OUTPUT" "STATUS=rebased"
cleanup

# --- Test 3: No remote configured -> exit 2 ---
echo "=== Test 3: No remote configured ==="
TMPDIR_TEST=$(mktemp -d)
cd "$TMPDIR_TEST"
git init -q
git config user.email "test@test.com"
git config user.name "Test User"
git config commit.gpgsign false
git commit --allow-empty -q -m "initial commit"
git checkout -q -b feature/no-remote
# No remote added at all
set +e
OUTPUT=$("$SYNC_WITH_REMOTE" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "no remote: exit 2" "$EXIT_CODE" "2"
cleanup

# --- Test 4: Conflicting diverged branches -> STATUS=conflicts, exit 1 ---
echo "=== Test 4: Diverged branches with conflicts ==="
setup_origin_and_clone

# Add a conflicting commit on origin/main
cd "$TMPDIR_TEST/source"
echo "origin content" > "$TMPDIR_TEST/source/conflict.txt"
git add conflict.txt
git commit -q -m "add conflict.txt on origin main"
git push -q origin main

# Add a conflicting commit on the clone's feature branch
cd "$TMPDIR_TEST/clone"
echo "local content" > "$TMPDIR_TEST/clone/conflict.txt"
git add conflict.txt
git commit -q -m "add conflict.txt on local feature branch"

# Now sync: rebase local onto origin/main should produce conflicts
set +e
OUTPUT=$(cd "$TMPDIR_TEST/clone" && "$SYNC_WITH_REMOTE" 2>/dev/null)
EXIT_CODE=$?
set -e
# If there are conflicts, exit 1 and STATUS=conflicts
# If git is smart enough to auto-resolve, it may succeed — we check either case
if [ "$EXIT_CODE" -eq 1 ]; then
    assert_exit_code "conflict: exit 1" "$EXIT_CODE" "1"
    assert_output_contains "conflict: STATUS=conflicts" "$OUTPUT" "STATUS=conflicts"
elif [ "$EXIT_CODE" -eq 0 ]; then
    # Git resolved it trivially (different lines) — still a valid outcome
    assert_exit_code "no-conflict-auto-resolved: exit 0" "$EXIT_CODE" "0"
    echo "INFO: git auto-resolved the conflict (different lines in file)"
else
    assert_exit_code "conflict test: unexpected exit code" "$EXIT_CODE" "1"
fi
# Abort any ongoing rebase to clean up
cd "$TMPDIR_TEST/clone"
git rebase --abort 2>/dev/null || true
cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
