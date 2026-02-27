---
name: initiate-worktree
description: Creates a git worktree in .worktrees/<name>. Ensures .worktrees is gitignored and committed, then creates the worktree and changes into it.
argument-hint: "<worktree-name>"
user-invocable: true
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
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

3. **Create the worktree** — Run:

   ```bash
   git worktree add .worktrees/$ARGUMENTS
   ```

   This creates a new branch with the same name as the worktree. If the user needs a specific base branch or an existing branch, they can pass additional git flags after the name.

4. **Change into the worktree directory** — Run:

   ```bash
   cd .worktrees/$ARGUMENTS
   ```

   Confirm to the user that the working directory is now inside the worktree and show the current branch.

## Error handling

- If the worktree already exists, inform the user and offer to just `cd` into it.
- If the branch name already exists, use `git worktree add .worktrees/$ARGUMENTS $ARGUMENTS` to attach to the existing branch.
