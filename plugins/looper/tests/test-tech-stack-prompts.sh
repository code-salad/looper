#!/usr/bin/env bash
set -euo pipefail

# test-tech-stack-prompts.sh — Verify that agent prompt files contain
# tech stack compliance instructions added to address issue #42.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../agents" && pwd)"

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

# planner.md must contain a "Tech stack compliance" rule
check "planner.md contains Tech stack compliance rule" \
    "$AGENTS_DIR/planner.md" \
    "Tech stack compliance"

# planner.md must mention extracting tech stack constraints from the issue body
check "planner.md instructs to extract tech stack from issue body" \
    "$AGENTS_DIR/planner.md" \
    "Tech Stack Constraints"

# doer.md must contain a "Tech stack compliance" rule
check "doer.md contains Tech stack compliance rule" \
    "$AGENTS_DIR/doer.md" \
    "Tech stack compliance"

# doer.md must warn against using wrong ecosystem (e.g., npm/Next.js when plan says Rust/Axum)
check "doer.md warns against wrong ecosystem" \
    "$AGENTS_DIR/doer.md" \
    "Tech Stack Constraints"

# checker.md must contain a tech stack compliance check in the Logic Reviewer section
check "checker.md contains tech stack compliance check" \
    "$AGENTS_DIR/checker.md" \
    "[Tt]ech [Ss]tack [Cc]ompliance"

# checker.md must flag wrong-ecosystem files as BLOCKER
check "checker.md flags wrong-ecosystem files as BLOCKER" \
    "$AGENTS_DIR/checker.md" \
    "BLOCKER.*[Tt]ech [Ss]tack\|[Tt]ech [Ss]tack.*BLOCKER"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
