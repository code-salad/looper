# SOP: Feature-Slice Waterfall Development

A full waterfall discipline applied per feature slice. The process flows from problem understanding through entity extraction and schema design before any implementation begins. Multiple contributors work in parallel on independent slices, all coding against shared contracts established upfront.

---

## Overview

```
Problem Statement
       │
       ▼
┌─ Phase 0: Understand ─────────────────────────────────────────────┐
│  Problem → User Flows → Entities → DB Schema + API Schema         │
└───────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─ Phase 1: Slice & Plan ───────────────────────────────────────────┐
│  Schemas → Feature Slices → Dependency Graph → GitHub Issues      │
└───────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─ Phase 2+: Parallel Execution ────────────────────────────────────┐
│                                                                    │
│  Contributor 1        Contributor 2        Contributor 3           │
│  ┌──────────┐         ┌──────────┐         ┌──────────┐           │
│  │ Slice A  │         │ Slice B  │         │ Slice C  │           │
│  │ Require  │         │ Require  │         │ Require  │           │
│  │ Design   │         │ Design   │         │ Design   │           │
│  │ Implement│         │ Implement│         │ Implement│           │
│  │ Verify   │         │ Verify   │         │ Verify   │           │
│  └────┬─────┘         └────┬─────┘         └──────────┘           │
│       │ ✓                  │ ✓                                     │
│       └────────┬───────────┘                                       │
│                ▼                                                   │
│         ┌──────────┐   (D was blocked on A+B, now unblocked)      │
│         │ Slice D  │                                               │
│         └────┬─────┘                                               │
│              │ ✓                                                   │
│              ▼                                                     │
│         ┌──────────┐                                               │
│         │ Slice E  │                                               │
│         └──────────┘                                               │
└────────────────────────────────────────────────────────────────────┘
```

---

## Phase 0: Understand the Problem

**Who:** A single planner (tech lead, product owner, or senior dev). This phase is NOT parallelized — one person owns the analysis to ensure coherent design.

**Input:** Feature request, bug report, epic, or product goal.
**Output:** Entity model, DB schema, API schema, flow diagrams.

### 0.1 Define the Problem

Write a clear problem statement:
- **What is broken or missing?** (current state)
- **What should it look like?** (desired state)
- **Who is affected?** (users, systems, stakeholders)
- **What are the constraints?** (performance, compatibility, deadlines)

### 0.2 Map the User Flows

Before thinking about code, map every flow a user or system takes:

```
Example: "User uploads a document for review"

1. User selects file → validates type/size → uploads to storage
2. System creates document record → notifies reviewers
3. Reviewer opens document → adds comments → submits review
4. Author receives review → revises or approves → document finalized
```

For each flow, capture:
- **Trigger:** What starts this flow?
- **Steps:** What happens in sequence?
- **Branches:** Where can it go differently? (errors, edge cases, permissions)
- **Outcome:** What is the end state?

### 0.3 Extract Entities

From the flows, identify every noun that the system needs to track:

| Entity | Attributes | Relationships |
|--------|-----------|---------------|
| Document | id, title, status, file_url, created_at | belongs to Author, has many Reviews |
| Author | id, name, email | has many Documents |
| Review | id, status, submitted_at | belongs to Document, belongs to Reviewer |
| Reviewer | id, name, email | has many Reviews |
| Comment | id, body, line_number | belongs to Review |

**Rules for entity extraction:**
- If a flow mentions it, it's probably an entity
- If it has attributes that change over time, it's an entity (not just a value)
- If two flows reference the same noun, it's one entity (not two)
- If an entity has a lifecycle (created → active → archived), capture the states

### 0.4 Design the DB Schema

Translate entities into a database schema. This is the **single source of truth** for data structure.

```sql
-- or use Prisma schema, SQLAlchemy models, etc.

Table documents {
  id          uuid        [pk, default: `gen_random_uuid()`]
  title       varchar(255) [not null]
  status      enum('draft', 'in_review', 'approved', 'archived') [not null, default: 'draft']
  file_url    text        [not null]
  author_id   uuid        [ref: > authors.id]
  created_at  timestamp   [not null, default: `now()`]
  updated_at  timestamp   [not null, default: `now()`]
}

Table reviews {
  id          uuid        [pk]
  document_id uuid        [ref: > documents.id]
  reviewer_id uuid        [ref: > reviewers.id]
  status      enum('pending', 'submitted') [not null, default: 'pending']
  submitted_at timestamp
}

Table comments {
  id          uuid        [pk]
  review_id   uuid        [ref: > reviews.id]
  body        text        [not null]
  line_number int
}
```

**Validate the schema against every flow from 0.2:**
- Can each flow be fully executed with this schema?
- Are there missing fields or tables?
- Are the relationships correct?

### 0.5 Design the API Schema

Define every endpoint the system needs, derived directly from the flows:

```yaml
# Flow 1: Upload document
POST   /api/documents          → Create document record + upload
GET    /api/documents/:id      → Get document details

# Flow 2: Review process
POST   /api/documents/:id/reviews           → Assign reviewer
GET    /api/documents/:id/reviews           → List reviews
POST   /api/reviews/:id/comments            → Add comment
PATCH  /api/reviews/:id                     → Submit review

# Flow 3: Author actions
GET    /api/documents?author=me             → List my documents
PATCH  /api/documents/:id                   → Update document status
```

For each endpoint, define:
- **Method + path**
- **Request body** (JSON schema or TypeScript type)
- **Response body** (JSON schema or TypeScript type)
- **Status codes** (200, 201, 400, 401, 404, etc.)
- **Auth requirements** (public, authenticated, role-based)

### 0.6 Commit the Schemas

The DB schema and API schema are committed as the **integration blueprint** — a single setup PR that merges before any slice work begins. All contributors code against these contracts.

This PR contains:
- Database schema file (Prisma, SQL migrations, etc.)
- API type definitions / OpenAPI spec
- Shared types / interfaces
- Entity model diagram (optional, Mermaid in a doc)

---

## Phase 1: Slice & Plan

**Who:** Same planner from Phase 0.
**Input:** Schemas and flows from Phase 0.
**Output:** GitHub issues with dependency graph.

### 1.1 Decompose Flows into Slices

Each flow (or sub-flow) from Phase 0.2 becomes one or more slices. Slicing follows the flows, not the layers:

```
Flow: "User uploads a document for review"

  Slice A: POST /api/documents — create document + file upload (happy path)
  Slice B: GET /api/documents/:id — retrieve document
  Slice C: POST /api/documents — validation & error handling
  Slice D: Document upload — size limits, type checking, virus scan
```

Each slice must be:

| Criterion | Rule |
|-----------|------|
| **Vertical** | Touches all layers needed (UI, API, DB) — not horizontal layers in isolation |
| **Independently valuable** | Delivers something a user or system can use, even if minimal |
| **Small** | Completable in one cycle (1 issue = 1 PR = 1 deploy) |
| **Schema-aligned** | Uses the DB/API contracts from Phase 0 without modifying them |

### 1.2 Build the Dependency Graph

Map which slices depend on which. This determines what can run in parallel.

```
Independent slices → can run in parallel by different contributors
Dependent slices   → must wait for predecessor to merge
```

**Rules for maximizing parallelism:**
- Slices that implement different API endpoints on different entities are independent
- Slices that implement the same endpoint (happy path vs. error handling) are sequential
- Split slices at **ownership boundaries** — if two slices touch completely different files/modules, they're independent
- If two slices must touch the same file, make one depend on the other

### 1.3 Create Issues

Each slice becomes one GitHub issue containing:
- Title: concise action (`Add user login endpoint`)
- Acceptance criteria: checkboxes (derived from the flow steps + API contract)
- Dependencies: `Depends on #N` if blocked by another slice
- Labels: priority, area
- Reference to the relevant API endpoints and DB tables from Phase 0
- **No assignee yet** — contributors pull issues when ready

---

## Phase 2: Requirements (per slice)

**Who:** The contributor who picks up the slice.
**Input:** GitHub issue for this slice.
**Output:** Finalized acceptance criteria.

### 2.1 Claim the Issue

- Assign yourself to the issue
- Verify dependencies are resolved (all `Depends on #N` issues are closed)
- If dependencies aren't met, pick a different issue

### 2.2 Clarify Scope

- Re-read the issue and the referenced API/DB contracts from Phase 0.
- If anything is unclear, comment on the issue and resolve before proceeding.
- Explicitly list what is **out of scope** for this slice.

### 2.3 Refine Acceptance Criteria

The issue already has acceptance criteria from Phase 1. Refine them:
- Add edge cases discovered while reading the contracts
- Make each criterion testable and binary (pass/fail)
- Map each criterion to a specific API endpoint or DB operation

### 2.4 Identify Integration Points

- Which API endpoints and DB tables (from Phase 0) does this slice implement or consume?
- Which other in-flight slices touch adjacent code?
- Flag potential merge conflicts early — coordinate with the other contributor

**Gate:** Do not proceed to Design until all acceptance criteria are finalized and dependencies are resolved.

---

## Phase 3: Design (per slice)

**Input:** Finalized acceptance criteria + schemas from Phase 0.
**Output:** Technical design captured in the issue or a linked doc.

### 3.1 Implementation Design

The API and DB contracts already exist from Phase 0. This phase focuses on **how** to implement this slice within those contracts:
- Which API endpoint(s) does this slice implement?
- Which DB tables/columns does it read from or write to?
- What internal logic connects the API layer to the DB layer?
- UI changes: which screens, what components

### 3.2 Architecture Decision

For each slice, answer:
- Where does this code live? (which module/directory)
- What existing code does it touch?
- What patterns does the codebase already use for this? (follow them)
- Are there any new dependencies needed?

### 3.3 Conflict Surface Check

Before starting implementation, check:
- Are any other contributors currently modifying files this slice needs to touch?
- If yes: coordinate. Options:
  - **Reorder:** let the other slice merge first, then rebase
  - **Split:** extract the shared file change into its own slice that goes first
  - **Coordinate:** agree on non-overlapping sections of the file

### 3.4 Test Plan

Define how each acceptance criterion will be verified:

| Criterion | Verification Method |
|-----------|-------------------|
| Returns 200 with valid creds | Integration test |
| Returns 401 with invalid creds | Integration test |
| JWT has 1h expiry | Unit test |
| Audit log recorded | Integration test |

**Gate:** Do not proceed to Implementation until the design is reviewed and the test plan exists.

---

## Phase 4: Implementation (per slice)

**Input:** Approved design and test plan.
**Output:** Code + tests in a PR.

### 4.1 Create Branch

```
git checkout -b feat/slice-description
```

### 4.2 Rebase on Latest Main

Before writing code, ensure your branch is up to date:
```
git fetch origin && git rebase origin/main
```

This minimizes merge conflicts with slices that merged while you were in Requirements/Design.

### 4.3 Implement

- Follow the design exactly. If the design is wrong, go back to Phase 2 — do not improvise.
- Write code and tests together (not tests-after).
- Each acceptance criterion maps to at least one test.
- Keep changes minimal — only what the slice requires.

### 4.4 Self-Review

Before opening a PR:
- Re-read every acceptance criterion. Is each one met?
- Run the full test suite. Does it pass?
- Run linter/formatter. Is it clean?
- Read the diff as if you're reviewing someone else's code.
- Rebase on latest main again — catch any conflicts from slices that merged during your implementation.

### 4.5 Open PR

- Reference the issue (`Closes #N`)
- PR description summarizes what changed and why
- Request review from a contributor who worked on an adjacent slice (they know the context)

**Gate:** Do not merge until Phase 5 is complete.

---

## Phase 5: Verification (per slice)

**Input:** Open PR with passing tests.
**Output:** Merged PR, closed issue.

### 5.1 Code Review

- Reviewer checks: correctness, design adherence, test coverage, edge cases
- **Cross-slice reviewer preferred** — someone working on a related slice catches integration issues
- All comments resolved before merge

### 5.2 Acceptance Testing

Walk through each acceptance criterion manually or via automated tests:
- Every checkbox must pass
- If any criterion fails -> back to Phase 4 (fix, don't patch around it)

### 5.3 Merge & Deploy

- Rebase on latest main one final time
- Merge PR
- Deploy to staging/production
- Verify in deployed environment
- Close the issue — **this unblocks dependent slices**

### 5.4 Notify Dependents

After merging, check if any blocked issues were waiting on this slice. If so:
- Comment on the dependent issue: "Dependency #N is now merged. This issue is unblocked."
- The contributor assigned to the dependent slice can now proceed

---

## Coordination Model

### Roles

| Role | Responsibility | Count |
|------|---------------|-------|
| **Planner** | Phases 0-1 (problem analysis, schemas, slicing, dependency graph) | 1 per feature |
| **Contributor** | Phases 2-5 (pull an issue, waterfall it to completion) | N in parallel |
| **Reviewer** | Phase 5.1 (code review, preferably cross-slice) | Rotate among contributors |

### How Contributors Pick Work

1. Look at open issues with no assignee
2. Filter out issues with unresolved dependencies (`Depends on #N` where #N is still open)
3. Pick one, assign yourself, start Phase 2
4. When done, go back to step 1

This is exactly what `/looper-issue` automates.

### Communication Touchpoints

| When | What | Who |
|------|------|-----|
| Phase 1 complete | Planner shares the slice list, dependency graph, and committed schemas | Planner -> all contributors |
| Phase 2, step 2.4 | Flag potential file conflicts | Contributor -> affected contributor |
| Phase 3, step 3.3 | Coordinate on shared files | Contributors working on adjacent slices |
| Phase 5, step 5.4 | Notify that a dependency is resolved | Merging contributor -> blocked contributor |

### Handling Merge Conflicts

| Scenario | Resolution |
|----------|-----------|
| Two PRs touch different files | No conflict — merge in any order |
| Two PRs touch the same file, different sections | Likely auto-resolved by git — verify after rebase |
| Two PRs touch the same file, same lines | Should have been caught in Phase 3.3. Resolve: the later PR rebases and adapts |
| Shared contract changes mid-flight | Planner updates the contract PR, all active contributors rebase |

### Maximum Parallelism Formula

```
Max parallel contributors = number of slices with zero unresolved dependencies
```

The planner's job in Phase 0 is to maximize this number by:
- Making slices as independent as possible
- Pushing shared work into the setup PR (Phase 0.5)
- Avoiding deep dependency chains (wide graphs > deep chains)

---

## Flow Diagram (Multi-Contributor)

```
                    Planner
                       │
        Phase 0: Problem → Flows → Entities
                  → DB Schema → API Schema
                       │
               Phase 1: Slice & Plan
              (commit schemas, create issues)
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
     ┌─────────┐ ┌─────────┐ ┌─────────┐
     │ Slice A │ │ Slice B │ │ Slice C │   ← independent, run in parallel
     │ (Dev 1) │ │ (Dev 2) │ │ (Dev 3) │
     │ Require │ │ Require │ │ Require │
     │ Design  │ │ Design  │ │ Design  │
     │ Impl    │ │ Impl    │ │ Impl    │
     │ Verify  │ │ Verify  │ │ Verify  │
     └────┬────┘ └────┬────┘ └─────────┘
          │ merged     │ merged
          └─────┬──────┘
                ▼
          ┌─────────┐
          │ Slice D │   ← was blocked on A+B, now unblocked
          │ (Dev 1) │
          └────┬────┘
               │ merged
               ▼
          ┌─────────┐
          │ Slice E │   ← was blocked on D
          │ (Dev 2) │
          └─────────┘
```

---

## Rules

1. **Schemas before slices.** DB and API schemas are committed before any contributor starts. They are the shared contract.
2. **No phase skipping.** Every slice goes through Phases 2-5, even if a phase takes 5 minutes.
3. **No phase blending.** Finish requirements before starting design. Finish design before writing code.
4. **Slice, don't batch.** If a slice feels too big, split it. If it takes more than one PR, it's too big.
5. **Dependencies are explicit.** Every `Depends on #N` is tracked in the issue. No implicit ordering.
6. **Claim before you start.** Assign yourself to an issue before beginning Phase 2. One contributor per slice.
7. **Rebase often.** Rebase on main before starting implementation and before opening a PR.
8. **Design is a contract.** If implementation reveals a design flaw, return to Phase 3 — don't hack around it. If a schema flaw is found, escalate to the planner.
9. **Done means verified.** Code that isn't tested against acceptance criteria isn't done.
10. **Merging unblocks.** When your slice merges, notify contributors waiting on it.
