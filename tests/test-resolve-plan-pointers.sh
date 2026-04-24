#!/usr/bin/env bash
set -euo pipefail

# test-resolve-plan-pointers.sh — Tests for the resolve-plan-pointers helper.
#
# Verifies that the helper expands delta-mode pointers:
#   - section-body pointers ("(unchanged from iteration N-1 — see <hash>)")
#   - list-item pointers ("- (N prior cases unchanged — see <hash>)")
#   - missing-commit fallback (pointer left in place + warning)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
RESOLVER="$REPO_ROOT/plugins/looper/skills/looper/scripts/resolve-plan-pointers"

PASS=0
FAIL=0

assert_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description"
        echo "  Expected to find: $needle"
        echo "  In: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "FAIL: $description"
        echo "  Did not expect to find: $needle"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $description"
        PASS=$((PASS + 1))
    fi
}

# --- Setup: create a temp git repo with a prior plan commit ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"
git init -q
git config user.email test@example.com
git config user.name Test
git commit --allow-empty -qm "init"

# Commit a prior-iteration plan that pointers can resolve against.
cat > /tmp/prior-plan-$$.txt <<'PRIOR'
chore(foo): plan iteration 1

## Goal
Implement the foo feature.

## Tech Stack Constraints
- Rust + tokio
- No JS framework

## Corner cases
- empty input
- null input
- whitespace-only input

## Acceptance criteria
- unit test for happy path
- unit test for empty input
PRIOR
git commit --allow-empty -q -F /tmp/prior-plan-$$.txt
PRIOR_HASH=$(git rev-parse --short=7 HEAD)
rm -f /tmp/prior-plan-$$.txt

# --- Test 1: resolver exists and is executable ---
echo "=== Test 1: resolver exists and is executable ==="
if [ -x "$RESOLVER" ]; then
    echo "PASS: resolve-plan-pointers is executable"
    PASS=$((PASS + 1))
else
    echo "FAIL: resolve-plan-pointers missing or not executable at $RESOLVER"
    FAIL=$((FAIL + 1))
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 2: section-body pointer expands to full section ---
echo "=== Test 2: section-body pointer resolves to the referenced section body ==="
INPUT=$(cat <<EOF
## Goal
(unchanged from iteration 1 — see ${PRIOR_HASH})

## Corner cases
- new case
EOF
)
OUTPUT=$(printf '%s\n' "$INPUT" | "$RESOLVER")
assert_contains "section-body pointer expands to 'Implement the foo feature.'" \
    "$OUTPUT" "Implement the foo feature."
assert_not_contains "section-body pointer no longer appears verbatim" \
    "$OUTPUT" "(unchanged from iteration 1 — see ${PRIOR_HASH})"

# --- Test 3: list-item pointer expands to inherited bullets ---
echo "=== Test 3: list-item pointer expands to the inherited bullets ==="
INPUT=$(cat <<EOF
## Corner cases
- (3 prior cases unchanged — see ${PRIOR_HASH})
- NEW: unicode RTL characters
EOF
)
OUTPUT=$(printf '%s\n' "$INPUT" | "$RESOLVER")
assert_contains "list-item pointer expands to include 'empty input'" \
    "$OUTPUT" "- empty input"
assert_contains "list-item pointer expands to include 'null input'" \
    "$OUTPUT" "- null input"
assert_contains "list-item pointer expands to include 'whitespace-only input'" \
    "$OUTPUT" "- whitespace-only input"
assert_contains "new bullet after inherited bullets is preserved" \
    "$OUTPUT" "- NEW: unicode RTL characters"
assert_not_contains "list-item pointer no longer appears verbatim" \
    "$OUTPUT" "(3 prior cases unchanged"

# --- Test 4: Tech Stack Constraints pointer inherits verbatim ---
echo "=== Test 4: Tech Stack Constraints pointer inherits verbatim ==="
INPUT=$(cat <<EOF
## Tech Stack Constraints
(unchanged from iteration 1 — see ${PRIOR_HASH})
EOF
)
OUTPUT=$(printf '%s\n' "$INPUT" | "$RESOLVER")
assert_contains "tech-stack pointer resolves to 'Rust + tokio'" \
    "$OUTPUT" "Rust + tokio"
assert_contains "tech-stack pointer resolves to 'No JS framework'" \
    "$OUTPUT" "No JS framework"

# --- Test 5: missing-commit fallback leaves pointer + prints warning ---
echo "=== Test 5: missing-commit fallback leaves pointer in place ==="
INPUT=$(cat <<'EOF'
## Goal
(unchanged from iteration 1 — see deadbee)
EOF
)
OUTPUT=$(printf '%s\n' "$INPUT" | "$RESOLVER" 2>/tmp/resolver-stderr-$$)
STDERR=$(cat /tmp/resolver-stderr-$$)
rm -f /tmp/resolver-stderr-$$
assert_contains "missing-hash pointer is preserved verbatim" \
    "$OUTPUT" "(unchanged from iteration 1 — see deadbee)"
assert_contains "warning is emitted to stderr for missing hash" \
    "$STDERR" "WARN"

# --- Test 6: plan with no pointers is returned unchanged ---
echo "=== Test 6: plan with no pointers is passed through unchanged ==="
INPUT=$(cat <<'EOF'
## Goal
Implement bar.

## Corner cases
- case A
- case B
EOF
)
OUTPUT=$(printf '%s\n' "$INPUT" | "$RESOLVER")
# Allow for a trailing newline discrepancy — compare trimmed forms.
EXPECTED_TRIMMED=$(printf '%s' "$INPUT")
ACTUAL_TRIMMED=$(printf '%s' "$OUTPUT")
if [ "$EXPECTED_TRIMMED" = "$ACTUAL_TRIMMED" ]; then
    echo "PASS: plan with no pointers is unchanged"
    PASS=$((PASS + 1))
else
    echo "FAIL: plan with no pointers was modified"
    echo "  Expected: $EXPECTED_TRIMMED"
    echo "  Actual:   $ACTUAL_TRIMMED"
    FAIL=$((FAIL + 1))
fi

# --- Test 7: size reduction — a delta plan is smaller than the full plan ---
echo "=== Test 7: pointer-form plan is significantly smaller than resolved form ==="
POINTER_FORM=$(cat <<EOF
## Goal
(unchanged from iteration 1 — see ${PRIOR_HASH})

## Tech Stack Constraints
(unchanged from iteration 1 — see ${PRIOR_HASH})

## Corner cases
- (3 prior cases unchanged — see ${PRIOR_HASH})
- NEW: empty-string input → 400 not 500

## Acceptance criteria
- (criteria 1-2 unchanged — see ${PRIOR_HASH})
- REVISED: response body must be {code,message}
EOF
)
RESOLVED=$(printf '%s\n' "$POINTER_FORM" | "$RESOLVER")
POINTER_LINES=$(printf '%s\n' "$POINTER_FORM" | wc -l)
RESOLVED_LINES=$(printf '%s\n' "$RESOLVED" | wc -l)
# Pointer form must be strictly smaller than the resolved form.
if [ "$POINTER_LINES" -lt "$RESOLVED_LINES" ]; then
    echo "PASS: pointer form ($POINTER_LINES lines) < resolved form ($RESOLVED_LINES lines)"
    PASS=$((PASS + 1))
else
    echo "FAIL: pointer form ($POINTER_LINES) not smaller than resolved ($RESOLVED_LINES)"
    FAIL=$((FAIL + 1))
fi
# Spot-check that the RESOLVED form contains the inherited bullets.
assert_contains "resolved form inherits 'empty input'" "$RESOLVED" "empty input"
assert_contains "resolved form inherits 'Rust + tokio'" "$RESOLVED" "Rust + tokio"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
