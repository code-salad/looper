#!/usr/bin/env bash
set -euo pipefail

# test-agent-definitions.sh — Tests for the collapsed agent architecture.
# The three PDC agents (planner, doer, checker) now do their own work
# inline — no more plan-review or check-* fan-out subagents.
# Only the on-demand utility agents (debugger, gh-issue-creator) remain.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
AGENTS_DIR="$REPO_ROOT/plugins/looper/agents"

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

# --- Test 1: Collapsed agent set — exactly 5 agent files ---
echo "=== Test 1: Agent set is the collapsed 5: planner, doer, checker, debugger, gh-issue-creator ==="
for keeper in planner doer checker debugger gh-issue-creator; do
    assert_file_exists "$keeper.md exists" "$AGENTS_DIR/$keeper.md"
done

# --- Test 2: Obsolete fan-out agents are removed ---
echo "=== Test 2: Obsolete fan-out agents have been removed ==="
for gone in check-build check-tests check-code check-runtime check-adversarial \
            plan-feasibility plan-completeness plan-scope simplifier summarizer; do
    assert_file_not_exists "$gone.md is removed" "$AGENTS_DIR/$gone.md"
done

# --- Test 3: Each kept agent has valid frontmatter ---
echo "=== Test 3: Each agent file has valid YAML frontmatter (name, description, tools, model) ==="
for keeper in planner doer checker debugger gh-issue-creator; do
    f="$AGENTS_DIR/$keeper.md"
    first_line="$(head -1 "$f" 2>/dev/null || echo "")"
    assert_true "$keeper.md starts with ---" "$([ "$first_line" = "---" ] && echo "true" || echo "false")"
    assert_file_contains "$keeper.md has 'name:' field" "$f" "^name:"
    assert_file_contains "$keeper.md has 'description:' field" "$f" "^description:"
    assert_file_contains "$keeper.md has 'tools:' field" "$f" "^tools:"
    assert_file_contains "$keeper.md has 'model:' field" "$f" "^model:"
    assert_file_contains "$keeper.md name matches filename" "$f" "^name: ${keeper}$"
done

# --- Test 4: Model tiers are explicit and from the allowed set ---
echo "=== Test 4: All agents declare an allowed model tier ==="
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

# --- Test 5: Planner stays read-only (no Write/Edit tools) ---
echo "=== Test 5: Planner has Read/Glob/Grep/Bash and disallows Write/Edit ==="
assert_file_contains "planner declares disallowedTools" "$AGENTS_DIR/planner.md" "^disallowedTools:"
assert_file_contains "planner disallows Write" "$AGENTS_DIR/planner.md" "^disallowedTools:.*Write"
assert_file_contains "planner disallows Edit" "$AGENTS_DIR/planner.md" "^disallowedTools:.*Edit"

# --- Test 6: Checker no longer spawns the 5 review subagents ---
echo "=== Test 6: Checker does not spawn deleted check-* subagents ==="
for gone in check-build check-tests check-code check-runtime check-adversarial; do
    assert_file_not_contains "checker.md does not spawn $gone" \
        "$AGENTS_DIR/checker.md" "looper:$gone"
done
# The two-pass language replaces the fan-out
assert_file_contains "checker.md describes Pass 1 (attack)" "$AGENTS_DIR/checker.md" "Pass 1"
assert_file_contains "checker.md describes Pass 2 (verify)" "$AGENTS_DIR/checker.md" "Pass 2"

# --- Test 7: Planner no longer spawns the 3 plan-review subagents ---
echo "=== Test 7: Planner does not spawn deleted plan-* subagents ==="
for gone in plan-feasibility plan-completeness plan-scope; do
    assert_file_not_contains "planner.md does not spawn $gone" \
        "$AGENTS_DIR/planner.md" "looper:$gone"
done
# Self-review replaces the fan-out
assert_file_contains "planner.md mentions self-review" "$AGENTS_DIR/planner.md" "[Ss]elf-review"

# --- Test 8: Doer no longer spawns the simplifier subagent ---
echo "=== Test 8: Doer does not spawn looper:simplifier; simplify is inline ==="
# The doer prompt may mention "looper:simplifier" in a "Do NOT spawn" rule;
# we only want to fail if it appears as an actual claude-spawn-agent call.
assert_file_not_contains "doer.md does not invoke claude-spawn-agent looper:simplifier" \
    "$AGENTS_DIR/doer.md" 'claude-spawn-agent "looper:simplifier\|claude-spawn-agent looper:simplifier'
assert_file_contains "doer.md mentions inline simplify" "$AGENTS_DIR/doer.md" "[Ss]implify inline"
# The simplifier subagent's iron law was "revert on test break". That guard
# now lives inline in the Doer — pin it so a refactor can't silently drop
# the self-revert behavior.
assert_file_contains "doer.md describes simplify-revert on test failure" \
    "$AGENTS_DIR/doer.md" "revert the simplify\|checkout -- <files-you-touched"
assert_file_contains "doer.md preserves an iron-law-style invariant for simplify" \
    "$AGENTS_DIR/doer.md" "[Ii]ron law"

# --- Test 9: Plan embeds tests (TDD red phase is copy-paste, not write) ---
echo "=== Test 9: Planner embeds tests in plan body; Doer copies them ==="
assert_file_contains "planner.md instructs embedding test code blocks" \
    "$AGENTS_DIR/planner.md" "[Tt]ests to write first\|embedded tests"
assert_file_contains "doer.md describes pasting embedded tests" \
    "$AGENTS_DIR/doer.md" "[Cc]opy embedded tests\|paste them"
# The collapsed TDD contract: Doer copies, does NOT invent tests. Pin this
# explicitly so the rule survives future trims.
assert_file_contains "doer.md forbids inventing tests" \
    "$AGENTS_DIR/doer.md" "Do NOT invent tests\|do not invent tests"

# --- Test 10: Doer keeps RED→GREEN sequence (TDD is preserved) ---
echo "=== Test 10: Doer commits do-red and do-green; no do-simplify or do-integration ==="
assert_file_contains "doer.md commits do-red phase" "$AGENTS_DIR/doer.md" 'phase "do-red"'
assert_file_contains "doer.md commits do-green phase" "$AGENTS_DIR/doer.md" 'phase "do-green"'
assert_file_not_contains "doer.md no longer commits do-simplify" \
    "$AGENTS_DIR/doer.md" 'phase "do-simplify"'
assert_file_not_contains "doer.md no longer commits do-integration" \
    "$AGENTS_DIR/doer.md" 'phase "do-integration"'

# --- Test 11: Delta-mode pointer resolution still wired up ---
echo "=== Test 11: Delta-mode pointer resolution survives the collapse ==="
assert_file_contains "planner.md mentions delta-mode planning" \
    "$AGENTS_DIR/planner.md" "[Dd]elta-mode planning"
assert_file_contains "planner.md mentions resolve-plan-pointers helper" \
    "$AGENTS_DIR/planner.md" "resolve-plan-pointers"
assert_file_contains "doer.md resolves pointers before acting" \
    "$AGENTS_DIR/doer.md" "resolve-plan-pointers"
assert_file_contains "checker.md resolves pointers before reviewing" \
    "$AGENTS_DIR/checker.md" "resolve-plan-pointers"

# --- Test 12: Checker is downgraded to sonnet; planner stays opus ---
echo "=== Test 12: Model tiers were tuned (checker → sonnet, planner stays opus) ==="
assert_file_contains "checker.md uses sonnet" "$AGENTS_DIR/checker.md" "^model: sonnet$"
assert_file_contains "planner.md stays on opus" "$AGENTS_DIR/planner.md" "^model: opus$"
assert_file_contains "doer.md uses sonnet" "$AGENTS_DIR/doer.md" "^model: sonnet$"

# --- Test 13: Doer's smarter retry policy is preserved ---
echo "=== Test 13: Doer keeps error-delta-aware retry policy ==="
assert_file_contains "doer.md mentions ERROR_DELTA" "$AGENTS_DIR/doer.md" "ERROR_DELTA\|error delta\|error prefix"
assert_file_contains "doer.md references per-iteration scratch file" \
    "$AGENTS_DIR/doer.md" 'last-error-\${ITERATION}'
assert_file_not_contains "doer.md no longer uses 'after 2 fix attempts' language" \
    "$AGENTS_DIR/doer.md" "after 2 fix attempts"

# --- Test 14: Doer keeps scope-creep check via check-scope ---
echo "=== Test 14: Doer invokes check-scope after GREEN ==="
assert_file_contains "doer.md references check-scope helper" \
    "$AGENTS_DIR/doer.md" "check-scope"

# --- Test 15: Step numbers in doer.md are unique ---
echo "=== Test 15: doer.md step numbers are unique ==="
dup_count=$(grep -oE '^[0-9]+\.' "$AGENTS_DIR/doer.md" | sort | uniq -d | wc -l)
dup_count=$(echo "$dup_count" | tr -d '[:space:]')
assert_true "doer.md has no duplicate step numbers (duplicates=$dup_count)" \
    "$([ "$dup_count" = "0" ] && echo "true" || echo "false")"

# --- Test 16: parallel fan-out instructions require run_in_background=true ---
# Foreground `wait` for parallel claude-spawn-agent calls is SIGKILLed by the
# Bash tool's 10-min timeout (default 2 min). Reviewer subagents routinely
# take 5–10+ min, so the parallel-fanout pattern MUST be invoked with
# run_in_background=true. (Inherited from #109; survives the collapse since
# planner + doer still fan out Explore subagents and Checker still spawns
# gh-issue-creator fire-and-forget.)
echo "=== Test 16: parallel fan-out docs require run_in_background=true ==="
SUBAGENTS_SKILL_MD="$REPO_ROOT/plugins/looper/skills/subagents/SKILL.md"
for doc in "$AGENTS_DIR/planner.md" "$AGENTS_DIR/checker.md" "$AGENTS_DIR/doer.md" "$SUBAGENTS_SKILL_MD"; do
    basename_doc="$(basename "$doc")"
    assert_file_contains "$basename_doc references Bash(run_in_background=true)" \
        "$doc" 'Bash(run_in_background=true)'
    assert_file_not_contains "$basename_doc no longer claims 'no polling, the response arrives directly'" \
        "$doc" "no polling, the response arrives directly"
done

# --- Test 17: spawn-agent captures stderr instead of suppressing it ---
echo "=== Test 17: spawn-agent captures stderr for diagnostics ==="
SPAWN_AGENT="$REPO_ROOT/plugins/looper/skills/subagents/scripts/spawn-agent"
assert_file_exists "spawn-agent script exists" "$SPAWN_AGENT"
assert_file_contains "spawn-agent captures claude stderr to ERRFILE" \
    "$SPAWN_AGENT" 'ERRFILE'
assert_file_contains "spawn-agent redirects claude stderr to ERRFILE" \
    "$SPAWN_AGENT" '2>"\$ERRFILE"'
assert_file_contains "spawn-agent surfaces stderr on missing JSON output" \
    "$SPAWN_AGENT" 'claude stderr'

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
