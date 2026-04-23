#!/usr/bin/env bash
set -euo pipefail

# test-checker-structure.sh — Structural tests for checker.md and SKILL.md
# Verifies checker.md subagent count, summarizer removal, on-demand gh rules,
# and explicit model tiers for all agents.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
CHECKER_MD="$REPO_ROOT/plugins/looper/agents/checker.md"
SKILL_MD="$REPO_ROOT/plugins/looper/skills/looper/SKILL.md"
PLANNER_MD="$REPO_ROOT/plugins/looper/agents/planner.md"
SUMMARIZER_MD="$REPO_ROOT/plugins/looper/agents/summarizer.md"

PASS=0
FAIL=0

assert_true() {
    local description="$1"
    local condition="$2"
    if [ "$condition" = "true" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local description="$1"
    local file="$2"
    if [ -f "$file" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (file not found: $file)"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_not_exists() {
    local description="$1"
    local file="$2"
    if [ ! -f "$file" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (file unexpectedly exists: $file)"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_contains() {
    local description="$1"
    local file="$2"
    local pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (pattern '$pattern' not found in $file)"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_not_contains() {
    local description="$1"
    local file="$2"
    local pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $description (pattern '$pattern' found in $file but should not be)"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $description"
        PASS=$((PASS + 1))
    fi
}

assert_count_equals() {
    local description="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" -eq "$expected" ]; then
        echo "PASS: $description (count=$actual)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected $expected, got $actual)"
        FAIL=$((FAIL + 1))
    fi
}

# --- Test 1: checker.md has exactly 5 subagent definitions ---
echo "=== Test 1: checker.md has exactly 5 subagents ==="
assert_file_exists "checker.md exists" "$CHECKER_MD"

# Count "**Subagent N" definition headings (may have leading spaces)
subagent_count=$(grep -c "\*\*Subagent [0-9]" "$CHECKER_MD" 2>/dev/null || echo "0")
# Remove any trailing whitespace/newline from count
subagent_count=$(echo "$subagent_count" | tr -d '[:space:]')
assert_count_equals "checker.md has exactly 5 subagents" "$subagent_count" "5"

# --- Test 2: checker.md does not have Subagent 6 or 7 (but may have 5) ---
echo "=== Test 2: checker.md does not have Subagent 6 or 7 ==="
assert_file_not_contains "no Subagent 6 in checker.md" "$CHECKER_MD" "\*\*Subagent 6"
assert_file_not_contains "no Subagent 7 in checker.md" "$CHECKER_MD" "\*\*Subagent 7"

# --- Test 3: checker.md has the expected subagent names including Adversarial Reviewer ---
echo "=== Test 3: checker.md has the expected subagent names ==="
assert_file_contains "checker.md has Build & Types subagent" "$CHECKER_MD" "Build.*Types\|Types.*Build"
assert_file_contains "checker.md has Test & Coverage subagent" "$CHECKER_MD" "Test.*Coverage\|Coverage.*Test"
assert_file_contains "checker.md has Code Review subagent" "$CHECKER_MD" "Code Review"
assert_file_contains "checker.md has Runtime Verification subagent" "$CHECKER_MD" "Runtime Verification"
assert_file_contains "checker.md has Adversarial Reviewer subagent" "$CHECKER_MD" "Adversarial"

# --- Test 4: checker.md spawn command references 5 subagent output files ---
echo "=== Test 4: checker.md spawn command uses 5 parallel subagents ==="
assert_file_contains "checker.md spawns check-adversarial.txt" "$CHECKER_MD" "check-adversarial.txt"
assert_file_contains "checker.md spawns check-build.txt" "$CHECKER_MD" "check-build.txt"
assert_file_not_contains "checker.md does not spawn check7.txt" "$CHECKER_MD" "check7.txt"

# --- Test 5: SKILL.md has build-agent-context invocations for all three roles ---
echo "=== Test 5: SKILL.md has build-agent-context role invocations ==="
assert_file_exists "SKILL.md exists" "$SKILL_MD"
assert_file_contains "SKILL.md has build-agent-context planner invocation" "$SKILL_MD" "build-agent-context.*planner\|--role planner"
assert_file_contains "SKILL.md has build-agent-context doer invocation" "$SKILL_MD" "build-agent-context.*doer\|--role doer"
assert_file_contains "SKILL.md has build-agent-context checker invocation" "$SKILL_MD" "build-agent-context.*checker\|--role checker"

# --- Test 6: SKILL.md invokes pre-check before Checker spawn ---
echo "=== Test 6: SKILL.md invokes pre-check before Checker spawn ==="
assert_file_contains "SKILL.md invokes pre-check script" "$SKILL_MD" "pre-check"

# --- Test 7: summarizer.md agent file has been REMOVED ---
echo "=== Test 7: summarizer.md has been removed ==="
assert_file_not_exists "summarizer.md removed" "$SUMMARIZER_MD"

# --- Test 8: SKILL.md no longer references summarizer ---
echo "=== Test 8: SKILL.md no longer references summarizer ==="
assert_file_not_contains "SKILL.md no longer references summarizer" "$SKILL_MD" "summarizer"

# --- Test 9: planner.md instructs file snippet embedding ---
echo "=== Test 9: planner.md instructs file snippet embedding ==="
assert_file_exists "planner.md exists" "$PLANNER_MD"
assert_file_contains "planner.md instructs embedding small files" "$PLANNER_MD" "50 lines\|<50 lines\|embed"

# --- Test 10: SKILL.md has diff-only context for Checker on iteration N>1 ---
echo "=== Test 10: SKILL.md has diff-only context for Checker ==="
assert_file_contains "SKILL.md has DIFF_CONTEXT variable" "$SKILL_MD" "DIFF_CONTEXT"

# --- Test 11: planner.md has on-demand GitHub query rules section ---
echo "=== Test 11: planner.md has on-demand gh rules ==="
assert_file_contains "planner.md has Rules - Querying GitHub on demand" "$PLANNER_MD" "Rules.*Querying GitHub on demand\|Querying GitHub on demand"
assert_file_contains "planner.md has gh pr view example" "$PLANNER_MD" "gh pr view"
assert_file_contains "planner.md has gh api repos example" "$PLANNER_MD" "gh api repos"

# --- Test 12: Every agent has explicit model tier ---
echo "=== Test 12: All remaining agents have explicit model tier ==="
for f in "$REPO_ROOT"/plugins/looper/agents/*.md; do
    stem="$(basename "$f" .md)"
    if grep -Eq '^model: (haiku|sonnet|opus)$' "$f"; then
        echo "PASS: $stem has explicit model tier"
        PASS=$((PASS+1))
    else
        echo "FAIL: $stem missing explicit model tier"
        FAIL=$((FAIL+1))
    fi
done

# --- Test 13: check-build and check-tests demoted to haiku ---
echo "=== Test 13: check-build and check-tests have model: haiku ==="
assert_file_contains "check-build demoted to haiku" \
    "$REPO_ROOT/plugins/looper/agents/check-build.md" "^model: haiku$"
assert_file_contains "check-tests demoted to haiku" \
    "$REPO_ROOT/plugins/looper/agents/check-tests.md" "^model: haiku$"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
