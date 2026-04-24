---
name: Default
about: Default issue template — mirrors the canonical Looper format
---

## Description / Summary
<2-4 sentences.>

## Motivation
<Why this is needed — skip for bug reports.>

## Acceptance Criteria
- [ ] <specific, testable criterion>

<!--
The next two sections are load-bearing. They are parsed by:
  - plugins/looper/skills/looper/scripts/check-blocked
  - crates/looper-watch/src/github.rs::is_blocked
to decide whether `looper-watch` should pick this issue up.

Use the EXACT format below. Bare issue numbers, no [#42](url) wrapping.
-->

## Dependencies
<!-- Open issues this builds on. Remove the section if none. -->
- [ ] Depends on #<N> — <one-line reason>

## Blockers
<!-- Open issues that must close before this one starts. Remove if none. -->
- [ ] Blocked by #<N> — <one-line reason>

## Subtasks
- [ ] <subtask>

## References
- `path/to/file` — <why it's relevant>

## Context
- **Found by:** <how/when discovered>
