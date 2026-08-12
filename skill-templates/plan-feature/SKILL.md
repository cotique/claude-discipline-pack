---
name: plan-feature
description: Produces an implementation plan for a task or feature in «project», grounded in the project's own docs. Use whenever the user asks to plan, scope, or design a task/feature, asks "how would we build X", or wants a plan before any code gets written. This skill produces a plan for approval — it does not write implementation code (see implement-plan for that stage).
---

# Plan a feature for «project»

The project's architecture was decided deliberately and captured in
«docs location». Every plan applies that already-agreed design to a specific
piece of work — it does not re-decide the architecture per task. If a task
doesn't fit cleanly into what the docs describe, say so explicitly in the plan
as an open question — don't quietly invent a new architectural call to fill
the gap.

## Read first

- «architecture doc» — stack, execution model, module boundaries
- «data model doc» — existing tables/schemas and their conventions
- «spec / requirements doc» — so you know whether this task belongs in the
  current phase or a later one
- «tradeoffs / decisions log» — deliberate shortcuts with revisit triggers.
  Check both directions: does this task *trip* an existing revisit trigger
  (then the plan should include resolving it), and does it *create* a new
  deliberate shortcut (then the plan should say it gets recorded there)?

## Project-specific design decisions the plan must state

«For each recurring architectural fork in your project, make the plan take a
side and justify it. Examples of forks worth listing here: async workflow vs.
synchronous handler; which module owns the logic; new table vs. extending an
existing one; which layer a validation belongs to. Delete this block and write
your own forks.»

## Flag database changes

Check the existing schema first — most work extends an existing table rather
than needing a new one. If a new table or column is genuinely needed, follow
the conventions already established in «data model doc»:

- «convention 1, e.g. tenant/user scoping column on every owned row»
- «convention 2, e.g. versioning columns alongside generated content»

## Map to requirements

If the task implements or touches a documented requirement, cite its ID. If
nothing covers it, say so plainly — that's a useful signal the spec may need
updating, not something to paper over.

## Output

Present the plan for approval before any code gets written. Cover: what's
being built, which module(s), each design fork taken and why, any DB changes
with rationale, and the requirement mapping. Be concrete — name real file
paths, function names, and table names where you can.

Open with a three-line task contract, so the boundaries are agreed before the
details are argued:

- **Will do** — the scoped outcome.
- **Will verify by** — the check that will prove it (see `test-implementation`).
- **Out of scope** — what this task deliberately does not touch. Naming this
  is what keeps a plan from quietly growing during implementation.

Any causal claim the plan rests on ("the bug is X", "this path is never hit")
carries a **falsifier**: one line saying *"this is wrong if ___"*, checked
before the plan is presented. Tag claims by evidence tier — `[OBSERVED]`,
`[READ: path:line]`, `[INFERRED]` — and never let an `[INFERRED]` claim be the
load-bearing one.

Every plan must end with a **Verification** section: how the work will be
proven working, concretely — which tests at which layer (see
`test-implementation`), and any manual check left for the user. "Tests pass"
isn't a verification plan. If part of the work can't be verified yet (missing
infrastructure, deferred dependency), the plan says so explicitly instead of
leaving it to be discovered during testing.

Mark steps that need a human to do something outside of code (cloud console,
secrets, approvals in a UI) as **manual** so it's clear upfront which parts
`implement-plan` can execute directly.

## Granularity

Default to one plan per task. When several tasks are tightly coupled and
sequential, one epic-level plan beats several thin per-task plans that repeat
each other's context.

## Persisting the plan

Once — and only once — the plan is approved:

- **Trivial/scaffolding work** (no real decision to remember) — don't persist
  a plan file; approval in the moment is enough.
- **Anything with a real decision** — write the approved plan to
  «plans location, e.g. docs/plans/T<N>-<slug>.md» and link it from
  «task list location». Commit it together with the implementation.

Treat a persisted plan file as a frozen historical record, not a living doc.
If reality diverges during implementation, append a short "changed during
implementation: ..." note at the end — never silently rewrite the plan to
match what actually happened.
