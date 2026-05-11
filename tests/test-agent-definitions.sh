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

assert_line_count_le() {
    local description="$1"
    local file="$2"
    local max_lines="$3"
    local actual
    actual=$(wc -l < "$file" 2>/dev/null || echo "0")
    actual=$(echo "$actual" | tr -d '[:space:]')
    if [ "$actual" -le "$max_lines" ]; then
        echo "PASS: $description (lines=$actual, max=$max_lines)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (lines=$actual, expected <= $max_lines)"
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
# Bumped from 350 → 365 to accommodate the parallel-fanout run_in_background
# warning added after foreground `wait` was found to be SIGKILLed by the Bash
# 10-min timeout when reviewer subagents run 5–10+ min.
assert_line_count_lt "checker.md is under 365 lines (was 482)" "$CHECKER_MD" 365
# Use <= here: GitHub's squash-merge may add a trailing newline, bumping wc -l
# by 1 post-merge (see #97). Bumped 360 → 400 to accommodate the parallel-fanout
# run_in_background warning (see above).
assert_line_count_le "planner.md is at or under 400 lines (was 311, +89 for on-demand gh rules + issue context sub-sections + run_in_background warning)" "$PLANNER_MD" 400

# --- Test 11: simplifier.md agent exists with valid frontmatter ---
echo "=== Test 11: simplifier.md exists with valid frontmatter ==="
SIMPLIFIER_MD="$AGENTS_DIR/simplifier.md"
assert_file_exists "simplifier.md exists" "$SIMPLIFIER_MD"
if [ -f "$SIMPLIFIER_MD" ]; then
    first_line="$(head -1 "$SIMPLIFIER_MD" 2>/dev/null || echo "")"
    assert_true "simplifier.md starts with ---" "$([ "$first_line" = "---" ] && echo "true" || echo "false")"
    assert_file_contains "simplifier.md has name: simplifier" "$SIMPLIFIER_MD" "^name: simplifier$"
    assert_file_contains "simplifier.md has model: sonnet" "$SIMPLIFIER_MD" "^model: sonnet$"
    assert_file_contains "simplifier.md has tools: field" "$SIMPLIFIER_MD" "^tools:"
    assert_file_contains "simplifier.md tools include Read" "$SIMPLIFIER_MD" "^tools:.*Read"
    assert_file_contains "simplifier.md tools include Edit" "$SIMPLIFIER_MD" "^tools:.*Edit"
    assert_file_contains "simplifier.md tools include Bash" "$SIMPLIFIER_MD" "^tools:.*Bash"
    assert_file_contains "simplifier.md tools include Glob" "$SIMPLIFIER_MD" "^tools:.*Glob"
    assert_file_contains "simplifier.md tools include Grep" "$SIMPLIFIER_MD" "^tools:.*Grep"
    # Scope-awareness + verdict structure
    assert_file_contains "simplifier.md mentions Scope Guard" "$SIMPLIFIER_MD" "Scope Guard"
    assert_file_contains "simplifier.md defines APPLIED verdict" "$SIMPLIFIER_MD" "APPLIED"
    assert_file_contains "simplifier.md defines SKIPPED verdict" "$SIMPLIFIER_MD" "SKIPPED"
    assert_file_contains "simplifier.md defines REVERTED verdict" "$SIMPLIFIER_MD" "REVERTED"
fi

# --- Test 12: doer.md step numbering is unique (each step 1..16 appears once) ---
echo "=== Test 12: doer.md step numbers are unique ==="
DOER_MD="$AGENTS_DIR/doer.md"
if [ -f "$DOER_MD" ]; then
    dup_count=$(grep -oE '^[0-9]+\.' "$DOER_MD" | sort | uniq -d | wc -l)
    dup_count=$(echo "$dup_count" | tr -d '[:space:]')
    assert_true "doer.md has no duplicate step numbers (duplicates=$dup_count)" \
        "$([ "$dup_count" = "0" ] && echo "true" || echo "false")"
fi

# --- Test 13: doer.md references looper:simplifier (not general-purpose simplifier) ---
echo "=== Test 13: doer.md uses looper:simplifier subagent ==="
if [ -f "$DOER_MD" ]; then
    assert_file_contains "doer.md spawns looper:simplifier" "$DOER_MD" 'looper:simplifier'
    assert_file_not_contains "doer.md does not inline 'You are a code simplifier' prompt" \
        "$DOER_MD" "You are a code simplifier"
fi

# --- Test 14: doer.md mentions check-scope helper ---
echo "=== Test 14: doer.md invokes check-scope after GREEN ==="
if [ -f "$DOER_MD" ]; then
    assert_file_contains "doer.md references check-scope helper" "$DOER_MD" "check-scope"
fi

# --- Test 15: doer.md replaces '2 fix attempts' with delta-aware rule ---
echo "=== Test 15: doer.md smarter retry policy ==="
if [ -f "$DOER_MD" ]; then
    assert_file_contains "doer.md mentions error delta" "$DOER_MD" "Error delta\|error delta\|error prefix\|ERROR_DELTA"
    assert_file_contains "doer.md references per-iteration last-error scratch file" \
        "$DOER_MD" 'last-error-\${ITERATION}'
    assert_file_not_contains "doer.md no longer uses 'after 2 fix attempts' language" \
        "$DOER_MD" "after 2 fix attempts"
fi

# --- Test 16: parallel fan-out instructions require run_in_background=true ---
# Foreground `wait` for parallel claude-spawn-agent calls is SIGKILLed by the
# Bash tool's 10-min timeout (default 2 min). Reviewer subagents routinely
# take 5–10+ min, so the parallel-fanout pattern MUST be invoked with
# run_in_background=true. Regression test for that guidance.
echo "=== Test 16: parallel fan-out docs mention run_in_background=true ==="
SUBAGENTS_SKILL_MD="$REPO_ROOT/plugins/looper/skills/subagents/SKILL.md"
for doc in "$PLANNER_MD" "$CHECKER_MD" "$DOER_MD" "$SUBAGENTS_SKILL_MD"; do
    basename_doc="$(basename "$doc")"
    assert_file_contains "$basename_doc parallel-fanout docs reference run_in_background=true" \
        "$doc" "run_in_background=true"
done

# --- Test 17: spawn-agent captures stderr instead of suppressing it ---
# Suppressing claude's stderr with `2>/dev/null` hides why a child session
# failed, making parallel fan-out failures impossible to diagnose. spawn-agent
# must capture claude's stderr to a file and surface it when JSON output is
# missing.
echo "=== Test 17: spawn-agent captures stderr for diagnostics ==="
SPAWN_AGENT="$REPO_ROOT/plugins/looper/skills/subagents/scripts/spawn-agent"
if [ -f "$SPAWN_AGENT" ]; then
    assert_file_contains "spawn-agent captures claude stderr to ERRFILE" \
        "$SPAWN_AGENT" 'ERRFILE'
    assert_file_contains "spawn-agent redirects claude stderr to ERRFILE" \
        "$SPAWN_AGENT" '2>"\$ERRFILE"'
    assert_file_contains "spawn-agent surfaces stderr on missing JSON output" \
        "$SPAWN_AGENT" 'claude stderr'
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
