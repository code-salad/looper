#!/usr/bin/env bash
set -euo pipefail

# test-migration-merge-strategy.sh — Verify that create-github-pr skill contains
# migration-aware merge logic that skips auto-merge (PR-only) when DB migration
# files are detected, and squash-merges when no DB migrations are present.

SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills" && pwd)"
CREATE_PR_SKILL="$SKILLS_DIR/create-github-pr/SKILL.md"
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

check_absent() {
    local label="$1"
    local file="$2"
    local pattern="$3"

    if grep -q "$pattern" "$file"; then
        echo "FAIL: $label"
        echo "  Pattern '$pattern' should NOT be in $file"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $label"
        PASS=$((PASS + 1))
    fi
}

# Test 1: create-github-pr SKILL.md contains migration detection logic
check "create-github-pr SKILL.md contains migration detection logic" \
    "$CREATE_PR_SKILL" \
    "migration"

# Test 2: create-github-pr SKILL.md does NOT use --merge (regular merge)
check_absent "create-github-pr SKILL.md does not use gh pr merge --merge" \
    "$CREATE_PR_SKILL" \
    "gh pr merge.*--merge --delete-branch"

# Test 3: create-github-pr SKILL.md lists migration path patterns
check "create-github-pr SKILL.md lists migration path patterns" \
    "$CREATE_PR_SKILL" \
    "migrations/\|db/migrate\|alembic"

# Test 4: create-github-pr SKILL.md conditionally chooses merge strategy
check "create-github-pr SKILL.md conditionally chooses merge strategy" \
    "$CREATE_PR_SKILL" \
    "HAS_MIGRATIONS"

# Test 5: create-github-pr SKILL.md skips merge when migrations detected
check "create-github-pr SKILL.md skips auto-merge for DB migrations" \
    "$CREATE_PR_SKILL" \
    "skipping auto-merge"

# Test 6: create-github-pr SKILL.md uses squash merge for non-DB PRs
check "create-github-pr SKILL.md uses squash merge" \
    "$CREATE_PR_SKILL" \
    "\-\-squash"

# Test 7: looper SKILL.md references migration-aware merging
check "looper SKILL.md references migration-aware merging" \
    "$LOOPER_SKILL" \
    "migration"

# Test 8: looper SKILL.md says PR-only for DB migrations
check "looper SKILL.md says PR-only for DB migrations" \
    "$LOOPER_SKILL" \
    "PR-only\|left open for manual review\|no auto-merge"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
