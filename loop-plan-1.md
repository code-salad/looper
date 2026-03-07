# Plan: Fix create-github-pr abort when current branch is GitHub default

## Goal

Fix the `create-github-pr` skill so it does not abort when the current branch
happens to be the GitHub default branch but the user intends to PR into a
different base (e.g., on `alpha` wanting to PR into `main`). Also fix diff
commands that fail when the base branch does not exist locally.

## File to Modify

`plugins/looper/skills/create-github-pr/SKILL.md` (single file change)

## Problem Analysis

Three locations in SKILL.md need changes:

1. **Phase 0 Gate (line ~37-44):** The abort condition
   `Current branch IS the default branch` is too aggressive. It prevents
   creating PRs from branches like `alpha` (which may be the GitHub default)
   into `main`.

2. **Phase 1 Diff Commands (line ~52-68):** All `git diff $BASE_BRANCH...HEAD`
   and `git log $BASE_BRANCH..HEAD` commands assume `$BASE_BRANCH` exists
   locally. When it does not (e.g., repo has no local `main`), these fail with
   `fatal: ambiguous argument`.

3. **Error Handling Table (line ~376):** The row
   `On default branch | Abort: "Create a feature branch first."` reinforces
   the broken behavior.

## Implementation Steps

### Step 1: Revise Phase 0 Gate Logic

Replace the current abort rule with smarter logic:

**Current (lines 37-44):**
```
**Gate:** Abort with a clear message if:
- Not in a git repo
- `gh` is not authenticated
- Current branch IS the default branch (main/master) — prompt the user to create a feature branch first

Store:
- `CURRENT_BRANCH` = current branch name
- `BASE_BRANCH` = default branch (main, master, etc.)
```

**New:**
```
**Gate:** Abort with a clear message if:
- Not in a git repo
- `gh` is not authenticated

**Branch resolution:**
- If `CURRENT_BRANCH` != GitHub default branch → set `BASE_BRANCH` = GitHub default branch (normal case)
- If `CURRENT_BRANCH` == GitHub default branch → do NOT abort. Instead:
  1. Look for a plausible base branch: check if `main` or `master` exists
     (locally or on remote) as an alternative target. If the GitHub default IS
     `main`/`master`, check for other common bases like `develop`, `release`.
  2. If a plausible base is found, set `BASE_BRANCH` to that and inform the
     user: "Current branch is the GitHub default. Using <base> as PR target."
  3. If no plausible base is found, prompt the user to specify a
     `--base <branch>` target rather than aborting.

Store:
- `CURRENT_BRANCH` = current branch name
- `BASE_BRANCH` = resolved base branch
```

### Step 2: Fix Phase 1 Diff Commands to Handle Missing Local Refs

Update all diff/log commands in Phase 1a to try `origin/$BASE_BRANCH` as
fallback when the local ref does not exist.

**Current:**
```bash
git diff $BASE_BRANCH...HEAD
git log --oneline $BASE_BRANCH..HEAD
git diff --stat $BASE_BRANCH...HEAD
```

**New:**
Add a ref-resolution step before the diffs:
```bash
# Resolve the base ref: prefer local branch, fall back to remote tracking
if git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
  BASE_REF="$BASE_BRANCH"
elif git rev-parse --verify "origin/$BASE_BRANCH" >/dev/null 2>&1; then
  BASE_REF="origin/$BASE_BRANCH"
else
  # Fetch and retry
  git fetch origin "$BASE_BRANCH" 2>/dev/null
  BASE_REF="origin/$BASE_BRANCH"
fi
```

Then replace all `$BASE_BRANCH` in diff/log commands with `$BASE_REF`.
Also update Phase 1b's `git diff --name-only $BASE_BRANCH...HEAD` reference.

### Step 3: Update Error Handling Table

Change the "On default branch" row from:
```
| On default branch | Abort: "Create a feature branch first." |
```
To:
```
| On default branch | Detect alternate base branch or prompt user for --base target. Do not abort. |
```

### Step 4: Update Phase 4 (PR Create Command)

Ensure `--base "$BASE_BRANCH"` in the `gh pr create` command uses the
resolved base branch, not necessarily the GitHub default. This should already
work if `BASE_BRANCH` is set correctly in Phase 0, but verify the wording
does not imply it must be the GitHub default.

## What NOT to Change

- Phase 2, 3, 5 logic remains unchanged (they use `$BASE_BRANCH` which will
  now be correctly resolved).
- The YAML frontmatter and skill description remain unchanged.
- The Mermaid diagram style guide remains unchanged.

## Acceptance Criteria

1. When `CURRENT_BRANCH == GitHub default branch`, the skill does NOT abort.
   Instead it resolves an alternate base branch or prompts the user.
2. All `git diff` and `git log` commands use a ref-resolution step that falls
   back to `origin/$BASE_BRANCH` when the local branch does not exist.
3. The error handling table no longer says "Abort" for the default-branch case.
4. The skill still aborts correctly when not in a git repo or gh is not
   authenticated.
5. No other behavior is changed -- the rest of the skill works as before.

## Risks

- This is a SKILL.md file (agent instructions, not executable code), so the
  changes are prose/pseudocode that guide an LLM agent. The Doer must preserve
  the existing markdown structure and formatting conventions.
- The branch-resolution logic must be clear enough for an LLM to follow at
  runtime. Keep it concrete with exact bash commands.
