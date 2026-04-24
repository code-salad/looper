#!/usr/bin/env bash
set -euo pipefail
# test-agent-spawn-migration.sh — Guard-rails for issue #89
# Ensures the migration away from async+poll subagent spawning does not
# regress. Covers acceptance criteria AC1-AC7.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
LOOPER_SKILL="$REPO_ROOT/plugins/looper/skills/looper/SKILL.md"
SUBAGENTS_SKILL="$REPO_ROOT/plugins/looper/skills/subagents/SKILL.md"
SPAWN_AGENT="$REPO_ROOT/plugins/looper/skills/subagents/scripts/spawn-agent"
PLANNER="$REPO_ROOT/plugins/looper/agents/planner.md"
DOER="$REPO_ROOT/plugins/looper/agents/doer.md"
CHECKER="$REPO_ROOT/plugins/looper/agents/checker.md"
README="$REPO_ROOT/README.md"

PASS=0
FAIL=0

assert_file_contains() {
    local description="$1" file="$2" pattern="$3"
    if grep -q -- "$pattern" "$file" 2>/dev/null; then
        echo "PASS: $description"; PASS=$((PASS + 1))
    else
        echo "FAIL: $description (pattern '$pattern' not found in $file)"; FAIL=$((FAIL + 1))
    fi
}

assert_file_not_contains() {
    local description="$1" file="$2" pattern="$3"
    if grep -q -- "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $description (pattern '$pattern' found in $file but should not be)"; FAIL=$((FAIL + 1))
    else
        echo "PASS: $description"; PASS=$((PASS + 1))
    fi
}

# AC1 — SKILL.md shrink: misdiagnosed watchdog phrase removed; section ≤30 lines.
assert_file_not_contains "SKILL.md: old watchdog phrase removed" \
    "$LOOPER_SKILL" "600s of no tool-call activity"
assert_file_not_contains "SKILL.md: poll-loop fallback prose removed" \
    "$LOOPER_SKILL" "Then poll in a loop"
assert_file_not_contains "SKILL.md: step-7d fallback annotation removed" \
    "$LOOPER_SKILL" "+ poll, per"
# Section length ≤ 30 lines (renamed from "Agent spawning mode" to
# "Spawning planner / doer / checker" after the Agent-first migration).
section_lines=$(awk '/^## Spawning planner/{flag=1;next} /^## /{if(flag){flag=0;exit}} flag{print}' "$LOOPER_SKILL" | wc -l)
if [ "$section_lines" -gt 0 ] && [ "$section_lines" -le 30 ]; then
    echo "PASS: SKILL.md: spawning section is 1..30 lines ($section_lines)"
    PASS=$((PASS + 1))
else
    echo "FAIL: SKILL.md: spawning section is $section_lines lines (expected 1..30)"
    FAIL=$((FAIL + 1))
fi

# AC2 — Primary pattern for the fallback path (subagents skill) still documents
# run_in_background + completion notification. The looper skill itself no
# longer has to, since Agent-first is the documented default and those details
# are owned by the subagents (fallback) skill.
assert_file_contains "subagents/SKILL.md: mentions run_in_background" \
    "$SUBAGENTS_SKILL" "run_in_background"
assert_file_contains "subagents/SKILL.md: mentions completion notification" \
    "$SUBAGENTS_SKILL" "completion notification"

# AC3 — parallel fan-out via stdout-redirect + &/wait; --async removed from spawn-agent.
assert_file_contains "subagents/SKILL.md: frames parallel fan-out" \
    "$SUBAGENTS_SKILL" "parallel fan-out"
assert_file_not_contains "subagents/SKILL.md: no --async references" \
    "$SUBAGENTS_SKILL" '--async'
assert_file_not_contains "subagents/SKILL.md: old poll-loop removed from parallel example" \
    "$SUBAGENTS_SKILL" 'while \[ ! -s '
assert_file_not_contains "spawn-agent: --async mode removed" \
    "$SPAWN_AGENT" 'MODE="async"'
assert_file_not_contains "spawn-agent: --async flag branch removed" \
    "$SPAWN_AGENT" '== "--async"'

# AC3 extended — no /tmp/subagent-response-* artefacts anywhere
assert_file_not_contains "subagents/SKILL.md: no subagent-response- path" \
    "$SUBAGENTS_SKILL" 'subagent-response-'
assert_file_not_contains "looper/SKILL.md: no subagent-response- path" \
    "$LOOPER_SKILL" 'subagent-response-'
assert_file_not_contains "spawn-agent: no subagent-response- path" \
    "$SPAWN_AGENT" 'subagent-response-'

# AC3 extended — agent preambles have no --async
assert_file_not_contains "planner.md: preamble has no --async" \
    "$PLANNER" '--async'
assert_file_not_contains "doer.md: preamble has no --async" \
    "$DOER" '--async'
assert_file_not_contains "checker.md: preamble has no --async" \
    "$CHECKER" '--async'

# AC3 extended — spawn-agent prints .result directly
assert_file_contains "spawn-agent: prints .result directly" \
    "$SPAWN_AGENT" "jq -r '.result"

# AC4 — Per-agent preambles migrated and lose dual-path fallback language.
for f in "$PLANNER" "$DOER" "$CHECKER"; do
    assert_file_contains "$(basename "$f"): preamble mentions run_in_background" \
        "$f" "run_in_background"
    assert_file_not_contains "$(basename "$f"): no 'Agent tool is NOT' dual-path branching" \
        "$f" "Agent tool is NOT"
    assert_file_not_contains "$(basename "$f"): no 'async + poll' fallback language" \
        "$f" "async.*poll"
done

# AC5 — README documents env var with 2-hour recommendation.
assert_file_contains "README: documents CLAUDE_STREAM_IDLE_TIMEOUT_MS" \
    "$README" "CLAUDE_STREAM_IDLE_TIMEOUT_MS"
assert_file_contains "README: recommends 7200000" \
    "$README" "7200000"
assert_file_contains "README: explains stream-stall rationale" \
    "$README" "stalled model streams"

# AC7 — No reintroduction of absolute CLAUDE_PLUGIN_ROOT paths in migrated docs.
for f in "$LOOPER_SKILL" "$PLANNER" "$DOER" "$CHECKER"; do
    assert_file_not_contains "$(basename "$f"): no CLAUDE_PLUGIN_ROOT absolute path" \
        "$f" 'CLAUDE_PLUGIN_ROOT/skills/subagents/scripts/spawn-agent'
done

# AC8 — Stale result-file framing removed from all four docs.
for f in "$LOOPER_SKILL" "$PLANNER" "$DOER" "$CHECKER"; do
    assert_file_not_contains "$(basename "$f"): no 'result-file path' framing" \
        "$f" 'result-file path'
done

# AC9 — Stale 'read result file' synonym removed from all four docs.
for f in "$LOOPER_SKILL" "$PLANNER" "$DOER" "$CHECKER"; do
    assert_file_not_contains "$(basename "$f"): no 'read result file' synonym" \
        "$f" 'read result file'
done

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
