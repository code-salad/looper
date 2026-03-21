#!/usr/bin/env bash
set -euo pipefail

# test-migration-merge-strategy.sh — Verify that create-github-pr skill contains
# migration-aware merge logic that switches from squash to regular merge when
# DB migration files are detected in the PR's changeset.

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

# Test 1: create-github-pr SKILL.md contains migration detection logic
check "create-github-pr SKILL.md contains migration detection logic" \
    "$CREATE_PR_SKILL" \
    "migration"

# Test 2: create-github-pr SKILL.md supports regular merge for migrations
check "create-github-pr SKILL.md supports regular merge for migrations" \
    "$CREATE_PR_SKILL" \
    "\-\-merge"

# Test 3: create-github-pr SKILL.md lists migration path patterns
check "create-github-pr SKILL.md lists migration path patterns" \
    "$CREATE_PR_SKILL" \
    "migrations/\|db/migrate\|alembic"

# Test 4: create-github-pr SKILL.md conditionally chooses merge strategy
check "create-github-pr SKILL.md conditionally chooses merge strategy" \
    "$CREATE_PR_SKILL" \
    "HAS_MIGRATIONS"

# Test 5: looper SKILL.md references migration-aware merging
check "looper SKILL.md references migration-aware merging" \
    "$LOOPER_SKILL" \
    "migration"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
