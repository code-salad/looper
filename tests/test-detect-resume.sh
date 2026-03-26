#!/usr/bin/env bash
set -euo pipefail

# test-detect-resume.sh — Corner-case tests for the detect-resume script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT_RESUME="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/detect-resume"

PASS=0
FAIL=0
TMPDIR_TEST=""

cleanup() {
    if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
        rm -rf "$TMPDIR_TEST"
    fi
}
trap cleanup EXIT

assert_output_equals() {
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
    local msg="test(task): $phase commit"
    local trailers
    trailers="Loop-Phase: $phase"$'\n'"Loop-Iteration: $iteration"
    if [ -n "$verdict" ]; then
        trailers+=$'\n'"Loop-Verdict: $verdict"
    fi
    git commit --allow-empty -q -m "$msg"$'\n\n'"$trailers"
}

# --- Test 1: Fresh repo with no loop commits -> outputs "1" ---
echo "=== Test 1: Fresh repo, no loop commits ==="
setup_test_repo
RESULT=$("$DETECT_RESUME" 2>/dev/null)
assert_output_equals "fresh repo: output is 1" "$RESULT" "1"
cleanup

# --- Test 2: After PASS verdict at iteration 3 -> outputs "4" ---
echo "=== Test 2: PASS verdict at iteration 3 ==="
setup_test_repo
make_loop_commit "plan" "3"
make_loop_commit "do-red" "3"
make_loop_commit "do-green" "3"
make_loop_commit "check" "3" "PASS"
RESULT=$("$DETECT_RESUME" 2>/dev/null)
assert_output_equals "after PASS iteration 3: output is 4" "$RESULT" "4"
cleanup

# --- Test 3: After FAIL verdict at iteration 2 -> outputs "3" ---
echo "=== Test 3: FAIL verdict at iteration 2 ==="
setup_test_repo
make_loop_commit "plan" "2"
make_loop_commit "do-red" "2"
make_loop_commit "do-green" "2"
make_loop_commit "check" "2" "FAIL"
RESULT=$("$DETECT_RESUME" 2>/dev/null)
assert_output_equals "after FAIL iteration 2: output is 3" "$RESULT" "3"
cleanup

# --- Test 4: Mid-iteration: plan committed but no do commit -> outputs same iteration ---
echo "=== Test 4: plan committed, DO pending ==="
setup_test_repo
make_loop_commit "plan" "2"
RESULT=$("$DETECT_RESUME" 2>/dev/null)
assert_output_equals "after plan iter 2: output is 2" "$RESULT" "2"
cleanup

# --- Test 5: Mid-iteration: do-red committed but no do-green -> outputs same iteration ---
echo "=== Test 5: do-red committed, GREEN pending ==="
setup_test_repo
make_loop_commit "plan" "2"
make_loop_commit "do-red" "2"
RESULT=$("$DETECT_RESUME" 2>/dev/null)
assert_output_equals "after do-red iter 2: output is 2" "$RESULT" "2"
cleanup

# --- Test 6: Mid-iteration: do-green committed but no check -> outputs same iteration ---
echo "=== Test 6: do-green committed, CHECK pending ==="
setup_test_repo
make_loop_commit "plan" "2"
make_loop_commit "do-red" "2"
make_loop_commit "do-green" "2"
RESULT=$("$DETECT_RESUME" 2>/dev/null)
assert_output_equals "after do-green iter 2: output is 2" "$RESULT" "2"
cleanup

# --- Test 7: do-simplify committed -> outputs same iteration ---
echo "=== Test 7: do-simplify committed ==="
setup_test_repo
make_loop_commit "plan" "2"
make_loop_commit "do-red" "2"
make_loop_commit "do-green" "2"
make_loop_commit "do-simplify" "2"
RESULT=$("$DETECT_RESUME" 2>/dev/null)
assert_output_equals "after do-simplify iter 2: output is 2" "$RESULT" "2"
cleanup

# --- Test 8: do-integration committed -> outputs same iteration ---
echo "=== Test 8: do-integration committed ==="
setup_test_repo
make_loop_commit "plan" "2"
make_loop_commit "do-red" "2"
make_loop_commit "do-green" "2"
make_loop_commit "do-simplify" "2"
make_loop_commit "do-integration" "2"
RESULT=$("$DETECT_RESUME" 2>/dev/null)
assert_output_equals "after do-integration iter 2: output is 2" "$RESULT" "2"
cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
