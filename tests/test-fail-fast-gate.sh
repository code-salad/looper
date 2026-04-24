#!/usr/bin/env bash
set -euo pipefail

# test-fail-fast-gate.sh — Regression tests for the step-0 fail-fast gate in SKILL.md
# Verifies that looper aborts cleanly when claude-spawn-agent is absent from PATH,
# the hard-negative "never inline" rule is present, and the note propagates to agents.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
THIS_BASH="${BASH:-/usr/bin/bash}"  # full path to bash (for PATH-isolation tests)
SKILL_MD="$REPO_ROOT/plugins/looper/skills/looper/SKILL.md"
PLANNER_MD="$REPO_ROOT/plugins/looper/agents/planner.md"
DOER_MD="$REPO_ROOT/plugins/looper/agents/doer.md"
CHECKER_MD="$REPO_ROOT/plugins/looper/agents/checker.md"

PASS=0
FAIL=0

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

assert_eq() {
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

assert_not_eq() {
    local description="$1"
    local actual="$2"
    local unexpected="$3"
    if [ "$actual" != "$unexpected" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (value should not be '$unexpected', but it was)"
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

# Extract the step-0 gate snippet from SKILL.md — exercises the live source of truth.
# Finds the first fenced bash block containing 'command -v claude-spawn-agent'.
GATE_SNIPPET=$(awk '
    /^```bash$/ { in_block=1; buf=""; next }
    /^```$/ && in_block {
        if (buf ~ /command -v claude-spawn-agent/) { printf "%s", buf; exit }
        in_block=0; next
    }
    in_block { buf = buf $0 "\n" }
' "$SKILL_MD")

# --- Test 1: SKILL.md contains a step-0 gate snippet ---
echo "=== Test 1: SKILL.md contains a step-0 gate snippet ==="

# 1a. The gate command is present
if grep -q 'command -v claude-spawn-agent' "$SKILL_MD"; then
    echo "PASS: SKILL.md contains 'command -v claude-spawn-agent'"
    PASS=$((PASS + 1))
else
    echo "FAIL: SKILL.md does not contain 'command -v claude-spawn-agent'"
    FAIL=$((FAIL + 1))
fi

# 1b. A ### 0. heading exists whose text mentions subagent dispatch or claude-spawn-agent
if grep -qE '^### 0\.' "$SKILL_MD"; then
    echo "PASS: SKILL.md has a '### 0.' heading"
    PASS=$((PASS + 1))
else
    echo "FAIL: SKILL.md does not have a '### 0.' heading"
    FAIL=$((FAIL + 1))
fi

HEADING_0_TEXT=$(grep -E '^### 0\.' "$SKILL_MD" || true)
if echo "$HEADING_0_TEXT" | grep -qiE 'subagent dispatch|claude-spawn-agent'; then
    echo "PASS: '### 0.' heading mentions 'subagent dispatch' or 'claude-spawn-agent'"
    PASS=$((PASS + 1))
else
    echo "FAIL: '### 0.' heading does not mention 'subagent dispatch' or 'claude-spawn-agent'"
    echo "  Heading text: $HEADING_0_TEXT"
    FAIL=$((FAIL + 1))
fi

# 1c. The ### 0. heading's line number is less than all other numbered step headings (### N.)
# This confirms it is the first step — non-step subsections (### Never run...) are excluded.
HEADING_0_LINE=$(grep -n '^### 0\.' "$SKILL_MD" | head -1 | cut -d: -f1 || true)
if [ -z "$HEADING_0_LINE" ]; then
    echo "FAIL: Could not find '### 0.' heading in SKILL.md"
    FAIL=$((FAIL + 1))
else
    # Get all other numbered step headings (### N. ...) excluding ### 0. itself
    OTHER_STEP_HEADINGS=$(grep -n '^### [0-9]' "$SKILL_MD" | grep -v '^'"$HEADING_0_LINE"':' || true)
    ALL_BEFORE=true
    while IFS= read -r line; do
        if [ -z "$line" ]; then continue; fi
        OTHER_LINE=$(echo "$line" | cut -d: -f1)
        if [ -n "$OTHER_LINE" ] && [ "$OTHER_LINE" -le "$HEADING_0_LINE" ]; then
            ALL_BEFORE=false
            echo "FAIL: Found numbered step heading at line $OTHER_LINE which is not after '### 0.' at line $HEADING_0_LINE"
            echo "  Heading: $line"
            break
        fi
    done <<< "$OTHER_STEP_HEADINGS"
    if [ "$ALL_BEFORE" = "true" ]; then
        echo "PASS: '### 0.' heading (line $HEADING_0_LINE) appears before all other numbered step headings"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
fi

# --- Test 2: Step-0 gate aborts with specific message when claude-spawn-agent is absent ---
echo ""
echo "=== Test 2: Gate aborts with specific message when claude-spawn-agent is absent ==="

if [ -z "$GATE_SNIPPET" ]; then
    echo "FAIL: could not extract step-0 gate snippet from SKILL.md — all test 2/3 subtests skipped"
    FAIL=$((FAIL + 1))
else
    echo "PASS: step-0 gate snippet extracted from SKILL.md"
    PASS=$((PASS + 1))

    TMP_EMPTY_PATH=$(mktemp -d)
    set +e
    OUTPUT=$(PATH="$TMP_EMPTY_PATH" "$THIS_BASH" -c "$GATE_SNIPPET" 2>&1)
    EXIT=$?
    set -e
    rmdir "$TMP_EMPTY_PATH"

    assert_not_eq "gate exits non-zero when claude-spawn-agent is absent" "$EXIT" "0"
    assert_output_contains "gate output contains 'ERROR:'" "$OUTPUT" "ERROR:"
    assert_output_contains "gate output contains 'claude-spawn-agent not found'" "$OUTPUT" "claude-spawn-agent not found"
    assert_output_contains "gate output contains 'Cannot run /looper'" "$OUTPUT" "Cannot run /looper"
fi

# --- Test 3: Step-0 gate passes silently when claude-spawn-agent IS on PATH ---
echo ""
echo "=== Test 3: Gate passes silently when claude-spawn-agent IS on PATH ==="

if [ -z "$GATE_SNIPPET" ]; then
    echo "SKIP: gate snippet not available — skipping test 3"
else
    TMP_SHIM_DIR=$(mktemp -d)
    cat > "$TMP_SHIM_DIR/claude-spawn-agent" << 'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
    chmod +x "$TMP_SHIM_DIR/claude-spawn-agent"

    set +e
    OUTPUT=$(PATH="$TMP_SHIM_DIR:$PATH" "$THIS_BASH" -c "$GATE_SNIPPET" 2>&1)
    EXIT=$?
    set -e
    rm -rf "$TMP_SHIM_DIR"

    assert_exit_zero "gate exits 0 when claude-spawn-agent is on PATH" "$EXIT"
    assert_eq "gate produces no output when claude-spawn-agent is present" "$OUTPUT" ""
fi

# --- Test 4: Hard-negative rule "Never run the PDC loop inline" is present and prominent ---
echo ""
echo "=== Test 4: Hard-negative rule is present and prominent in SKILL.md ==="

if grep -q 'Never run the PDC loop inline' "$SKILL_MD"; then
    echo "PASS: SKILL.md contains 'Never run the PDC loop inline'"
    PASS=$((PASS + 1))
else
    echo "FAIL: SKILL.md does not contain 'Never run the PDC loop inline'"
    FAIL=$((FAIL + 1))
fi

# The rule must appear AFTER "## Agent spawning mode" and BEFORE "If the \`Agent\` tool is in your toolset"
AGENT_SPAWN_LINE=$(grep -n '^## Agent spawning mode' "$SKILL_MD" | head -1 | cut -d: -f1 || true)
NEVER_INLINE_LINE=$(grep -n 'Never run the PDC loop inline' "$SKILL_MD" | head -1 | cut -d: -f1 || true)
# shellcheck disable=SC2016  # backticks here are literal grep text, not command substitutions
AGENT_TOOL_PATTERN='If the `Agent` tool is in your toolset'
AGENT_TOOL_LINE=$(grep -n "$AGENT_TOOL_PATTERN" "$SKILL_MD" | head -1 | cut -d: -f1 || true)

if [ -z "$AGENT_SPAWN_LINE" ]; then
    echo "FAIL: Could not find '## Agent spawning mode' heading in SKILL.md"
    FAIL=$((FAIL + 1))
elif [ -z "$NEVER_INLINE_LINE" ]; then
    echo "FAIL: Could not find 'Never run the PDC loop inline' in SKILL.md"
    FAIL=$((FAIL + 1))
elif [ -z "$AGENT_TOOL_LINE" ]; then
    echo "FAIL: Could not find 'If the Agent tool is in your toolset' in SKILL.md"
    FAIL=$((FAIL + 1))
else
    if [ "$NEVER_INLINE_LINE" -gt "$AGENT_SPAWN_LINE" ]; then
        echo "PASS: 'Never run the PDC loop inline' (line $NEVER_INLINE_LINE) is after '## Agent spawning mode' (line $AGENT_SPAWN_LINE)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: 'Never run the PDC loop inline' (line $NEVER_INLINE_LINE) is NOT after '## Agent spawning mode' (line $AGENT_SPAWN_LINE)"
        FAIL=$((FAIL + 1))
    fi
    if [ "$NEVER_INLINE_LINE" -lt "$AGENT_TOOL_LINE" ]; then
        echo "PASS: 'Never run the PDC loop inline' (line $NEVER_INLINE_LINE) is before 'If the Agent tool...' (line $AGENT_TOOL_LINE)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: 'Never run the PDC loop inline' (line $NEVER_INLINE_LINE) is NOT before 'If the Agent tool...' (line $AGENT_TOOL_LINE)"
        FAIL=$((FAIL + 1))
    fi
fi

# --- Test 5: Each agent prompt carries the propagated note ---
echo ""
echo "=== Test 5: Each agent prompt carries the propagated 'Never improvise PDC work inline' note ==="

for agent_file in "$PLANNER_MD" "$DOER_MD" "$CHECKER_MD"; do
    agent_name=$(basename "$agent_file")

    # 5a. The phrase exists
    if grep -q 'Never improvise PDC work inline' "$agent_file"; then
        echo "PASS: $agent_name contains 'Never improvise PDC work inline'"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $agent_name does NOT contain 'Never improvise PDC work inline'"
        FAIL=$((FAIL + 1))
    fi

    # 5b. The "Never improvise" line appears AFTER the ## Instructions heading
    INSTRUCTIONS_LINE=$(grep -n '^## Instructions' "$agent_file" | head -1 | cut -d: -f1 || true)
    IMPROVISE_LINE=$(grep -n 'Never improvise PDC work inline' "$agent_file" | head -1 | cut -d: -f1 || true)

    if [ -z "$INSTRUCTIONS_LINE" ]; then
        echo "FAIL: $agent_name does not have a '## Instructions' heading"
        FAIL=$((FAIL + 1))
    elif [ -z "$IMPROVISE_LINE" ]; then
        echo "SKIP: $agent_name 'Never improvise' line not found (already failed above)"
    else
        if [ "$IMPROVISE_LINE" -gt "$INSTRUCTIONS_LINE" ]; then
            echo "PASS: $agent_name 'Never improvise' (line $IMPROVISE_LINE) is after '## Instructions' (line $INSTRUCTIONS_LINE)"
            PASS=$((PASS + 1))
        else
            echo "FAIL: $agent_name 'Never improvise' (line $IMPROVISE_LINE) is NOT after '## Instructions' (line $INSTRUCTIONS_LINE)"
            FAIL=$((FAIL + 1))
        fi
    fi
done

# --- Test 6: Gate snippet is side-effect-free on failure ---
echo ""
echo "=== Test 6: Gate snippet contains no side-effect code ==="

if [ -z "$GATE_SNIPPET" ]; then
    echo "FAIL: gate snippet not available — cannot check for side effects"
    FAIL=$((FAIL + 1))
else
    FORBIDDEN_TOKENS=("setup-worktree" "fetch-issue-context" "git worktree" "gh issue" "git commit")
    ALL_CLEAN=true
    for token in "${FORBIDDEN_TOKENS[@]}"; do
        if echo "$GATE_SNIPPET" | grep -q "$token"; then
            echo "FAIL: gate snippet contains forbidden side-effect token: '$token'"
            FAIL=$((FAIL + 1))
            ALL_CLEAN=false
        fi
    done
    if [ "$ALL_CLEAN" = "true" ]; then
        echo "PASS: gate snippet contains no forbidden side-effect tokens"
        PASS=$((PASS + 1))
    fi
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
