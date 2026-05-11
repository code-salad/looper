#!/usr/bin/env bash
set -euo pipefail

# test-checker-structure.sh — Structural tests for the collapsed Checker.
# The 5 fan-out subagents (check-build, check-tests, check-code, check-runtime,
# check-adversarial) have been folded into a single two-pass review run by
# the Checker itself. This test pins the new shape.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
CHECKER_MD="$REPO_ROOT/plugins/looper/agents/checker.md"
PLANNER_MD="$REPO_ROOT/plugins/looper/agents/planner.md"
SKILL_MD="$REPO_ROOT/plugins/looper/skills/looper/SKILL.md"
AGENTS_DIR="$REPO_ROOT/plugins/looper/agents"

PASS=0
FAIL=0

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

# --- Test 1: No more **Subagent N** fan-out blocks in checker.md ---
echo "=== Test 1: checker.md no longer fans out to subagents ==="
assert_file_exists "checker.md exists" "$CHECKER_MD"
assert_file_not_contains "no '**Subagent 1' fan-out block in checker.md" "$CHECKER_MD" "\*\*Subagent 1"
assert_file_not_contains "no '**Subagent 5' fan-out block in checker.md" "$CHECKER_MD" "\*\*Subagent 5"
assert_file_not_contains "no check-build.txt parallel collector" "$CHECKER_MD" "check-build.txt"
assert_file_not_contains "no check-adversarial.txt parallel collector" "$CHECKER_MD" "check-adversarial.txt"

# --- Test 2: Two-pass structure is present ---
echo "=== Test 2: checker.md describes Pass 1 (attack) and Pass 2 (verify) ==="
assert_file_contains "checker.md mentions Pass 1" "$CHECKER_MD" "Pass 1"
assert_file_contains "checker.md mentions Pass 2" "$CHECKER_MD" "Pass 2"
assert_file_contains "checker.md mentions attack vectors" "$CHECKER_MD" "[Aa]ttack vector"
# Folded-in check-adversarial invariant: every finding must name a specific
# input + predicted failure (no generic "consider edge cases" advice).
# Without this, the attack pass collapses into a coverage checklist.
assert_file_contains "checker.md enforces specific-input findings" \
    "$CHECKER_MD" "specific input"
assert_file_contains "checker.md defines BLOCKER/WARNING severities" \
    "$CHECKER_MD" "Severity rules\|BLOCKER.*WARNING"

# --- Test 3: Checker runs the mechanical scripts directly ---
echo "=== Test 3: Checker runs all mechanical checks inline ==="
for script in run-tests run-typecheck run-build run-lint run-format security-scan; do
    assert_file_contains "checker.md invokes $script" "$CHECKER_MD" "$script"
done

# --- Test 4: Runtime check is now Pass 3 inline (not a subagent) ---
echo "=== Test 4: Runtime / integration testing is part of Pass 3 inline ==="
assert_file_contains "checker.md has Pass 3 runtime" "$CHECKER_MD" "Pass 3"
assert_file_contains "checker.md mentions run-integration-tests" "$CHECKER_MD" "run-integration-tests"
assert_file_not_contains "checker.md does not delegate to a runtime subagent" \
    "$CHECKER_MD" "looper:check-runtime"

# --- Test 5: SKILL.md still wires build-agent-context for all three roles ---
echo "=== Test 5: SKILL.md still calls build-agent-context for planner/doer/checker ==="
assert_file_exists "SKILL.md exists" "$SKILL_MD"
assert_file_contains "SKILL.md invokes build-agent-context for planner" \
    "$SKILL_MD" "build-agent-context.*planner\|--role planner"
assert_file_contains "SKILL.md invokes build-agent-context for doer" \
    "$SKILL_MD" "build-agent-context.*doer\|--role doer"
assert_file_contains "SKILL.md invokes build-agent-context for checker" \
    "$SKILL_MD" "build-agent-context.*checker\|--role checker"

# --- Test 6: SKILL.md keeps the mechanical pre-check bail-out ---
echo "=== Test 6: SKILL.md still invokes pre-check as a synthetic-FAIL bail-out ==="
assert_file_contains "SKILL.md invokes pre-check script" "$SKILL_MD" "pre-check"

# --- Test 7: Removed legacy agents are still gone ---
echo "=== Test 7: Legacy summarizer + fan-out agents remain removed ==="
for gone in summarizer check-build check-tests check-code check-runtime check-adversarial \
            plan-feasibility plan-completeness plan-scope simplifier; do
    assert_file_not_exists "$gone.md is removed" "$AGENTS_DIR/$gone.md"
done
assert_file_not_contains "SKILL.md no longer references summarizer" "$SKILL_MD" "summarizer"

# --- Test 8: Planner embedding instructions ---
echo "=== Test 8: planner.md instructs file-snippet embedding for small files ==="
assert_file_exists "planner.md exists" "$PLANNER_MD"
assert_file_contains "planner.md instructs embedding small files" \
    "$PLANNER_MD" "50 lines\|<50 lines\|embed"

# --- Test 9: SKILL.md keeps DIFF_CONTEXT plumbing for Checker on iter > 1 ---
echo "=== Test 9: SKILL.md keeps DIFF_CONTEXT plumbing ==="
assert_file_contains "SKILL.md has DIFF_CONTEXT variable" "$SKILL_MD" "DIFF_CONTEXT"

# --- Test 10: Every remaining agent has an explicit model tier ---
echo "=== Test 10: All remaining agents have explicit model tier ==="
for f in "$AGENTS_DIR"/*.md; do
    stem="$(basename "$f" .md)"
    if grep -Eq '^model: (haiku|sonnet|opus)$' "$f"; then
        echo "PASS: $stem has explicit model tier"
        PASS=$((PASS+1))
    else
        echo "FAIL: $stem missing explicit model tier"
        FAIL=$((FAIL+1))
    fi
done

# --- Test 11: Planner keeps on-demand GitHub query rules ---
echo "=== Test 11: planner.md keeps on-demand gh rules ==="
assert_file_contains "planner.md has 'Querying GitHub on demand' section" \
    "$PLANNER_MD" "Querying GitHub on demand"
assert_file_contains "planner.md has gh pr view example" "$PLANNER_MD" "gh pr view"
assert_file_contains "planner.md has gh api repos example" "$PLANNER_MD" "gh api repos"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
