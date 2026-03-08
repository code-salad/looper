# SOP: Feature-Slice Waterfall Development (v2)

A waterfall discipline applied per feature slice with upfront entity modeling, draft schemas as living contracts, and a concrete amendment protocol for when reality diverges from the plan.

---

## When to Use This SOP

| Use when | Don't use when |
|----------|---------------|
| Domain is understood (CRUD, business logic, integrations) | Exploring a new domain where entities are unclear |
| Requirements are stable enough to extract entities | Requirements are actively shifting week to week |
| Multiple contributors need to work in parallel | Solo developer on a small feature |
| Feature touches multiple entities/endpoints | Single-file bug fix or config change |

**If you're unsure whether the domain is understood enough:** run a timboxed spike (Phase 0.5) before committing to schemas. If the spike changes your entity model, the domain isn't settled yet — iterate the spike, don't proceed to slicing.

---

## Overview

```
Problem
  │
  ▼
Phase 0: Understand          (1 planner, timeboxed)
  Problem → Flows → Entities
  │
  ▼
Phase 1: Scaffold             (1 planner, timeboxed)
  Draft DB schema → Draft API schema → Commit scaffold PR
  │
  ▼
Phase 2: Slice                (1 planner)
  Entity boundaries → Slices → Dependency graph → Issues
  │
  ├──────────────┬──────────────┐
  ▼              ▼              ▼
Phase 3-6:     Phase 3-6:     Phase 3-6:      (N contributors, parallel)
Slice A        Slice B        Slice C
  │              │              │
  │   ┌──────────┘              │
  │   │  Schema wrong?          │
  │   │  ▼                      │
  │   │  Amendment Protocol     │
  │   │  (patch schema, all     │
  │   │   rebase, continue)     │
  │   │                         │
  ▼   ▼                         ▼
Merge Merge                   Merge
  │     │
  └──┬──┘
     ▼
  Slice D (was blocked, now unblocked)
```

---

## Phase 0: Understand the Problem

**Who:** Single planner.
**Timebox:** Half a day for small features, 1-2 days for large ones. If it takes longer, the feature is too big — split it into multiple SOPs.
**Output:** Problem statement, user flows, entity model.

### 0.1 Define the Problem

One paragraph:
- **What is broken or missing?**
- **What should it look like?**
- **Who is affected?**
- **What are the constraints?**

### 0.2 Map the User Flows

Map every flow end-to-end before thinking about data or code:

```
Example: "User uploads a document for review"

1. User selects file → validates type/size → uploads to storage
2. System creates document record → notifies reviewers
3. Reviewer opens document → adds comments → submits review
4. Author receives review → revises or approves → document finalized
```

For each flow:
- **Trigger:** What starts it?
- **Steps:** What happens in sequence?
- **Branches:** Where can it go differently?
- **Outcome:** What is the end state?

### 0.3 Extract Entities

From the flows, identify every noun the system needs to track:

| Entity | Key Attributes | Relationships | States |
|--------|---------------|---------------|--------|
| Document | title, file_url | belongs to Author, has many Reviews | draft → in_review → approved → archived |
| Review | status | belongs to Document + Reviewer, has many Comments | pending → submitted |
| Comment | body, line_number | belongs to Review | — |

**Rules:**
- If a flow references it, it's probably an entity
- If it has a lifecycle (states), it's definitely an entity
- If two flows reference the same noun, it's one entity
- An attribute that is itself complex (has sub-attributes or a lifecycle) is probably its own entity

**Do NOT design the full schema here.** Just identify what exists and how things relate. The schema comes in Phase 1.

### 0.4 Spike (if needed)

If any entity or flow feels uncertain, timebox a spike before proceeding:

```
Spike: "Can we extract text from uploaded PDFs?"
Timebox: 4 hours
Output: Yes/no + technical constraints discovered
```

A spike is throwaway code. Its only output is knowledge that informs the entity model. If the spike changes the entity model, update Phase 0.3 before moving on.

---

## Phase 1: Scaffold

**Who:** Single planner (same person as Phase 0).
**Timebox:** Half a day. The scaffold is intentionally minimal — just enough structure to unblock parallel work.
**Output:** A merged "scaffold PR" containing draft schemas.

### 1.1 Draft the DB Schema

Translate entities into schema. Include only:
- Tables and primary keys
- Foreign keys (relationships)
- Columns that are **obvious** from the entity model
- Enums for entity states
- Timestamps (created_at, updated_at)

**Do NOT include:**
- Indexes (add when you have queries)
- Constraints beyond foreign keys (add per slice)
- Columns you're unsure about (add per slice)

```prisma
// Example: draft schema — minimal, correct, extensible

model Document {
  id        String   @id @default(uuid())
  title     String
  status    DocumentStatus @default(DRAFT)
  fileUrl   String
  authorId  String
  author    Author   @relation(fields: [authorId], references: [id])
  reviews   Review[]
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt
}

enum DocumentStatus {
  DRAFT
  IN_REVIEW
  APPROVED
  ARCHIVED
}

model Review {
  id         String   @id @default(uuid())
  status     ReviewStatus @default(PENDING)
  documentId String
  document   Document @relation(fields: [documentId], references: [id])
  reviewerId String
  reviewer   Reviewer @relation(fields: [reviewerId], references: [id])
  comments   Comment[]
}

// ... etc
```

### 1.2 Draft the API Schema

Define endpoints derived from the flows. Include only:
- Method + path
- Key request/response fields
- Auth level (public, authenticated, admin)

```
POST   /api/documents              Auth: user     → { title, file }  → { id, status }
GET    /api/documents/:id          Auth: user     →                  → { id, title, status, fileUrl, reviews }
POST   /api/documents/:id/reviews  Auth: user     → { reviewerId }   → { id, status }
POST   /api/reviews/:id/comments   Auth: reviewer → { body, line }   → { id }
PATCH  /api/reviews/:id            Auth: reviewer → { status }       → { id, status }
```

**Do NOT include:**
- Pagination, filtering, sorting (add per slice)
- Detailed error responses (add per slice)
- Fields you're unsure about (add per slice)

### 1.3 Commit the Scaffold PR

The scaffold PR contains:
- DB schema file
- API type definitions or spec
- Shared types/interfaces

Merge this before any slice work begins. This is the **shared contract** — but it's a **draft**, not a freeze. See the Amendment Protocol below.

### 1.4 What "Draft" Means

The scaffold is deliberately incomplete. It captures:
- **What we know:** entities, relationships, states, core endpoints
- **Not what we don't:** optional fields, edge-case endpoints, performance concerns

Each slice will **extend** the scaffold (add columns, add endpoints, add constraints). No slice should **contradict** it (rename tables, change relationships, alter primary keys). If a contradiction is needed, that's an amendment.

---

## Phase 2: Slice

**Who:** Single planner.
**Output:** GitHub issues with dependency graph.

### 2.1 Slice Along Entity Boundaries

Each slice should ideally own one entity's behavior for one flow:

```
Flow: "User uploads a document for review"

  Slice A: Create document (POST /api/documents) — happy path
  Slice B: Retrieve document (GET /api/documents/:id)
  Slice C: Assign reviewer (POST /api/documents/:id/reviews)
  Slice D: Add comments (POST /api/reviews/:id/comments) — depends on C
  Slice E: Submit review (PATCH /api/reviews/:id) — depends on C
  Slice F: Document upload validation & error handling — depends on A
```

### 2.2 Build the Dependency Graph

```
A ──── F
B
C ──┬─ D
    └─ E
```

**Parallelism = width of the graph.** Here, A, B, and C can run simultaneously (3 contributors). Then D, E, and F open up.

**Maximize width by:**
- Slicing at entity boundaries (different entities = independent slices)
- Pushing shared setup into the scaffold PR (already done in Phase 1)
- Making read-only slices (GET endpoints) independent of write slices
- Avoiding deep chains — if A → B → C → D, consider whether B and C can be made independent

### 2.3 Create Issues

Each issue contains:
- Title: action + entity + endpoint (`Create document upload endpoint`)
- Acceptance criteria: checkboxes derived from the flow + API contract
- Dependencies: `Depends on #N` where N is still open
- Labels: priority, entity/area
- References to relevant schema sections
- **No assignee** — contributors claim when ready

---

## Phases 3-6: Per-Slice Waterfall (parallel across contributors)

Each contributor picks an unblocked, unassigned issue and runs it through four phases. Multiple contributors work in parallel on independent slices.

### Phase 3: Requirements (per slice)

**3.1 Claim the issue.** Assign yourself. Verify all `Depends on #N` are closed. If not, pick a different issue.

**3.2 Refine acceptance criteria.** The issue already has criteria from Phase 2. Add:
- Edge cases discovered while reading the schema
- Error scenarios for this endpoint
- Integration points with other slices

**3.3 Check for conflicts.** Are other contributors touching adjacent files? Coordinate early.

**Gate:** Criteria finalized, dependencies resolved.

### Phase 4: Design (per slice)

**4.1 Implementation plan.** The API and DB contracts exist. Focus on:
- What internal logic connects the API layer to the DB?
- What validations are needed?
- What existing patterns in the codebase to follow?

**4.2 Schema extensions.** If this slice needs columns or endpoints not in the scaffold:
- **Additive changes** (new column, new endpoint): add them in this slice's PR. No amendment needed.
- **Contradictory changes** (rename table, change relationship): trigger the Amendment Protocol.

**4.3 Test plan.** Map each acceptance criterion to a test type (unit, integration, e2e).

**Gate:** Design reviewed, test plan exists.

### Phase 5: Implementation (per slice)

**5.1 Branch and rebase.**
```
git checkout -b feat/slice-description
git fetch origin && git rebase origin/main
```

**5.2 Implement.** Follow the design. Write code and tests together. If the design is wrong, go back to Phase 4.

**5.3 Self-review.** Re-check acceptance criteria, run tests, run linter, rebase on latest main.

**5.4 Open PR.** Reference the issue (`Closes #N`). Request review from a contributor on an adjacent slice.

**Gate:** PR open, tests passing.

### Phase 6: Verification (per slice)

**6.1 Code review.** Cross-slice reviewer preferred.

**6.2 Acceptance testing.** Every criterion must pass. Failures go back to Phase 5.

**6.3 Merge and deploy.** Rebase one final time, merge, verify in deployed environment.

**6.4 Unblock dependents.** Comment on any issues that were waiting on this slice.

---

## Amendment Protocol

When a contributor discovers the scaffold schema is wrong during implementation.

### Severity Levels

| Level | What changed | Process | Impact |
|-------|-------------|---------|--------|
| **Additive** | New column, new endpoint, new enum value | Add in your slice's PR. No coordination needed. | None — other slices are unaffected |
| **Modification** | Column type change, endpoint response shape change | Amendment PR. Planner reviews. Affected contributors rebase. | Low — only slices touching the changed entity |
| **Structural** | Entity renamed, relationship changed, entity split/merged | Stop-the-line. All contributors pause. Planner revises schema. All rebase. | High — potentially all slices |

### Amendment Process

1. **Contributor discovers the issue.** Opens a GitHub issue titled `schema-amendment: <description>` with:
   - What's wrong with the current schema
   - What it should be instead
   - Which slices are affected
   - Why an additive change won't work

2. **Planner reviews within 4 hours** (timebox — don't let this block contributors for days).
   - Approved: planner creates the amendment PR with the schema change
   - Rejected with workaround: planner explains how to work within the current schema
   - Deferred: change is real but can wait until current slices merge; create a follow-up issue

3. **Amendment PR merges.** All active contributors rebase:
   ```
   git fetch origin && git rebase origin/main
   ```
   Fix any conflicts caused by the schema change.

4. **If structural:** planner reviews the slice dependency graph — some slices may need re-scoping or reordering.

### Prevention

Most amendments happen because Phase 0 missed something. After each amendment, the planner should ask:
- Could this have been caught in the entity extraction?
- Was there a flow we didn't map?
- Should we spike uncertain areas before scaffolding next time?

---

## Coordination Model

### Roles

| Role | Responsibility | Count |
|------|---------------|-------|
| **Planner** | Phases 0-2 (problem, schemas, slicing). Reviews amendments. | 1 per feature |
| **Contributor** | Phases 3-6 (pull an issue, waterfall it to completion) | N in parallel |
| **Reviewer** | Phase 6.1 (code review, preferably cross-slice) | Rotate among contributors |

### How Contributors Pick Work

1. Look at open issues with no assignee
2. Filter out issues with unresolved dependencies (`Depends on #N` where #N is still open)
3. Pick one, assign yourself, start Phase 3
4. When done, go back to step 1

This is what `/looper-issue` automates.

### Communication

| When | What | Who |
|------|------|-----|
| Phase 2 complete | Planner shares slice list, dependency graph, and scaffold PR | Planner -> all |
| Phase 3.3 | Flag potential file conflicts | Contributor -> affected contributor |
| Phase 4.2 | Schema amendment needed | Contributor -> planner |
| Phase 6.4 | Dependency resolved, slice merged | Contributor -> blocked contributors |

### Handling Merge Conflicts

| Scenario | Resolution |
|----------|-----------|
| Different files | No conflict — merge in any order |
| Same file, different sections | Likely auto-resolved by git — verify after rebase |
| Same file, same lines | Should have been caught in Phase 3.3. Later PR rebases and adapts |
| Schema amendment mid-flight | All active contributors rebase after amendment PR merges |

### Parallelism

```
Max parallel contributors = number of slices with zero unresolved dependencies
```

The planner maximizes this by:
- Slicing at entity boundaries (different entities = independent)
- Keeping the dependency graph wide, not deep
- Pushing shared setup into the scaffold

---

## Timeboxes

| Phase | Timebox | If exceeded |
|-------|---------|-------------|
| Phase 0: Understand | Half day (small) / 2 days (large) | Feature is too big — split into multiple SOPs |
| Phase 1: Scaffold | Half day | You're over-specifying — cut back to entities + relationships only |
| Phase 2: Slice | 2-4 hours | Slices are too granular — merge some |
| Amendment review | 4 hours | Planner must respond — don't let contributors block |
| Per-slice (Phases 3-6) | 1-3 days per slice | Slice is too big — split it |

---

## Rules

1. **Understand before you scaffold.** Flows and entities come from the problem, not from guessing at tables.
2. **Scaffold is a draft, not a freeze.** It's the best guess at the data model. Amendments are expected, not failures.
3. **Additive is free, structural is expensive.** Design the scaffold so most slice work is additive (new columns, new endpoints) not structural (changing relationships).
4. **No phase skipping.** Every slice goes through Phases 3-6, even if a phase takes 5 minutes.
5. **No phase blending.** Finish requirements before design. Finish design before code.
6. **Slice at entity boundaries.** This maximizes independence and minimizes conflicts.
7. **Claim before you start.** One contributor per slice. Assign yourself before Phase 3.
8. **Rebase often.** Before implementation and before opening a PR.
9. **Done means verified.** Code without passing acceptance tests isn't done.
10. **Merging unblocks.** Notify contributors waiting on your slice.
