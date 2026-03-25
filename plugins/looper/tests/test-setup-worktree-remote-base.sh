#!/usr/bin/env bash
set -euo pipefail

# test-setup-worktree-remote-base.sh — Regression tests for issue #47:
# setup-worktree must branch from origin/<default-branch> instead of local HEAD.
# This prevents unpushed local commits from leaking into task worktrees.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/skills/looper/scripts"
SETUP_WORKTREE="$SCRIPTS_DIR/setup-worktree"

PASS=0
FAIL=0

check() {
    local label="$1"
    local result="$2"

    if [ "$result" = "true" ]; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label"
        FAIL=$((FAIL + 1))
    fi
}

# --- A) Static check: setup-worktree references "origin/" for branch creation ---

check "setup-worktree references origin/ for branch creation" \
    "$(grep -q 'origin/' "$SETUP_WORKTREE" && echo true || echo false)"

# --- B) Main regression test: unpushed commits must not leak into worktree ---

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

ORIGIN_DIR="$TMPDIR/origin.git"
LOCAL_DIR="$TMPDIR/local"
WORKTREE_DIR=""

# Create bare origin repo
git init --bare --initial-branch=main "$ORIGIN_DIR" >/dev/null 2>&1

# Clone origin
git clone "$ORIGIN_DIR" "$LOCAL_DIR" >/dev/null 2>&1
cd "$LOCAL_DIR"

# Configure git identity for commits
git config user.email "test@test.com"
git config user.name "Test User"
git config commit.gpgsign false

# Make initial commit and push to origin
echo "initial" > INITIAL.md
git add INITIAL.md
git commit -m "initial commit" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
PUSHED_SHA=$(git rev-parse HEAD)

# Make second commit locally — do NOT push (simulates unpushed work)
echo "unpushed" > UNPUSHED.md
git add UNPUSHED.md
git commit -m "unpushed commit" >/dev/null 2>&1
LOCAL_HEAD_SHA=$(git rev-parse HEAD)

# Sanity: local HEAD differs from pushed SHA
check "local HEAD differs from pushed SHA (sanity)" \
    "$([ "$LOCAL_HEAD_SHA" != "$PUSHED_SHA" ] && echo true || echo false)"

# Run setup-worktree for a new task
worktree_output=$("$SETUP_WORKTREE" --task test-task 2>/dev/null)
# setup-worktree may emit multiple lines; the last line is the worktree path
WORKTREE_DIR=$(echo "$worktree_output" | tail -1)

# Worktree directory should exist
check "worktree directory exists" \
    "$([ -d "$WORKTREE_DIR" ] && echo true || echo false)"

# Worktree should be on branch loop/test-task
if [ -d "$WORKTREE_DIR" ]; then
    WORKTREE_BRANCH=$(git -C "$WORKTREE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    check "worktree is on branch loop/test-task" \
        "$([ "$WORKTREE_BRANCH" = "loop/test-task" ] && echo true || echo false)"

    WORKTREE_HEAD=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")

    # KEY ASSERTION: worktree HEAD must equal the pushed SHA (not local HEAD)
    check "worktree HEAD equals pushed (remote) SHA" \
        "$([ "$WORKTREE_HEAD" = "$PUSHED_SHA" ] && echo true || echo false)"

    # Unpushed commit must NOT be in worktree
    check "worktree HEAD does not equal local (unpushed) HEAD SHA" \
        "$([ "$WORKTREE_HEAD" != "$LOCAL_HEAD_SHA" ] && echo true || echo false)"

    # Unpushed file must not exist in worktree
    check "UNPUSHED.md does not exist in worktree" \
        "$([ ! -f "$WORKTREE_DIR/UNPUSHED.md" ] && echo true || echo false)"
else
    check "worktree HEAD equals pushed (remote) SHA" "false"
    check "worktree HEAD does not equal local (unpushed) HEAD SHA" "false"
    check "UNPUSHED.md does not exist in worktree" "false"
fi

# --- C) Sync scenario: works when local and remote are in sync ---

ORIGIN2_DIR="$TMPDIR/origin2.git"
LOCAL2_DIR="$TMPDIR/local2"

git init --bare --initial-branch=main "$ORIGIN2_DIR" >/dev/null 2>&1
git clone "$ORIGIN2_DIR" "$LOCAL2_DIR" >/dev/null 2>&1
cd "$LOCAL2_DIR"
git config user.email "test@test.com"
git config user.name "Test User"
git config commit.gpgsign false

echo "synced" > SYNCED.md
git add SYNCED.md
git commit -m "synced commit" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
SYNC_SHA=$(git rev-parse HEAD)

worktree_output2=$("$SETUP_WORKTREE" --task test-sync 2>/dev/null)
WORKTREE2_DIR=$(echo "$worktree_output2" | tail -1)

check "sync scenario: worktree directory exists" \
    "$([ -d "$WORKTREE2_DIR" ] && echo true || echo false)"

if [ -d "$WORKTREE2_DIR" ]; then
    WORKTREE2_HEAD=$(git -C "$WORKTREE2_DIR" rev-parse HEAD 2>/dev/null || echo "")
    check "sync scenario: worktree HEAD equals remote SHA" \
        "$([ "$WORKTREE2_HEAD" = "$SYNC_SHA" ] && echo true || echo false)"
else
    check "sync scenario: worktree HEAD equals remote SHA" "false"
fi

# --- D) Resume scenario: re-running setup-worktree for same task resumes ---

cd "$LOCAL_DIR"
worktree_output_resume=$("$SETUP_WORKTREE" --task test-task 2>/dev/null)
WORKTREE_RESUME=$(echo "$worktree_output_resume" | tail -1)

check "resume scenario: same worktree path returned" \
    "$([ "$WORKTREE_RESUME" = "$WORKTREE_DIR" ] && echo true || echo false)"

if [ -d "$WORKTREE_DIR" ]; then
    WORKTREE_RESUME_HEAD=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")
    check "resume scenario: HEAD unchanged after resume" \
        "$([ "$WORKTREE_RESUME_HEAD" = "$PUSHED_SHA" ] && echo true || echo false)"
else
    check "resume scenario: HEAD unchanged after resume" "false"
fi

# --- Summary ---

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
