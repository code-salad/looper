#!/usr/bin/env bash
set -euo pipefail

# test-git-loop-context.sh — Corner-case tests for git-loop-context script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_LOOP_CONTEXT="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/git-loop-context"

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
        echo "  Actual output (first 5 lines): $(echo "$output" | head -5)"
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

setup_test_repo() {
    TMPDIR_TEST=$(mktemp -d)
    cd "$TMPDIR_TEST"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false
    git commit --allow-empty -q -m "initial commit"
}

make_loop_commit() {
    local phase="$1"
    local iteration="$2"
    local verdict="${3:-}"
    local msg_body="${4:-test body for $phase iteration $iteration}"
    local msg="test(mytask): $phase iter $iteration"
    local trailers
    trailers="Loop-Phase: $phase"$'\n'"Loop-Iteration: $iteration"
    if [ -n "$verdict" ]; then
        trailers+=$'\n'"Loop-Verdict: $verdict"
    fi
    git commit --allow-empty -q -m "$msg"$'\n\n'"$msg_body"$'\n\n'"$trailers"
}

# --- Test 1: Iteration 1 -> prints "first iteration" message and exits 0 ---
echo "=== Test 1: Iteration 1 outputs first iteration message ==="
setup_test_repo
set +e
OUTPUT=$("$GIT_LOOP_CONTEXT" --task "mytask" --iteration "1" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_zero "iteration 1: exits zero" "$EXIT_CODE"
assert_output_contains "iteration 1: mentions first iteration" "$OUTPUT" "first iteration"
cleanup

# --- Test 2: Missing --task -> exit 1 with usage ---
echo "=== Test 2: Missing --task ==="
setup_test_repo
set +e
OUTPUT=$("$GIT_LOOP_CONTEXT" --iteration "2" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_nonzero "missing --task: exits non-zero" "$EXIT_CODE"
assert_output_contains "missing --task: shows usage" "$OUTPUT" "Usage"
cleanup

# --- Test 3: Missing --iteration -> exit 1 with usage ---
echo "=== Test 3: Missing --iteration ==="
setup_test_repo
set +e
OUTPUT=$("$GIT_LOOP_CONTEXT" --task "mytask" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_nonzero "missing --iteration: exits non-zero" "$EXIT_CODE"
assert_output_contains "missing --iteration: shows usage" "$OUTPUT" "Usage"
cleanup

# --- Test 4: Iteration 2 with one prior plan+do+check -> output includes plan ---
echo "=== Test 4: Iteration 2 with prior loop iteration ==="
setup_test_repo
make_loop_commit "plan" "1" "" "## Goal\nFix the bug in the login flow"
make_loop_commit "do-red" "1"
make_loop_commit "do-green" "1"
make_loop_commit "check" "1" "PASS" "## Verdict\nAll tests passed"
set +e
OUTPUT=$("$GIT_LOOP_CONTEXT" --task "mytask" --iteration "2" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_zero "iter 2 with prior: exits zero" "$EXIT_CODE"
assert_output_contains "iter 2 with prior: shows iteration 1" "$OUTPUT" "Iteration 1"
assert_output_contains "iter 2 with prior: shows Plan section" "$OUTPUT" "Plan"
cleanup

# --- Test 5: Iteration 5 -> output includes multiple iterations ---
echo "=== Test 5: Iteration 5 shows progressive context ==="
setup_test_repo
for i in 1 2 3 4; do
    make_loop_commit "plan" "$i" "" "## Goal\nFix bug $i in the system"
    make_loop_commit "do-red" "$i"
    make_loop_commit "do-green" "$i"
    make_loop_commit "check" "$i" "PASS" "## Verdict\nAll good for iteration $i"
done
set +e
OUTPUT=$("$GIT_LOOP_CONTEXT" --task "mytask" --iteration "5" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_zero "iter 5 progressive: exits zero" "$EXIT_CODE"
assert_output_contains "iter 5 progressive: shows iteration 4 (full)" "$OUTPUT" "Iteration 4"
assert_output_contains "iter 5 progressive: shows iteration 1" "$OUTPUT" "Iteration 1"
cleanup

# --- Test 6: No prior commits matching Loop-Iteration -> empty context output ---
echo "=== Test 6: Iteration 3, but no Loop-Iteration commits ==="
setup_test_repo
# No loop commits; just regular commits
git commit --allow-empty -q -m "some regular work"
git commit --allow-empty -q -m "another regular commit"
set +e
OUTPUT=$("$GIT_LOOP_CONTEXT" --task "mytask" --iteration "3" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_zero "no prior loop commits: exits zero" "$EXIT_CODE"
assert_output_contains "no prior loop commits: has header" "$OUTPUT" "Loop Context"
# Should not crash or error; just no data for iterations 1-2
assert_output_not_contains "no prior loop commits: no error" "$OUTPUT" "Error"
cleanup

# --- Test 7: Legacy "do" phase -> shows "Changes" section ---
echo "=== Test 7: Legacy 'do' phase shows Changes section ==="
setup_test_repo
make_loop_commit "plan" "1" "" "## Goal\nDo the thing"
make_loop_commit "do" "1" "" "Implemented the feature with legacy do phase"
make_loop_commit "check" "1" "PASS" "## Verdict\nAll passed"
set +e
OUTPUT=$("$GIT_LOOP_CONTEXT" --task "mytask" --iteration "2" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_zero "legacy do: exits zero" "$EXIT_CODE"
assert_output_contains "legacy do: shows Changes section" "$OUTPUT" "Changes"
cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
