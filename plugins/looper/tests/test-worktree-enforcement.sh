#!/usr/bin/env bash
set -euo pipefail

# test-worktree-enforcement.sh — Verify that the looper skill enforces
# branch isolation and prevents committing directly to the default branch.
# Worktree creation itself is now handled externally by Claude Desktop, so the
# /looper skill only verifies that the current working directory is a worktree
# on a non-default branch before doing any work.

SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills" && pwd)"
LOOPER_SKILL="$SKILLS_DIR/looper/SKILL.md"
GIT_COMMIT_LOOP="$SKILLS_DIR/looper/scripts/git-commit-loop"

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
        echo "  Expected pattern '$pattern' in $file"
        FAIL=$((FAIL + 1))
    fi
}

check_absent() {
    local label="$1"
    local file="$2"
    local pattern="$3"

    if grep -qE "$pattern" "$file"; then
        echo "FAIL: $label"
        echo "  Pattern '$pattern' should NOT be in $file"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $label"
        PASS=$((PASS + 1))
    fi
}

# looper/SKILL.md must resolve WORKTREE_DIR from the current repo (Claude Desktop
# is responsible for cd-ing into the worktree before invoking the skill).
check "looper SKILL.md resolves WORKTREE_DIR via git rev-parse" \
    "$LOOPER_SKILL" \
    'WORKTREE_DIR=\$\(git rev-parse --show-toplevel\)'

# looper/SKILL.md must state CRITICAL: never commit directly to default branch
# (The phrase may wrap across lines, so match the leading half only.)
check "looper SKILL.md forbids committing directly to the default branch" \
    "$LOOPER_SKILL" \
    "NEVER commit directly to"

# looper/SKILL.md must reject detached HEAD before any work
check "looper SKILL.md rejects detached HEAD" \
    "$LOOPER_SKILL" \
    "Detached HEAD"

# looper/SKILL.md must reject the default branch (dynamic detection + main/master fallback)
check "looper SKILL.md rejects running on default/protected branch" \
    "$LOOPER_SKILL" \
    "Refusing to run on default/protected branch"

# looper/SKILL.md must NOT call setup-worktree (Claude Desktop handles worktree creation)
check_absent "looper SKILL.md does not call setup-worktree" \
    "$LOOPER_SKILL" \
    'setup-worktree --task'

# looper/SKILL.md must forbid local merges
check "looper SKILL.md forbids local merges" \
    "$LOOPER_SKILL" \
    "never merge locally|CRITICAL.*never merge|never merge.*CRITICAL"

# looper/SKILL.md must direct to create-github-pr for merging
check "looper SKILL.md uses create-github-pr for merging" \
    "$LOOPER_SKILL" \
    "create-github-pr"

# git-commit-loop must guard against committing on detached HEAD
check "git-commit-loop guards detached HEAD" \
    "$GIT_COMMIT_LOOP" \
    "Detached HEAD"

# git-commit-loop must guard against committing on the default branch
check "git-commit-loop guards default branch" \
    "$GIT_COMMIT_LOOP" \
    "Refusing to commit on protected branch"

# git-commit-loop must refuse if the default branch cannot be determined
check "git-commit-loop refuses when default branch undetermined" \
    "$GIT_COMMIT_LOOP" \
    "Could not determine default branch"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
