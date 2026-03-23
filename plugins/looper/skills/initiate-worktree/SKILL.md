---
name: initiate-worktree
description: Use this skill when the user wants to create a git worktree. Creates a worktree in .worktrees/<name>, ensures .worktrees is gitignored and committed, then changes into it.
tools: Bash, Read, Edit, Write, Grep, Glob
---

# Worktree Skill

Create an isolated git worktree under `.worktrees/` in the repo root.

**Argument:** `$ARGUMENTS` is the worktree name.

## Steps

1. **Validate argument** — If `$ARGUMENTS` is empty, ask the user for a worktree name. Do not proceed without one.

2. **Ensure `.worktrees` is gitignored** — Check if `.gitignore` exists at the repo root and whether it already contains a line that ignores `.worktrees`. If not, append `.worktrees` to `.gitignore` (create the file if needed). Then stage and commit `.gitignore` with the message:

   ```
   chore: gitignore .worktrees
   ```

   Skip the commit if `.gitignore` was already up to date.

3. **Guard against core.bare=true** — Before creating the worktree, check and fix `core.bare`:

   ```bash
   bare_val=$(git config --get core.bare 2>/dev/null || echo "")
   if [ "$bare_val" = "true" ]; then
       echo "WARNING: core.bare=true detected, fixing..."
       git config core.bare false
   fi
   ```

4. **Create the worktree** — Run:

   ```bash
   git worktree add .worktrees/$ARGUMENTS
   ```

   This creates a new branch with the same name as the worktree. If the user needs a specific base branch or an existing branch, they can pass additional git flags after the name.

5. **Guard again after creation** — Worktree creation can set `core.bare=true` on the parent repo:

   ```bash
   git config core.bare false
   ```

6. **Change into the worktree directory** — Run:

   ```bash
   cd .worktrees/$ARGUMENTS
   ```

   Confirm to the user that the working directory is now inside the worktree and show the current branch.

## Error handling

- If the worktree already exists, inform the user and offer to just `cd` into it.
- If the branch name already exists, use `git worktree add .worktrees/$ARGUMENTS $ARGUMENTS` to attach to the existing branch.
