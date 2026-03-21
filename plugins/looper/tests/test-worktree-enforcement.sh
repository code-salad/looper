#!/usr/bin/env bash
set -euo pipefail

# test-worktree-enforcement.sh — Verify that looper skill enforces
# worktree isolation and prevents committing directly to main/default branch.
# Addresses issue #42: Looper committed directly to main without worktree.

SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills" && pwd)"
LOOPER_SKILL="$SKILLS_DIR/looper/SKILL.md"

PASS=0
FAIL=0

check() {
    local label="$1"
    local file="$2"
    local pattern="$3"

    if grep -q "$pattern" "$file"; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label"
        echo "  Expected pattern '$pattern' in $file"
        FAIL=$((FAIL + 1))
    fi
}

# looper/SKILL.md must require creating a worktree before any work
check "looper SKILL.md requires worktree creation" \
    "$LOOPER_SKILL" \
    "setup-worktree"

# looper/SKILL.md must have a gate that aborts if worktree creation fails
check "looper SKILL.md has worktree creation gate" \
    "$LOOPER_SKILL" \
    "WORKTREE_DIR.*empty.*abort\|abort.*WORKTREE_DIR.*empty\|setup-worktree.*exits non-zero"

# looper/SKILL.md must state CRITICAL: never commit directly to default branch
check "looper SKILL.md forbids committing directly to default branch" \
    "$LOOPER_SKILL" \
    "NEVER commit directly to the default branch"

# looper/SKILL.md must verify loop/ branch before proceeding
check "looper SKILL.md verifies loop/ branch" \
    "$LOOPER_SKILL" \
    "loop/"

# looper/SKILL.md must forbid local merges
check "looper SKILL.md forbids local merges" \
    "$LOOPER_SKILL" \
    "never merge locally\|CRITICAL.*never merge\|never merge.*CRITICAL"

# looper/SKILL.md must direct to create-github-pr for merging
check "looper SKILL.md uses create-github-pr for merging" \
    "$LOOPER_SKILL" \
    "create-github-pr"

SETUP_WORKTREE_SCRIPT="$SKILLS_DIR/looper/scripts/setup-worktree"

# setup-worktree must contain a bare-repo guard
check "setup-worktree script contains bare-repo guard" \
    "$SETUP_WORKTREE_SCRIPT" \
    "ensure_not_bare\|core\.bare"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
