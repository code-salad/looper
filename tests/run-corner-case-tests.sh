#!/usr/bin/env bash
set -euo pipefail

# run-corner-case-tests.sh — Run all corner-case tests for looper scripts
# Executes: test-detect-stack.sh, test-detect-resume.sh,
#           test-git-commit-loop-validation.sh, test-git-loop-context.sh,
#           test-sync-with-remote.sh, test-check-blocked.sh,
#           test-check-scope.sh,
#           test-fetch-issue-context.sh, test-build-agent-context.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0

run_suite() {
    local name="$1"
    local file="$SCRIPT_DIR/$name"
    echo "=============================="
    echo "Running: $name"
    echo "=============================="
    if bash "$file"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
    echo ""
}

run_suite "test-detect-stack.sh"
run_suite "test-detect-resume.sh"
run_suite "test-git-commit-loop-validation.sh"
run_suite "test-git-loop-context.sh"
run_suite "test-sync-with-remote.sh"
run_suite "test-check-blocked.sh"
run_suite "test-check-scope.sh"
run_suite "test-fetch-issue-context.sh"
run_suite "test-build-agent-context.sh"
run_suite "test-resolve-plan-pointers.sh"
run_suite "test-delta-mode-prompts.sh"

echo "=============================="
echo "Corner-case suite: $PASS suites passed, $FAIL suites failed"
echo "=============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
