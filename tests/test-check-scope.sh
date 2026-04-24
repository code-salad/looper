#!/usr/bin/env bash
set -euo pipefail

# test-check-scope.sh — Corner-case tests for the check-scope helper.
# Sets up a throwaway git repo, creates commits, and asserts the helper's
# stdout/exit-code against expected-files lists with tolerance rules.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCOPE="$SCRIPT_DIR/../plugins/looper/skills/looper/scripts/check-scope"

if [ ! -x "$CHECK_SCOPE" ]; then
    echo "FAIL: $CHECK_SCOPE not found or not executable" >&2
    exit 1
fi

PASS=0
FAIL=0
TMPDIR_TEST=""

cleanup() {
    if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
        rm -rf "$TMPDIR_TEST"
    fi
}
trap cleanup EXIT

setup_repo() {
    TMPDIR_TEST="$(mktemp -d)"
    cd "$TMPDIR_TEST"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git commit --allow-empty -q -m "root"
}

teardown_repo() {
    cd /
    if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
        rm -rf "$TMPDIR_TEST"
    fi
    TMPDIR_TEST=""
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

assert_exit_two() {
    local description="$1"
    local exit_code="$2"
    if [ "$exit_code" -eq 2 ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected exit 2, got $exit_code)"
        FAIL=$((FAIL + 1))
    fi
}

assert_stdout_contains() {
    local description="$1"
    local output="$2"
    local expected="$3"
    if echo "$output" | grep -q -- "$expected"; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected stdout to contain '$expected')"
        echo "  Actual stdout: $output"
        FAIL=$((FAIL + 1))
    fi
}

assert_stdout_not_contains() {
    local description="$1"
    local output="$2"
    local unexpected="$3"
    if echo "$output" | grep -q -- "$unexpected"; then
        echo "FAIL: $description (stdout unexpectedly contains '$unexpected')"
        echo "  Actual stdout: $output"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $description"
        PASS=$((PASS + 1))
    fi
}

# --- Test 1: All changed files are expected -> exit 0 ---
echo "=== Test 1: All changed files within expected set ==="
setup_repo
mkdir -p src
echo "hello" > src/a.rs
echo "world" > src/b.rs
git add -A
git commit -q -m "green"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "src/a.rs,src/b.rs" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_zero "within-scope: exit 0" "$EC"
teardown_repo

# --- Test 2: Extra file outside expected -> exit 1 ---
echo "=== Test 2: Drift file ==="
setup_repo
mkdir -p src
echo "a" > src/a.rs
echo "b" > src/unrelated.rs
git add -A
git commit -q -m "green"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "src/a.rs" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_one "drift: exit 1" "$EC"
assert_stdout_contains "drift: lists drift file" "$OUTPUT" "src/unrelated.rs"
teardown_repo

# --- Test 3: Cargo.lock tolerated when Cargo.toml is expected ---
echo "=== Test 3: Cargo.lock companion tolerance ==="
setup_repo
echo "[package]" > Cargo.toml
echo "# lock" > Cargo.lock
git add -A
git commit -q -m "green"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "Cargo.toml" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_zero "Cargo.lock tolerated: exit 0" "$EC"
teardown_repo

# --- Test 4: package-lock.json tolerated when package.json is expected ---
echo "=== Test 4: package-lock.json companion tolerance ==="
setup_repo
echo "{}" > package.json
echo "{}" > package-lock.json
git add -A
git commit -q -m "green"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "package.json" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_zero "package-lock.json tolerated: exit 0" "$EC"
teardown_repo

# --- Test 5: pnpm-lock.yaml tolerated when package.json is expected ---
echo "=== Test 5: pnpm-lock.yaml companion tolerance ==="
setup_repo
echo "{}" > package.json
echo "lockfileVersion: 6.0" > pnpm-lock.yaml
git add -A
git commit -q -m "green"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "package.json" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_zero "pnpm-lock.yaml tolerated: exit 0" "$EC"
teardown_repo

# --- Test 6: Test files tolerated for expected source files ---
echo "=== Test 6: Test-file heuristic tolerance ==="
setup_repo
mkdir -p src tests
echo "fn foo() {}" > src/foo.rs
echo "// test" > tests/foo_test.rs
git add -A
git commit -q -m "green"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "src/foo.rs" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_zero "test file tolerated: exit 0" "$EC"
teardown_repo

# --- Test 7: Snapshot files alongside expected dir tolerated ---
echo "=== Test 7: Snapshot tolerance ==="
setup_repo
mkdir -p src/__snapshots__
echo "fn x() {}" > src/x.rs
echo "snap" > src/__snapshots__/x.snap
git add -A
git commit -q -m "green"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "src/x.rs" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_zero "snapshot tolerated: exit 0" "$EC"
teardown_repo

# --- Test 8: Glob pattern in expected set ---
echo "=== Test 8: Glob match in expected ==="
setup_repo
mkdir -p src
echo "a" > src/a.rs
echo "b" > src/b.rs
echo "c" > src/c.rs
git add -A
git commit -q -m "green"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "src/*.rs" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_zero "glob match: exit 0" "$EC"
teardown_repo

# --- Test 9: Directory-prefix expected matches nested path ---
echo "=== Test 9: Directory prefix match ==="
setup_repo
mkdir -p src/sub
echo "a" > src/sub/a.rs
echo "b" > src/sub/b.rs
git add -A
git commit -q -m "green"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "src/" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_zero "dir prefix match: exit 0" "$EC"
teardown_repo

# --- Test 10: Expected-files-file input works ---
echo "=== Test 10: --expected-files-file input ==="
setup_repo
mkdir -p src
echo "a" > src/a.rs
git add -A
git commit -q -m "green"
HASH=$(git rev-parse HEAD)
EXPFILE="$(mktemp)"
printf '# plan-list\nsrc/a.rs\n' > "$EXPFILE"
OUTPUT=$("$CHECK_SCOPE" --expected-files-file "$EXPFILE" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_zero "expected-files-file: exit 0" "$EC"
rm -f "$EXPFILE"
teardown_repo

# --- Test 11: Missing --commit flag -> exit 2 ---
echo "=== Test 11: Missing --commit ==="
setup_repo
OUTPUT=$("$CHECK_SCOPE" --expected-files "src/a.rs" 2>/dev/null) && EC=0 || EC=$?
assert_exit_two "missing --commit: exit 2" "$EC"
teardown_repo

# --- Test 12: Missing expected input -> exit 2 ---
echo "=== Test 12: Missing --expected-files and --expected-files-file ==="
setup_repo
OUTPUT=$("$CHECK_SCOPE" --commit HEAD 2>/dev/null) && EC=0 || EC=$?
assert_exit_two "missing expected: exit 2" "$EC"
teardown_repo

# --- Test 13: Multiple drift files all reported ---
echo "=== Test 13: Multiple drift files listed ==="
setup_repo
mkdir -p src
echo "a" > src/a.rs
echo "x" > src/x.rs
echo "y" > src/y.rs
git add -A
git commit -q -m "green"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "src/a.rs" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_one "multi drift: exit 1" "$EC"
assert_stdout_contains "multi drift: lists x" "$OUTPUT" "src/x.rs"
assert_stdout_contains "multi drift: lists y" "$OUTPUT" "src/y.rs"
assert_stdout_not_contains "multi drift: does NOT list a" "$OUTPUT" "src/a.rs"
teardown_repo

# --- Test 14: go.sum tolerated when go.mod is expected ---
echo "=== Test 14: go.sum companion tolerance ==="
setup_repo
echo "module x" > go.mod
echo "hash" > go.sum
git add -A
git commit -q -m "green"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "go.mod" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_zero "go.sum tolerated: exit 0" "$EC"
teardown_repo

# --- Test 15: Empty commit (no changes) -> exit 0 ---
echo "=== Test 15: Empty commit ==="
setup_repo
git commit --allow-empty -q -m "empty"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "anything" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_zero "empty commit: exit 0" "$EC"
teardown_repo

# --- Test 16: Unrelated test under tests/ is flagged as drift ---
echo "=== Test 16: Unrelated test file is drift ==="
setup_repo
mkdir -p src tests
echo "fn main() {}" > src/main.rs
echo "// unrelated" > tests/test_unrelated.sh
git add -A
git commit -q -m "drift"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "src/main.rs" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_one "unrelated test: exit 1" "$EC"
assert_stdout_contains "unrelated test: lists tests/test_unrelated.sh" "$OUTPUT" "tests/test_unrelated.sh"
teardown_repo

# --- Test 17: Test with a non-matching stem is flagged as drift ---
echo "=== Test 17: Misleading-stem test is drift ==="
setup_repo
mkdir -p src tests
echo "fn baz() {}" > src/baz.rs
echo "// unrelated name" > tests/test_misleading.sh
git add -A
git commit -q -m "drift"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "src/baz.rs" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_one "misleading stem: exit 1" "$EC"
assert_stdout_contains "misleading stem: lists tests/test_misleading.sh" "$OUTPUT" "tests/test_misleading.sh"
teardown_repo

# --- Test 18: Unrelated spec/ file is flagged as drift ---
echo "=== Test 18: Unrelated spec file is drift ==="
setup_repo
mkdir -p src spec
echo "fn x() {}" > src/x.rs
echo "// random spec" > spec/unrelated_spec.rb
git add -A
git commit -q -m "drift"
HASH=$(git rev-parse HEAD)
OUTPUT=$("$CHECK_SCOPE" --expected-files "src/x.rs" --commit "$HASH" 2>/dev/null) && EC=0 || EC=$?
assert_exit_one "unrelated spec: exit 1" "$EC"
assert_stdout_contains "unrelated spec: lists spec/unrelated_spec.rb" "$OUTPUT" "spec/unrelated_spec.rb"
teardown_repo

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
