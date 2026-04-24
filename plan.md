# Plan — iteration 2: scrub stale "result-file path" framing

## Goal

Finish iteration 1's canonical-spawn migration by rewriting the four
documentation blocks the Checker flagged as BLOCKERs. Every instance of
"read the result-file path" framing (and its close synonym
"read result file") must be removed from:

1. `plugins/looper/skills/looper/SKILL.md` (lines 15-22, `## Agent spawning mode` body)
2. `plugins/looper/agents/planner.md` (lines 20-29, `## Instructions` preamble paragraph)
3. `plugins/looper/agents/doer.md` (lines 37-46, step-1 spawn-mode paragraph)
4. `plugins/looper/agents/checker.md` (lines 19-28, `## Instructions` preamble paragraph)

Two regression assertions are added in the red phase so neither
`result-file path` nor the unhyphenated synonym `read result file` can
reappear in these four files without a test-suite failure.

## Tech Stack Constraints

(unchanged from iteration 1 — see 7d2c8c7 — plain-markdown docs edit +
bash regression test under `tests/`, no framework or language change.)

## Files to modify

### Red phase (do-red commit)

- `tests/test-agent-spawn-migration.sh` — add TWO regression loops that
  assert none of the four files above contain the literal string
  `result-file path`, nor the literal string `read result file`. Both
  loops must FAIL against the current (pre-green) tree: every target
  file still contains `result-file path`, and `looper/SKILL.md` line 21
  additionally contains `read result file`. Both loops must PASS after
  the green phase.

### Green phase (do-green commit)

- `plugins/looper/skills/looper/SKILL.md` — rewrite lines 15-22.
- `plugins/looper/agents/planner.md` — rewrite lines 20-29.
- `plugins/looper/agents/doer.md` — rewrite lines 37-46.
- `plugins/looper/agents/checker.md` — rewrite lines 19-28.

## Do NOT modify

- `plugins/looper/skills/subagents/scripts/spawn-agent` — script already
  correct (AC #1, #2, #7 pass in iter 1).
- `plugins/looper/skills/subagents/SKILL.md` — already reframed (AC #5
  passes); its canonical wording is the template the 4 docs above will
  adopt.
- `plugins/looper/skills/looper/SKILL.md` line 13 (`Never run the PDC
  loop inline.`) and lines 34-48 (`### 0. Verify subagent dispatch is
  available` + body) — `tests/test-fail-fast-gate.sh` pins these by
  exact line position and content.
- The `**Never improvise PDC work inline.**` paragraph in all three
  agent files — must stay at the same line position after the edit so
  `test-fail-fast-gate.sh` Test 5 (which checks ordering relative to
  `## Instructions`) continues to pass. The replacement block must
  occupy the **same number of lines** as the current block so the
  Never-improvise paragraph does not drift.

## Current text (to be replaced)

### Location 1 — `plugins/looper/skills/looper/SKILL.md` lines 15-22 (8 lines)

```
Spawn subagents with `claude-spawn-agent <agent-name> <prompt>` invoked via
the Bash tool with `run_in_background: true`. The Bash tool returns
immediately; the parent receives an automatic completion notification when
the subprocess exits — read the result-file path printed on stdout then.
No polling is required.

- Sync: `Bash(command="claude-spawn-agent X Y", run_in_background=true)` → completion notification → read result file.
- Parallel fan-out: several `Bash(run_in_background=true, ...)` calls in one message, or `claude-spawn-agent X Y > /tmp/file.txt &` + `wait`.
```

### Location 2 — `plugins/looper/agents/planner.md` lines 20-29 (10 lines)

```
Spawn subagents with `claude-spawn-agent <agent-name> <prompt>`. For a
single subagent, invoke it through the Bash tool with
`run_in_background: true` — the Bash tool returns immediately with a task
handle and the parent receives an automatic completion notification when
the subprocess exits; read the result-file path it printed on stdout
then, no polling required. For parallel fan-out (multiple subagents at
once), redirect each subagent's stdout to a temp file and `&`/`wait`:
`claude-spawn-agent X Y > /tmp/a.txt & claude-spawn-agent X Z > /tmp/b.txt & wait`.
`claude-spawn-agent` is on `PATH` in every Claude Code context and
self-locates its plugin root — no env-var setup is required.
```

### Location 3 — `plugins/looper/agents/doer.md` lines 37-46 (10 lines, inside step 1 — note 3-space indent)

```
   Spawn subagents with `claude-spawn-agent <agent-name> <prompt>`. For a
   single subagent, invoke it through the Bash tool with
   `run_in_background: true` — the Bash tool returns immediately with a task
   handle and the parent receives an automatic completion notification when
   the subprocess exits; read the result-file path it printed on stdout
   then, no polling required. For parallel fan-out (multiple subagents at
   once), redirect each subagent's stdout to a temp file and `&`/`wait`:
   `claude-spawn-agent X Y > /tmp/a.txt & claude-spawn-agent X Z > /tmp/b.txt & wait`.
   `claude-spawn-agent` is on `PATH` in every Claude Code context and
   self-locates its plugin root — no env-var setup is required.
```

### Location 4 — `plugins/looper/agents/checker.md` lines 19-28 (10 lines)

```
Spawn subagents with `claude-spawn-agent <agent-name> <prompt>`. For a
single subagent, invoke it through the Bash tool with
`run_in_background: true` — the Bash tool returns immediately with a task
handle and the parent receives an automatic completion notification when
the subprocess exits; read the result-file path it printed on stdout
then, no polling required. For parallel fan-out (multiple subagents at
once), redirect each subagent's stdout to a temp file and `&`/`wait`:
`claude-spawn-agent X Y > /tmp/a.txt & claude-spawn-agent X Z > /tmp/b.txt & wait`.
`claude-spawn-agent` is on `PATH` in every Claude Code context and
self-locates its plugin root — no env-var setup is required.
```

## Replacement text (exact, verbatim)

The replacement is derived from `plugins/looper/skills/subagents/SKILL.md`
lines 9-13 + 80-83 + 92-102 — that file is authoritative and is NOT
changing this iteration, so the agent docs and looper SKILL.md will
inherit its canonical phrasing.

### Replacement 1 — `looper/SKILL.md` lines 15-22 (MUST be exactly 8 lines to preserve surrounding anchors)

```
Spawn subagents with `claude-spawn-agent <agent-name> <prompt>` invoked
via the Bash tool. It is the drop-in for the built-in `Agent` tool inside
subagent contexts: the subagent's text response is printed directly to
stdout (foreground) or delivered inline in the completion notification
(background).

- Sync: `Bash(command="claude-spawn-agent X Y", run_in_background=true)` → completion notification fires on finish; its output contains the subagent's response text inline.
- Parallel fan-out: several `claude-spawn-agent X Y > /tmp/file.txt &` calls in one Bash block, followed by `wait`.
```

Line count: 8 (matches original — SKILL.md anchors around line 13
`Never run the PDC loop inline` and line 34 `### 0.` are preserved
unchanged, and the `## Agent spawning mode` section total stays at 20
lines, satisfying the existing `≤ 20` test assertion).

### Replacement 2 — `planner.md` lines 20-29 (MUST be exactly 10 lines)

```
Spawn subagents with `claude-spawn-agent <agent-name> <prompt>` invoked
via the Bash tool. It is the drop-in for the built-in `Agent` tool inside
subagent contexts: the subagent's text response is printed directly to
stdout (foreground) or delivered inline in the completion notification
(background). For a single subagent:
`Bash(command="claude-spawn-agent X Y", run_in_background=true)` —
the Bash tool returns immediately; an automatic completion notification
fires on subprocess exit and its output contains the subagent's response
text inline. For parallel fan-out, redirect each subagent's stdout to a
temp file and `&`/`wait` — no polling, the response arrives directly.
```

Line count: 10 (matches original — the blank line 30 and the
`**Never improvise PDC work inline.**` paragraph starting at line 31
stay at identical positions).

### Replacement 3 — `doer.md` lines 37-46 (MUST be exactly 10 lines, with 3-space indent since this block is inside step 1's indented body)

```
   Spawn subagents with `claude-spawn-agent <agent-name> <prompt>` invoked
   via the Bash tool. It is the drop-in for the built-in `Agent` tool
   inside subagent contexts: the subagent's text response is printed
   directly to stdout (foreground) or delivered inline in the completion
   notification (background). For a single subagent:
   `Bash(command="claude-spawn-agent X Y", run_in_background=true)` — the
   Bash tool returns immediately; the completion notification fires on
   subprocess exit and its output contains the response text inline. For
   parallel fan-out, redirect each subagent's stdout to a temp file and
   `&`/`wait` — no polling, the response arrives directly.
```

Line count: 10 (matches original; three-space indent preserved because
the surrounding list item at line 28 uses that indent).

### Replacement 4 — `checker.md` lines 19-28 (MUST be exactly 10 lines)

```
Spawn subagents with `claude-spawn-agent <agent-name> <prompt>` invoked
via the Bash tool. It is the drop-in for the built-in `Agent` tool inside
subagent contexts: the subagent's text response is printed directly to
stdout (foreground) or delivered inline in the completion notification
(background). For a single subagent:
`Bash(command="claude-spawn-agent X Y", run_in_background=true)` —
the Bash tool returns immediately; an automatic completion notification
fires on subprocess exit and its output contains the subagent's response
text inline. For parallel fan-out, redirect each subagent's stdout to a
temp file and `&`/`wait` — no polling, the response arrives directly.
```

Line count: 10 (matches original).

## Semantic contract carried by every replacement

Every replacement block (all 4 locations) MUST mention:

1. `claude-spawn-agent` as the canonical drop-in for the `Agent` tool in
   subagent contexts (NO "fallback" language).
2. `Bash(command="claude-spawn-agent X Y")` / foreground invocation
   returns the subagent's text on stdout.
3. `Bash(command="claude-spawn-agent X Y", run_in_background=true)` —
   background invocation fires a task-completion notification whose
   output contains the response text inline.
4. Parallel fan-out pattern: stdout-redirect + `&` + `wait`.

And every replacement block MUST NOT contain:

- the phrase `result-file path`
- the phrase `read result file` (no hyphen)
- the phrase `read the result file` / `read a result file`
- any reference to `.output` file (we describe it as "output contains
  the response text inline", not as a file to read)
- any reference to `--async`
- any reference to `subagent-response-`
- any reference to polling / "poll" / "while [ ! -s"

## Tests to write first (red phase)

### New assertions appended to `tests/test-agent-spawn-migration.sh`

Append the following block **after** the AC7 loop (after the existing
`done` at line 119, before the final `echo` at line 121) — use variable
names already declared at the top of the file (`LOOPER_SKILL`, `PLANNER`,
`DOER`, `CHECKER` — confirmed present at lines 9, 12, 13, 14):

```bash
# AC iter-2 (a) — stale 'result-file path' framing scrubbed.
for f in "$LOOPER_SKILL" "$PLANNER" "$DOER" "$CHECKER"; do
    assert_file_not_contains "$(basename "$f"): no 'result-file path' framing" \
        "$f" 'result-file path'
done

# AC iter-2 (b) — unhyphenated synonym 'read result file' also scrubbed.
# (looper/SKILL.md:21 currently contains the bullet phrase
# "→ completion notification → read result file." — the green phase
# removes it. Guarding here prevents future reintroduction.)
for f in "$LOOPER_SKILL" "$PLANNER" "$DOER" "$CHECKER"; do
    assert_file_not_contains "$(basename "$f"): no 'read result file' synonym" \
        "$f" 'read result file'
done
```

**Red phase expected behaviour.** Before the green edits:
- Suite-level outcome: `test-agent-spawn-migration.sh` fails — so
  `run-corner-case-tests.sh` reports `14 suites passed, 1 suite failed`.
- Assertion-level detail inside that one suite: **5 new FAIL lines**
  will appear (4 files × `result-file path`, plus 1 file — SKILL.md —
  × `read result file`). The other three files do not contain
  `read result file`, so those three assertions in the (b) loop PASS
  in red — only SKILL.md's (b) assertion fails in red.
- The Doer should not be surprised that individual-assertion counts
  (4+1 = 5 fails in red) differ from the suite count (1 suite failed).

**Green phase expected behaviour.** After the four doc rewrites:
- All 8 new assertions (4 × (a) loop + 4 × (b) loop) pass.
- `test-agent-spawn-migration.sh` is fully green again.
- The existing 15-suite runner (`tests/run-corner-case-tests.sh`)
  returns to `15 suites passed, 0 suites failed`.
- `tests/test-fail-fast-gate.sh` stays 21/21 green because:
  - `looper/SKILL.md` line 13 (`Never run the PDC loop inline`) is not
    touched.
  - `looper/SKILL.md` lines 34-48 (step-0 gate) are not touched.
  - Each agent file's `**Never improvise PDC work inline.**` paragraph
    stays at the same line number (replacement blocks preserve line
    counts — 8/10/10/10).

### Why no other tests are needed

- The refactor has zero runtime impact (pure docs edit).
- No new script, flag, or CLI surface is added.
- The existing `test-spawn-agent-canonical.sh`, `test-fail-fast-gate.sh`,
  and `test-agent-spawn-migration.sh` already cover every mechanism
  mentioned in the replacement text (AC1-AC7 from iter 1 still pass).

## Corner cases (each must be explicitly verified)

Pure-docs corner cases — the Doer must verify each by grep / line-count:

1. **Phrase scrubbing is total across all four files (primary).**
   Verification:
   `grep -n "result-file path" plugins/looper/skills/looper/SKILL.md plugins/looper/agents/{planner,doer,checker}.md`
   returns zero hits after green. Expected: 0 matches.
2. **No regression-via-synonym.** Verification:
   `grep -nE "read (the )?result file|result file to read" plugins/looper/skills/looper/SKILL.md plugins/looper/agents/{planner,doer,checker}.md`
   returns zero hits — we are not allowed to rename `result-file path`
   into a pseudo-equivalent phrase. (Red-phase state: SKILL.md line 21
   matches `read result file`; green-phase state: zero matches.)
3. **`**Never improvise PDC work inline.**` stays at its original line
   number in each of the three agent files.** Verification:
   `grep -n "Never improvise PDC work inline" plugins/looper/agents/{planner,doer,checker}.md`
   returns `planner.md:31`, `doer.md:22`, `checker.md:30`. (Same as
   pre-edit line positions.)
4. **`**Never run the PDC loop inline**` stays at SKILL.md line 13.**
   Verification:
   `grep -n "Never run the PDC loop inline" plugins/looper/skills/looper/SKILL.md`
   returns `13:`. Unchanged.
5. **Step-0 fail-fast gate stays pinned at `looper/SKILL.md` line 34.**
   Verification:
   `grep -n "^### 0\. Verify subagent dispatch is available" plugins/looper/skills/looper/SKILL.md`
   returns `34:`. Unchanged.
6. **The `## Agent spawning mode` section in `looper/SKILL.md` stays
   ≤20 lines** (asserted by existing test lines 46-53). The replacement
   preserves line count exactly, so the section stays at 20 lines —
   still satisfies the `≤ 20` assertion. Verification:
   ```bash
   awk '/^## Agent spawning mode/{flag=1;next} /^## /{if(flag){flag=0;exit}} flag{print}' \
       plugins/looper/skills/looper/SKILL.md | wc -l
   ```
   returns `20`.
7. **No accidental reintroduction of `--async`, `subagent-response-`,
   or `Agent tool is NOT` fallback language** — already covered by
   existing assertions lines 86-91, 78-83, 101-104 of the migration
   test; they must all still pass.

## Acceptance criteria (the Checker will verify)

1. `grep -n "result-file path" plugins/looper/skills/looper/SKILL.md plugins/looper/agents/{planner,doer,checker}.md`
   returns **zero** matches.
2. `grep -nE "read (the )?result file" plugins/looper/skills/looper/SKILL.md plugins/looper/agents/{planner,doer,checker}.md`
   returns **zero** matches.
3. `tests/test-agent-spawn-migration.sh` runs 100% green and now
   includes both regression loops shown above. The Checker should
   `grep -cE "'result-file path'|'read result file'" tests/test-agent-spawn-migration.sh`
   to confirm both patterns are asserted.
4. `bash tests/run-corner-case-tests.sh` reports `15 suites passed, 0
   suites failed`.
5. `bash tests/test-fail-fast-gate.sh` reports `21 passed, 0 failed`
   — i.e. the `Never run the PDC loop inline` / `Never improvise PDC
   work inline` anchor guarantees still hold.
6. TDD sequence is visible in git log: `do-red` commit contains **only**
   the new test assertions (no doc edits); `do-green` commit contains
   **only** the four doc edits (no test changes). The Checker's TDD
   sequence check is the authoritative audit.
7. Every replacement block satisfies the Semantic contract listed above
   — the Checker can spot-check by reading each block and looking for
   the 4 required mentions and the 7 forbidden phrases.
8. Line counts of the replacement blocks match the originals exactly
   (8/10/10/10) so the pinned-by-position paragraphs in each file are
   not displaced.

## Risks

- **Line-drift risk (mitigated).** If the Doer's replacement block has
  a different line count than the original, the
  `**Never improvise PDC work inline.**` paragraph moves, and while the
  existing `test-fail-fast-gate.sh` Test 5 only checks "after
  `## Instructions`" ordering (not a specific line number), the
  Checker explicitly flagged "same line position" as a correctness
  requirement. Mitigation: the plan specifies exact line counts
  (8, 10, 10, 10) for each replacement.
- **Synonym drift (mitigated).** A sloppy rewrite could swap
  "result-file path" for "result file to read" and still convey the
  same wrong mental model. Mitigation: the red-phase guard now covers
  both `result-file path` and `read result file`; corner case #2 greps
  for a broader `read (the )?result file|result file to read` pattern.
- **Red-phase legibility (mitigated).** The red phase only touches the
  test file — the Doer must resist the urge to also touch docs in red.
  Mitigation: the plan lists the red-phase file scope explicitly (test
  file only).

## Scope discipline

This is a surgical docs edit + two regression assertion loops. Nothing
else changes. In particular:

- No new scripts, no new tests (beyond two assertion loops appended to
  an existing test file), no refactors of existing tests.
- No restructuring of SKILL.md section hierarchy.
- No rename / move of any file.
- Spawn-agent script: untouched.
- `subagents/SKILL.md`: untouched (already correct).
- README: untouched.
