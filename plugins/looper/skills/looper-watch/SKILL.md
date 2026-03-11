---
name: looper-watch
description: >-
  Set up a GitHub issue watcher that polls a repo for open unassigned issues
  and automatically works on them via looper. Triggered by
  "/looper-watch <owner/repo> [interval_minutes]".
tools: Bash, Read
---

# Looper Watch Skill

Starts the `looper-watch` standalone binary which continuously polls a GitHub
repo for open, unassigned, non-blocked issues and feeds them to looper-ee.

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

Check that `looper-watch` is installed:

```bash
which looper-watch
```

**Gate:** If not found, tell the user to install it:
> "looper-watch binary not found. Install it from the releases page or build from `crates/looper-watch`."

---

## Phase 2: Start Watcher

Convert `INTERVAL` from minutes to seconds (multiply by 60). Launch in the background:

```bash
looper-watch --repo "$REPO" --interval "$INTERVAL_SECONDS" &
```

Report to the user:
> "looper-watch started for `<repo>` polling every `<interval>` minutes. Attach to tmux sessions to observe progress."

---

## Phase 3: Confirm

```bash
looper-watch --repo "$REPO" --once --dry-run
```

Show the user which issues are currently open and eligible.
