---
name: create-github-issue
description: >-
  Use this skill when the user wants to create a structured GitHub issue from a
  task description. Detects issue templates, generates acceptance criteria,
  parses dependency references, and creates the issue via gh CLI.
tools: Bash, Read, Grep, Glob
---

# Create GitHub Issue Skill

Creates a well-structured GitHub issue from a task description, respecting the repo's issue template if one exists.

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

## Phase 1: Parse Input

### 1a. Extract description

Extract the task description from `$ARGUMENTS`. If `$ARGUMENTS` is empty or not provided, abort: "Please provide a task description: `/create-github-issue \"description of the task\"`"

### 1b. Parse dependency references

Scan the description for dependency patterns (case-insensitive):
- `after #N`
- `depends on #N`
- `blocked by #N`
- `requires #N`

Collect all referenced issue numbers. For each one, fetch its title and state:

```bash
gh issue view N --json title,state --jq '.title'
```

If a referenced issue is not found, log a warning and continue without it.

---

## Phase 2: Analyze Codebase Context

### 2a. Detect project stack

Run `detect-stack` to understand the project tech stack:

```bash
bash "$(dirname "$(dirname "$0")")/looper/scripts/detect-stack"
```

If `detect-stack` is not available, skip this step.

### 2b. Read relevant files

If the description mentions specific files or directories, use the Glob and Read tools to examine them for context.

Read the project README (if present) for high-level context:

```bash
# Find README
ls README.md README.rst README.txt 2>/dev/null | head -1
```

### 2c. List existing labels

```bash
gh label list --limit 50
```

Store the list of label names for use in Phase 4.

---

## Phase 3: Detect Issue Templates

Run the `detect-issue-template` script:

```bash
bash "$(dirname "$(dirname "$0")")/looper/scripts/detect-issue-template"
```

The script returns JSON with `template_found`, `template_type`, `template_path`, and `template_content`.

If the script is not available or returns no template, also manually scan for non-bug templates:

```bash
ls .github/ISSUE_TEMPLATE/ 2>/dev/null
```

Check for:
- `.github/ISSUE_TEMPLATE/feature_request.yml`
- `.github/ISSUE_TEMPLATE/feature_request.md`
- Any other non-bug templates in `.github/ISSUE_TEMPLATE/`

If a template is found, read it with the Read tool to understand its structure. Select the most relevant template based on keywords in the task description (e.g., "feature", "add", "refactor", "chore").

If no template is found or the template is unparseable, fall back to the default format in Phase 4.

---

## Phase 4: Compose Issue Content

### 4a. Compose the title

Generate a clear, concise title:
- Start with an action verb (Add, Refactor, Fix, Update, Remove, Implement)
- Include the entity or area being affected
- Keep under 70 characters
- Examples: "Add OAuth2 login flow", "Refactor payment processing pipeline"

### 4b. Compose the body

#### If template found:

Mirror the template's structure:
- Use field labels from the template as section headings
- Fill each section with gathered context from the description and codebase
- For YAML-based templates (`.yml`), use `label` values as section headings and respect `required` markers
- For Markdown templates (`.md`), follow the existing heading structure

#### If no template (default format):

```markdown
## Summary
<2-4 sentences describing the task or feature, drawn from $ARGUMENTS and codebase context>

## Motivation
<why this change is needed, what problem it solves>

## Acceptance Criteria
- [ ] <criterion 1 — testable, binary pass/fail>
- [ ] <criterion 2>
- [ ] <criterion 3>

## Dependencies
- Depends on #N — <title of issue N>
(or "No dependencies." if none detected)

## References
- `path/to/relevant/file.ts` — <why it's relevant>
(or "No file references." if none identified)
```

Fill in as much as possible from the gathered context. Leave sections marked `N/A` if no relevant info is available rather than omitting them.

### 4c. Select labels

Match the task description against the existing repo labels collected in Phase 2. Only select labels that actually exist in the repo. Do not create new labels.

---

## Phase 5: Check for Duplicates

Before creating the issue, search for potential duplicates:

```bash
# Search open issues for key terms from the description
gh issue list --state open --search "<key terms from description>" --limit 5
```

Extract 2-3 key terms from the task description for the search query.

**If potential duplicates are found:**
- List them with issue number, title, and URL
- Ask the user: "These existing issues look related. Do you still want to create a new issue?"
- If the user confirms, proceed to Phase 6
- If the user cancels, abort gracefully

**If no duplicates found:** Proceed to Phase 6.

---

## Phase 6: Create Issue

### 6a. Create the issue

```bash
gh issue create \
  --title "<title from Phase 4>" \
  --body "$(cat <<'EOF'
<body from Phase 4>
EOF
)"
```

Add `--label "<label>"` only for labels confirmed to exist in Phase 2. Do NOT use `--assignee`.

### 6b. Report back

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
| No description provided | Abort: "Please provide a task description: `/create-github-issue \"description\"`" |
| Template unparseable | Log warning, fall back to default format |
| Duplicate found | List duplicates, ask user to confirm before creating |
| Label doesn't exist in repo | Omit that label; create issue without it |
| `gh issue create` fails | Report the error message from `gh` to the user |
| `detect-issue-template` not found | Skip template detection, use default format |
| `detect-stack` not found | Skip stack detection, proceed without it |
| Referenced issue #N not found | Log warning: "Issue #N not found, skipping dependency"; continue |
