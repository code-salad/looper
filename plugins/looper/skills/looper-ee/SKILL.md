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
worktree → PDC loop → push branch → create PR → wait CI → squash merge.

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
