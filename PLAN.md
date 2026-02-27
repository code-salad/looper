# Plan: improve-loop-observability — Iteration 1

## Goal

Add 5 targeted observability improvements to `plugins/looper/skills/loop/scripts/loop.sh`
so users can clearly see loop progress at all times.

## Problem Analysis

Current gaps in `loop.sh`:
1. **Silent agent runs** — once a phase starts you see the agent's raw output but no
   indication of elapsed time; hard to tell if it's hung.
2. **Phase timing gated behind `--verbose`** — duration shown only with that flag.
3. **Token usage hidden** — only appears in the final summary, never per-phase.
4. **No ETA** — after iteration 1, no estimate of how many more to go.
5. **No external monitoring** — no way to `watch`/`tail -f` from another terminal.

## Changes (all in `loop.sh`)

### 1. Heartbeat ticker during agent execution

Add two helper functions `start_ticker` / `stop_ticker`.
`start_ticker` forks a background process that prints to stderr every 30 s:

```
  [10:31:45] PLANNER still running... 60s elapsed
```

Called inside `run_phase` around the `"${claude_cmd[@]}"` invocation:
```bash
start_ticker "$phase"
... agent runs ...
stop_ticker
```

Background PID stored in `TICKER_PID`. `stop_ticker` kills it and clears the var.
Also kill on `cleanup` (SIGINT/SIGTERM trap).

### 2. Always show per-phase completion line

After every phase (not just `--verbose`) print one line:

```
  PLANNER done in 45s | tokens in=1 234 out=567
```

Requires tracking `LAST_PHASE_TOKENS_IN` / `LAST_PHASE_TOKENS_OUT` in
`parse_tokens` (currently only accumulates into `TOTAL_TOKENS_IN/OUT`) and then
printing in `run_phase` unconditionally after the phase exits.

### 3. ETA in iteration header

Track `ITER_DURATIONS` array (seconds per completed iteration).
From iteration 2 onward, compute:

```
avg = sum(ITER_DURATIONS) / count
remaining_iters = MAX_ITERATIONS - ITERATION + 1
eta_seconds = avg * remaining_iters
```

Print alongside the iteration banner:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ITERATION 2 of 10 | Elapsed: 5m30s | Avg: 2m45s/iter | ETA: ~27m remaining
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 4. `--status-file <path>` option

Write a JSON snapshot after each phase (and on completion/interruption):

```json
{
  "task": "my-task",
  "iteration": 2,
  "maxIterations": 10,
  "phase": "doer",
  "totalElapsedSeconds": 145,
  "verdict": null,
  "tokensIn": 12340,
  "tokensOut": 5670
}
```

Users can then `watch -n5 cat /tmp/loop-status.json` or `cat` it from another
terminal. Written with `jq -n ...` so it's always valid JSON.

Add `update_status` helper called from `run_phase` start and end, and from the
main loop's verdict check.

### 5. `--log-file <path>` option

Redirect stdout through `tee` at process start:

```bash
if [ -n "$LOG_FILE" ]; then
    exec > >(tee -a "$LOG_FILE")
fi
```

Applied once, right before the main loop. Users can `tail -f "$LOG_FILE"` from
another terminal while the loop runs silently in the background.

## File to Modify

- `plugins/looper/skills/loop/scripts/loop.sh`

## Non-Changes

- No agent `.md` files need editing.
- No other scripts need editing.
- No new files (status/log are runtime outputs, not committed).

## Acceptance Criteria

1. Running the loop prints "still running…" heartbeats every 30 s during each phase.
2. Each phase completion always shows duration and token counts.
3. Iteration headers from iteration 2 onward show elapsed time + ETA.
4. `--status-file /tmp/foo.json` creates a valid JSON file updated each phase.
5. `--log-file /tmp/foo.log` creates a log file that `tail -f` can follow.
6. Existing `--verbose`, `--timeout`, `--interactive` behaviour is unchanged.
7. No new dependencies beyond what's already required (`jq`, `git`, `claude`).
