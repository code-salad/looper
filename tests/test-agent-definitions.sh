#!/usr/bin/env bash
set -euo pipefail

# test-agent-definitions.sh — Tests for extracted subagent agent definitions
# Verifies that 7 new agent files exist with valid frontmatter, that
# checker.md and planner.md no longer inline prompt templates, and that
# output files are namespaced by TASK_NAME.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
AGENTS_DIR="$REPO_ROOT/plugins/looper/agents"
CHECKER_MD="$AGENTS_DIR/checker.md"
PLANNER_MD="$AGENTS_DIR/planner.md"

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

assert_line_count_lt() {
    local description="$1"
    local file="$2"
    local max_lines="$3"
    local actual
    actual=$(wc -l < "$file" 2>/dev/null || echo "0")
    actual=$(echo "$actual" | tr -d '[:space:]')
    if [ "$actual" -lt "$max_lines" ]; then
        echo "PASS: $description (lines=$actual, max=$max_lines)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (lines=$actual, expected < $max_lines)"
        FAIL=$((FAIL + 1))
    fi
}

# --- Test 1: All 7 new agent files exist ---
echo "=== Test 1: All 7 new agent files exist ==="
assert_file_exists "check-build.md exists" "$AGENTS_DIR/check-build.md"
assert_file_exists "check-tests.md exists" "$AGENTS_DIR/check-tests.md"
assert_file_exists "check-code.md exists" "$AGENTS_DIR/check-code.md"
assert_file_exists "check-runtime.md exists" "$AGENTS_DIR/check-runtime.md"
assert_file_exists "plan-feasibility.md exists" "$AGENTS_DIR/plan-feasibility.md"
assert_file_exists "plan-completeness.md exists" "$AGENTS_DIR/plan-completeness.md"
assert_file_exists "plan-scope.md exists" "$AGENTS_DIR/plan-scope.md"

# --- Test 2: Each file has valid YAML frontmatter ---
echo "=== Test 2: Each agent file has valid YAML frontmatter (name, description, tools, model) ==="
for agent_file in \
    "$AGENTS_DIR/check-build.md" \
    "$AGENTS_DIR/check-tests.md" \
    "$AGENTS_DIR/check-code.md" \
    "$AGENTS_DIR/check-runtime.md" \
    "$AGENTS_DIR/plan-feasibility.md" \
    "$AGENTS_DIR/plan-completeness.md" \
    "$AGENTS_DIR/plan-scope.md"; do
    basename_file="$(basename "$agent_file")"
    # Check frontmatter starts on line 1
    first_line="$(head -1 "$agent_file" 2>/dev/null || echo "")"
    assert_true "$basename_file starts with ---" "$([ "$first_line" = "---" ] && echo "true" || echo "false")"
    assert_file_contains "$basename_file has 'name:' field" "$agent_file" "^name:"
    assert_file_contains "$basename_file has 'description:' field" "$agent_file" "^description:"
    assert_file_contains "$basename_file has 'tools:' field" "$agent_file" "^tools:"
    assert_file_contains "$basename_file has 'model:' field" "$agent_file" "^model:"
done

# --- Test 3: Name field matches filename stem ---
echo "=== Test 3: name field in frontmatter matches filename stem ==="
for agent_file in \
    "$AGENTS_DIR/check-build.md" \
    "$AGENTS_DIR/check-tests.md" \
    "$AGENTS_DIR/check-code.md" \
    "$AGENTS_DIR/check-runtime.md" \
    "$AGENTS_DIR/plan-feasibility.md" \
    "$AGENTS_DIR/plan-completeness.md" \
    "$AGENTS_DIR/plan-scope.md"; do
    stem="${agent_file%.md}"
    stem="$(basename "$stem")"
    assert_file_contains "$stem: name field matches filename" "$agent_file" "^name: ${stem}$"
done

# --- Test 4: check-runtime has Skill in tools; others do not ---
echo "=== Test 4: check-runtime has Skill tool; others do not ==="
assert_file_contains "check-runtime.md has Skill in tools" "$AGENTS_DIR/check-runtime.md" "Skill"
for agent_file in \
    "$AGENTS_DIR/check-build.md" \
    "$AGENTS_DIR/check-tests.md" \
    "$AGENTS_DIR/check-code.md" \
    "$AGENTS_DIR/plan-feasibility.md" \
    "$AGENTS_DIR/plan-completeness.md" \
    "$AGENTS_DIR/plan-scope.md"; do
    basename_file="$(basename "$agent_file")"
    assert_file_not_contains "$basename_file does not have Skill in tools line" "$agent_file" "^tools:.*Skill"
done

# --- Test 5: Severity format present in each agent file ---
echo "=== Test 5: Each agent file contains severity format indicators ==="
for agent_file in \
    "$AGENTS_DIR/check-build.md" \
    "$AGENTS_DIR/check-tests.md" \
    "$AGENTS_DIR/check-code.md" \
    "$AGENTS_DIR/check-runtime.md" \
    "$AGENTS_DIR/plan-feasibility.md" \
    "$AGENTS_DIR/plan-completeness.md" \
    "$AGENTS_DIR/plan-scope.md"; do
    basename_file="$(basename "$agent_file")"
    assert_file_contains "$basename_file contains BLOCKER severity" "$agent_file" "BLOCKER"
    assert_file_contains "$basename_file contains WARNING severity" "$agent_file" "WARNING"
done

# --- Test 6: Report format (Issues Found + Summary) present in each agent file ---
echo "=== Test 6: Each agent file contains 'Issues Found' and 'Summary' sections ==="
for agent_file in \
    "$AGENTS_DIR/check-build.md" \
    "$AGENTS_DIR/check-tests.md" \
    "$AGENTS_DIR/check-code.md" \
    "$AGENTS_DIR/check-runtime.md" \
    "$AGENTS_DIR/plan-feasibility.md" \
    "$AGENTS_DIR/plan-completeness.md" \
    "$AGENTS_DIR/plan-scope.md"; do
    basename_file="$(basename "$agent_file")"
    assert_file_contains "$basename_file contains 'Issues Found'" "$agent_file" "Issues Found"
    assert_file_contains "$basename_file contains 'Summary'" "$agent_file" "Summary"
done

# --- Test 7: Inline prompt template removed from checker.md ---
echo "=== Test 7: checker.md does not contain old inline prompt template ==="
assert_file_not_contains "checker.md no longer has inline subagent prompt template" \
    "$CHECKER_MD" "You are a review subagent for the Checker"

# --- Test 8: Inline prompt template removed from planner.md ---
echo "=== Test 8: planner.md does not contain old inline prompt template ==="
assert_file_not_contains "planner.md no longer has inline subagent prompt template" \
    "$PLANNER_MD" "You are a plan review subagent for the Planner"

# --- Test 9: TASK_NAME namespacing used in checker.md and planner.md ---
echo "=== Test 9: checker.md and planner.md use /tmp/looper-\${TASK_NAME}/ namespacing ==="
assert_file_contains "checker.md uses TASK_NAME-namespaced tmpdir" \
    "$CHECKER_MD" '/tmp/looper-\${TASK_NAME}'
assert_file_contains "planner.md uses TASK_NAME-namespaced tmpdir" \
    "$PLANNER_MD" '/tmp/looper-\${TASK_NAME}'

# --- Test 10: Line count reduction ---
echo "=== Test 10: checker.md and planner.md are significantly shorter ==="
assert_line_count_lt "checker.md is under 350 lines (was 482)" "$CHECKER_MD" 350
assert_line_count_lt "planner.md is under 270 lines (was 311)" "$PLANNER_MD" 270

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
