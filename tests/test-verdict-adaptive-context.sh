#!/usr/bin/env bash
set -euo pipefail

# test-verdict-adaptive-context.sh — Tests for verdict-adaptive compression in git-loop-context
# Verifies PASS iterations always get minimal detail (even at N-2),
# FAIL iterations keep medium when recent (within N-4), and N-1 is always full.

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
        echo "  Actual output: $(echo "$output" | head -20)"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_not_contains() {
    local description="$1"
    local output="$2"
    local unexpected="$3"
    if echo "$output" | grep -q "$unexpected"; then
        echo "FAIL: $description (expected output NOT to contain '$unexpected')"
        echo "  Actual output: $(echo "$output" | head -20)"
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

# --- Test 1: PASS iteration at N-2 gets minimal (not medium) ---
# The OLD logic gave N-2 medium regardless of verdict.
# The NEW logic: PASS -> always minimal (even at N-2).
# Setup: iter1=FAIL, iter2=PASS, iter3=FAIL. Running with --iteration 4.
# iter3=N-1 -> full. iter2=PASS at N-2 -> NEW: minimal (no "#### Plan" block). iter1=FAIL -> medium.
echo "=== Test 1: PASS at N-2 gets minimal (not medium) ==="
setup_test_repo

make_loop_commit "plan" "1" "" "## Goal\nAttempt one FAIL"
make_loop_commit "do-red" "1"
make_loop_commit "do-green" "1"
make_loop_commit "check" "1" "FAIL" "## Issues\nSomething broken in iter1"

make_loop_commit "plan" "2" "" "## Goal\nAttempt two PASS"
make_loop_commit "do-red" "2"
make_loop_commit "do-green" "2"
make_loop_commit "check" "2" "PASS" "## What passed\nAll tests passed in iter2"

make_loop_commit "plan" "3" "" "## Goal\nAttempt three FAIL"
make_loop_commit "do-red" "3"
make_loop_commit "do-green" "3"
make_loop_commit "check" "3" "FAIL" "## Issues\nSomething broken in iter3"

set +e
OUTPUT=$("$GIT_LOOP_CONTEXT" --task "mytask" --iteration "4" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_zero "PASS at N-2 minimal: exits zero" "$EXIT_CODE"

# Iteration 3 is N-1: must be full (has "#### Plan" header)
assert_output_contains "iter 3 (N-1): full detail has Plan section" "$OUTPUT" "#### Plan"

# Iteration 2 is PASS at N-2:
# OLD behavior: medium (would have "#### Plan" or "#### Verdict" for iter 2)
# NEW behavior: minimal (just "### Iteration 2 — PASS" with plan summary, no "#### Plan" block)
# We test that "Iteration 2" appears with inline verdict "PASS" in minimal format
assert_output_contains "iter 2 (PASS, N-2): appears in output" "$OUTPUT" "Iteration 2"
assert_output_contains "iter 2 (PASS, N-2): verdict is PASS" "$OUTPUT" "PASS"

# The key assertion: under the new verdict-adaptive logic, "#### Plan" should NOT appear
# for iteration 2's section (it should be minimal). We check this by counting Plan headers
# and verifying they only belong to iter 3's full section (N-1).
# The "#### Verdict" header for iter 2 should also NOT appear (that's medium format).
# We use a trick: extract just the iter2 section and verify no "#### Verdict" in it.
ITER2_SECTION=$(echo "$OUTPUT" | awk '/### Iteration 2/,/### Iteration [^2]|^---$/' | head -10)
assert_output_not_contains "iter 2 (PASS, N-2): no '#### Plan' in iter2 section (minimal)" "$ITER2_SECTION" "#### Plan"
assert_output_not_contains "iter 2 (PASS, N-2): no '#### Verdict' in iter2 section (minimal)" "$ITER2_SECTION" "#### Verdict"

cleanup

# --- Test 2: FAIL at N-2 gets medium (preserved because recent FAIL) ---
# Setup: iter1=PASS, iter2=FAIL, iter3=PASS. Running with --iteration 4.
# iter3=N-1 -> full. iter2=FAIL at N-2 -> NEW: medium (within N-4). iter1=PASS -> minimal.
echo "=== Test 2: FAIL at N-2 gets medium detail ==="
setup_test_repo

make_loop_commit "plan" "1" "" "## Goal\nAttempt one PASS"
make_loop_commit "do-red" "1"
make_loop_commit "do-green" "1"
make_loop_commit "check" "1" "PASS" "## What passed\nAll good in iter1"

make_loop_commit "plan" "2" "" "## Goal\nAttempt two FAIL"
make_loop_commit "do-red" "2"
make_loop_commit "do-green" "2"
make_loop_commit "check" "2" "FAIL" "## Issues\nSomething broken in iter2"

make_loop_commit "plan" "3" "" "## Goal\nAttempt three PASS"
make_loop_commit "do-red" "3"
make_loop_commit "do-green" "3"
make_loop_commit "check" "3" "PASS" "## What passed\nAll good in iter3"

set +e
OUTPUT=$("$GIT_LOOP_CONTEXT" --task "mytask" --iteration "4" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_zero "FAIL at N-2 medium: exits zero" "$EXIT_CODE"

# Iteration 3 is N-1, PASS: must be full (still full because N-1 rule trumps)
assert_output_contains "iter 3 (N-1, PASS): shown (full)" "$OUTPUT" "Iteration 3"

# Iteration 2 is FAIL at N-2 within N-4 (4-4=0, iter2 >= 0): medium
# Medium format has "#### Verdict" section
ITER2_SECTION=$(echo "$OUTPUT" | awk '/### Iteration 2/,/### Iteration [^2]|^---$/')
assert_output_contains "iter 2 (FAIL, N-2): medium has Verdict section" "$ITER2_SECTION" "#### Verdict"

# Iteration 1 is PASS: minimal (no "#### Verdict" in iter1 section)
ITER1_SECTION=$(echo "$OUTPUT" | awk '/### Iteration 1/,/### Iteration [^1]|^---$/' | head -10)
assert_output_not_contains "iter 1 (PASS): minimal, no Verdict section" "$ITER1_SECTION" "#### Verdict"

cleanup

# --- Test 3: FAIL older than N-4 gets minimal ---
# Setup: 6 iterations. iter1=FAIL, iter2=FAIL, iter3=FAIL, iter4=PASS, iter5=FAIL.
# Running with --iteration 6: N-1=5 full, N-4=2.
# iter3=FAIL, iter3 >= (6-4)=2 -> medium. iter2=FAIL, iter2 >= 2 -> medium.
# iter1=FAIL, iter1 < 2 -> minimal.
echo "=== Test 3: FAIL older than N-4 gets minimal ==="
setup_test_repo

make_loop_commit "plan" "1" "" "## Goal\nIter one old FAIL"
make_loop_commit "do-red" "1"
make_loop_commit "do-green" "1"
make_loop_commit "check" "1" "FAIL" "## Issues\nOld failure iter1"

make_loop_commit "plan" "2" "" "## Goal\nIter two medium FAIL"
make_loop_commit "do-red" "2"
make_loop_commit "do-green" "2"
make_loop_commit "check" "2" "FAIL" "## Issues\nMedium failure iter2"

make_loop_commit "plan" "3" "" "## Goal\nIter three medium FAIL"
make_loop_commit "do-red" "3"
make_loop_commit "do-green" "3"
make_loop_commit "check" "3" "FAIL" "## Issues\nMedium failure iter3"

make_loop_commit "plan" "4" "" "## Goal\nIter four PASS"
make_loop_commit "do-red" "4"
make_loop_commit "do-green" "4"
make_loop_commit "check" "4" "PASS" "## What passed\nAll good iter4"

make_loop_commit "plan" "5" "" "## Goal\nIter five N-1 FAIL"
make_loop_commit "do-red" "5"
make_loop_commit "do-green" "5"
make_loop_commit "check" "5" "FAIL" "## Issues\nN-1 failure iter5"

set +e
OUTPUT=$("$GIT_LOOP_CONTEXT" --task "mytask" --iteration "6" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_zero "FAIL older than N-4: exits zero" "$EXIT_CODE"

# iter5 is N-1: full (has "#### Plan")
assert_output_contains "iter 5 (N-1): full detail has Plan" "$OUTPUT" "#### Plan"

# iter4 is PASS: minimal
ITER4_SECTION=$(echo "$OUTPUT" | awk '/### Iteration 4/,/### Iteration [^4]|^---$/' | head -10)
assert_output_not_contains "iter 4 (PASS): minimal, no Verdict section" "$ITER4_SECTION" "#### Verdict"

# iter3 is FAIL within N-4 (6-4=2, iter3>=2): medium has Verdict
ITER3_SECTION=$(echo "$OUTPUT" | awk '/### Iteration 3/,/### Iteration [^3]|^---$/')
assert_output_contains "iter 3 (FAIL, within N-4): medium has Verdict" "$ITER3_SECTION" "#### Verdict"

# iter2 is FAIL within N-4 (iter2>=2): medium
ITER2_SECTION=$(echo "$OUTPUT" | awk '/### Iteration 2/,/### Iteration [^2]|^---$/')
assert_output_contains "iter 2 (FAIL, within N-4): medium has Verdict" "$ITER2_SECTION" "#### Verdict"

# iter1 is FAIL older than N-4 (iter1 < 2): minimal (no Verdict section)
ITER1_SECTION=$(echo "$OUTPUT" | awk '/### Iteration 1/,/### Iteration [^1]|^---$/' | head -10)
assert_output_not_contains "iter 1 (FAIL, older than N-4): minimal, no Verdict section" "$ITER1_SECTION" "#### Verdict"

cleanup

# --- Test 4: Edge case - N-1=1 FAIL -> still full (N-1 rule beats verdict) ---
echo "=== Test 4: Edge case - N-1 FAIL -> still full ==="
setup_test_repo

make_loop_commit "plan" "1" "" "## Goal\nAttempt one FAIL"
make_loop_commit "do-red" "1"
make_loop_commit "do-green" "1"
make_loop_commit "check" "1" "FAIL" "## Issues\nSomething went wrong"

set +e
OUTPUT=$("$GIT_LOOP_CONTEXT" --task "mytask" --iteration "2" 2>&1)
EXIT_CODE=$?
set -e

assert_exit_zero "edge case N-1 FAIL: exits zero" "$EXIT_CODE"
# Iteration 1 is N-1 and FAIL: N-1 rule trumps -> full detail
assert_output_contains "edge case: iter 1 (N-1, FAIL) has Plan section" "$OUTPUT" "#### Plan"

cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
