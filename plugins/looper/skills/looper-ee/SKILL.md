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

## Phase 4: Delegate to Looper

```
/looper #$ISSUE_NUMBER $ISSUE_TITLE
```
