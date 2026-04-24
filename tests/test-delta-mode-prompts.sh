#!/usr/bin/env bash
set -euo pipefail

# test-delta-mode-prompts.sh — Verify that agent prompt files contain the
# delta-mode planning instructions added for issue #90.
#
# Acceptance criteria (from #90):
#   - planner.md step 4 has a dedicated subsection for iter > 1 behavior
#     with the "(unchanged from iteration N-1 — see <commit-hash>)" pattern
#   - planner.md bans "improving" sections the Checker didn't flag (no-drift)
#   - planner.md includes a partial-revision example
#   - planner.md flags Tech Stack Constraints as almost always (unchanged)
#   - planner.md has a fallback path for missing prior commit
#   - doer.md has a pointer-resolution rule
#   - checker.md has a pointer-resolution rule
#   - sub-checkers (check-tests, check-code, check-adversarial, plan-*)
#     each have a pointer-resolution note

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
    "[Dd]elta-mode pointer resolution|resolve-plan-pointers"

check "doer.md: instructs resolving pointers before acting on the plan" \
    "$AGENTS_DIR/doer.md" \
    "unchanged from iteration"

check "checker.md: pointer-resolution rule present" \
    "$AGENTS_DIR/checker.md" \
    "[Dd]elta-mode pointer resolution|resolve-plan-pointers"

check "checker.md: passes expanded plan to sub-checkers" \
    "$AGENTS_DIR/checker.md" \
    "fully-expanded plan|expand every pointer"

# --- Sub-checker prompts ---
echo "=== Sub-checker pointer-resolution notes ==="
for sub in check-tests check-code check-adversarial plan-completeness plan-feasibility; do
    check "$sub.md: mentions delta-mode pointers" \
        "$AGENTS_DIR/$sub.md" \
        "[Dd]elta-mode pointers|unchanged from iteration"
done

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
