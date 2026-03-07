---
name: looper-issue
description: >-
  Use this skill when the user wants to automatically pick up an open GitHub
  issue and work on it. Finds an unassigned, non-blocked issue, assigns it
  to the current user, and invokes the looper skill. Triggered by "/looper-issue".
tools: Bash, Read, Grep, Glob
---

# Looper Issue Skill

Automatically selects an open, unassigned, non-blocked GitHub issue, assigns it
to the current user, and delegates to the existing `looper` skill.

## Prerequisites

- Must be in a git repository hosted on GitHub
- `gh` CLI must be installed and authenticated

---

## Phase 0: Preflight Checks

Run these checks:

```bash
# Check 1: Confirm inside a git repo
git rev-parse --is-inside-work-tree

# Check 2: Confirm gh CLI is authenticated
gh auth status
```

**Gate:** Abort with a clear message if:
- Not in a git repo → "This is not a git repository."
- `gh` is not authenticated → "Please run `gh auth login` first."

---

## Phase 1: Fetch Open Unassigned Issues

```bash
gh issue list --state open --search "no:assignee" --limit 20 \
  --json number,title,labels,body,createdAt
```

- If the result is an empty array, inform the user:
  > "No open unassigned issues found."
  and exit.

Store the result as `ISSUES`.

---

## Phase 2: Filter Out Blocked Issues

For each issue in `ISSUES`, apply the three blocking checks below. Remove any
issue that fails at least one check.

### 2a. Label-based blocking

Skip (block) the issue if any of its labels contain "blocked" or "dependencies"
(case-insensitive match).

```
labels[].name | ascii_downcase | contains("blocked") or contains("dependencies")
```

### 2b. Task-list dependency references

Parse the issue body for lines matching either of these patterns:
- `- [ ] Depends on #N`
- `- [ ] #N`

(where `N` is one or more digits)

For each referenced issue number `N` found, check whether it is still open:

```bash
gh issue view N --json state --jq '.state'
```

If the result is `"OPEN"`, the issue is blocked. Skip it.

### 2c. "Blocked by" references

Parse the issue body for lines matching the pattern:
- `Blocked by #N` (case-insensitive)

For each referenced issue number `N`, check whether it is still open:

```bash
gh issue view N --json state --jq '.state'
```

If the result is `"OPEN"`, the issue is blocked. Skip it.

---

## Phase 3: Select Issue

- If no eligible issues remain after Phase 2, inform the user:
  > "All open unassigned issues are currently blocked."
  and exit.

- Otherwise, sort the remaining issues by `createdAt` ascending and select the
  first (oldest) issue.

Store the selected issue's number as `NUMBER` and its title as `TITLE`.

---

## Phase 4: Assign Issue

```bash
gh issue edit $NUMBER --add-assignee @me
```

- **Success:** Log:
  > "Assigned issue #`$NUMBER` to current user."
- **Failure:** Warn:
  > "Could not assign issue #`$NUMBER`. Continuing anyway."
  Do NOT abort — proceed to Phase 5 regardless.

---

## Phase 5: Delegate to Looper

Invoke the `looper` skill with the selected issue reference:

```
/looper #$NUMBER $TITLE
```

This hands off entirely to the existing looper skill, which will:
- Sanitize the task name from the argument
- Create or resume an isolated worktree
- Run the Plan-Do-Check loop

---

## Error Handling

| Scenario | Action |
|----------|--------|
| Not a git repo | Abort: "This is not a git repository." |
| `gh` not authenticated | Abort: "Please run `gh auth login` first." |
| `gh issue list` fails | Abort: report the error message from `gh` to the user |
| No open unassigned issues | Inform: "No open unassigned issues found." and exit |
| All issues blocked | Inform: "All open unassigned issues are currently blocked." and exit |
| Assignment failure | Warn: "Could not assign issue #N. Continuing anyway." and continue |
