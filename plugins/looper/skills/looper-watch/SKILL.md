---
name: looper-watch
description: >-
  Set up a GitHub issue watcher that polls a repo for open unassigned issues
  and automatically works on them via looper. Triggered by
  "/looper-watch <owner/repo> [interval_minutes]".
tools: Bash, Read
---

# Looper Watch Skill

Starts a watcher that continuously polls a GitHub repo for open, unassigned,
non-blocked issues and feeds them to looper-ee.

The first poll runs immediately on setup — no need to wait for the first
cron interval.

---

## Phase 0: Parse Arguments

The argument format is: `<owner/repo> [interval_minutes]`

- `REPO` — required, GitHub repo in `owner/repo` format
- `INTERVAL` — optional, polling interval in minutes (default: 10)

**Gate:** If no repo is provided, abort:
> "Usage: /looper-watch owner/repo [interval_minutes]"

---

## Phase 1: Validate

```bash
gh auth status
```

**Gate:** Abort if not authenticated.

Verify the repo exists:

```bash
gh repo view "$REPO" --json name --jq '.name'
```

**Gate:** Abort if repo not found.

---

## Phase 2: Start Watcher

Call the `setup_watcher` MCP tool with:
- `repo`: the parsed `REPO`
- `interval_minutes`: the parsed `INTERVAL`

Report the watcher ID and configuration to the user:
> "Watcher started for `<repo>` polling every `<interval>` minutes. Watcher ID: `<id>`. First poll is running now."

---

## Phase 3: Confirm

Call the `list_watchers` MCP tool to show the user all active watchers.
