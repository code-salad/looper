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

### 1a. Fetch ready issues

```bash
SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/looper}/skills/looper/scripts"
LRI_STATS=$(mktemp)
READY_JSON=$($SCRIPTS_DIR/list-ready-issues --json --limit 20 2>"$LRI_STATS")
SUMMARY=$(cat "$LRI_STATS")
rm -f "$LRI_STATS"
echo "$SUMMARY"   # e.g. "Found 3 ready issues (2 blocked skipped)"
```

`list-ready-issues` is the single source of truth for "what's pickable":
it wraps `gh issue list` + per-issue `check-blocked` and emits a JSON array
sorted oldest-first, plus the stderr summary line.

If `READY_JSON` is `[]`:
> "No open unassigned ready issues found (none open, or all are blocked)."
and exit.

### 1b. Select issue

`list-ready-issues --json` already emits oldest-first. Pick the first entry:

```bash
NUMBER=$(echo "$READY_JSON" | jq -r '.[0].number')
TITLE=$(echo "$READY_JSON" | jq -r '.[0].title')
echo "Picking #$NUMBER: $TITLE"
```

Store as `NUMBER` and `TITLE` for the claim phase below.

### 1d. Claim the issue (local lock → remote claim → settle → verify)

Run this entire block as a **single Bash invocation** so the `EXIT` trap
lives for the full claim+verify window and the `sleep` is not the first
command (both are Claude Code harness requirements):

```bash
RUN_ID="$(hostname)-$$-$(uuidgen)"

# Local O_EXCL fast-path — short-circuits same-host races before any API call.
LOCK_DIR=".looper/locks"
mkdir -p "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/${NUMBER}.lock"
if ! (set -o noclobber; echo "$RUN_ID" > "$LOCK_FILE") 2>/dev/null; then
    echo "Issue #$NUMBER is locked locally by another process. Skipping."
    exit 0
fi
trap 'rm -f "$LOCK_FILE"' EXIT

# Label creation is best-effort — assignee + claim comment are load-bearing.
gh label create looper-claimed --force 2>/dev/null || true

gh issue edit "$NUMBER" --add-assignee @me --add-label looper-claimed || {
    echo "Failed to claim issue #$NUMBER; skipping."
    exit 0
}

gh issue comment "$NUMBER" -b "looper-claim:$RUN_ID" && sleep 3

# Earliest-comment-wins verify. Both instances see the same GitHub-ordered
# list, so they always agree on the winner without a central lock.
WINNER=$(gh issue view "$NUMBER" --json comments \
  --jq '[.comments[] | select(.body | startswith("looper-claim:"))] | sort_by(.createdAt) | .[0].body' \
  | sed 's/^looper-claim://')

if [ "$WINNER" != "$RUN_ID" ]; then
    echo "Lost race to $WINNER; ceding issue #$NUMBER."
    gh issue edit "$NUMBER" --remove-assignee @me --remove-label looper-claimed 2>/dev/null || true
    exit 0
fi

echo "Won claim for issue #$NUMBER (run_id=$RUN_ID)."
```

Notes:
- **Single block is required.** Each Bash tool invocation is a fresh shell,
  so splitting this across multiple calls would fire the `EXIT` trap (and
  delete the lockfile) between steps — defeating the fast-path.
- `sleep 3` is not the first command of the invocation (the earlier `gh`
  calls run first), so it is not blocked by the Claude Code harness rule
  against leading `sleep N` with N ≥ 2. If you refactor this block, keep
  that invariant.
- The lockfile is cleaned up when this shell exits — that's fine, because
  by that point the remote claim is already authoritative for any future
  instance. See `crates/looper-watch/src/claim.rs` for the Rust equivalent
  where the `ClaimGuard` is held for the full claude session lifetime.

---

## Phase 2: Delegate to Looper

Invoke the `looper` skill with the selected issue reference:

```
/looper #$NUMBER $TITLE
```

This hands off entirely to the existing looper skill, which will:
- Sanitize the task name from the argument
- Resolve the current worktree (Claude Desktop creates the worktree before invocation)
- Run the Plan-Do-Check loop

---

## Error Handling

| Scenario | Action |
|----------|--------|
| `gh` not authenticated | Abort: "Please run `gh auth login` first." |
| `gh issue list` fails | Abort: report the error message from `gh` to the user |
| `READY_JSON == []` (none open OR all blocked) | Inform: "No open unassigned ready issues found (none open, or all are blocked)." and exit |
| Assignment failure | Warn: "Could not assign issue #N. Continuing anyway." and continue |
