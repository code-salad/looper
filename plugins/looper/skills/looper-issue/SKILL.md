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

## Phase 0: Authenticate GitHub CLI

```bash
gh auth status
```

**Gate:** Abort if `gh` is not authenticated → "Please run `gh auth login` first."

---

## Phase 1: Claim an Issue (before anything else)

Find, select, and assign an issue **immediately** to minimize the race window
where two parallel invocations could claim the same issue.

### 1a. Fetch open unassigned issues

```bash
gh issue list --state open --search "no:assignee" --limit 20 \
  --json number,title,labels,body,createdAt
```

- If the result is an empty array, inform the user:
  > "No open unassigned issues found."
  and exit.

Store the result as `ISSUES`.

### 1b. Filter out blocked issues

For each issue in `ISSUES`, check if it is blocked using `check-blocked`:

```bash
SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/looper}/skills/looper/scripts"
ELIGIBLE_ISSUES=()
for issue_number in $(echo "$ISSUES" | jq -r '.[].number'); do
    if $SCRIPTS_DIR/check-blocked --issue "$issue_number" >/dev/null 2>&1; then
        ELIGIBLE_ISSUES+=("$issue_number")
    fi
done
```

`check-blocked` applies three checks: label-based blocking ("blocked" or
"dependencies" labels), task-list dependency references (`- [ ] Depends on #N`
or `- [ ] #N`), and "Blocked by #N" references. Exit 0 means not blocked.

### 1c. Select issue

- If no eligible issues remain after filtering, inform the user:
  > "All open unassigned issues are currently blocked."
  and exit.

- Otherwise, sort the remaining issues by `createdAt` ascending and select the
  first (oldest) issue.

Store the selected issue's number as `NUMBER` and its title as `TITLE`.

### 1d. Generate run id

```bash
RUN_ID="$(hostname)-$$-$(uuidgen)"
```

### 1e. Local lock

```bash
LOCK_DIR=".looper/locks"
mkdir -p "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/${NUMBER}.lock"
# O_EXCL via noclobber — atomic, no TOCTOU race
if ! (set -o noclobber; echo "$RUN_ID" > "$LOCK_FILE") 2>/dev/null; then
    echo "Issue #$NUMBER is locked locally by another process. Skipping."
    exit 0
fi
trap 'rm -f "$LOCK_FILE"' EXIT
```

The EXIT trap keeps the lock file in place for the lifetime of this shell
session (which encompasses the `/looper` invocation). The lockfile is
automatically removed when the session exits.

### 1f. Remote claim

```bash
# Label creation is best-effort — the assignee + comment are the
# load-bearing parts of the claim protocol.
gh label create looper-claimed --force 2>/dev/null || true

gh issue edit "$NUMBER" --add-assignee @me --add-label looper-claimed || {
    rm -f "$LOCK_FILE"
    echo "Failed to claim issue #$NUMBER; skipping."
    exit 0
}

gh issue comment "$NUMBER" -b "looper-claim:$RUN_ID" || {
    rm -f "$LOCK_FILE"
    echo "Failed to post claim comment for #$NUMBER; skipping."
    exit 0
}
```

### 1g. Settle and verify (earliest-comment-wins)

```bash
sleep 3

WINNER=$(gh issue view "$NUMBER" --json comments \
  --jq '[.comments[] | select(.body | startswith("looper-claim:"))] | sort_by(.createdAt) | .[0].body' \
  | sed 's/^looper-claim://')

if [ "$WINNER" != "$RUN_ID" ]; then
    echo "Lost race to $WINNER; ceding issue #$NUMBER."
    gh issue edit "$NUMBER" --remove-assignee @me --remove-label looper-claimed 2>/dev/null || true
    rm -f "$LOCK_FILE"
    exit 0
fi

echo "Won claim for issue #$NUMBER (run_id=$RUN_ID)."
```

Both instances evaluate the same GitHub-ordered comment list, so they always
agree on the winner without a central lock. A 3-second settle window is well
above observed GitHub comment replication lag. See `crates/looper-watch/src/claim.rs`
for the equivalent Rust implementation and detailed commentary on edge cases.

---

## Phase 2: Delegate to Looper

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
| `gh` not authenticated | Abort: "Please run `gh auth login` first." |
| `gh issue list` fails | Abort: report the error message from `gh` to the user |
| No open unassigned issues | Inform: "No open unassigned issues found." and exit |
| All issues blocked | Inform: "All open unassigned issues are currently blocked." and exit |
| Assignment failure | Warn: "Could not assign issue #N. Continuing anyway." and continue |
