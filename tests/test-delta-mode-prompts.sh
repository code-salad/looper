#!/usr/bin/env bash
set -euo pipefail

# test-delta-mode-prompts.sh — Verify delta-mode planning instructions remain
# wired up after the agent collapse. The 5 check-* and 3 plan-* fan-out
# subagents have been removed; the surviving consumers are planner, doer,
# and checker, which all need the pointer-resolution wiring.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../plugins/looper/agents" && pwd)"

PASS=0
FAIL=0

check() {
    local label="$1"
    local file="$2"
    local pattern="$3"
    if grep -qE "$pattern" "$file"; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label"
        echo "  Expected regex '$pattern' in $file"
        FAIL=$((FAIL + 1))
    fi
}

# --- Planner prompt updates ---
echo "=== Planner delta-mode rules ==="
check "planner.md: iter > 1 delta-mode section present" \
    "$AGENTS_DIR/planner.md" \
    "[Dd]elta-mode planning"

check "planner.md: defines pointer syntax '(unchanged from iteration ... — see <hash>)'" \
    "$AGENTS_DIR/planner.md" \
    "unchanged from iteration"

check "planner.md: no-drift rule bans improving unflagged sections" \
    "$AGENTS_DIR/planner.md" \
    "[Nn]o-drift|BANNED from \"improving\""

check "planner.md: includes partial-revision example block" \
    "$AGENTS_DIR/planner.md" \
    "[Pp]artial-revision example"

check "planner.md: Tech Stack Constraints is almost always unchanged" \
    "$AGENTS_DIR/planner.md" \
    "Tech Stack Constraints.*almost always.*unchanged"

check "planner.md: fallback for missing prior plan commit" \
    "$AGENTS_DIR/planner.md" \
    "delta-mode fallback"

check "planner.md: mentions resolve-plan-pointers helper" \
    "$AGENTS_DIR/planner.md" \
    "resolve-plan-pointers"

# --- Consumer prompts ---
echo "=== Consumer prompt pointer-resolution rules ==="
check "doer.md: pointer-resolution rule present" \
    "$AGENTS_DIR/doer.md" \
    "[Dd]elta-mode pointer|resolve-plan-pointers"

check "doer.md: instructs resolving pointers before acting on the plan" \
    "$AGENTS_DIR/doer.md" \
    "unchanged from iteration"

check "checker.md: pointer-resolution rule present" \
    "$AGENTS_DIR/checker.md" \
    "[Dd]elta-mode pointer|resolve-plan-pointers"

check "checker.md: expands pointers before reviewing" \
    "$AGENTS_DIR/checker.md" \
    "Expand before reviewing|expanded plan|resolve-plan-pointers"

# (The pre-collapse "sub-checker pointer-resolution notes" tests are
#  removed: those subagents no longer exist. Checker handles all review
#  work inline, so the single pointer-resolution rule above is sufficient.)

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
