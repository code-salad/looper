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

Resolve the `looper-watch` launcher:

```bash
LOOPER_WATCH="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/looper}/bin/looper-watch"
```

**Gate:** If the launcher does not exist, abort:
> "looper-watch launcher not found at $LOOPER_WATCH"

---

## Phase 2: Start Watcher

Convert `INTERVAL` from minutes to seconds (multiply by 60). Launch in the background:

```bash
"$LOOPER_WATCH" --repo "$REPO" --interval "$INTERVAL_SECONDS" &
```

Report to the user:
> "looper-watch started for `<repo>` polling every `<interval>` minutes. Attach to tmux sessions to observe progress."

---

## Phase 3: Confirm

```bash
"$LOOPER_WATCH" --repo "$REPO" --once --dry-run
```

Show the user which issues are currently open and eligible.
