---
name: looper-ee
description: >-
  Use this skill when a watcher feeds a GitHub issue from an external repo.
  Ensures the repo is cloned locally, changes into it, and delegates to
  the looper skill. Triggered by "/looper-ee <issue_url>".
tools: Bash, Read, Grep, Glob, Skill, Agent
---

# Looper EE (External Execution) Skill

Handles GitHub issues from external repos by ensuring the repo is available
locally, then delegating to the looper skill.

**CRITICAL:** All work MUST happen in an isolated git worktree (the `/looper`
skill creates one). Changes are delivered via a GitHub pull request — never
merged locally into the default branch. The full flow is:
worktree → PDC loop → push branch → create PR → wait CI → squash-merge (or PR-only if DB migrations are present).

---

## Phase 1: Ensure Repo & Parse URL

Run the `ensure-repo` script (located next to this skill at `scripts/ensure-repo`):

```bash
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")/scripts" # or use $CLAUDE_PLUGIN_ROOT
$CLAUDE_PLUGIN_ROOT/skills/looper-ee/scripts/ensure-repo --url "$ARGUMENTS"
```

The script:
- Parses the GitHub issue URL
- Checks `gh auth status`
- Clones to `~/repos/<owner>/<repo>` if missing, or fetches if exists
- Returns JSON: `{"repo_dir": "...", "owner": "...", "repo": "...", "issue_number": "...", "full_repo": "..."}`

**Gate:** If the script exits non-zero, abort and report the error.

Parse the JSON output and store `REPO_DIR`, `ISSUE_NUMBER`, and `FULL_REPO`.

---

## Phase 2: Change to Repo Directory

```bash
cd "$REPO_DIR"
```

---

## Phase 3: Fetch Issue Title

```bash
gh issue view $ISSUE_NUMBER --repo "$FULL_REPO" --json title --jq '.title'
```

Store as `ISSUE_TITLE`.

---

## Phase 3b: Claim the Issue (upstream-aware)

`looper-ee` is entered from two paths:

1. **Fed by `looper-watch`:** the watcher has already run `claim::try_claim`
   (local lock + remote write-then-verify) before spawning this session. The
   issue is already assigned to `@me` and has the `looper-claimed` label,
   and `ClaimGuard` is held for the full session lifetime in the parent
   Rust process. Running the claim protocol again here would cede incorrectly
   (the earliest `looper-claim:` comment belongs to the watcher, not to this
   run).
2. **Invoked manually (`/looper-ee <url>`):** the issue is unclaimed. This
   phase is the only TOCTOU protection against two manual sessions racing.

Detect upstream ownership first, then run the full claim protocol only if
needed. Run the entire block as a **single Bash invocation** so the `EXIT`
trap spans the full claim+verify window and `sleep 3` is not the first
command (Claude Code harness requirements — see `looper-issue/SKILL.md`
phase 1d for the rationale).

```bash
# Detect upstream claim: am I already assigned with the looper-claimed label?
STATE=$(gh issue view "$ISSUE_NUMBER" --repo "$FULL_REPO" \
    --json assignees,labels 2>/dev/null || echo '{}')
ME=$(gh api user --jq .login 2>/dev/null)
UPSTREAM_OWNED=$(echo "$STATE" | jq -r --arg me "$ME" '
    ((.assignees // []) | map(.login) | any(. == $me))
    and ((.labels // []) | map(.name) | any(. == "looper-claimed"))')

if [ "$UPSTREAM_OWNED" = "true" ]; then
    echo "Issue #$ISSUE_NUMBER already claimed upstream (assignee=$ME); skipping claim."
else
    RUN_ID="$(hostname)-$$-$(uuidgen)"

    # Local O_EXCL fast-path inside the external repo (per-target-repo lock).
    LOCK_DIR=".looper/locks"
    mkdir -p "$LOCK_DIR"
    LOCK_FILE="$LOCK_DIR/${ISSUE_NUMBER}.lock"
    if ! (set -o noclobber; echo "$RUN_ID" > "$LOCK_FILE") 2>/dev/null; then
        echo "Issue #$ISSUE_NUMBER is locked locally by another process. Skipping."
        exit 0
    fi
    trap 'rm -f "$LOCK_FILE"' EXIT

    # Label creation is best-effort — assignee + claim comment are load-bearing.
    gh label create looper-claimed --repo "$FULL_REPO" --force 2>/dev/null || true

    gh issue edit "$ISSUE_NUMBER" --repo "$FULL_REPO" \
        --add-assignee @me --add-label looper-claimed || {
        echo "Failed to claim issue #$ISSUE_NUMBER; skipping."
        exit 0
    }

    gh issue comment "$ISSUE_NUMBER" --repo "$FULL_REPO" \
        -b "looper-claim:$RUN_ID" && sleep 3

    WINNER=$(gh issue view "$ISSUE_NUMBER" --repo "$FULL_REPO" --json comments \
      --jq '[.comments[] | select(.body | startswith("looper-claim:"))] | sort_by(.createdAt) | .[0].body' \
      | sed 's/^looper-claim://')

    if [ "$WINNER" != "$RUN_ID" ]; then
        echo "Lost race to $WINNER; ceding issue #$ISSUE_NUMBER."
        gh issue edit "$ISSUE_NUMBER" --repo "$FULL_REPO" \
            --remove-assignee @me --remove-label looper-claimed 2>/dev/null || true
        exit 0
    fi

    echo "Won claim for issue #$ISSUE_NUMBER (run_id=$RUN_ID)."
fi
```

Notes:
- The upstream-owned check is `assignee == @me AND label looper-claimed`.
  When `looper-watch` feeds this session, both are already true because
  `claim::try_claim` set them before spawning claude. When invoked
  manually, both are false and the full protocol runs.
- The lockfile lives at `$REPO_DIR/.looper/locks/<issue>.lock`, so locks
  are scoped per target repo — a race on `owner-a/repo-a#42` does not
  block `owner-b/repo-b#42`.
- **Minor gap:** two *manual* invocations on the same host *after* an
  earlier session has already claimed-and-exited (leaving the assignee +
  label in place) would both see "upstream owned" and proceed. That is
  the correct behaviour: the first invocation is resuming the claim, and
  a concurrent second invocation is the user's explicit choice.

---

## Phase 3c: Pre-Worktree Blocked Check

Before creating a worktree, verify the issue is not blocked. Skip the check
when the issue was already upstream-claimed (the watcher runs the same
check pre-claim, so re-running here is wasted work).

`$UPSTREAM_OWNED` set in Phase 3b does NOT survive across Bash tool calls
(each invocation is a fresh shell), so we re-derive it here.

```bash
SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT}/skills/looper/scripts"

# Re-derive upstream ownership (fresh shell — cannot reuse Phase 3b's var).
STATE=$(gh issue view "$ISSUE_NUMBER" --repo "$FULL_REPO" \
    --json assignees,labels 2>/dev/null || echo '{}')
ME=$(gh api user --jq .login 2>/dev/null)
UPSTREAM_OWNED=$(echo "$STATE" | jq -r --arg me "$ME" '
    ((.assignees // []) | map(.login) | any(. == $me))
    and ((.labels // []) | map(.name) | any(. == "looper-claimed"))')

if [ "$UPSTREAM_OWNED" = "true" ]; then
    echo "Skipping blocked check (upstream-claimed by watcher)."
else
    if ! BLOCK_REASON=$($SCRIPTS_DIR/check-blocked --issue "$ISSUE_NUMBER" --repo "$FULL_REPO" 2>&1); then
        echo "Issue #$ISSUE_NUMBER is blocked: $BLOCK_REASON"
        echo "Aborting before worktree creation. Resolve the blocker, then retry."
        # Best-effort: release the claim we just took.
        gh issue edit "$ISSUE_NUMBER" --repo "$FULL_REPO" \
            --remove-assignee @me --remove-label looper-claimed 2>/dev/null || true
        exit 0
    fi
fi
```

Notes:
- The upstream-owned re-derivation matches Phase 3b exactly: `assignee == @me
  AND label looper-claimed`. When `looper-watch` feeds this session, both are
  true; otherwise both are false.
- On block, we release the claim so a future run (after the blocker closes)
  can pick the issue back up cleanly. Best-effort; we do not fail if
  release fails.
- The exit is `0`, not non-zero — being blocked is a normal short-circuit.

---

## Phase 4: Create Worktree

**CRITICAL:** You MUST create a worktree before delegating to the looper skill.
Never run the PDC loop directly on the default branch.

Sanitize the issue title into a kebab-case task name (same logic as looper skill):
lowercase, replace spaces/underscores with hyphens, remove non-alphanumeric
characters (except hyphens), truncate to 50 characters, strip leading/trailing
hyphens. Prepend the issue number.

```bash
TASK_NAME=$(echo "$ISSUE_NUMBER-$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | sed 's/[^a-z0-9-]//g' | cut -c1-50 | sed 's/^-*//;s/-*$//')
```

Resolve `SCRIPTS_DIR` for the external repo (use the plugin root, not the
external repo):

```bash
SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT}/skills/looper/scripts"
```

Create the worktree:

```bash
WORKTREE_DIR=$($SCRIPTS_DIR/setup-worktree --task "$TASK_NAME")
cd "$WORKTREE_DIR"
```

**Gate:** If `setup-worktree` exits non-zero or `WORKTREE_DIR` is empty, abort.

Verify you are on a `loop/` branch:

```bash
git branch --show-current | grep -q '^loop/' || { echo "ERROR: not on a loop/ branch"; exit 1; }
```

---

## Phase 5: Delegate to Looper

```
/looper #$ISSUE_NUMBER $ISSUE_TITLE
```

The looper skill will detect the existing worktree (via `setup-worktree`
returning the existing path) and resume from there.
