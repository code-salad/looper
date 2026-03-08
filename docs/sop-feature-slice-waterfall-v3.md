# SOP: Feature-Slice Waterfall Development (v3) — Incremental Discovery

For when the planner doesn't know the full picture upfront. The entity model and schemas emerge slice by slice. Each slice discovers just enough, builds just enough, and leaves the door open for what comes next.

---

## When to Use v3 vs v2

| v3 (this doc) | v2 |
|---|---|
| Domain is partially understood or new | Domain is well understood |
| Entities will be discovered during implementation | Entities can be listed upfront |
| Requirements arrive incrementally | Requirements are mostly stable |
| "We'll know it when we see it" | "We can spec it now" |
| Planner has a vision but not the details | Planner can design the full schema |

**v3 trades upfront parallelism for reduced waste.** Early slices are sequential. Parallelism emerges as the model stabilizes.

---

## Overview

```
Problem (partial understanding)
  │
  ▼
Slice 1: Walking Skeleton                          ← sequential
  Thinnest possible end-to-end flow
  Discover entities → schema → implement → ship
  │
  ▼
Slice 2: Next most valuable flow                   ← sequential
  Extend entities → extend schema → implement → ship
  │
  ▼
Slice 3+: Model stabilizing                        ← parallelism emerges
  ┌────────────┬────────────┐
  │ Slice 3    │ Slice 4    │   (independent entities = parallel)
  │ extend     │ extend     │
  │ implement  │ implement  │
  └─────┬──────┘─────┬──────┘
        │ merged      │ merged
        ▼             ▼
  ┌────────────┐
  │ Slice 5    │   (depends on 3+4)
  └────────────┘
```

There is no big upfront schema phase. The schema grows with each slice. Early slices are slower and sequential. Later slices are faster and parallel because the model has settled.

---

## The Slice Lifecycle

Every slice — from the first to the last — follows the same six steps. The difference is that early slices spend more time on discovery, later slices spend more time on implementation.

```
┌─────────────────────────────────────────────────┐
│                  One Slice                       │
│                                                  │
│  1. Pick    → Choose the next most valuable flow │
│  2. Map     → Map that flow end-to-end           │
│  3. Discover→ Extract/extend entities & schema   │
│  4. Design  → Plan the implementation            │
│  5. Build   → Code + tests                       │
│  6. Ship    → Review, merge, deploy              │
│                                                  │
│  Output: working software + extended schema      │
└─────────────────────────────────────────────────┘
```

---

## Step 1: Pick

**Who decides:** Planner (or the team together).

Choose the next slice based on:

| Priority | Rationale |
|----------|-----------|
| **Highest uncertainty** (early) | Tackle what you understand least first — it will reshape the model |
| **Highest value** (mid) | Deliver the most impactful flows once the model is stable |
| **Edge cases & hardening** (late) | Polish after the core works |

For the very first slice, always pick the **thinnest possible end-to-end happy path**. This is the walking skeleton — it proves the architecture works and establishes the first entities.

```
Example — Building a document review system:

Slice 1: Author creates a document (just a title + empty file) and sees it in a list
         → Establishes: Document, Author
         → Doesn't yet handle: file upload, reviews, comments

Slice 2: Author uploads a file to an existing document
         → Extends: Document (adds fileUrl, fileSize, mimeType)
         → Establishes: nothing new, just enriches Document

Slice 3: Reviewer is assigned to a document
         → Establishes: Review, Reviewer
         → First cross-entity relationship

Slice 4: Reviewer adds a comment (depends on 3)
         → Establishes: Comment

Slice 5: Author sees review status on document list (depends on 3)
         → No new entities, but adds a query that joins Document + Review
```

Notice: the planner didn't need to know about Comments in Slice 1. The entity emerged when the flow demanded it.

---

## Step 2: Map

Map the flow for this slice only. Don't map flows you're not building yet.

```
Slice 3: "Reviewer is assigned to a document"

Trigger: Author clicks "Add Reviewer" on a document
Steps:
  1. Author selects a user from the team list
  2. System creates a Review record linking the reviewer to the document
  3. Reviewer receives a notification (out of scope for this slice — just the record)
  4. Document status changes to IN_REVIEW
Outcome: Review record exists, document is in review status
```

For each step, note:
- What data is created, read, updated, or deleted?
- Which existing entities are involved?
- Does this flow need a new entity?

---

## Step 3: Discover

This is where v3 diverges from v2. Instead of designing all entities upfront, you discover them flow by flow.

### 3a. Check Existing Entities

Read the current schema. Ask:
- Can this flow be implemented with entities that already exist?
- Do existing entities need new fields?
- Is there a new entity hiding in this flow?

### 3b. Extend the Schema

Apply the **minimal extension** principle:

| Change type | Action | Example |
|-------------|--------|---------|
| New entity for this flow | Add the table + relationships | Add `reviews` table |
| New field on existing entity | Add the column | Add `status` to `documents` |
| New enum value | Add it | Add `IN_REVIEW` to DocumentStatus |
| Relationship between existing entities | Add foreign key | `reviews.document_id → documents.id` |

**Rules:**
- Only add what this slice needs. Don't add fields "because we'll probably need them."
- Every column you add must be used by this slice's code.
- If you're unsure whether something is an entity or an attribute, make it an attribute. Promote to entity later if needed.

### 3c. Commit the Schema Extension

The schema change is part of this slice's PR — not a separate PR. The schema grows with the code.

```
Slice 3 PR contains:
  - Migration: add reviews table
  - Migration: add IN_REVIEW to DocumentStatus
  - API: POST /api/documents/:id/reviews
  - Tests for the above
```

### 3d. Document What You Learned

Add a brief comment to the slice's issue:
```
Entities discovered/extended:
  - NEW: Review (id, status, documentId, reviewerId)
  - EXTENDED: Document.status added IN_REVIEW value
  - NOTED: Reviewer is currently just a User — may need its own entity later
    if reviewer-specific attributes emerge
```

This breadcrumb trail helps the planner (and future slices) understand how the model evolved.

---

## Step 4: Design

Now that you know what entities and schema changes this slice needs, plan the implementation.

**4a. Implementation plan:**
- Which API endpoint(s)?
- What internal logic?
- What validations?
- What existing patterns to follow?

**4b. Test plan:**
- Map each acceptance criterion to a test

**4c. Conflict check:**
- Is anyone else currently working on a slice that touches the same entities?
- If yes, coordinate: who extends the schema first? Sequence your merges.

**Gate:** Design reviewed, test plan exists.

---

## Step 5: Build

**5a. Branch and rebase.**
```
git checkout -b feat/slice-description
git fetch origin && git rebase origin/main
```

**5b. Schema first.** Apply the schema extension (migration) before writing application code. Run it. Verify it works.

**5c. Implement.** API, logic, tests. Follow the design.

**5d. Self-review.** Check acceptance criteria, run full test suite, rebase on latest main.

**5e. Open PR.** Reference the issue. Include the "Entities discovered/extended" note from Step 3d in the PR description.

---

## Step 6: Ship

**6a. Code review.** Reviewer checks correctness AND schema decisions:
- Is the entity model reasonable?
- Are there entities hiding as attributes (or vice versa)?
- Will this schema extension cause problems for known future slices?

**6b. Acceptance testing.** Every criterion passes.

**6c. Merge and deploy.** This slice's schema extension is now part of the shared reality.

**6d. Update the backlog.** Does this slice's discovery change the priority or shape of future slices? If yes, the planner re-evaluates.

---

## Parallelism: How It Emerges

You can't parallelize on day one — the model doesn't exist yet. Here's how parallelism grows:

### Phase: Sequential Foundation (Slices 1-3ish)

Early slices run one at a time. Each one establishes core entities and relationships. This is the cost of not knowing upfront.

```
Slice 1 → merge → Slice 2 → merge → Slice 3 → merge
```

**Why sequential:** Each slice's discoveries reshape what comes next. Running them in parallel would cause conflicting schema changes.

### Phase: Emerging Parallelism (Slices 4+)

Once the core entities exist, slices that touch **different entities** can run in parallel:

```
                    ┌── Slice 4 (extends Review) ──── merge
Slice 3 merged ────┤
                    └── Slice 5 (extends Document) ── merge
```

**The planner's job shifts:** Instead of designing schemas, the planner now identifies which upcoming slices are independent (touch different entities) and can be parallelized.

### Phase: Full Parallelism (Late slices)

The entity model is stable. New slices mostly add behavior to existing entities, not new entities. Conflicts are rare. Multiple contributors work freely.

```
┌── Slice 8 (Document search) ────── merge
├── Slice 9 (Review analytics) ───── merge
├── Slice 10 (Bulk upload) ────────── merge
└── Slice 11 (Email notifications) ── merge
```

### Parallelism Decision Table

| Question | If yes | If no |
|----------|--------|-------|
| Does this slice create a new entity? | Likely sequential — wait for related slices to merge | Possibly parallel |
| Does this slice extend an entity another active slice also extends? | Sequential — coordinate who goes first | Parallel |
| Does this slice only read from existing entities? | Parallel — read-only slices are always safe | Check write conflicts |
| Is the entity model still changing frequently? | Stay sequential — model hasn't settled | Open up parallelism |

---

## Schema Conflict Resolution

When two slices need to extend the same entity at the same time.

### Prevention

The planner checks before assigning parallel slices:
- Do these slices touch the same tables?
- If yes, can one go first and the other rebase?

### Resolution

If a conflict is discovered mid-flight:

1. **Both additive, different columns:** No conflict. Both PRs add their columns. Second to merge rebases and the migration includes both.

2. **Both modify the same column/relationship:** One contributor pauses. The other merges first. The paused contributor rebases and adapts.

3. **One discovers the other's entity model is wrong:** Both pause. Discuss. Agree on the right model. One refactors, the other adapts. This is the cost of incremental discovery — but it's cheaper than building the wrong thing from a full upfront spec.

---

## Coordination Model

### Roles

| Role | Early slices | Late slices |
|------|-------------|-------------|
| **Planner** | Picks flows, reviews schema decisions in PRs, sequences slices | Identifies parallel opportunities, tracks entity model stability |
| **Contributor** | Runs one slice at a time (Steps 1-6) | Runs slices in parallel on independent entities |

### The Planner's Evolving Job

```
Early:  "What's the next most valuable flow? What entities will it need?"
Mid:    "The model is stabilizing. Which slices can run in parallel?"
Late:   "The model is stable. Just point contributors at issues."
```

The planner doesn't need to know everything at the start. They need to know **what to build next** and **when it's safe to parallelize**.

### Living Entity Model

The planner maintains a lightweight entity map (can be a markdown file, a Mermaid diagram, or just a list). Updated after each slice merges:

```markdown
## Entity Model (updated after Slice 5)

Document: id, title, status, fileUrl, authorId, createdAt
  states: DRAFT → IN_REVIEW → APPROVED → ARCHIVED
  has many: Reviews

Author: id, name, email
  has many: Documents

Review: id, status, documentId, reviewerId
  states: PENDING → SUBMITTED
  has many: Comments

Comment: id, body, lineNumber, reviewId

Reviewer: (currently aliased to User — may split later)
```

This is a **descriptive** artifact (documents what exists) not a **prescriptive** one (dictates what to build). The code and migrations are the source of truth.

---

## Comparison: v2 vs v3

| Aspect | v2 (Full Upfront) | v3 (Incremental Discovery) |
|--------|-------------------|---------------------------|
| When schemas are designed | All at once before slicing | Per slice, as flows demand |
| Parallelism from day 1 | Yes (high) | No (sequential start) |
| Wasted design effort | Higher (may design entities never needed) | Lower (only design what you build) |
| Schema amendment frequency | Occasional (amendments to the upfront plan) | Never (there's no plan to amend — schema just grows) |
| Planner knowledge required | Must understand full domain | Must understand priorities and sequencing |
| Risk of wrong model | Discovered late (during implementation) | Discovered early (each slice tests the model) |
| Best for | Stable domains, many contributors from day 1 | New domains, evolving requirements, small-to-growing teams |
| Total time to first deploy | Longer (upfront phases first) | Shorter (first slice ships fast) |

---

## Rules

1. **Build the thinnest thing first.** Slice 1 is a walking skeleton — end-to-end, minimal, ugly is fine.
2. **Discover, don't predict.** Only add entities and columns that this slice's code uses. No speculative schema.
3. **Schema grows with code.** Schema changes live in the slice's PR, not in separate schema PRs.
4. **Sequential until safe.** Don't parallelize until the entity model has stabilized. The planner decides when.
5. **Document what you learned.** Each slice records what entities it discovered or extended.
6. **No phase skipping.** Every slice runs Pick → Map → Discover → Design → Build → Ship.
7. **No phase blending.** Map the flow before touching the schema. Design before coding.
8. **Entity boundaries enable parallelism.** Different entities = safe to parallelize. Same entity = sequence.
9. **The code is the spec.** The living entity model is descriptive, not prescriptive. Migrations are the source of truth.
10. **Planner evolves.** Early: sequence flows. Mid: identify parallelism. Late: just point at issues.
