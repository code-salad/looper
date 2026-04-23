#!/usr/bin/env bash
set -euo pipefail

# test-loop-context-trim.sh — Verify role-scoped loop context, project-context
# pruning on iter > 1, internal per-role fetch, planner.md Track A cleanup,
# and SKILL.md upstream-fetch removal.
#
# Runs standalone: bash plugins/looper/tests/test-loop-context-trim.sh
# Exit 0 = all assertions PASS.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/looper/scripts" && pwd)"
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../agents" && pwd)"
SKILL_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/looper" && pwd)/SKILL.md"

GLC="$SCRIPTS_DIR/git-loop-context"
BAC="$SCRIPTS_DIR/build-agent-context"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; echo "  $2"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Group A — git-loop-context --role flag
# ---------------------------------------------------------------------------
echo "=== Group A: git-loop-context --role flag ==="

TMPDIR_A=$(mktemp -d)
trap 'rm -rf "$TMPDIR_A"' EXIT

# Set up seeded repo for Group A
git -C "$TMPDIR_A" init -b main >/dev/null 2>&1
git -C "$TMPDIR_A" -c user.email=test@test -c user.name=test \
    commit --allow-empty -m "seed" >/dev/null 2>&1

git -C "$TMPDIR_A" -c user.email=test@test -c user.name=test \
    commit --allow-empty -F - <<'MSG' >/dev/null 2>&1
chore: plan commit

PLAN_MARKER_BODY
Loop-Phase: plan
Loop-Iteration: 1
MSG

git -C "$TMPDIR_A" -c user.email=test@test -c user.name=test \
    commit --allow-empty -F - <<'MSG' >/dev/null 2>&1
test: do-red commit

DO_RED_MARKER_BODY
Loop-Phase: do-red
Loop-Iteration: 1
MSG

git -C "$TMPDIR_A" -c user.email=test@test -c user.name=test \
    commit --allow-empty -F - <<'MSG' >/dev/null 2>&1
feat: do-green commit

DO_GREEN_MARKER_BODY
Loop-Phase: do-green
Loop-Iteration: 1
MSG

git -C "$TMPDIR_A" -c user.email=test@test -c user.name=test \
    commit --allow-empty -F - <<'MSG' >/dev/null 2>&1
test: check commit

VERDICT_MARKER_BODY
Loop-Phase: check
Loop-Iteration: 1
Loop-Verdict: FAIL
MSG

printf 'CONTRIB_A\n\n## Code Style\n\nFoo.\n' > "$TMPDIR_A/CONTRIBUTING.md"

SAVED_DIR="$PWD"

cd "$TMPDIR_A"

# A1: planner role — plan + verdict, NOT do-red or do-green
out=$("$GLC" --task demo --iteration 2 --role planner 2>&1 || true)
if echo "$out" | grep -q "PLAN_MARKER_BODY" && \
   echo "$out" | grep -q "VERDICT_MARKER_BODY" && \
   ! echo "$out" | grep -q "DO_RED_MARKER_BODY" && \
   ! echo "$out" | grep -q "DO_GREEN_MARKER_BODY"; then
    pass "A1: planner role shows plan+verdict, hides do-red/do-green"
else
    fail "A1: planner role shows plan+verdict, hides do-red/do-green" \
        "output: $out"
fi

# A2: doer role — only one-line summary per iteration, NO marker bodies
out=$("$GLC" --task demo --iteration 2 --role doer 2>&1 || true)
if ! echo "$out" | grep -q "PLAN_MARKER_BODY" && \
   ! echo "$out" | grep -q "DO_RED_MARKER_BODY" && \
   ! echo "$out" | grep -q "DO_GREEN_MARKER_BODY" && \
   ! echo "$out" | grep -q "VERDICT_MARKER_BODY" && \
   echo "$out" | grep -q "### Iteration 1 — FAIL"; then
    pass "A2: doer role emits one-line summary, no marker bodies"
else
    fail "A2: doer role emits one-line summary, no marker bodies" \
        "output: $out"
fi

# A3: checker role — only verdict body, NOT plan or do-* bodies
out=$("$GLC" --task demo --iteration 2 --role checker 2>&1 || true)
if echo "$out" | grep -q "VERDICT_MARKER_BODY" && \
   ! echo "$out" | grep -q "PLAN_MARKER_BODY" && \
   ! echo "$out" | grep -q "DO_RED_MARKER_BODY" && \
   ! echo "$out" | grep -q "DO_GREEN_MARKER_BODY"; then
    pass "A3: checker role shows verdict only"
else
    fail "A3: checker role shows verdict only" \
        "output: $out"
fi

# A4: iteration 1 with any role → first-iteration banner
out=$("$GLC" --task demo --iteration 1 --role planner 2>&1 || true)
if echo "$out" | grep -q "This is the first iteration. No prior context available."; then
    pass "A4: iteration 1 with role prints first-iteration banner"
else
    fail "A4: iteration 1 with role prints first-iteration banner" \
        "output: $out"
fi

# A5: no --role → legacy full output (backward compat)
out=$("$GLC" --task demo --iteration 2 2>&1 || true)
if echo "$out" | grep -q "PLAN_MARKER_BODY" && \
   echo "$out" | grep -q "DO_RED_MARKER_BODY" && \
   echo "$out" | grep -q "DO_GREEN_MARKER_BODY" && \
   echo "$out" | grep -q "VERDICT_MARKER_BODY"; then
    pass "A5: no --role emits legacy full output"
else
    fail "A5: no --role emits legacy full output" \
        "output: $out"
fi

# A6: invalid role → non-zero exit + stderr contains 'role'
err_a6=$("$GLC" --task demo --iteration 2 --role bogus 2>&1 || true)
if ! "$GLC" --task demo --iteration 2 --role bogus >/dev/null 2>/dev/null; then
    if echo "$err_a6" | grep -qi "role"; then
        pass "A6: --role bogus exits non-zero with 'role' in stderr"
    else
        fail "A6: --role bogus exits non-zero with 'role' in stderr" \
            "combined output: $err_a6"
    fi
else
    fail "A6: --role bogus should exit non-zero" "exited 0"
fi

# A7: empty role string → legacy full output (additive behavior)
out=$("$GLC" --task demo --iteration 2 --role "" 2>&1 || true)
if echo "$out" | grep -q "PLAN_MARKER_BODY" && \
   echo "$out" | grep -q "DO_RED_MARKER_BODY" && \
   echo "$out" | grep -q "DO_GREEN_MARKER_BODY" && \
   echo "$out" | grep -q "VERDICT_MARKER_BODY"; then
    pass "A7: --role '' treated as legacy (full output)"
else
    fail "A7: --role '' treated as legacy (full output)" \
        "output: $out"
fi

cd "$SAVED_DIR"
rm -rf "$TMPDIR_A"
trap '' EXIT

# ---------------------------------------------------------------------------
# Group B — build-agent-context project-context pruning
# ---------------------------------------------------------------------------
echo ""
echo "=== Group B: build-agent-context project-context pruning ==="

TMPDIR_B=$(mktemp -d)
trap 'rm -rf "$TMPDIR_B"' EXIT

git -C "$TMPDIR_B" init -b main >/dev/null 2>&1
git -C "$TMPDIR_B" -c user.email=test@test -c user.name=test \
    commit --allow-empty -m "seed" >/dev/null 2>&1

printf 'CONTRIB_MARKER_XYZ\n\n## Code Style\n\nFoo.\n\n## Testing and CI\n\nBar.\n' \
    > "$TMPDIR_B/CONTRIBUTING.md"

cd "$TMPDIR_B"

BAC_COMMON=(
    --task test --task-prompt "test prompt"
    --scripts-dir "$SCRIPTS_DIR"
    --dev-port 9999
    --compose false --compose-services none
    --worktree-dir "$TMPDIR_B"
)

# B1: iter 1, planner role — CONTRIB_MARKER_XYZ present
out=$("$BAC" --role planner --iteration 1 "${BAC_COMMON[@]}" \
    --loop-context "placeholder" 2>&1 || true)
if echo "$out" | grep -q "CONTRIB_MARKER_XYZ"; then
    pass "B1: iter 1 planner includes full project-context (CONTRIB_MARKER_XYZ present)"
else
    fail "B1: iter 1 planner includes full project-context (CONTRIB_MARKER_XYZ present)" \
        "CONTRIB_MARKER_XYZ not found in output"
fi

# B2: iter 2, planner role — CONTRIB_MARKER_XYZ absent, pointer present
out=$("$BAC" --role planner --iteration 2 "${BAC_COMMON[@]}" \
    --loop-context "placeholder" 2>&1 || true)
if ! echo "$out" | grep -q "CONTRIB_MARKER_XYZ" && \
   echo "$out" | grep -q "project context unchanged"; then
    pass "B2: iter 2 planner omits CONTRIB and has pointer"
else
    fail "B2: iter 2 planner omits CONTRIB and has pointer" \
        "has_contrib=$(echo "$out" | grep -c CONTRIB_MARKER_XYZ 2>/dev/null || echo 0), has_pointer=$(echo "$out" | grep -c 'project context unchanged' 2>/dev/null || echo 0)"
fi

# B3: iter 2, doer role
out=$("$BAC" --role doer --iteration 2 "${BAC_COMMON[@]}" \
    --loop-context "placeholder" 2>&1 || true)
if ! echo "$out" | grep -q "CONTRIB_MARKER_XYZ" && \
   echo "$out" | grep -q "project context unchanged"; then
    pass "B3: iter 2 doer omits CONTRIB and has pointer"
else
    fail "B3: iter 2 doer omits CONTRIB and has pointer" \
        "has_contrib=$(echo "$out" | grep -c CONTRIB_MARKER_XYZ 2>/dev/null || echo 0)"
fi

# B4: iter 2, checker role
out=$("$BAC" --role checker --iteration 2 "${BAC_COMMON[@]}" \
    --loop-context "placeholder" 2>&1 || true)
if ! echo "$out" | grep -q "CONTRIB_MARKER_XYZ" && \
   echo "$out" | grep -q "project context unchanged"; then
    pass "B4: iter 2 checker omits CONTRIB and has pointer"
else
    fail "B4: iter 2 checker omits CONTRIB and has pointer" \
        "has_contrib=$(echo "$out" | grep -c CONTRIB_MARKER_XYZ 2>/dev/null || echo 0)"
fi

# B5: iter 2 output still has <project-context> tags
out=$("$BAC" --role planner --iteration 2 "${BAC_COMMON[@]}" \
    --loop-context "placeholder" 2>&1 || true)
if echo "$out" | grep -q "<project-context>" && \
   echo "$out" | grep -q "</project-context>"; then
    pass "B5: iter 2 output still has <project-context> tags"
else
    fail "B5: iter 2 output still has <project-context> tags" \
        "tags not found in output"
fi

cd "$SAVED_DIR"
rm -rf "$TMPDIR_B"
trap '' EXIT

# ---------------------------------------------------------------------------
# Group C — build-agent-context internal per-role loop-context fetch
# ---------------------------------------------------------------------------
echo ""
echo "=== Group C: build-agent-context internal per-role loop-context fetch ==="

TMPDIR_C=$(mktemp -d)
trap 'rm -rf "$TMPDIR_C"' EXIT

git -C "$TMPDIR_C" init -b main >/dev/null 2>&1
git -C "$TMPDIR_C" -c user.email=test@test -c user.name=test \
    commit --allow-empty -m "seed" >/dev/null 2>&1

git -C "$TMPDIR_C" -c user.email=test@test -c user.name=test \
    commit --allow-empty -F - <<'MSG' >/dev/null 2>&1
chore: plan commit

PLAN_MARKER_BODY
Loop-Phase: plan
Loop-Iteration: 1
MSG

git -C "$TMPDIR_C" -c user.email=test@test -c user.name=test \
    commit --allow-empty -F - <<'MSG' >/dev/null 2>&1
test: do-red commit

DO_RED_MARKER_BODY
Loop-Phase: do-red
Loop-Iteration: 1
MSG

git -C "$TMPDIR_C" -c user.email=test@test -c user.name=test \
    commit --allow-empty -F - <<'MSG' >/dev/null 2>&1
feat: do-green commit

DO_GREEN_MARKER_BODY
Loop-Phase: do-green
Loop-Iteration: 1
MSG

git -C "$TMPDIR_C" -c user.email=test@test -c user.name=test \
    commit --allow-empty -F - <<'MSG' >/dev/null 2>&1
test: check commit

VERDICT_MARKER_BODY
Loop-Phase: check
Loop-Iteration: 1
Loop-Verdict: FAIL
MSG

printf 'CONTRIB_C\n\n## Code Style\n\nFoo.\n' > "$TMPDIR_C/CONTRIBUTING.md"

cd "$TMPDIR_C"

BAC_C_COMMON=(
    --task test --iteration 2 --task-prompt "test prompt"
    --scripts-dir "$SCRIPTS_DIR"
    --dev-port 9999
    --compose false --compose-services none
    --worktree-dir "$TMPDIR_C"
)

# C1: planner role, no --loop-context → internal fetch → plan+verdict in Prior Loop Context
out=$("$BAC" --role planner "${BAC_C_COMMON[@]}" 2>&1 || true)
prior=$(echo "$out" | awk '/^## Prior Loop Context/,0' | tail -n +2)
if echo "$prior" | grep -q "PLAN_MARKER_BODY" && \
   echo "$prior" | grep -q "VERDICT_MARKER_BODY" && \
   ! echo "$prior" | grep -q "DO_RED_MARKER_BODY"; then
    pass "C1: planner internal fetch: plan+verdict in Prior Loop Context"
else
    fail "C1: planner internal fetch: plan+verdict in Prior Loop Context" \
        "prior section: $prior"
fi

# C2: doer role, no --loop-context → only one-line summary under Prior Loop Context
out=$("$BAC" --role doer "${BAC_C_COMMON[@]}" 2>&1 || true)
prior=$(echo "$out" | awk '/^## Prior Loop Context/,0' | tail -n +2)
if ! echo "$prior" | grep -q "PLAN_MARKER_BODY" && \
   ! echo "$prior" | grep -q "DO_RED_MARKER_BODY" && \
   ! echo "$prior" | grep -q "DO_GREEN_MARKER_BODY" && \
   ! echo "$prior" | grep -q "VERDICT_MARKER_BODY" && \
   echo "$prior" | grep -q "### Iteration 1 — FAIL"; then
    pass "C2: doer internal fetch: only summary in Prior Loop Context"
else
    fail "C2: doer internal fetch: only summary in Prior Loop Context" \
        "prior section: $prior"
fi

# C3: checker role, no --loop-context → only verdict under Prior Loop Context
out=$("$BAC" --role checker "${BAC_C_COMMON[@]}" 2>&1 || true)
prior=$(echo "$out" | awk '/^## Prior Loop Context/,0' | tail -n +2)
if echo "$prior" | grep -q "VERDICT_MARKER_BODY" && \
   ! echo "$prior" | grep -q "PLAN_MARKER_BODY" && \
   ! echo "$prior" | grep -q "DO_RED_MARKER_BODY" && \
   ! echo "$prior" | grep -q "DO_GREEN_MARKER_BODY"; then
    pass "C3: checker internal fetch: only verdict in Prior Loop Context"
else
    fail "C3: checker internal fetch: only verdict in Prior Loop Context" \
        "prior section: $prior"
fi

# C4: explicit --loop-context passthrough honored, seeded markers bypassed
out=$("$BAC" --role planner "${BAC_C_COMMON[@]}" \
    --loop-context "LITERAL_SENTINEL" 2>&1 || true)
prior=$(echo "$out" | awk '/^## Prior Loop Context/,0' | tail -n +2)
if echo "$prior" | grep -q "LITERAL_SENTINEL" && \
   ! echo "$prior" | grep -q "PLAN_MARKER_BODY"; then
    pass "C4: explicit --loop-context passthrough honored, internal fetch bypassed"
else
    fail "C4: explicit --loop-context passthrough honored, internal fetch bypassed" \
        "prior section: $prior"
fi

cd "$SAVED_DIR"
rm -rf "$TMPDIR_C"
trap '' EXIT

# ---------------------------------------------------------------------------
# Group D — planner.md Track A cleanup (static grep assertions)
# ---------------------------------------------------------------------------
echo ""
echo "=== Group D: planner.md Track A cleanup ==="

PLANNER_FILE="$AGENTS_DIR/planner.md"

# D1: Track A section no longer contains git-loop-context
track_a_block=$(sed -n '/Track A/,/Track B/p' "$PLANNER_FILE" 2>/dev/null || true)
if echo "$track_a_block" | grep -q "git-loop-context"; then
    fail "D1: Track A should not contain git-loop-context" \
        "Found git-loop-context in Track A block"
else
    pass "D1: Track A does not contain git-loop-context"
fi

# D2: Track A still contains detect-stack
if echo "$track_a_block" | grep -q "detect-stack"; then
    pass "D2: Track A still contains detect-stack"
else
    fail "D2: Track A still contains detect-stack" \
        "detect-stack not found in Track A block"
fi

# D3: file mentions loop context is pre-injected / already injected
if grep -qE "already.*injected|pre-injected" "$PLANNER_FILE"; then
    pass "D3: planner.md mentions loop context is pre-injected"
else
    fail "D3: planner.md mentions loop context is pre-injected" \
        "No match for 'already.*injected' or 'pre-injected' in planner.md"
fi

# D4: Available Skills entry for git-loop-context annotated
# Extract section from ## Available Skills to next ## header
avail_block=$(awk '/^## Available Skills/{found=1;next} found && /^## /{exit} found{print}' "$PLANNER_FILE" 2>/dev/null || true)
glc_annotation=$(echo "$avail_block" | grep -A2 "git-loop-context" | grep -E "pre-injected|do not call manually" || true)
if [ -n "$glc_annotation" ]; then
    pass "D4: git-loop-context Available Skills entry annotated"
else
    glc_line=$(echo "$avail_block" | grep "git-loop-context" || true)
    fail "D4: git-loop-context Available Skills entry annotated" \
        "git-loop-context line/context in Available Skills: '$glc_line'"
fi

# ---------------------------------------------------------------------------
# Group E — SKILL.md cleanup (static grep assertions)
# ---------------------------------------------------------------------------
echo ""
echo "=== Group E: SKILL.md cleanup ==="

# E1: SKILL.md does not contain LOOP_CONTEXT=$(... git-loop-context
# shellcheck disable=SC2016
if grep -qE 'LOOP_CONTEXT=\$\(.*git-loop-context' "$SKILL_FILE"; then
    fail "E1: SKILL.md should not have upstream shared LOOP_CONTEXT fetch" \
        "Found LOOP_CONTEXT=\$(... git-loop-context in SKILL.md"
else
    pass "E1: SKILL.md does not have upstream shared LOOP_CONTEXT fetch"
fi

# E2: CTX_COMMON in SKILL.md does not contain --loop-context
ctx_block=$(awk '/CTX_COMMON/,/\)/' "$SKILL_FILE" 2>/dev/null | head -20 || true)
if echo "$ctx_block" | grep -q "\-\-loop-context"; then
    fail "E2: CTX_COMMON in SKILL.md should not contain --loop-context" \
        "Found --loop-context in CTX_COMMON block"
else
    pass "E2: CTX_COMMON in SKILL.md does not contain --loop-context"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
