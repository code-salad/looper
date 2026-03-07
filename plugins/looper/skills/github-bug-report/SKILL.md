---
name: github-bug-report
description: >-
  Use this skill when a bug is found and needs to be reported as a GitHub issue.
  Detects repo issue templates, gathers environment info, and creates a
  well-structured bug report via gh CLI.
tools: Bash, Read, Grep, Glob
---

# GitHub Bug Report Skill

Creates a well-structured GitHub issue for a bug, respecting the repo's issue template if one exists.

## Prerequisites

- Must be in a git repository hosted on GitHub
- `gh` CLI must be installed and authenticated

---

## Phase 0: Preflight Checks

Run these checks in parallel:

```bash
# Check 1: Confirm inside a git repo
git rev-parse --is-inside-work-tree

# Check 2: Confirm gh CLI is authenticated
gh auth status

# Check 3: Get repo slug
gh repo view --json nameWithOwner --jq '.nameWithOwner'
```

**Gate:** Abort with a clear message if:
- Not in a git repo → "This is not a git repository."
- `gh` is not authenticated → "Please run `gh auth login` first."

Store:
- `REPO_SLUG` = owner/repo from `gh repo view`

---

## Phase 1: Gather Bug Context

### 1a. Parse bug description

Extract the bug description from `$ARGUMENTS`. If `$ARGUMENTS` is empty or not provided, abort: "Please provide a bug description: `/github-bug-report \"description of the bug\"`"

### 1b. Collect environment info

Run `detect-stack` (from the loop skill scripts) to gather project tech stack:

```bash
bash "$(dirname "$(dirname "$0")")/looper/scripts/detect-stack"
```

If `detect-stack` is not available, manually collect:

```bash
# OS info
uname -srm

# Language/runtime versions (check what's relevant)
node --version 2>/dev/null || true
python3 --version 2>/dev/null || true
go version 2>/dev/null || true
rustc --version 2>/dev/null || true
```

### 1c. Read referenced files

If the bug description mentions specific files, stack traces, or line numbers, use the Read tool to gather the relevant source code context.

---

## Phase 2: Detect Issue Template

Run the `detect-issue-template` script to find bug report templates:

```bash
bash "$(dirname "$(dirname "$0")")/looper/scripts/detect-issue-template"
```

The script returns JSON with `template_found`, `template_type`, `template_path`, and `template_content`.

If a template is found, read it with the Read tool to understand its structure. Parse the template natively — identify section headings, required fields, and expected format.

If no template is found or the template is unparseable, fall back to the default format in Phase 3.

---

## Phase 3: Compose Bug Report

### If template found:

Mirror the template's structure:
- Use field labels from the template as section headings
- Fill each section with the gathered context from Phase 1
- For YAML-based templates (`.yml`), use the field `label` values as section headings and respect `required` markers
- For Markdown templates (`.md`), follow the existing heading structure

### If no template (default format):

Compose the issue body using this structure:

```markdown
## Description
<2-4 sentences describing the bug, drawn from $ARGUMENTS and any additional context>

## Steps to Reproduce
1. <step>
2. <step>
3. <step>

## Expected Behavior
<what should happen>

## Actual Behavior
<what actually happens>

## Environment
| Component | Version |
|-----------|---------|
| OS        | <from uname> |
| Language  | <from detect-stack> |
| Runtime   | <from detect-stack> |
| Framework | <from detect-stack> |

## Additional Context
<stack traces, logs, code snippets, or other relevant details>
```

Fill in as much as possible from the gathered context. Leave sections marked `N/A` if no relevant info is available rather than omitting them.

### Compose the title

Generate a concise, descriptive title:
- Start with `bug:` or `Bug:` prefix
- Keep under 70 characters total
- Be specific — "bug: crash on empty input in user search" not "bug: something broken"

---

## Phase 4: Check for Duplicates

Before creating the issue, search for potential duplicates:

```bash
# Search open issues for key terms from the bug description
gh issue list --state open --search "<key terms from description>" --limit 5
```

Extract 2-3 key terms from the bug description for the search query.

**If potential duplicates are found:**
- List them with issue number, title, and URL
- Ask the user: "These existing issues look related. Do you still want to create a new issue?"
- If the user confirms, proceed to Phase 5
- If the user cancels, abort gracefully

**If no duplicates found:** Proceed to Phase 5.

---

## Phase 5: Create Issue

### 5a. Check if "bug" label exists

```bash
gh label list --search "bug" --limit 5
```

If a "bug" label exists, include `--label "bug"` in the create command. If not, omit the label flag (do not attempt to create the label).

### 5b. Create the issue

```bash
gh issue create \
  --title "<title from Phase 3>" \
  --body "$(cat <<'EOF'
<body from Phase 3>
EOF
)"
```

Add `--label "bug"` only if the label was confirmed to exist in 5a.

### 5c. Report back

After successful creation, report:
```
Created issue #<number>: <title>
<issue URL>
```

---

## Error Handling

| Scenario | Action |
|----------|--------|
| Not a git repo | Abort: "This is not a git repository." |
| `gh` not authenticated | Abort: "Please run `gh auth login` first." |
| No description provided | Abort: "Please provide a bug description: `/github-bug-report \"description\"`" |
| Template unparseable | Log warning, fall back to default format |
| Duplicate found | List duplicates, ask user to confirm before creating |
| "bug" label doesn't exist | Create issue without the label |
| `gh issue create` fails | Report the error message from `gh` to the user |
| `detect-issue-template` not found | Skip template detection, use default format |
| `detect-stack` not found | Collect environment info manually |
